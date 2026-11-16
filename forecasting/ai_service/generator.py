from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any, Iterable, Mapping

from forecasting.ai_core import (
    analyse_series,
    build_insight,
    issue_id,
    issue_key,
    summarize_insights,
)
from forecasting.ai_core.calendar import (
    DEFAULT_HISTORY_WEEKS,
    HistoryWindow,
    as_kuching_date,
    completed_week_starts,
    week_start,
)
from forecasting.ai_core.forecast_models import POINT_SEMANTICS
from forecasting.ai_core.opportunity import retailer_opportunities
from forecasting.ai_core.retailer_ranking import (
    DEFAULT_WEEK_CAPACITY,
    build_rankings,
    evidence_from_opportunities,
)

from .normalization import NON_DEMAND_ORDER_STATUSES, NormalizedData
from .notifications import build_ai_notifications
from .outcome_feedback import NormalizedOutcome, apply_outcome_feedback
from .overdue_reorder import detect_overdue_reorders
from .replenishment import derive_replenishment
from .retailer_segments import build_retailer_segments
from .retailer_memory import build_retailer_memory
from .visit_briefs import build_visit_briefs

_DAYS_PER_WEEK = 7.0

DEFAULT_RANKING_SEED = 20260918

_OVERDUE_WINDOW_STAMP = HistoryWindow(
    weeks=DEFAULT_HISTORY_WEEKS,
    requested=DEFAULT_HISTORY_WEEKS,
    source="default",
).stamp()


def _pattern_id(retailer_id: str, product_id: str) -> str:
    key = f"{retailer_id}::{product_id}"
    return "pattern_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:24]


@dataclass(frozen=True)
class GenerationResult:
    run: dict[str, Any]
    patterns: tuple[dict[str, Any], ...]
    insights: tuple[dict[str, Any], ...]
    retailer_segments: tuple[dict[str, Any], ...]
    visit_briefs: tuple[dict[str, Any], ...]
    weekly_summary: dict[str, Any]
    weekly_summaries: tuple[dict[str, Any], ...]
    notifications: tuple[dict[str, Any], ...]
    retailer_memory: tuple[dict[str, Any], ...]
    priority_rankings: tuple[dict[str, Any], ...] = ()
    replenishment: tuple[dict[str, Any], ...] = ()
    coverage_retailers: tuple[dict[str, Any], ...] = ()


def _missing_price_insight(
    *,
    retailer_id: str,
    product_id: str,
    data: NormalizedData,
    run_id: str,
    observed_week: date,
) -> dict[str, Any]:
    retailer = data.retailers[retailer_id]
    product = data.products[product_id]
    insight_type = "missing_product_price"
    return {
        "issueId": issue_id(insight_type, retailer_id, product_id),
        "issueKey": issue_key(insight_type, retailer_id, product_id),
        "type": insight_type,
        "retailerId": retailer_id,
        "productId": product_id,
        "retailerName": retailer.retailer_name,
        "productName": product.product_name,
        "salesmanUid": retailer.salesman_uid,
        "salesmanCode": retailer.salesman_code,
        "branchId": retailer.branch_id,
        "priority": "high",
        "confidence": "high",
        "confidenceScore": 1.0,
        "latestEvidence": {
            "field": "price",
            "problem": "missing_or_non_positive",
        },
        "anomalyScore": 0.0,
        "forecastNextWeek": 0.0,
        "valueAtRiskRm": 0.0,
        "lastObservedWeekStart": observed_week,
        "occurrenceCount": 1,
        "ageDays": 0,
        "questions": [],
        "recommendation": "Open the product editor and add a valid selling price.",
        "reason": "Orders reference this product, but the catalogue has no usable price.",
        "fixTarget": "product",
        "fixEntityId": product_id,
        "sourceRunId": run_id,
        "isDemo": retailer.is_demo or product.is_demo,
    }


def _order_salesman_scopes(
    orders: Iterable[Mapping[str, Any]],
    *,
    as_of: date,
    weeks: int,
) -> dict[str, dict[str, Any]]:
    allowed_weeks = set(completed_week_starts(as_of, weeks=weeks))
    scopes: dict[str, dict[str, Any]] = {}
    for order in orders:
        if _order_status(order) in NON_DEMAND_ORDER_STATUSES:
            continue
        raw = (
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if isinstance(raw, datetime):
            moment = raw
        elif raw is None:
            continue
        else:
            to_datetime = getattr(raw, "to_datetime", None)
            try:
                moment = (
                    to_datetime()
                    if callable(to_datetime)
                    else datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
                )
            except (TypeError, ValueError):
                continue
        if not isinstance(moment, datetime) or week_start(moment) not in allowed_weeks:
            continue
        code = ""
        for field in ("salesmanCode", "salesmanId", "staffId"):
            code = str(order.get(field) or "").strip()
            if code:
                break
        if not code:
            continue
        retailer_id = ""
        for field in ("retailerId", "retailer_id", "retailerCode"):
            retailer_id = str(order.get(field) or "").strip()
            if retailer_id:
                break
        scope = scopes.setdefault(
            code, {"retailers": set(), "uids": set(), "branches": set()}
        )
        if retailer_id:
            scope["retailers"].add(retailer_id)
        uid = str(
            order.get("salesmanUid") or order.get("submittedByUid") or ""
        ).strip()
        if uid:
            scope["uids"].add(uid)
        branch = str(order.get("branchId") or order.get("branch_id") or "").strip()
        if branch:
            scope["branches"].add(branch)
    return scopes


def _scoped_weekly_summaries(
    *,
    patterns: list[dict[str, Any]],
    insights: list[dict[str, Any]],
    base_summary: dict[str, Any],
    order_scopes: Mapping[str, Mapping[str, Any]] | None = None,
) -> tuple[dict[str, Any], ...]:
    order_scopes = order_scopes or {}
    summaries: list[dict[str, Any]] = [
        {**base_summary, "scopeType": "organization", "scopeKey": "all"}
    ]
    for scope_type, field in (
        ("branch", "branchId"),
        ("salesman", "salesmanCode"),
    ):
        by_order = scope_type == "salesman"
        keys = {
            str(row.get(field) or "").strip()
            for row in patterns + insights
            if str(row.get(field) or "").strip()
        }
        if by_order:
            keys |= set(order_scopes)
        for key in sorted(keys):
            ordered = (
                set(order_scopes.get(key, {}).get("retailers", ()))
                if by_order
                else set()
            )

            def _in_scope(row: Mapping[str, Any]) -> bool:
                return str(row.get(field) or "").strip() == key or (
                    str(row.get("retailerId") or "") in ordered
                )

            scoped_patterns = _dedupe(
                (row for row in patterns if _in_scope(row)), "patternId"
            )
            scoped_insights = _dedupe(
                (row for row in insights if _in_scope(row)), "issueId"
            )
            owned = next(
                (
                    row
                    for row in scoped_patterns + scoped_insights
                    if str(row.get(field) or "").strip() == key
                ),
                None,
            )
            source = owned or {}
            order_scope = order_scopes.get(key, {}) if by_order else {}
            summary_id = (
                f"{base_summary['summaryId']}__{scope_type}_"
                + hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
            )
            summaries.append(
                {
                    **base_summary,
                    **summarize_insights(scoped_insights),
                    "summaryId": summary_id,
                    "scopeType": scope_type,
                    "scopeKey": key,
                    "branchId": str(
                        source.get("branchId")
                        or min(order_scope.get("branches") or {""})
                    ),
                    "salesmanUid": str(
                        source.get("salesmanUid")
                        or min(order_scope.get("uids") or {""})
                    ),
                    "salesmanCode": key if by_order else str(
                        source.get("salesmanCode") or ""
                    ),
                    "patternCount": len(scoped_patterns),
                    "retailerCount": len(
                        {
                            str(row.get("retailerId") or "")
                            for row in scoped_patterns + scoped_insights
                            if str(row.get("retailerId") or "")
                        }
                        | ordered
                    ),
                }
            )
    return tuple(summaries)


def _order_status(order: Mapping[str, Any]) -> str:
    return str(order.get("status") or "").strip().lower()


def _dedupe(rows: Iterable[dict[str, Any]], id_field: str) -> list[dict[str, Any]]:
    seen: set[str] = set()
    unique: list[dict[str, Any]] = []
    for row in rows:
        identity = str(row.get(id_field) or "")
        if identity and identity in seen:
            continue
        seen.add(identity)
        unique.append(row)
    return unique


def _last_order_date_by_retailer(
    orders: Iterable[Mapping[str, Any]],
    *,
    as_of: date,
) -> dict[str, date]:
    latest: dict[str, date] = {}
    for order in orders:
        if _order_status(order) in NON_DEMAND_ORDER_STATUSES:
            continue
        raw = (
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if isinstance(raw, datetime):
            order_date = as_kuching_date(raw)
        elif isinstance(raw, date):
            order_date = raw
        elif raw is None:
            continue
        else:
            try:
                order_date = as_kuching_date(
                    datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
                )
            except ValueError:
                continue
        retailer_id = str(
            order.get("retailerId") or order.get("retailer_id") or ""
        ).strip()
        if not retailer_id or order_date > as_of:
            continue
        if retailer_id not in latest or order_date > latest[retailer_id]:
            latest[retailer_id] = order_date
    return latest


def build_priority_rankings(
    patterns: Iterable[Mapping[str, Any]],
    *,
    data: NormalizedData,
    as_of: date,
    run_id: str,
    generated_at: datetime,
    orders: Iterable[Mapping[str, Any]] = (),
    target_size: int = DEFAULT_WEEK_CAPACITY,
    seed: int = DEFAULT_RANKING_SEED,
) -> tuple[dict[str, Any], ...]:
    patterns = tuple(patterns)
    if not patterns:
        return ()
    unit_prices = {
        product_id: record.unit_price_rm
        for product_id, record in data.products.items()
    }
    opportunities = retailer_opportunities(patterns, unit_prices=unit_prices)
    records = {
        retailer_id: {
            "retailerName": record.retailer_name,
            "salesmanUid": record.salesman_uid,
            "salesmanCode": record.salesman_code,
            "branchId": record.branch_id,
            "latitude": record.latitude,
            "longitude": record.longitude,
            "isDemo": record.is_demo,
            "isRetired": record.is_retired,
        }
        for retailer_id, record in data.retailers.items()
    }
    evidence = evidence_from_opportunities(
        opportunities,
        retailer_records=records,
        last_contact_by_retailer=_last_order_date_by_retailer(
            orders, as_of=as_of
        ),
        as_of=as_of,
    )
    if not evidence:
        return ()
    week_start_date = week_start(as_of)
    rankings = build_rankings(
        evidence,
        week_start=week_start_date,
        seed=seed,
        target_size=target_size,
    )
    codes = {
        record.salesman_uid: record.salesman_code
        for record in data.retailers.values()
        if record.salesman_uid
    }

    def _code_for(ranking: Any) -> str:
        resolved = codes.get(ranking.salesman_uid, "")
        if resolved:
            return resolved
        if ranking.salesman_uid or ranking.scope_key == "unassigned":
            return ""
        return ranking.scope_key

    return tuple(
        ranking.to_read_model(
            week_start=week_start_date,
            salesman_code=_code_for(ranking),
            run_id=run_id,
            generated_at=generated_at,
        )
        for ranking in rankings
    )


def _pattern_run_rates(
    patterns: Iterable[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    return [
        {
            "retailerId": row["retailerId"],
            "productId": row["productId"],
            "runRatePerDay": float(row["forecastNextWeek"]) / _DAYS_PER_WEEK,
        }
        for row in patterns
        if str(row.get("forecastStatus") or "").strip().lower() == "ok"
        if row.get("forecastSemantics") == POINT_SEMANTICS
        if float(row.get("forecastNextWeek") or 0) > 0
    ]


def _coverage_retailers(
    data: NormalizedData,
    *,
    run_id: str,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for retailer_id in sorted(data.retailers):
        record = data.retailers[retailer_id]
        if not record.salesman_uid and not record.salesman_code:
            continue
        rows.append(
            {
                "retailerId": retailer_id,
                "retailerName": record.retailer_name,
                "salesmanUid": record.salesman_uid,
                "salesmanCode": record.salesman_code,
                "branchId": record.branch_id,
                "isDemo": record.is_demo,
                "sourceRunId": run_id,
            }
        )
    return rows


def build_generation(
    data: NormalizedData,
    *,
    as_of: date,
    run_id: str,
    generated_at: datetime | None = None,
    outcomes: tuple[NormalizedOutcome, ...] = (),
    orders: Iterable[Mapping[str, Any]] = (),
    window: HistoryWindow | None = None,
) -> GenerationResult:
    window = window or HistoryWindow(
        weeks=DEFAULT_HISTORY_WEEKS,
        requested=DEFAULT_HISTORY_WEEKS,
        source="default",
    )
    stamp = window.stamp()
    now = generated_at or datetime.now(timezone.utc)
    orders = tuple(orders)
    patterns: list[dict[str, Any]] = []
    insights: list[dict[str, Any]] = []

    for series in data.series:
        metrics = analyse_series(series, as_of=as_of, weeks=window.weeks)
        retailer = data.retailers.get(series.retailer_id)
        product = data.products.get(series.product_id)
        pattern_id = _pattern_id(series.retailer_id, series.product_id)
        patterns.append(
            {
                "patternId": pattern_id,
                "retailerId": series.retailer_id,
                "productId": series.product_id,
                "retailerName": series.retailer_name,
                "productName": series.product_name,
                "salesmanUid": series.salesman_uid,
                "salesmanCode": series.salesman_code,
                "branchId": series.branch_id,
                "weekStarts": list(metrics.evidence["weekStarts"]),
                "weeklyQuantities": list(metrics.quantities),
                "weeklyRevenueRm": list(metrics.revenues_rm),
                "weeklyOrderCounts": list(metrics.order_counts),
                "trend": metrics.trend,
                "baselineAverage": metrics.baseline_average,
                "recentAverage": metrics.recent_average,
                "forecastNextWeek": metrics.forecast_next_week,
                "forecastModel": metrics.forecast_model,
                "forecastModelsVersion": metrics.forecast_version,
                "forecastLower": metrics.forecast_lower,
                "forecastUpper": metrics.forecast_upper,
                "forecastProbabilityNonZero": (
                    metrics.forecast_probability_non_zero
                ),
                "forecastStatus": metrics.forecast_status,
                "forecastSemantics": metrics.forecast_semantics,
                "forecastPeriodStart": week_start(as_of).isoformat(),
                "forecastDataCutoff": (
                    week_start(as_of) - timedelta(days=1)
                ).isoformat(),
                "packingSize": product.packing_size if product else "",
                "unitOfMeasure": product.unit_of_measure if product else "",
                "demandClassification": metrics.forecast_classification,
                "anomalyScore": metrics.anomaly_score,
                "confidence": metrics.confidence,
                "confidenceScore": metrics.confidence_score,
                "sourceRunId": run_id,
                "lastObservedWeekStart": metrics.week_starts[-1],
                "isDemo": bool(
                    (retailer and retailer.is_demo) or (product and product.is_demo)
                ),
                "updatedAt": now,
                **stamp,
            }
        )
        candidate = build_insight(series, as_of=as_of, weeks=window.weeks)
        if candidate is not None:
            document = candidate.to_document()
            document.update(
                {
                    **stamp,
                    "sourceRunId": run_id,
                    "isDemo": bool(
                        (retailer and retailer.is_demo)
                        or (product and product.is_demo)
                    ),
                }
            )
            insights.append(document)

    observed_week = patterns[0]["lastObservedWeekStart"] if patterns else as_of
    for retailer_id, product_id in data.data_quality["missingPricePairs"]:
        if retailer_id in data.retailers and product_id in data.products:
            insights.append(
                {
                    **_missing_price_insight(
                        retailer_id=retailer_id,
                        product_id=product_id,
                        data=data,
                        run_id=run_id,
                        observed_week=observed_week,
                    ),
                    **stamp,
                }
            )

    retailer_memory = build_retailer_memory(
        outcomes,
        as_of=as_of,
        run_id=run_id,
        generated_at=now,
    )
    insights.extend(
        {**row, **_OVERDUE_WINDOW_STAMP}
        for row in detect_overdue_reorders(
            orders,
            patterns,
            retailer_memory,
            {
                product_id: record.unit_price_rm
                for product_id, record in data.products.items()
            },
            as_of=as_of,
            run_id=run_id,
            generated_at=now,
        )
    )

    insights = list(
        apply_outcome_feedback(insights, outcomes, evaluated_at=now)
    )
    insights.sort(
        key=lambda row: (
            {"high": 0, "medium": 1, "low": 2}.get(str(row["priority"]), 3),
            str(row["issueId"]),
        )
    )
    summary_metrics = summarize_insights(insights)
    retailer_segments = build_retailer_segments(
        patterns,
        insights,
        run_id=run_id,
        generated_at=now,
    )
    replenishment = tuple(
        derive_replenishment(
            orders,
            patterns,
            retailer_memory,
            _pattern_run_rates(patterns),
            today=as_of,
            require_current_forecast=True,
        )
    )
    coverage_retailers = _coverage_retailers(data, run_id=run_id)
    visit_briefs = build_visit_briefs(
        insights,
        as_of=as_of,
        run_id=run_id,
        generated_at=now,
        retailer_memory=retailer_memory,
        retailer_segments=retailer_segments,
        replenishment=replenishment,
        coverage_retailers=coverage_retailers,
    )
    summary_id = f"week_{observed_week.isoformat()}"
    weekly_summary = {
        "summaryId": summary_id,
        "weekStart": observed_week,
        "asOf": as_of,
        "sourceRunId": run_id,
        **stamp,
        **summary_metrics,
        "dataQuality": {
            key: value
            for key, value in data.data_quality.items()
            if key not in {"missingPricePairs", "retailersMissingCoordinates"}
        },
        "missingPricePairCount": len(data.data_quality["missingPricePairs"]),
        "missingCoordinateRetailerCount": len(
            data.data_quality["retailersMissingCoordinates"]
        ),
        "updatedAt": now,
    }
    weekly_summaries = _scoped_weekly_summaries(
        patterns=patterns,
        insights=insights,
        base_summary=weekly_summary,
        order_scopes=_order_salesman_scopes(
            orders, as_of=as_of, weeks=window.weeks
        ),
    )
    notifications = build_ai_notifications(
        insights,
        as_of=as_of,
        week_start=observed_week,
        run_id=run_id,
        generated_at=now,
    )
    priority_rankings = tuple(
        {**ranking, **stamp}
        for ranking in build_priority_rankings(
            patterns,
            data=data,
            as_of=as_of,
            run_id=run_id,
            generated_at=now,
            orders=orders,
        )
    )
    run = {
        **window.to_dict(),
        "runId": run_id,
        "type": "sales_intelligence",
        "status": "completed",
        "asOf": as_of,
        "weekStart": observed_week,
        "startedAt": now,
        "finishedAt": now,
        "patternCount": len(patterns),
        "insightCount": len(insights),
        "visitBriefCount": len(visit_briefs),
        "retailerSegmentCount": len(retailer_segments),
        "notificationCount": len(notifications),
        "retailerMemoryCount": len(retailer_memory),
        "priorityRankingCount": len(priority_rankings),
        "outcomeCount": len(outcomes),
        "highPriorityCount": summary_metrics["highPriorityCount"],
        "valueAtRiskRm": summary_metrics["valueAtRiskRm"],
        "dataQuality": weekly_summary["dataQuality"],
        "source": "ai1_runner",
    }
    return GenerationResult(
        run=run,
        patterns=tuple(patterns),
        insights=tuple(insights),
        retailer_segments=retailer_segments,
        visit_briefs=visit_briefs,
        weekly_summary=weekly_summary,
        weekly_summaries=weekly_summaries,
        notifications=notifications,
        retailer_memory=retailer_memory,
        priority_rankings=priority_rankings,
        coverage_retailers=tuple(coverage_retailers),
        replenishment=replenishment,
    )

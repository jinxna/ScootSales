from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any, Iterable, Mapping

from forecasting.ai_core.calendar import (
    DEFAULT_HISTORY_WEEKS,
    HistoryWindow,
    as_kuching_date,
    completed_week_starts,
    week_start,
)

from .generator import GenerationResult, build_generation
from .normalization import (
    NormalizedData,
    normalize_firestore_inputs,
    order_moment,
    order_retailer_id,
)
from .outcome_feedback import normalize_outcomes


SCORECARD_VERSION = "scorecard/1.0.0"
SCORECARD_WEEKS = 12
SCORECARD_TOP_COUNT = 2
REPLAY_RUN_ID = "scorecard-replay"
REPLAY_GENERATED_AT = datetime(2000, 1, 1, tzinfo=timezone.utc)
REBUILD_BASIS = "rebuilt with today's shop list and prices"
COMPARISON_NOTE = "compares, does not prove cause"
SIMULATED_LABEL = "simulated"
REAL_LABEL = "real_orders"


class ScorecardError(RuntimeError):
    def __init__(self, cause: BaseException) -> None:
        super().__init__(f"scorecard failed: {type(cause).__name__}: {cause}")


def order_read_weeks(window: HistoryWindow) -> int:
    return max(window.weeks, DEFAULT_HISTORY_WEEKS)


def scorecard_read_weeks(window: HistoryWindow, weeks: int = SCORECARD_WEEKS) -> int:
    return order_read_weeks(window) + weeks


def orders_between(
    orders: Iterable[Mapping[str, Any]],
    start: date,
    end: date,
) -> list[Mapping[str, Any]]:
    kept: list[Mapping[str, Any]] = []
    for order in orders:
        moment = order_moment(order)
        if moment is None:
            continue
        if start <= as_kuching_date(moment) < end:
            kept.append(order)
    return kept


def data_label(*row_groups: Iterable[Mapping[str, Any]]) -> dict[str, Any]:
    batch_ids: set[str] = set()
    total = 0
    simulated = 0
    for rows in row_groups:
        for row in rows:
            total += 1
            batch_id = str(row.get("simulationBatchId") or "").strip()
            if batch_id:
                simulated += 1
                batch_ids.add(batch_id)
    return {
        "kind": SIMULATED_LABEL if batch_ids else REAL_LABEL,
        "simulationBatchIds": sorted(batch_ids),
        "recordCount": total,
        "simulatedRecordCount": simulated,
    }


@dataclass(frozen=True)
class WeekReplay:
    cutoff: date
    data: NormalizedData
    result: GenerationResult
    orders: tuple[Mapping[str, Any], ...]


def replay_week(
    *,
    orders: Iterable[Mapping[str, Any]],
    products: Iterable[Mapping[str, Any]],
    retailers: Iterable[Mapping[str, Any]],
    users: Iterable[Mapping[str, Any]],
    cutoff: date,
    window: HistoryWindow,
) -> WeekReplay:
    if week_start(cutoff) != cutoff:
        raise ValueError(f"cut-off {cutoff.isoformat()} is not a week start")
    sliced = tuple(
        orders_between(
            orders,
            cutoff - timedelta(weeks=order_read_weeks(window)),
            cutoff,
        )
    )
    data = normalize_firestore_inputs(
        orders=sliced,
        products=products,
        retailers=retailers,
        users=users,
        as_of=cutoff,
        history_weeks=window.weeks,
    )
    result = build_generation(
        data,
        as_of=cutoff,
        run_id=REPLAY_RUN_ID,
        generated_at=REPLAY_GENERATED_AT,
        outcomes=(),
        orders=sliced,
        window=window,
    )
    return WeekReplay(cutoff=cutoff, data=data, result=result, orders=sliced)


def period_actuals(
    *,
    orders: Iterable[Mapping[str, Any]],
    products: Iterable[Mapping[str, Any]],
    retailers: Iterable[Mapping[str, Any]],
    users: Iterable[Mapping[str, Any]],
    start: date,
    weeks: int = 1,
) -> dict[tuple[str, str], tuple[float, float]]:
    end = start + timedelta(weeks=weeks)
    data = normalize_firestore_inputs(
        orders=orders_between(orders, start, end),
        products=products,
        retailers=retailers,
        users=users,
        as_of=end,
        history_weeks=weeks,
    )
    actuals: dict[tuple[str, str], tuple[float, float]] = {}
    for series in data.series:
        quantity = sum(row.quantity for row in series.observations)
        revenue = sum(row.revenue_rm for row in series.observations)
        if quantity > 0:
            actuals[(series.retailer_id, series.product_id)] = (quantity, revenue)
    return actuals


def ranked_retailer_ids(ranking: Mapping[str, Any]) -> list[str]:
    rows = sorted(
        (row for row in ranking.get("ranking") or () if row.get("retailerId")),
        key=lambda row: (int(row.get("rank") or 0), str(row["retailerId"])),
    )
    return [str(row["retailerId"]) for row in rows]


def _percent(part: float, whole: float) -> float | None:
    return round(100.0 * part / whole, 1) if whole > 0 else None


def _in_scope(row: Mapping[str, Any], scope_type: str, scope_key: str) -> bool:
    if scope_type == "organization":
        return True
    if scope_type == "branch":
        return row["branchId"] == scope_key
    if scope_type == "salesman":
        return row["salesmanCode"] == scope_key
    raise ValueError(f"unknown scope type {scope_type!r}")


def _label_row(
    raw: Mapping[str, Any], salesman_code: str, branch_id: str
) -> dict[str, str]:
    return {
        "salesmanCode": salesman_code,
        "branchId": branch_id,
        "simulationBatchId": str(raw.get("simulationBatchId") or ""),
    }


def _order_label_row(
    order: Mapping[str, Any], tags: Mapping[str, tuple[str, str]]
) -> dict[str, str]:
    retailer_salesman, retailer_branch = tags.get(order_retailer_id(order), ("", ""))
    return _label_row(
        order,
        retailer_salesman
        or str(order.get("salesmanCode") or order.get("salesmanId") or "").strip(),
        retailer_branch or str(order.get("branchId") or "").strip(),
    )


@dataclass(frozen=True)
class Scorecard:
    common: dict[str, Any]
    label_rows: tuple[dict[str, str], ...]
    weeks_scored: int
    rank_rows: tuple[dict[str, Any], ...]
    forecast_rows: tuple[dict[str, Any], ...]
    unforecast_rows: tuple[dict[str, Any], ...]
    suggestion_rows: tuple[dict[str, Any], ...]
    outcome_rows: tuple[dict[str, Any], ...]

    def block(self, scope_type: str, scope_key: str) -> dict[str, Any]:
        def scoped(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
            return [row for row in rows if _in_scope(row, scope_type, scope_key)]

        rank_rows = scoped(self.rank_rows)
        forecast_rows = scoped(self.forecast_rows)
        unforecast_rows = scoped(self.unforecast_rows)
        suggestion_rows = scoped(self.suggestion_rows)
        outcomes = scoped(self.outcome_rows)
        common = self._scope_common(
            scope_type,
            scoped(self.label_rows),
            [*rank_rows, *forecast_rows, *unforecast_rows, *suggestion_rows],
        )
        block = {
            **common,
            "scopeType": scope_type,
            "scopeKey": scope_key,
            "topRankedOrdered": self._top_ranked(common, rank_rows),
            "forecastAgainstActual": self._forecast(
                common, forecast_rows, unforecast_rows
            ),
            "suggestedReordersKept": self._suggestions(common, suggestion_rows),
        }
        if outcomes:
            block["noSaleReasons"] = self._reasons(common, outcomes)
        return block

    def _scope_common(
        self,
        scope_type: str,
        label_rows: list[dict[str, Any]],
        week_rows: list[dict[str, Any]],
    ) -> dict[str, Any]:
        weeks_scored = (
            self.weeks_scored
            if scope_type == "organization"
            else len({row["weekStart"] for row in week_rows})
        )
        return {
            **self.common,
            "window": {**self.common["window"], "weeksScored": weeks_scored},
            "dataLabel": data_label(label_rows),
        }

    def _top_ranked(
        self, common: dict[str, Any], rows: list[dict[str, Any]]
    ) -> dict[str, Any]:
        top = [row for row in rows if row["inTop"]]
        other = [row for row in rows if not row["inTop"]]
        top_ordered = sum(row["ordered"] for row in top)
        other_ordered = sum(row["ordered"] for row in other)
        return {
            **common,
            "note": COMPARISON_NOTE,
            "topCount": SCORECARD_TOP_COUNT,
            "sample": {
                "salespersonWeeks": len(
                    {(row["weekStart"], row["rankingScopeKey"]) for row in rows}
                ),
                "topShopWeeks": len(top),
                "otherShopWeeks": len(other),
            },
            "topOrderedShopWeeks": top_ordered,
            "topOrderedPercent": _percent(top_ordered, len(top)),
            "otherOrderedShopWeeks": other_ordered,
            "otherOrderedPercent": _percent(other_ordered, len(other)),
        }

    def _forecast(
        self,
        common: dict[str, Any],
        rows: list[dict[str, Any]],
        unforecast: list[dict[str, Any]],
    ) -> dict[str, Any]:
        by_product_week: dict[tuple[str, str], list[float]] = {}
        for row in rows:
            totals = by_product_week.setdefault(
                (row["weekStart"], row["productId"]), [0.0, 0.0]
            )
            totals[0] += row["forecast"]
            totals[1] += row["actual"]
        forecast_units = sum(totals[0] for totals in by_product_week.values())
        actual_units = sum(totals[1] for totals in by_product_week.values())
        absolute_error = sum(
            abs(totals[0] - totals[1]) for totals in by_product_week.values()
        )
        return {
            **common,
            "source": "rebuilt forecasts",
            "level": "product",
            "sample": {
                "productWeeks": len(by_product_week),
                "shopProductWeeks": len(rows),
            },
            "forecastUnits": round(forecast_units, 2),
            "actualUnits": round(actual_units, 2),
            "absoluteErrorUnits": round(absolute_error, 2),
            "weightedAbsolutePercentageError": _percent(
                absolute_error, actual_units
            ),
            "actualUnitsWithoutForecast": round(
                sum(row["actual"] for row in unforecast), 2
            ),
        }

    def _suggestions(
        self, common: dict[str, Any], rows: list[dict[str, Any]]
    ) -> dict[str, Any]:
        kept = sum(row["kept"] for row in rows)
        return {
            **common,
            "sample": {"suggestions": len(rows)},
            "keptSuggestions": kept,
            "keptPercent": _percent(kept, len(rows)),
        }

    def _reasons(
        self, common: dict[str, Any], rows: list[dict[str, Any]]
    ) -> dict[str, Any]:
        counts: dict[str, int] = {}
        for row in rows:
            counts[row["reasonCode"]] = counts.get(row["reasonCode"], 0) + 1
        return {
            **common,
            "sample": {"outcomes": len(rows)},
            "byReasonCode": [
                {"reasonCode": code, "count": count}
                for code, count in sorted(
                    counts.items(), key=lambda item: (-item[1], item[0])
                )
            ],
        }


def build_scorecard(
    *,
    orders: Iterable[Mapping[str, Any]],
    products: Iterable[Mapping[str, Any]],
    retailers: Iterable[Mapping[str, Any]],
    users: Iterable[Mapping[str, Any]],
    as_of: date,
    window: HistoryWindow,
    outcomes: Iterable[Mapping[str, Any]] = (),
    weeks: int = SCORECARD_WEEKS,
) -> Scorecard:
    orders = tuple(orders)
    products = tuple(products)
    retailers = tuple(retailers)
    users = tuple(users)
    outcomes = tuple(outcomes)
    scored_weeks = completed_week_starts(as_of, weeks=weeks)
    window_end = week_start(as_of)

    rank_rows: list[dict[str, Any]] = []
    forecast_rows: list[dict[str, Any]] = []
    unforecast_rows: list[dict[str, Any]] = []
    suggestion_rows: list[dict[str, Any]] = []
    weeks_scored = 0
    tags: dict[str, tuple[str, str]] = {}

    for cutoff in scored_weeks:
        replay = replay_week(
            orders=orders,
            products=products,
            retailers=retailers,
            users=users,
            cutoff=cutoff,
            window=window,
        )
        for retailer_id, record in replay.data.retailers.items():
            tags[retailer_id] = (record.salesman_code, record.branch_id)
        if not replay.result.patterns:
            continue
        weeks_scored += 1
        week_key = cutoff.isoformat()
        actuals = period_actuals(
            orders=orders,
            products=products,
            retailers=retailers,
            users=users,
            start=cutoff,
        )
        ordered_retailers = {retailer_id for retailer_id, _ in actuals}

        for ranking in replay.result.priority_rankings:
            for position, retailer_id in enumerate(ranked_retailer_ids(ranking)):
                rank_rows.append(
                    {
                        "weekStart": week_key,
                        "rankingScopeKey": str(ranking.get("scopeKey") or ""),
                        "salesmanCode": str(ranking.get("salesmanCode") or ""),
                        "branchId": str(ranking.get("branchId") or ""),
                        "retailerId": retailer_id,
                        "inTop": position < SCORECARD_TOP_COUNT,
                        "ordered": retailer_id in ordered_retailers,
                    }
                )

        pattern_tags: dict[tuple[str, str], tuple[str, str]] = {}
        forecast_pairs: set[tuple[str, str]] = set()
        for pattern in replay.result.patterns:
            pair = (str(pattern["retailerId"]), str(pattern["productId"]))
            pattern_tags[pair] = (
                str(pattern.get("salesmanCode") or ""),
                str(pattern.get("branchId") or ""),
            )
            if str(pattern.get("forecastStatus") or "").strip().lower() != "ok":
                continue
            forecast_pairs.add(pair)
            forecast_rows.append(
                {
                    "weekStart": week_key,
                    "productId": pair[1],
                    "salesmanCode": pattern_tags[pair][0],
                    "branchId": pattern_tags[pair][1],
                    "forecast": float(pattern.get("forecastNextWeek") or 0),
                    "actual": actuals.get(pair, (0.0, 0.0))[0],
                }
            )

        def _pair_tags(pair: tuple[str, str]) -> tuple[str, str]:
            return pattern_tags.get(pair) or tags.get(pair[0], ("", ""))

        for pair in sorted(set(actuals) - forecast_pairs):
            salesman_code, branch_id = _pair_tags(pair)
            unforecast_rows.append(
                {
                    "weekStart": week_key,
                    "productId": pair[1],
                    "salesmanCode": salesman_code,
                    "branchId": branch_id,
                    "actual": actuals[pair][0],
                }
            )

        for suggestion in replay.result.replenishment:
            if str(suggestion.get("suggestionStatus") or "").lower() != "suggested":
                continue
            if float(suggestion.get("suggestedQty") or 0) <= 0:
                continue
            pair = (
                str(suggestion.get("retailerId") or ""),
                str(suggestion.get("productId") or ""),
            )
            salesman_code, branch_id = _pair_tags(pair)
            suggestion_rows.append(
                {
                    "weekStart": week_key,
                    "retailerId": pair[0],
                    "productId": pair[1],
                    "salesmanCode": salesman_code,
                    "branchId": branch_id,
                    "kept": pair in actuals,
                }
            )

    outcome_rows: list[dict[str, Any]] = []
    outcome_label_rows: list[dict[str, str]] = []
    if scored_weeks:
        for raw in outcomes:
            outcome = normalize_outcomes((raw,))[0]
            if outcome.submitted_at is None or not outcome.reason_code:
                continue
            local_date = as_kuching_date(outcome.submitted_at)
            if not scored_weeks[0] <= local_date < window_end:
                continue
            fallback = tags.get(outcome.retailer_id, ("", ""))
            salesman_code = outcome.salesman_code or fallback[0]
            branch_id = outcome.branch_id or fallback[1]
            outcome_label_rows.append(_label_row(raw, salesman_code, branch_id))
            outcome_rows.append(
                {
                    "reasonCode": outcome.reason_code,
                    "salesmanCode": salesman_code,
                    "branchId": branch_id,
                }
            )

    common = {
        "version": SCORECARD_VERSION,
        "asOf": as_of.isoformat(),
        "basis": REBUILD_BASIS,
        "window": {
            "firstWeekStart": scored_weeks[0].isoformat(),
            "lastWeekStart": scored_weeks[-1].isoformat(),
            "weeksRequested": weeks,
            "weeksScored": weeks_scored,
            "historyWeeks": window.weeks,
            "orderReadWeeks": scorecard_read_weeks(window, weeks),
        },
    }
    label_rows = (
        *(_order_label_row(order, tags) for order in orders),
        *outcome_label_rows,
    )
    return Scorecard(
        common=common,
        label_rows=label_rows,
        weeks_scored=weeks_scored,
        rank_rows=tuple(rank_rows),
        forecast_rows=tuple(forecast_rows),
        unforecast_rows=tuple(unforecast_rows),
        suggestion_rows=tuple(suggestion_rows),
        outcome_rows=tuple(outcome_rows),
    )


def scorecard_blocks(
    scorecard: Scorecard,
    summaries: Iterable[Mapping[str, Any]],
) -> list[tuple[str, dict[str, Any]]]:
    return [
        (
            str(summary["summaryId"]),
            {
                "scorecard": scorecard.block(
                    str(summary.get("scopeType") or "organization"),
                    str(summary.get("scopeKey") or "all"),
                )
            },
        )
        for summary in summaries
    ]

from __future__ import annotations

import math
from datetime import date, datetime, timedelta
from typing import Any, Iterable, Mapping

from forecasting.ai_core.calendar import as_kuching_date, week_start
from forecasting.ai_core.forecast_contract import PERIOD_DAYS
from forecasting.ai_core.forecast_models import POINT_SEMANTICS
from forecasting.ai_service.order_lines import authoritative_order_items


SUPPRESSING_REASON_CODES = frozenset(
    {
        "switched_to_alternative",
        "seasonal_change",
        "packaging_change",
    }
)

EXCLUDED_ORDER_STATUSES = frozenset(
    {
        "cancelled",
        "canceled",
        "rejected",
        "draft",
        "deleted",
        "held_for_review",
    }
)

_HISTORY_BAND_LOW = 0.5
_HISTORY_BAND_HIGH = 2.0

_RUN_RATE_WEIGHT = 0.6
_HISTORY_WEIGHT = 0.4

_CONF_HISTORY_WEIGHT = 0.5
_CONF_RECENCY_WEIGHT = 0.3
_CONF_RUN_RATE_WEIGHT = 0.2
_SPARSE_ORDER_THRESHOLD = 2
_SPARSE_CONFIDENCE_CAP = 0.35
_RUN_RATE_FALLBACK_FACTOR = 0.4
_RECENCY_HORIZON_DAYS = 90.0
_HISTORY_DEPTH_TARGET = 4


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _number(value: Any) -> float:
    if isinstance(value, bool) or value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = str(value).replace(",", "").replace("RM", "").strip()
    try:
        return float(cleaned)
    except ValueError:
        return 0.0


def _first_text(row: Mapping[str, Any], fields: tuple[str, ...]) -> str:
    for field in fields:
        value = _text(row.get(field))
        if value:
            return value
    return ""


def _first_number(row: Mapping[str, Any], fields: tuple[str, ...]) -> float:
    for field in fields:
        if field in row and row.get(field) is not None:
            number = _number(row.get(field))
            if number:
                return number
    return 0.0


def _as_local_date(value: Any) -> date | None:
    if isinstance(value, datetime):
        return as_kuching_date(value)
    if isinstance(value, date):
        return value
    if value is None:
        return None
    to_datetime = getattr(value, "to_datetime", None)
    if callable(to_datetime):
        converted = to_datetime()
        if isinstance(converted, datetime):
            return as_kuching_date(converted)
    try:
        return as_kuching_date(
            datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        )
    except ValueError:
        return None


def _round_half_up(value: float) -> int:
    return int(value + 0.5) if value >= 0 else -int(-value + 0.5)


def _suppressed_pairs(
    memory: Iterable[Mapping[str, Any]],
) -> set[tuple[str, str]]:
    suppressed: set[tuple[str, str]] = set()
    for row in memory:
        retailer_id = _first_text(row, ("retailerId", "retailer_id"))
        if not retailer_id:
            continue
        issues = row.get("lastConfirmedIssues")
        if not isinstance(issues, (list, tuple)):
            continue
        for issue in issues:
            if not isinstance(issue, Mapping):
                continue
            reason = _text(issue.get("reasonCode")).lower()
            if reason not in SUPPRESSING_REASON_CODES:
                continue
            key_text = _text(issue.get("issueKey"))
            product_id = key_text.split("::")[-1] if "::" in key_text else ""
            if product_id:
                suppressed.add((retailer_id, product_id))
    return suppressed


def _pattern_index(
    item_patterns: Iterable[Mapping[str, Any]],
) -> dict[tuple[str, str], dict[str, Any]]:
    index: dict[tuple[str, str], dict[str, Any]] = {}
    for row in item_patterns:
        retailer_id = _first_text(row, ("retailerId", "retailer_id"))
        product_id = _first_text(row, ("productId", "product_id"))
        if retailer_id and product_id:
            index[(retailer_id, product_id)] = dict(row)
    return index


def _pattern_mean_qty(pattern: Mapping[str, Any] | None) -> float:
    if not pattern:
        return 0.0
    quantities = pattern.get("weeklyQuantities")
    order_counts = pattern.get("weeklyOrderCounts")
    if isinstance(quantities, (list, tuple)) and isinstance(
        order_counts, (list, tuple)
    ):
        total_qty = sum(_number(value) for value in quantities)
        total_orders = sum(_number(value) for value in order_counts)
        if total_orders > 0:
            return total_qty / total_orders
    return _number(pattern.get("baselineAverage"))


def _run_rate_index(
    run_rates: Iterable[Mapping[str, Any]],
) -> dict[tuple[str, str], float]:
    index: dict[tuple[str, str], float] = {}
    for row in run_rates:
        retailer_id = _first_text(row, ("retailerId", "retailer_id"))
        product_id = _first_text(row, ("productId", "product_id"))
        if not retailer_id or not product_id:
            continue
        rate = _first_number(
            row,
            ("runRatePerDay", "run_rate_per_day", "runRate", "rate"),
        )
        if rate > 0:
            index[(retailer_id, product_id)] = rate
    return index


def _forecast_provenance(
    pattern: Mapping[str, Any] | None,
    *,
    today: date,
    require_current_forecast: bool,
) -> dict[str, Any]:
    expected_period_start = week_start(today)
    expected_data_cutoff = expected_period_start - timedelta(days=1)
    source_period_start = _as_local_date(
        (pattern or {}).get("forecastPeriodStart")
    )
    source_data_cutoff = _as_local_date(
        (pattern or {}).get("forecastDataCutoff")
    )
    raw_status = _text((pattern or {}).get("forecastStatus")).lower()
    point_semantics = _text((pattern or {}).get("forecastSemantics"))
    raw_classification = _text(
        (pattern or {}).get("demandClassification")
    ).lower()
    raw_starts = (pattern or {}).get("weekStarts")
    raw_quantities = (pattern or {}).get("weeklyQuantities")
    observed_periods = (
        len(raw_starts) if isinstance(raw_starts, (list, tuple)) else 0
    )
    non_zero_periods = (
        sum(1 for value in raw_quantities if _number(value) > 0)
        if isinstance(raw_quantities, (list, tuple))
        else 0
    )
    if pattern is None:
        status = "insufficient_history"
    elif (
        not require_current_forecast
        and not any(
            field in pattern
            for field in (
                "forecastStatus",
                "forecastSemantics",
                "forecastPeriodStart",
                "forecastDataCutoff",
            )
        )
    ):
        status = "legacy"
    elif source_period_start is None or source_data_cutoff is None:
        status = "unavailable"
    elif (
        source_period_start < expected_period_start
        or source_data_cutoff < expected_data_cutoff
    ):
        status = "stale"
    elif (
        source_period_start > expected_period_start
        or source_data_cutoff > expected_data_cutoff
    ):
        status = "unavailable"
    elif raw_status == "insufficient_history":
        status = (
            "no_demand"
            if raw_classification == "no_demand"
            and observed_periods > 0
            and non_zero_periods == 0
            else "insufficient_history"
        )
    elif raw_status == "ok" and point_semantics == POINT_SEMANTICS:
        status = "ok"
    else:
        status = "unavailable"

    raw_point = (pattern or {}).get("forecastNextWeek")
    point: float | None = None
    if (
        status in {"ok", "stale"}
        and raw_status == "ok"
        and point_semantics == POINT_SEMANTICS
    ):
        if isinstance(raw_point, bool) or raw_point is None:
            status = "unavailable"
        else:
            try:
                candidate = float(raw_point)
            except (TypeError, ValueError, OverflowError):
                status = "unavailable"
            else:
                if math.isfinite(candidate) and candidate >= 0:
                    point = candidate
                else:
                    status = "unavailable"

    raw_probability = (pattern or {}).get("forecastProbabilityNonZero")
    probability: float | None = None
    if isinstance(raw_probability, (int, float)) and not isinstance(raw_probability, bool):
        candidate_probability = float(raw_probability)
        if math.isfinite(candidate_probability) and 0 <= candidate_probability <= 1:
            probability = candidate_probability

    return {
        "periodStart": (
            source_period_start.isoformat() if source_period_start else None
        ),
        "periodDays": PERIOD_DAYS,
        "dataCutoff": (
            source_data_cutoff.isoformat() if source_data_cutoff else None
        ),
        "point": point,
        "pointSemantics": point_semantics,
        "probabilityNonZero": probability,
        "model": _text((pattern or {}).get("forecastModel")) or None,
        "modelVersion": _text((pattern or {}).get("forecastModelsVersion")) or None,
        "status": status,
        "observedPeriods": observed_periods,
        "nonZeroPeriods": non_zero_periods,
        "generatedAt": (pattern or {}).get("updatedAt"),
    }


def _order_history(
    orders: Iterable[Mapping[str, Any]],
) -> dict[tuple[str, str], dict[str, Any]]:
    history: dict[tuple[str, str], dict[str, Any]] = {}
    for position, raw_order in enumerate(orders):
        order = dict(raw_order)
        status = _text(order.get("status")).lower()
        if status in EXCLUDED_ORDER_STATUSES:
            continue
        order_date = _as_local_date(
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if order_date is None:
            continue
        retailer_id = _first_text(
            order,
            ("retailerId", "retailer_id", "retailerCode"),
        )
        if not retailer_id:
            continue
        items = authoritative_order_items(order)
        order_id = _first_text(order, ("orderId", "docId")) or f"row-{position}"
        per_product: dict[str, float] = {}
        for raw_item in items:
            if not isinstance(raw_item, Mapping):
                continue
            product_id = _first_text(
                raw_item,
                ("productId", "itemId", "productCode", "sku"),
            )
            if not product_id:
                continue
            quantity = _first_number(
                raw_item,
                ("qty", "quantity", "orderQty", "boxes"),
            )
            if quantity <= 0:
                continue
            per_product[product_id] = per_product.get(product_id, 0.0) + quantity

        for product_id, quantity in per_product.items():
            key = (retailer_id, product_id)
            record = history.setdefault(
                key,
                {
                    "orderIds": set(),
                    "lastDate": order_date,
                    "lastQty": quantity,
                    "quantities": [],
                },
            )
            record["orderIds"].add(order_id)
            record["quantities"].append(quantity)
            if order_date >= record["lastDate"]:
                record["lastDate"] = order_date
                record["lastQty"] = quantity
    return history


def _confidence(
    *,
    order_count: int,
    days_ago: int,
    run_rate_available: bool,
) -> float:
    history_depth = min(1.0, order_count / _HISTORY_DEPTH_TARGET)
    recency = max(0.0, 1.0 - (days_ago / _RECENCY_HORIZON_DAYS))
    run_rate_factor = 1.0 if run_rate_available else _RUN_RATE_FALLBACK_FACTOR
    score = (
        _CONF_HISTORY_WEIGHT * history_depth
        + _CONF_RECENCY_WEIGHT * recency
        + _CONF_RUN_RATE_WEIGHT * run_rate_factor
    )
    if order_count < _SPARSE_ORDER_THRESHOLD:
        score = min(score, _SPARSE_CONFIDENCE_CAP)
    return max(0.0, min(1.0, score))


def _confidence_label(confidence: float) -> str:
    if confidence >= 0.7:
        return "high"
    if confidence >= 0.4:
        return "medium"
    return "low"


def derive_replenishment(
    orders: Iterable[Mapping[str, Any]],
    item_patterns: Iterable[Mapping[str, Any]],
    memory: Iterable[Mapping[str, Any]],
    run_rates: Iterable[Mapping[str, Any]],
    today: date,
    require_current_forecast: bool = False,
) -> list[dict[str, Any]]:
    suppressed = _suppressed_pairs(memory)
    patterns = _pattern_index(item_patterns)
    run_rate_by_pair = _run_rate_index(run_rates)
    history = _order_history(orders)

    suggestions: list[dict[str, Any]] = []
    for key in sorted(history):
        retailer_id, product_id = key
        if key in suppressed:
            continue

        pattern = patterns.get(key)
        if pattern and _text(pattern.get("trend")).lower() == "stopped":
            continue

        record = history[key]
        last_date: date = record["lastDate"]
        days_ago = (today - last_date).days
        if days_ago <= 0:
            continue

        last_order_qty = _round_half_up(record["lastQty"])
        order_count = len(record["orderIds"])
        forecast = _forecast_provenance(
            pattern,
            today=today,
            require_current_forecast=require_current_forecast,
        )
        run_rate = (
            run_rate_by_pair.get(key)
            if forecast["status"] in {"ok", "legacy"}
            else None
        )

        pattern_mean_qty = _pattern_mean_qty(pattern)
        if pattern_mean_qty <= 0 and record["quantities"]:
            pattern_mean_qty = sum(record["quantities"]) / len(
                record["quantities"]
            )

        if forecast["status"] not in {"ok", "legacy"}:
            confidence = _confidence(
                order_count=order_count,
                days_ago=days_ago,
                run_rate_available=False,
            )
            observed_periods = int(forecast["observedPeriods"])
            non_zero_periods = int(forecast["nonZeroPeriods"])
            insufficient_history = forecast["status"] == "insufficient_history"
            no_demand = forecast["status"] == "no_demand"
            history_detail = (
                f"({non_zero_periods}/{observed_periods} demand weeks)"
                if observed_periods > 0
                else "(no weekly series)"
            )
            if insufficient_history:
                rationale = (
                    "Insufficient usable weekly history "
                    f"{history_detail}; no order quantity suggested."
                )
            elif forecast["status"] == "stale":
                rationale = "Weekly forecast is stale; no order quantity suggested."
            elif no_demand:
                rationale = (
                    "No demand in the completed weekly history; "
                    "no order quantity suggested."
                )
            else:
                rationale = (
                    "Weekly forecast metadata is unavailable; "
                    "no order quantity suggested."
                )
            suggestions.append(
                {
                    "retailerId": retailer_id,
                    "productId": product_id,
                    "productName": _text((pattern or {}).get("productName")),
                    "packingSize": _text((pattern or {}).get("packingSize")),
                    "unitOfMeasure": _text((pattern or {}).get("unitOfMeasure")),
                    "suggestedQty": None,
                    "suggestionStatus": (
                        "insufficient_history"
                        if insufficient_history
                        else "no_demand"
                        if no_demand
                        else "stale_forecast"
                        if forecast["status"] == "stale"
                        else "forecast_unavailable"
                    ),
                    "confidence": round(confidence, 3),
                    "confidenceLabel": _confidence_label(confidence),
                    "rationale": rationale,
                    "inputs": {
                        "lastOrderQty": last_order_qty,
                        "lastOrderDaysAgo": days_ago,
                        "runRatePerDay": None,
                        "patternMeanQty": round(pattern_mean_qty, 2),
                    },
                    "forecast": forecast,
                }
            )
            continue

        if forecast["status"] == "ok" and forecast["point"] == 0:
            confidence = _confidence(
                order_count=order_count,
                days_ago=days_ago,
                run_rate_available=False,
            )
            suggestions.append(
                {
                    "retailerId": retailer_id,
                    "productId": product_id,
                    "productName": _text((pattern or {}).get("productName")),
                    "packingSize": _text((pattern or {}).get("packingSize")),
                    "unitOfMeasure": _text((pattern or {}).get("unitOfMeasure")),
                    "suggestedQty": None,
                    "suggestionStatus": "no_demand",
                    "confidence": round(confidence, 3),
                    "confidenceLabel": _confidence_label(confidence),
                    "rationale": (
                        "The usable weekly forecast is zero; "
                        "no order quantity suggested."
                    ),
                    "inputs": {
                        "lastOrderQty": last_order_qty,
                        "lastOrderDaysAgo": days_ago,
                        "runRatePerDay": None,
                        "patternMeanQty": round(pattern_mean_qty, 2),
                    },
                    "forecast": forecast,
                }
            )
            continue

        if run_rate and run_rate > 0:
            projection = run_rate * days_ago
            if pattern_mean_qty > 0:
                blended = (
                    _RUN_RATE_WEIGHT * projection
                    + _HISTORY_WEIGHT * pattern_mean_qty
                )
                expected = min(
                    max(blended, _HISTORY_BAND_LOW * pattern_mean_qty),
                    _HISTORY_BAND_HIGH * pattern_mean_qty,
                )
            else:
                expected = projection
            run_rate_available = True
            rationale = (
                f"Last ordered {days_ago} days ago (qty {last_order_qty}). "
                f"Run-rate {round(run_rate, 3)}/day projects "
                f"{round(projection, 2)} units over the gap; typical order "
                f"{round(pattern_mean_qty, 2)}."
            )
        elif pattern_mean_qty > 0:
            expected = pattern_mean_qty
            run_rate_available = False
            rationale = (
                f"Last ordered {days_ago} days ago (qty {last_order_qty}). "
                f"No run-rate available; using typical order "
                f"{round(pattern_mean_qty, 2)}."
            )
        else:
            continue

        suggested_qty = max(1, _round_half_up(expected))
        confidence = _confidence(
            order_count=order_count,
            days_ago=days_ago,
            run_rate_available=run_rate_available,
        )
        suggestions.append(
            {
                "retailerId": retailer_id,
                "productId": product_id,
                "productName": _text((pattern or {}).get("productName")),
                "packingSize": _text((pattern or {}).get("packingSize")),
                "unitOfMeasure": _text((pattern or {}).get("unitOfMeasure")),
                "suggestedQty": suggested_qty,
                "suggestionStatus": (
                    "suggested"
                    if forecast["status"] == "ok"
                    else "legacy_unverified"
                ),
                "confidence": round(confidence, 3),
                "confidenceLabel": _confidence_label(confidence),
                "rationale": rationale,
                "inputs": {
                    "lastOrderQty": last_order_qty,
                    "lastOrderDaysAgo": days_ago,
                    "runRatePerDay": (
                        round(run_rate, 3) if run_rate and run_rate > 0 else None
                    ),
                    "patternMeanQty": round(pattern_mean_qty, 2),
                },
                "forecast": forecast,
            }
        )
    return suggestions

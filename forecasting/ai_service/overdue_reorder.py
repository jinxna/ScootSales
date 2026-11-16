from __future__ import annotations

import statistics
from datetime import date, datetime, timedelta
from typing import Any, Iterable, Mapping

from forecasting.ai_service.order_lines import authoritative_order_items

from forecasting.ai_core import completed_week_starts, issue_id, issue_key
from forecasting.ai_core.calendar import as_kuching_date

from .replenishment import (
    EXCLUDED_ORDER_STATUSES,
    _as_local_date,
    _first_number,
    _first_text,
    _round_half_up,
    _suppressed_pairs,
    _text,
)
from .normalization import is_demo_record

INSIGHT_TYPE = "overdue_reorder"

MIN_ORDERS_IN_WINDOW = 3

OVERDUE_MULTIPLIER = 1.5

CV_CUTOFF = 0.5

DEPTH_TARGET = 4

_CONF_REGULARITY_WEIGHT = 0.5
_CONF_DEPTH_WEIGHT = 0.3
_CONF_MAGNITUDE_WEIGHT = 0.2

_HIGH_RISK_RM = 100.0


def _confidence_label(confidence: float) -> str:
    if confidence >= 0.7:
        return "high"
    if confidence >= 0.4:
        return "medium"
    return "low"


def _pair_orders(
    orders: Iterable[Mapping[str, Any]],
    *,
    window_start: date,
    window_end: date,
    recency_end: date,
    unit_prices: Mapping[str, float],
) -> dict[tuple[str, str], list[dict[str, Any]]]:
    by_pair: dict[tuple[str, str], dict[str, dict[str, Any]]] = {}
    for position, raw_order in enumerate(orders):
        order = dict(raw_order)
        if _text(order.get("status")).lower() in EXCLUDED_ORDER_STATUSES:
            continue
        order_date = _as_local_date(
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if order_date is None or not (window_start <= order_date < recency_end):
            continue
        in_window = order_date < window_end
        retailer_id = _first_text(
            order,
            ("retailerId", "retailer_id", "retailerCode"),
        )
        if not retailer_id:
            continue
        items = authoritative_order_items(order)
        order_id = _first_text(order, ("orderId", "docId")) or f"row-{position}"
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
            item_price = _first_number(raw_item, ("price", "unitPrice"))
            unit_price = item_price if item_price > 0 else unit_prices.get(
                product_id, 0.0
            )
            per_order = by_pair.setdefault((retailer_id, product_id), {})
            record = per_order.setdefault(
                order_id,
                {
                    "date": order_date,
                    "qty": 0.0,
                    "revenue": 0.0,
                    "inWindow": in_window,
                },
            )
            record["qty"] += quantity
            record["revenue"] += quantity * unit_price
            if order_date < record["date"]:
                record["date"] = order_date
    return {
        pair: sorted(records.values(), key=lambda row: row["date"])
        for pair, records in by_pair.items()
    }


def _metadata_index(
    patterns: Iterable[Mapping[str, Any]],
) -> dict[tuple[str, str], dict[str, Any]]:
    index: dict[tuple[str, str], dict[str, Any]] = {}
    for row in patterns:
        retailer_id = _first_text(row, ("retailerId", "retailer_id"))
        product_id = _first_text(row, ("productId", "product_id"))
        if retailer_id and product_id:
            index[(retailer_id, product_id)] = dict(row)
    return index


def _copy(
    product_name: str,
    *,
    interval_days: int,
    days_since: int,
    overdue_by: int,
    order_count: int,
) -> tuple[tuple[str, str], str, str]:
    name = product_name or "this product"
    questions = (
        f"Is {name} due for a reorder? The retailer reorders about every "
        f"{interval_days} days, but the last order was {days_since} days ago.",
        "Confirm whether the retailer still buys on the usual cadence or has "
        "changed their ordering pattern.",
    )
    recommendation = (
        f"Prompt a reorder of {name}: the usual {interval_days}-day ordering "
        f"cadence is overdue by {overdue_by} days."
    )
    reason = (
        f"The retailer's ordering cadence for {name} averages {interval_days} "
        f"days across {order_count} recent orders, and {days_since} days have "
        f"passed since the last order - beyond the {OVERDUE_MULTIPLIER}x "
        "overdue point for that cadence."
    )
    return questions, recommendation, reason


def detect_overdue_reorders(
    orders: Iterable[Mapping[str, Any]],
    patterns: Iterable[Mapping[str, Any]],
    memory: Iterable[Mapping[str, Any]],
    unit_prices: Mapping[str, float],
    *,
    as_of: date,
    run_id: str,
    generated_at: datetime | None = None,
) -> list[dict[str, Any]]:
    week_starts = completed_week_starts(as_of, weeks=8)
    window_start = week_starts[0]
    window_end = week_starts[-1] + (week_starts[1] - week_starts[0])
    observed_week = week_starts[-1]
    as_of_day = as_kuching_date(as_of)
    recency_end = max(window_end, as_of_day + timedelta(days=1))

    suppressed = _suppressed_pairs(memory)
    metadata = _metadata_index(patterns)
    pair_orders = _pair_orders(
        orders,
        window_start=window_start,
        window_end=window_end,
        recency_end=recency_end,
        unit_prices=unit_prices,
    )

    insights: list[dict[str, Any]] = []
    for pair in sorted(pair_orders):
        retailer_id, product_id = pair
        if pair in suppressed:
            continue

        meta = metadata.get(pair, {})
        if _text(meta.get("trend")).lower() == "stopped":
            continue

        all_records = pair_orders[pair]
        records = [record for record in all_records if record["inWindow"]]
        if len(records) < MIN_ORDERS_IN_WINDOW:
            continue

        dates = [record["date"] for record in records]
        gaps = [(dates[index + 1] - dates[index]).days for index in range(len(dates) - 1)]
        interval = statistics.median(gaps)
        mean_gap = statistics.fmean(gaps)
        if interval <= 0 or mean_gap <= 0:
            continue
        cv = statistics.pstdev(gaps) / mean_gap if len(gaps) > 1 else 0.0
        if cv > CV_CUTOFF:
            continue

        last_order_date = max(record["date"] for record in all_records)
        days_since = (as_of_day - last_order_date).days
        if days_since <= interval * OVERDUE_MULTIPLIER:
            continue

        overdue_ratio = days_since / interval
        regularity = max(0.0, 1.0 - cv / CV_CUTOFF)
        depth = min(1.0, len(records) / DEPTH_TARGET)
        magnitude = min(
            1.0,
            max(0.0, (overdue_ratio - OVERDUE_MULTIPLIER) / OVERDUE_MULTIPLIER),
        )
        confidence_score = round(
            max(
                0.0,
                min(
                    1.0,
                    _CONF_REGULARITY_WEIGHT * regularity
                    + _CONF_DEPTH_WEIGHT * depth
                    + _CONF_MAGNITUDE_WEIGHT * magnitude,
                ),
            ),
            4,
        )
        confidence = _confidence_label(confidence_score)

        quantities = [record["qty"] for record in records]
        typical_qty = _round_half_up(statistics.median(quantities))
        revenues = [record["revenue"] for record in records]
        total_qty = sum(quantities)
        total_revenue = sum(revenues)
        unit_price = unit_prices.get(product_id, 0.0)
        if unit_price <= 0 and total_qty > 0:
            unit_price = total_revenue / total_qty
        value_at_risk = round(max(0.0, typical_qty * unit_price), 2)

        priority = (
            "high"
            if value_at_risk >= _HIGH_RISK_RM or confidence == "high"
            else "medium"
        )

        interval_days = round(interval)
        overdue_by = days_since - interval_days
        questions, recommendation, reason = _copy(
            _text(meta.get("productName")),
            interval_days=interval_days,
            days_since=days_since,
            overdue_by=overdue_by,
            order_count=len(records),
        )
        insights.append(
            {
                "issueId": issue_id(INSIGHT_TYPE, retailer_id, product_id),
                "issueKey": issue_key(INSIGHT_TYPE, retailer_id, product_id),
                "type": INSIGHT_TYPE,
                "retailerId": retailer_id,
                "productId": product_id,
                "retailerName": _text(meta.get("retailerName")),
                "productName": _text(meta.get("productName")),
                "salesmanUid": _text(meta.get("salesmanUid")),
                "salesmanCode": _text(meta.get("salesmanCode")),
                "branchId": _text(meta.get("branchId")),
                "priority": priority,
                "confidence": confidence,
                "confidenceScore": confidence_score,
                "latestEvidence": {
                    "reorderIntervalDays": round(interval, 2),
                    "daysSinceLastOrder": days_since,
                    "overdueByDays": round(days_since - interval, 2),
                    "overdueMultiplier": OVERDUE_MULTIPLIER,
                    "orderCount": len(records),
                    "gapCoefficientOfVariation": round(cv, 3),
                    "typicalOrderQty": typical_qty,
                    "lastOrderDate": last_order_date.isoformat(),
                },
                "anomalyScore": 0.0,
                "forecastNextWeek": 0.0,
                "valueAtRiskRm": value_at_risk,
                "lastObservedWeekStart": observed_week,
                "occurrenceCount": 1,
                "ageDays": 0,
                "questions": list(questions),
                "recommendation": recommendation,
                "reason": reason,
                "sourceRunId": run_id,
                "isDemo": is_demo_record(meta),
            }
        )
    return insights

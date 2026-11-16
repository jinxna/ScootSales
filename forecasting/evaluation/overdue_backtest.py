from __future__ import annotations

import statistics
from dataclasses import dataclass
from datetime import date
from typing import Any, Iterable, Mapping

from forecasting.ai_core import completed_week_starts
from forecasting.ai_service.order_lines import authoritative_order_items
from forecasting.ai_service.overdue_reorder import (
    INSIGHT_TYPE,
    MIN_ORDERS_IN_WINDOW,
    detect_overdue_reorders,
)
from forecasting.ai_service.replenishment import (
    EXCLUDED_ORDER_STATUSES,
    _as_local_date,
    _first_number,
    _first_text,
    _text,
)

from .metrics import ClassificationMetrics, classification_from_sets

Pair = tuple[str, str]


def _pair_dates(orders: Iterable[Mapping[str, Any]]) -> dict[Pair, list[date]]:
    by_pair: dict[Pair, set[date]] = {}
    for raw_order in orders:
        order = dict(raw_order)
        if _text(order.get("status")).lower() in EXCLUDED_ORDER_STATUSES:
            continue
        order_date = _as_local_date(
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if order_date is None:
            continue
        retailer_id = _first_text(
            order, ("retailerId", "retailer_id", "retailerCode")
        )
        if not retailer_id:
            continue
        items = authoritative_order_items(order)
        for raw_item in items:
            if not isinstance(raw_item, Mapping):
                continue
            product_id = _first_text(
                raw_item, ("productId", "itemId", "productCode", "sku")
            )
            if not product_id:
                continue
            qty = _first_number(raw_item, ("qty", "quantity", "orderQty", "boxes"))
            if qty <= 0:
                continue
            by_pair.setdefault((retailer_id, product_id), set()).add(order_date)
    return {
        pair: sorted(dates) for pair, dates in by_pair.items()
    }


def _demo_index(
    patterns: Iterable[Mapping[str, Any]],
) -> dict[Pair, bool]:
    index: dict[Pair, bool] = {}
    for row in patterns:
        retailer_id = _first_text(row, ("retailerId", "retailer_id"))
        product_id = _first_text(row, ("productId", "product_id"))
        if retailer_id and product_id:
            index[(retailer_id, product_id)] = bool(row.get("isDemo"))
    return index


@dataclass
class OverdueCohortReport:
    cohort: str
    eligible_population: int
    ground_truth_positives: int
    detector_fired: int
    baseline_fired: int
    detector: ClassificationMetrics
    baseline: ClassificationMetrics
    tiny_population: bool
    note: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "cohort": self.cohort,
            "eligiblePopulation": self.eligible_population,
            "groundTruthPositives": self.ground_truth_positives,
            "detectorFired": self.detector_fired,
            "baselineFired": self.baseline_fired,
            "detector": self.detector.to_dict(),
            "baseline": self.baseline.to_dict(),
            "tinyPopulation": self.tiny_population,
            "note": self.note,
        }


def _learn_cadence(dates: list[date], window_start: date, window_end: date):
    in_window = [d for d in dates if window_start <= d < window_end]
    if len(in_window) < MIN_ORDERS_IN_WINDOW:
        return None
    gaps = [
        (in_window[i + 1] - in_window[i]).days
        for i in range(len(in_window) - 1)
    ]
    if not gaps:
        return None
    interval = statistics.median(gaps)
    if interval <= 0:
        return None
    return interval


def run_overdue_backtest(
    orders: Iterable[Mapping[str, Any]],
    patterns: Iterable[Mapping[str, Any]],
    memory: Iterable[Mapping[str, Any]],
    unit_prices: Mapping[str, float],
    *,
    cutoff: date,
    post_window_end: date,
    run_id: str = "overdue-backtest",
    tiny_population_threshold: int = 10,
) -> dict[str, OverdueCohortReport]:
    if post_window_end <= cutoff:
        raise ValueError("post_window_end must be after cutoff")

    orders = list(orders)
    patterns = list(patterns)
    memory = list(memory)

    week_starts = completed_week_starts(cutoff, weeks=8)
    window_start = week_starts[0]
    window_end = week_starts[-1] + (week_starts[1] - week_starts[0])

    pair_dates = _pair_dates(orders)
    demo_index = _demo_index(patterns)

    fired_insights = detect_overdue_reorders(
        orders, patterns, memory, unit_prices, as_of=cutoff, run_id=run_id
    )
    detector_fired: set[Pair] = {
        (insight["retailerId"], insight["productId"])
        for insight in fired_insights
        if insight.get("type") == INSIGHT_TYPE
    }

    cohorts: dict[str, dict[str, set[Pair]]] = {
        "demo": {"eligible": set(), "truth": set(), "baseline": set()},
        "nonDemo": {"eligible": set(), "truth": set(), "baseline": set()},
    }

    for pair, dates in pair_dates.items():
        interval = _learn_cadence(dates, window_start, window_end)
        if interval is None:
            continue
        cohort = "demo" if demo_index.get(pair) else "nonDemo"
        bucket = cohorts[cohort]
        bucket["eligible"].add(pair)

        prior = [d for d in dates if d <= cutoff]
        if not prior:
            continue
        last_prior = max(prior)
        future = [d for d in dates if d > cutoff]

        if future:
            silence_gap = (min(future) - cutoff).days
            went_silent = silence_gap > interval
        else:
            went_silent = (post_window_end - cutoff).days >= interval
        if went_silent:
            bucket["truth"].add(pair)

        days_since = (cutoff - last_prior).days
        if days_since > interval:
            bucket["baseline"].add(pair)

    reports: dict[str, OverdueCohortReport] = {}
    for cohort, bucket in cohorts.items():
        eligible = bucket["eligible"]
        truth = bucket["truth"]
        detector_positive = {p for p in detector_fired if p in eligible}
        baseline_positive = {p for p in bucket["baseline"] if p in eligible}
        detector_metrics = classification_from_sets(detector_positive, truth)
        baseline_metrics = classification_from_sets(baseline_positive, truth)
        tiny = len(eligible) < tiny_population_threshold
        note = (
            "Eligible population is small; treat precision/recall as indicative, "
            "not conclusive."
            if tiny
            else "Eligible population is adequate for an indicative read."
        )
        reports[cohort] = OverdueCohortReport(
            cohort=cohort,
            eligible_population=len(eligible),
            ground_truth_positives=len(truth),
            detector_fired=len(detector_positive),
            baseline_fired=len(baseline_positive),
            detector=detector_metrics,
            baseline=baseline_metrics,
            tiny_population=tiny,
            note=note,
        )
    return reports

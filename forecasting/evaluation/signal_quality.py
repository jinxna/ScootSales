from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from typing import Any, Iterable, Mapping, Sequence

from forecasting.ai_core.calendar import as_kuching_date
from forecasting.ai_service.order_lines import authoritative_order_items
from forecasting.ai_service.overdue_reorder import detect_overdue_reorders
from forecasting.ai_service.replenishment import (
    EXCLUDED_ORDER_STATUSES,
    derive_replenishment,
)

from .metrics import ClassificationMetrics, classification_metrics
from .ranking_metrics import (
    CalibrationReport,
    LeadTimeReport,
    average_precision,
    calibration_report,
    lead_time_report,
    precision_at_k,
    recall_at_k,
)

BRIEF_FOCUS_LIMIT = 3


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _first_text(row: Mapping[str, Any], fields: Sequence[str]) -> str:
    for field in fields:
        value = _text(row.get(field))
        if value:
            return value
    return ""


def _number(value: Any) -> float:
    if isinstance(value, bool) or value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).replace(",", "").replace("RM", "").strip())
    except ValueError:
        return 0.0


def _as_date(value: Any) -> date | None:
    if isinstance(value, datetime):
        return as_kuching_date(value)
    if isinstance(value, date):
        return value
    if value is None:
        return None
    try:
        return as_kuching_date(
            datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        )
    except ValueError:
        return None


def _order_date(row: Mapping[str, Any]) -> date | None:
    return _as_date(
        row.get("submittedAt") or row.get("orderDate") or row.get("createdAt")
    )


def _retailer_id(row: Mapping[str, Any]) -> str:
    return _first_text(row, ("retailerId", "retailer_id", "retailerCode"))


@dataclass(frozen=True)
class ScoredSignal:
    signal_type: str
    retailer_id: str
    product_id: str
    priority: str
    confidence: float
    value_at_risk_rm: float
    hit: bool
    lead_time_days: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "type": self.signal_type,
            "retailerId": self.retailer_id,
            "productId": self.product_id,
            "priority": self.priority,
            "confidence": self.confidence,
            "valueAtRiskRm": self.value_at_risk_rm,
            "hit": self.hit,
            "leadTimeDays": self.lead_time_days,
        }


@dataclass
class SignalFamilyReport:
    family: str
    cutoff: str
    truth_window_days: int
    eligible_pairs: int
    fired: int
    scored: list[ScoredSignal] = field(default_factory=list)
    classification: ClassificationMetrics | None = None
    precision_at_k3: float | None = None
    recall_at_k3: float | None = None
    average_precision: float | None = None
    calibration: CalibrationReport | None = None
    lead_time: LeadTimeReport | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "family": self.family,
            "cutoff": self.cutoff,
            "truthWindowDays": self.truth_window_days,
            "eligiblePairs": self.eligible_pairs,
            "fired": self.fired,
            "classification": (
                self.classification.to_dict() if self.classification else None
            ),
            "precisionAtK": self.precision_at_k3,
            "recallAtK": self.recall_at_k3,
            "averagePrecision": self.average_precision,
            "calibration": (
                self.calibration.to_dict() if self.calibration else None
            ),
            "leadTime": self.lead_time.to_dict() if self.lead_time else None,
            "signals": [row.to_dict() for row in self.scored],
        }


def _single_product_order_dates(order: Mapping[str, Any]) -> list[str]:
    product_ids: list[str] = []
    for raw_item in authoritative_order_items(order):
        if not isinstance(raw_item, Mapping):
            continue
        product_id = _first_text(
            raw_item, ("productId", "itemId", "productCode", "sku")
        )
        if not product_id:
            continue
        quantity = _number(
            raw_item.get("qty")
            or raw_item.get("quantity")
            or raw_item.get("orderQty")
            or raw_item.get("boxes")
        )
        if quantity > 0:
            product_ids.append(product_id)
    return product_ids


def _truth_index(
    orders: Iterable[Mapping[str, Any]],
    *,
    window_start: date,
    window_end: date,
) -> dict[tuple[str, str], list[date]]:
    truth: dict[tuple[str, str], list[date]] = {}
    for raw in orders:
        order = dict(raw)
        if _text(order.get("status")).lower() in EXCLUDED_ORDER_STATUSES:
            continue
        order_date = _order_date(order)
        if order_date is None or not (window_start <= order_date < window_end):
            continue
        retailer_id = _retailer_id(order)
        if not retailer_id:
            continue
        for product_id in set(_single_product_order_dates(order)):
            truth.setdefault((retailer_id, product_id), []).append(order_date)
    for dates in truth.values():
        dates.sort()
    return truth


def _eligible_pairs(
    orders: Iterable[Mapping[str, Any]], *, before: date
) -> set[tuple[str, str]]:
    pairs: set[tuple[str, str]] = set()
    for raw in orders:
        order = dict(raw)
        if _text(order.get("status")).lower() in EXCLUDED_ORDER_STATUSES:
            continue
        order_date = _order_date(order)
        if order_date is None or order_date >= before:
            continue
        retailer_id = _retailer_id(order)
        if not retailer_id:
            continue
        for product_id in _single_product_order_dates(order):
            pairs.add((retailer_id, product_id))
    return pairs


def _orders_before(
    orders: Sequence[Mapping[str, Any]], *, cutoff: date
) -> list[dict[str, Any]]:
    return [
        dict(order)
        for order in orders
        if (_order_date(dict(order)) or date.max) < cutoff
    ]


def _confidence_of(row: Mapping[str, Any]) -> float:
    score = _number(row.get("confidenceScore"))
    if score > 0:
        return min(1.0, score)
    label = _text(row.get("confidence")).lower()
    if label == "high":
        return 0.85
    if label == "medium":
        return 0.6
    if label == "low":
        return 0.3
    return 0.0


def _rank_and_score(
    signals: Sequence[Mapping[str, Any]],
    *,
    truth: Mapping[tuple[str, str], list[date]],
    cutoff: date,
    family: str,
) -> list[ScoredSignal]:
    priority_order = {"high": 0, "medium": 1, "low": 2}
    grouped: dict[str, list[Mapping[str, Any]]] = {}
    for signal in signals:
        retailer_id = _text(signal.get("retailerId"))
        if retailer_id:
            grouped.setdefault(retailer_id, []).append(signal)

    scored: list[ScoredSignal] = []
    for retailer_id, rows in sorted(grouped.items()):
        ranked = sorted(
            rows,
            key=lambda row: (
                priority_order.get(_text(row.get("priority")), 3),
                -_number(row.get("valueAtRiskRm")),
                _text(row.get("issueId") or row.get("productId")),
            ),
        )
        for row in ranked[:BRIEF_FOCUS_LIMIT]:
            product_id = _text(row.get("productId"))
            dates = truth.get((retailer_id, product_id), [])
            first = dates[0] if dates else None
            scored.append(
                ScoredSignal(
                    signal_type=family,
                    retailer_id=retailer_id,
                    product_id=product_id,
                    priority=_text(row.get("priority")) or "medium",
                    confidence=_confidence_of(row),
                    value_at_risk_rm=_number(row.get("valueAtRiskRm")),
                    hit=first is not None,
                    lead_time_days=(
                        None if first is None else float((first - cutoff).days)
                    ),
                )
            )
    return scored


def evaluate_signal_family(
    candidate_signals: Sequence[Mapping[str, Any]],
    *,
    truth: Mapping[tuple[str, str], list[date]],
    eligible_pairs: set[tuple[str, str]],
    cutoff: date,
    truth_window_days: int,
    family: str,
) -> SignalFamilyReport:
    top_signals = _rank_and_score(
        candidate_signals, truth=truth, cutoff=cutoff, family=family
    )
    fired_pairs = {
        (_text(row.get("retailerId")), _text(row.get("productId")))
        for row in candidate_signals
        if _text(row.get("retailerId")) and _text(row.get("productId"))
    }
    truth_pairs = set(truth)
    true_positives = len({pair for pair in fired_pairs if pair in truth_pairs})
    false_positives = len(fired_pairs) - true_positives
    false_negatives = len({pair for pair in truth_pairs if pair not in fired_pairs})
    classification = classification_metrics(
        true_positives, false_positives, false_negatives
    )
    labels: list[bool] = []
    confidences: list[float] = []
    leads: list[float] = []
    for row in top_signals:
        labels.append(row.hit)
        confidences.append(row.confidence)
        if row.lead_time_days is not None:
            leads.append(row.lead_time_days)
    return SignalFamilyReport(
        family=family,
        cutoff=cutoff.isoformat(),
        truth_window_days=truth_window_days,
        eligible_pairs=len(eligible_pairs),
        fired=len(candidate_signals),
        scored=top_signals,
        classification=classification,
        precision_at_k3=precision_at_k(labels, BRIEF_FOCUS_LIMIT),
        recall_at_k3=recall_at_k(labels, BRIEF_FOCUS_LIMIT),
        average_precision=average_precision(labels),
        calibration=calibration_report(confidences, labels),
        lead_time=lead_time_report(leads),
    )


def evaluate_signals_at_cutoff(
    *,
    orders: Sequence[Mapping[str, Any]],
    patterns: Sequence[Mapping[str, Any]],
    memory: Sequence[Mapping[str, Any]],
    unit_prices: Mapping[str, float],
    cutoff: date,
    truth_window_days: int = 28,
    run_id: str = "eval",
) -> dict[str, Any]:
    if truth_window_days <= 0:
        raise ValueError("truth_window_days must be positive")
    seen = _orders_before(orders, cutoff=cutoff)
    truth = _truth_index(
        orders,
        window_start=cutoff,
        window_end=cutoff + timedelta(days=truth_window_days),
    )
    eligible = _eligible_pairs(orders, before=cutoff)

    overdue = detect_overdue_reorders(
        seen,
        patterns,
        memory,
        unit_prices,
        as_of=cutoff,
        run_id=run_id,
        generated_at=datetime.combine(cutoff, time.min),
    )
    replenishment = derive_replenishment(
        seen,
        patterns,
        memory,
        [],
        today=cutoff,
    )
    return {
        "cutoff": cutoff.isoformat(),
        "truthWindowDays": truth_window_days,
        "ordersSeenBeforeCutoff": len(seen),
        "eligiblePairs": len(eligible),
        "truthPairs": len(truth),
        "families": {
            "overdueReorder": evaluate_signal_family(
                overdue,
                truth=truth,
                eligible_pairs=eligible,
                cutoff=cutoff,
                truth_window_days=truth_window_days,
                family="overdue_reorder",
            ).to_dict(),
            "replenishment": evaluate_signal_family(
                replenishment,
                truth=truth,
                eligible_pairs=eligible,
                cutoff=cutoff,
                truth_window_days=truth_window_days,
                family="replenishment_opportunity",
            ).to_dict(),
        },
    }


__all__ = [
    "BRIEF_FOCUS_LIMIT",
    "ScoredSignal",
    "SignalFamilyReport",
    "evaluate_signal_family",
    "evaluate_signals_at_cutoff",
]

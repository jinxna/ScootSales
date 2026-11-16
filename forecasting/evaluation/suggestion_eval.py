from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from typing import Any, Iterable, Mapping

from forecasting.ai_service.order_lines import authoritative_order_items

from forecasting.ai_service.replenishment import (
    EXCLUDED_ORDER_STATUSES,
    _as_local_date,
    _first_number,
    _first_text,
    _suppressed_pairs,
    _text,
)

EXACT = "exact"
WITHIN_ONE = "within_one"
DIRECTIONAL = "directional"
NOT_ORDERED = "not_ordered"
ACCEPTANCE_CLASSES = (EXACT, WITHIN_ONE, DIRECTIONAL, NOT_ORDERED)


def extract_suggestions_from_briefs(
    briefs: Iterable[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    suggestions: list[dict[str, Any]] = []
    for brief in briefs:
        retailer_id = _text(brief.get("retailerId"))
        if not retailer_id:
            continue
        is_demo = bool(brief.get("isDemo"))
        rows = brief.get("replenishment")
        if not isinstance(rows, (list, tuple)):
            continue
        for row in rows:
            if not isinstance(row, Mapping):
                continue
            product_id = _text(row.get("productId"))
            if not product_id:
                continue
            suggestions.append(
                {
                    "retailerId": retailer_id,
                    "productId": product_id,
                    "suggestedQty": _first_number(row, ("suggestedQty",)),
                    "confidence": row.get("confidence"),
                    "confidenceLabel": row.get("confidenceLabel"),
                    "isDemo": is_demo,
                }
            )
    return suggestions


def _ordered_qty_index(
    orders: Iterable[Mapping[str, Any]],
    *,
    on_or_after: date | None,
) -> dict[tuple[str, str], float]:
    earliest: dict[tuple[str, str], date] = {}
    quantity: dict[tuple[str, str], float] = {}
    for position, raw_order in enumerate(orders):
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
        if on_or_after is not None and order_date < on_or_after:
            continue
        retailer_id = _first_text(
            order, ("retailerId", "retailer_id", "retailerCode")
        )
        if not retailer_id:
            continue
        items = authoritative_order_items(order)
        per_product: dict[str, float] = {}
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
            per_product[product_id] = per_product.get(product_id, 0.0) + qty
        for product_id, qty in per_product.items():
            key = (retailer_id, product_id)
            if key not in earliest or order_date < earliest[key]:
                earliest[key] = order_date
                quantity[key] = qty
    return quantity


def classify_acceptance(suggested_qty: float, ordered_qty: float | None) -> str:
    if ordered_qty is None:
        return NOT_ORDERED
    diff = abs(ordered_qty - suggested_qty)
    if diff == 0:
        return EXACT
    if diff <= 1:
        return WITHIN_ONE
    return DIRECTIONAL


@dataclass
class AcceptanceReport:
    cohort: str
    counts: dict[str, int]
    total: int

    def rate(self, acceptance_class: str) -> float | None:
        if self.total == 0:
            return None
        return self.counts.get(acceptance_class, 0) / self.total

    def to_dict(self) -> dict[str, Any]:
        return {
            "cohort": self.cohort,
            "total": self.total,
            "counts": dict(self.counts),
            "rates": {
                cls: self.rate(cls) for cls in ACCEPTANCE_CLASSES
            },
        }


def evaluate_acceptance(
    suggestions: Iterable[Mapping[str, Any]],
    orders: Iterable[Mapping[str, Any]],
    *,
    on_or_after: date | None = None,
) -> dict[str, AcceptanceReport]:
    ordered = _ordered_qty_index(orders, on_or_after=on_or_after)
    reports = {
        "demo": AcceptanceReport(
            "demo", {cls: 0 for cls in ACCEPTANCE_CLASSES}, 0
        ),
        "nonDemo": AcceptanceReport(
            "nonDemo", {cls: 0 for cls in ACCEPTANCE_CLASSES}, 0
        ),
    }
    for suggestion in suggestions:
        retailer_id = _text(suggestion.get("retailerId"))
        product_id = _text(suggestion.get("productId"))
        if not retailer_id or not product_id:
            continue
        report = (
            reports["demo"]
            if bool(suggestion.get("isDemo"))
            else reports["nonDemo"]
        )
        ordered_qty = ordered.get((retailer_id, product_id))
        outcome = classify_acceptance(
            _first_number(suggestion, ("suggestedQty",)), ordered_qty
        )
        report.counts[outcome] += 1
        report.total += 1
    return reports


@dataclass
class SuppressionViolation:
    retailer_id: str
    product_id: str
    is_demo: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "retailerId": self.retailer_id,
            "productId": self.product_id,
            "isDemo": self.is_demo,
        }


@dataclass
class SuppressionReport:
    suppressed_pair_count: int
    suggestion_count: int
    violations: list[SuppressionViolation] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.violations

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "suppressedPairCount": self.suppressed_pair_count,
            "suggestionCount": self.suggestion_count,
            "violationCount": len(self.violations),
            "violations": [v.to_dict() for v in self.violations],
        }


def evaluate_suppression(
    suggestions: Iterable[Mapping[str, Any]],
    memory: Iterable[Mapping[str, Any]],
) -> SuppressionReport:
    suggestion_list = list(suggestions)
    suppressed = _suppressed_pairs(memory)
    violations: list[SuppressionViolation] = []
    seen: set[tuple[str, str]] = set()
    for suggestion in suggestion_list:
        key = (
            _text(suggestion.get("retailerId")),
            _text(suggestion.get("productId")),
        )
        if not key[0] or not key[1]:
            continue
        if key in suppressed and key not in seen:
            seen.add(key)
            violations.append(
                SuppressionViolation(
                    retailer_id=key[0],
                    product_id=key[1],
                    is_demo=bool(suggestion.get("isDemo")),
                )
            )
    violations.sort(key=lambda v: (v.retailer_id, v.product_id))
    return SuppressionReport(
        suppressed_pair_count=len(suppressed),
        suggestion_count=len(suggestion_list),
        violations=violations,
    )

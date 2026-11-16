from datetime import date, datetime, timezone

from forecasting.ai_service.replenishment import derive_replenishment


def _order(retailer_id, product_id, qty, order_date, *, order_id=None):
    return {
        "orderId": order_id or f"{retailer_id}-{product_id}-{order_date}",
        "retailerId": retailer_id,
        "submittedAt": order_date,
        "status": "submitted",
        "items": [{"productId": product_id, "qty": qty}],
    }


def _pattern(retailer_id, product_id, *, quantities, order_counts, trend="stable"):
    return {
        "retailerId": retailer_id,
        "productId": product_id,
        "weeklyQuantities": quantities,
        "weeklyOrderCounts": order_counts,
        "baselineAverage": sum(quantities) / len(quantities),
        "trend": trend,
    }


def _run_rate(retailer_id, product_id, rate):
    return {
        "retailerId": retailer_id,
        "productId": product_id,
        "runRatePerDay": rate,
    }


TODAY = date(2026, 7, 1)


def test_never_ordered_product_has_no_suggestion() -> None:
    suggestions = derive_replenishment(
        orders=[],
        item_patterns=[
            _pattern("R1", "P1", quantities=[10] * 8, order_counts=[1] * 8)
        ],
        memory=[],
        run_rates=[_run_rate("R1", "P1", 0.5)],
        today=TODAY,
    )
    assert suggestions == []


def test_stopped_or_rejected_product_is_suppressed() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 11)),
        _order("R1", "P1", 10, date(2026, 5, 21)),
    ]
    memory = [
        {
            "retailerId": "R1",
            "lastConfirmedIssues": [
                {
                    "issueKey": "stopped_product::R1::P1",
                    "reasonCode": "switched_to_alternative",
                }
            ],
        }
    ]
    suggestions = derive_replenishment(
        orders=orders,
        item_patterns=[
            _pattern("R1", "P1", quantities=[10] * 8, order_counts=[1] * 8)
        ],
        memory=memory,
        run_rates=[_run_rate("R1", "P1", 0.5)],
        today=TODAY,
    )
    assert suggestions == []


def test_regular_cadence_uses_documented_reconciliation() -> None:
    last_order = date(2026, 6, 11)
    orders = [
        _order("R1", "P1", 10, last_order),
        _order("R1", "P1", 10, date(2026, 5, 21)),
        _order("R1", "P1", 10, date(2026, 4, 30)),
    ]
    patterns = [
        _pattern(
            "R1",
            "P1",
            quantities=[10, 0, 0, 10, 0, 0, 10, 0],
            order_counts=[1, 0, 0, 1, 0, 0, 1, 0],
        )
    ]
    suggestions = derive_replenishment(
        orders=orders,
        item_patterns=patterns,
        memory=[],
        run_rates=[_run_rate("R1", "P1", 0.5)],
        today=TODAY,
    )
    assert len(suggestions) == 1
    suggestion = suggestions[0]
    assert suggestion["suggestedQty"] == 10
    assert suggestion["inputs"]["lastOrderDaysAgo"] == 20
    assert suggestion["inputs"]["runRatePerDay"] == 0.5


def test_zero_days_elapsed_yields_no_suggestion_and_positive_quantities() -> None:
    orders = [
        _order("R1", "P1", 10, TODAY),
        _order("R2", "P2", 8, date(2026, 6, 21)),
    ]
    suggestions = derive_replenishment(
        orders=orders,
        item_patterns=[
            _pattern("R2", "P2", quantities=[8] * 8, order_counts=[1] * 8)
        ],
        memory=[],
        run_rates=[_run_rate("R1", "P1", 0.5), _run_rate("R2", "P2", 0.4)],
        today=TODAY,
    )
    assert all(s["inputs"]["lastOrderDaysAgo"] > 0 for s in suggestions)
    assert not any(s["retailerId"] == "R1" for s in suggestions)
    assert all(s["suggestedQty"] >= 1 for s in suggestions)


def test_sparse_history_keeps_confidence_low() -> None:
    orders = [_order("R1", "P1", 12, date(2026, 6, 11))]
    suggestions = derive_replenishment(
        orders=orders,
        item_patterns=[
            _pattern("R1", "P1", quantities=[12, 0, 0, 0, 0, 0, 0, 0], order_counts=[1, 0, 0, 0, 0, 0, 0, 0])
        ],
        memory=[],
        run_rates=[_run_rate("R1", "P1", 0.5)],
        today=TODAY,
    )
    assert len(suggestions) == 1
    assert suggestions[0]["confidence"] < 0.4
    assert suggestions[0]["confidence"] > 0.0


def test_missing_run_rate_falls_back_to_pattern() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 11)),
        _order("R1", "P1", 10, date(2026, 5, 21)),
        _order("R1", "P1", 10, date(2026, 4, 30)),
    ]
    patterns = [
        _pattern(
            "R1",
            "P1",
            quantities=[10, 0, 0, 10, 0, 0, 10, 0],
            order_counts=[1, 0, 0, 1, 0, 0, 1, 0],
        )
    ]
    with_rate = derive_replenishment(
        orders=orders,
        item_patterns=patterns,
        memory=[],
        run_rates=[_run_rate("R1", "P1", 0.5)],
        today=TODAY,
    )
    without_rate = derive_replenishment(
        orders=orders,
        item_patterns=patterns,
        memory=[],
        run_rates=[],
        today=TODAY,
    )
    assert len(without_rate) == 1
    fallback = without_rate[0]
    assert fallback["suggestedQty"] == 10
    assert fallback["inputs"]["runRatePerDay"] is None
    assert "No run-rate available" in fallback["rationale"]
    assert fallback["confidence"] < with_rate[0]["confidence"]


def test_confidence_bounded_and_rationale_has_numbers() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 11)),
        _order("R1", "P1", 10, date(2026, 5, 21)),
        _order("R1", "P1", 10, date(2026, 4, 30)),
        _order("R1", "P1", 10, date(2026, 4, 9)),
    ]
    patterns = [
        _pattern(
            "R1",
            "P1",
            quantities=[10, 0, 10, 0, 10, 0, 10, 0],
            order_counts=[1, 0, 1, 0, 1, 0, 1, 0],
        )
    ]
    suggestions = derive_replenishment(
        orders=orders,
        item_patterns=patterns,
        memory=[],
        run_rates=[_run_rate("R1", "P1", 0.5)],
        today=TODAY,
    )
    assert len(suggestions) == 1
    suggestion = suggestions[0]
    assert 0.0 <= suggestion["confidence"] <= 1.0
    assert "20 days ago" in suggestion["rationale"]
    assert "0.5/day" in suggestion["rationale"]


def test_output_is_deterministic_and_sorted() -> None:
    orders = [
        _order("R2", "P9", 5, date(2026, 6, 11)),
        _order("R1", "P3", 7, date(2026, 6, 11)),
        _order("R1", "P1", 9, date(2026, 6, 11)),
    ]
    patterns = [
        _pattern("R2", "P9", quantities=[5] * 8, order_counts=[1] * 8),
        _pattern("R1", "P3", quantities=[7] * 8, order_counts=[1] * 8),
        _pattern("R1", "P1", quantities=[9] * 8, order_counts=[1] * 8),
    ]
    run_rates = [
        _run_rate("R2", "P9", 0.2),
        _run_rate("R1", "P3", 0.3),
        _run_rate("R1", "P1", 0.4),
    ]
    first = derive_replenishment(orders, patterns, [], run_rates, TODAY)
    second = derive_replenishment(orders, patterns, [], run_rates, TODAY)
    assert first == second
    keys = [(s["retailerId"], s["productId"]) for s in first]
    assert keys == sorted(keys)
    assert keys == [("R1", "P1"), ("R1", "P3"), ("R2", "P9")]


def test_elapsed_days_count_from_the_kuching_order_date() -> None:
    class _Timestamp:
        def to_datetime(self):
            return datetime(2026, 6, 28, 18, tzinfo=timezone.utc)

    orders = [
        _order("R1", "P1", 5, "2026-06-28T18:00:00Z"),
        _order("R2", "P1", 5, _Timestamp()),
        _order("R3", "P1", 5, "2026-06-29T09:00:00"),
    ]
    suggestions = derive_replenishment(orders, [], [], [], TODAY)
    days = {row["retailerId"]: row["inputs"]["lastOrderDaysAgo"] for row in suggestions}
    assert days == {"R1": 2, "R2": 2, "R3": 2}

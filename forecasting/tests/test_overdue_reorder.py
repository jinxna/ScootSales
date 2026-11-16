from datetime import date, datetime, timezone

from forecasting.ai_core import issue_id, issue_key, merge_insight
from forecasting.ai_service.overdue_reorder import detect_overdue_reorders


TODAY = date(2026, 7, 1)
GENERATED_AT = datetime(2026, 7, 1, tzinfo=timezone.utc)
PRICES = {"P1": 20.0, "P2": 15.0}

PRESERVED_FIELDS = {
    "status": "acknowledged",
    "acknowledgedBy": "admin-1",
    "acknowledgedAt": "2026-06-12T09:00:00+08:00",
    "resolvedBy": "admin-2",
    "resolvedAt": "2026-06-13T09:00:00+08:00",
    "dismissedBy": "admin-3",
    "dismissedAt": "2026-06-13T10:00:00+08:00",
    "snoozedUntil": "2026-06-20",
    "suppressedBy": "system",
    "adminNotes": "Follow up during next visit.",
    "assignedToUid": "supervisor-1",
    "assignedRole": "supervisor",
    "dueDate": "2026-06-19",
    "statusHistory": [{"status": "acknowledged"}],
}


def _order(retailer_id, product_id, qty, order_date, *, order_id=None):
    return {
        "orderId": order_id or f"{retailer_id}-{product_id}-{order_date}",
        "retailerId": retailer_id,
        "submittedAt": order_date,
        "status": "submitted",
        "items": [{"productId": product_id, "qty": qty}],
    }


def _pattern(retailer_id, product_id, *, trend="stable", is_demo=False):
    return {
        "retailerId": retailer_id,
        "productId": product_id,
        "retailerName": "Demo Retailer",
        "productName": "Demo Product",
        "salesmanUid": "U001",
        "salesmanCode": "S001",
        "branchId": "B001",
        "trend": trend,
        "isDemo": is_demo,
    }


def _detect(orders, patterns=None, memory=None, prices=None):
    return detect_overdue_reorders(
        orders,
        patterns if patterns is not None else [_pattern("R1", "P1")],
        memory or [],
        PRICES if prices is None else prices,
        as_of=TODAY,
        run_id="run-test",
        generated_at=GENERATED_AT,
    )


def test_regular_cadence_overdue_fires_with_confidence_and_severity() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    insights = _detect(orders)
    assert len(insights) == 1
    insight = insights[0]
    assert insight["type"] == "overdue_reorder"
    assert insight["issueKey"] == "overdue_reorder::R1::P1"
    assert insight["issueId"] == issue_id("overdue_reorder", "R1", "P1")
    assert insight["latestEvidence"]["reorderIntervalDays"] == 14
    assert insight["latestEvidence"]["daysSinceLastOrder"] == 25
    assert insight["confidence"] == "high"
    assert insight["confidenceScore"] > 0.7
    assert insight["valueAtRiskRm"] == 200.0
    assert insight["priority"] == "high"


def test_legacy_demo_marker_is_preserved_on_overdue_insight() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    pattern = _pattern("R1", "P1")
    pattern.pop("isDemo")
    pattern["is_demo"] = "true"

    insights = _detect(orders, patterns=[pattern])

    assert insights[0]["isDemo"] is True


def test_irregular_cadence_abstains() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 29)),
        _order("R1", "P1", 10, date(2026, 6, 25)),
        _order("R1", "P1", 10, date(2026, 5, 31)),
        _order("R1", "P1", 10, date(2026, 5, 29)),
    ]
    assert _detect(orders) == []


def test_recent_order_within_interval_yields_no_insight() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 26)),
        _order("R1", "P1", 10, date(2026, 6, 12)),
        _order("R1", "P1", 10, date(2026, 5, 29)),
    ]
    assert _detect(orders) == []


def test_suppressing_reason_code_in_memory_blocks_overdue() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
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
    assert _detect(orders, memory=memory) == []


def test_stopped_pattern_trend_blocks_overdue() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    assert _detect(orders, patterns=[_pattern("R1", "P1", trend="stopped")]) == []


def test_fewer_than_three_orders_abstains() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
    ]
    assert _detect(orders) == []


def test_only_in_window_orders_count_at_the_eight_week_boundary() -> None:
    in_window = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    out_of_window = _order("R1", "P1", 10, date(2026, 4, 5))

    assert len(_detect(in_window)) == 1
    combined = _detect([*in_window, out_of_window])
    assert len(combined) == 1
    assert combined[0]["latestEvidence"]["orderCount"] == 3


def test_recent_order_in_current_partial_week_clears_the_pair() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 29)),
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    assert _detect(orders) == []


def test_partial_week_order_does_not_skew_learned_cadence_but_still_fires() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 29)),
        _order("R1", "P1", 10, date(2026, 5, 11)),
        _order("R1", "P1", 10, date(2026, 5, 10)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    insights = _detect(orders)
    assert len(insights) == 1
    evidence = insights[0]["latestEvidence"]
    assert evidence["reorderIntervalDays"] == 1
    assert evidence["orderCount"] == 3
    assert evidence["daysSinceLastOrder"] == 2
    assert evidence["lastOrderDate"] == "2026-06-29"


def test_upsert_is_idempotent_and_preserves_admin_fields() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    first = _detect(orders)[0]
    second = _detect(orders)[0]
    assert first["issueId"] == second["issueId"] == issue_id(
        "overdue_reorder", "R1", "P1"
    )

    existing = {
        "issueId": first["issueId"],
        "issueKey": issue_key("overdue_reorder", "R1", "P1"),
        "priority": "medium",
        "occurrenceCount": 2,
        "lastObservedWeekStart": "2026-06-15",
        **PRESERVED_FIELDS,
    }
    merged = merge_insight(existing, first)
    for field, value in PRESERVED_FIELDS.items():
        assert merged[field] == value
    assert merged["priority"] == first["priority"]
    assert merged["valueAtRiskRm"] == first["valueAtRiskRm"]
    assert merged["occurrenceCount"] == 3

    remerged = merge_insight(merged, second)
    assert remerged["occurrenceCount"] == 3


def test_labels_carry_the_cadence_numbers_and_never_say_stock() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 6)),
        _order("R1", "P1", 10, date(2026, 5, 23)),
        _order("R1", "P1", 10, date(2026, 5, 9)),
    ]
    insight = _detect(orders)[0]
    blob = " ".join(
        [insight["reason"], insight["recommendation"], *insight["questions"]]
    ).lower()
    assert "reorder" in blob
    assert "cadence" in blob
    assert "stock" not in blob
    assert "14" in blob
    assert "25" in blob


def test_output_is_deterministic_and_sorted() -> None:
    def three(retailer_id, product_id):
        return [
            _order(retailer_id, product_id, 10, date(2026, 6, 6)),
            _order(retailer_id, product_id, 10, date(2026, 5, 23)),
            _order(retailer_id, product_id, 10, date(2026, 5, 9)),
        ]

    orders = [*three("R2", "P2"), *three("R1", "P1")]
    patterns = [_pattern("R2", "P2"), _pattern("R1", "P1")]
    first = detect_overdue_reorders(
        orders, patterns, [], PRICES,
        as_of=TODAY, run_id="run-test", generated_at=GENERATED_AT,
    )
    second = detect_overdue_reorders(
        orders, patterns, [], PRICES,
        as_of=TODAY, run_id="run-test", generated_at=GENERATED_AT,
    )
    assert first == second
    keys = [(row["retailerId"], row["productId"]) for row in first]
    assert keys == sorted(keys)
    assert keys == [("R1", "P1"), ("R2", "P2")]


def test_cadence_and_recency_use_kuching_order_dates() -> None:
    orders = [
        _order("R1", "P1", 10, "2026-05-24T18:00:00Z"),
        _order("R1", "P1", 10, "2026-05-31T18:00:00Z"),
        _order("R1", "P1", 10, "2026-06-07T18:00:00Z"),
    ]
    insights = _detect(orders)
    assert len(insights) == 1
    evidence = insights[0]["latestEvidence"]
    assert evidence["lastOrderDate"] == "2026-06-08"
    assert evidence["daysSinceLastOrder"] == 23


def test_a_timestamp_as_of_resolves_to_the_kuching_day() -> None:
    orders = [
        _order("R1", "P1", 10, date(2026, 5, 25)),
        _order("R1", "P1", 10, date(2026, 6, 1)),
        _order("R1", "P1", 10, date(2026, 6, 8)),
    ]
    by_timestamp = detect_overdue_reorders(
        orders,
        [_pattern("R1", "P1")],
        [],
        PRICES,
        as_of=datetime(2026, 6, 30, 18, tzinfo=timezone.utc),
        run_id="run-test",
        generated_at=GENERATED_AT,
    )
    assert by_timestamp == _detect(orders)

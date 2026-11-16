from datetime import date

from forecasting.evaluation.suggestion_eval import (
    classify_acceptance,
    evaluate_acceptance,
    evaluate_suppression,
    extract_suggestions_from_briefs,
)


def _brief(retailer_id, suggestions, *, is_demo=False):
    return {
        "retailerId": retailer_id,
        "isDemo": is_demo,
        "replenishment": [
            {"productId": pid, "suggestedQty": qty, "confidenceLabel": "medium"}
            for pid, qty in suggestions
        ],
    }


def _order(retailer_id, product_id, qty, order_date):
    return {
        "orderId": f"{retailer_id}-{product_id}-{order_date}",
        "retailerId": retailer_id,
        "submittedAt": order_date,
        "status": "submitted",
        "items": [{"productId": product_id, "qty": qty}],
    }


def _memory_stopped(retailer_id, product_id, reason="switched_to_alternative"):
    return {
        "retailerId": retailer_id,
        "lastConfirmedIssues": [
            {
                "issueKey": f"stopped_product::{retailer_id}::{product_id}",
                "reasonCode": reason,
            }
        ],
    }


def test_classify_acceptance_boundaries() -> None:
    assert classify_acceptance(10, 10) == "exact"
    assert classify_acceptance(10, 11) == "within_one"
    assert classify_acceptance(10, 9) == "within_one"
    assert classify_acceptance(10, 12) == "directional"
    assert classify_acceptance(10, 1) == "directional"
    assert classify_acceptance(10, None) == "not_ordered"


def test_extract_and_evaluate_acceptance_distribution() -> None:
    briefs = [
        _brief("R1", [("P1", 10), ("P2", 10), ("P3", 10), ("P4", 10)]),
    ]
    suggestions = extract_suggestions_from_briefs(briefs)
    assert len(suggestions) == 4
    orders = [
        _order("R1", "P1", 10, date(2026, 6, 2)),
        _order("R1", "P2", 11, date(2026, 6, 2)),
        _order("R1", "P3", 15, date(2026, 6, 2)),
    ]
    reports = evaluate_acceptance(suggestions, orders)
    non_demo = reports["nonDemo"]
    assert non_demo.total == 4
    assert non_demo.counts == {
        "exact": 1,
        "within_one": 1,
        "directional": 1,
        "not_ordered": 1,
    }
    assert non_demo.rate("exact") == 0.25


def test_acceptance_on_or_after_excludes_pre_suggestion_orders() -> None:
    suggestions = extract_suggestions_from_briefs([_brief("R1", [("P1", 5)])])
    orders = [_order("R1", "P1", 5, date(2026, 5, 1))]
    reports = evaluate_acceptance(
        suggestions, orders, on_or_after=date(2026, 6, 1)
    )
    assert reports["nonDemo"].counts["not_ordered"] == 1
    assert reports["nonDemo"].counts["exact"] == 0


def test_demo_and_non_demo_acceptance_are_separate() -> None:
    suggestions = extract_suggestions_from_briefs(
        [
            _brief("R1", [("P1", 5)], is_demo=True),
            _brief("R2", [("P1", 5)], is_demo=False),
        ]
    )
    orders = [
        _order("R1", "P1", 5, date(2026, 6, 2)),
        _order("R2", "P1", 5, date(2026, 6, 2)),
    ]
    reports = evaluate_acceptance(suggestions, orders)
    assert reports["demo"].counts["exact"] == 1
    assert reports["nonDemo"].counts["exact"] == 1
    assert reports["demo"].total == 1
    assert reports["nonDemo"].total == 1


def test_suppression_violation_detected() -> None:
    suggestions = [
        {"retailerId": "R1", "productId": "P1"},
        {"retailerId": "R1", "productId": "P2"},
    ]
    memory = [_memory_stopped("R1", "P1")]
    report = evaluate_suppression(suggestions, memory)
    assert report.ok is False
    assert len(report.violations) == 1
    assert report.violations[0].retailer_id == "R1"
    assert report.violations[0].product_id == "P1"


def test_suppression_clean_when_no_suppressed_pair_suggested() -> None:
    suggestions = [{"retailerId": "R1", "productId": "P2"}]
    memory = [_memory_stopped("R1", "P1")]
    report = evaluate_suppression(suggestions, memory)
    assert report.ok is True
    assert report.suppressed_pair_count == 1
    assert report.violations == []


def test_suppression_empty_inputs_are_ok() -> None:
    report = evaluate_suppression([], [])
    assert report.ok is True
    assert report.to_dict()["violationCount"] == 0

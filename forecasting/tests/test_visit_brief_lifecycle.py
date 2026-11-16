from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from forecasting.ai_service.outcome_feedback import (
    SUPPRESSION_WINDOW_DAYS,
    apply_outcome_feedback,
    suppression_expires_at,
    suppression_window_days,
)
from forecasting.ai_service.visit_briefs import (
    FOCUS_LIMIT,
    NO_FOCUS_BODY,
    NO_FOCUS_HEADLINE,
    build_visit_briefs,
)

AS_OF = date(2026, 6, 15)
GENERATED_AT = datetime(2026, 6, 15, tzinfo=timezone.utc)


def _insight(
    *,
    retailer_id: str = "R001",
    product_id: str = "P1",
    issue_type: str = "stopped_product",
    priority: str = "high",
    value_at_risk_rm: float = 50.0,
    **extra: object,
) -> dict:
    insight = {
        "issueId": f"issue-{retailer_id}-{product_id}",
        "issueKey": f"{issue_type}::{retailer_id}::{product_id}",
        "type": issue_type,
        "retailerId": retailer_id,
        "retailerName": "Retailer One",
        "salesmanUid": "U001",
        "salesmanCode": "S001",
        "branchId": "B001",
        "productId": product_id,
        "productName": "Product " + product_id,
        "priority": priority,
        "confidence": "medium",
        "confidenceScore": 0.6,
        "reason": "No order for this product in 6 weeks",
        "recommendation": "Ask whether the product is still stocked",
        "questions": ["Is it still on the shelf?"],
        "valueAtRiskRm": value_at_risk_rm,
    }
    insight.update(extra)
    return insight


def _brief(insights: list[dict], **kwargs: object) -> dict:
    briefs = build_visit_briefs(
        insights,
        as_of=AS_OF,
        run_id="run-test",
        generated_at=GENERATED_AT,
        **kwargs,
    )
    assert len(briefs) == 1
    return briefs[0]


def test_suppression_window_is_stated_per_reason_code() -> None:
    assert suppression_window_days("switched_to_alternative") == 42
    assert suppression_window_days("seasonal_change") == 84
    assert suppression_window_days("packaging_change") == 42
    assert suppression_window_days("ordered") is None
    assert suppression_window_days("not_interested") is None


def test_suppression_expiry_is_the_submit_time_plus_the_window() -> None:
    submitted = datetime(2026, 5, 1, tzinfo=timezone.utc)
    assert suppression_expires_at("switched_to_alternative", submitted) == (
        submitted + timedelta(days=42)
    )
    assert suppression_expires_at("ordered", submitted) is None


def _outcome(reason_code: str, submitted_at: datetime) -> dict:
    return {
        "outcomeId": "outcome-1",
        "issueKey": "stopped_product::R001::P1",
        "retailerId": "R001",
        "salesmanUid": "U001",
        "reasonCode": reason_code,
        "submittedAt": submitted_at,
    }


def test_suppression_holds_the_day_before_expiry_and_releases_on_the_day() -> None:
    submitted = datetime(2026, 5, 1, tzinfo=timezone.utc)
    insight = _insight()
    from forecasting.ai_service.outcome_feedback import normalize_outcomes

    outcomes = normalize_outcomes([_outcome("switched_to_alternative", submitted)])

    day_41 = apply_outcome_feedback(
        [insight], outcomes, evaluated_at=submitted + timedelta(days=41)
    )[0]
    assert day_41["autoState"] == "suppressed"
    assert day_41["autoSuppressionExpiresAt"] == submitted + timedelta(days=42)
    assert "autoSuppressionExpiredAt" not in day_41

    day_42 = apply_outcome_feedback(
        [insight], outcomes, evaluated_at=submitted + timedelta(days=42)
    )[0]
    assert day_42["autoState"] == "follow_up"
    assert day_42["autoSuppressionExpiredAt"] == submitted + timedelta(days=42)
    assert day_42["latestOutcome"]["reasonCode"] == "switched_to_alternative"
    assert day_42["outcomeCount"] == 1


def test_a_returning_issue_reaches_the_brief_with_its_history() -> None:
    submitted = datetime(2026, 5, 1, tzinfo=timezone.utc)
    from forecasting.ai_service.outcome_feedback import normalize_outcomes

    released = apply_outcome_feedback(
        [_insight(occurrenceCount=2)],
        normalize_outcomes([_outcome("packaging_change", submitted)]),
        evaluated_at=submitted + timedelta(days=42),
    )[0]
    brief = _brief([released])
    assert brief["focusCount"] == 1
    item = brief["focusItems"][0]
    assert item["autoState"] == "follow_up"
    assert item["previousOutcome"]["reasonCode"] == "packaging_change"
    assert item["occurrenceCount"] == 2
    assert item["action"] == "Ask whether the product is still stocked"


def test_a_suppressed_issue_never_reaches_the_brief() -> None:
    submitted = datetime(2026, 6, 14, tzinfo=timezone.utc)
    from forecasting.ai_service.outcome_feedback import normalize_outcomes

    suppressed = apply_outcome_feedback(
        [_insight()],
        normalize_outcomes([_outcome("switched_to_alternative", submitted)]),
        evaluated_at=submitted + timedelta(days=1),
    )[0]
    brief = _brief(
        [suppressed],
        coverage_retailers=[{"retailerId": "R001", "salesmanUid": "U001"}],
    )
    assert brief["focusItems"] == []
    assert brief["hasFocus"] is False


def test_focus_items_are_capped_and_never_padded() -> None:
    insights = [
        _insight(product_id=f"P{index}", priority="medium")
        for index in range(5)
    ]
    brief = _brief(insights)
    assert brief["insightCount"] == 5
    assert brief["focusCount"] == FOCUS_LIMIT == 3
    assert len(brief["focusItems"]) == 3
    single = _brief([_insight()])
    assert single["focusCount"] == 1
    assert len(single["focusItems"]) == 1


def test_focus_item_order_is_stable_for_identical_input() -> None:
    insights = [
        _insight(product_id="P1", priority="low", value_at_risk_rm=1.0),
        _insight(product_id="P2", priority="high", value_at_risk_rm=10.0),
        _insight(product_id="P3", priority="high", value_at_risk_rm=90.0),
        _insight(product_id="P4", priority="medium", value_at_risk_rm=50.0),
    ]
    first = _brief(insights)
    second = _brief(list(reversed(insights)))
    assert [row["issueId"] for row in first["focusItems"]] == [
        row["issueId"] for row in second["focusItems"]
    ]
    assert [row["productId"] for row in first["focusItems"]] == ["P3", "P2", "P4"]


def test_every_focus_item_carries_a_recommended_action() -> None:
    brief = _brief([_insight(), _insight(product_id="P2")])
    for item in brief["focusItems"]:
        assert item["action"].strip()
        assert item["signal"].strip()
        assert item["priority"]


def test_issue_identity_is_type_plus_retailer_plus_product() -> None:
    brief = _brief([_insight(issue_type="overdue_reorder", product_id="P9")])
    assert brief["focusItems"][0]["issueKey"] == "overdue_reorder::R001::P9"
    assert brief["focusItems"][0]["issueId"] == brief["focusItems"][0]["issueId"]


def test_a_retailer_with_nothing_to_flag_gets_the_no_issue_brief() -> None:
    brief = _brief(
        [],
        coverage_retailers=[
            {
                "retailerId": "R009",
                "retailerName": "Quiet Retailer",
                "salesmanUid": "U001",
                "salesmanCode": "S001",
                "branchId": "B001",
            }
        ],
    )
    assert brief["retailerId"] == "R009"
    assert brief["retailerName"] == "Quiet Retailer"
    assert brief["status"] == "active"
    assert brief["focusItems"] == []
    assert brief["hasFocus"] is False
    assert brief["topInsights"] == []
    assert brief["emptyStateHeadline"] == NO_FOCUS_HEADLINE
    assert brief["emptyStateBody"] == NO_FOCUS_BODY


def test_a_retailer_with_focus_items_gets_no_empty_state_copy() -> None:
    brief = _brief([_insight()])
    assert brief["hasFocus"] is True
    assert brief["emptyStateHeadline"] == ""
    assert brief["emptyStateBody"] == ""


def test_coverage_retailers_do_not_add_a_second_brief_for_a_flagged_retailer() -> None:
    brief = _brief(
        [_insight()],
        coverage_retailers=[{"retailerId": "R001", "retailerName": "Retailer One"}],
    )
    assert brief["retailerId"] == "R001"
    assert brief["focusCount"] == 1


def test_a_demo_coverage_retailer_stays_in_the_demo_cohort() -> None:
    brief = _brief(
        [],
        coverage_retailers=[
            {"retailerId": "R-DEMO", "salesmanUid": "U001", "isDemo": True}
        ],
    )
    assert brief["isDemo"] is True


def test_the_suppression_window_map_is_the_documented_one() -> None:
    assert SUPPRESSION_WINDOW_DAYS == {
        "switched_to_alternative": 42,
        "seasonal_change": 84,
        "packaging_change": 42,
    }

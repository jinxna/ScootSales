from datetime import date, datetime, timedelta, timezone

import pytest

from forecasting.ai_core import (
    RetailerProductSeries,
    WeeklyObservation,
    build_insight,
    issue_id,
    merge_insight,
    summarize_insights,
)


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


def _series(quantities: list[float], *, price: float = 20) -> RetailerProductSeries:
    first = date(2026, 4, 20)
    observations = tuple(
        WeeklyObservation(
            week_start=first + timedelta(weeks=index),
            quantity=quantity,
            revenue_rm=quantity * price,
            order_count=1 if quantity else 0,
        )
        for index, quantity in enumerate(quantities)
    )
    return RetailerProductSeries(
        retailer_id="R001",
        product_id="P004",
        retailer_name="Demo Retailer",
        product_name="Demo Product",
        unit_price_rm=price,
        observations=observations,
        salesman_uid="salesman-1",
        salesman_code="S001",
        branch_id="B001",
    )


def test_stopped_product_has_stable_identity_and_value_at_risk() -> None:
    insight = build_insight(
        _series([8, 9, 10, 9, 8, 7, 0, 0]),
        as_of=date(2026, 6, 15),
    )
    assert insight is not None
    assert insight.type == "stopped_product"
    assert insight.issue_key == "stopped_product::R001::P004"
    assert insight.issue_id == issue_id("stopped_product", "R001", "P004")
    assert insight.value_at_risk_rm == pytest.approx(170.0)
    assert insight.priority == "high"


def test_issue_id_does_not_change_with_observation_week() -> None:
    first = build_insight(
        _series([8, 9, 10, 9, 8, 7, 0, 0]),
        as_of=date(2026, 6, 15),
    )
    second = build_insight(
        _series([9, 10, 9, 8, 7, 6, 0, 0]),
        as_of=date(2026, 6, 22),
    )
    assert first is not None and second is not None
    assert first.issue_id == second.issue_id
    assert first.issue_key == second.issue_key


def test_sparse_evidence_is_confidence_gated() -> None:
    insight = build_insight(
        _series([1, 0, 0, 0, 1, 0, 0, 0]),
        as_of=date(2026, 6, 15),
    )
    assert insight is None


def test_merge_upsert_preserves_every_human_admin_field() -> None:
    existing = {
        "issueId": "stopped_product_123",
        "issueKey": "stopped_product::R001::P004",
        "priority": "medium",
        "occurrenceCount": 3,
        "lastObservedWeekStart": "2026-06-01",
        **PRESERVED_FIELDS,
    }
    computed = {
        "issueId": "stopped_product_123",
        "issueKey": "stopped_product::R001::P004",
        "priority": "high",
        "confidence": "high",
        "valueAtRiskRm": 450.0,
        "lastObservedWeekStart": "2026-06-08",
        "occurrenceCount": 1,
    }
    merged = merge_insight(existing, computed)
    for field, value in PRESERVED_FIELDS.items():
        assert merged[field] == value
    assert merged["priority"] == "high"
    assert merged["valueAtRiskRm"] == 450.0
    assert merged["occurrenceCount"] == 4


def test_same_week_upsert_is_idempotent_for_occurrence_count() -> None:
    existing = {
        "issueKey": "stopped_product::R001::P004",
        "lastObservedWeekStart": "2026-06-08",
        "occurrenceCount": 4,
        "status": "new",
    }
    computed = {
        "issueKey": "stopped_product::R001::P004",
        "lastObservedWeekStart": "2026-06-08",
        "occurrenceCount": 1,
        "priority": "high",
    }
    assert merge_insight(existing, computed)["occurrenceCount"] == 4


def test_same_kuching_week_matches_firestore_utc_timestamp() -> None:
    existing = {
        "issueKey": "stopped_product::R001::P004",
        "lastObservedWeekStart": datetime(
            2026,
            6,
            7,
            16,
            tzinfo=timezone.utc,
        ),
        "occurrenceCount": 4,
    }
    computed = {
        "issueKey": "stopped_product::R001::P004",
        "lastObservedWeekStart": date(2026, 6, 8),
        "occurrenceCount": 1,
    }
    assert merge_insight(existing, computed)["occurrenceCount"] == 4


def test_weekly_summary_is_structured() -> None:
    summary = summarize_insights(
        [
            {
                "type": "stopped_product",
                "priority": "high",
                "status": "new",
                "valueAtRiskRm": 120,
            },
            {
                "type": "declining_sales",
                "priority": "medium",
                "status": "new",
                "autoState": "suppressed",
                "valueAtRiskRm": 80,
            },
        ]
    )
    assert summary == {
        "insightCount": 2,
        "unresolvedCount": 1,
        "resolvedCount": 0,
        "ignoredCount": 1,
        "highPriorityCount": 1,
        "valueAtRiskRm": 120.0,
        "byPriority": {"high": 1, "medium": 1},
        "byType": {"stopped_product": 1, "declining_sales": 1},
    }

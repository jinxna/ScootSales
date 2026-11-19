from __future__ import annotations

import json
from datetime import date, datetime

import pytest

from forecasting.ai_service.repository import _firestore_value
from forecasting.ai_core.opportunity import EXPECTED_ORDER_VALUE_VERSION
from forecasting.ai_core.retailer_ranking import (
    COVERAGE_BASIS_LAST_ORDER,
    RETAILER_RANKING_VERSION,
    RetailerEvidence,
    branch_centroid,
    build_rankings,
    decision_log_id,
    evidence_from_opportunities,
    ranking_id,
    week_key_for,
)
from forecasting.ai_core.opportunity import retailer_opportunities
from forecasting.ai_core.route_policy import POLICY_VERSION


def _evidence(count: int = 6, *, scope: str = "uid-1") -> list[RetailerEvidence]:
    return [
        RetailerEvidence(
            retailer_id="R" + str(index).zfill(2),
            retailer_name="Retailer " + str(index),
            salesman_uid=scope,
            branch_id="B1",
            expected_order_value_rm=100.0 + 25.0 * index,
            forecast_relative_uncertainty=0.3,
            service_minutes=20.0,
            days_since_last_visit=float(5 + index),
            observed_periods=8,
            latitude=1.5535 + 0.004 * index,
            longitude=110.3592 + 0.004 * index,
            supporting_issue_keys=(
                "overdue_reorder::R" + str(index).zfill(2) + "::P1",
            ),
        )
        for index in range(count)
    ]


def test_week_key_is_an_iso_week() -> None:
    assert week_key_for(date(2026, 3, 23)) == "2026-W13"


def test_read_model_carries_the_reproducible_decision_record() -> None:
    rankings = build_rankings(
        _evidence(5), week_start=date(2026, 3, 23), seed=5, target_size=3
    )
    row = rankings[0].to_read_model(
        week_start=date(2026, 3, 23),
        salesman_code="S01",
        run_id="run-1",
        generated_at="2026-03-23T00:00:00+00:00",
    )
    assert row["status"] == "active"
    assert row["rankingId"] == ranking_id("uid-1", "2026-W13")
    assert row["policyVersion"] == POLICY_VERSION
    assert row["rankingVersion"] == RETAILER_RANKING_VERSION
    assert row["expectedOrderValueVersion"] == EXPECTED_ORDER_VALUE_VERSION
    assert row["coverageBasis"] == COVERAGE_BASIS_LAST_ORDER
    assert len(row["decisionLog"]) == row["retailerCount"]
    required = {
        "candidate",
        "score",
        "rank",
        "selectionProbability",
        "exploitOrExplore",
        "policyVersion",
        "chosen",
        "components",
        "seed",
        "weekKey",
        "salesmanUid",
    }
    for entry in row["decisionLog"]:
        assert required.issubset(entry.keys())
        assert entry["weekKey"] == "2026-W13"
    persisted = _firestore_value(row)
    assert isinstance(persisted["weekStart"], datetime)
    assert persisted["retailerCount"] == row["retailerCount"]
    assert json.loads(json.dumps(persisted, default=str))["rankingId"] == row["rankingId"]
    assert sum(1 for entry in row["decisionLog"] if entry["chosen"]) == 3


def test_evidence_from_opportunities_keeps_retailers_without_history() -> None:
    opportunities = retailer_opportunities(
        [
            {
                "retailerId": "R1",
                "productId": "P1",
                "weeklyQuantities": [0.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 0.0],
            }
        ],
        unit_prices={"P1": 2.0},
    )
    evidence = evidence_from_opportunities(
        opportunities,
        retailer_records={
            "R1": {"retailerName": "One", "salesmanUid": "uid-1", "latitude": 1.55, "longitude": 110.35},
            "R2": {"retailerName": "Two", "salesmanUid": "uid-1", "latitude": 1.56, "longitude": 110.36},
        },
        last_contact_by_retailer={"R1": date(2026, 3, 1)},
        as_of=date(2026, 3, 23),
    )
    by_id = {row.retailer_id: row for row in evidence}
    assert set(by_id) == {"R1", "R2"}
    assert by_id["R1"].expected_order_value_rm == pytest.approx(10.0)
    assert by_id["R1"].days_since_last_visit == pytest.approx(22.0)
    assert by_id["R2"].expected_order_value_rm == 0.0
    assert by_id["R2"].days_since_last_visit is None
    assert by_id["R2"].coverage_basis == COVERAGE_BASIS_LAST_ORDER


def test_evidence_ignores_unusable_coordinates() -> None:
    evidence = evidence_from_opportunities(
        (),
        retailer_records={"R1": {"latitude": 0, "longitude": 0}},
    )
    assert evidence[0].latitude is None
    assert evidence[0].longitude is None


def test_ranking_and_log_ids_are_deterministic_and_distinct() -> None:
    first = ranking_id("uid-1", "2026-W13")
    assert first == ranking_id("uid-1", "2026-W13")
    assert first != ranking_id("uid-2", "2026-W13")
    log = decision_log_id("uid-1", "2026-W13", "R01")
    assert log == decision_log_id("uid-1", "2026-W13", "R01")
    assert log != decision_log_id("uid-1", "2026-W13", "R02")


def test_branch_centroid_averages_located_retailers_only() -> None:
    rows = _evidence(4)
    rows.append(
        RetailerEvidence(retailer_id="NOLOC", salesman_uid="uid-1", latitude=None)
    )
    centroid = branch_centroid(rows)
    assert centroid is not None
    assert centroid[0] == pytest.approx(1.5535 + 0.004 * 1.5, abs=1e-6)


def test_branch_centroid_is_none_without_coordinates() -> None:
    assert branch_centroid([RetailerEvidence(retailer_id="A")]) is None


def test_rankings_are_built_per_salesman_scope() -> None:
    evidence = _evidence(4, scope="uid-1") + _evidence(3, scope="uid-2")
    rankings = build_rankings(evidence, week_start=date(2026, 3, 23), seed=5)
    assert [row.scope_key for row in rankings] == ["uid-1", "uid-2"]
    assert [row.week_key for row in rankings] == ["2026-W13", "2026-W13"]


def test_ranking_is_deterministic_for_a_seed() -> None:
    first = build_rankings(
        _evidence(10), week_start=date(2026, 3, 23), seed=9, target_size=4
    )[0].to_dict()
    second = build_rankings(
        _evidence(10), week_start=date(2026, 3, 23), seed=9, target_size=4
    )[0].to_dict()
    assert first == second


def test_adding_another_scope_does_not_change_this_scope() -> None:
    mine = _evidence(10, scope="uid-1")
    mine_only = build_rankings(
        mine, week_start=date(2026, 3, 23), seed=9, target_size=3
    )[0]
    with_other_scope = build_rankings(
        mine + _evidence(6, scope="uid-2"),
        week_start=date(2026, 3, 23),
        seed=9,
        target_size=3,
    )[0]
    assert mine_only.seed == with_other_scope.seed
    assert mine_only.to_dict() == with_other_scope.to_dict()


def test_decision_rows_carry_the_required_logging_fields() -> None:
    ranking = build_rankings(
        _evidence(8), week_start=date(2026, 3, 23), seed=3, target_size=3
    )[0]
    assert len(ranking.decision_rows) == 8
    for row in ranking.decision_rows:
        assert row["policyVersion"] == POLICY_VERSION
        assert row["candidate"]
        assert row["rank"] >= 1
        assert 0.0 <= row["selectionProbability"] <= 1.0
        assert row["exploitOrExplore"] in {"exploit", "explore", "not_selected"}
        assert isinstance(row["chosen"], bool)
        assert row["weekKey"] == "2026-W13"
        assert row["salesmanUid"] == "uid-1"
        assert row["seed"] == ranking.seed


def test_ranked_rows_expose_their_score_components() -> None:
    ranking = build_rankings(
        _evidence(4), week_start=date(2026, 3, 23), seed=3, target_size=2
    )[0]
    for row in ranking.ranked:
        assert "opportunityPerRouteDay" in row.components
        assert "travelMinutes" in row.components


def test_supporting_issue_keys_are_preserved() -> None:
    ranking = build_rankings(
        _evidence(3), week_start=date(2026, 3, 23), seed=3, target_size=2
    )[0]
    top = ranking.ranked[0]
    assert top.supporting_issue_keys == (
        "overdue_reorder::" + top.retailer_id + "::P1",
    )


def test_zero_target_size_is_rejected() -> None:
    with pytest.raises(ValueError):
        build_rankings(
            _evidence(2), week_start=date(2026, 3, 23), seed=1, target_size=0
        )


def test_retired_retailers_are_not_ranking_candidates() -> None:
    evidence = evidence_from_opportunities(
        (),
        retailer_records={
            "active": {"retailerName": "Active"},
            "retired": {"retailerName": "Retired", "isRetired": True},
        },
    )
    assert [row.retailer_id for row in evidence] == ["active"]


def test_current_assignment_code_wins_over_a_stale_uid_and_retired_is_flagged() -> None:
    from forecasting.ai_service.normalization import normalize_firestore_inputs

    data = normalize_firestore_inputs(
        orders=(),
        products=(),
        retailers=(
            {"docId": "r1", "assignedSalesmanId": "S002", "salesmanUid": "u1"},
            {"docId": "r2", "assignedSalesmanId": "S001", "status": "retired"},
        ),
        users=(
            {"uid": "u1", "employeeCode": "S001"},
            {"uid": "u2", "employeeCode": "S002"},
        ),
        as_of=date(2026, 10, 5),
    )
    assert data.retailers["r1"].salesman_uid == "u2"
    assert data.retailers["r1"].is_retired is False
    assert data.retailers["r2"].is_retired is True


def test_contact_recency_uses_the_kuching_date() -> None:
    from datetime import timezone

    from forecasting.ai_service.generator import _last_order_date_by_retailer

    orders = [
        {"retailerId": "R1", "submittedAt": datetime(2026, 3, 1, 18, tzinfo=timezone.utc)},
        {"retailerId": "R2", "submittedAt": "2026-03-22T17:00:00Z"},
        {"retailerId": "R3", "submittedAt": "2026-03-23T17:00:00Z"},
    ]
    as_of = date(2026, 3, 23)
    latest = _last_order_date_by_retailer(orders, as_of=as_of)
    assert latest == {"R1": date(2026, 3, 2), "R2": date(2026, 3, 23)}

    evidence = evidence_from_opportunities(
        (),
        retailer_records={"R1": {}, "R2": {}},
        last_contact_by_retailer={
            "R1": datetime(2026, 3, 1, 18, tzinfo=timezone.utc),
            "R2": "2026-03-22T17:00:00Z",
        },
        as_of=as_of,
    )
    days = {row.retailer_id: row.days_since_last_visit for row in evidence}
    assert days == {"R1": 21.0, "R2": 0.0}

from __future__ import annotations

import pytest

from forecasting.ai_core.route_policy import (
    COVERAGE_STARVATION_DAYS,
    DEFAULT_ROUTE_DAY_MINUTES,
    DEFAULT_SERVICE_MINUTES,
    POLICY_VERSION,
    UNCERTAINTY_WEIGHT,
    RetailerVisitCandidate,
    haversine_km,
    opportunity_per_route_day,
    route_value_per_day,
    score_candidate,
    select_route_candidates,
    travel_minutes,
)


def _candidate(retailer_id: str, value: float, **kwargs: object) -> RetailerVisitCandidate:
    defaults: dict[str, object] = {
        "retailer_name": retailer_id.upper(),
        "service_minutes": 20.0,
        "distance_km": 0.0,
        "days_since_last_visit": 7.0,
        "observed_periods": 8,
    }
    defaults.update(kwargs)
    return RetailerVisitCandidate(
        retailer_id=retailer_id, expected_order_value_rm=value, **defaults  # type: ignore[arg-type]
    )


def test_haversine_matches_a_known_distance() -> None:
    distance = haversine_km(1.5533, 110.3592, 2.2878, 111.8305)
    assert distance == pytest.approx(190.0, abs=15.0)


def test_haversine_is_zero_for_the_same_point() -> None:
    assert haversine_km(1.5, 110.0, 1.5, 110.0) == pytest.approx(0.0)


def test_travel_minutes_applies_road_factor_and_speed() -> None:
    assert travel_minutes(28.0) == pytest.approx(78.0)


def test_travel_minutes_is_zero_for_non_positive_distance() -> None:
    assert travel_minutes(0.0) == 0.0
    assert travel_minutes(-3.0) == 0.0


def test_opportunity_per_route_day_divides_by_consumed_days() -> None:
    value = opportunity_per_route_day(
        100.0, service_minutes=54.0, travel_minutes_value=0.0
    )
    assert value == pytest.approx(1000.0)


def test_opportunity_per_route_day_of_zero_time_is_zero() -> None:
    assert (
        opportunity_per_route_day(
            100.0, service_minutes=0.0, travel_minutes_value=0.0
        )
        == 0.0
    )


def test_route_value_per_day_is_a_ratio_of_sums() -> None:
    assert route_value_per_day([50.0, 150.0], route_days=2.0) == pytest.approx(100.0)


def test_route_value_per_day_without_days_is_zero() -> None:
    assert route_value_per_day([10.0], route_days=0.0) == 0.0


def test_score_is_value_per_route_day_for_a_local_retailer() -> None:
    scored = score_candidate(_candidate("A", 54.0, service_minutes=54.0))
    assert scored.opportunity_per_route_day == pytest.approx(540.0)


def test_travel_time_reduces_value_per_route_day() -> None:
    near = score_candidate(_candidate("A", 100.0, distance_km=1.0))
    far = score_candidate(_candidate("A", 100.0, distance_km=20.0))
    assert far.opportunity_per_route_day < near.opportunity_per_route_day
    assert far.adjusted_score < near.adjusted_score


def test_uncertainty_produces_an_upper_confidence_bonus() -> None:
    certain = score_candidate(_candidate("A", 100.0, forecast_relative_uncertainty=0.0))
    uncertain = score_candidate(_candidate("A", 100.0, forecast_relative_uncertainty=0.5))
    assert uncertain.uncertainty_rm == pytest.approx(50.0)
    assert uncertain.adjusted_value_rm == pytest.approx(100.0 + UNCERTAINTY_WEIGHT * 50.0)
    assert uncertain.adjusted_score > certain.adjusted_score


def test_negative_forecast_values_are_clamped_to_zero() -> None:
    scored = score_candidate(_candidate("A", -40.0))
    assert scored.expected_value_rm == 0.0
    assert scored.adjusted_score == 0.0


def test_missing_service_time_uses_the_documented_default() -> None:
    scored = score_candidate(_candidate("A", 20.0, service_minutes=None))
    assert scored.service_minutes == DEFAULT_SERVICE_MINUTES


def test_missing_coordinates_do_not_add_travel_cost() -> None:
    scored = score_candidate(_candidate("A", 20.0, distance_km=None))
    assert scored.travel_minutes == 0.0
    assert scored.candidate.distance_km is None


def test_coverage_boost_rises_with_time_since_last_visit() -> None:
    recent = score_candidate(_candidate("A", 50.0, days_since_last_visit=1.0))
    stale = score_candidate(_candidate("A", 50.0, days_since_last_visit=42.0))
    assert recent.coverage_boost < stale.coverage_boost
    assert stale.adjusted_score > recent.adjusted_score


def test_never_visited_scores_the_full_coverage_boost() -> None:
    never = score_candidate(_candidate("A", 50.0, days_since_last_visit=None))
    stale = score_candidate(
        _candidate("A", 50.0, days_since_last_visit=COVERAGE_STARVATION_DAYS)
    )
    assert never.coverage_boost == pytest.approx(stale.coverage_boost)


def test_score_components_expose_every_factor() -> None:
    components = score_candidate(_candidate("A", 90.0, distance_km=5.0)).score_components()
    for key in (
        "expectedValueRm",
        "uncertaintyRm",
        "adjustedValueRm",
        "serviceMinutes",
        "travelMinutes",
        "routeTimeDays",
        "opportunityPerRouteDay",
        "coverageBoost",
        "adjustedScore",
    ):
        assert key in components


def test_selection_is_deterministic_for_a_seed() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(20)]
    first = select_route_candidates(candidates, target_size=8, seed=7)
    second = select_route_candidates(candidates, target_size=8, seed=7)
    assert [row.retailer_id for row in first.scored] == [
        row.retailer_id for row in second.scored
    ]
    assert [row.retailer_id for row in first.chosen] == [
        row.retailer_id for row in second.chosen
    ]


def test_different_seeds_can_change_exploration_picks() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(30)]
    picks = set()
    for seed in range(12):
        result = select_route_candidates(candidates, target_size=10, seed=seed)
        picks.add(tuple(sorted(row.retailer_id for row in result.chosen)))
    assert len(picks) > 1


def test_chosen_set_is_exactly_the_target_size() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(20)]
    result = select_route_candidates(candidates, target_size=8, seed=3)
    assert len(result.chosen) == 8


def test_every_candidate_is_logged_with_the_required_fields() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(12)]
    result = select_route_candidates(candidates, target_size=5, seed=1)
    rows = result.to_rows(week_key="2026-W12", salesman_uid="uid-1")
    assert len(rows) == 12
    for row in rows:
        assert row["policyVersion"] == POLICY_VERSION
        assert row["candidate"]
        assert isinstance(row["score"], float)
        assert row["rank"] >= 1
        assert 0.0 <= row["selectionProbability"] <= 1.0
        assert row["exploitOrExplore"] in {"exploit", "explore", "not_selected"}
        assert isinstance(row["chosen"], bool)
        assert row["weekKey"] == "2026-W12"
        assert row["salesmanUid"] == "uid-1"


def test_exactly_one_row_per_candidate_is_chosen() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(12)]
    rows = select_route_candidates(
        candidates, target_size=5, seed=1
    ).to_rows(week_key="2026-W12", salesman_uid="uid-1")
    assert sum(1 for row in rows if row["chosen"]) == 5


def test_all_zero_candidates_do_not_freeze_the_policy() -> None:
    candidates = [_candidate(f"R{index:02d}", 0.0) for index in range(10)]
    result = select_route_candidates(candidates, target_size=4, seed=5)
    assert len(result.chosen) == 4


def test_low_value_candidate_is_not_preferred_over_a_high_value_one() -> None:
    candidates = [
        _candidate("BIG", 5000.0),
        _candidate("SMALL", 5.0),
    ]
    result = select_route_candidates(candidates, target_size=1, seed=1)
    assert [row.retailer_id for row in result.chosen] == ["BIG"]


def test_exploration_draws_only_from_the_swap_band() -> None:
    candidates = [
        _candidate("BIG", 5000.0),
        _candidate("MID", 4900.0),
        _candidate("HOPELESS", 1.0),
    ]
    for seed in range(20):
        result = select_route_candidates(candidates, target_size=2, seed=seed)
        chosen = {row.retailer_id for row in result.chosen}
        assert "HOPELESS" not in chosen


def test_coverage_guard_promotes_a_starved_retailer() -> None:
    candidates = [_candidate(f"R{index:02d}", 1000.0 - index) for index in range(10)]
    candidates.append(
        _candidate(
            "STARVED",
            10.0,
            days_since_last_visit=COVERAGE_STARVATION_DAYS + 30,
        )
    )
    result = select_route_candidates(candidates, target_size=6, seed=2)
    assert "STARVED" in {row.retailer_id for row in result.chosen}


def test_coverage_guard_is_bounded() -> None:
    candidates = [_candidate(f"R{index:02d}", 1000.0 - index) for index in range(12)]
    candidates += [
        _candidate(f"S{index:02d}", 1.0, days_since_last_visit=None)
        for index in range(12)
    ]
    result = select_route_candidates(candidates, target_size=8, seed=4)
    starved = [row for row in result.chosen if row.retailer_id.startswith("S")]
    assert 0 < len(starved) <= 2


def test_exploit_pick_has_probability_one_and_explore_pick_records_the_draw() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(20)]
    result = select_route_candidates(candidates, target_size=8, seed=11)
    exploit = [row for row in result.chosen if row.exploit_or_explore == "exploit"]
    explore = [row for row in result.chosen if row.exploit_or_explore == "explore"]
    assert exploit and all(row.selection_probability == 1.0 for row in exploit)
    assert explore and all(0.0 < row.selection_probability <= 1.0 for row in explore)


def test_not_selected_band_members_still_record_their_probability() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(20)]
    result = select_route_candidates(candidates, target_size=8, seed=1)
    band_missed = [
        row
        for row in result.scored
        if not row.chosen and row.selection_probability > 0.0
    ]
    assert band_missed
    assert all(row.exploit_or_explore == "not_selected" for row in band_missed)


def test_ranks_are_dense_and_start_at_one() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(7)]
    result = select_route_candidates(candidates, target_size=3, seed=1)
    assert [row.rank for row in result.scored] == [1, 2, 3, 4, 5, 6, 7]


def test_empty_candidate_set_is_handled() -> None:
    result = select_route_candidates([], target_size=5, seed=1)
    assert result.scored == ()
    assert result.chosen == ()


def test_zero_target_size_is_rejected() -> None:
    with pytest.raises(ValueError):
        select_route_candidates([_candidate("A", 10.0)], target_size=0, seed=1)


def test_target_larger_than_pool_selects_everything() -> None:
    candidates = [_candidate("A", 10.0), _candidate("B", 20.0)]
    result = select_route_candidates(candidates, target_size=10, seed=1)
    assert len(result.chosen) == 2


def test_route_day_minutes_scales_the_ranking_uniformly() -> None:
    candidates = [_candidate(f"R{index:02d}", 100.0 - index) for index in range(10)]
    normal = select_route_candidates(candidates, target_size=4, seed=1)
    halved = select_route_candidates(
        candidates,
        target_size=4,
        seed=1,
        route_day_minutes=DEFAULT_ROUTE_DAY_MINUTES / 2,
    )
    assert [row.retailer_id for row in normal.chosen] == [
        row.retailer_id for row in halved.chosen
    ]

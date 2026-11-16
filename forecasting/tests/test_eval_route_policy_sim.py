from __future__ import annotations

from itertools import combinations

import pytest

from forecasting.evaluation.route_policy_sim import (
    EXHAUSTIVE_SUBSET_LIMIT,
    POLICIES,
    SimCandidate,
    _benchmark_value,
    _best_order,
    realised_ratio_catalogue,
    simulate_policies,
)


def _pool(count: int = 8, *, spread_km: float = 0.02) -> list[SimCandidate]:
    pool: list[SimCandidate] = []
    for index in range(count):
        pool.append(
            SimCandidate(
                retailer_id=f"R{index:02d}",
                expected_value_rm=100.0 + 10.0 * index,
                forecast_relative_uncertainty=0.3,
                latitude=1.55 + spread_km * (index % 4),
                longitude=110.35 + spread_km * (index // 4),
                service_minutes=20.0,
                days_since_last_visit=7.0 + index,
            )
        )
    return pool


def test_catalogue_uses_only_positive_expectations() -> None:
    ratios = realised_ratio_catalogue(
        [
            {"expectedValueRm": 100.0, "realisedValueRm": 50.0},
            {"expectedValueRm": 0.0, "realisedValueRm": 50.0},
            {"expectedValueRm": 100.0, "realisedValueRm": 200.0},
        ]
    )
    assert ratios == [0.5, 2.0]


def test_catalogue_clamps_pathological_ratios() -> None:
    ratios = realised_ratio_catalogue(
        [{"expectedValueRm": 1.0, "realisedValueRm": 1000.0}]
    )
    assert ratios == [4.0]


def test_simulation_is_deterministic_for_a_seed() -> None:
    pool = _pool()
    first = simulate_policies(
        pool, target_size=4, seed=13, replicates=6, realised_ratios=[0.0, 1.0, 2.0]
    ).to_dict()
    second = simulate_policies(
        pool, target_size=4, seed=13, replicates=6, realised_ratios=[0.0, 1.0, 2.0]
    ).to_dict()
    assert first == second


def test_simulation_reports_every_policy() -> None:
    result = simulate_policies(
        _pool(), target_size=4, seed=1, replicates=3, realised_ratios=[1.0]
    )
    assert set(result.comparisons) == set(POLICIES)
    for comparison in result.comparisons.values():
        assert comparison.replicates == 3
        assert comparison.mean_realised_per_day is not None
        assert comparison.mean_benchmark_gap_per_day is not None


def test_provenance_marks_the_evidence_as_simulated() -> None:
    result = simulate_policies(
        _pool(), target_size=4, seed=1, replicates=2, realised_ratios=[1.0]
    )
    assert result.provenance["evidence"] == "simulated"
    assert result.provenance["degenerateNoRatioCatalogue"] is False
    assert result.provenance["ratioCatalogueSize"] == 1


def test_empty_catalogue_is_flagged_as_degenerate() -> None:
    result = simulate_policies(_pool(), target_size=4, seed=1, replicates=2)
    assert result.provenance["degenerateNoRatioCatalogue"] is True
    regret = result.comparisons["priorityRouting"].mean_benchmark_gap_per_day
    assert regret == pytest.approx(0.0)


def test_regret_is_never_negative() -> None:
    result = simulate_policies(
        _pool(),
        target_size=4,
        seed=3,
        replicates=8,
        realised_ratios=[0.0, 0.5, 1.0, 1.5, 2.0],
    )
    for comparison in result.comparisons.values():
        for outcome in comparison.outcomes:
            assert outcome.regret_per_day >= 0.0


def test_benchmark_is_not_beaten_by_any_policy() -> None:
    result = simulate_policies(
        _pool(count=14),
        target_size=5,
        seed=17,
        replicates=12,
        realised_ratios=[0.0, 0.5, 1.0, 1.5, 2.0],
    )
    assert result.provenance["benchmarkBeatenByComparedPolicies"] == 0
    assert result.provenance["benchmarkComparedPolicyFloor"] is True
    for policy, comparison in result.comparisons.items():
        assert policy in POLICIES
        for outcome in comparison.outcomes:
            assert outcome.regret_per_day >= 0.0


def test_exhaustive_benchmark_equals_brute_force_maximum() -> None:
    pool = _pool(count=7)
    realised = {
        candidate.retailer_id: round(candidate.expected_value_rm, 4)
        for candidate in pool
    }
    depot = (1.55, 110.35)
    result = simulate_policies(
        pool,
        target_size=3,
        seed=23,
        replicates=1,
        realised_ratios=[1.0],
        policies=["roundRobin", "priorityRouting"],
        depot=depot,
    )
    assert result.provenance["benchmarkMethods"] == {"exhaustiveOverPool": 1}
    assert result.provenance["benchmarkIsExact"] is True

    best = 0.0
    for subset in combinations(pool, 3):
        _, per_day = _benchmark_value(
            subset, realised, depot=depot, route_day_minutes=540.0
        )
        best = max(best, per_day)
    for comparison in result.comparisons.values():
        outcome = comparison.outcomes[0]
        assert outcome.regret_per_day == pytest.approx(
            max(0.0, best - outcome.realised_per_day)
        )
    assert (
        result.comparisons["roundRobin"].outcomes[0].regret_per_day
        >= result.comparisons["priorityRouting"].outcomes[0].regret_per_day
    )


def test_large_pool_reports_a_non_exact_best_known_benchmark() -> None:
    pool = _pool(count=20)
    result = simulate_policies(
        pool,
        target_size=8,
        seed=5,
        replicates=3,
        realised_ratios=[0.5, 1.0, 1.5],
    )
    methods = result.provenance["benchmarkMethods"]
    assert set(methods).issubset(
        {"exhaustiveOverPool", "exactOverCandidateSuperset", "bestKnownFeasible"}
    )
    assert sum(methods.values()) == 3
    if "bestKnownFeasible" in methods:
        assert result.provenance["benchmarkIsExact"] is False
        assert "not a proven optimum" in result.provenance["benchmarkGuarantee"]


def test_benchmark_never_returns_an_impossible_value() -> None:
    pool = _pool(count=9)
    realised = {candidate.retailer_id: 1.0 for candidate in pool}
    realised["R08"] = 9000.0
    result = simulate_policies(
        pool,
        target_size=2,
        seed=31,
        replicates=4,
        realised_ratios=[1.0],
        policies=["priorityOnly", "distanceOnly"],
    )
    for comparison in result.comparisons.values():
        for outcome in comparison.outcomes:
            assert outcome.regret_per_day >= 0.0


def test_priority_routing_is_not_worse_than_round_robin() -> None:
    result = simulate_policies(
        _pool(count=10),
        target_size=4,
        seed=5,
        replicates=12,
        realised_ratios=[0.0, 0.5, 1.0, 1.5, 2.0],
    )
    routing = result.comparisons["priorityRouting"].mean_realised_per_day
    round_robin = result.comparisons["roundRobin"].mean_realised_per_day
    assert routing is not None and round_robin is not None
    assert routing > round_robin


def test_exploration_selects_at_least_as_many_distinct_retailers() -> None:
    result = simulate_policies(
        _pool(count=12),
        target_size=5,
        seed=7,
        replicates=16,
        realised_ratios=[0.5, 1.0, 1.5],
    )
    exploring = result.comparisons["priorityRoutingExploration"]
    plain = result.comparisons["priorityRouting"]
    assert (
        exploring.distinct_retailers_selected
        >= plain.distinct_retailers_selected
    )


def test_every_policy_fills_the_target_size() -> None:
    result = simulate_policies(
        _pool(count=9), target_size=4, seed=2, replicates=4, realised_ratios=[1.0]
    )
    for comparison in result.comparisons.values():
        assert comparison.mean_retailers_selected == pytest.approx(4.0)


def test_target_larger_than_pool_is_handled() -> None:
    result = simulate_policies(
        _pool(count=3), target_size=10, seed=1, replicates=2, realised_ratios=[1.0]
    )
    for comparison in result.comparisons.values():
        assert comparison.mean_retailers_selected == pytest.approx(3.0)


def test_empty_pool_is_handled() -> None:
    result = simulate_policies([], target_size=4, seed=1, replicates=2)
    assert result.pool_size == 0
    for comparison in result.comparisons.values():
        assert comparison.mean_retailers_selected == pytest.approx(0.0)


def test_invalid_replicate_count_is_rejected() -> None:
    with pytest.raises(ValueError):
        simulate_policies(_pool(), target_size=2, seed=1, replicates=0)


def test_unknown_policy_is_rejected() -> None:
    with pytest.raises(ValueError):
        simulate_policies(
            _pool(), target_size=2, seed=1, replicates=1, policies=["nonsense"]
        )


def test_distance_only_prefers_the_nearest_candidates() -> None:
    pool = [
        SimCandidate(
            retailer_id="NEAR",
            expected_value_rm=1.0,
            forecast_relative_uncertainty=0.0,
            latitude=1.5501,
            longitude=110.3501,
        ),
        SimCandidate(
            retailer_id="FAR",
            expected_value_rm=100000.0,
            forecast_relative_uncertainty=0.0,
            latitude=1.9,
            longitude=110.9,
        ),
    ]
    result = simulate_policies(
        pool,
        target_size=1,
        seed=1,
        replicates=1,
        realised_ratios=[1.0],
        depot=(1.55, 110.35),
    )
    chosen = result.comparisons["distanceOnly"].outcomes[0].chosen
    assert chosen == ("NEAR",)

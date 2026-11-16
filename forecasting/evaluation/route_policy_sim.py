from __future__ import annotations

import math
import random
import statistics
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any, Mapping, Sequence

from forecasting.ai_core.calendar import as_kuching_date
from forecasting.ai_core.route_policy import (
    DEFAULT_ROUTE_DAY_MINUTES,
    DEFAULT_SERVICE_MINUTES,
    POLICY_VERSION,
    RetailerVisitCandidate,
    haversine_km,
    score_candidate,
    travel_minutes,
)
from forecasting.ai_service.order_lines import authoritative_order_items

POLICIES: tuple[str, ...] = (
    "roundRobin",
    "distanceOnly",
    "priorityOnly",
    "priorityRouting",
    "priorityRoutingExploration",
)

EXPLORATION_SCORE_BAND = 0.15

EXPLORATION_EVERY = 4

EXHAUSTIVE_SUBSET_LIMIT = 5000

BEST_KNOWN_SWAP_PASSES = 4


@dataclass(frozen=True)
class SimCandidate:
    retailer_id: str
    expected_value_rm: float
    forecast_relative_uncertainty: float
    latitude: float
    longitude: float
    service_minutes: float = DEFAULT_SERVICE_MINUTES
    days_since_last_visit: float | None = 7.0
    observed_periods: int = 8

    def to_candidate(self, *, distance_km: float | None) -> RetailerVisitCandidate:
        return RetailerVisitCandidate(
            retailer_id=self.retailer_id,
            retailer_name=self.retailer_id,
            expected_order_value_rm=self.expected_value_rm,
            forecast_relative_uncertainty=self.forecast_relative_uncertainty,
            service_minutes=self.service_minutes,
            distance_km=distance_km,
            days_since_last_visit=self.days_since_last_visit,
            observed_periods=self.observed_periods,
        )


@dataclass(frozen=True)
class PolicyOutcome:
    policy: str
    replicate: int
    chosen: tuple[str, ...]
    expected_value_rm: float
    realised_value_rm: float
    route_days: float
    expected_per_day: float
    realised_per_day: float
    regret_per_day: float
    service_minutes: float
    travel_minutes: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "policy": self.policy,
            "replicate": self.replicate,
            "chosen": list(self.chosen),
            "expectedValueRm": round(self.expected_value_rm, 4),
            "realisedValueRm": round(self.realised_value_rm, 4),
            "routeDays": round(self.route_days, 6),
            "expectedPerDay": round(self.expected_per_day, 4),
            "realisedPerDay": round(self.realised_per_day, 4),
            "hindsightBenchmarkGapPerDay": round(self.regret_per_day, 4),
            "serviceMinutes": round(self.service_minutes, 2),
            "travelMinutes": round(self.travel_minutes, 2),
        }


@dataclass
class PolicyComparison:
    policy: str
    replicates: int
    mean_realised_per_day: float | None
    mean_benchmark_gap_per_day: float | None
    min_realised_per_day: float | None
    max_realised_per_day: float | None
    mean_retailers_selected: float | None
    distinct_retailers_selected: int
    starved_retailers_selected: int
    mean_travel_minutes: float | None
    outcomes: list[PolicyOutcome] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "policy": self.policy,
            "replicates": self.replicates,
            "meanRealisedPerDay": self.mean_realised_per_day,
            "meanHindsightBenchmarkGapPerDay": self.mean_benchmark_gap_per_day,
            "minRealisedPerDay": self.min_realised_per_day,
            "maxRealisedPerDay": self.max_realised_per_day,
            "meanRetailersSelected": self.mean_retailers_selected,
            "distinctRetailersSelected": self.distinct_retailers_selected,
            "starvedRetailersSelected": self.starved_retailers_selected,
            "meanTravelMinutes": self.mean_travel_minutes,
            "outcomes": [row.to_dict() for row in self.outcomes],
        }


@dataclass
class RoutePolicySimulation:
    seed: int
    replicates: int
    target_size: int
    route_day_minutes: float
    pool_size: int
    comparisons: dict[str, PolicyComparison]
    provenance: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "seed": self.seed,
            "replicates": self.replicates,
            "targetSize": self.target_size,
            "routeDayMinutes": self.route_day_minutes,
            "poolSize": self.pool_size,
            "policies": {
                policy: comparison.to_dict()
                for policy, comparison in self.comparisons.items()
            },
            "provenance": dict(self.provenance),
        }


def realised_ratio_catalogue(
    observations: Sequence[Mapping[str, Any]],
) -> list[float]:
    ratios: list[float] = []
    for row in observations:
        expected = float(row.get("expectedValueRm") or 0.0)
        if expected <= 0:
            continue
        realised = max(0.0, float(row.get("realisedValueRm") or 0.0))
        ratios.append(max(0.0, min(4.0, realised / expected)))
    return ratios


def _draw_realised_values(
    candidates: Sequence[SimCandidate],
    *,
    ratios: Sequence[float],
    rng: random.Random,
) -> dict[str, float]:
    realised: dict[str, float] = {}
    if not ratios:
        for candidate in candidates:
            realised[candidate.retailer_id] = candidate.expected_value_rm
        return realised
    for candidate in candidates:
        ratio = ratios[rng.randrange(len(ratios))]
        realised[candidate.retailer_id] = round(
            candidate.expected_value_rm * ratio, 4
        )
    return realised


def _best_order(
    subset: Sequence[SimCandidate], depot: tuple[float, float]
) -> list[SimCandidate]:
    remaining = sorted(subset, key=lambda candidate: candidate.retailer_id)
    ordered: list[SimCandidate] = []
    position = depot
    while remaining:
        nearest = min(
            remaining,
            key=lambda candidate: (
                haversine_km(
                    position[0], position[1], candidate.latitude, candidate.longitude
                ),
                candidate.retailer_id,
            ),
        )
        ordered.append(nearest)
        remaining.remove(nearest)
        position = (nearest.latitude, nearest.longitude)
    return ordered


def _ordered_travel_minutes(
    stops: Sequence[SimCandidate], depot: tuple[float, float]
) -> float:
    total = 0.0
    previous = depot
    for stop in stops:
        total += travel_minutes(
            haversine_km(previous[0], previous[1], stop.latitude, stop.longitude)
        )
        previous = (stop.latitude, stop.longitude)
    return total


def _route_days(
    stops: Sequence[SimCandidate],
    depot: tuple[float, float],
    route_day_minutes: float,
) -> tuple[float, float]:
    travel = _ordered_travel_minutes(stops, depot)
    service = sum(candidate.service_minutes for candidate in stops)
    return (service + travel) / route_day_minutes, travel


def _value_per_day(values: Sequence[float], route_days: float) -> float:
    if route_days <= 0:
        return 0.0
    return sum(values) / route_days


def _subsets(
    pool: Sequence[SimCandidate], size: int
) -> list[tuple[SimCandidate, ...]]:
    if size <= 0:
        return []
    if size >= len(pool):
        return [tuple(pool)]
    results: list[tuple[SimCandidate, ...]] = []
    stack: list[tuple[int, list[SimCandidate]]] = [(0, [])]
    while stack:
        start, current = stack.pop()
        if len(current) == size:
            results.append(tuple(current))
            continue
        for index in range(start, len(pool)):
            stack.append((index + 1, [*current, pool[index]]))
    return results


def _benchmark_value(
    subset: Sequence[SimCandidate],
    realised: Mapping[str, float],
    *,
    depot: tuple[float, float],
    route_day_minutes: float,
) -> tuple[float, float]:
    if not subset:
        return 0.0, 0.0
    ordered = _best_order(subset, depot)
    days, _ = _route_days(ordered, depot, route_day_minutes)
    value = sum(realised[candidate.retailer_id] for candidate in ordered)
    return value, _value_per_day([value], days)


def _best_known_selection(
    pool: Sequence[SimCandidate],
    realised: Mapping[str, float],
    *,
    target_size: int,
    route_day_minutes: float,
    depot: tuple[float, float],
    start: Sequence[SimCandidate],
) -> tuple[float, list[SimCandidate]]:
    remaining = sorted(pool, key=lambda candidate: candidate.retailer_id)
    chosen: list[SimCandidate] = list(start)
    while remaining and len(chosen) < target_size:
        best_candidate: SimCandidate | None = None
        best_per_day = -1.0
        for candidate in remaining:
            trial = [*chosen, candidate]
            _, per_day = _benchmark_value(
                trial,
                realised,
                depot=depot,
                route_day_minutes=route_day_minutes,
            )
            if per_day > best_per_day or (
                per_day == best_per_day
                and best_candidate is not None
                and candidate.retailer_id < best_candidate.retailer_id
            ):
                best_per_day = per_day
                best_candidate = candidate
        if best_candidate is None:
            break
        chosen.append(best_candidate)
        remaining = [
            candidate
            for candidate in remaining
            if candidate.retailer_id != best_candidate.retailer_id
        ]

    _, best_per_day = _benchmark_value(
        chosen, realised, depot=depot, route_day_minutes=route_day_minutes
    )
    for _ in range(BEST_KNOWN_SWAP_PASSES):
        chosen_ids = {candidate.retailer_id for candidate in chosen}
        outside = [
            candidate
            for candidate in sorted(pool, key=lambda row: row.retailer_id)
            if candidate.retailer_id not in chosen_ids
        ]
        improvement_value = best_per_day
        improvement: tuple[SimCandidate, SimCandidate] | None = None
        for dropped in sorted(chosen, key=lambda row: row.retailer_id):
            trial_without = [
                candidate
                for candidate in chosen
                if candidate.retailer_id != dropped.retailer_id
            ]
            for added in outside:
                _, per_day = _benchmark_value(
                    [*trial_without, added],
                    realised,
                    depot=depot,
                    route_day_minutes=route_day_minutes,
                )
                if per_day > improvement_value:
                    improvement_value = per_day
                    improvement = (dropped, added)
        if improvement is None:
            break
        dropped, added = improvement
        chosen = [
            candidate
            for candidate in chosen
            if candidate.retailer_id != dropped.retailer_id
        ]
        chosen.append(added)
        best_per_day = improvement_value
    return best_per_day, chosen


def _hindsight_benchmark(
    pool: Sequence[SimCandidate],
    realised: Mapping[str, float],
    *,
    target_size: int,
    route_day_minutes: float,
    depot: tuple[float, float],
    compared_selections: Sequence[Sequence[SimCandidate]],
) -> dict[str, Any]:
    from math import comb

    if target_size <= 0 or not pool:
        return {
            "valuePerDay": 0.0,
            "method": "empty",
            "isExact": True,
            "beatenByComparedPolicies": 0,
        }
    size = min(target_size, len(pool))
    compared_values = [
        _benchmark_value(
            selection,
            realised,
            depot=depot,
            route_day_minutes=route_day_minutes,
        )[1]
        for selection in compared_selections
        if selection
    ]
    best_compared = max(compared_values) if compared_values else 0.0

    universe: list[SimCandidate] = []
    method = "bestKnownFeasible"
    is_exact = False
    if comb(len(pool), size) <= EXHAUSTIVE_SUBSET_LIMIT:
        universe = list(pool)
        method = "exhaustiveOverPool"
        is_exact = True
    else:
        seen: dict[str, SimCandidate] = {}
        for selection in compared_selections:
            for candidate in selection:
                seen[candidate.retailer_id] = candidate
        for candidate in sorted(
            pool, key=lambda row: (-realised[row.retailer_id], row.retailer_id)
        )[:size]:
            seen[candidate.retailer_id] = candidate
        candidate_universe = sorted(
            seen.values(), key=lambda row: row.retailer_id
        )
        if comb(len(candidate_universe), size) <= EXHAUSTIVE_SUBSET_LIMIT:
            universe = candidate_universe
            method = "exactOverCandidateSuperset"
            is_exact = True

    if is_exact:
        best_per_day = 0.0
        for subset in _subsets(universe, size):
            _, per_day = _benchmark_value(
                subset,
                realised,
                depot=depot,
                route_day_minutes=route_day_minutes,
            )
            if per_day > best_per_day:
                best_per_day = per_day
    else:
        best_per_day, _ = _best_known_selection(
            pool,
            realised,
            target_size=size,
            route_day_minutes=route_day_minutes,
            depot=depot,
            start=(),
        )

    beaten = sum(1 for value in compared_values if value > best_per_day + 1e-9)
    return {
        "valuePerDay": max(best_per_day, best_compared),
        "method": method,
        "isExact": is_exact,
        "beatenByComparedPolicies": beaten,
    }


def _greedy_by_score(
    pool: Sequence[SimCandidate],
    *,
    target_size: int,
    depot: tuple[float, float],
    route_day_minutes: float,
    exploration_every: int | None,
    exploration_band: float,
    seed: int,
) -> list[SimCandidate]:
    remaining = list(pool)
    chosen: list[SimCandidate] = []
    rng = random.Random(seed)
    position = depot
    while remaining and len(chosen) < target_size:
        scored = []
        for candidate in remaining:
            distance = haversine_km(
                position[0], position[1], candidate.latitude, candidate.longitude
            )
            scored.append(
                score_candidate(
                    candidate.to_candidate(distance_km=distance),
                    route_day_minutes=route_day_minutes,
                )
            )
        scored.sort(key=lambda row: (-row.adjusted_score, row.retailer_id))
        pick = scored[0]
        if (
            exploration_every is not None
            and exploration_every > 0
            and (len(chosen) + 1) % exploration_every == 0
            and len(scored) > 1
        ):
            band = [
                row
                for row in scored
                if row.adjusted_score
                >= pick.adjusted_score * (1.0 - exploration_band)
            ]
            pick = band[rng.randrange(len(band))]
        picked = next(
            candidate
            for candidate in remaining
            if candidate.retailer_id == pick.retailer_id
        )
        chosen.append(picked)
        remaining = [
            candidate
            for candidate in remaining
            if candidate.retailer_id != pick.retailer_id
        ]
        position = (picked.latitude, picked.longitude)
    return chosen


def _policy_selection(
    policy: str,
    pool: Sequence[SimCandidate],
    *,
    target_size: int,
    depot: tuple[float, float],
    route_day_minutes: float,
    exploration_band: float,
    seed: int,
    replicate: int,
) -> list[SimCandidate]:
    if policy == "roundRobin":
        return sorted(pool, key=lambda c: c.retailer_id)[:target_size]
    if policy == "distanceOnly":
        remaining = sorted(pool, key=lambda c: c.retailer_id)
        chosen: list[SimCandidate] = []
        position = depot
        while remaining and len(chosen) < target_size:
            nearest = min(
                remaining,
                key=lambda c: (
                    haversine_km(
                        position[0], position[1], c.latitude, c.longitude
                    ),
                    c.retailer_id,
                ),
            )
            chosen.append(nearest)
            remaining.remove(nearest)
            position = (nearest.latitude, nearest.longitude)
        return chosen
    if policy == "priorityOnly":
        scored = [
            score_candidate(candidate.to_candidate(distance_km=0.0))
            for candidate in pool
        ]
        scored.sort(key=lambda row: (-row.adjusted_score, row.retailer_id))
        by_id = {candidate.retailer_id: candidate for candidate in pool}
        return [by_id[row.retailer_id] for row in scored[:target_size]]
    if policy == "priorityRouting":
        return _greedy_by_score(
            pool,
            target_size=target_size,
            depot=depot,
            route_day_minutes=route_day_minutes,
            exploration_every=None,
            exploration_band=exploration_band,
            seed=seed,
        )
    if policy == "priorityRoutingExploration":
        return _greedy_by_score(
            pool,
            target_size=target_size,
            depot=depot,
            route_day_minutes=route_day_minutes,
            exploration_every=EXPLORATION_EVERY,
            exploration_band=exploration_band,
            seed=seed * 1000 + replicate,
        )
    raise ValueError(f"unknown policy: {policy}")


def simulate_policies(
    candidates: Sequence[SimCandidate],
    *,
    target_size: int,
    seed: int,
    replicates: int = 30,
    route_day_minutes: float = DEFAULT_ROUTE_DAY_MINUTES,
    depot: tuple[float, float] | None = None,
    realised_ratios: Sequence[float] = (),
    policies: Sequence[str] = POLICIES,
    exploration_band: float = EXPLORATION_SCORE_BAND,
) -> RoutePolicySimulation:
    if replicates <= 0:
        raise ValueError("replicates must be positive")
    pool = sorted(candidates, key=lambda candidate: candidate.retailer_id)
    origin = depot or (
        statistics.fmean(candidate.latitude for candidate in pool) if pool else 0.0,
        statistics.fmean(candidate.longitude for candidate in pool) if pool else 0.0,
    )
    comparisons: dict[str, PolicyComparison] = {}
    outcomes_by_policy: dict[str, list[PolicyOutcome]] = {
        policy: [] for policy in policies
    }
    benchmark_methods: dict[str, int] = {}
    benchmark_beaten_counts: list[int] = []
    benchmark_is_exact = True
    for replicate in range(replicates):
        rng = random.Random(seed * 7919 + replicate)
        realised = _draw_realised_values(pool, ratios=realised_ratios, rng=rng)
        selections: dict[str, list[SimCandidate]] = {}
        pending: dict[str, dict[str, Any]] = {}
        for policy in policies:
            chosen = _policy_selection(
                policy,
                pool,
                target_size=target_size,
                depot=origin,
                route_day_minutes=route_day_minutes,
                exploration_band=exploration_band,
                seed=seed,
                replicate=replicate,
            )
            ordered = _best_order(chosen, origin)
            selections[policy] = ordered
            days, travel = _route_days(ordered, origin, route_day_minutes)
            realised_value = sum(realised[c.retailer_id] for c in ordered)
            expected_value = sum(c.expected_value_rm for c in ordered)
            pending[policy] = {
                "chosen": tuple(c.retailer_id for c in ordered),
                "expected_value_rm": expected_value,
                "realised_value_rm": realised_value,
                "route_days": days,
                "expected_per_day": _value_per_day([expected_value], days),
                "realised_per_day": _value_per_day([realised_value], days),
                "service_minutes": sum(c.service_minutes for c in ordered),
                "travel_minutes": travel,
            }
        benchmark = _hindsight_benchmark(
            pool,
            realised,
            target_size=target_size,
            route_day_minutes=route_day_minutes,
            depot=origin,
            compared_selections=[selections[policy] for policy in policies],
        )
        benchmark_methods[benchmark["method"]] = (
            benchmark_methods.get(benchmark["method"], 0) + 1
        )
        benchmark_beaten_counts.append(benchmark["beatenByComparedPolicies"])
        benchmark_is_exact = benchmark_is_exact and bool(benchmark["isExact"])
        for policy in policies:
            row = pending[policy]
            outcomes_by_policy[policy].append(
                PolicyOutcome(
                    policy=policy,
                    replicate=replicate,
                    regret_per_day=max(
                        0.0, benchmark["valuePerDay"] - row["realised_per_day"]
                    ),
                    **row,
                )
            )
    for policy in policies:
        comparisons[policy] = _summarise(
            policy, outcomes_by_policy[policy], pool
        )
    return RoutePolicySimulation(
        seed=seed,
        replicates=replicates,
        target_size=target_size,
        route_day_minutes=route_day_minutes,
        pool_size=len(pool),
        comparisons=comparisons,
        provenance={
            "evidence": "simulated",
            "policyVersion": POLICY_VERSION,
            "realisationModel": (
                "seeded bootstrap of realised over expected ratios from the "
                "frozen evaluation dataset"
            ),
            "ratioCatalogueSize": len(realised_ratios),
            "degenerateNoRatioCatalogue": not realised_ratios,
            "benchmarkMethods": dict(sorted(benchmark_methods.items())),
            "benchmarkIsExact": benchmark_is_exact,
            "benchmarkBeatenByComparedPolicies": sum(benchmark_beaten_counts),
            "benchmarkGuarantee": (
                "exact for service time plus nearest-neighbour sequencing from "
                "the depot, the same route-day convention every policy is "
                "priced under; not a travelling-salesman optimum"
                if benchmark_is_exact
                else "the benchmark is at least the best selection any compared "
                "policy made on the same draw, and otherwise a best-known "
                "feasible hindsight selection, not a proven optimum"
            ),
            "benchmarkComparedPolicyFloor": True,
            "explorationScoreBand": exploration_band,
            "explorationEveryNthPick": EXPLORATION_EVERY,
        },
    )


def _summarise(
    policy: str,
    outcomes: Sequence[PolicyOutcome],
    pool: Sequence[SimCandidate],
) -> PolicyComparison:
    if not outcomes:
        return PolicyComparison(
            policy=policy,
            replicates=0,
            mean_realised_per_day=None,
            mean_benchmark_gap_per_day=None,
            min_realised_per_day=None,
            max_realised_per_day=None,
            mean_retailers_selected=None,
            distinct_retailers_selected=0,
            starved_retailers_selected=0,
            mean_travel_minutes=None,
        )
    selected_ids = {rid for outcome in outcomes for rid in outcome.chosen}
    starved_ids = {
        candidate.retailer_id
        for candidate in pool
        if candidate.days_since_last_visit is None
        or candidate.days_since_last_visit > 42
    }
    return PolicyComparison(
        policy=policy,
        replicates=len(outcomes),
        mean_realised_per_day=round(
            statistics.fmean(row.realised_per_day for row in outcomes), 4
        ),
        mean_benchmark_gap_per_day=round(
            statistics.fmean(row.regret_per_day for row in outcomes), 4
        ),
        min_realised_per_day=round(
            min(row.realised_per_day for row in outcomes), 4
        ),
        max_realised_per_day=round(
            max(row.realised_per_day for row in outcomes), 4
        ),
        mean_retailers_selected=round(
            statistics.fmean(len(row.chosen) for row in outcomes), 4
        ),
        distinct_retailers_selected=len(selected_ids),
        starved_retailers_selected=len(selected_ids & starved_ids),
        mean_travel_minutes=round(
            statistics.fmean(row.travel_minutes for row in outcomes), 4
        ),
        outcomes=list(outcomes),
    )


def _text_of(value: Any) -> str:
    return "" if value is None else str(value).strip()


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


def realised_ratio_catalogue_from_snapshot(
    snapshot: Mapping[str, Sequence[Mapping[str, Any]]],
) -> list[float]:
    series: dict[tuple[str, str], list[tuple[date, float]]] = {}
    for raw in snapshot.get("orders", []):
        order = dict(raw)
        order_date = _as_date(
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        retailer_id = _text_of(
            order.get("retailerId") or order.get("retailer_id")
        )
        if order_date is None or not retailer_id:
            continue
        for raw_item in authoritative_order_items(order):
            product_id = _text_of(raw_item.get("productId"))
            quantity = float(raw_item.get("qty") or 0.0)
            price = float(raw_item.get("price") or 0.0)
            if not product_id or quantity <= 0:
                continue
            series.setdefault((retailer_id, product_id), []).append(
                (order_date, quantity * max(0.0, price))
            )
    rows: list[dict[str, float]] = []
    for entries in series.values():
        entries.sort()
        for index in range(1, len(entries)):
            expected = entries[index - 1][1]
            realised = entries[index][1]
            if expected > 0:
                rows.append(
                    {"expectedValueRm": expected, "realisedValueRm": realised}
                )
    return realised_ratio_catalogue(rows)


KUCHING_GEOGRAPHY: tuple[float, float] = (1.5535, 110.3592)
KUCHING_SPREAD_DEGREES = 0.04


def kuching_coordinates(index: int, total: int) -> tuple[float, float]:
    if total <= 0:
        return KUCHING_GEOGRAPHY
    columns = max(1, int(math.ceil(math.sqrt(total))))
    row = index // columns
    column = index % columns
    rows = max(1, int(math.ceil(total / columns)))
    latitude = KUCHING_GEOGRAPHY[0] + (
        (row - (rows - 1) / 2) / max(rows, 1) * KUCHING_SPREAD_DEGREES
    )
    longitude = KUCHING_GEOGRAPHY[1] + (
        (column - (columns - 1) / 2) / max(columns, 1) * KUCHING_SPREAD_DEGREES
    )
    return round(latitude, 6), round(longitude, 6)


__all__ = [
    "EXPLORATION_EVERY",
    "EXPLORATION_SCORE_BAND",
    "KUCHING_GEOGRAPHY",
    "KUCHING_SPREAD_DEGREES",
    "POLICIES",
    "PolicyComparison",
    "PolicyOutcome",
    "RoutePolicySimulation",
    "SimCandidate",
    "kuching_coordinates",
    "realised_ratio_catalogue",
    "realised_ratio_catalogue_from_snapshot",
    "simulate_policies",
]

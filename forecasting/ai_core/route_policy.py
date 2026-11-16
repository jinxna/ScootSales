from __future__ import annotations

import math
import random
from dataclasses import dataclass, replace
from typing import Any, Sequence

POLICY_VERSION = "route-opportunity/1.0.0"

FALLBACK_SPEED_KMH = 28.0
ROAD_FACTOR = 1.3
DEFAULT_ROUTE_DAY_MINUTES = 540.0
DEFAULT_SERVICE_MINUTES = 20.0

UNCERTAINTY_WEIGHT = 0.25
COVERAGE_BOOST = 0.15
COVERAGE_STARVATION_DAYS = 42.0

EXPLOIT_FRACTION = 0.8
SWAP_BAND = 0.15
SOFTMAX_TEMPERATURE_FRACTION = 0.35
MIN_EXPLORE_SLOTS = 1
MAX_EXPLORE_SLOTS = 3
COVERAGE_GUARD_FRACTION = 0.25

PLANNING_HORIZON_DAYS = 7.0
DEFAULT_INTERVAL_RELATIVE_WIDTH = 0.5


def haversine_km(
    latitude_a: float, longitude_a: float, latitude_b: float, longitude_b: float
) -> float:
    radius = 6371.0088
    phi_a = math.radians(latitude_a)
    phi_b = math.radians(latitude_b)
    delta_phi = math.radians(latitude_b - latitude_a)
    delta_lambda = math.radians(longitude_b - longitude_a)
    a = (
        math.sin(delta_phi / 2) ** 2
        + math.cos(phi_a) * math.cos(phi_b) * math.sin(delta_lambda / 2) ** 2
    )
    return 2 * radius * math.asin(min(1.0, math.sqrt(a)))


def travel_minutes(
    distance_km: float, *, speed_kmh: float = FALLBACK_SPEED_KMH
) -> float:
    if not math.isfinite(distance_km) or distance_km <= 0:
        return 0.0
    return (distance_km * ROAD_FACTOR) / speed_kmh * 60.0


@dataclass(frozen=True)
class RetailerVisitCandidate:
    retailer_id: str
    retailer_name: str = ""
    expected_order_value_rm: float = 0.0
    forecast_relative_uncertainty: float = 0.0
    service_minutes: float | None = None
    distance_km: float | None = None
    days_since_last_visit: float | None = None
    observed_periods: int = 0
    cold_start: bool = False

    @property
    def is_starved(self) -> bool:
        return (
            self.days_since_last_visit is None
            or self.days_since_last_visit > COVERAGE_STARVATION_DAYS
        )


@dataclass(frozen=True)
class ScoredCandidate:
    candidate: RetailerVisitCandidate
    expected_value_rm: float
    uncertainty_rm: float
    adjusted_value_rm: float
    service_minutes: float
    travel_minutes: float
    route_time_days: float
    opportunity_per_route_day: float
    coverage_boost: float
    adjusted_score: float
    rank: int = 0
    selection_probability: float = 0.0
    exploit_or_explore: str = "not_selected"
    chosen: bool = False

    @property
    def retailer_id(self) -> str:
        return self.candidate.retailer_id

    def score_components(self) -> dict[str, Any]:
        return {
            "expectedValueRm": round(self.expected_value_rm, 4),
            "uncertaintyRm": round(self.uncertainty_rm, 4),
            "adjustedValueRm": round(self.adjusted_value_rm, 4),
            "serviceMinutes": round(self.service_minutes, 2),
            "travelMinutes": round(self.travel_minutes, 2),
            "routeTimeDays": round(self.route_time_days, 6),
            "opportunityPerRouteDay": round(self.opportunity_per_route_day, 4),
            "coverageBoost": round(self.coverage_boost, 4),
            "adjustedScore": round(self.adjusted_score, 4),
            "distanceKm": (
                None
                if self.candidate.distance_km is None
                else round(self.candidate.distance_km, 3)
            ),
            "daysSinceLastVisit": self.candidate.days_since_last_visit,
            "observedPeriods": self.candidate.observed_periods,
            "coldStart": self.candidate.cold_start,
        }


def opportunity_per_route_day(
    expected_value_rm: float,
    *,
    service_minutes: float,
    travel_minutes_value: float,
    route_day_minutes: float = DEFAULT_ROUTE_DAY_MINUTES,
) -> float:
    if route_day_minutes <= 0:
        raise ValueError("route_day_minutes must be positive")
    consumed_days = (service_minutes + travel_minutes_value) / route_day_minutes
    if consumed_days <= 0:
        return 0.0
    return max(0.0, expected_value_rm) / consumed_days


def route_value_per_day(values_rm: Sequence[float], *, route_days: float) -> float:
    if route_days <= 0:
        return 0.0
    return max(0.0, sum(values_rm)) / route_days


def score_candidate(
    candidate: RetailerVisitCandidate,
    *,
    route_day_minutes: float = DEFAULT_ROUTE_DAY_MINUTES,
) -> ScoredCandidate:
    expected = max(0.0, float(candidate.expected_order_value_rm))
    relative = max(0.0, float(candidate.forecast_relative_uncertainty))
    uncertainty = expected * relative
    adjusted_value = expected + UNCERTAINTY_WEIGHT * uncertainty

    service = (
        float(candidate.service_minutes)
        if candidate.service_minutes is not None and candidate.service_minutes > 0
        else DEFAULT_SERVICE_MINUTES
    )
    travel = (
        0.0
        if candidate.distance_km is None
        else travel_minutes(candidate.distance_km)
    )
    consumed_days = (service + travel) / route_day_minutes
    base = (adjusted_value / consumed_days) if consumed_days > 0 else 0.0

    boost = 0.0
    days = candidate.days_since_last_visit
    if days is None:
        boost = COVERAGE_BOOST
    elif days > 0:
        boost = COVERAGE_BOOST * min(1.0, days / COVERAGE_STARVATION_DAYS)
    score = base * (1.0 + boost)

    return ScoredCandidate(
        candidate=candidate,
        expected_value_rm=expected,
        uncertainty_rm=uncertainty,
        adjusted_value_rm=adjusted_value,
        service_minutes=service,
        travel_minutes=travel,
        route_time_days=consumed_days,
        opportunity_per_route_day=(
            expected / consumed_days if consumed_days > 0 else 0.0
        ),
        coverage_boost=boost,
        adjusted_score=score,
    )


def softmax_probabilities(scores: Sequence[float], temperature: float) -> list[float]:
    if not scores:
        return []
    if temperature <= 0:
        best = max(scores)
        winners = [1.0 if score >= best else 0.0 for score in scores]
        total = sum(winners)
        return [value / total for value in winners]
    peak = max(scores)
    weights = [math.exp((score - peak) / temperature) for score in scores]
    total = sum(weights)
    if total <= 0:
        return [1.0 / len(scores)] * len(scores)
    return [weight / total for weight in weights]


@dataclass(frozen=True)
class SelectionResult:
    policy_version: str
    seed: int
    target_size: int
    scored: tuple[ScoredCandidate, ...]

    @property
    def chosen(self) -> tuple[ScoredCandidate, ...]:
        return tuple(row for row in self.scored if row.chosen)

    def to_rows(self, *, week_key: str, salesman_uid: str) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for row in self.scored:
            rows.append(
                {
                    "policyVersion": self.policy_version,
                    "seed": self.seed,
                    "weekKey": week_key,
                    "salesmanUid": salesman_uid,
                    "targetSize": self.target_size,
                    "candidate": row.retailer_id,
                    "retailerName": row.candidate.retailer_name,
                    "score": round(row.adjusted_score, 6),
                    "rank": row.rank,
                    "selectionProbability": round(row.selection_probability, 6),
                    "exploitOrExplore": row.exploit_or_explore,
                    "chosen": row.chosen,
                    "components": row.score_components(),
                }
            )
        return rows


def _exploration_pool(
    ordered: Sequence[ScoredCandidate], exploit_slots: int, size: int
) -> list[ScoredCandidate]:
    if not ordered:
        return []
    cutoff_index = min(size, len(ordered)) - 1
    cutoff = ordered[cutoff_index].adjusted_score
    band_floor = cutoff * (1.0 - SWAP_BAND)
    return [
        row
        for row in ordered[exploit_slots:]
        if row.adjusted_score >= band_floor
    ]


def select_route_candidates(
    candidates: Sequence[RetailerVisitCandidate],
    *,
    target_size: int,
    seed: int,
    policy_version: str = POLICY_VERSION,
    route_day_minutes: float = DEFAULT_ROUTE_DAY_MINUTES,
    explore_slots: int | None = None,
) -> SelectionResult:
    if target_size <= 0:
        raise ValueError("target_size must be positive")
    scored = [
        score_candidate(row, route_day_minutes=route_day_minutes)
        for row in candidates
    ]
    ordered = sorted(
        scored, key=lambda row: (-row.adjusted_score, row.retailer_id)
    )
    if len(ordered) > 1:
        top_score = ordered[0].adjusted_score
        if top_score == 0.0:
            ordered = sorted(
                scored, key=lambda row: row.retailer_id
            )

    size = max(0, min(target_size, len(ordered)))
    slots = _explore_slot_count(size, explore_slots)
    exploit_slots = max(0, size - slots)
    pool = _exploration_pool(ordered, exploit_slots, size)
    pool_probabilities: dict[str, float] = {}
    if pool:
        pool_scores = [row.adjusted_score for row in pool]
        mean_score = sum(pool_scores) / len(pool_scores)
        temperature = max(
            1e-9, SOFTMAX_TEMPERATURE_FRACTION * max(abs(mean_score), 1e-6)
        )
        for row, probability in zip(
            pool, softmax_probabilities(pool_scores, temperature)
        ):
            pool_probabilities[row.retailer_id] = probability

    chosen_ids: list[str] = [row.retailer_id for row in ordered[:exploit_slots]]
    explore_ids: set[str] = set()
    if pool and slots > 0:
        draw = random.Random(seed)
        available = list(range(len(pool)))
        probabilities = [pool_probabilities[row.retailer_id] for row in pool]
        for _ in range(slots):
            weights = [probabilities[index] for index in available]
            total = sum(weights)
            if total <= 0:
                break
            position = draw.random() * total
            cursor = 0.0
            pick = available[-1]
            for index, weight in zip(available, weights):
                cursor += weight
                if position <= cursor:
                    pick = index
                    break
            available.remove(pick)
            retailer_id = pool[pick].retailer_id
            if retailer_id not in chosen_ids:
                chosen_ids.append(retailer_id)
                explore_ids.add(retailer_id)

    promotion_limit = max(1, int(math.ceil(size * COVERAGE_GUARD_FRACTION)))
    promotions = 0
    starved_ranked = sorted(
        (row for row in ordered if row.candidate.is_starved),
        key=lambda row: (-row.adjusted_score, row.retailer_id),
    )
    for row in starved_ranked:
        if promotions >= promotion_limit:
            break
        if row.retailer_id in chosen_ids:
            continue
        displaceable = [
            retailer_id
            for retailer_id in chosen_ids
            if retailer_id not in explore_ids
        ]
        if not displaceable:
            break
        chosen_ids.remove(displaceable[-1])
        chosen_ids.append(row.retailer_id)
        promotions += 1

    final: list[ScoredCandidate] = []
    for index, row in enumerate(ordered):
        chosen = row.retailer_id in chosen_ids
        if chosen and row.retailer_id in explore_ids:
            marker = "explore"
        elif chosen:
            marker = "exploit"
        else:
            marker = "not_selected"
        probability = (
            1.0 if marker == "exploit" else pool_probabilities.get(row.retailer_id, 0.0)
        )
        final.append(
            replace(
                row,
                rank=index + 1,
                selection_probability=probability,
                exploit_or_explore=marker,
                chosen=chosen,
            )
        )
    return SelectionResult(
        policy_version=policy_version,
        seed=seed,
        target_size=size,
        scored=tuple(final),
    )


def _explore_slot_count(size: int, explore_slots: int | None) -> int:
    if size <= 0:
        return 0
    if explore_slots is not None:
        return max(0, min(explore_slots, size))
    natural = size - int(math.floor(size * EXPLOIT_FRACTION))
    bounded = max(MIN_EXPLORE_SLOTS, min(MAX_EXPLORE_SLOTS, natural))
    return max(0, min(bounded, size))


__all__ = [
    "COVERAGE_BOOST",
    "COVERAGE_STARVATION_DAYS",
    "DEFAULT_INTERVAL_RELATIVE_WIDTH",
    "DEFAULT_ROUTE_DAY_MINUTES",
    "DEFAULT_SERVICE_MINUTES",
    "EXPLOIT_FRACTION",
    "FALLBACK_SPEED_KMH",
    "MAX_EXPLORE_SLOTS",
    "MIN_EXPLORE_SLOTS",
    "PLANNING_HORIZON_DAYS",
    "POLICY_VERSION",
    "ROAD_FACTOR",
    "RetailerVisitCandidate",
    "ScoredCandidate",
    "SelectionResult",
    "haversine_km",
    "opportunity_per_route_day",
    "route_value_per_day",
    "score_candidate",
    "select_route_candidates",
    "softmax_probabilities",
    "travel_minutes",
]

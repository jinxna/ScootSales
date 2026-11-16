from __future__ import annotations

import hashlib
import statistics
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any, Iterable, Mapping, Sequence

from .calendar import as_kuching_date
from .models import require_supported_number
from .route_policy import (
    DEFAULT_ROUTE_DAY_MINUTES,
    POLICY_VERSION,
    RetailerVisitCandidate,
    ScoredCandidate,
    haversine_km,
    select_route_candidates,
)
from .opportunity import (
    EXPECTED_ORDER_VALUE_VERSION,
    RetailerOpportunity,
)

RETAILER_RANKING_VERSION = "retailer-ranking/1.1.1"
COVERAGE_BASIS_LAST_ORDER = "last_observed_order"
COVERAGE_BASIS_VISIT = "last_visit"
DEFAULT_WEEK_CAPACITY = 36
DISTANCE_PRECISION = 4


@dataclass(frozen=True)
class RetailerEvidence:
    retailer_id: str
    retailer_name: str = ""
    salesman_uid: str = ""
    salesman_code: str = ""
    branch_id: str = ""
    expected_order_value_rm: float = 0.0
    forecast_relative_uncertainty: float = 0.0
    service_minutes: float | None = None
    days_since_last_visit: float | None = None
    observed_periods: int = 0
    cold_start: bool = False
    latitude: float | None = None
    longitude: float | None = None
    is_demo: bool = False
    coverage_basis: str = COVERAGE_BASIS_LAST_ORDER
    forecast_pair_count: int = 0
    observed_baseline_pair_count: int = 0
    expected_order_value_version: str = EXPECTED_ORDER_VALUE_VERSION
    supporting_issue_keys: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        require_supported_number(
            self.expected_order_value_rm, "expected_order_value_rm"
        )
        require_supported_number(
            self.forecast_relative_uncertainty, "forecast_relative_uncertainty"
        )
        for field_name in ("service_minutes", "days_since_last_visit"):
            value = getattr(self, field_name)
            if value is not None:
                require_supported_number(value, field_name)
        for field_name in ("latitude", "longitude"):
            value = getattr(self, field_name)
            if value is not None:
                require_supported_number(value, field_name)

    @property
    def scope_key(self) -> str:
        return self.salesman_uid or self.salesman_code or "unassigned"


@dataclass(frozen=True)
class RankedRetailer:
    retailer_id: str
    retailer_name: str
    rank: int
    score: float
    expected_order_value_rm: float
    opportunity_per_route_day: float
    route_time_days: float
    travel_minutes: float
    service_minutes: float
    days_since_last_visit: float | None
    chosen: bool
    exploit_or_explore: str
    selection_probability: float
    supporting_issue_keys: tuple[str, ...]
    is_demo: bool
    expected_order_value_version: str = EXPECTED_ORDER_VALUE_VERSION
    forecast_pair_count: int = 0
    observed_baseline_pair_count: int = 0
    coverage_basis: str = COVERAGE_BASIS_LAST_ORDER
    components: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "retailerId": self.retailer_id,
            "retailerName": self.retailer_name,
            "rank": self.rank,
            "score": self.score,
            "expectedOrderValueRm": self.expected_order_value_rm,
            "opportunityPerRouteDay": self.opportunity_per_route_day,
            "routeTimeDays": self.route_time_days,
            "travelMinutes": self.travel_minutes,
            "serviceMinutes": self.service_minutes,
            "daysSinceLastVisit": self.days_since_last_visit,
            "chosen": self.chosen,
            "exploitOrExplore": self.exploit_or_explore,
            "selectionProbability": self.selection_probability,
            "supportingIssueKeys": list(self.supporting_issue_keys),
            "isDemo": self.is_demo,
            "expectedOrderValueVersion": self.expected_order_value_version,
            "forecastPairCount": self.forecast_pair_count,
            "observedBaselinePairCount": self.observed_baseline_pair_count,
            "coverageBasis": self.coverage_basis,
            "components": dict(self.components),
        }


@dataclass(frozen=True)
class SalesmanRanking:
    scope_key: str
    salesman_uid: str
    branch_id: str
    week_key: str
    policy_version: str
    seed: int
    target_size: int
    ranked: tuple[RankedRetailer, ...]
    decision_rows: tuple[dict[str, Any], ...]
    is_demo: bool

    @property
    def chosen(self) -> tuple[RankedRetailer, ...]:
        return tuple(row for row in self.ranked if row.chosen)

    def to_read_model(
        self,
        *,
        week_start: date,
        salesman_code: str,
        run_id: str,
        generated_at: Any,
        coverage_basis: str = COVERAGE_BASIS_LAST_ORDER,
    ) -> dict[str, Any]:
        return {
            "rankingId": ranking_id(self.scope_key, self.week_key),
            "status": "active",
            "scopeKey": self.scope_key,
            "salesmanUid": self.salesman_uid,
            "salesmanCode": salesman_code,
            "branchId": self.branch_id,
            "weekKey": self.week_key,
            "weekStart": week_start,
            "asOf": week_start,
            "sourceRunId": run_id,
            "policyVersion": self.policy_version,
            "rankingVersion": RETAILER_RANKING_VERSION,
            "expectedOrderValueVersion": EXPECTED_ORDER_VALUE_VERSION,
            "coverageBasis": coverage_basis,
            "seed": self.seed,
            "targetSize": self.target_size,
            "retailerCount": len(self.ranked),
            "chosenCount": len(self.chosen),
            "isDemo": self.is_demo,
            "ranking": [row.to_dict() for row in self.ranked],
            "decisionLog": [dict(row) for row in self.decision_rows],
            "generatedAt": generated_at,
            "updatedAt": generated_at,
        }

    def to_dict(self) -> dict[str, Any]:
        return {
            "scopeKey": self.scope_key,
            "salesmanUid": self.salesman_uid,
            "branchId": self.branch_id,
            "weekKey": self.week_key,
            "policyVersion": self.policy_version,
            "seed": self.seed,
            "targetSize": self.target_size,
            "retailerCount": len(self.ranked),
            "chosenCount": len(self.chosen),
            "isDemo": self.is_demo,
            "ranking": [row.to_dict() for row in self.ranked],
            "decisionRows": [dict(row) for row in self.decision_rows],
        }


def week_key_for(week_start: date) -> str:
    year, week, _ = week_start.isocalendar()
    return f"{year}-W{week:02d}"


def ranking_id(scope_key: str, week_key: str) -> str:
    digest = hashlib.sha256(f"{scope_key}::{week_key}".encode("utf-8")).hexdigest()
    return f"rank_{digest[:24]}"


def decision_log_id(scope_key: str, week_key: str, retailer_id: str) -> str:
    digest = hashlib.sha256(
        f"{scope_key}::{week_key}::{retailer_id}".encode("utf-8")
    ).hexdigest()
    return f"pol_{digest[:24]}"


def branch_centroid(
    evidence: Iterable[RetailerEvidence],
) -> tuple[float, float] | None:
    located = [
        row
        for row in evidence
        if row.latitude is not None and row.longitude is not None
    ]
    if not located:
        return None
    return (
        statistics.fmean(row.latitude for row in located),  # type: ignore[arg-type]
        statistics.fmean(row.longitude for row in located),  # type: ignore[arg-type]
    )


def _distance_from(
    row: RetailerEvidence, origin: tuple[float, float] | None
) -> float | None:
    if origin is None or row.latitude is None or row.longitude is None:
        return None
    return round(
        haversine_km(origin[0], origin[1], row.latitude, row.longitude),
        DISTANCE_PRECISION,
    )


def build_rankings(
    evidence: Sequence[RetailerEvidence],
    *,
    week_start: date,
    seed: int,
    target_size: int = DEFAULT_WEEK_CAPACITY,
    route_day_minutes: float = DEFAULT_ROUTE_DAY_MINUTES,
    policy_version: str = POLICY_VERSION,
    origins_by_scope: Mapping[str, tuple[float, float] | None] | None = None,
) -> tuple[SalesmanRanking, ...]:
    if target_size <= 0:
        raise ValueError("target_size must be positive")
    groups: dict[str, list[RetailerEvidence]] = {}
    for row in sorted(evidence, key=lambda item: item.retailer_id):
        groups.setdefault(row.scope_key, []).append(row)

    week_key = week_key_for(week_start)
    rankings: list[SalesmanRanking] = []
    for scope_key in sorted(groups):
        rows = groups[scope_key]
        origin = (
            origins_by_scope.get(scope_key)
            if origins_by_scope is not None and scope_key in origins_by_scope
            else branch_centroid(rows)
        )
        candidates = [
            RetailerVisitCandidate(
                retailer_id=row.retailer_id,
                retailer_name=row.retailer_name,
                expected_order_value_rm=row.expected_order_value_rm,
                forecast_relative_uncertainty=row.forecast_relative_uncertainty,
                service_minutes=row.service_minutes,
                distance_km=_distance_from(row, origin),
                days_since_last_visit=row.days_since_last_visit,
                observed_periods=row.observed_periods,
                cold_start=row.cold_start,
            )
            for row in rows
        ]
        scope_seed = _scope_seed(seed, scope_key)
        selection = select_route_candidates(
            candidates,
            target_size=target_size,
            seed=scope_seed,
            policy_version=policy_version,
            route_day_minutes=route_day_minutes,
        )
        by_id = {row.retailer_id: row for row in rows}
        ranked = tuple(
            _to_ranked(scored, by_id[scored.retailer_id])
            for scored in selection.scored
        )
        rankings.append(
            SalesmanRanking(
                scope_key=scope_key,
                salesman_uid=rows[0].salesman_uid,
                branch_id=rows[0].branch_id,
                week_key=week_key,
                policy_version=selection.policy_version,
                seed=scope_seed,
                target_size=selection.target_size,
                ranked=ranked,
                decision_rows=tuple(
                    selection.to_rows(
                        week_key=week_key, salesman_uid=rows[0].salesman_uid
                    )
                ),
                is_demo=all(row.is_demo for row in rows),
            )
        )
    return tuple(rankings)


def _scope_seed(seed: int, scope_key: str) -> int:
    digest = hashlib.sha256(f"{seed}::{scope_key}".encode("utf-8")).hexdigest()
    return int(digest[:8], 16)


def _to_ranked(
    scored: ScoredCandidate, evidence: RetailerEvidence
) -> RankedRetailer:
    return RankedRetailer(
        retailer_id=scored.retailer_id,
        retailer_name=evidence.retailer_name or scored.retailer_id,
        rank=scored.rank,
        score=round(scored.adjusted_score, 4),
        expected_order_value_rm=round(scored.expected_value_rm, 4),
        opportunity_per_route_day=round(scored.opportunity_per_route_day, 4),
        route_time_days=round(scored.route_time_days, 6),
        travel_minutes=round(scored.travel_minutes, 2),
        service_minutes=round(scored.service_minutes, 2),
        days_since_last_visit=evidence.days_since_last_visit,
        chosen=scored.chosen,
        exploit_or_explore=scored.exploit_or_explore,
        selection_probability=round(scored.selection_probability, 6),
        supporting_issue_keys=evidence.supporting_issue_keys,
        is_demo=evidence.is_demo,
        expected_order_value_version=evidence.expected_order_value_version,
        forecast_pair_count=evidence.forecast_pair_count,
        observed_baseline_pair_count=evidence.observed_baseline_pair_count,
        coverage_basis=evidence.coverage_basis,
        components=scored.score_components(),
    )


def evidence_from_opportunities(
    opportunities: Sequence[RetailerOpportunity],
    *,
    retailer_records: Mapping[str, Any],
    last_contact_by_retailer: Mapping[str, Any] | None = None,
    service_minutes_by_retailer: Mapping[str, float] | None = None,
    as_of: date | None = None,
    coverage_basis: str = COVERAGE_BASIS_LAST_ORDER,
) -> tuple[RetailerEvidence, ...]:
    by_id = {row.retailer_id: row for row in opportunities}
    records = {
        str(key): value
        for key, value in retailer_records.items()
        if str(key).strip()
    }
    retired = {key for key, value in records.items() if value.get("isRetired")}
    evidence: list[RetailerEvidence] = []
    for retailer_id in sorted((set(records) | set(by_id)) - retired):
        record = records.get(retailer_id) or {}
        opportunity = by_id.get(retailer_id)
        try:
            row = RetailerEvidence(
                retailer_id=retailer_id,
                retailer_name=str(
                    _record_text(record, ("retailerName", "name", "retailer_name"))
                ),
                salesman_uid=str(_record_text(record, ("salesmanUid",))),
                salesman_code=str(_record_text(record, ("salesmanCode",))),
                branch_id=str(_record_text(record, ("branchId",))),
                expected_order_value_rm=(
                    0.0 if opportunity is None else opportunity.expected_order_value_rm
                ),
                forecast_relative_uncertainty=(
                    0.0 if opportunity is None else opportunity.relative_uncertainty
                ),
                service_minutes=(
                    None
                    if not service_minutes_by_retailer
                    else service_minutes_by_retailer.get(retailer_id)
                ),
                days_since_last_visit=_days_since(
                    (last_contact_by_retailer or {}).get(retailer_id), as_of
                ),
                observed_periods=(
                    0
                    if opportunity is None
                    else max(
                        (pair.observed_periods for pair in opportunity.pairs),
                        default=0,
                    )
                ),
                cold_start=(
                    True
                    if opportunity is None
                    else opportunity.forecast_pair_count == 0
                ),
                latitude=_record_number(record, ("latitude", "lat")),
                longitude=_record_number(record, ("longitude", "lng", "lon")),
                is_demo=bool(record.get("isDemo")),
                coverage_basis=coverage_basis,
                forecast_pair_count=(
                    0 if opportunity is None else opportunity.forecast_pair_count
                ),
                observed_baseline_pair_count=(
                    0
                    if opportunity is None
                    else opportunity.observed_baseline_pair_count
                ),
            )
        except (TypeError, ValueError) as error:
            raise ValueError(f"retailer {retailer_id!r}: {error}") from error
        evidence.append(row)
    return tuple(evidence)


def _record_text(record: Mapping[str, Any], fields: Sequence[str]) -> str:
    for field in fields:
        value = record.get(field)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return ""


def _record_number(record: Mapping[str, Any], fields: Sequence[str]) -> float | None:
    coordinate_limits = {
        "latitude": 90.0,
        "lat": 90.0,
        "longitude": 180.0,
        "lng": 180.0,
        "lon": 180.0,
    }
    coordinate_limit = next(
        (coordinate_limits[field] for field in fields if field in coordinate_limits),
        None,
    )
    for field in fields:
        value = record.get(field)
        if value is None:
            continue
        try:
            number = require_supported_number(value, f"retailer {field}")
        except (TypeError, ValueError, OverflowError):
            continue
        if coordinate_limit is not None and abs(number) > coordinate_limit:
            continue
        if number == 0.0 and field in {"latitude", "longitude", "lng", "lon", "lat"}:
            continue
        return number
    return None


def _days_since(value: Any, as_of: date | None) -> float | None:
    if value is None or as_of is None:
        return None
    if isinstance(value, datetime):
        contact = as_kuching_date(value)
    elif isinstance(value, date):
        contact = value
    else:
        try:
            contact = as_kuching_date(
                datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            )
        except ValueError:
            return None
    return max(0.0, float((as_of - contact).days))


__all__ = [
    "COVERAGE_BASIS_LAST_ORDER",
    "COVERAGE_BASIS_VISIT",
    "DEFAULT_WEEK_CAPACITY",
    "RETAILER_RANKING_VERSION",
    "RankedRetailer",
    "RetailerEvidence",
    "SalesmanRanking",
    "branch_centroid",
    "build_rankings",
    "decision_log_id",
    "evidence_from_opportunities",
    "ranking_id",
    "week_key_for",
]

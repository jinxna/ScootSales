from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Iterable, Mapping, Sequence

from forecasting.ai_core import week_start
from forecasting.ai_core.calendar import as_kuching_date

_CLOSED_STATUSES = frozenset({"resolved", "dismissed", "ignored", "suppressed"})


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _moment(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, date):
        parsed = datetime.combine(value, time.min)
    elif value is None:
        return None
    else:
        to_datetime = getattr(value, "to_datetime", None)
        if callable(to_datetime):
            try:
                converted = to_datetime()
            except Exception:  # noqa: BLE001 - defensive on foreign timestamp types
                converted = None
            if isinstance(converted, datetime):
                parsed = converted
            else:
                return None
        else:
            try:
                parsed = datetime.fromisoformat(
                    str(value).replace("Z", "+00:00")
                )
            except ValueError:
                return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _effective_status(insight: Mapping[str, Any]) -> str:
    workflow_status = _text(insight.get("status")).lower() or "new"
    auto_state = _text(insight.get("autoState")).lower() or "active"
    return "suppressed" if auto_state == "suppressed" else workflow_status


def _is_closed(insight: Mapping[str, Any]) -> bool:
    return _effective_status(insight) in _CLOSED_STATUSES


def _product_from_issue_key(issue_key: str) -> str:
    parts = issue_key.split("::")
    return parts[2].strip() if len(parts) == 3 else ""


@dataclass(frozen=True)
class _Insight:
    issue_key: str
    retailer_id: str
    product_id: str
    is_demo: bool
    detected_at: datetime | None
    closed: bool
    closed_at: datetime | None
    value_at_risk_rm: float


@dataclass(frozen=True)
class _Outcome:
    issue_key: str
    retailer_id: str
    product_id: str
    submitted_at: datetime | None


def _detection_moment(insight: Mapping[str, Any]) -> datetime | None:
    for field_name in ("firstDetected", "createdAt", "detectedAt"):
        moment = _moment(insight.get(field_name))
        if moment is not None:
            return moment
    return None


def _close_moment(insight: Mapping[str, Any]) -> datetime | None:
    for field_name in (
        "resolvedAt",
        "autoSuppressedAt",
        "dismissedAt",
        "suppressedAt",
        "acknowledgedAt",
    ):
        moment = _moment(insight.get(field_name))
        if moment is not None:
            return moment
    latest = insight.get("latestOutcome")
    if isinstance(latest, Mapping):
        moment = _moment(latest.get("submittedAt"))
        if moment is not None:
            return moment
    return None


def _parse_insight(row: Mapping[str, Any]) -> _Insight:
    issue_key = _text(row.get("issueKey"))
    product_id = _text(row.get("productId")) or _product_from_issue_key(issue_key)
    closed = _is_closed(row)
    return _Insight(
        issue_key=issue_key,
        retailer_id=_text(row.get("retailerId")),
        product_id=product_id,
        is_demo=row.get("isDemo") is True,
        detected_at=_detection_moment(row),
        closed=closed,
        closed_at=_close_moment(row) if closed else None,
        value_at_risk_rm=float(row.get("valueAtRiskRm") or 0.0),
    )


def _parse_outcome(row: Mapping[str, Any]) -> _Outcome:
    issue_key = _text(row.get("issueKey"))
    return _Outcome(
        issue_key=issue_key,
        retailer_id=_text(row.get("retailerId")),
        product_id=_product_from_issue_key(issue_key),
        submitted_at=_moment(
            row.get("submittedAt")
            or row.get("createdAt")
            or row.get("clientCreatedAt")
        ),
    )


def _outcome_related(insight: _Insight, outcome: _Outcome) -> bool:
    if insight.issue_key and outcome.issue_key:
        return insight.issue_key == outcome.issue_key
    if not insight.retailer_id or insight.retailer_id != outcome.retailer_id:
        return False
    if insight.product_id and outcome.product_id:
        return insight.product_id == outcome.product_id
    return True


def _percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = fraction * (len(ordered) - 1)
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    weight = rank - low
    return ordered[low] * (1 - weight) + ordered[high] * weight


def _median(values: Sequence[float]) -> float | None:
    return _percentile(values, 0.5)


@dataclass(frozen=True)
class LatencyDistribution:
    label: str
    count: int
    median_days: float | None
    p90_days: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "count": self.count,
            "medianDays": self.median_days,
            "p90Days": self.p90_days,
        }


def _distribution(label: str, values: Sequence[float]) -> LatencyDistribution:
    return LatencyDistribution(
        label=label,
        count=len(values),
        median_days=_median(values),
        p90_days=_percentile(values, 0.9),
    )


@dataclass(frozen=True)
class ResolutionMetrics:
    cohort: str
    total_insights: int
    closed_insights: int
    loop_engaged: int
    loop_closed: int
    resolution_rate: float | None
    insufficient_data: bool
    note: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "cohort": self.cohort,
            "totalInsights": self.total_insights,
            "closedInsights": self.closed_insights,
            "loopEngaged": self.loop_engaged,
            "loopClosed": self.loop_closed,
            "resolutionRate": self.resolution_rate,
            "insufficientData": self.insufficient_data,
            "note": self.note,
        }


@dataclass(frozen=True)
class VarTrendPoint:
    week_start: str
    open_value_at_risk_rm: float
    open_count: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "weekStart": self.week_start,
            "openValueAtRiskRm": round(self.open_value_at_risk_rm, 2),
            "openCount": self.open_count,
        }


@dataclass(frozen=True)
class VarTrend:
    cohort: str
    points: list[VarTrendPoint] = field(default_factory=list)
    undated_insight_count: int = 0
    note: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "cohort": self.cohort,
            "points": [point.to_dict() for point in self.points],
            "undatedInsightCount": self.undated_insight_count,
            "note": self.note,
        }


@dataclass(frozen=True)
class LoopMetricsReport:
    cohort: str
    resolution: ResolutionMetrics
    detection_to_outcome: LatencyDistribution
    outcome_to_close: LatencyDistribution
    var_trend: VarTrend

    def to_dict(self) -> dict[str, Any]:
        return {
            "cohort": self.cohort,
            "resolution": self.resolution.to_dict(),
            "latency": {
                "detectionToOutcome": self.detection_to_outcome.to_dict(),
                "outcomeToClose": self.outcome_to_close.to_dict(),
            },
            "valueAtRiskTrend": self.var_trend.to_dict(),
        }


def _cohort_metrics(
    cohort: str,
    insights: Sequence[_Insight],
    outcomes: Sequence[_Outcome],
    *,
    cutoff: date,
) -> LoopMetricsReport:
    dated_outcomes = [o for o in outcomes if o.submitted_at is not None]

    loop_engaged = 0
    loop_closed = 0
    closed_insights = 0
    detection_to_outcome: list[float] = []
    outcome_to_close: list[float] = []

    for insight in insights:
        if insight.closed:
            closed_insights += 1

        if insight.detected_at is None:
            continue

        related_after = [
            o
            for o in dated_outcomes
            if _outcome_related(insight, o)
            and o.submitted_at >= insight.detected_at
        ]
        if not related_after:
            continue

        loop_engaged += 1
        earliest = min(o.submitted_at for o in related_after)
        detection_to_outcome.append(
            (earliest - insight.detected_at).total_seconds() / 86400.0
        )

        if insight.closed and insight.closed_at is not None:
            in_between = [
                o for o in related_after if o.submitted_at <= insight.closed_at
            ]
            if in_between:
                loop_closed += 1
                first_in_between = min(o.submitted_at for o in in_between)
                outcome_to_close.append(
                    (insight.closed_at - first_in_between).total_seconds()
                    / 86400.0
                )

    resolution_rate = (
        loop_closed / loop_engaged if loop_engaged else None
    )
    insufficient = loop_engaged == 0
    resolution = ResolutionMetrics(
        cohort=cohort,
        total_insights=len(insights),
        closed_insights=closed_insights,
        loop_engaged=loop_engaged,
        loop_closed=loop_closed,
        resolution_rate=resolution_rate,
        insufficient_data=insufficient,
        note=(
            "No insight had a related outcome captured after detection; "
            "resolution rate is undefined, not zero."
            if insufficient
            else "Rate is over insights whose loop was engaged by an outcome."
        ),
    )

    var_trend = _var_trend(cohort, insights, cutoff=cutoff)
    return LoopMetricsReport(
        cohort=cohort,
        resolution=resolution,
        detection_to_outcome=_distribution(
            "detectionToOutcome", detection_to_outcome
        ),
        outcome_to_close=_distribution("outcomeToClose", outcome_to_close),
        var_trend=var_trend,
    )


def _var_trend(
    cohort: str,
    insights: Sequence[_Insight],
    *,
    cutoff: date,
) -> VarTrend:
    dated = [i for i in insights if i.detected_at is not None]
    undated = len(insights) - len(dated)
    if not dated:
        return VarTrend(
            cohort=cohort,
            points=[],
            undated_insight_count=undated,
            note=(
                "No insight carried a parseable detection timestamp; "
                "the trend cannot be placed on the calendar."
            ),
        )

    earliest_week = min(week_start(i.detected_at) for i in dated)
    last_week = week_start(cutoff)
    if last_week < earliest_week:
        last_week = earliest_week

    points: list[VarTrendPoint] = []
    cursor = earliest_week
    while cursor <= last_week:
        week_end = cursor + timedelta(weeks=1)
        open_value = 0.0
        open_count = 0
        for insight in dated:
            detected_day = as_kuching_date(insight.detected_at)
            if detected_day >= week_end:
                continue
            if insight.closed and insight.closed_at is not None:
                if as_kuching_date(insight.closed_at) < week_end:
                    continue
            open_value += insight.value_at_risk_rm
            open_count += 1
        points.append(
            VarTrendPoint(
                week_start=cursor.isoformat(),
                open_value_at_risk_rm=open_value,
                open_count=open_count,
            )
        )
        cursor = week_end

    note = (
        f"{undated} insight(s) excluded from the trend for lack of a "
        "detection timestamp."
        if undated
        else "All insights carried a usable detection timestamp."
    )
    return VarTrend(
        cohort=cohort,
        points=points,
        undated_insight_count=undated,
        note=note,
    )


def compute_loop_metrics(
    insights: Iterable[Mapping[str, Any]],
    outcomes: Iterable[Mapping[str, Any]],
    *,
    cutoff: date,
) -> dict[str, LoopMetricsReport]:
    parsed_insights = [_parse_insight(row) for row in insights]
    parsed_outcomes = [_parse_outcome(row) for row in outcomes]

    reports: dict[str, LoopMetricsReport] = {}
    for cohort, is_demo in (("demo", True), ("nonDemo", False)):
        cohort_insights = [i for i in parsed_insights if i.is_demo is is_demo]
        reports[cohort] = _cohort_metrics(
            cohort,
            cohort_insights,
            parsed_outcomes,
            cutoff=cutoff,
        )
    return reports

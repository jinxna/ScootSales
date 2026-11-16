from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any, Iterable, Mapping

from .calendar import as_kuching_date
from .models import PatternMetrics, RetailerProductSeries
from .patterns import analyse_series


HUMAN_FIELDS = frozenset(
    {
        "status",
        "acknowledgedBy",
        "acknowledgedAt",
        "resolvedBy",
        "resolvedAt",
        "dismissedBy",
        "dismissedAt",
        "snoozedUntil",
        "suppressedBy",
        "adminNotes",
        "assignedToUid",
        "assignedRole",
        "dueDate",
        "statusHistory",
    }
)

COMPUTED_FIELDS = frozenset(
    {
        "priority",
        "confidence",
        "confidenceScore",
        "latestEvidence",
        "anomalyScore",
        "forecastNextWeek",
        "valueAtRiskRm",
        "lastObservedWeekStart",
        "occurrenceCount",
        "ageDays",
        "questions",
        "recommendation",
        "reason",
        "sourceRunId",
        "updatedAt",
        "autoState",
        "autoSuppressedAt",
        "autoSuppressionReason",
        "autoSuppressionExpiresAt",
        "autoSuppressionExpiredAt",
        "consecutiveSightings",
        "latestOutcome",
        "outcomeCount",
        "outcomeQualityScore",
    }
)


def issue_key(insight_type: str, retailer_id: str, product_id: str) -> str:
    values = (insight_type.strip(), retailer_id.strip(), product_id.strip())
    if not all(values):
        raise ValueError("type, retailer_id, and product_id are required")
    return "::".join(values)


def issue_id(insight_type: str, retailer_id: str, product_id: str) -> str:
    key = issue_key(insight_type, retailer_id, product_id)
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:24]
    readable_type = re.sub(r"[^a-z0-9]+", "_", insight_type.lower()).strip("_")
    return f"{readable_type}_{digest}"


@dataclass(frozen=True)
class InsightCandidate:
    issue_id: str
    issue_key: str
    type: str
    retailer_id: str
    product_id: str
    retailer_name: str
    product_name: str
    salesman_uid: str
    salesman_code: str
    branch_id: str
    priority: str
    confidence: str
    confidence_score: float
    latest_evidence: dict[str, object]
    anomaly_score: float
    forecast_next_week: float
    value_at_risk_rm: float
    last_observed_week_start: date
    occurrence_count: int
    age_days: int
    questions: tuple[str, ...]
    recommendation: str
    reason: str

    def to_document(self) -> dict[str, Any]:
        return {
            "issueId": self.issue_id,
            "issueKey": self.issue_key,
            "type": self.type,
            "retailerId": self.retailer_id,
            "productId": self.product_id,
            "retailerName": self.retailer_name,
            "productName": self.product_name,
            "salesmanUid": self.salesman_uid,
            "salesmanCode": self.salesman_code,
            "branchId": self.branch_id,
            "priority": self.priority,
            "confidence": self.confidence,
            "confidenceScore": self.confidence_score,
            "latestEvidence": self.latest_evidence,
            "anomalyScore": self.anomaly_score,
            "forecastNextWeek": self.forecast_next_week,
            "valueAtRiskRm": self.value_at_risk_rm,
            "lastObservedWeekStart": self.last_observed_week_start,
            "occurrenceCount": self.occurrence_count,
            "ageDays": self.age_days,
            "questions": list(self.questions),
            "recommendation": self.recommendation,
            "reason": self.reason,
        }


def _insight_type(metrics: PatternMetrics) -> str | None:
    if metrics.trend == "stopped":
        return "stopped_product"
    if metrics.trend == "declining":
        return "declining_sales"
    if metrics.trend == "growing":
        return "growth_opportunity"
    if metrics.anomaly_score >= 0.72:
        return "sales_anomaly"
    return None


def _value_at_risk(
    insight_type: str,
    metrics: PatternMetrics,
    unit_price_rm: float,
) -> float:
    if unit_price_rm <= 0:
        return 0.0
    if insight_type == "stopped_product":
        gap = metrics.baseline_average
    elif insight_type == "declining_sales":
        gap = max(0.0, metrics.baseline_average - metrics.recent_average)
    elif insight_type == "sales_anomaly":
        gap = max(0.0, metrics.baseline_average - metrics.latest_quantity)
    else:
        gap = 0.0
    return round(gap * unit_price_rm, 2)


def _copy(
    insight_type: str, product_name: str, weeks: int
) -> tuple[tuple[str, ...], str, str]:
    name = product_name or "this product"
    if insight_type == "stopped_product":
        return (
            (
                f"Has the retailer stopped ordering {name}?",
                "Was it replaced by another product or affected by price or stock?",
            ),
            "Confirm the reason for the stop and record any replacement product.",
            "The product had repeated demand but recorded zero quantity in the latest two completed weeks.",
        )
    if insight_type == "declining_sales":
        return (
            (
                f"What changed in sell-through for {name}?",
                "Is price, stock, shelf space, or a competitor affecting demand?",
            ),
            "Review the decline with the retailer and agree on one follow-up action.",
            f"Recent weekly quantity is materially below the earlier {weeks}-week baseline.",
        )
    if insight_type == "growth_opportunity":
        return (
            (
                f"Can the retailer sustain the recent growth in {name}?",
                "Would additional stock or shelf space prevent a missed sale?",
            ),
            "Validate stock coverage and consider a measured replenishment increase.",
            "Recent weekly quantity is materially above the earlier baseline.",
        )
    return (
        (
            f"What explains the unusual latest-week result for {name}?",
            "Was there a one-off order, stock issue, promotion, or data problem?",
        ),
        "Validate the latest result before taking operational action.",
        "The latest quantity differs materially from the prior weekly pattern.",
    )


def build_insight(
    series: RetailerProductSeries,
    *,
    as_of: date | datetime,
    weeks: int = 8,
) -> InsightCandidate | None:
    metrics = analyse_series(series, as_of=as_of, weeks=weeks)
    insight_type = _insight_type(metrics)
    if insight_type is None or metrics.confidence_score < 0.55:
        return None
    if insight_type == "sales_anomaly" and metrics.confidence_score < 0.65:
        return None

    risk = _value_at_risk(insight_type, metrics, series.unit_price_rm)
    if insight_type == "stopped_product":
        priority = "high" if risk >= 100 or metrics.confidence == "high" else "medium"
    elif insight_type == "declining_sales":
        priority = "high" if risk >= 500 else "medium"
    elif insight_type == "sales_anomaly":
        priority = "high" if metrics.anomaly_score >= 0.85 else "medium"
    else:
        priority = "medium"
    questions, recommendation, reason = _copy(
        insight_type,
        series.product_name,
        weeks,
    )
    return InsightCandidate(
        issue_id=issue_id(insight_type, series.retailer_id, series.product_id),
        issue_key=issue_key(insight_type, series.retailer_id, series.product_id),
        type=insight_type,
        retailer_id=series.retailer_id,
        product_id=series.product_id,
        retailer_name=series.retailer_name,
        product_name=series.product_name,
        salesman_uid=series.salesman_uid,
        salesman_code=series.salesman_code,
        branch_id=series.branch_id,
        priority=priority,
        confidence=metrics.confidence,
        confidence_score=metrics.confidence_score,
        latest_evidence=metrics.evidence,
        anomaly_score=metrics.anomaly_score,
        forecast_next_week=metrics.forecast_next_week,
        value_at_risk_rm=risk,
        last_observed_week_start=metrics.week_starts[-1],
        occurrence_count=1,
        age_days=0,
        questions=questions,
        recommendation=recommendation,
        reason=reason,
    )


def merge_insight(
    existing: Mapping[str, Any] | None,
    computed: Mapping[str, Any],
) -> dict[str, Any]:
    if not existing:
        created = dict(computed)
        created.setdefault("status", "new")
        created.setdefault("statusHistory", [])
        created.setdefault("occurrenceCount", 1)
        return created

    old_key = str(existing.get("issueKey", "")).strip()
    new_key = str(computed.get("issueKey", "")).strip()
    if old_key and new_key and old_key != new_key:
        raise ValueError("cannot merge different issue identities")

    merged = dict(existing)
    for key, value in computed.items():
        if key not in HUMAN_FIELDS:
            merged[key] = value
    for field in HUMAN_FIELDS:
        if field in existing:
            merged[field] = existing[field]

    previous_week = _week_identity(existing.get("lastObservedWeekStart"))
    refreshed_week = _week_identity(computed.get("lastObservedWeekStart"))
    previous_count = int(existing.get("occurrenceCount") or 1)
    merged["occurrenceCount"] = (
        previous_count + 1
        if previous_week and refreshed_week and previous_week != refreshed_week
        else previous_count
    )
    merged.setdefault("status", "new")
    merged.setdefault("statusHistory", [])
    return merged


def _week_identity(value: Any) -> str:
    if isinstance(value, datetime):
        return as_kuching_date(value).isoformat()
    if isinstance(value, date):
        return value.isoformat()
    text = str(value or "").strip()
    if not text:
        return ""
    try:
        return as_kuching_date(
            datetime.fromisoformat(text.replace("Z", "+00:00"))
        ).isoformat()
    except ValueError:
        return text[:10]


def summarize_insights(insights: Iterable[Mapping[str, Any]]) -> dict[str, Any]:
    rows = list(insights)
    by_priority: dict[str, int] = {}
    by_type: dict[str, int] = {}
    unresolved_risk = 0.0
    unresolved = 0
    resolved = 0
    ignored = 0
    for row in rows:
        priority = str(row.get("priority") or "unknown")
        insight_type = str(row.get("type") or "unknown")
        by_priority[priority] = by_priority.get(priority, 0) + 1
        by_type[insight_type] = by_type.get(insight_type, 0) + 1
        workflow_status = str(row.get("status") or "new")
        auto_state = str(row.get("autoState") or "active")
        effective_status = (
            "suppressed" if auto_state == "suppressed" else workflow_status
        )
        if effective_status == "resolved":
            resolved += 1
        if effective_status in {"dismissed", "ignored", "suppressed"}:
            ignored += 1
        if effective_status not in {
            "resolved",
            "dismissed",
            "suppressed",
        }:
            unresolved += 1
            unresolved_risk += float(row.get("valueAtRiskRm") or 0)
    return {
        "insightCount": len(rows),
        "unresolvedCount": unresolved,
        "resolvedCount": resolved,
        "ignoredCount": ignored,
        "highPriorityCount": by_priority.get("high", 0),
        "valueAtRiskRm": round(unresolved_risk, 2),
        "byPriority": by_priority,
        "byType": by_type,
    }

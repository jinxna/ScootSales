from __future__ import annotations

import hashlib
from datetime import date, datetime
from typing import Any, Iterable, Mapping

from .normalization import is_demo_record

REPLENISHMENT_TOP_N = 5

FOCUS_LIMIT = 3

NO_FOCUS_HEADLINE = "No priority issues today."
NO_FOCUS_BODY = "Proceed with standard visit."


def _brief_id(retailer_id: str) -> str:
    digest = hashlib.sha256(retailer_id.encode("utf-8")).hexdigest()[:24]
    return f"brief_{digest}"


def _is_field_actionable(insight: Mapping[str, Any]) -> bool:
    if not str(insight.get("retailerId") or "").strip():
        return False
    if not (
        str(insight.get("salesmanUid") or "").strip()
        or str(insight.get("salesmanCode") or "").strip()
    ):
        return False
    if insight.get("fixTarget"):
        return False
    questions = insight.get("questions")
    return isinstance(questions, (list, tuple)) and any(
        str(question).strip() for question in questions
    )


def build_visit_briefs(
    insights: Iterable[Mapping[str, Any]],
    *,
    as_of: date,
    run_id: str,
    generated_at: datetime,
    retailer_memory: Iterable[Mapping[str, Any]] = (),
    retailer_segments: Iterable[Mapping[str, Any]] = (),
    replenishment: Iterable[Mapping[str, Any]] = (),
    coverage_retailers: Iterable[Mapping[str, Any]] = (),
) -> tuple[dict[str, Any], ...]:
    replenishment_by_retailer: dict[str, list[dict[str, Any]]] = {}
    for row in replenishment:
        suggestion_retailer_id = str(row.get("retailerId") or "").strip()
        if suggestion_retailer_id:
            replenishment_by_retailer.setdefault(
                suggestion_retailer_id, []
            ).append(dict(row))
    memory_by_retailer = {
        str(row.get("retailerId") or "").strip(): dict(row)
        for row in retailer_memory
        if str(row.get("retailerId") or "").strip()
        and str(row.get("status") or "active").lower() == "active"
        and row.get("isStale") is not True
    }
    segment_by_retailer = {
        str(row.get("retailerId") or "").strip(): dict(row)
        for row in retailer_segments
        if str(row.get("retailerId") or "").strip()
        and str(row.get("status") or "active").lower() == "active"
    }
    grouped: dict[str, list[dict[str, Any]]] = {}
    for raw in insights:
        insight = dict(raw)
        retailer_id = str(insight.get("retailerId") or "").strip()
        workflow_status = str(insight.get("status") or "new").lower()
        if (
            not _is_field_actionable(insight)
            or insight.get("autoState") == "suppressed"
            or workflow_status in {"resolved", "dismissed", "suppressed"}
        ):
            continue
        grouped.setdefault(retailer_id, []).append(insight)

    coverage_identity: dict[str, dict[str, Any]] = {}
    for raw in coverage_retailers:
        retailer_id = str(raw.get("retailerId") or "").strip()
        if not retailer_id:
            continue
        coverage_identity.setdefault(retailer_id, dict(raw))
        grouped.setdefault(retailer_id, [])

    priority_order = {"high": 0, "medium": 1, "low": 2}
    briefs: list[dict[str, Any]] = []
    for retailer_id, rows in sorted(grouped.items()):
        production_rows = [
            row for row in rows if not is_demo_record(row)
        ]
        if production_rows:
            rows = production_rows
        rows.sort(
            key=lambda row: (
                priority_order.get(str(row.get("priority")), 3),
                -float(row.get("valueAtRiskRm") or 0),
                str(row.get("issueId") or ""),
            )
        )
        top = rows[:FOCUS_LIMIT]
        identity = coverage_identity.get(retailer_id) or {}
        first = top[0] if top else identity
        memory = memory_by_retailer.get(retailer_id)
        segment = segment_by_retailer.get(retailer_id)
        focus_items = [_focus_item(row) for row in top]
        briefs.append(
            {
                "briefId": _brief_id(retailer_id),
                "retailerId": retailer_id,
                "retailerName": first.get("retailerName", ""),
                "salesmanUid": first.get("salesmanUid", ""),
                "salesmanCode": first.get("salesmanCode", ""),
                "branchId": first.get("branchId", ""),
                "asOf": as_of,
                "status": "active",
                "sourceRunId": run_id,
                "insightCount": len(rows),
                "highPriorityCount": sum(
                    row.get("priority") == "high" for row in rows
                ),
                "totalValueAtRiskRm": round(
                    sum(float(row.get("valueAtRiskRm") or 0) for row in rows),
                    2,
                ),
                "focusItems": focus_items,
                "focusCount": len(focus_items),
                "hasFocus": bool(focus_items),
                "headline": "",
                "emptyStateHeadline": "" if focus_items else NO_FOCUS_HEADLINE,
                "emptyStateBody": "" if focus_items else NO_FOCUS_BODY,
                "topInsights": [_legacy_insight(row) for row in top],
                "retailerMemory": _memory_context(memory),
                "routeIntelligence": _route_intelligence(segment),
                "replenishment": _replenishment_context(
                    replenishment_by_retailer.get(retailer_id, [])
                ),
                "isDemo": (
                    any(is_demo_record(row) for row in rows)
                    if rows
                    else is_demo_record(identity)
                ),
                "generatedAt": generated_at,
                "updatedAt": generated_at,
            }
        )
    return tuple(briefs)


def _legacy_insight(row: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "issueId": row.get("issueId", ""),
        "issueKey": row.get("issueKey", ""),
        "type": row.get("type", ""),
        "priority": row.get("priority", ""),
        "confidence": row.get("confidence", ""),
        "productId": row.get("productId", ""),
        "productName": row.get("productName", ""),
        "reason": row.get("reason", ""),
        "recommendation": row.get("recommendation", ""),
        "questions": list(row.get("questions") or [])[:3],
        "valueAtRiskRm": float(row.get("valueAtRiskRm") or 0),
    }


def _focus_item(row: Mapping[str, Any]) -> dict[str, Any]:
    outcome = row.get("latestOutcome")
    previous: dict[str, Any] | None = None
    if isinstance(outcome, Mapping):
        previous = {
            "reasonCode": str(outcome.get("reasonCode") or ""),
            "note": str(outcome.get("note") or ""),
            "submittedAt": outcome.get("submittedAt"),
            "replacementProductId": str(outcome.get("replacementProductId") or ""),
        }
    return {
        "issueId": row.get("issueId", ""),
        "issueKey": row.get("issueKey", ""),
        "type": row.get("type", ""),
        "priority": row.get("priority", ""),
        "confidence": row.get("confidence", ""),
        "confidenceScore": float(row.get("confidenceScore") or 0),
        "productId": row.get("productId", ""),
        "productName": row.get("productName", ""),
        "signal": str(row.get("reason") or ""),
        "action": str(row.get("recommendation") or ""),
        "questions": list(row.get("questions") or [])[:3],
        "valueAtRiskRm": float(row.get("valueAtRiskRm") or 0),
        "previousOutcome": previous,
        "occurrenceCount": int(row.get("occurrenceCount") or 1),
        "autoState": str(row.get("autoState") or "active"),
    }


def _replenishment_context(
    rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    ordered = sorted(
        (
            row
            for row in rows
            if row.get("suggestedQty") is not None
            and str(row.get("suggestionStatus") or "suggested").lower()
            == "suggested"
        ),
        key=lambda row: (
            -float(row.get("confidence") or 0),
            -float(row.get("suggestedQty") or 0),
            str(row.get("productId") or ""),
        ),
    )
    readiness = sorted(
        (
            row
            for row in rows
            if str(row.get("suggestionStatus") or "").lower()
            in {
                "insufficient_history",
                "stale_forecast",
                "forecast_unavailable",
                "no_demand",
            }
        ),
        key=lambda row: str(row.get("productId") or ""),
    )
    combined: list[dict[str, Any]] = []
    for index in range(max(len(ordered), len(readiness))):
        if index < len(ordered):
            combined.append(ordered[index])
        if index < len(readiness):
            combined.append(readiness[index])
    return combined[:REPLENISHMENT_TOP_N]


def _memory_context(memory: Mapping[str, Any] | None) -> dict[str, Any] | None:
    if not memory:
        return None
    reasons = [
        str(row.get("reasonCode") or "").strip()
        for row in memory.get("commonReasonCodes") or ()
        if isinstance(row, Mapping) and str(row.get("reasonCode") or "").strip()
    ][:3]
    replacements = [
        str(row.get("productId") or "").strip()
        for row in memory.get("replacementProducts") or ()
        if isinstance(row, Mapping) and str(row.get("productId") or "").strip()
    ][:2]
    recent_issues = [
        {
            "issueKey": str(row.get("issueKey") or "").strip(),
            "reasonCode": str(row.get("reasonCode") or "").strip(),
            "submittedAt": row.get("submittedAt"),
        }
        for row in memory.get("lastConfirmedIssues") or ()
        if isinstance(row, Mapping)
    ][:3]
    return {
        "status": "active",
        "confidence": str(memory.get("confidenceLabel") or "low"),
        "lastOutcomeAt": memory.get("lastOutcomeAt"),
        "commonReasonCodes": reasons,
        "replacementProductIds": replacements,
        "priceSensitivityScore": float(
            memory.get("priceSensitivityScore") or 0
        ),
        "seasonalityScore": float(memory.get("seasonalityScore") or 0),
        "recentConfirmedIssues": recent_issues,
    }


def _route_intelligence(
    segment: Mapping[str, Any] | None,
) -> dict[str, Any] | None:
    if not segment:
        return None
    attention_score = max(0, min(100, int(segment.get("attentionScore") or 0)))
    priority = str(segment.get("routePriority") or "").strip().lower()
    if priority not in {"urgent", "high", "normal"}:
        priority = (
            "urgent"
            if attention_score >= 75
            else "high"
            if attention_score >= 55
            else "normal"
        )
    return {
        "attentionScore": attention_score,
        "priority": priority,
        "considerVisitingEarlier": (
            segment.get("considerVisitingEarlier") is True
        ),
        "topIssueTypes": [
            str(value).strip()
            for value in segment.get("topIssueTypes") or ()
            if str(value).strip()
        ][:3],
    }

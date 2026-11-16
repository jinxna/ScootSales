from __future__ import annotations

from collections import Counter, defaultdict
from datetime import datetime
from typing import Any, Iterable, Mapping

from .normalization import is_demo_record


def build_retailer_segments(
    patterns: Iterable[Mapping[str, Any]],
    insights: Iterable[Mapping[str, Any]],
    *,
    run_id: str,
    generated_at: datetime,
) -> tuple[dict[str, Any], ...]:
    pattern_rows: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    insight_rows: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for row in patterns:
        retailer_id = str(row.get("retailerId") or "").strip()
        if retailer_id:
            pattern_rows[retailer_id].append(row)
    for row in insights:
        retailer_id = str(row.get("retailerId") or "").strip()
        if retailer_id and _is_active(row):
            insight_rows[retailer_id].append(row)

    segments: list[dict[str, Any]] = []
    for retailer_id in sorted(pattern_rows.keys() | insight_rows.keys()):
        retailer_patterns = pattern_rows.get(retailer_id, [])
        retailer_insights = insight_rows.get(retailer_id, [])
        source_rows_for_retailer = source_rows(retailer_patterns, retailer_insights)
        production_rows = [
            row
            for row in source_rows_for_retailer
            if not is_demo_record(row)
        ]
        if production_rows:
            retailer_patterns = [
                row for row in retailer_patterns if not is_demo_record(row)
            ]
            retailer_insights = [
                row for row in retailer_insights if not is_demo_record(row)
            ]
        source = (retailer_patterns or retailer_insights)[0]
        field_insights = [
            row
            for row in retailer_insights
            if str(row.get("fixTarget") or "").strip() == ""
        ]
        high_priority = sum(
            str(row.get("priority") or "").lower() == "high"
            for row in field_insights
        )
        value_at_risk = round(
            sum(float(row.get("valueAtRiskRm") or 0) for row in field_insights),
            2,
        )
        trends = Counter(
            str(row.get("trend") or "unknown").lower()
            for row in retailer_patterns
        )
        growing = trends["growing"]
        negative = trends["stopped"] + trends["declining"]
        attention_score = min(
            100,
            high_priority * 35
            + len(field_insights) * 12
            + min(30, round(value_at_risk / 20))
            + min(15, negative * 5),
        )
        if high_priority > 0 or attention_score >= 55:
            segment = "at_risk"
        elif growing > negative and growing > 0:
            segment = "growth"
        elif retailer_patterns:
            segment = "stable"
        else:
            segment = "low_signal"
        reasons = Counter(
            str(row.get("type") or "").strip()
            for row in field_insights
            if str(row.get("type") or "").strip()
        )
        route_priority = (
            "urgent"
            if attention_score >= 75 or high_priority >= 2
            else "high"
            if attention_score >= 55
            else "normal"
        )
        segments.append(
            {
                "segmentId": retailer_id,
                "retailerId": retailer_id,
                "retailerName": str(source.get("retailerName") or "Retailer"),
                "salesmanUid": str(source.get("salesmanUid") or ""),
                "salesmanCode": str(source.get("salesmanCode") or ""),
                "branchId": str(source.get("branchId") or ""),
                "segment": segment,
                "status": "active",
                "attentionScore": attention_score,
                "routePriority": route_priority,
                "considerVisitingEarlier": (
                    attention_score >= 70 and bool(field_insights)
                ),
                "activeInsightCount": len(field_insights),
                "highPriorityCount": high_priority,
                "valueAtRiskRm": value_at_risk,
                "trendCounts": dict(sorted(trends.items())),
                "topIssueTypes": [
                    key
                    for key, _ in sorted(
                        reasons.items(),
                        key=lambda item: (-item[1], item[0]),
                    )[:3]
                ],
                "sourceRunId": run_id,
                "isDemo": any(
                    is_demo_record(row)
                    for row in source_rows(retailer_patterns, retailer_insights)
                ),
                "updatedAt": generated_at,
            }
        )
    return tuple(segments)


def source_rows(
    patterns: Iterable[Mapping[str, Any]],
    insights: Iterable[Mapping[str, Any]],
) -> tuple[Mapping[str, Any], ...]:
    return tuple(patterns) + tuple(insights)


def _is_active(row: Mapping[str, Any]) -> bool:
    status = str(row.get("status") or "new").lower()
    auto_state = str(row.get("autoState") or "active").lower()
    return status not in {"resolved", "dismissed", "suppressed"} and (
        auto_state != "suppressed"
    )

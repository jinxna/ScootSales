from __future__ import annotations

from collections import Counter
from datetime import date, datetime, time, timezone
from typing import Any, Iterable

from .outcome_feedback import NormalizedOutcome


MEMORY_STALE_AFTER_DAYS = 180


def _as_datetime(as_of: date) -> datetime:
    return datetime.combine(as_of, time.max, tzinfo=timezone.utc)


def build_retailer_memory(
    outcomes: Iterable[NormalizedOutcome],
    *,
    as_of: date,
    run_id: str,
    generated_at: datetime,
) -> tuple[dict[str, Any], ...]:
    grouped: dict[str, list[NormalizedOutcome]] = {}
    for outcome in outcomes:
        if (
            outcome.accepted
            and outcome.retailer_id
            and outcome.submitted_at is not None
        ):
            grouped.setdefault(outcome.retailer_id, []).append(outcome)

    memories: list[dict[str, Any]] = []
    now = _as_datetime(as_of)
    for retailer_id, grouped_rows in sorted(grouped.items()):
        production_rows = [
            outcome for outcome in grouped_rows if not outcome.is_demo
        ]
        rows = production_rows or grouped_rows
        rows.sort(key=lambda item: item.submitted_at or generated_at, reverse=True)
        reason_weights: Counter[str] = Counter()
        replacement_weights: Counter[str] = Counter()
        weighted_quality = 0.0
        total_weight = 0.0
        for outcome in rows:
            age_days = max(0, (now - outcome.submitted_at).days)
            weight = max(0.0, 1.0 - (age_days / MEMORY_STALE_AFTER_DAYS))
            reason_weights[outcome.reason_code] += weight
            if outcome.replacement_product_id:
                replacement_weights[outcome.replacement_product_id] += weight
            weighted_quality += outcome.quality_score * weight
            total_weight += weight

        latest = rows[0]
        average_quality = weighted_quality / total_weight if total_weight else 0.0
        recency_days = max(0, (now - latest.submitted_at).days)
        recency_factor = max(
            0.0,
            1.0 - (recency_days / MEMORY_STALE_AFTER_DAYS),
        )
        confidence = min(1.0, len(rows) / 5) * (average_quality / 100) * recency_factor
        is_stale = recency_days >= MEMORY_STALE_AFTER_DAYS
        top_reasons = [
            {"reasonCode": reason, "score": round(score, 3)}
            for reason, score in reason_weights.most_common(5)
        ]
        replacements = [
            {"productId": product_id, "score": round(score, 3)}
            for product_id, score in replacement_weights.most_common(5)
        ]
        memories.append(
            {
                "memoryId": retailer_id,
                "retailerId": retailer_id,
                "salesmanUid": latest.salesman_uid,
                "salesmanCode": latest.salesman_code,
                "branchId": latest.branch_id,
                "status": "stale" if is_stale else "active",
                "isStale": is_stale,
                "ageDays": recency_days,
                "staleAfterDays": MEMORY_STALE_AFTER_DAYS,
                "outcomeCount": len(rows),
                "commonReasonCodes": top_reasons,
                "priceSensitivityScore": round(
                    sum(
                        reason_weights[reason]
                        for reason in ("price_too_high", "competitor_promotion")
                    ),
                    3,
                ),
                "seasonalityScore": round(reason_weights["seasonal_change"], 3),
                "replacementProducts": replacements,
                "lastConfirmedIssues": [
                    {
                        "issueKey": outcome.issue_key,
                        "reasonCode": outcome.reason_code,
                        "submittedAt": outcome.submitted_at,
                    }
                    for outcome in rows[:5]
                ],
                "confidence": round(confidence, 3),
                "confidenceLabel": (
                    "high" if confidence >= 0.7 else "medium" if confidence >= 0.4 else "low"
                ),
                "lastOutcomeAt": latest.submitted_at,
                "sourceRunId": run_id,
                "isDemo": all(outcome.is_demo for outcome in rows),
                "updatedAt": generated_at,
            }
        )
    return tuple(memories)

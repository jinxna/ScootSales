from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Iterable, Mapping, Sequence

from forecasting.ai_core import score_outcome_quality

from .normalization import is_demo_record

SUPPRESSION_WINDOW_DAYS: dict[str, int] = {
    "switched_to_alternative": 42,
    "seasonal_change": 84,
    "packaging_change": 42,
}

SUPPRESSING_REASON_CODES = frozenset(SUPPRESSION_WINDOW_DAYS)

FOLLOW_UP_REASON_CODES = frozenset(
    {
        "not_asked_today",
        "retailer_busy",
        "decision_maker_unavailable",
        "not_decision_maker",
    }
)


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
        try:
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _evidence_moment(value: Any) -> datetime | None:
    if isinstance(value, date) and not isinstance(value, datetime):
        return datetime.combine(value, time.min, tzinfo=timezone.utc)
    return _moment(value)


@dataclass(frozen=True)
class NormalizedOutcome:
    outcome_id: str
    issue_key: str
    issue_id: str
    reason_code: str
    note: str
    replacement_product_id: str
    salesman_uid: str
    salesman_code: str
    branch_id: str
    retailer_id: str
    submitted_at: datetime | None
    quality_score: int
    quality: str
    quality_flags: tuple[str, ...]
    accepted: bool
    is_demo: bool


def normalize_outcomes(
    rows: Iterable[Mapping[str, Any]],
) -> tuple[NormalizedOutcome, ...]:
    outcomes: list[NormalizedOutcome] = []
    for row in rows:
        reason = _text(row.get("reasonCode") or row.get("reason_code")).lower()
        note = _text(row.get("note") or row.get("notes"))
        replacement = _text(
            row.get("replacementProductId")
            or row.get("replacement_product_id")
            or row.get("alternativeProductId")
        )
        quality = score_outcome_quality(
            reason,
            note=note,
            replacement_product_id=replacement,
        )
        outcomes.append(
            NormalizedOutcome(
                outcome_id=_text(row.get("outcomeId") or row.get("docId")),
                issue_key=_text(row.get("issueKey")),
                issue_id=_text(row.get("issueId")),
                reason_code=reason,
                note=note,
                replacement_product_id=replacement,
                salesman_uid=_text(row.get("salesmanUid")),
                salesman_code=_text(row.get("salesmanCode")),
                branch_id=_text(row.get("branchId")),
                retailer_id=_text(row.get("retailerId")),
                submitted_at=_moment(
                    row.get("submittedAt")
                    or row.get("createdAt")
                    or row.get("clientCreatedAt")
                ),
                quality_score=quality.score,
                quality=quality.quality,
                quality_flags=quality.flags,
                accepted=quality.accepted,
                is_demo=is_demo_record(row),
            )
        )
    outcomes.sort(
        key=lambda item: item.submitted_at or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )
    return tuple(outcomes)


def apply_outcome_feedback(
    insights: Iterable[Mapping[str, Any]],
    outcomes: Iterable[NormalizedOutcome],
    *,
    evaluated_at: datetime | None = None,
) -> tuple[dict[str, Any], ...]:
    accepted_by_key: dict[str, list[NormalizedOutcome]] = {}
    for outcome in outcomes:
        if outcome.accepted and outcome.issue_key and outcome.submitted_at is not None:
            accepted_by_key.setdefault(outcome.issue_key, []).append(outcome)

    reference = evaluated_at
    if reference is None:
        moments = [
            outcome.submitted_at
            for rows in accepted_by_key.values()
            for outcome in rows
        ]
        reference = max(moments) if moments else None

    refreshed: list[dict[str, Any]] = []
    for source in insights:
        insight = dict(source)
        retailer_id = str(insight.get("retailerId") or "")
        evidence_at = _evidence_moment(insight.get("lastObservedWeekStart"))
        matches = [
            outcome
            for outcome in accepted_by_key.get(
                str(insight.get("issueKey") or ""),
                [],
            )
            if (not outcome.retailer_id or outcome.retailer_id == retailer_id)
            and (evidence_at is None or outcome.submitted_at >= evidence_at)
        ]
        if not matches:
            insight["outcomeCount"] = 0
            insight["autoState"] = "active"
            insight["consecutiveSightings"] = 0
            refreshed.append(insight)
            continue

        latest = matches[0]
        auto_state = _auto_state(latest.reason_code)
        insight.update(
            {
                "outcomeCount": len(matches),
                "autoState": auto_state,
                "consecutiveSightings": _consecutive_sightings(matches),
                "latestOutcome": {
                    "outcomeId": latest.outcome_id,
                    "reasonCode": latest.reason_code,
                    "note": latest.note,
                    "replacementProductId": latest.replacement_product_id,
                    "qualityScore": latest.quality_score,
                    "quality": latest.quality,
                    "qualityFlags": list(latest.quality_flags),
                    "salesmanUid": latest.salesman_uid,
                    "submittedAt": latest.submitted_at,
                },
                "outcomeQualityScore": latest.quality_score,
            }
        )
        if auto_state == "suppressed":
            insight["autoSuppressedAt"] = latest.submitted_at
            insight["autoSuppressionReason"] = latest.reason_code
            window = suppression_window_days(latest.reason_code)
            if window is not None:
                expires_at = latest.submitted_at + timedelta(days=window)
                insight["autoSuppressionExpiresAt"] = expires_at
                if reference is not None and reference >= expires_at:
                    insight["autoState"] = "follow_up"
                    insight["autoSuppressionExpiredAt"] = expires_at
        refreshed.append(insight)
    return tuple(refreshed)


def suppression_window_days(reason_code: str) -> int | None:
    return SUPPRESSION_WINDOW_DAYS.get(reason_code.strip().lower())


def suppression_expires_at(
    reason_code: str, submitted_at: datetime | None
) -> datetime | None:
    window = suppression_window_days(reason_code)
    if window is None or submitted_at is None:
        return None
    return submitted_at + timedelta(days=window)


def _consecutive_sightings(matches: Sequence[NormalizedOutcome]) -> int:
    if not matches:
        return 0
    newest = matches[0].reason_code
    count = 0
    for outcome in matches:
        if outcome.reason_code != newest:
            break
        count += 1
    return count


def _auto_state(reason_code: str) -> str:
    if reason_code in SUPPRESSING_REASON_CODES:
        return "suppressed"
    if reason_code in FOLLOW_UP_REASON_CODES:
        return "follow_up"
    return "confirmed"

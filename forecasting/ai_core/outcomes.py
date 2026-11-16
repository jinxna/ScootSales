from __future__ import annotations

import re
from dataclasses import dataclass


REASON_CODES = frozenset(
    {
        "low_sell_through",
        "price_too_high",
        "switched_to_alternative",
        "supplier_issue",
        "out_of_stock",
        "shelf_space_limited",
        "cash_flow_issue",
        "seasonal_change",
        "not_decision_maker",
        "not_asked_today",
        "retailer_busy",
        "decision_maker_unavailable",
        "competitor_promotion",
        "packaging_change",
        "quality_complaint",
        "other",
    }
)

_JUNK_NOTES = {
    "ok",
    "okay",
    "test",
    "testing",
    "n/a",
    "na",
    "none",
    "no",
    "yes",
    "-",
    ".",
}


@dataclass(frozen=True)
class OutcomeQuality:
    score: int
    quality: str
    accepted: bool
    flags: tuple[str, ...]


def _meaningful_note(note: str) -> bool:
    cleaned = " ".join(note.strip().split())
    if len(cleaned) < 8 or cleaned.lower() in _JUNK_NOTES:
        return False
    if not re.search(r"[A-Za-z]", cleaned):
        return False
    if re.fullmatch(r"(.)\1{4,}", cleaned.lower()):
        return False
    words = re.findall(r"[A-Za-z0-9]+", cleaned.lower())
    return len(set(words)) >= 2


def score_outcome_quality(
    reason_code: str,
    *,
    note: str = "",
    replacement_product_id: str = "",
) -> OutcomeQuality:
    reason = reason_code.strip().lower()
    clean_note = " ".join(note.strip().split())
    flags: list[str] = []
    score = 70

    if reason not in REASON_CODES:
        return OutcomeQuality(
            score=0,
            quality="invalid",
            accepted=False,
            flags=("invalid_reason_code",),
        )

    note_is_meaningful = _meaningful_note(clean_note) if clean_note else False
    if clean_note and not note_is_meaningful:
        flags.append("junk_note")
        score -= 35
    elif note_is_meaningful:
        score += 20

    if reason == "other" and not note_is_meaningful:
        flags.append("note_required_for_other")
        score -= 60

    if reason == "switched_to_alternative":
        if replacement_product_id.strip():
            score += 10
        else:
            flags.append("replacement_product_missing")
            score -= 20

    score = max(0, min(100, score))
    blocking = {"invalid_reason_code", "note_required_for_other"}
    accepted = score >= 50 and not blocking.intersection(flags)
    quality = "high" if score >= 85 else "medium" if score >= 60 else "low"
    return OutcomeQuality(
        score=score,
        quality=quality,
        accepted=accepted,
        flags=tuple(flags),
    )

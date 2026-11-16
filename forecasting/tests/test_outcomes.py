from forecasting.ai_core import score_outcome_quality


def test_other_requires_meaningful_note() -> None:
    quality = score_outcome_quality("other", note="ok")
    assert quality.accepted is False
    assert "note_required_for_other" in quality.flags
    assert "junk_note" in quality.flags


def test_switched_product_scores_high_with_replacement() -> None:
    quality = score_outcome_quality(
        "switched_to_alternative",
        note="Retailer moved to the smaller pack after a competitor promotion.",
        replacement_product_id="P004",
    )
    assert quality.accepted is True
    assert quality.quality == "high"
    assert quality.score == 100


def test_invalid_reason_code_is_rejected() -> None:
    quality = score_outcome_quality("made_up_reason")
    assert quality.accepted is False
    assert quality.flags == ("invalid_reason_code",)

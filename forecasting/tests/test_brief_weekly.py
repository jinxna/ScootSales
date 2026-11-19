import json
from datetime import date, datetime, timezone

import pytest

from forecasting.ai_service import generator
from forecasting.ai_service.demo_seed import build_demo_documents
from forecasting.ai_service.generator import build_generation
from forecasting.ai_service.normalization import normalize_firestore_inputs
from forecasting.ai_service.repository import _visit_brief_rows
from forecasting.ai_service.visit_briefs import (
    BRIEF_WEEKLY_VERSION,
    build_visit_briefs,
)

AS_OF = date(2026, 6, 15)
NEW_KEYS = {"weeklyVersion", "weekStarts", "weeklyQuantities"}
WEEKS = [
    "2026-04-20",
    "2026-04-27",
    "2026-05-04",
    "2026-05-11",
    "2026-05-18",
    "2026-05-25",
    "2026-06-01",
    "2026-06-08",
]
QUANTITIES = [6, 6, 5, 6, 6, 6, 0, 0]


def _bytes(value) -> str:
    return json.dumps(value, sort_keys=True, default=str)


def _insight(retailer_id="R1", product_id="P1", issue="i1", value=50):
    return {
        "issueId": issue,
        "issueKey": f"k::{retailer_id}::{product_id}",
        "retailerId": retailer_id,
        "retailerName": "Shop",
        "salesmanUid": "U1",
        "salesmanCode": "S1",
        "branchId": "B1",
        "productId": product_id,
        "priority": "high",
        "valueAtRiskRm": value,
        "questions": ["What changed?"],
    }


def _pattern(retailer_id="R1", product_id="P1", starts=None, quantities=None):
    return {
        "patternId": f"{retailer_id}_{product_id}",
        "retailerId": retailer_id,
        "productId": product_id,
        "weekStarts": list(WEEKS if starts is None else starts),
        "weeklyQuantities": list(QUANTITIES if quantities is None else quantities),
    }


def _briefs(insights, patterns=(), as_of=AS_OF):
    return build_visit_briefs(
        insights,
        as_of=as_of,
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
        patterns=patterns,
    )


def test_focus_item_carries_the_stored_pattern_weeks_oldest_first() -> None:
    item = _briefs([_insight()], [_pattern()])[0]["focusItems"][0]

    assert item["weeklyVersion"] == BRIEF_WEEKLY_VERSION == "brief-weekly/1.0.0"
    assert item["weekStarts"] == WEEKS
    assert item["weeklyQuantities"] == [6, 6, 5, 6, 6, 6, 0, 0]
    assert len(item["weekStarts"]) == len(item["weeklyQuantities"]) == 8
    assert all(isinstance(value, float) for value in item["weeklyQuantities"])


def test_current_week_and_extra_old_weeks_are_left_out() -> None:
    starts = ["2026-04-13", *WEEKS, "2026-06-15"]
    quantities = [9, *QUANTITIES, 99]
    pattern = _pattern(starts=starts, quantities=quantities)
    item = _briefs([_insight()], [pattern])[0]["focusItems"][0]

    assert item["weekStarts"] == WEEKS
    assert item["weeklyQuantities"] == QUANTITIES


def test_short_history_writes_what_exists() -> None:
    pattern = _pattern(starts=WEEKS[-4:], quantities=[1, 2, 0, 4])
    item = _briefs([_insight()], [pattern])[0]["focusItems"][0]

    assert item["weekStarts"] == WEEKS[-4:]
    assert item["weeklyQuantities"] == [1, 2, 0, 4]


def test_unsorted_pattern_is_returned_oldest_first() -> None:
    pattern = _pattern(starts=WEEKS[::-1], quantities=QUANTITIES[::-1])
    item = _briefs([_insight()], [pattern])[0]["focusItems"][0]

    assert item["weekStarts"] == WEEKS
    assert item["weeklyQuantities"] == QUANTITIES


def test_item_without_product_or_pattern_has_no_weekly_keys() -> None:
    brief = _briefs(
        [
            _insight(product_id="", issue="a", value=90),
            _insight(product_id="P2", issue="b", value=80),
            _insight(product_id="P1", issue="c", value=70),
        ],
        [_pattern(product_id="P1"), _pattern(retailer_id="R2", product_id="P2")],
    )[0]
    by_issue = {item["issueId"]: item for item in brief["focusItems"]}

    assert not NEW_KEYS & set(by_issue["a"])
    assert not NEW_KEYS & set(by_issue["b"])
    assert NEW_KEYS <= set(by_issue["c"])


def test_product_id_with_spaces_still_matches() -> None:
    item = _briefs([_insight(product_id=" P1 ")], [_pattern(product_id="P1")])[0][
        "focusItems"
    ][0]

    assert item["weeklyQuantities"] == QUANTITIES


def test_two_patterns_for_one_pair_choose_the_latest_then_lowest_id() -> None:
    older = _pattern(starts=WEEKS[:-1], quantities=[1] * 7)
    older["patternId"] = "a"
    newer = _pattern()
    newer["patternId"] = "b"
    tie = _pattern(quantities=[7] * 8)
    tie["patternId"] = "c"
    for order in ([older, newer, tie], [tie, newer, older]):
        item = _briefs([_insight()], order)[0]["focusItems"][0]
        assert item["weeklyQuantities"] == QUANTITIES


@pytest.mark.parametrize(
    "bad",
    [
        {"quantities": [6, 6, 5]},
        {"quantities": [6, 6, 5, 6, 6, 6, 0, -1]},
        {"quantities": [6, 6, 5, 6, 6, 6, 0, float("nan")]},
        {"quantities": [6, 6, 5, 6, 6, 6, 0, "x"]},
        {"quantities": [6, 6, 5, 6, 6, 6, 0, True]},
        {"starts": WEEKS[:-1] + ["not-a-date"]},
        {"starts": ["2026-06-15"], "quantities": [3]},
        {"starts": [], "quantities": []},
        {"starts": WEEKS[:-1] + [WEEKS[0]]},
    ],
)
def test_unusable_pattern_gives_no_weekly_keys(bad) -> None:
    pattern = _pattern(starts=bad.get("starts"), quantities=bad.get("quantities"))
    item = _briefs([_insight()], [pattern])[0]["focusItems"][0]

    assert not NEW_KEYS & set(item)


def test_briefs_differ_only_by_the_three_keys_on_focus_items() -> None:
    insights = [_insight(), _insight(product_id="P2", issue="b", value=10)]
    plain = _briefs(insights)
    with_weeks = _briefs(insights, [_pattern()])

    for before, after in zip(plain, with_weeks):
        assert {k: v for k, v in before.items() if k != "focusItems"} == {
            k: v for k, v in after.items() if k != "focusItems"
        }
        for old, new in zip(before["focusItems"], after["focusItems"]):
            assert old == {k: v for k, v in new.items() if k not in NEW_KEYS}
    assert any(
        NEW_KEYS <= set(item) for brief in with_weeks for item in brief["focusItems"]
    )


def test_rebuilt_in_same_week_is_identical() -> None:
    patterns = [_pattern()]
    assert _bytes(_briefs([_insight()], patterns)) == _bytes(
        _briefs([_insight()], patterns)
    )


def test_inactive_brief_keeps_the_previous_payload_untouched() -> None:
    brief = _briefs([_insight()], [_pattern()])[0]
    rows = _visit_brief_rows(
        current=[],
        existing=[brief],
        run_id="run-2",
        generated_at=datetime(2026, 6, 22, tzinfo=timezone.utc),
    )

    assert rows[0][1]["status"] == "inactive"
    assert rows[0][1]["focusItems"] == brief["focusItems"]


def test_job_changes_only_brief_focus_items(monkeypatch) -> None:
    documents = build_demo_documents(as_of=AS_OF)

    def flat(name):
        return [{"docId": doc_id, **row} for doc_id, row in documents[name]]

    normalized = normalize_firestore_inputs(
        orders=flat("orders"),
        products=flat("products"),
        retailers=flat("retailers"),
        users=flat("users"),
        as_of=AS_OF,
    )
    kwargs = {
        "as_of": AS_OF,
        "run_id": "run-test",
        "generated_at": datetime(2026, 6, 15, tzinfo=timezone.utc),
        "orders": flat("orders"),
    }
    now = build_generation(normalized, **kwargs)

    real = generator.build_visit_briefs
    monkeypatch.setattr(
        generator,
        "build_visit_briefs",
        lambda insights, **kw: real(insights, **{**kw, "patterns": ()}),
    )
    before = build_generation(normalized, **kwargs)

    for name in (
        "priority_rankings",
        "replenishment",
        "patterns",
        "insights",
        "retailer_segments",
        "weekly_summaries",
    ):
        assert _bytes(getattr(now, name)) == _bytes(getattr(before, name)), name
    assert now.visit_briefs != before.visit_briefs
    assert len(now.visit_briefs) == len(before.visit_briefs)
    pattern_rows = {(row["retailerId"], row["productId"]): row for row in now.patterns}
    seen = 0
    for after_brief, before_brief in zip(now.visit_briefs, before.visit_briefs):
        assert {k: v for k, v in after_brief.items() if k != "focusItems"} == {
            k: v for k, v in before_brief.items() if k != "focusItems"
        }
        for new, old in zip(after_brief["focusItems"], before_brief["focusItems"]):
            assert old == {k: v for k, v in new.items() if k not in NEW_KEYS}
            if NEW_KEYS & set(new):
                seen += 1
                pattern = pattern_rows[(after_brief["retailerId"], new["productId"])]
                assert new["weekStarts"] == pattern["weekStarts"][-8:]
                assert new["weeklyQuantities"] == pattern["weeklyQuantities"][-8:]
                assert max(new["weekStarts"]) < "2026-06-15"
    assert seen > 0

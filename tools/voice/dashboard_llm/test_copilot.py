import json
import os
from pathlib import Path

import pytest

from tools.voice.dashboard_llm import copilot_model, copilot_schema as schema
from tools.voice.dashboard_llm import evaluate_copilot as ev
from tools.voice.dashboard_llm.train import make_copilot_dataset as ds
from tools.voice.dashboard_llm.train import make_dataset as md

PAGES = [
    {"key": "all_orders", "label": "All Orders", "aliases": ["orders"]},
    {"key": "reports", "label": "Reports", "aliases": []},
]
ALL = list(schema.ACTION_ORDER)


def out(text: str) -> str:
    return schema.PREFILL + text


def call(name, **args):
    return out(schema.serialize_call({"name": name, "args": args}))


def parse(output, pages=PAGES, actions=ALL):
    return schema.parse_call(output, pages, actions)


def test_serialize_sorts_keys_and_writes_numbers_bare():
    text = schema.serialize_call({"name": "search_orders", "args": {"salesperson": "Ahmad", "period": "this_week"}})
    assert text == (
        "search_orders{period:<escape>this_week<escape>,salesperson:<escape>Ahmad<escape>}<end_function_call>"
    )
    assert schema.serialize_call({"name": "explain_item", "args": {"position": 3}}) == (
        "explain_item{position:3}<end_function_call>"
    )
    assert schema.serialize_call({"name": "no_match", "args": {}}) == "no_match{}<end_function_call>"


def test_valid_calls_round_trip():
    for name, args in [
        ("search_orders", {"salesperson": "Ahmad", "period": "this_week", "status": "approved"}),
        ("export_results", {}),
        ("daily_briefing", {}),
        ("explain_item", {"position": 2}),
        ("explain_item", {}),
        ("set_item_status", {"position": 2, "status": "in_review"}),
        ("set_item_status", {"status": "ignored"}),
        ("brief_retailer", {"retailer": "Kedai Maju"}),
        ("brief_retailer", {}),
        ("route_why", {"retailer": "Emart Matang", "salesperson": "Jayson"}),
        ("route_why", {}),
        ("salesperson_visits", {"salesperson": "Jayson", "week": "next_week"}),
        ("due_overview", {}),
        ("open_planner", {"salesperson": "Jayson", "week": "next_week"}),
        ("no_route", {"week": "this_week"}),
        ("navigate_to_page", {"page": "reports"}),
    ]:
        parsed = parse(call(name, **args))
        assert parsed is not None and parsed.as_dict() == {"name": name, "args": args}, (name, args)
    assert parse(call("no_match")).name == "no_match"


def test_leading_white_space_before_the_name_is_tolerated_but_other_text_is_not():
    parsed = parse(out("\n\nsearch_orders{status:<escape>approved<escape>}<end_function_call>"))
    assert parsed is not None and parsed.args == {"status": "approved"}
    assert parse(out(" export_results{}<end_function_call>")) is not None
    assert parse(out("item_no_3:explain_item{position:3}<end_function_call>")) is None
    assert parse(out("\n\nNo_match{}<end_function_call>")) is None


def test_hosted_only_actions_are_rejected_unless_offered_and_have_checked_arguments():
    assert parse(call("no_route", week="next_week"), actions=["search_orders"]) is None
    assert parse(call("no_route", week="next_year")) is None
    assert parse(call("open_planner", week="someday")) is None
    assert parse(call("due_overview", week="next_week")) is None
    assert parse(call("route_why", position=2)) is None
    assert set(schema.HOSTED_ONLY_ACTIONS) <= set(schema.ACTION_ORDER)
    assert set(schema.HOSTED_ONLY_ACTIONS).isdisjoint(schema.TRAINED_ACTION_ORDER)
    _, _, offered = schema.validate_request({"text": "hello", "actions": ["no_route"]})
    assert offered == ["no_route"]


def test_page_alias_resolves_and_unknown_page_is_rejected():
    assert parse(call("navigate_to_page", page="Orders")).args == {"page": "all_orders"}
    assert parse(call("navigate_to_page", page="system_health")) is None
    assert parse(call("navigate_to_page", page="reports"), pages=[]) is None


@pytest.mark.parametrize(
    "bad",
    [
        "sure, here you go",
        call("search_orders", period="this_week") + call("export_results"),
        call("delete_everything"),
        call("search_orders", period="next_year"),
        call("search_orders", colour="red"),
        call("search_orders"),
        call("set_item_status", position=2),
        call("set_item_status", status="done"),
        call("explain_item", position=0),
        call("explain_item", position=999),
        out("explain_item{position:<escape>two<escape>}<end_function_call>"),
        out("search_orders{period:<escape>today<escape>,period:<escape>today<escape>}<end_function_call>"),
        out("search_orders{period:<escape>today<escape>,}<end_function_call>"),
        out("search_orders{period:<escape>today<escape>} trailing<end_function_call>"),
        out("search_orders{salesperson:<escape>a<b<escape>}<end_function_call>"),
        out("search_orders{period:<escape>today<escape>}"),
        out("no_match{period:<escape>today<escape>}<end_function_call>"),
    ],
)
def test_malformed_or_invalid_output_is_rejected(bad):
    assert parse(bad) is None


def test_only_offered_actions_parse():
    assert parse(call("export_results"), actions=["search_orders"]) is None
    assert parse(call("export_results"), actions=["export_results"]) is not None
    assert parse(call("no_match"), actions=[]) is not None


def test_interpret_gates_by_confidence_and_never_returns_a_declined_call():
    body = {"text": "show Ahmad's orders today", "pages": PAGES, "actions": ALL}
    good = schema.serialize_call({"name": "search_orders", "args": {"salesperson": "Ahmad", "period": "today"}})
    hit = copilot_model.interpret(lambda t, p, a: (good, 0.99), body, 0.98)
    assert hit["call"] == {"name": "search_orders", "args": {"salesperson": "Ahmad", "period": "today"}}
    low = copilot_model.interpret(lambda t, p, a: (good, 0.5), body, 0.98)
    assert low["call"] is None and low["confidence"] == 0.0
    edge = copilot_model.interpret(lambda t, p, a: (good, 0.97996), body, 0.98)
    assert edge["call"] is None
    kept = copilot_model.interpret(lambda t, p, a: (good, 0.97996), body, 0.0)
    assert kept["confidence"] == 0.97996
    declined = copilot_model.interpret(lambda t, p, a: ("no_match{}<end_function_call>", 1.0), body, 0.5)
    assert declined["call"] is None
    garbage = copilot_model.interpret(lambda t, p, a: ("hello there", 1.0), body, 0.5)
    assert garbage["call"] is None


def test_request_validation():
    assert schema.validate_request({"text": " hi  there ", "pages": PAGES})[0] == "hi there"
    assert schema.validate_request({"text": "x"})[1:] == ([], ALL)
    for bad in (
        {"text": "x" * 201}, {"text": "  "}, {"text": "x", "actions": ["drop_database"]},
        {"text": "x", "pages": [{"key": "Bad Key", "label": "l"}]},
        {"text": "x", "pages": [{"key": "a", "label": "<escape>"}]}, "text",
    ):
        with pytest.raises(schema.RequestError):
            schema.validate_request(bad)


def test_consequential_writes_are_not_tools_yet():
    assert not {"approve_order", "publish_route", "save_route_draft", "reject_order"} & set(schema.ACTION_SPECS)


@pytest.fixture(scope="module")
def dataset(tmp_path_factory):
    ds.install_navigation_source()
    frozen = ds.frozen_texts()
    test = ds.build("test", 400, ds.SEED, frozen)
    val = ds.build("validation", 300, ds.SEED, frozen | {ds.norm(x["text"]) for x in test})
    banned = frozen | {ds.norm(x["text"]) for x in test + val}
    train = ds.build("train", 1500, ds.SEED, banned)
    return train, val, test, frozen


def test_dataset_is_deterministic():
    ds.install_navigation_source()
    first = ds.build("validation", 60, ds.SEED, set())
    second = ds.build("validation", 60, ds.SEED, set())
    assert first == second


def test_every_target_is_valid_and_names_are_copied(dataset):
    train, val, test, _ = dataset
    for rows in (train, val, test):
        assert ds.verbatim_errors(rows) == []
        for row in rows:
            request = ds.to_request(row)
            parsed = schema.parse_call(
                schema.PREFILL + schema.serialize_call(row["target"]), request["pages"], request["actions"]
            )
            expected = row["target"]
            if expected["name"] == schema.NAVIGATE:
                assert parsed is not None and parsed.args == expected["args"], row
            elif expected["name"] == schema.NO_MATCH:
                assert parsed is not None and parsed.name == schema.NO_MATCH
            else:
                assert expected["name"] in request["actions"], f"target action not offered: {row}"
                assert parsed is not None and parsed.as_dict() == expected, row


def test_no_leakage_between_train_validation_test_and_frozen(dataset):
    train, val, test, frozen = dataset
    sets = {name: {ds.norm(x["text"]) for x in rows} for name, rows in (("train", train), ("val", val), ("test", test))}
    assert not sets["train"] & sets["val"] and not sets["train"] & sets["test"] and not sets["val"] & sets["test"]
    for name, texts in sets.items():
        assert not texts & frozen, name


def test_held_out_names_never_appear_in_training(dataset):
    train = dataset[0]
    held = {n.lower() for pool in ("validation", "test") for n in ds.SALESPEOPLE[pool] + ds.RETAILERS[pool]}
    text = " ".join(x["text"].lower() for x in train)
    assert not any(name in text for name in held)
    assert not (set(ds.SALESPEOPLE["train"]) & set(ds.SALESPEOPLE["test"]))
    assert not (set(ds.RETAILERS["train"]) & set(ds.RETAILERS["test"]))


def test_frozen_names_are_unseen_by_training():
    cases = json.loads((Path(ds.LLM_DIR) / "copilot_eval_phrases.json").read_text(encoding="utf-8"))["cases"]
    pool = {n.lower() for split in ds.SALESPEOPLE.values() for n in split} | {
        n.lower() for split in ds.RETAILERS.values() for n in split
    }
    for case in cases:
        for key in ("salesperson", "retailer"):
            value = (case["expect"] or {"args": {}})["args"].get(key)
            assert value is None or value.lower() not in pool, case["text"]
        assert case["expect"] is None or case["expect"]["name"] in {schema.NAVIGATE, *schema.ACTION_SPECS}


def test_one_sentence_has_one_positive_answer(dataset):
    assert ds.conflicts(*dataset[:3]) == []


def test_dataset_covers_every_action_in_both_languages(dataset):
    train = dataset[0]
    seen = {(x["target"]["name"], x["lang"]) for x in train}
    for action in schema.TRAINED_ACTION_ORDER:
        assert (action, "en") in seen and (action, "ms") in seen, action
    kinds = {x["kind"].split(":")[0] for x in train}
    assert {"gated", "write_negative"} <= kinds


def test_overlapping_navigation_phrases_are_removed():
    ds.install_navigation_source()
    assert "what needs my attention today" not in md.INTENTS["dashboard"]
    assert "submitted orders" not in md.NOUNS["all_orders"]
    assert "orders" in md.NOUNS["all_orders"]


def row(expect, call_, confidence=1.0):
    return {"expect": expect, "call": call_, "confidence": confidence, "lang": "en", "kind": "k"}


def test_scoring_counts_wrong_calls_yield_and_abstention():
    search = {"name": "search_orders", "args": {"salesperson": "Ahmad", "period": "today"}}
    rows = [
        row(search, {"name": "search_orders", "args": {"salesperson": "ahmad", "period": "today"}}),
        row(search, {"name": "search_orders", "args": {"salesperson": "Ahmad", "period": "this_week"}}),
        row(search, None),
        row(None, None),
        row(None, {"name": "daily_briefing", "args": {}}),
    ]
    s = ev.score_rows(rows, 0.0)
    assert (s["wrongCount"], s["yield"], s["abstainOnNegatives"]) == (2, round(1 / 3, 4), 0.5)
    assert s["nameYield"] == round(2 / 3, 4)
    s2 = ev.score_rows([row(search, search, 0.9), row(None, search, 0.9)], 0.95)
    assert s2["wrongCount"] == 0 and s2["yield"] == 0.0 and s2["abstainOnNegatives"] == 1.0


def test_frozen_set_loads_with_real_catalogues():
    cases = ev.load_frozen()
    assert len(cases) >= 100
    assert {c["lang"] for c in cases} == {"en", "ms", "mix"}
    for case in cases:
        request = schema.validate_request(case["request"])
        assert request[0] == " ".join(case["text"].split())
        exp = case["expect"]
        if exp and exp["name"] == schema.NAVIGATE:
            assert exp["args"]["page"] in {p["key"] for p in case["request"]["pages"]}, case["text"]
        if exp and exp["name"] in schema.ACTION_SPECS:
            assert exp["name"] in case["request"]["actions"], case["text"]


MODEL_DIR = os.environ.get("DASHBOARD_VOICE_MODEL_DIR", r"D:\models\functiongemma-270m-it")


@pytest.mark.skipif(not Path(MODEL_DIR, "tokenizer.json").exists(), reason="base model not installed")
def test_call_format_matches_the_chat_template_and_token_ids():
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(MODEL_DIR, local_files_only=True)
    assert tok.convert_tokens_to_ids(schema.END_CALL) == copilot_model.END_CALL_ID
    tools = schema.build_tools(PAGES, ALL)
    base = [{"role": "developer", "content": schema.DEVELOPER_PROMPT}, {"role": "user", "content": "q"}]
    prompt = tok.apply_chat_template(base, tools=tools, add_generation_prompt=True, tokenize=False)
    assert schema.render_prompt(tok, "q", PAGES, ALL) == prompt + schema.PREFILL
    for target in (
        {"name": "search_orders", "args": {"salesperson": "Ahmad", "period": "this_week", "status": "approved"}},
        {"name": "set_item_status", "args": {"position": 2, "status": "in_review"}},
        {"name": "navigate_to_page", "args": {"page": "reports"}},
    ):
        full = tok.apply_chat_template(
            base + [{"role": "assistant", "tool_calls": [{"type": "function", "function": {
                "name": target["name"], "arguments": target["args"]}}]}],
            tools=tools, tokenize=False,
        )
        assert prompt + schema.PREFILL + schema.serialize_call(target) in full
    ids = tok(schema.serialize_call({"name": "no_match", "args": {}}), add_special_tokens=False)["input_ids"]
    assert ids[-1] == copilot_model.END_CALL_ID

from __future__ import annotations

import json
import math
import random
from datetime import datetime, timezone

import pytest

from scripts.synthetic_cleanup import cli
from scripts.synthetic_cleanup.test_synthetic_cleanup import EMULATOR_ENV, PROJECT, START, MemoryStore

MARK = {"syntheticBatchId": "batch-7"}
ORIGIN = {"dataOrigin": "synthetic_history"}
SIM = {"simulationBatchId": "sim-1"}
SHOP = {"isDemo": True, "retailerName": "AI-1 Riverside Mart"}
ITEM = {"isDemo": True, "productName": "P001 Classic Beverage"}
ALLOWED = ("route_plans", "route_plan_progress", "route_stop_progress", "conversation_outcomes", "purchase_orders",
           "ai_insights", "retailer_priority_rankings", "visit_briefs", "retailer_item_patterns",
           "weekly_ai_summaries", "retailer_segments", "retailer_memory", "retailers", "products")
MARKED_ALLOWED = ALLOWED[:-2]
OUTSIDE = ("orders", "users", "user_access", "branches", "system_audit_logs", "order_audit_logs", "visits",
           "dashboard_notifications", "ai_runs", "demand_forecasts", "route_plan_drafts")


class RelatedStore(MemoryStore):
    def __init__(self, documents, project=PROJECT):
        super().__init__(documents, project)
        self.queries = []
        self.after_count = {}

    def count(self, collection):
        self.touched.add(collection)
        found = sum(1 for key in self.documents if key[0] == collection)
        hook = self.after_count.pop(collection, None)
        if hook is not None:
            hook(self)
        self.reads += max(1, math.ceil(found / 1000))
        return found

    def first_equal(self, collection, name, value):
        self.touched.add(collection)
        self.queries.append((collection, name, value))
        self.reads += 1
        for key in sorted(self.documents):
            if key[0] == collection and self.documents[key][0].get(name) == value:
                return key[1]
        return None


class BreakingRelatedStore(RelatedStore):
    def __init__(self, documents, fail_on, error, applied):
        super().__init__(documents)
        self.fail_on, self.error, self.applied = fail_on, error, applied

    def delete_batch(self, items):
        if self.commits + 1 != self.fail_on:
            super().delete_batch(items)
            return
        self.fail_on = None
        if self.applied:
            super().delete_batch(items)
        else:
            self.commits += 1
        raise self.error


def run(store, expect, **options):
    settings = {"max_deletes": 1500, "max_reads": 6000, **options}
    return cli.delete_related(store, expect=expect, started=START, record=lambda row: None, say=lambda text: None,
                              **settings)


def planned(store):
    return {name: count for name, count in cli.inventory_related(store, max_reads=10 ** 6).summary["plannedDeletes"].items()
            if name != "total" and count}


WORLD = {
    "route_plans/P-1": ({**MARK, "date": "2025-03-02"}, "gone"),
    "route_plans/P-2": ({**ORIGIN, "date": "2025-04-06"}, "gone"),
    "route_plans/P-real": ({"date": "2026-11-16", "stops": [{"retailerId": "AI1_R004"}]}, "kept"),
    "route_plans/P-sim": ({**SIM}, "kept"),
    "route_plan_progress/P-1_real-uid": ({"planId": "P-1", "status": "done"}, "kept"),
    "route_plan_progress/P-1_syn": ({**MARK, "planId": "P-1"}, "gone"),
    "route_plan_progress/P-real_syn": ({**MARK, "planId": "P-real"}, "gone"),
    "route_stop_progress/P-1_real-uid_S1": ({"planId": "P-1", "retailerId": "AI1_R005"}, "kept"),
    "route_stop_progress/P-1_syn_S1": ({**ORIGIN, "planId": "P-1", "retailerId": "AI1_R006"}, "gone"),
    "conversation_outcomes/C-1": ({**MARK, "retailerId": "AI1_R001"}, "gone"),
    "conversation_outcomes/C-real": ({"retailerId": "R-9"}, "kept"),
    "purchase_orders/PO-orphan": ({**MARK}, "gone"),
    "purchase_orders/PO-real": ({"orderId": "PO-real"}, "kept"),
    "purchase_orders/PO-sim": ({**SIM}, "kept"),
    "ai_insights/I-1": ({**MARK}, "gone"),
    "ai_insights/I-2": ({"retailerId": "AI1_R001", "status": "new"}, "kept"),
    "retailer_priority_rankings/W-1": ({**ORIGIN}, "gone"),
    "visit_briefs/B-1": ({**MARK}, "gone"),
    "retailer_item_patterns/X-1": ({**MARK}, "gone"),
    "retailer_item_patterns/X-2": ({"retailerId": "AI1_R001"}, "kept"),
    "weekly_ai_summaries/S-1": ({**MARK}, "gone"),
    "retailer_segments/G-1": ({**ORIGIN}, "gone"),
    "retailer_memory/M-1": ({**MARK}, "gone"),
    "retailers/AI1_R001": ({**SHOP}, "gone"),
    "retailers/AI1_R002": ({**SHOP, "retailerName": "AI-1 Central Grocer"}, "kept"),
    "retailers/AI1_R003": ({**SHOP, "name": "AI-1 Market Square"}, "kept"),
    "retailers/AI1_R004": ({**SHOP}, "kept"),
    "retailers/AI1_R005": ({**SHOP}, "kept"),
    "retailers/AI1_R006": ({**SHOP}, "gone"),
    "retailers/AI1_R007": ({**SHOP}, "kept"),
    "retailers/AI1_R008": ({**SHOP, **MARK, "isDemo": "true"}, "kept"),
    "retailers/R-real": ({**MARK}, "kept"),
    "products/AI1_P001": ({**ITEM}, "kept"),
    "products/AI1_P002": ({**ITEM, "productName": "P002 Family Pack"}, "gone"),
    "products/AI1_P003": ({**ITEM}, "kept"),
    "products/P-real": ({**MARK, "isDemo": True}, "kept"),
    "orders/O-real": ({"retailerId": "AI1_R002", "items": [{"productId": "AI1_P001", "qty": 2}]}, "kept"),
    "orders/O-path": ({"shop": {"ref": "retailers/AI1_R003"}, "lines": [["products/AI1_P003"]]}, "kept"),
    "visits/V-1": ({"retailerId": "AI1_R007", "ownerUid": "real-uid"}, "kept"),
    **{f"{name}/marked": ({**MARK, **ORIGIN}, "kept") for name in OUTSIDE},
}
GONE = {path for path, (_, kind) in WORLD.items() if kind == "gone"}
EXPECT = {"route_plans": 2, "route_plan_progress": 2, "route_stop_progress": 1, "conversation_outcomes": 1,
          "purchase_orders": 1, "ai_insights": 1, "retailer_priority_rankings": 1, "visit_briefs": 1,
          "retailer_item_patterns": 1, "weekly_ai_summaries": 1, "retailer_segments": 1, "retailer_memory": 1,
          "retailers": 2, "products": 1}


def world_store(world=WORLD):
    return RelatedStore({path: data for path, (data, _) in world.items()})


def test_only_the_closed_set_is_deleted():
    store = world_store()
    run(store, EXPECT)
    assert set(WORLD) - store.paths() == GONE


def test_every_kept_document_is_unchanged():
    store = world_store()
    before = store.contents()
    run(store, EXPECT)
    assert store.contents() == {path: text for path, text in before.items() if path not in GONE}


def test_the_tool_reads_only_the_allowlist_orders_and_visits():
    store = world_store()
    run(store, EXPECT)
    assert store.touched == set(ALLOWED) | {"orders", "visits"}


def test_the_only_query_asks_visits_by_retailer_id_for_each_demo_shop():
    store = world_store()
    run(store, EXPECT)
    assert sorted(store.queries) == [("visits", "retailerId", f"AI1_R00{n}") for n in range(1, 8)]


@pytest.mark.parametrize("name", MARKED_ALLOWED)
@pytest.mark.parametrize("mark", [MARK, ORIGIN])
def test_a_marked_document_of_each_allowed_collection_is_deleted(name, mark):
    store = RelatedStore({f"{name}/D-1": {**mark}, f"{name}/D-2": {"plain": True}})
    run(store, {name: 1})
    assert store.paths() == {f"{name}/D-2"}


@pytest.mark.parametrize("name", OUTSIDE)
def test_a_marked_document_outside_the_allowlist_is_kept(name):
    store = RelatedStore({f"{name}/D-1": {**MARK}, "route_plans/P-1": {**MARK}})
    run(store, {"route_plans": 1})
    assert store.paths() == {f"{name}/D-1"}


@pytest.mark.parametrize("data", [{**SIM}, {"simulationBatchId": "sim-1", "dataOrigin": "simulation"},
                                  {"syntheticBatchId": False}, {"syntheticBatchId": 0}, {"syntheticBatchId": "  "},
                                  {"syntheticBatchId": ""}, {"syntheticBatchId": ["b"]},
                                  {"dataOrigin": "Synthetic_History"}, {"dataOrigin": "synthetic_history "},
                                  {"dataOrigin": ["synthetic_history"]}])
def test_a_near_miss_or_simulation_marker_keeps_the_document(data):
    store = RelatedStore({"route_plans/P-1": data, "route_plans/P-2": {**MARK}})
    run(store, {"route_plans": 1})
    assert store.paths() == {"route_plans/P-1"}


@pytest.mark.parametrize("doc_id", ["AI1-R001", "ai1_R001", "AI1_", "AI1_R001\n", "xAI1_R001", "AI1_R 01", "AI2_R001",
                                    "AI1_R.01"])
def test_a_shop_id_outside_the_demo_pattern_is_kept(doc_id):
    store = RelatedStore({f"retailers/{doc_id}": {**SHOP}, "retailers/AI1_R009": {**SHOP}})
    run(store, {"retailers": 1})
    assert store.paths() == {f"retailers/{doc_id}"}


@pytest.mark.parametrize("flag", ["true", 1, None, False, "True"])
def test_a_demo_shop_without_the_flag_true_is_kept(flag):
    store = RelatedStore({"retailers/AI1_R001": {"isDemo": flag}, "products/AI1_P001": {"isDemo": flag},
                          "retailers/AI1_R009": {**SHOP}})
    run(store, {"retailers": 1})
    assert store.paths() == {"retailers/AI1_R001", "products/AI1_P001"}


def test_a_demo_shop_with_no_flag_field_is_kept():
    store = RelatedStore({"retailers/AI1_R001": {"name": "x"}, "retailers/AI1_R009": {**SHOP}})
    run(store, {"retailers": 1})
    assert store.paths() == {"retailers/AI1_R001"}


@pytest.mark.parametrize("holder", [
    ("orders/O-1", {"retailerId": "AI1_R001"}),
    ("orders/O-1", {"retailer": {"path": "retailers/AI1_R001"}}),
    ("orders/O-1", {"notes": ["x", {"AI1_R001": 1}]}),
    ("visits/V-1", {"retailerId": "AI1_R001"}),
    ("route_stop_progress/P_u_S", {"retailerId": "AI1_R001"}),
    ("route_plans/P-real", {"stops": [{"retailerId": "AI1_R001"}]}),
    ("conversation_outcomes/C-1", {"retailerId": "AI1_R001"}),
    ("purchase_orders/PO-1", {"retailerId": "AI1_R001"}),
])
def test_a_demo_shop_named_by_a_kept_record_is_kept(holder):
    path, data = holder
    store = RelatedStore({"retailers/AI1_R001": {**SHOP}, path: data, "retailers/AI1_R009": {**SHOP}})
    run(store, {"retailers": 1})
    assert store.paths() == {"retailers/AI1_R001", path}


@pytest.mark.parametrize("path, data, expect, left", [
    ("route_plans/P-1", {**MARK, "stops": [{"retailerId": "AI1_R001"}]}, {"route_plans": 1, "retailers": 1}, set()),
    ("ai_insights/I-1", {"retailerId": "AI1_R001"}, {"retailers": 1}, {"ai_insights/I-1"}),
    ("retailers/AI1_R009", {**SHOP, "near": "AI1_R001"}, {"retailers": 2}, set()),
])
def test_a_demo_shop_named_only_by_a_deleted_record_or_a_job_output_is_deleted(path, data, expect, left):
    store = RelatedStore({"retailers/AI1_R001": {**SHOP}, path: data})
    run(store, expect)
    assert store.paths() == left


def test_a_demo_product_named_in_a_real_order_line_is_kept():
    store = RelatedStore({"products/AI1_P001": {**ITEM}, "products/AI1_P002": {**ITEM},
                          "orders/O-1": {"items": [{"productId": "AI1_P001", "qty": 1}]}})
    run(store, {"products": 1})
    assert store.paths() == {"products/AI1_P001", "orders/O-1"}


def test_a_demo_product_named_by_an_unmarked_stop_row_is_kept():
    store = RelatedStore({"products/AI1_P001": {**ITEM}, "route_stop_progress/P_u_S": {"productIds": ["AI1_P001"]}})
    run(store, {})
    assert store.paths() == {"products/AI1_P001", "route_stop_progress/P_u_S"}


def test_the_summary_lists_demo_records_to_delete_with_names_and_kept_ones_with_their_holder():
    summary = cli.inventory_related(world_store(), max_reads=6000).summary
    assert (summary["demoToDelete"], summary["demoKept"]) == (
        {"retailers": [["AI1_R001", "AI-1 Riverside Mart"], ["AI1_R006", "AI-1 Riverside Mart"]],
         "products": [["AI1_P002", "P002 Family Pack"]]},
        {"retailers": [["AI1_R002", "orders/O-real"], ["AI1_R003", "orders/O-path"], ["AI1_R004", "route_plans/P-real"],
                       ["AI1_R005", "route_stop_progress/P-1_real-uid_S1"], ["AI1_R007", "visits/V-1"]],
         "products": [["AI1_P001", "orders/O-real"], ["AI1_P003", "orders/O-path"]]})


def test_the_summary_reports_plan_groups_without_acting_on_them():
    summary = cli.inventory_related(world_store(), max_reads=6000).summary
    assert (summary["markedRowsWithoutAMarkedPlan"], summary["unmarkedRowsOnAMarkedPlan"]) == (
        ["route_plan_progress/P-real_syn"], ["route_plan_progress/P-1_real-uid", "route_stop_progress/P-1_real-uid_S1"])


def test_the_summary_counts_collections_dates_kept_outputs_and_simulation_rows():
    summary = cli.inventory_related(world_store(), max_reads=6000).summary
    assert (summary["collections"]["route_plans"], summary["unmarkedJobOutputsKept"], summary["simulationMarkedKept"],
            summary["plannedDeletes"]["total"]) == (
        {"total": 4, "delete": 2, "kept": 2, "firstDate": "2025-03-02", "lastDate": "2025-04-06"}, 2,
        {"route_plans": 1, "purchase_orders": 1}, 17)


def test_the_summary_counts_reads_with_one_count_read_per_collection():
    store = world_store()
    summary = cli.inventory_related(store, max_reads=6000).summary
    streamed = sum(1 for path in WORLD if path.split("/")[0] in (*ALLOWED, "orders"))
    assert summary["readsUsed"] == 15 + streamed + 7


@pytest.mark.parametrize("bad", [".", "..", "a\nb", "x\x7f"])
def test_a_marked_document_with_an_unsafe_id_is_kept_and_listed(bad):
    store = RelatedStore({f"route_plans/{bad}": {**MARK}, "route_plans/P-1": {**MARK}})
    report = run(store, {"route_plans": 1})
    assert (store.paths(), report["summary"]["unsafeIds"]) == ({f"route_plans/{bad}"}, {"route_plans": [bad]})


@pytest.mark.parametrize("change", [("route_plans", 1), ("retailers", -1), ("products", 1), ("ai_insights", -1)])
def test_an_expected_count_wrong_by_one_refuses_with_zero_writes(change):
    store = world_store()
    name, step = change
    with pytest.raises(cli.CleanupError):
        run(store, {**EXPECT, name: EXPECT[name] + step})
    assert (store.commits, store.paths()) == (0, set(WORLD))


def test_a_missing_expected_collection_refuses_with_zero_writes():
    store = world_store()
    with pytest.raises(cli.CleanupError):
        run(store, {name: count for name, count in EXPECT.items() if name != "visit_briefs"})
    assert store.commits == 0


def test_an_extra_expected_collection_refuses_with_zero_writes():
    store = RelatedStore({"route_plans/P-1": {**MARK}})
    with pytest.raises(cli.CleanupError):
        run(store, {"route_plans": 1, "products": 1})
    assert store.commits == 0


def test_max_deletes_below_the_plan_refuses_with_zero_writes():
    store = world_store()
    with pytest.raises(cli.CleanupError):
        run(store, EXPECT, max_deletes=16)
    assert store.commits == 0


def test_max_deletes_equal_to_the_plan_runs():
    store = world_store()
    report = run(store, EXPECT, max_deletes=17)
    assert sum(report["deleted"].values()) == 17


def test_the_default_max_deletes_is_fifteen_hundred():
    store = RelatedStore({f"route_plans/P-{n:04d}": {**MARK} for n in range(1501)})
    with pytest.raises(cli.CleanupError):
        cli.delete_related(store, expect={"route_plans": 1501}, max_reads=6000, started=START,
                           record=lambda row: None, say=lambda text: None)
    assert store.commits == 0


def test_the_counts_refuse_above_max_reads_before_any_document_is_read():
    store = RelatedStore({f"purchase_orders/PO-{n:04d}": {**MARK} for n in range(2500)})
    with pytest.raises(cli.ReadLimit):
        run(store, {"purchase_orders": 2500}, max_reads=2516)
    assert (store.commits, store.reads) == (0, 17)


def test_the_counts_allow_a_read_plan_equal_to_max_reads():
    store = RelatedStore({f"purchase_orders/PO-{n:04d}": {**MARK} for n in range(2500)})
    report = run(store, {"purchase_orders": 2500}, max_reads=2517, max_deletes=2500)
    assert report["deleted"]["purchase_orders"] == 2500


def test_the_visit_check_stops_at_max_reads_before_the_query():
    store = RelatedStore({"retailers/AI1_R001": {**SHOP}})
    with pytest.raises(cli.ReadLimit):
        run(store, {"retailers": 1}, max_reads=16)
    assert (store.commits, "visits" in store.touched) == (0, False)

def test_a_batch_holds_at_most_four_hundred_documents():
    store = RelatedStore({f"route_plans/P-{n:04d}": {**MARK} for n in range(900)})
    run(store, {"route_plans": 900})
    assert store.batch_sizes == [400, 400, 100]


def test_every_delete_carries_the_update_time_of_the_read():
    store = RelatedStore({"route_plans/P-1": {**MARK}, "retailers/AI1_R001": {**SHOP}})
    store.before_commit.append(lambda s: (s.change("route_plans/P-1", note="x"), s.change("retailers/AI1_R001", note="x")))
    report = run(store, {"route_plans": 1, "retailers": 1})
    assert (report["rereads"], store.commits) == (2, 5)


def test_a_document_changed_after_the_read_and_still_marked_is_read_again_and_deleted():
    store = RelatedStore({"route_plans/P-1": {**MARK, "status": "draft"}, "route_plans/P-2": {**MARK}})
    store.before_commit.append(lambda s: s.change("route_plans/P-1", status="published"))
    report = run(store, {"route_plans": 2})
    assert (store.paths(), report["deletedAfterReread"]) == (set(), ["route_plans/P-1"])


def test_a_document_changed_to_unmarked_is_read_again_and_kept():
    store = RelatedStore({"route_plans/P-1": {**MARK}, "route_plans/P-2": {**MARK}})
    store.before_commit.append(lambda s: s.drop_field("route_plans/P-1", "syntheticBatchId"))
    report = run(store, {"route_plans": 2})
    assert (store.paths(), report["keptAfterReread"]) == ({"route_plans/P-1"}, ["route_plans/P-1"])


def test_a_marker_changed_to_the_simulation_marker_after_the_read_keeps_the_document():
    store = RelatedStore({"ai_insights/I-1": {**MARK}})
    store.before_commit.append(lambda s: (s.drop_field("ai_insights/I-1", "syntheticBatchId"),
                                          s.change("ai_insights/I-1", simulationBatchId="sim-1")))
    run(store, {"ai_insights": 1})
    assert store.paths() == {"ai_insights/I-1"}


def test_a_demo_shop_whose_flag_is_cleared_after_the_read_is_kept():
    store = RelatedStore({"retailers/AI1_R001": {**SHOP}})
    store.before_commit.append(lambda s: s.change("retailers/AI1_R001", isDemo=False))
    report = run(store, {"retailers": 1})
    assert (store.paths(), report["keptAfterReread"]) == ({"retailers/AI1_R001"}, ["retailers/AI1_R001"])


def test_a_document_deleted_by_someone_else_after_the_read_is_reported_gone():
    store = RelatedStore({"route_plans/P-1": {**MARK}, "route_plans/P-2": {**MARK}})
    store.before_commit.append(lambda s: s.documents.pop(("route_plans", "P-1")))
    report = run(store, {"route_plans": 2})
    assert (report["goneBeforeDelete"], report["deleted"]["route_plans"]) == (["route_plans/P-1"], 1)


def test_a_document_that_keeps_changing_is_kept_after_three_reads():
    store = RelatedStore({"route_plans/P-1": {**MARK}})

    def change_each_commit(items, original=store.delete_batch):
        store.change("route_plans/P-1", n=store.commits)
        original(items)

    store.delete_batch = change_each_commit
    report = run(store, {"route_plans": 1})
    assert (store.paths(), report["rereads"], report["keptAfterReread"]) == ({"route_plans/P-1"}, 3, ["route_plans/P-1"])


def test_one_changed_document_in_a_full_batch_costs_one_extra_read():
    store = RelatedStore({f"route_plans/P-{n:04d}": {**MARK} for n in range(300)})
    store.before_commit.append(lambda s: s.change("route_plans/P-0100", note="touched"))
    report = run(store, {"route_plans": 300})
    assert (store.paths(), report["rereads"]) == (set(), 1)


@pytest.mark.parametrize("error, applied, reported", [
    (cli.ServiceError("503 UNAVAILABLE"), False, 500),
    (cli.ServiceError("deadline: the answer was lost"), True, 100),
    (cli.QuotaExhausted("RESOURCE_EXHAUSTED"), False, 500),
])
def test_a_stop_then_a_rerun_with_new_counts_finishes(error, applied, reported):
    world = {f"route_plans/P-{n:04d}": {**MARK} for n in range(500)}
    world["route_plans/KEEP"] = {}
    store = BreakingRelatedStore(world, 1, error, applied)
    first = run(store, {"route_plans": 500})
    second = run(store, planned(store))
    assert (first["stopped"] is not None, second["stopped"], store.paths(),
            first["deleted"]["route_plans"] + second["deleted"]["route_plans"]) == (True, None, {"route_plans/KEEP"}, reported)


def test_a_quota_stop_says_the_batch_was_not_deleted_and_lists_nothing_as_unanswered():
    store = BreakingRelatedStore({"route_plans/P-1": {**MARK}}, 1, cli.QuotaExhausted("RESOURCE_EXHAUSTED"), False)
    report = run(store, {"route_plans": 1})
    assert (report["unanswered"], "quota is used up" in report["stopped"], store.paths()) == ([], True, {"route_plans/P-1"})

def test_a_rerun_after_a_full_run_reads_again_and_deletes_nothing():
    store = world_store()
    run(store, EXPECT)
    commits = store.commits
    again = run(store, {})
    assert (again["deleted"], store.commits) == ({name: 0 for name in ALLOWED}, commits)


def _main(store, args, tmp_path, env=EMULATOR_ENV):
    return cli.main([*args, "--out", str(tmp_path)], env=env, open_store=lambda project: store, now=lambda: START)


def _apply(expect):
    return ["delete-related", "--apply", "--no-backup", "--project", PROJECT, "--confirm-project", PROJECT,
            *[part for name, count in expect.items() for part in ("--expect", f"{name}={count}")]]


def test_main_delete_related_deletes_the_closed_set(tmp_path, capsys):
    store = world_store()
    code = _main(store, _apply(EXPECT), tmp_path)
    assert (code, set(WORLD) - store.paths()) == (0, GONE)


def test_main_inventory_related_writes_nothing_to_the_database(tmp_path, capsys):
    store = world_store()
    code = _main(store, ["inventory-related", "--project", PROJECT], tmp_path)
    written = json.loads((tmp_path / "related-summary.json").read_text(encoding="utf-8"))
    assert (code, store.commits, written["plannedDeletes"]["total"]) == (0, 0, 17)


@pytest.mark.parametrize("bad", ["orders=1", "users=0", "route_plans", "route_plans=-1", "route_plans=1x",
                                 "Route_plans=1"])
def test_main_refuses_an_expected_count_that_is_not_an_allowed_collection_and_a_number(tmp_path, capsys, bad):
    store = world_store()
    with pytest.raises(SystemExit) as stop:
        _main(store, ["delete-related", "--apply", "--no-backup", "--project", PROJECT, "--confirm-project", PROJECT,
                      "--expect", bad], tmp_path)
    assert (stop.value.code, store.reads) == (2, 0)


def test_main_refuses_the_same_collection_expected_twice(tmp_path, capsys):
    store = world_store()
    with pytest.raises(SystemExit) as stop:
        _main(store, [*_apply({"route_plans": 2}), "--expect", "route_plans=2"], tmp_path)
    assert (stop.value.code, store.reads) == (2, 0)


def test_a_document_created_between_the_count_and_the_read_stops_with_zero_writes():
    store = RelatedStore({"route_plans/P-1": {**MARK}})
    store.after_count["route_plans"] = lambda s: s.put("route_plans/P-2", {**MARK})
    with pytest.raises(cli.ServiceError):
        run(store, {"route_plans": 2})
    assert store.commits == 0


def test_main_needs_the_project_twice(tmp_path, capsys):
    store = world_store()
    args = _apply(EXPECT)
    args[args.index("--confirm-project") + 1] = "demo-other"
    assert (_main(store, args, tmp_path), store.reads) == (2, 0)


@pytest.mark.parametrize("project, env", [("cos40005", {"FIRESTORE_EMULATOR_HOST": "127.0.0.1:1"}),
                                          ("demo-x", {}), ("demo-scoot-platform", EMULATOR_ENV)])
def test_main_refuses_a_wrong_environment_before_opening_the_store(tmp_path, capsys, project, env):
    opened = []
    code = cli.main(["delete-related", "--apply", "--no-backup", "--project", project, "--confirm-project", project,
                     "--out", str(tmp_path)], env=env, open_store=opened.append, now=lambda: START)
    assert (code, opened) == (1, [])


def test_main_stops_on_a_service_error_with_exit_four_and_no_traceback(tmp_path, capsys):
    store = BreakingRelatedStore({"route_plans/P-1": {**MARK}}, 1, cli.ServiceError("503 UNAVAILABLE"), False)
    code = _main(store, _apply({"route_plans": 1}), tmp_path)
    err = capsys.readouterr().err
    assert (code, "Traceback" in err, "Run inventory-related again" in err) == (4, False, True)


def test_the_log_records_each_delete_and_each_kept_document(tmp_path, capsys):
    store = RelatedStore({"route_plans/P-1": {**MARK}, "route_plans/P-2": {**MARK}})
    store.before_commit.append(lambda s: s.change("route_plans/P-1", syntheticBatchId=""))
    code = _main(store, _apply({"route_plans": 2}), tmp_path)
    rows = [json.loads(line) for line in (tmp_path / "delete-related-log.jsonl").read_text(encoding="utf-8").splitlines()]
    events = [(row["t"], row.get("documents")) for row in rows if row["t"] in ("deleted", "kept")]
    assert (code, events) == (3, [("kept", ["route_plans/P-1"]), ("deleted", ["route_plans/P-2"])])


def test_phase_one_delete_still_reads_only_orders_and_people(tmp_path, capsys):
    store = world_store()
    code = cli.main(["delete", "--apply", "--no-backup", "--project", PROJECT, "--confirm-project", PROJECT,
                     "--expect-orders", "1", "--expect-users", "0", "--out", str(tmp_path)],
                    env=EMULATOR_ENV, open_store=lambda project: store, now=lambda: START)
    assert (code, store.touched, set(WORLD) - store.paths()) == (0, {"orders", "users", "user_access"},
                                                                 {"orders/marked"})


def _generated(seed):
    rng = random.Random(seed)
    world, gone = {}, set()
    shapes = ("marked", "origin", "sim", "plain", "near")
    for n in range(rng.randint(10, 60)):
        name = rng.choice((*MARKED_ALLOWED, *OUTSIDE[1:]))
        shape = rng.choice(shapes)
        data = {"marked": {**MARK}, "origin": {**ORIGIN}, "sim": {**SIM}, "plain": {"status": "x"},
                "near": {"syntheticBatchId": " "}}[shape]
        world[f"{name}/D-{n}"] = data
        if name in MARKED_ALLOWED and shape in ("marked", "origin"):
            gone.add(f"{name}/D-{n}")
    for n in range(rng.randint(0, 6)):
        kind = rng.choice(("retailers", "products"))
        doc_id = rng.choice((f"AI1_X{n}", f"AI1_X{n}", f"AI1-X{n}", f"ai1_X{n}"))
        flag = rng.choice((True, True, "true", None))
        held = rng.random() < 0.3
        world[f"{kind}/{doc_id}"] = {"isDemo": flag}
        if held:
            world[f"orders/O-{n}"] = {"items": [{"productId": doc_id}], "retailerId": doc_id}
        if doc_id == f"AI1_X{n}" and flag is True and not held:
            gone.add(f"{kind}/{doc_id}")
    return world, gone


@pytest.mark.parametrize("seed", range(30))
def test_generated_worlds_delete_exactly_the_documents_labelled_gone(seed):
    world, gone = _generated(seed)
    store = RelatedStore(world)
    expect = {}
    for path in gone:
        expect[path.split("/")[0]] = expect.get(path.split("/")[0], 0) + 1
    run(store, expect)
    assert set(world) - store.paths() == gone


def test_generated_worlds_cover_every_kind_at_least_ten_times():
    seen = {"gone": 0, "kept": 0, "demo gone": 0, "demo kept": 0}
    for seed in range(30):
        world, gone = _generated(seed)
        for path in world:
            demo = path.startswith(("retailers/", "products/"))
            seen[("demo " if demo else "") + ("gone" if path in gone else "kept")] += 1
    assert min(seen.values()) >= 10


def test_main_exits_three_when_a_marked_document_is_kept_for_its_unsafe_id(tmp_path, capsys):
    store = RelatedStore({"route_plans/.": {**MARK}, "route_plans/P-1": {**MARK}})
    assert (_main(store, _apply({"route_plans": 1}), tmp_path), store.paths()) == (3, {"route_plans/."})
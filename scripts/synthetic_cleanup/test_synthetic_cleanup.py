from __future__ import annotations

import copy
import itertools
import json
import random
from datetime import datetime, timedelta, timezone

import pytest

from scripts.synthetic_cleanup import cli

PROJECT = "demo-strict"
EMULATOR_ENV = {"FIRESTORE_EMULATOR_HOST": "127.0.0.1:1", "FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:2"}
REAL = "Qx7Lm2Pa9Rt4Vb6Nc8Kd1Fe3Gh5J"
SYN = "synthetic-sales-001"
MARK = {"syntheticBatchId": "batch-7"}
START = datetime(2026, 11, 19, 3, tzinfo=timezone.utc)


def ms(moment):
    return int(moment.timestamp() * 1000)


class MemoryStore:
    def __init__(self, documents, project=PROJECT):
        self.project = project
        self.ticks = itertools.count(1)
        self.documents = {}
        for path, data in documents.items():
            self.put(path, data)
        self.reads = 0
        self.commits = 0
        self.batch_sizes = []
        self.touched = set()
        self.before_commit = []

    @staticmethod
    def split(path):
        collection, doc_id = path.split("/", 1)
        return collection, doc_id

    def _time(self, tick):
        return datetime(2026, 11, 18, tzinfo=timezone.utc) + timedelta(seconds=tick)

    def put(self, path, data):
        self.documents[self.split(path)] = (copy.deepcopy(data), self._time(next(self.ticks)))

    def change(self, path, **fields):
        key = self.split(path)
        self.documents[key] = ({**self.documents[key][0], **fields}, self._time(next(self.ticks)))

    def drop_field(self, path, name):
        key = self.split(path)
        data = dict(self.documents[key][0])
        del data[name]
        self.documents[key] = (data, self._time(next(self.ticks)))

    def stream(self, collection, limit):
        self.touched.add(collection)
        for key in sorted(key for key in self.documents if key[0] == collection)[:limit]:
            self.reads += 1
            data, moment = self.documents[key]
            yield key[1], copy.deepcopy(data), moment

    def read(self, collection, doc_id):
        self.touched.add(collection)
        self.reads += 1
        found = self.documents.get((collection, doc_id))
        return (copy.deepcopy(found[0]), found[1]) if found else None

    def delete_batch(self, items):
        while self.before_commit:
            self.before_commit.pop(0)(self)
        self.commits += 1
        for collection, doc_id, wanted in items:
            found = self.documents.get((collection, doc_id))
            if wanted is not None and (found is None or found[1] != wanted):
                raise cli.Refused(f"{collection}/{doc_id}")
        self.batch_sizes.append(len(items))
        for collection, doc_id, _ in items:
            self.documents.pop((collection, doc_id), None)

    def paths(self):
        return {f"{collection}/{doc_id}" for collection, doc_id in self.documents}

    def contents(self):
        return {f"{c}/{i}": json.dumps(data, sort_keys=True, default=str) for (c, i), (data, _) in self.documents.items()}


class BreakingStore(MemoryStore):
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


class FakeAuth:
    def __init__(self, accounts, wrong=()):
        self.accounts = dict(accounts)
        self.wrong = set(wrong)
        self.deleted = []
        self.fail = None

    def list_uids(self):
        return sorted(self.accounts)

    def get(self, uid):
        if self.fail:
            raise self.fail
        if uid not in self.accounts:
            return None
        return (uid + "x" if uid in self.wrong else uid), self.accounts[uid]

    def delete(self, uid):
        del self.accounts[uid]
        self.deleted.append(uid)


def run(store, expect_orders, expect_users, auth=None, **options):
    settings = {"max_deletes": cli.DEFAULT_MAX_DELETES, "max_reads": cli.DEFAULT_MAX_READS, **options}
    return cli.delete(store, auth, expect_orders=expect_orders, expect_users=expect_users, started=START,
                      record=lambda row: None, say=lambda text: None, **settings)


def counts(store):
    plan = cli.inventory(store, max_reads=10 ** 6)
    return len(plan.orders), len(plan.people[cli.USERS])


WORLD = {
    "orders/O-batch": {**MARK, "salesmanUid": REAL, "submittedAt": datetime(2025, 2, 3, tzinfo=timezone.utc)},
    "purchase_orders/O-batch": {"orderId": "O-batch"},
    "orders/O-origin": {"dataOrigin": "synthetic_history", "createdAt": "2025-03-04T10:00:00"},
    "orders/O-sim": {"simulationBatchId": "s-1", "salesmanUid": SYN},
    "orders/O-real": {"salesmanUid": REAL, "salesmanCode": "SYN12"},
    "purchase_orders/O-real": {**MARK},
    "orders/O-token-person": {"salesmanUid": SYN},
    "order_audit_logs/O-batch": {**MARK},
    "system_audit_logs/approved_O-batch": {**MARK},
    "route_plans/P-1": {**MARK},
    f"users/{SYN}": {"uid": SYN},
    f"user_access/{SYN}": {"uid": SYN},
    f"users/{REAL}": {**MARK},
}
WORLD_GONE = {"orders/O-batch", "purchase_orders/O-batch", "orders/O-origin", "orders/O-sim", f"users/{SYN}",
              f"user_access/{SYN}"}


def test_only_the_closed_set_is_deleted():
    store = MemoryStore(WORLD)
    before = store.contents()
    run(store, 3, 1)
    assert set(before) - store.paths() == WORLD_GONE


def test_every_kept_document_is_unchanged():
    store = MemoryStore(WORLD)
    before = store.contents()
    run(store, 3, 1)
    assert store.contents() == {path: text for path, text in before.items() if path not in WORLD_GONE}


@pytest.mark.parametrize("data", [{"syntheticBatchId": False}, {"syntheticBatchId": 0}, {"syntheticBatchId": "  "},
                                  {"syntheticBatchId": ""}, {"simulationBatchId": 5}, {"simulationBatchId": " \n"},
                                  {"dataOrigin": "Synthetic_History"}, {"dataOrigin": "synthetic_history "},
                                  {"dataOrigin": ["synthetic_history"]}])
def test_a_near_miss_marker_keeps_the_order(data):
    store = MemoryStore({"orders/O-1": data, "orders/O-2": {**MARK}})
    run(store, 1, 0)
    assert store.paths() == {"orders/O-1"}


def test_the_tool_reads_only_orders_and_the_two_people_collections():
    store = MemoryStore(WORLD)
    run(store, 3, 1)
    assert store.touched == {"orders", "users", "user_access"}


def test_a_purchase_order_created_after_the_read_goes_with_its_order():
    store = MemoryStore({"orders/O-1": {**MARK}})
    store.before_commit.append(lambda s: s.put("purchase_orders/O-1", {"orderId": "O-1"}))
    run(store, 1, 0)
    assert store.paths() == set()


def test_a_missing_purchase_order_does_not_stop_the_order_delete():
    store = MemoryStore({"orders/O-1": {**MARK}, "orders/O-2": {**MARK}, "purchase_orders/O-2": {}})
    report = run(store, 2, 0)
    assert (store.paths(), report["deleted"]["orders"], report["stopped"]) == (set(), 2, None)


def test_a_marked_purchase_order_of_an_unmarked_order_is_kept_and_never_read():
    store = MemoryStore({"orders/O-1": {"status": "approved"}, "purchase_orders/O-1": {**MARK}, "orders/O-2": {**MARK}})
    run(store, 1, 0)
    assert (store.paths(), "purchase_orders" in store.touched) == ({"orders/O-1", "purchase_orders/O-1"}, False)


def test_an_order_changed_after_the_read_and_still_marked_is_read_again_and_deleted():
    store = MemoryStore({"orders/O-1": {**MARK, "status": "pending"}})

    def approve(s):
        s.change("orders/O-1", status="approved")
        s.put("purchase_orders/O-1", {"orderId": "O-1"})

    store.before_commit.append(approve)
    report = run(store, 1, 0)
    assert (store.paths(), report["deletedAfterReread"]) == (set(), ["O-1"])


def test_an_order_changed_after_the_read_to_unmarked_is_read_again_and_kept():
    store = MemoryStore({"orders/O-1": {**MARK, "status": "pending"}})
    store.before_commit.append(lambda s: s.change("orders/O-1", syntheticBatchId="", status="approved"))
    report = run(store, 1, 0)
    assert (store.paths(), report["keptAfterReread"]) == ({"orders/O-1"}, ["O-1"])


def test_a_marker_removed_after_the_read_keeps_the_order_and_its_purchase_order():
    store = MemoryStore({"orders/O-1": {**MARK}, "purchase_orders/O-1": {"orderId": "O-1"}})
    store.before_commit.append(lambda s: s.drop_field("orders/O-1", "syntheticBatchId"))
    run(store, 1, 0)
    assert store.paths() == {"orders/O-1", "purchase_orders/O-1"}


def test_an_order_deleted_by_someone_else_after_the_read_is_reported_gone():
    store = MemoryStore({"orders/O-1": {**MARK}, "orders/O-2": {**MARK}})
    store.before_commit.append(lambda s: s.documents.pop(("orders", "O-1")))
    report = run(store, 2, 0)
    assert (report["goneBeforeDelete"], report["deleted"]["orders"]) == (["O-1"], 1)


def test_a_batch_holds_at_most_two_hundred_orders_and_their_purchase_orders():
    store = MemoryStore({f"orders/O-{n:04d}": {**MARK} for n in range(450)})
    run(store, 450, 0)
    assert store.batch_sizes == [400, 400, 100]


def test_one_changed_order_in_a_full_batch_costs_one_extra_read():
    store = MemoryStore({f"orders/O-{n:04d}": {**MARK} for n in range(300)})
    store.before_commit.append(lambda s: s.change("orders/O-0100", note="touched"))
    report = run(store, 300, 0)
    assert (store.paths(), report["rereads"], report["readsUsed"]) == (set(), 1, 301)


def test_files_named_like_an_old_manifest_or_journal_have_no_effect(tmp_path):
    forged = [{"t": "doc", "collection": "orders", "id": "O-real", "proof": "P1", "group": "orders/O-real"},
              {"t": "doc", "collection": "users", "id": REAL, "proof": "P2", "group": f"users/{REAL}"}]
    for name in ("manifest.jsonl", "manifest.jsonl.delete.journal", "delete-log.jsonl"):
        (tmp_path / name).write_text("".join(json.dumps({**row, "t": "refused"}) + "\n" for row in forged), encoding="utf-8")
    store = MemoryStore(WORLD)
    code = cli.main(["delete", "--apply", "--no-backup", "--project", PROJECT, "--confirm-project", PROJECT,
                     "--expect-orders", "3", "--expect-users", "1", "--out", str(tmp_path)],
                    env=EMULATOR_ENV, open_store=lambda project: store, now=lambda: START)
    assert (code, set(MemoryStore(WORLD).paths()) - store.paths()) == (0, WORLD_GONE)


@pytest.mark.parametrize("orders, users", [(2, 1), (4, 1), (3, 0), (3, 2)])
def test_expected_counts_wrong_by_one_refuse_with_zero_writes(orders, users):
    store = MemoryStore(WORLD)
    with pytest.raises(cli.CleanupError):
        run(store, orders, users)
    assert (store.commits, store.paths()) == (0, MemoryStore(WORLD).paths())


def test_max_deletes_below_the_plan_refuses_with_zero_writes():
    store = MemoryStore(WORLD)
    with pytest.raises(cli.CleanupError):
        run(store, 3, 1, max_deletes=7)
    assert store.commits == 0


def test_max_deletes_equal_to_the_plan_runs():
    store = MemoryStore(WORLD)
    report = run(store, 3, 1, max_deletes=8)
    assert report["deleted"] == {"orders": 3, "users": 1, "user_access": 1}


@pytest.mark.parametrize("bad", [".", "..", "a/b", "", "O\x01", "O\n"])
def test_a_marked_order_with_an_unsafe_id_is_kept_and_listed(bad):
    plan = cli.classify([(bad, {**MARK}, 1), ("O-1", {**MARK}, 2)], [], [])
    assert (sorted(plan.orders), plan.summary["unsafeOrderIds"]) == (["O-1"], [bad])


@pytest.mark.parametrize("uid", ["synthetic-sales-12\n", "Synthetic-sales-12", " synthetic-sales-12",
                                 "synthetic-sales-12a", "synthetic-sales-", "xsynthetic-sales-12", "SYN12"])
def test_a_near_miss_user_id_is_kept(uid):
    store = MemoryStore({f"users/{uid}": {"uid": SYN}, f"user_access/{uid}": {"uid": SYN}, f"users/{SYN}": {}})
    run(store, 0, 1)
    assert store.paths() == {f"users/{uid}", f"user_access/{uid}"}


def test_a_changed_token_profile_is_read_again_and_deleted():
    store = MemoryStore({f"users/{SYN}": {"role": "salesman"}})
    store.before_commit.append(lambda s: s.change(f"users/{SYN}", role="manager"))
    report = run(store, 0, 1)
    assert (store.paths(), report["rereads"]) == (set(), 1)


def test_the_summary_lists_the_ten_most_common_marker_values():
    rows = [(f"O-{n}-{k}", {"syntheticBatchId": f"b-{n:02d}"}, 1) for n in range(12) for k in range(n + 1)]
    assert cli.classify(rows, [], []).summary["markedByValue"] == [[f"syntheticBatchId=b-{n:02d}", n + 1]
                                                                   for n in range(11, 1, -1)]


@pytest.mark.parametrize("project, env, auth", [
    ("cos40005", {"FIRESTORE_EMULATOR_HOST": "127.0.0.1:1"}, False),
    ("cos40005", {"FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:2"}, True),
    ("cos40005", {"FIREBASE_AUTH_EMULATOR_HOST": ""}, False),
    ("demo-x", {}, False),
    ("demo-x", {"FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:2"}, False),
    ("demo-x", {"FIRESTORE_EMULATOR_HOST": "127.0.0.1:1"}, True),
    ("demo-scoot-platform", EMULATOR_ENV, False),
])
def test_the_environment_guard_refuses(project, env, auth):
    with pytest.raises(cli.CleanupError):
        cli.check_environment(project, env, auth_needed=auth, auth_injected=False)


@pytest.mark.parametrize("project, env, auth, injected", [
    ("cos40005", {}, True, False),
    ("demo-x", {"FIRESTORE_EMULATOR_HOST": "127.0.0.1:1"}, False, False),
    ("demo-x", EMULATOR_ENV, True, False),
    ("demo-x", {"FIRESTORE_EMULATOR_HOST": "127.0.0.1:1"}, True, True),
])
def test_the_environment_guard_allows(project, env, auth, injected):
    assert cli.check_environment(project, env, auth_needed=auth, auth_injected=injected) is None


def test_a_store_opened_on_another_project_is_refused(tmp_path, capsys):
    store = MemoryStore(WORLD, project="demo-other")
    code = cli.main(["inventory", "--project", PROJECT, "--out", str(tmp_path)], env=EMULATOR_ENV,
                    open_store=lambda project: store, now=lambda: START)
    assert (code, store.reads) == (1, 0)


def test_inventory_writes_nothing_and_prints_the_summary(tmp_path, capsys):
    store = MemoryStore(WORLD)
    code = cli.main(["inventory", "--project", PROJECT, "--out", str(tmp_path)], env=EMULATOR_ENV,
                    open_store=lambda project: store, now=lambda: START)
    written = json.loads((tmp_path / "summary.json").read_text(encoding="utf-8"))
    assert (code, store.commits, written["orders"]) == (0, 0, {"total": 5, "marked": 3, "unmarked": 2})


def test_the_summary_counts_values_months_people_and_reads():
    store = MemoryStore({**WORLD, "orders/O-sim2": {"simulationBatchId": "s-1", "submittedAt": "2025-02-28"}})
    summary = cli.inventory(store, max_reads=100).summary
    assert summary == {
        "orders": {"total": 6, "marked": 4, "unmarked": 2},
        "markedByValue": [["simulationBatchId=s-1", 2], ["dataOrigin=synthetic_history", 1],
                          ["syntheticBatchId=batch-7", 1]],
        "markedByMonth": {"2025-02": 2, "2025-03": 1, "no date": 1},
        "unsafeOrderIds": [],
        "tokenPeople": {"users": [SYN], "user_access": [SYN]},
        "keptPeople": {"users": 1, "user_access": 0},
        "unmarkedOrdersUnderATokenSalesperson": 1,
        "plannedDeletes": {"orders": 4, "purchaseOrderDeletesSent": 4, "users": 1, "user_access": 1, "total": 10},
        "readsUsed": 9,
    }


def test_the_read_limit_stops_the_inventory_before_any_write():
    store = MemoryStore({f"orders/O-{n}": {**MARK} for n in range(20)})
    with pytest.raises(cli.ReadLimit):
        run(store, 20, 0, max_reads=20)
    assert store.commits == 0


def test_the_read_limit_stops_a_reread_cleanly():
    store = MemoryStore({"orders/O-1": {**MARK}, "orders/O-2": {**MARK}})
    store.before_commit.append(lambda s: (s.change("orders/O-1", note="x"), s.change("orders/O-2", note="x")))
    report = run(store, 2, 0, max_reads=3)
    assert (report["stopped"].startswith("Stopped: the next read"), store.paths()) == (True, {"orders/O-2"})


@pytest.mark.parametrize("error, applied, reported", [
    (cli.ServiceError("503 UNAVAILABLE"), False, 500),
    (cli.ServiceError("deadline: the answer was lost"), True, 300),
    (cli.QuotaExhausted("RESOURCE_EXHAUSTED"), False, 500),
])
def test_a_stop_mid_run_then_a_rerun_with_new_counts_finishes_and_counts_each_delete_once(error, applied, reported):
    world = {f"orders/O-{n:04d}": {**MARK} for n in range(500)}
    world.update({f"users/{SYN}": {}, "orders/KEEP": {}})
    store = BreakingStore(world, 2, error, applied)
    first = run(store, 500, 1)
    orders, users = counts(store)
    second = run(store, orders, users)
    assert (first["stopped"] is not None, second["stopped"], store.paths(),
            first["deleted"]["orders"] + second["deleted"]["orders"]) == (True, None, {"orders/KEEP"}, reported)


def test_a_quota_stop_says_the_batch_was_not_deleted_and_lists_nothing_as_unanswered():
    store = BreakingStore({"orders/O-1": {**MARK}}, 1, cli.QuotaExhausted("RESOURCE_EXHAUSTED"), False)
    report = run(store, 1, 0)
    assert (report["unanswered"], "quota is used up" in report["stopped"], store.paths()) == ([], True, {"orders/O-1"})


def test_a_lost_answer_lists_the_orders_of_that_batch_as_unanswered():
    store = BreakingStore({"orders/O-1": {**MARK}}, 1, cli.ServiceError("503 UNAVAILABLE"), True)
    report = run(store, 1, 0)
    assert (report["unanswered"], report["deleted"]["orders"], store.paths()) == (["O-1"], 0, set())


@pytest.mark.parametrize("error", [cli.ServiceError("503 UNAVAILABLE"), cli.QuotaExhausted("RESOURCE_EXHAUSTED")])
def test_main_stops_on_a_service_error_with_exit_four_and_no_traceback(tmp_path, capsys, error):
    store = BreakingStore({"orders/O-1": {**MARK}}, 1, error, False)
    code = cli.main(["delete", "--apply", "--no-backup", "--project", PROJECT, "--confirm-project", PROJECT,
                     "--expect-orders", "1", "--expect-users", "0", "--out", str(tmp_path)],
                    env=EMULATOR_ENV, open_store=lambda project: store, now=lambda: START)
    err = capsys.readouterr().err
    assert (code, "Traceback" in err, "Run inventory again" in err) == (4, False, True)


def test_the_log_records_each_delete_and_refusal(tmp_path):
    store = MemoryStore({"orders/O-1": {**MARK}, "orders/O-2": {**MARK}})
    store.before_commit.append(lambda s: s.change("orders/O-1", syntheticBatchId=""))
    code = cli.main(["delete", "--apply", "--no-backup", "--project", PROJECT, "--confirm-project", PROJECT,
                     "--expect-orders", "2", "--expect-users", "0", "--out", str(tmp_path)],
                    env=EMULATOR_ENV, open_store=lambda project: store, now=lambda: START)
    rows = [json.loads(line) for line in (tmp_path / "delete-log.jsonl").read_text(encoding="utf-8").splitlines()]
    events = [(row["t"], row.get("orders")) for row in rows if row["t"] in ("deleted", "kept")]
    assert (code, events) == (3, [("kept", ["O-1"]), ("deleted", ["O-2"])])


def test_apply_needs_the_project_twice_and_no_backup(tmp_path, capsys):
    store = MemoryStore(WORLD)
    code = cli.main(["delete", "--apply", "--project", PROJECT, "--confirm-project", "demo-other",
                     "--expect-orders", "3", "--expect-users", "1", "--no-backup", "--out", str(tmp_path)],
                    env=EMULATOR_ENV, open_store=lambda project: store, now=lambda: START)
    assert (code, store.reads) == (2, 0)


AUTH_WORLD = {f"users/{SYN}": {}, f"user_access/{SYN}": {}, "users/synthetic-sales-002": {}}


def test_delete_auth_deletes_token_accounts_without_profiles_and_never_others():
    store = MemoryStore(AUTH_WORLD)
    auth = FakeAuth({SYN: None, "synthetic-sales-002": None, "synthetic-sales-009": None, REAL: None,
                     "synthetic-sales-12\n": None})
    run(store, 0, 2, auth=auth)
    assert sorted(auth.accounts) == sorted([REAL, "synthetic-sales-12\n"])


def test_delete_auth_keeps_an_account_whose_profile_exists_now():
    store = MemoryStore({f"users/{SYN}": {}})
    store.before_commit.append(lambda s: s.put("user_access/synthetic-sales-002", {}))
    auth = FakeAuth({SYN: None, "synthetic-sales-002": None})
    report = run(store, 0, 1, auth=auth)
    assert (sorted(auth.accounts), report["authRefused"]) == (["synthetic-sales-002"],
                                                              {"synthetic-sales-002": "a profile exists now"})


def test_delete_auth_refuses_when_the_fetched_uid_differs():
    store = MemoryStore({f"users/{SYN}": {}})
    auth = FakeAuth({SYN: None}, wrong={SYN})
    report = run(store, 0, 1, auth=auth)
    assert (auth.deleted, report["authRefused"]) == ([], {SYN: "the fetched account has another uid"})


@pytest.mark.parametrize("signed_in, deleted", [
    (START - cli.SIGN_IN_MARGIN - timedelta(seconds=1), [SYN]),
    (START - cli.SIGN_IN_MARGIN + timedelta(seconds=1), []),
    (START + timedelta(minutes=1), []),
])
def test_delete_auth_refuses_a_recent_sign_in(signed_in, deleted):
    store = MemoryStore({f"users/{SYN}": {}})
    auth = FakeAuth({SYN: ms(signed_in)})
    run(store, 0, 1, auth=auth)
    assert auth.deleted == deleted


def test_an_auth_error_stops_cleanly_and_a_rerun_finishes(tmp_path, capsys):
    store = MemoryStore({f"users/{SYN}": {}})
    auth = FakeAuth({SYN: None})
    auth.fail = cli.ServiceError("auth 500 INTERNAL")
    args = ["delete", "--apply", "--no-backup", "--project", PROJECT, "--confirm-project", PROJECT,
            "--expect-orders", "0", "--delete-auth", "--out", str(tmp_path)]
    first = cli.main([*args, "--expect-users", "1"], env=EMULATOR_ENV, open_store=lambda project: store,
                     open_auth=lambda project: auth, now=lambda: START)
    err = capsys.readouterr().err
    auth.fail = None
    second = cli.main([*args, "--expect-users", "0"], env=EMULATOR_ENV, open_store=lambda project: store,
                      open_auth=lambda project: auth, now=lambda: START)
    assert (first, "Traceback" in err, second, auth.accounts) == (4, False, 0, {})


def _generated(seed):
    rng = random.Random(seed)
    world, gone = {}, set()
    for n in range(rng.randint(5, 40)):
        order = f"O-{seed}-{n}"
        shape = rng.choice(["marked", "origin", "sim", "plain", "near", "token-person"])
        data = {"marked": {**MARK}, "origin": {"dataOrigin": "synthetic_history"}, "sim": {"simulationBatchId": "s"},
                "plain": {"status": "approved"}, "near": {"syntheticBatchId": " "},
                "token-person": {"salesmanUid": SYN}}[shape]
        world[f"orders/{order}"] = data
        with_po = rng.random() < 0.6
        if with_po:
            world[f"purchase_orders/{order}"] = {**MARK}
        if shape in ("marked", "origin", "sim"):
            gone.add(f"orders/{order}")
            if with_po:
                gone.add(f"purchase_orders/{order}")
    for n in range(rng.randint(0, 5)):
        uid = rng.choice([f"synthetic-sales-{n}", f"synthetic-sales-{n}x", f"Synthetic-sales-{n}"])
        for collection in ("users", "user_access"):
            if rng.random() < 0.7:
                world[f"{collection}/{uid}"] = {}
                if uid == f"synthetic-sales-{n}":
                    gone.add(f"{collection}/{uid}")
    return world, gone


@pytest.mark.parametrize("seed", range(30))
def test_generated_worlds_delete_exactly_the_documents_labelled_gone(seed):
    world, gone = _generated(seed)
    store = MemoryStore(world)
    orders = sum(1 for path in gone if path.startswith("orders/"))
    users = sum(1 for path in gone if path.startswith("users/"))
    run(store, orders, users)
    assert set(world) - store.paths() == gone

from __future__ import annotations

import copy
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.ai_simulation import job_outputs as jo
from scripts.ai_simulation.inputs import SimulationError

NOW = datetime(2026, 11, 19, tzinfo=timezone.utc)
OLD_RUN = "run_old"
NEW_RUN = "run_new"


class MemoryStore:
    def __init__(self, documents=None):
        self.docs = {path: (copy.deepcopy(data), None) for path, data in (documents or {}).items()}
        self.clock = 0
        self.docs = {path: (data, self._tick()) for path, (data, _) in self.docs.items()}
        self.list_calls = 0

    def _tick(self):
        self.clock += 1
        return {"$timestamp": [1_700_000_000 + self.clock, 0]}

    def count(self, collection):
        return sum(1 for path in self.docs if path.startswith(collection + "/"))

    def list(self, collection):
        self.list_calls += 1
        for path in sorted(self.docs):
            if path.startswith(collection + "/"):
                data, update_time = self.docs[path]
                yield path.split("/", 1)[1], copy.deepcopy(data), update_time

    def create(self, path, data):
        if path in self.docs:
            return False
        self.docs[path] = (copy.deepcopy(dict(data)), self._tick())
        return True

    def person_edit(self, path, **fields):
        data, _ = self.docs[path]
        self.docs[path] = ({**data, **fields}, self._tick())

    def data(self):
        return {path: data for path, (data, _) in self.docs.items()}


def stamp(seconds):
    return {"$timestamp": [seconds, 0]}


def run_doc(run_id, started):
    return {"runId": run_id, "status": "completed", "startedAt": stamp(started)}


def insight(run_id, week=1_700_000_000, **extra):
    return {"issueId": "x", "status": "new", "statusHistory": [], "sourceRunId": run_id, "lastObservedWeekStart": stamp(week), **extra}


def stale_store():
    return MemoryStore({
        f"ai_runs/{OLD_RUN}": run_doc(OLD_RUN, 100),
        f"ai_runs/{NEW_RUN}": run_doc(NEW_RUN, 200),
        "ai_insights/old_plain": insight(OLD_RUN),
        "ai_insights/old_acked": insight(OLD_RUN, status="acknowledged", acknowledgedBy="u1"),
        "ai_insights/old_note": insight(OLD_RUN, adminNotes="call him"),
        "ai_insights/new_plain": insight(NEW_RUN),
        "visit_briefs/old_brief": {"sourceRunId": OLD_RUN, "asOf": "2026-10-05", "status": "active"},
        "visit_briefs/new_brief": {"sourceRunId": NEW_RUN, "asOf": "2026-11-09", "status": "active"},
        "weekly_ai_summaries/week_old": {"sourceRunId": OLD_RUN, "weekStart": stamp(1_696_000_000)},
        "weekly_ai_summaries/scorecard_x": {"weekStart": stamp(1_696_000_000)},
        "dashboard_notifications/n_read": {"sourceRunId": OLD_RUN, "read": True, "readAt": stamp(5)},
        "dashboard_notifications/n_old": {"sourceRunId": OLD_RUN, "read": False},
        "dashboard_notifications/n_forecast": {"source": "forecasting_service"},
        "retailer_segments/seg_inactive_new": {"sourceRunId": NEW_RUN, "status": "inactive"},
    })


def job_write(store, path, **fields):
    stamp = jo.RUN_STAMPS.get(path.split("/", 1)[0])
    stamped = {**fields, **({stamp: NEW_RUN} if stamp else {})}
    if path in store.docs:
        store.person_edit(path, **stamped)
    else:
        store.create(path, stamped)
    return stamp is not None


def make_manifest(before_store, job, tmp_path):
    copy_file = tmp_path / "before.json"
    jo.take_copy(before_store, "demo-p", copy_file, 20000, NOW)
    job(before_store)
    before = json.loads(copy_file.read_text(encoding="utf-8"))
    return before, jo.build_diff(before, before_store, "demo-p", 20000, NOW, NEW_RUN)


def three_way_job(store):
    job_write(store, "ai_insights/created1", n=1)
    job_write(store, "ai_runs/r0", n=99)
    del store.docs["visit_briefs/gone"]


def seeded_store():
    return MemoryStore({
        "ai_runs/r0": {"n": 0},
        "ai_runs/r1": {"n": 1},
        "visit_briefs/gone": {"n": 5},
        "visit_briefs/keep": {"n": 6},
    })


def test_copy_refuses_above_cap_and_writes_nothing(tmp_path):
    store = MemoryStore({f"ai_insights/d{i}": {"n": i} for i in range(5)})
    out = tmp_path / "copy.json"
    with pytest.raises(SimulationError):
        jo.take_copy(store, "demo-p", out, 4, NOW)
    assert not out.exists()
    assert store.list_calls == 0


def test_copy_saves_only_job_collections_with_update_time(tmp_path):
    store = MemoryStore({"ai_insights/a": {"n": 1}, "orders/o1": {"n": 2}, "demand_forecasts/p_w": {"n": 3}})
    out = tmp_path / "copy.json"
    result = jo.take_copy(store, "demo-p", out, 20000, NOW)
    saved = json.loads(out.read_text(encoding="utf-8"))
    assert sorted(saved["documents"]) == ["ai_insights/a", "demand_forecasts/p_w"]
    assert saved["documents"]["ai_insights/a"]["updateTime"] == store.docs["ai_insights/a"][1]
    assert saved["project"] == "demo-p" and result["documents"] == 2


def test_copy_refuses_to_overwrite_an_earlier_copy(tmp_path):
    out = tmp_path / "copy.json"
    out.write_text("{}", encoding="utf-8")
    with pytest.raises(SimulationError):
        jo.take_copy(MemoryStore(), "demo-p", out, 10, NOW)


def test_diff_classifies_created_changed_unchanged_removed(tmp_path):
    _, manifest = make_manifest(seeded_store(), three_way_job, tmp_path)
    status = {row["path"]: (row["status"], row.get("owner")) for row in manifest["documents"]}
    assert status == {
        "ai_insights/created1": ("created", "job"),
        "ai_runs/r0": ("changed", "job"),
        "ai_runs/r1": ("unchanged", None),
        "visit_briefs/gone": ("removed", "otherWriter"),
        "visit_briefs/keep": ("unchanged", None),
    }
    assert manifest["counts"]["ai_runs"] == {"created": 0, "changed": 1, "unchanged": 1, "removed": 0}
    assert manifest["counts"]["visit_briefs"]["removed"] == 1


def test_stale_report_lists_exactly_what_the_newest_run_did_not_touch():
    store = stale_store()
    report = jo.stale_report(store, 20000)
    assert report["newestRunId"] == NEW_RUN
    insights = report["collections"]["ai_insights"]
    assert insights["touchedByNewestRun"] == 1
    assert insights["stale"] == ["ai_insights/old_plain"]
    assert insights["heldPersonField"] == ["ai_insights/old_acked", "ai_insights/old_note"]
    assert report["collections"]["visit_briefs"]["stale"] == ["visit_briefs/old_brief"]
    assert report["collections"]["visit_briefs"]["weeks"] == ["2026-10-05"]
    assert report["collections"]["weekly_ai_summaries"]["unstamped"] == 1
    assert report["collections"]["weekly_ai_summaries"]["weeks"] == ["2023-09-29"]
    assert report["collections"]["dashboard_notifications"]["stale"] == ["dashboard_notifications/n_old"]
    assert report["collections"]["dashboard_notifications"]["heldPersonField"] == ["dashboard_notifications/n_read"]
    assert report["collections"]["retailer_segments"]["touchedByNewestRun"] == 1


def test_stale_report_needs_a_completed_run():
    with pytest.raises(SimulationError):
        jo.stale_report(MemoryStore({"ai_insights/a": insight(OLD_RUN)}), 20000)


def test_job_collections_cover_every_collection_the_job_can_write():
    from forecasting.ai_service.repository import AI_RUNNER_WRITE_COLLECTIONS

    assert set(jo.AI_RUN_COLLECTIONS) == set(AI_RUNNER_WRITE_COLLECTIONS)


def test_cli_refuses_a_copy_above_the_cap_with_exit_1(monkeypatch, tmp_path):
    store = MemoryStore({f"ai_insights/d{i}": {"n": i} for i in range(5)})
    monkeypatch.setattr(jo, "open_store", lambda project: store)
    out = tmp_path / "c.json"
    assert jo.main(["copy", "--project", "demo-p", "--out", str(out), "--cap", "2"]) == 1
    assert not out.exists()


class WriteAttempt(AssertionError):
    pass


class _Watched:
    def __init__(self, db, allowed):
        self._db = db
        self._allowed = allowed

    def __getattr__(self, name):
        self._db.calls.append(name)
        if name not in self._allowed:
            self._db.refused.append(name)
            raise WriteAttempt(f"{type(self).__name__}.{name} was called")
        return object.__getattribute__(self, "_" + name)


class _Snapshot:
    def __init__(self, path, body):
        self.id = path.split("/", 1)[1]
        self.exists = body is not None
        self._body = body
        self.update_time = datetime(2026, 11, 19, 1, 2, 3, tzinfo=timezone.utc)

    def to_dict(self):
        return copy.deepcopy(self._body)


class _Aggregate:
    def __init__(self, value):
        self.value = value


class _CountQuery(_Watched):
    def __init__(self, db, total):
        super().__init__(db, {"get"})
        self._total = total

    def _get(self):
        return [[_Aggregate(self._total)]]


class _Collection(_Watched):
    def __init__(self, db, name):
        super().__init__(db, {"count", "stream"})
        self._name = name

    def _paths(self):
        return sorted(path for path in self._db.docs if path.split("/", 1)[0] == self._name)

    def _count(self):
        return _CountQuery(self._db, len(self._paths()))

    def _stream(self):
        return iter([_Snapshot(path, self._db.docs[path]) for path in self._paths()])


class ReadOnlyDb:
    def __init__(self, docs):
        self.docs = copy.deepcopy(docs)
        self.calls = []
        self.refused = []

    def __getattr__(self, name):
        self.calls.append(name)
        self.refused.append(name)
        raise WriteAttempt(f"db.{name} was called")

    def collection(self, name):
        self.calls.append("collection")
        return _Collection(self, name)


def _manifest_file(tmp_path):
    body = {"kind": "created", "mode": "apply", "project": "demo-p", "batchId": "sim-1", "seed": 7,
            "firstCutoff": "2026-11-16", "cutoff": "2026-11-16", "writeSet": "orders"}
    path = tmp_path / "sim-orders.json"
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


def test_copy_diff_provenance_and_stale_make_no_write_call_on_the_database(monkeypatch, tmp_path):
    docs = {
        f"ai_runs/{OLD_RUN}": {"runId": OLD_RUN, "status": "completed", "startedAt": datetime(2026, 11, 9, tzinfo=timezone.utc)},
        f"ai_runs/{NEW_RUN}": {"runId": NEW_RUN, "status": "completed", "startedAt": datetime(2026, 11, 16, tzinfo=timezone.utc)},
        "ai_insights/old_plain": {"issueId": "x", "status": "new", "sourceRunId": OLD_RUN},
        "ai_insights/fresh": {"issueId": "y", "status": "new", "sourceRunId": NEW_RUN},
        "demand_forecasts/p_w": {"pointForecast": 3},
    }
    db = ReadOnlyDb(docs)
    monkeypatch.setattr(jo, "_client", lambda project: db)
    copy_file, diff_file, provenance_file, stale_file = (tmp_path / name for name in ("c.json", "d.json", "p.json", "s.json"))
    assert jo.main(["copy", "--project", "demo-p", "--out", str(copy_file)]) == 0
    assert jo.main(["diff", "--before", str(copy_file), "--project", "demo-p", "--out", str(diff_file),
                    "--job-run-id", NEW_RUN, "--simulation-manifest", str(_manifest_file(tmp_path)),
                    "--provenance", str(provenance_file)]) == 0
    assert jo.main(["stale", "--project", "demo-p", "--out", str(stale_file)]) == 0
    assert db.refused == []
    assert set(db.calls) == {"collection", "count", "stream", "get"}
    assert db.docs == docs
    assert json.loads(copy_file.read_text(encoding="utf-8"))["documents"].keys() == {
        f"ai_runs/{OLD_RUN}", f"ai_runs/{NEW_RUN}", "ai_insights/old_plain", "ai_insights/fresh", "demand_forecasts/p_w"}
    assert json.loads(provenance_file.read_text(encoding="utf-8"))["jobRunId"] == NEW_RUN
    assert json.loads(stale_file.read_text(encoding="utf-8"))["collections"]["ai_insights"]["stale"] == ["ai_insights/old_plain"]


def test_a_write_call_on_the_database_is_seen_by_the_watch():
    db = ReadOnlyDb({})
    for attempt in (lambda: db.batch(), lambda: db.document("ai_runs/x"), lambda: db.collection("ai_runs").document("x"),
                    lambda: db.collection("ai_runs").add({}), lambda: db.transaction(), lambda: db.bulk_writer()):
        with pytest.raises(WriteAttempt):
            attempt()
    assert db.refused == ["batch", "document", "document", "add", "transaction", "bulk_writer"]


def test_job_output_undo_is_gone_and_the_cli_refuses_it():
    for name in ("undo_changes", "_plan_row"):
        assert not hasattr(jo, name), name
    for name in ("create", "replace_if", "delete_if", "read"):
        assert not hasattr(jo.FirestoreStore, name), name
    with pytest.raises(SystemExit) as stopped:
        jo.main(["undo", "--manifest", "m.json", "--apply", "--confirm-project", "demo-p"])
    assert stopped.value.code == 2

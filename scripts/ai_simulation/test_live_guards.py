from __future__ import annotations

import copy
import json
import re
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.ai_simulation import cli, demo_setup
from scripts.ai_simulation import job_outputs as jo
from scripts.ai_simulation.inputs import EXPORT_FORMAT, SimulationError, company_from_collections, resolve_team
from scripts.ai_simulation.simulate import Settings, simulate
from scripts.ai_simulation.test_ai_simulation import FIRST, NOW, ROSTER, MemoryStore, collections, simulation
from scripts.ai_simulation.test_demo_setup import OWNERS, PatchMemory, _shop_store, _shop_units, collections_21, roster_21
from scripts.ai_simulation.test_job_outputs import MemoryStore as JobStore

ROUTE_RECORDS = {"route_plans", "route_plan_progress", "route_stop_progress", "route_plan_publication_keys"}
JOB_RUN = "run_job"
OLD_RUN = "run_old"
PROVENANCE_SENTENCE = "Derived from simulated history. Not production evidence."


def _collections_of(paths):
    return {path.split("/", 1)[0] for path in paths}


@pytest.mark.parametrize("seed", (3, 7))
def test_route_records_are_planned_only_in_the_routes_set_with_no_audit_row_and_no_route_link_on_orders(seed):
    run = simulation(seed)
    planned = {name for name, rows in run.documents.items() if rows}
    assert planned == {"orders", "purchase_orders", "conversation_outcomes", *ROUTE_RECORDS}
    assert "system_audit_logs" not in run.documents
    for order in run.documents["orders"].values():
        assert "routePlanId" not in order and "routeStopId" not in order
        assert order["visitSource"] == "personal_planner"
    assert _collections_of(cli.planned_documents(run, "orders")) == {"orders", "purchase_orders"}
    assert _collections_of(cli.planned_documents(run, "routes")) == {"conversation_outcomes", *ROUTE_RECORDS}


def test_both_write_sets_applied_leave_no_audit_row(tmp_path):
    store = MemoryStore()
    run = simulation(7)
    for name in ("orders", "routes"):
        cli.apply_manifest(store, run, name, "alljoys-fixture", now=NOW, order_limit=900,
                           journal=tmp_path / f"{name}.json.journal")
    written = _collections_of(store.documents)
    assert written == {"orders", "purchase_orders", "conversation_outcomes", *ROUTE_RECORDS}
    assert all(data["simulationBatchId"] == run.settings.batch for data, _ in store.documents.values())
    outcomes = [path for path in store.documents if path.startswith("conversation_outcomes/")]
    assert outcomes and len(outcomes) == len(run.documents["conversation_outcomes"])


class CommitThenDrop(PatchMemory):
    def __init__(self, documents, drop_on):
        super().__init__(documents)
        self.drop_on = drop_on

    def update_unit(self, changes):
        result = super().update_unit(changes)
        if self.writes == self.drop_on:
            raise ConnectionError("the reply was lost after the commit")
        return result


def test_a_resume_never_adopts_an_intent_whose_commit_was_not_journaled(tmp_path):
    store = _shop_store(fail_after=3)
    journal = tmp_path / "shops.json.journal"
    with pytest.raises(ConnectionError):
        demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    pending = sorted(OWNERS)[3]
    store.fail_after = None
    store.person_edit(f"retailers/{pending}", assignedSalesmanId=OWNERS[pending])
    for name in demo_setup.LEGACY_ASSIGNMENT_FIELDS:
        store.documents[f"retailers/{pending}"][0].pop(name, None)
    person_state = copy.deepcopy(store.contents()[f"retailers/{pending}"])
    manifest = demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    rows = {row["unit"]: row for row in manifest["units"]}
    assert rows[f"retailers/{pending}"]["status"] == "check_by_hand"
    assert manifest["counts"]["check_by_hand"] == 1 and manifest["counts"]["written"] == 20
    report = demo_setup.undo_patch(store, manifest)
    assert report["checkByHand"] == [f"retailers/{pending}"]
    assert store.contents()[f"retailers/{pending}"] == person_state
    assert f"retailers/{pending}" not in report["restored"]


def test_a_commit_whose_reply_was_lost_is_listed_for_a_person_and_never_undone(tmp_path):
    store = CommitThenDrop({f"retailers/{key}": row for key, row in collections_21()["retailers"].items()}, drop_on=2)
    journal = tmp_path / "shops.json.journal"
    with pytest.raises(ConnectionError):
        demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    store.drop_on = None
    lost = sorted(OWNERS)[1]
    after_crash = copy.deepcopy(store.contents()[f"retailers/{lost}"])
    manifest = demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    assert {row["unit"]: row["status"] for row in manifest["units"]}[f"retailers/{lost}"] == "check_by_hand"
    demo_setup.undo_patch(store, manifest)
    assert store.contents()[f"retailers/{lost}"] == after_crash


class RaisingAfterCreate(MemoryStore):
    def __init__(self, raise_on):
        super().__init__()
        self.raise_on = raise_on
        self.creates = 0

    def create(self, path, data):
        made = super().create(path, data)
        self.creates += 1
        if self.creates == self.raise_on:
            raise ConnectionError("the reply was lost after the create")
        return made


def test_a_simulation_create_whose_reply_was_lost_is_checked_by_hand_not_claimed_or_deleted(tmp_path):
    store = RaisingAfterCreate(raise_on=3)
    run = simulation(7)
    journal = tmp_path / "o.json.journal"
    with pytest.raises(ConnectionError):
        cli.apply_manifest(store, run, "orders", "alljoys-fixture", now=NOW, order_limit=900, journal=journal)
    store.raise_on = None
    lost = list(cli.planned_documents(run, "orders"))[2]
    manifest = cli.apply_manifest(store, run, "orders", "alljoys-fixture", now=NOW, order_limit=900, journal=journal)
    rows = {row["path"]: row for row in manifest["documents"]}
    assert rows[lost]["status"] == "check_by_hand"
    assert manifest["counts"]["check_by_hand"] == 1
    report = cli.undo_manifest(store, manifest)
    assert lost in store.documents and lost in report["checkByHand"]
    assert lost not in report["deleted"]


def _job_store():
    return JobStore({
        f"ai_runs/{OLD_RUN}": {"runId": OLD_RUN, "status": "completed", "startedAt": {"$timestamp": [100, 0]}},
        "ai_insights/old": {"issueId": "a", "status": "new", "sourceRunId": OLD_RUN},
        "ai_insights/rewritten": {"issueId": "b", "status": "new", "sourceRunId": OLD_RUN, "score": 1},
        "visit_briefs/kept": {"sourceRunId": OLD_RUN, "asOf": "2026-11-09"},
        "demand_forecasts/p1_w": {"pointForecast": 3},
    })


def _job(store):
    store.create(f"ai_runs/{JOB_RUN}", {"runId": JOB_RUN, "status": "completed", "startedAt": {"$timestamp": [200, 0]}})
    store.create("ai_insights/fresh", {"issueId": "c", "status": "new", "sourceRunId": JOB_RUN})
    store.person_edit("ai_insights/rewritten", sourceRunId=JOB_RUN, score=9)
    store.person_edit("demand_forecasts/p1_w", pointForecast=4)


def _diff(store, tmp_path, between=None):
    copy_file = tmp_path / "copy.json"
    jo.take_copy(store, "demo-p", copy_file, 20000, NOW)
    if between:
        between(store)
    _job(store)
    before = json.loads(copy_file.read_text(encoding="utf-8"))
    return before, jo.build_diff(before, store, "demo-p", 20000, NOW, JOB_RUN)


def _person(store):
    store.person_edit("ai_insights/old", status="acknowledged", acknowledgedBy="u1")
    store.create("visit_briefs/by_hand", {"asOf": "2026-11-16", "note": "made by a person"})
    store.create("ai_insights/copied_stamp", {"issueId": "d", "status": "new", "sourceRunId": OLD_RUN})
    del store.docs["visit_briefs/kept"]


def test_diff_names_job_outputs_only_by_the_run_stamp_and_lists_every_other_writer(tmp_path):
    store = _job_store()
    _, manifest = _diff(store, tmp_path, between=_person)
    owners = {row["path"]: row["owner"] for row in manifest["documents"] if row["status"] != "unchanged"}
    assert owners == {
        f"ai_runs/{JOB_RUN}": "job",
        "ai_insights/fresh": "job",
        "ai_insights/rewritten": "job",
        "ai_insights/old": "otherWriter",
        "ai_insights/copied_stamp": "otherWriter",
        "visit_briefs/by_hand": "otherWriter",
        "visit_briefs/kept": "otherWriter",
        "demand_forecasts/p1_w": "notStamped",
    }


def test_a_job_output_a_person_acted_on_before_the_diff_is_another_writer(tmp_path):
    store = _job_store()
    copy_file = tmp_path / "copy.json"
    jo.take_copy(store, "demo-p", copy_file, 20000, NOW)
    _job(store)
    store.person_edit("ai_insights/fresh", status="acknowledged", acknowledgedBy="u1")
    store.person_edit("ai_insights/rewritten", adminNotes="call him")
    manifest = jo.build_diff(json.loads(copy_file.read_text(encoding="utf-8")), store, "demo-p", 20000, NOW, JOB_RUN)
    owners = {row["path"]: row.get("owner") for row in manifest["documents"]}
    assert owners["ai_insights/fresh"] == "otherWriter" and owners["ai_insights/rewritten"] == "otherWriter"


def test_an_unread_notification_the_job_created_is_job_output_and_a_read_one_is_another_writer():
    unread = {"data": {jo.RUN_STAMP_FIELD: JOB_RUN, "read": False, "readAt": None}}
    read = {"data": {jo.RUN_STAMP_FIELD: JOB_RUN, "read": True}}
    path = "dashboard_notifications/ai1_daily_admin_2026-11-19"
    assert jo.owner_of(path, None, unread, JOB_RUN) == jo.JOB
    assert jo.owner_of(path, None, read, JOB_RUN) == jo.OTHER_WRITER
    assert jo.owner_of(path, unread, read, JOB_RUN) == jo.OTHER_WRITER


def test_stale_delete_is_gone_and_the_cli_refuses_the_flag():
    assert not hasattr(jo, "stale_delete")
    with pytest.raises(SystemExit) as stopped:
        jo.main(["stale", "--project", "demo-p", "--delete"])
    assert stopped.value.code == 2


@pytest.mark.parametrize("status", ("running", "failed", "writing"))
def test_stale_never_calls_the_output_of_a_newer_unfinished_run_stale(status):
    store = JobStore({
        f"ai_runs/{OLD_RUN}": {"runId": OLD_RUN, "status": "completed", "startedAt": {"$timestamp": [100, 0]}},
        "ai_runs/run_mid": {"runId": "run_mid", "status": "completed", "startedAt": {"$timestamp": [200, 0]}},
        "ai_runs/run_late": {"runId": "run_late", "status": status, "startedAt": {"$timestamp": [300, 0]}},
        "ai_insights/from_old": {"issueId": "a", "status": "new", "sourceRunId": OLD_RUN},
        "ai_insights/from_mid": {"issueId": "b", "status": "new", "sourceRunId": "run_mid"},
        "ai_insights/from_late": {"issueId": "c", "status": "new", "sourceRunId": "run_late"},
    })
    report = jo.stale_report(store, 20000)
    insights = report["collections"]["ai_insights"]
    assert report["newestRunId"] == "run_mid"
    assert insights["stale"] == ["ai_insights/from_old"]
    assert insights["fromNewerUnfinishedRun"] == ["ai_insights/from_late"]


def _simulation_manifest(tmp_path, name, write_set):
    body = {"format": cli.MANIFEST_FORMAT, "kind": "created", "mode": "apply", "writeSet": write_set,
            "project": "demo-p", "batchId": "sim-20261116-7", "seed": 7, "firstCutoff": "2026-11-16",
            "cutoff": "2026-11-16", "runId": "abc", "documents": []}
    path = tmp_path / name
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


def test_diff_writes_a_provenance_file_that_names_every_affected_output(monkeypatch, tmp_path):
    store = _job_store()
    copy_file = tmp_path / "copy.json"
    jo.take_copy(store, "demo-p", copy_file, 20000, NOW)
    _job(store)
    monkeypatch.setattr(jo, "open_store", lambda project: store)
    orders = _simulation_manifest(tmp_path, "orders_applied.json", "orders")
    visits = _simulation_manifest(tmp_path, "routes_applied.json", "routes")
    diff_file = tmp_path / "diff.json"
    provenance_file = tmp_path / "provenance.json"
    code = jo.main(["diff", "--before", str(copy_file), "--project", "demo-p", "--out", str(diff_file),
                    "--job-run-id", JOB_RUN, "--simulation-manifest", str(orders), "--simulation-manifest", str(visits),
                    "--provenance", str(provenance_file)])
    assert code == 0
    body = json.loads(provenance_file.read_text(encoding="utf-8"))
    assert body["statement"] == PROVENANCE_SENTENCE
    assert body["simulationBatchId"] == "sim-20261116-7" and body["seed"] == 7
    assert body["firstCutoff"] == "2026-11-16" and body["cutoffs"] == ["2026-11-16"]
    assert body["jobRunId"] == JOB_RUN
    assert body["sourceManifests"] == [str(orders), str(visits)]
    assert body["copyFile"] == str(copy_file) and body["diffFile"] == str(diff_file)
    assert body["affectedOutputs"] == {"ai_insights": ["fresh", "rewritten"], "ai_runs": [JOB_RUN]}
    assert body["unstampedChanges"] == {"demand_forecasts": ["p1_w"]}


def test_diff_refuses_manifests_of_two_batches(monkeypatch, tmp_path):
    store = _job_store()
    copy_file = tmp_path / "copy.json"
    jo.take_copy(store, "demo-p", copy_file, 20000, NOW)
    monkeypatch.setattr(jo, "open_store", lambda project: store)
    first = _simulation_manifest(tmp_path, "a.json", "orders")
    other = json.loads(first.read_text(encoding="utf-8"))
    second = tmp_path / "b.json"
    second.write_text(json.dumps({**other, "batchId": "sim-20261123-7"}), encoding="utf-8")
    code = jo.main(["diff", "--before", str(copy_file), "--project", "demo-p", "--out", str(tmp_path / "d.json"),
                    "--job-run-id", JOB_RUN, "--simulation-manifest", str(first), "--simulation-manifest", str(second),
                    "--provenance", str(tmp_path / "p.json")])
    assert code == 1 and not (tmp_path / "d.json").exists() and not (tmp_path / "p.json").exists()


def _export(tmp_path, data, project="demo-fixture"):
    from platform_service.tenant_snapshot import encode

    path = tmp_path / "export.json"
    path.write_text(json.dumps({
        "format": EXPORT_FORMAT, "project": project, "takenAt": "2026-11-19T00:00:00+00:00",
        "collections": {name: {doc_id: encode(row) for doc_id, row in rows.items()} for name, rows in data.items()},
    }), encoding="utf-8")
    return path


def _roster_file(tmp_path, body):
    path = tmp_path / "roster.json"
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


def test_staff_refuses_to_print_a_plan_when_the_two_roster_copies_of_a_supervisor_disagree(tmp_path, capsys):
    data = collections()
    data["user_access"]["sup-d"]["assignedSalesmanCodes"] = ["S02"]
    code = demo_setup.main(["staff", "--export", str(_export(tmp_path, data)),
                            "--roster", str(_roster_file(tmp_path, ROSTER)), "--out", str(tmp_path / "plan.json")])
    shown = capsys.readouterr()
    assert code == 3 and not (tmp_path / "plan.json").exists()
    assert "instructions" not in shown.out
    cases = json.loads(shown.out)["rosterConflicts"]
    assert cases == [{"supervisorUid": "sup-d", "problem": "the users and user_access rosters differ",
                      "onlyInUsers": ["S03"], "onlyInUserAccess": []}]


def test_staff_refuses_a_salesperson_code_that_sits_in_two_rosters(tmp_path, capsys):
    data = collections()
    for name in ("users", "user_access"):
        data[name]["sup-c"]["assignedSalesmanCodes"] = ["s05"]
    code = demo_setup.main(["staff", "--export", str(_export(tmp_path, data)),
                            "--roster", str(_roster_file(tmp_path, ROSTER))])
    cases = json.loads(capsys.readouterr().out)["rosterConflicts"]
    assert code == 3
    assert cases == [{"salespersonCode": "S05", "problem": "the code is on more than one roster",
                      "supervisorUids": ["sup-a", "sup-c"]}]


def test_staff_prints_the_plan_when_the_rosters_agree(tmp_path, capsys):
    code = demo_setup.main(["staff", "--export", str(_export(tmp_path, collections())),
                            "--roster", str(_roster_file(tmp_path, ROSTER))])
    assert code == 0 and "instructions" in json.loads(capsys.readouterr().out)


def _roster_store(roster):
    return PatchMemory({"users/doc-a": {"role": "supervisor", "assignedSalesmanCodes": list(roster)},
                        "user_access/uid-a": {"role": "supervisor", "assignedSalesmanCodes": list(roster)}})


def test_roster_clear_refuses_a_held_code_in_any_spelling():
    store = _roster_store(["S01", "SYN001", "S02"])
    with pytest.raises(SimulationError, match="S02"):
        demo_setup.roster_clear_changes(store, "doc-a", "uid-a", ["SYN001", "s02"], user_codes={"S01", "S02"})
    units = demo_setup.roster_clear_changes(store, "doc-a", "uid-a", ["SYN001"], user_codes={"S01", "S02"})
    assert units[0]["unit"] == "roster-clear/uid-a"


def test_roster_clear_keeps_a_code_added_between_the_plan_and_the_write(tmp_path):
    store = _roster_store(["S01", "SYN001"])
    units = demo_setup.roster_clear_changes(store, "doc-a", "uid-a", ["SYN001"], user_codes={"S01"})
    for path in ("users/doc-a", "user_access/uid-a"):
        store.person_edit(path, assignedSalesmanCodes=["S01", "SYN001", "S07"])
    manifest = demo_setup.apply_patch(store, "roster-clear", "p", units, tmp_path / "r.journal")
    assert manifest["counts"] == {"written": 1}
    assert {path: row["assignedSalesmanCodes"] for path, row in store.contents().items()} == {
        "users/doc-a": ["S01", "S07"], "user_access/uid-a": ["S01", "S07"]}
    demo_setup.undo_patch(store, manifest)
    assert store.contents()["users/doc-a"]["assignedSalesmanCodes"] == ["S01", "SYN001", "S07"]


def test_roster_clear_on_the_command_line_refuses_an_active_salesperson_code(monkeypatch, tmp_path, capsys):
    store = _roster_store(["S01", "SYN001"])
    monkeypatch.setattr(demo_setup, "FirestorePatchStore", lambda db: store)
    monkeypatch.setattr(demo_setup, "_client", lambda project: object())
    monkeypatch.setattr(demo_setup, "live_company", lambda project: company_from_collections(project, collections()))
    code = demo_setup.main(["roster-clear", "--project", "demo-p", "--users-doc", "doc-a", "--uid", "uid-a",
                            "--codes", "SYN001,S01", "--manifest", str(tmp_path / "m.json")])
    assert code == 1 and "S01" in capsys.readouterr().err and not (tmp_path / "m.json").exists()


def _company_with_resting_users():
    data = collections()
    data["users"]["sp-02"]["status"] = "suspended"
    data["user_access"]["sp-02"]["status"] = "suspended"
    data["users"]["sp-03"]["status"] = "inactive"
    data["user_access"]["sp-03"]["isActive"] = False
    data["user_access"]["sp-03"]["status"] = "inactive"
    del data["users"]["sp-04"]
    data["user_access"]["sp-04"]["status"] = "disabled"
    data["users"]["sp-05"].pop("status")
    data["user_access"]["sp-05"].pop("status")
    return company_from_collections("demo-p", data)


@pytest.mark.parametrize("code", ("S02", "s03", "S04", "S05", "S01"))
def test_roster_clear_refuses_the_code_of_any_user_record_whatever_its_status(monkeypatch, tmp_path, capsys, code):
    store = _roster_store(["S01", "S02", "S03", "S04", "S05", "GONE1"])
    monkeypatch.setattr(demo_setup, "FirestorePatchStore", lambda db: store)
    monkeypatch.setattr(demo_setup, "_client", lambda project: object())
    monkeypatch.setattr(demo_setup, "live_company", lambda project: _company_with_resting_users())
    result = demo_setup.main(["roster-clear", "--project", "demo-p", "--users-doc", "doc-a", "--uid", "uid-a",
                              "--codes", code, "--manifest", str(tmp_path / "m.json")])
    assert result == 1 and code.upper() in capsys.readouterr().err and not (tmp_path / "m.json").exists()


def test_roster_clear_clears_a_code_that_no_user_record_holds(monkeypatch, tmp_path, capsys):
    store = _roster_store(["S01", "S02", "S03", "S04", "S05", "GONE1"])
    monkeypatch.setattr(demo_setup, "FirestorePatchStore", lambda db: store)
    monkeypatch.setattr(demo_setup, "_client", lambda project: object())
    monkeypatch.setattr(demo_setup, "live_company", lambda project: _company_with_resting_users())
    result = demo_setup.main(["roster-clear", "--project", "demo-p", "--users-doc", "doc-a", "--uid", "uid-a",
                              "--codes", "gone1", "--manifest", str(tmp_path / "m.json")])
    assert result == 0
    manifest = json.loads((tmp_path / "m.json").read_text(encoding="utf-8"))
    assert manifest["counts"] == {"would_change": 1}
    assert [change["set"]["assignedSalesmanCodes"] for change in manifest["units"][0]["changes"]] == [
        ["S01", "S02", "S03", "S04", "S05"], ["S01", "S02", "S03", "S04", "S05"]]


class Opened:
    def __init__(self, project):
        self.project = project


@pytest.mark.parametrize("project, emulator", [("cos40005", "127.0.0.1:8293"), ("demo-fixture", None)])
def test_the_client_refuses_a_live_project_on_the_emulator_and_a_demo_project_off_it(monkeypatch, project, emulator):
    import platform_service.migrate_seats as seats
    import scripts.fill_order_owners as owners

    opened = []
    monkeypatch.setattr(seats, "_client", lambda name, database: opened.append(name) or Opened(name))
    monkeypatch.setattr(owners, "is_control_centre", lambda db: False)
    if emulator:
        monkeypatch.setenv("FIRESTORE_EMULATOR_HOST", emulator)
    else:
        monkeypatch.delenv("FIRESTORE_EMULATOR_HOST", raising=False)
    with pytest.raises(SimulationError):
        cli._client(project)
    assert opened == []


@pytest.mark.parametrize("project, emulator", [("cos40005", None), ("demo-fixture", "127.0.0.1:8293")])
def test_the_client_opens_a_live_project_off_the_emulator_and_a_demo_project_on_it(monkeypatch, project, emulator):
    import platform_service.migrate_seats as seats
    import scripts.fill_order_owners as owners

    monkeypatch.setattr(seats, "_client", lambda name, database: Opened(name))
    monkeypatch.setattr(owners, "is_control_centre", lambda db: False)
    if emulator:
        monkeypatch.setenv("FIRESTORE_EMULATOR_HOST", emulator)
    else:
        monkeypatch.delenv("FIRESTORE_EMULATOR_HOST", raising=False)
    assert cli._client(project).project == project


class FixedNow(datetime):
    moment = datetime(2026, 11, 19, 3, 0, tzinfo=timezone.utc)

    @classmethod
    def now(cls, tz=None):
        return cls.moment


@pytest.mark.parametrize("today", (date(2026, 11, 19), date(2026, 11, 20), date(2026, 11, 26), date(2026, 12, 2)))
def test_the_write_dry_run_of_the_live_commands_works_on_19_november_and_any_later_day(monkeypatch, tmp_path, today, capsys):
    FixedNow.moment = datetime(today.year, today.month, today.day, 3, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(cli, "datetime", FixedNow)
    export = _export(tmp_path, collections())
    roster = _roster_file(tmp_path, ROSTER)
    for name in ("orders", "routes"):
        code = cli.main(["write", "--set", name, "--export", str(export), "--roster", str(roster),
                         "--manifest", str(tmp_path / f"{name}_plan.json"), "--first-cutoff", "2026-11-16"])
        assert code == 0, capsys.readouterr().err
        assert json.loads((tmp_path / f"{name}_plan.json").read_text(encoding="utf-8"))["firstCutoff"] == "2026-11-16"


def _hidden_shop_data():
    data = collections_21()
    data["retailers"]["R007"]["status"] = "Hide"
    data["retailers"]["R015"]["status"] = "hidden"
    data["retailers"]["R003"]["status"] = "active"
    return data


def test_the_shops_dry_run_names_every_shop_that_is_not_active(monkeypatch, tmp_path, capsys):
    data = _hidden_shop_data()
    store = PatchMemory({f"retailers/{key}": row for key, row in data["retailers"].items()})
    monkeypatch.setattr(demo_setup, "FirestorePatchStore", lambda db: store)
    monkeypatch.setattr(demo_setup, "_client", lambda project: object())
    code = demo_setup.main(["shops", "--export", str(_export(tmp_path, data)),
                            "--roster", str(_roster_file(tmp_path, roster_21())), "--manifest", str(tmp_path / "s.json")])
    shown = json.loads(capsys.readouterr().out)
    assert code == 0
    assert shown["notActiveShops"] == [
        {"shopId": "R007", "status": "Hide", "owner": OWNERS["R007"]},
        {"shopId": "R015", "status": "hidden", "owner": OWNERS["R015"]},
    ]


def test_the_write_dry_run_names_every_shop_that_is_not_active_and_gets_orders(tmp_path, capsys):
    data = _hidden_shop_data()
    code = cli.main(["write", "--set", "orders", "--export", str(_export(tmp_path, data)),
                     "--roster", str(_roster_file(tmp_path, roster_21())), "--manifest", str(tmp_path / "o.json"),
                     "--first-cutoff", "2026-11-16"])
    shown = json.loads(capsys.readouterr().out)
    assert code == 0
    assert [row["shopId"] for row in shown["notActiveShops"]] == ["R007", "R015"]
    assert all(row["orders"] > 0 for row in shown["notActiveShops"])

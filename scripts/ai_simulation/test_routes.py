from __future__ import annotations

import dataclasses
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forecasting.ai_core.calendar import ASIA_KUCHING, week_start
from scripts.ai_simulation import cli
from scripts.ai_simulation import simulate as simulate_module
from scripts.ai_simulation.inputs import SimulationError, company_from_collections, resolve_team
from scripts.ai_simulation.simulate import Settings, simulate
from scripts.ai_simulation.test_ai_simulation import FIRST, NOW, ROSTER, MemoryStore, collections, simulation, team
from scripts.ai_simulation.test_live_guards import Opened, _export, _roster_file

ROUTE_SET = {"route_plans", "route_plan_progress", "route_stop_progress", "route_plan_publication_keys",
             "conversation_outcomes"}
AUTHOR_FIELDS = ("createdByUid", "approvedByUid", "publishedByUid", "updatedByUid", "issuedByUid")
SALESPEOPLE = {"sp-01": "S01", "sp-02": "S02", "sp-03": "S03", "sp-04": "S04"}


def _planned(run, kept=()):
    return cli.planned_documents(run, "routes", skipped_groups=frozenset(kept))


def _of(planned, collection):
    return {path.split("/", 1)[1]: data for path, data in planned.items() if path.startswith(collection + "/")}


def reader_problems(planned):
    problems = []
    plans = _of(planned, "route_plans")
    progress = _of(planned, "route_plan_progress")
    stops = _of(planned, "route_stop_progress")
    keys = _of(planned, "route_plan_publication_keys")
    for plan_id, plan in plans.items():
        for field in ("salesmanUid", "salesmanCode", "branchId"):
            if not isinstance(plan.get(field), str) or not plan[field]:
                problems.append(f"plan {plan_id} has no {field}")
        if plan.get("planId") != plan_id or plan.get("status") != "published" or plan.get("isDemo") is not False:
            problems.append(f"plan {plan_id} is not a published, non-demo plan under its own id")
        if not isinstance(plan.get("weekStart"), datetime) or not isinstance(plan.get("weekEnd"), datetime):
            problems.append(f"plan {plan_id} has no week dates")
        days = plan.get("days")
        if not isinstance(days, list) or not days:
            problems.append(f"plan {plan_id} has no days")
            continue
        listed = []
        for day in days:
            if not isinstance(day, dict) or not isinstance(day.get("stops"), list) or not day.get("dayId"):
                problems.append(f"plan {plan_id} has a day the readers cannot read")
                continue
            for stop in day["stops"]:
                if not stop.get("stopId") or not stop.get("retailerId") or not isinstance(stop.get("sequence"), int):
                    problems.append(f"plan {plan_id} has a stop with no stopId, retailerId or sequence")
                listed.append(stop.get("stopId"))
        owner = plan.get("salesmanUid")
        record = progress.get(f"{plan_id}_{owner}")
        if record is None:
            problems.append(f"plan {plan_id} has no progress document under planId_salesmanUid")
        else:
            if record.get("planId") != plan_id or record.get("salesmanUid") != owner:
                problems.append(f"progress of {plan_id} does not name its plan and salesperson")
            if record.get("salesmanCode") != plan.get("salesmanCode") or record.get("branchId") != plan.get("branchId"):
                problems.append(f"progress of {plan_id} cannot be read by the supervisor or branch manager")
            if not isinstance(record.get("updatedAt"), datetime):
                problems.append(f"progress of {plan_id} has no updatedAt")
        for stop_id in listed:
            stop = stops.get(f"{plan_id}_{owner}_{stop_id}")
            if stop is None:
                problems.append(f"stop {stop_id} of {plan_id} has no stop progress under planId_salesmanUid_stopId")
                continue
            if stop.get("planId") != plan_id or stop.get("stopId") != stop_id or not stop.get("retailerId"):
                problems.append(f"stop progress {stop_id} of {plan_id} does not name its plan, stop and shop")
            if stop.get("status") not in ("completed", "skipped"):
                problems.append(f"stop progress {stop_id} of {plan_id} is not decided")
            moment = stop.get("completedAt") if stop.get("status") == "completed" else stop.get("skippedAt")
            if not isinstance(stop.get("arrivedAt"), datetime) or not isinstance(moment, datetime):
                problems.append(f"stop progress {stop_id} of {plan_id} has no arrival or decision time")
            for field in ("salesmanUid", "salesmanCode", "branchId"):
                if stop.get(field) != plan.get(field):
                    problems.append(f"stop progress {stop_id} of {plan_id} has a wrong {field}")
        key_id = f"{owner}_{week_start(plan['weekStart']):%Y%m%d}"
        key = keys.get(key_id)
        if key is None or key.get("planId") != plan_id or key.get("active") is not True or key.get("keyId") != key_id:
            problems.append(f"plan {plan_id} has no active publication key {key_id}")
    return problems


def scorecard_numbers(rows, uid, code, now):
    start = now - timedelta(days=56)
    progress_plans = {
        data["planId"] for path, data in rows.items()
        if path.startswith("route_plan_progress/") and start <= data["updatedAt"] <= now
        and (data.get("salesmanUid") == uid or data.get("salesmanCode", "").lower() == code.lower())
    }
    decided = completed = skipped = 0
    for path, data in rows.items():
        if not path.startswith("route_stop_progress/") or data.get("planId") not in progress_plans:
            continue
        if not start <= data["arrivedAt"] <= now:
            continue
        status = str(data.get("status", "")).strip().lower()
        completed += status == "completed"
        skipped += status == "skipped"
    decided = completed + skipped
    return {"decidedVisits": decided, "completed": completed, "skipped": skipped,
            "completionRate": round(completed / decided, 3) if decided >= 3 else None}


def test_the_routes_set_holds_one_published_plan_group_per_salesperson_and_past_week():
    run = simulation(7)
    planned = _planned(run)
    assert {path.split("/", 1)[0] for path in planned} == ROUTE_SET
    plans = _of(planned, "route_plans")
    current = week_start(NOW)
    weeks = {}
    for plan_id, plan in plans.items():
        week = week_start(plan["weekStart"])
        assert week < current and week >= run.settings.first_visit_week
        weeks.setdefault(plan["salesmanUid"], set()).add(week)
        assert plan_id.startswith(f"SIM-{run.settings.batch}-")
    expected = {run.settings.first_visit_week + timedelta(weeks=index) for index in range(run.settings.visit_weeks)}
    assert set(weeks) == set(SALESPEOPLE)
    assert all(found <= expected for found in weeks.values())
    assert reader_problems(planned) == []


def test_every_route_document_carries_the_batch_and_belongs_to_one_plan_group():
    run = simulation(7)
    planned = _planned(run)
    plans = set(_of(planned, "route_plans"))
    for path, data in planned.items():
        assert data["simulationBatchId"] == run.settings.batch, path
        assert data["planId"] in plans, path
        collection, doc_id = path.split("/", 1)
        if collection == "route_plan_publication_keys":
            assert doc_id == f"{data['salesmanUid']}_{week_start(data['weekStart']):%Y%m%d}", path
        else:
            assert doc_id.startswith(f"SIM-{run.settings.batch}-"), path
    outcomes = _of(planned, "conversation_outcomes")
    stops = _of(planned, "route_stop_progress")
    for outcome in outcomes.values():
        assert f"{outcome['planId']}_{outcome['salesmanUid']}_{outcome['stopId']}" in stops


def test_a_wrong_shape_fails_the_reader_check():
    planned = dict(_planned(simulation(7)))
    path = next(path for path in planned if path.startswith("route_stop_progress/"))
    planned[path] = {key: value for key, value in planned[path].items() if key != "arrivedAt"}
    assert reader_problems(planned)
    planned = dict(_planned(simulation(7)))
    path = next(path for path in planned if path.startswith("route_plan_progress/"))
    planned[path] = {**planned[path], "salesmanCode": ""}
    assert reader_problems(planned)


def test_each_simulated_order_of_a_route_week_sits_on_a_completed_stop_of_that_day():
    run = simulation(7)
    planned = _planned(run)
    plans = _of(planned, "route_plans")
    stops = _of(planned, "route_stop_progress")
    weeks = {week_start(plan["weekStart"]) for plan in plans.values()}
    checked = 0
    for order in run.documents["orders"].values():
        day = order["submittedAt"].astimezone(ASIA_KUCHING).date()
        if week_start(day) not in weeks:
            continue
        matches = [
            stop for stop in stops.values()
            if stop["retailerId"] == order["retailerId"] and stop["status"] == "completed"
            and stop["completedAt"].astimezone(ASIA_KUCHING).date() == day
            and stop["salesmanUid"] == order["salesmanUid"]
        ]
        assert len(matches) == 1, order["orderId"]
        checked += 1
    assert checked > 20


def test_no_route_document_names_a_person_who_did_not_do_the_visit():
    run = simulation(7)
    for path, data in _planned(run).items():
        for field in AUTHOR_FIELDS:
            assert field not in data, (path, field)
        assert data.get("salesmanUid") in SALESPEOPLE, path
    assert "system_audit_logs" not in run.documents


def _real_plan(uid, week, status, plan_id="realPlan01"):
    start = datetime(week.year, week.month, week.day, tzinfo=ASIA_KUCHING).astimezone(timezone.utc)
    return plan_id, {"planId": plan_id, "salesmanUid": uid, "salesmanCode": SALESPEOPLE[uid], "branchId": "kuching",
                     "status": status, "weekStart": start, "weekEnd": start + timedelta(days=5), "days": []}


def _sim_plan_for(run, uid, week):
    return next(plan_id for plan_id, plan in run.documents["route_plans"].items()
                if plan["salesmanUid"] == uid and week_start(plan["weekStart"]) == week)


def _apply_with_real_plan(tmp_path, plan_id, plan, *, with_progress=False):
    run = simulation(7)
    seeded = {f"route_plans/{plan_id}": plan}
    if with_progress:
        seeded[f"route_plan_progress/{plan_id}_sp-02"] = {"planId": plan_id, "salesmanUid": "sp-02", "status": "accepted"}
    store = MemoryStore(seeded)
    before = {path: data for path, (data, _) in store.documents.items()}
    manifest = cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=NOW, order_limit=900,
                                  journal=tmp_path / "r.json.journal")
    assert all(store.documents[path][0] == data for path, data in before.items())
    written = {path for path, (data, _) in store.documents.items() if data.get("simulationBatchId")}
    return run, manifest, written


@pytest.mark.parametrize("status, with_progress", [("published", False), ("approved", False), ("draft", True)])
def test_a_real_live_plan_of_a_salesperson_and_week_keeps_that_week_out_whole(tmp_path, status, with_progress):
    week = simulation(7).settings.first_visit_week + timedelta(weeks=2)
    plan_id, plan = _real_plan("sp-02", week, status)
    run, manifest, written = _apply_with_real_plan(tmp_path, plan_id, plan, with_progress=with_progress)
    simulated = _sim_plan_for(run, "sp-02", week)
    group = {path for path, data in _planned(run).items() if data["planId"] == simulated}
    assert len(group) > 2
    assert not group & written
    assert written == set(_planned(run)) - group
    assert manifest["keptRealPlans"] == [{
        "salesmanUid": "sp-02", "weekStart": week.isoformat(), "realPlanId": plan_id,
        "simulatedPlanId": simulated, "why": "kept the real plan",
    }]


def test_a_real_draft_with_no_progress_leaves_the_week_written_and_is_listed(tmp_path):
    week = simulation(7).settings.first_visit_week + timedelta(weeks=2)
    plan_id, plan = _real_plan("sp-02", week, "draft")
    run, manifest, written = _apply_with_real_plan(tmp_path, plan_id, plan)
    assert written == set(_planned(run))
    assert manifest["keptRealPlans"] == []
    assert manifest["realDraftsInSimulatedWeeks"] == [f"real draft in a simulated week: {plan_id}, {week.isoformat()}"]


def test_a_real_archived_plan_with_no_progress_in_a_simulated_week_is_listed(tmp_path):
    week = simulation(7).settings.first_visit_week + timedelta(weeks=2)
    plan_id, plan = _real_plan("sp-02", week, "archived")
    run, manifest, written = _apply_with_real_plan(tmp_path, plan_id, plan)
    assert written == set(_planned(run))
    assert manifest["keptRealPlans"] == []
    assert manifest["realDraftsInSimulatedWeeks"] == [
        f"real archived plan in a simulated week: {plan_id}, {week.isoformat()}"
    ]


def _utc_text_of_kuching_midnight(week):
    return f"{week - timedelta(days=1):%Y-%m-%d}T16:00:00Z"


REAL_PLAN_SHAPES = {
    "no salesmanUid and the code in lower case": lambda plan, week: {
        **{key: value for key, value in plan.items() if key != "salesmanUid"}, "salesmanCode": "s02"},
    "no salesmanUid and the code in lower case with spaces": lambda plan, week: {
        **{key: value for key, value in plan.items() if key != "salesmanUid"}, "salesmanCode": " s02 "},
    "weekStart as an ISO date": lambda plan, week: {**plan, "weekStart": week.isoformat()},
    "weekStart as an ISO date and Kuching time": lambda plan, week: {**plan, "weekStart": f"{week.isoformat()}T00:00:00+08:00"},
    "weekStart as UTC text of Kuching midnight": lambda plan, week: {**plan, "weekStart": _utc_text_of_kuching_midnight(week)},
}


@pytest.mark.parametrize("shape", sorted(REAL_PLAN_SHAPES))
def test_the_clash_read_finds_a_real_plan_stored_in_another_shape(tmp_path, shape):
    week = simulation(7).settings.first_visit_week + timedelta(weeks=1)
    plan_id, plan = _real_plan("sp-02", week, "published")
    run, manifest, written = _apply_with_real_plan(tmp_path, plan_id, REAL_PLAN_SHAPES[shape](plan, week))
    simulated = _sim_plan_for(run, "sp-02", week)
    group = {path for path, data in _planned(run).items() if data["planId"] == simulated}
    assert not group & written
    assert manifest["keptRealPlans"] == [{
        "salesmanUid": "sp-02", "weekStart": week.isoformat(), "realPlanId": plan_id,
        "simulatedPlanId": simulated, "why": "kept the real plan",
    }]


def test_a_real_plan_with_a_week_the_tool_cannot_read_refuses_and_writes_nothing(tmp_path):
    week = simulation(7).settings.first_visit_week + timedelta(weeks=1)
    plan_id, plan = _real_plan("sp-02", week, "published")
    store = MemoryStore({f"route_plans/{plan_id}": {**plan, "weekStart": "next week"}})
    with pytest.raises(SimulationError, match=plan_id):
        cli.apply_manifest(store, simulation(7), "routes", "alljoys-fixture", now=NOW, order_limit=900,
                           journal=tmp_path / "r.json.journal")
    assert set(store.documents) == {f"route_plans/{plan_id}"}
    assert not (tmp_path / "r.json.journal").exists()


@pytest.mark.parametrize("written_week", ["2026-11-16T16:00:00", "2026-11-16T00:00:00", "2026-11-16 16:00"])
def test_a_real_plan_with_a_time_and_no_zone_refuses_and_writes_nothing(tmp_path, written_week):
    week = simulation(7).settings.first_visit_week + timedelta(weeks=1)
    plan_id, plan = _real_plan("sp-02", week, "published")
    store = MemoryStore({f"route_plans/{plan_id}": {**plan, "weekStart": written_week}})
    with pytest.raises(SimulationError, match=plan_id):
        cli.apply_manifest(store, simulation(7), "routes", "alljoys-fixture", now=NOW, order_limit=900,
                           journal=tmp_path / "r.json.journal")
    assert set(store.documents) == {f"route_plans/{plan_id}"}
    assert not (tmp_path / "r.json.journal").exists()


def _old_published_plans(run, uid, count):
    rows = {}
    for index in range(count):
        week = run.settings.first_visit_week - timedelta(weeks=index + 1)
        plan_id, plan = _real_plan(uid, week, "published", plan_id=f"realOld{index:02d}")
        rows[f"route_plans/{plan_id}"] = plan
    return rows


def test_thirty_published_plans_on_one_phone_are_written(tmp_path):
    run = simulation(7)
    own = sum(1 for plan in run.documents["route_plans"].values() if plan["salesmanUid"] == "sp-01")
    assert 0 < own < 30
    store = MemoryStore(_old_published_plans(run, "sp-01", 30 - own))
    manifest = cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=NOW, order_limit=900,
                                  journal=tmp_path / "r.json.journal")
    assert manifest["phone"]["plansPerSalesperson"]["S01"] == {
        "realPublishedPlans": 30 - own, "simulatedPlans": own, "phoneHeadroom": 0, "undoBy": "2026-11-16",
    }
    written = {path for path, (data, _) in store.documents.items() if data.get("simulationBatchId")}
    assert written == set(_planned(run))


def test_the_phone_headroom_and_undo_week_count_real_plans_and_the_simulated_plans_written(tmp_path):
    run = simulation(7)
    kept_week = run.settings.first_visit_week + timedelta(weeks=2)
    kept_id, kept_plan = _real_plan("sp-03", kept_week, "published", plan_id="realKept")
    seeded = {**_old_published_plans(run, "sp-01", 17), f"route_plans/{kept_id}": kept_plan}
    store = MemoryStore(seeded)
    manifest = cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=NOW, order_limit=900,
                                  journal=tmp_path / "r.json.journal")
    phone = manifest["phone"]["plansPerSalesperson"]
    assert (phone["S01"]["phoneHeadroom"], phone["S01"]["undoBy"]) == (5, "2026-12-21")
    assert (phone["S02"]["phoneHeadroom"], phone["S02"]["undoBy"]) == (22, "2027-04-19")
    assert (phone["S03"]["phoneHeadroom"], phone["S03"]["undoBy"]) == (22, "2027-04-19")


def test_two_live_real_plans_in_one_simulated_week_count_as_one_plan_not_written(tmp_path):
    run = simulation(7)
    own = sum(1 for plan in run.documents["route_plans"].values() if plan["salesmanUid"] == "sp-03")
    clash_week = run.settings.first_visit_week + timedelta(weeks=1)
    other_week = run.settings.first_visit_week + timedelta(weeks=2)
    rows = [("realA", clash_week), ("realB", clash_week), ("realC", other_week)]
    seeded = {}
    for plan_id, week in rows:
        _, plan = _real_plan("sp-03", week, "published", plan_id=plan_id)
        seeded[f"route_plans/{plan_id}"] = plan
    manifest = cli.apply_manifest(MemoryStore(seeded), run, "routes", "alljoys-fixture", now=NOW, order_limit=900,
                                  journal=tmp_path / "r.json.journal")
    assert len(manifest["keptRealPlans"]) == 3
    counts = manifest["phone"]["plansPerSalesperson"]["S03"]
    written = own - 2
    assert counts["phoneHeadroom"] == 30 - (3 + written)


def test_the_undo_week_uses_the_kuching_monday_when_utc_is_still_sunday(tmp_path):
    run = simulation(7)
    sunday_utc = datetime(2026, 11, 22, 16, 30, tzinfo=timezone.utc)
    store = MemoryStore(_old_published_plans(run, "sp-01", 17))
    manifest = cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=sunday_utc, order_limit=900,
                                  journal=tmp_path / "r.json.journal")
    counts = manifest["phone"]["plansPerSalesperson"]["S01"]
    assert (counts["phoneHeadroom"], counts["undoBy"]) == (5, "2026-12-28")


def test_thirty_one_published_plans_on_one_phone_refuse_and_write_nothing(tmp_path):
    run = simulation(7)
    own = sum(1 for plan in run.documents["route_plans"].values() if plan["salesmanUid"] == "sp-01")
    seeded = _old_published_plans(run, "sp-01", 31 - own)
    store = MemoryStore(seeded)
    with pytest.raises(SimulationError, match="S01 would hold more than 30 published plans"):
        cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=NOW, order_limit=900,
                           journal=tmp_path / "r.json.journal")
    assert set(store.documents) == set(seeded)
    assert not (tmp_path / "r.json.journal").exists()


def test_the_dry_run_lists_a_kept_real_plan_from_the_export(tmp_path, capsys):
    run = simulation(7)
    week = run.settings.first_visit_week + timedelta(weeks=1)
    data = collections()
    plan_id, plan = _real_plan("sp-03", week, "published")
    data["route_plans"] = {plan_id: plan}
    code = cli.main(["write", "--set", "routes", "--export", str(_export(tmp_path, data, project="alljoys-fixture")),
                     "--roster", str(_roster_file(tmp_path, ROSTER)), "--manifest", str(tmp_path / "plan.json"),
                     "--first-cutoff", FIRST.isoformat()])
    shown = json.loads(capsys.readouterr().out)
    assert code == 0
    assert [row["realPlanId"] for row in shown["keptRealPlans"]] == [plan_id]
    assert shown["keptRealPlans"][0]["why"] == "kept the real plan"


def test_the_dry_run_lists_a_real_draft_in_a_simulated_week_and_still_plans_that_week(tmp_path, capsys):
    run = simulation(7)
    week = run.settings.first_visit_week + timedelta(weeks=1)
    data = collections()
    plan_id, plan = _real_plan("sp-03", week, "draft")
    data["route_plans"] = {plan_id: plan}
    manifest = tmp_path / "plan.json"
    code = cli.main(["write", "--set", "routes", "--export", str(_export(tmp_path, data, project="alljoys-fixture")),
                     "--roster", str(_roster_file(tmp_path, ROSTER)), "--manifest", str(manifest),
                     "--first-cutoff", FIRST.isoformat()])
    shown = json.loads(capsys.readouterr().out)
    assert code == 0
    assert shown["keptRealPlans"] == []
    assert shown["realDraftsInSimulatedWeeks"] == [f"real draft in a simulated week: {plan_id}, {week.isoformat()}"]
    planned = {row["path"] for row in json.loads(manifest.read_text(encoding="utf-8"))["documents"]}
    assert f"route_plans/{_sim_plan_for(run, 'sp-03', week)}" in planned


def _with_shops_of_a_salesperson_who_has_no_user_record():
    data = collections()
    for index in range(1, 4):
        data["retailers"][f"M{index:03d}"] = {
            "retailerId": f"M{index:03d}", "retailerName": f"Other branch shop {index}", "branchId": "miri",
            "latitude": 4.4 + index / 100, "longitude": 114.0, "assignedSalesmanId": "S77",
            "assignedSalesmanCodes": ["S77"], "address": "Miri",
        }
    return data


def test_a_ranking_of_a_salesperson_outside_the_roster_is_skipped_and_listed_in_the_dry_run(tmp_path, capsys):
    data = _with_shops_of_a_salesperson_who_has_no_user_record()
    code = cli.main(["write", "--set", "routes", "--export", str(_export(tmp_path, data, project="alljoys-fixture")),
                     "--roster", str(_roster_file(tmp_path, ROSTER)), "--manifest", str(tmp_path / "plan.json"),
                     "--first-cutoff", FIRST.isoformat()])
    shown = capsys.readouterr()
    assert code == 0, shown.err
    checks = json.loads(shown.out)["checks"]
    assert len(checks) == 3
    for check in checks:
        assert check["rankings"] == 4
        assert check["rankingsPerSalesperson"] == {"S01": 1, "S02": 1, "S03": 1, "S04": 1}
        assert check["skippedRankings"] == {"why": "skipped: not a roster salesperson", "count": 1}


def test_a_roster_salesperson_with_no_ranking_still_refuses_when_another_salesperson_has_one(monkeypatch):
    company_ = company_from_collections("alljoys-fixture", _with_shops_of_a_salesperson_who_has_no_user_record())
    team_ = resolve_team(company_, ROSTER)
    settings = Settings(first_cutoff=FIRST, cutoff=FIRST, seed=7)
    plain = simulate(company_, team_, settings, now=NOW)
    first_planted_owner = plain.shops[plain.story.stops[0][0]].person.code
    dropped = next(code for code in sorted(SALESPEOPLE.values()) if code != first_planted_owner)
    real = simulate_module.run_pipeline
    seen = []

    def without_one_roster_ranking_at_the_first_cutoff(company, shops, documents, as_of, *args, **kwargs):
        result = real(company, shops, documents, as_of, *args, **kwargs)
        if as_of != FIRST:
            return result
        kept = tuple(row for row in result.priority_rankings if row["salesmanCode"] != dropped)
        seen.append(len(result.priority_rankings) - len(kept))
        return dataclasses.replace(result, priority_rankings=kept)

    monkeypatch.setattr(simulate_module, "run_pipeline", without_one_roster_ranking_at_the_first_cutoff)
    with pytest.raises(SimulationError, match=f"{FIRST}: 3 rankings of roster salespeople, not one for each salesperson \\({dropped}\\)"):
        simulate(company_, team_, settings, now=NOW)
    assert seen and set(seen) == {1}


def test_an_existing_publication_key_keeps_the_whole_group_out(tmp_path):
    run = simulation(7)
    plan = run.documents["route_plans"][_sim_plan_for(run, "sp-01", run.settings.first_visit_week)]
    key_id = f"sp-01_{run.settings.first_visit_week:%Y%m%d}"
    store = MemoryStore({f"route_plan_publication_keys/{key_id}": {"keyId": key_id, "planId": "realPlan9", "active": True}})
    manifest = cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=NOW, order_limit=900,
                                  journal=tmp_path / "r.json.journal")
    assert not any(data.get("planId") == plan["planId"] for data, _ in store.documents.values())
    assert manifest["keptRealPlans"][0]["realKeyId"] == key_id


def test_undo_takes_back_whole_groups_and_keeps_a_changed_group_whole(tmp_path):
    run = simulation(7)
    store = MemoryStore()
    journal = tmp_path / "r.json.journal"
    manifest = cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=NOW, order_limit=900, journal=journal)
    changed_plan = _sim_plan_for(run, "sp-04", run.settings.first_visit_week + timedelta(weeks=3))
    stop_path = next(path for path in store.documents
                     if path.startswith("route_stop_progress/") and store.documents[path][0]["planId"] == changed_plan)
    store.change(stop_path, status="skipped")
    report = cli.undo_manifest(store, manifest)
    left = set(store.documents)
    group = {path for path, data in _planned(run).items() if data["planId"] == changed_plan}
    assert left == group
    assert stop_path in report["skippedChanged"]
    assert sorted(report["keptWithChangedPartner"]) == sorted(group - {stop_path})
    again = cli.undo_manifest(store, cli.manifest_from_journal(journal))
    assert set(store.documents) == group and not again["deleted"]


def test_write_then_undo_leaves_the_store_byte_equal(tmp_path):
    run = simulation(7)
    week = run.settings.first_visit_week
    plan_id, plan = _real_plan("sp-01", week, "published")
    store = MemoryStore({f"route_plans/{plan_id}": plan})
    before = json.dumps({path: cli._encode(data) for path, (data, _) in store.documents.items()}, sort_keys=True)
    manifest = cli.apply_manifest(store, run, "routes", "alljoys-fixture", now=NOW, order_limit=900,
                                  journal=tmp_path / "r.json.journal")
    assert manifest["counts"]["written"] > 100
    report = cli.undo_manifest(store, manifest)
    assert not any(report.get(key) for key in cli.UNDO_KEPT_BACK)
    after = json.dumps({path: cli._encode(data) for path, (data, _) in store.documents.items()}, sort_keys=True)
    assert after == before


def _main_routes(monkeypatch, tmp_path, capsys, project, *extra):
    store = MemoryStore()
    opened = []
    monkeypatch.setattr(cli, "_client", lambda name: opened.append(name) or Opened(name))
    monkeypatch.setattr(cli, "FirestoreStore", lambda db: store)
    monkeypatch.setattr(cli, "datetime", _FixedNow)
    manifest = tmp_path / "routes.json"
    code = cli.main(["write", "--set", "routes", "--export", str(_export(tmp_path, collections(), project=project)),
                     "--roster", str(_roster_file(tmp_path, ROSTER)), "--manifest", str(manifest),
                     "--first-cutoff", FIRST.isoformat(), *extra])
    return code, capsys.readouterr(), opened, store, manifest


class _FixedNow(datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW


def test_the_routes_set_applies_on_a_company_project_with_the_confirmation(monkeypatch, tmp_path, capsys):
    code, shown, opened, store, manifest = _main_routes(
        monkeypatch, tmp_path, capsys, "cos40005", "--apply", "--confirm-project", "cos40005")
    assert code == 0, shown.err
    assert opened == ["cos40005"]
    assert {path.split("/", 1)[0] for path in store.documents} == ROUTE_SET
    assert "visits" not in cli.WRITE_SETS


def test_the_routes_set_is_refused_above_max_writes_and_writes_nothing(monkeypatch, tmp_path, capsys):
    code, shown, opened, store, manifest = _main_routes(
        monkeypatch, tmp_path, capsys, "cos40005", "--max-writes", "50", "--apply", "--confirm-project", "cos40005")
    assert code == 1 and store.documents == {} and not cli.journal_path(manifest).exists()
    assert "--max-writes 50" in shown.err
    code, shown, *_ = _main_routes(monkeypatch, tmp_path, capsys, "cos40005", "--max-writes", "50")
    assert code == 1 and "--max-writes 50" in shown.err


def test_the_default_max_writes_is_3000_and_the_dry_run_prints_the_cost(monkeypatch, tmp_path, capsys):
    code, shown, opened, store, manifest = _main_routes(monkeypatch, tmp_path, capsys, "cos40005")
    body = json.loads(shown.out)
    planned = len(_planned(simulation(7)))
    assert code == 0 and opened == []
    assert body["cost"]["writes"] == planned
    assert body["cost"]["maxWrites"] == 3000
    assert body["cost"]["readsAtApply"] >= planned
    assert body["cost"]["freeDailyQuota"] == {"reads": 50000, "writes": 20000}
    assert "phone" in body and "past weeks" in body["phone"]["note"]


def test_the_dry_run_scorecard_preview_matches_an_independent_count_of_the_written_documents(monkeypatch, tmp_path, capsys):
    code, shown, opened, store, manifest = _main_routes(
        monkeypatch, tmp_path, capsys, "cos40005", "--apply", "--confirm-project", "cos40005")
    assert code == 0, shown.err
    preview = {row["salesmanCode"]: row for row in json.loads(shown.out)["scorecardPreview"]}
    rows = {path: data for path, (data, _) in store.documents.items()}
    assert set(preview) == set(SALESPEOPLE.values())
    for uid, code_ in SALESPEOPLE.items():
        expected = scorecard_numbers(rows, uid, code_, NOW)
        assert {key: preview[code_][key] for key in expected} == expected
        assert expected["decidedVisits"] > 0


def test_the_story_still_holds_with_routes_built():
    run = simulate(company_from_collections("alljoys-fixture", collections()), team(),
                   Settings(first_cutoff=FIRST, cutoff=FIRST, seed=7), now=NOW)
    assert all(check["flagged"] and check["rank"] == 1 for check in run.checks)

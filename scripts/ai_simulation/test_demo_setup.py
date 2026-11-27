from __future__ import annotations

import copy
import itertools
import json
import random
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.ai_simulation import demo_setup
from scripts.ai_simulation.inputs import (
    SimulationError,
    assign_areas,
    company_from_collections,
    load_roster,
    resolve_team,
    simulated_shops,
)
from scripts.ai_simulation.simulate import Settings, simulate
from scripts.ai_simulation.staff_plan import LEGACY_ASSIGNMENT_FIELDS, SUPERVISOR_CAP, replay_move, staff_move_plan
from scripts.ai_simulation.test_ai_simulation import FIRST, NOW, ROSTER, SEEDS, collections

DART = (ROOT / "admin_dashboard" / "lib" / "utils" / "retailer_bulk_assign.dart").read_text(encoding="utf-8")
OWNERS = {f"R{index:03d}": ("S01", "S02", "S03", "S04")[(index - 1) // 5 if index <= 20 else 1] for index in range(1, 22)}


def collections_21() -> dict:
    data = collections()
    data["retailers"]["R021"] = {**data["retailers"]["R020"], "retailerId": "R021", "retailerName": "Shop 021"}
    return data


def roster_21(owners=None) -> dict:
    return {**ROSTER, "shopOwners": dict(OWNERS if owners is None else owners)}


def company_21():
    return company_from_collections("alljoys-fixture", collections_21())


@pytest.mark.parametrize("seed", SEEDS)
def test_a_shop_owner_map_of_21_shops_gives_every_shop_orders_and_visits(seed):
    data = company_21()
    team = resolve_team(data, roster_21())
    run = simulate(data, team, Settings(first_cutoff=FIRST, cutoff=FIRST, seed=seed), now=NOW)
    assert {key: plan.person.code for key, plan in run.shops.items()} == OWNERS
    assert {order["retailerId"] for order in run.documents["orders"].values()} == set(OWNERS)
    assert {row["retailerId"] for row in run.documents["conversation_outcomes"].values()} <= set(OWNERS)
    for order in run.documents["orders"].values():
        assert order["salesmanCode"] == OWNERS[order["retailerId"]]
    assert all(check["rankings"] == 4 and check["rank"] == 1 and check["flagged"] for check in run.checks)


def test_without_a_shop_owner_map_21_shops_are_refused_as_before():
    data = company_21()
    with pytest.raises(SimulationError, match="21 active shops. The roster needs 20"):
        simulated_shops(data, resolve_team(data, ROSTER), 5)


@pytest.mark.parametrize("change, message", [
    (lambda owners: {**owners, "R021": "S99"}, "not a salesperson of the roster"),
    (lambda owners: {key: ("S01" if code == "S04" else code) for key, code in owners.items()}, "gives no shop to S04"),
    (lambda owners: {key: code for key, code in owners.items() if key != "R021"}, r"Not mapped: \['R021'\]"),
    (lambda owners: {**owners, "R099": "S01"}, r"not an active shop of the branch: \['R099'\]"),
    (lambda owners: {**owners, "r021": "S01"}, "maps the shop r021 twice"),
])
def test_a_wrong_shop_owner_map_is_refused(change, message):
    data = company_21()
    with pytest.raises(SimulationError, match=message):
        team = resolve_team(data, roster_21(change(OWNERS)))
        simulated_shops(data, team, 5)


def test_a_shop_named_twice_in_the_roster_file_is_refused(tmp_path):
    body = json.dumps(roster_21())
    path = tmp_path / "roster.json"
    path.write_text(body[:-2] + ', "R001": "S02"}}', encoding="utf-8")
    with pytest.raises(SimulationError, match="names R001 twice"):
        load_roster(path)


def test_the_assignment_payload_is_the_dashboard_payload():
    listed = re.search(r"kLegacyRetailerAssignmentFields = <String>\[(.*?)\];", DART, re.S).group(1)
    assert tuple(re.findall(r"'([^']+)'", listed)) == LEGACY_ASSIGNMENT_FIELDS
    payload = re.search(r"retailerAssignmentPayload\(String salesmanId\) =>(.*?)};", DART, re.S).group(1)
    assert re.findall(r"'([^']+)'", payload) == ["assignedSalesmanId"] and "salesmanId.trim()" in payload
    assert "'updatedAt': FieldValue.serverTimestamp()" in DART
    values, removed = demo_setup.assignment_payload(" S01 ")
    assert values == {"assignedSalesmanId": "S01", "updatedAt": demo_setup.SERVER_TIME}
    assert removed == list(LEGACY_ASSIGNMENT_FIELDS)
    data = company_21()
    team = resolve_team(data, roster_21())
    owners = assign_areas(simulated_shops(data, team, 5), team)
    assert {key: person.code for key, person in owners.items()} == OWNERS


class PatchMemory:
    def __init__(self, documents, fail_after=None):
        self.documents = {path: (copy.deepcopy(data), 1) for path, data in documents.items()}
        self.ticks = itertools.count(2)
        self.fail_after = fail_after
        self.writes = 0

    @staticmethod
    def _time(tick):
        return datetime(2026, 11, 18, tzinfo=timezone.utc) + timedelta(seconds=tick)

    def read(self, path):
        found = self.documents.get(path)
        return (copy.deepcopy(found[0]), self._time(found[1])) if found else None

    def update_unit(self, changes):
        for path, (expected, _, _) in changes.items():
            if path not in self.documents or self._time(self.documents[path][1]) != expected:
                return None
        if self.fail_after is not None and self.writes >= self.fail_after:
            raise ConnectionError("the network dropped")
        self.writes += 1
        tick = next(self.ticks)
        for path, (_, values, removed) in changes.items():
            data = dict(self.documents[path][0])
            for name in removed:
                data.pop(name, None)
            data.update({name: self._time(tick) if value == demo_setup.SERVER_TIME else copy.deepcopy(value)
                         for name, value in values.items()})
            self.documents[path] = (data, tick)
        return {path: self._time(tick) for path in changes}

    def person_edit(self, path, **fields):
        self.documents[path] = ({**self.documents[path][0], **fields}, next(self.ticks))

    def contents(self):
        return {path: data for path, (data, _) in self.documents.items()}


def _shop_units():
    units = []
    for key, code in sorted(OWNERS.items()):
        values, removed = demo_setup.assignment_payload(code)
        units.append({"unit": f"retailers/{key}", "changes": [{"path": f"retailers/{key}", "set": values, "delete": removed}]})
    return units


def _shop_store(**kwargs):
    return PatchMemory({f"retailers/{key}": row for key, row in collections_21()["retailers"].items()}, **kwargs)


def test_shop_assignments_apply_once_and_undo_restores_every_before_value(tmp_path):
    store = _shop_store()
    seeded = store.contents()
    journal = tmp_path / "shops.json.journal"
    manifest = demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    assert manifest["counts"] == {"written": 21}
    for key, code in OWNERS.items():
        row = store.contents()[f"retailers/{key}"]
        assert row["assignedSalesmanId"] == code and "assignedSalesmanCodes" not in row and "updatedAt" in row
    again = demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    assert again["counts"] == {"written": 21} and store.writes == 21
    report = demo_setup.undo_patch(store, manifest)
    assert len(report["restored"]) == 21 and store.contents() == seeded
    second = demo_setup.undo_patch(store, manifest)
    assert second["restored"] == [] and len(second["alreadyRestored"]) == 21 and store.contents() == seeded


def test_undo_skips_a_shop_that_a_person_changed_again(tmp_path):
    store = _shop_store()
    manifest = demo_setup.apply_patch(store, "shops", "p", _shop_units(), tmp_path / "a.journal")
    store.person_edit("retailers/R005", assignedSalesmanId="S03")
    report = demo_setup.undo_patch(store, manifest)
    assert report["skipped"] == [{"unit": "retailers/R005", "why": "changed since this write"}]
    assert store.contents()["retailers/R005"]["assignedSalesmanId"] == "S03"
    assert store.contents()["retailers/R006"]["assignedSalesmanCodes"] == ["S09"]


@pytest.mark.parametrize("fail_after", range(0, 21, 4))
def test_a_crash_part_way_through_apply_resumes_to_the_same_end_state(tmp_path, fail_after):
    clean = _shop_store()
    demo_setup.apply_patch(clean, "shops", "p", _shop_units(), tmp_path / "clean.journal")
    store = _shop_store(fail_after=fail_after)
    journal = tmp_path / "crash.journal"
    with pytest.raises(ConnectionError):
        demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    store.fail_after = None
    manifest = demo_setup.apply_patch(store, "shops", "p", _shop_units(), journal)
    unproven = f"retailers/{sorted(OWNERS)[fail_after]}"
    assert manifest["counts"] == {"written": 20, "check_by_hand": 1}
    assert [row["unit"] for row in manifest["units"] if row["status"] == "check_by_hand"] == [unproven]
    strip = lambda contents: {path: {k: v for k, v in row.items() if k != "updatedAt"} for path, row in contents.items()}
    seeded = _shop_store().contents()
    assert strip(store.contents()) == strip({**clean.contents(), unproven: seeded[unproven]})
    report = demo_setup.undo_patch(store, manifest)
    assert report["checkByHand"] == [unproven] and store.contents() == seeded


def test_the_start_point_is_merged_and_undo_removes_fields_that_were_absent(tmp_path):
    store = PatchMemory({"branches/kuching": {"branchId": "kuching", "branchName": "Kuching"}})
    units = demo_setup.start_point_changes("kuching", "Campus", 1.53, 110.36)
    manifest = demo_setup.apply_patch(store, "start-point", "p", units, tmp_path / "s.journal")
    assert store.contents()["branches/kuching"] == {"branchId": "kuching", "branchName": "Kuching",
                                                     "routeStartName": "Campus", "routeStartLat": 1.53, "routeStartLng": 110.36}
    demo_setup.undo_patch(store, manifest)
    assert store.contents()["branches/kuching"] == {"branchId": "kuching", "branchName": "Kuching"}
    with pytest.raises(SimulationError):
        demo_setup.start_point_changes("kuching", "Campus", 91, 110.36)


def test_roster_clear_removes_every_spelling_from_both_records_together_and_undo_restores_both(tmp_path):
    roster = ["S01", "syn001", "SYN002", "Syn003", "S02"]
    store = PatchMemory({"users/doc-a": {"role": "supervisor", "assignedSalesmanCodes": list(roster)},
                         "user_access/uid-a": {"role": "supervisor", "assignedSalesmanCodes": list(roster)}})
    seeded = store.contents()
    units = demo_setup.roster_clear_changes(store, "doc-a", "uid-a", ["SYN001", "SYN002", "SYN003"], user_codes={"S01", "S02"})
    manifest = demo_setup.apply_patch(store, "roster-clear", "p", units, tmp_path / "r.journal")
    assert store.writes == 1
    assert {path: row["assignedSalesmanCodes"] for path, row in store.contents().items()} == {
        "users/doc-a": ["S01", "S02"], "user_access/uid-a": ["S01", "S02"]}
    store.person_edit("user_access/uid-a", note="x")
    assert demo_setup.undo_patch(store, manifest)["skipped"] and store.contents()["users/doc-a"]["assignedSalesmanCodes"] == ["S01", "S02"]
    store.documents["user_access/uid-a"] = ({k: v for k, v in store.contents()["user_access/uid-a"].items() if k != "note"}, 1)
    fresh = demo_setup.apply_patch(store, "roster-clear", "p", units, tmp_path / "r2.journal")
    assert fresh["counts"] == {"unchanged": 1}
    store2 = PatchMemory(seeded)
    manifest2 = demo_setup.apply_patch(store2, "roster-clear", "p", units, tmp_path / "r3.journal")
    assert demo_setup.undo_patch(store2, manifest2)["restored"] == ["roster-clear/uid-a"] and store2.contents() == seeded


def _team_state(picker):
    users, access = {}, {}

    def person(uid, role, code, **extra):
        users[uid] = {"uid": uid, "name": uid, "role": role, "branchId": "k", "employeeCode": code, "status": "active", **extra}
        access[uid] = {"role": role, "branchId": "k", "employeeCode": code, "status": "active"}

    person("adm", "admin", "ADM")
    sups = [f"sup{index}" for index in range(picker.randint(3, 5))]
    people = [f"S{index:02d}" for index in range(picker.randint(6, 14))]
    orphans = [f"SYN{index}" for index in range(picker.randint(0, 3))]
    rosters = {uid: [] for uid in sups}
    for code in [*people, *orphans]:
        choices = [uid for uid in sups if len(rosters[uid]) < SUPERVISOR_CAP]
        if choices and picker.random() < 0.8:
            rosters[picker.choice(choices)].append(code if picker.random() < 0.7 else code.lower())
    for uid in sups:
        person(uid, "supervisor", uid.upper(), assignedSalesmanCodes=list(rosters[uid]))
        access[uid]["assignedSalesmanCodes"] = list(rosters[uid])
    for code in people:
        holder = next((uid for uid, roster in rosters.items() if code.casefold() in {c.casefold() for c in roster}), None)
        linked = holder if holder and picker.random() < 0.7 else ""
        person(f"u{code}", "salesman", code, supervisorId=linked.upper() if linked else "")
        access[f"u{code}"]["supervisorUid"] = linked
    chosen = picker.sample(people, 4)
    roster = {"branchId": "k", "routeAuthor": "adm",
              "teams": [{"supervisor": sups[0], "salespeople": chosen[:2]}, {"supervisor": sups[1], "salespeople": chosen[2:]}],
              "leaverSupervisors": sups[2:]}
    return company_from_collections("p", {"users": users, "user_access": access}), roster, rosters


def test_every_step_of_the_staff_plan_and_of_its_undo_keeps_each_roster_at_five_or_fewer():
    checked = blocked = 0
    for case in range(400):
        picker = random.Random(case)
        company, roster, start = _team_state(picker)
        team = resolve_team(company, roster)
        plan = staff_move_plan(company, team)
        if plan["blocked"]:
            blocked += 1
            assert all(row["problem"] and (row.get("salespersonUid") or row.get("salespersonCode")) for row in plan["blocked"]), case
            assert all(len(state) <= SUPERVISOR_CAP for state in plan["rostersAfter"].values()), case
            continue
        state = {uid: {code.casefold(): code for code in codes} for uid, codes in start.items()}
        for step in plan["steps"]:
            replay_move(state, step["salespersonCode"].casefold(), step["salespersonCode"], step["toSupervisorUid"])
            assert all(len(roster) <= SUPERVISOR_CAP for roster in state.values()), case
        for supervisor, members in team.groups:
            assert {member.code.casefold() for member in members} <= set(state[supervisor.uid]), case
        assert {uid: sorted(roster.values()) for uid, roster in state.items()} == plan["rostersAfter"], case
        for step in plan["undoSteps"]:
            replay_move(state, step["salespersonCode"].casefold(), step["salespersonCode"], step["toSupervisorUid"])
            assert all(len(roster) <= SUPERVISOR_CAP for roster in state.values()), case
        parked = {company_code(company, uid) for uid in plan["undoCannotRestore"]["parkedWithLeaverSupervisor"]}
        expected = {uid: {code.casefold() for code in codes if code.casefold() not in parked} for uid, codes in start.items()}
        ended = {uid: {code for code in roster if code not in parked} for uid, roster in state.items()}
        assert ended == expected, case
        home = team.leaver_supervisors[0].uid if team.leaver_supervisors else None
        assert all(code in state[home] for code in parked), case
        checked += 1
    assert (checked, blocked) == (296, 104)


def company_code(company, uid):
    return next(row["employeeCode"] for row in company.users if row["uid"] == uid).casefold()


def test_a_salesperson_on_the_roster_with_an_empty_own_link_gets_a_move_step():
    data = collections()
    data["users"]["sp-04"]["supervisorId"] = ""
    data["user_access"]["sp-04"]["supervisorUid"] = ""
    company = company_from_collections("p", data)
    plan = staff_move_plan(company, resolve_team(company, ROSTER))
    steps = [step for step in plan["steps"] if step["salespersonCode"] == "S04"]
    assert steps and steps[0]["toSupervisorUid"] == "sup-b" and steps[0]["fixesOwnLinkOnly"]
    assert "sp-04" not in plan["undoCannotRestore"]["parkedWithLeaverSupervisor"]
    assert plan["undoCannotRestore"]["linkFieldsWrittenByTheMove"] == ["sp-04"]
    assert not any(step["salespersonCode"] == "S04" for step in plan["undoSteps"])

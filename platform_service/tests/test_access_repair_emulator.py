from __future__ import annotations

import json
import os
import threading
import time
import uuid

import pytest
from google.api_core.exceptions import Aborted
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import access_migration, access_repair, lifecycle, prepare_data, tenant_readiness, tenant_snapshot
from platform_service.access_migration import plan_access_migration
from platform_service.company_access import project_auth
from platform_service.plans import load_catalogue

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

BRANCH = "HW1"
PASSWORD = "Passw0rd!2026"
ADMIN = {"uid": "uid-adm-5uzs", "profile": "ADM001", "email": "kitchen.admin@example.test", "role": "admin"}
SALES = {"uid": "uid-sm-5qo6", "profile": "SM001", "email": "kitchen.sales@example.test", "role": "salesman"}
THIRD = {"uid": "uid-third-9x", "email": "kitchen.third@example.test"}
CODE = "ADM002"


@pytest.fixture
def project():
    return f"demo-repair-{uuid.uuid4().hex[:10]}"


@pytest.fixture
def db(project):
    return firestore.Client(project=project, credentials=AnonymousCredentials())


@pytest.fixture
def auth(project):
    return project_auth(project)


def identity(person):
    salesman = person["role"] == "salesman"
    return {
        "userId": person["profile"], "employeeCode": person["profile"], "email": person["email"],
        "role": person["role"], "user_group": person["role"], "status": "active", "isActive": True,
        "branchId": BRANCH, "branch_id": BRANCH,
        "supervisorId": "SV0001" if salesman else "", "supervisor_id": "SV0001" if salesman else "",
    }


def seed(db, auth):
    for person in (ADMIN, SALES, THIRD):
        auth.create_user(uid=person["uid"], email=person["email"], password=PASSWORD)
    for person in (ADMIN, SALES):
        db.collection("users").document(person["profile"]).set(
            {"uid": person["uid"], "name": person["profile"], **identity(person)})
        db.collection("user_access").document(person["profile"]).set(
            {"uid": person["uid"], "userDocId": person["uid"], **identity(person)})


def fingerprint(db):
    result = {}
    for collection in db.collections():
        for snapshot in collection.stream():
            result[f"{collection.id}/{snapshot.id}"] = (snapshot.update_time, snapshot.to_dict())
    return result


def plan_of(db, auth, **grant):
    wanted = access_repair.Grant(**grant) if grant else None
    return access_repair.plan_repair(db, auth, wanted)


GRANT = {"email": THIRD["email"], "code": CODE, "name": "Third Admin", "branch": None}


def test_dry_run_writes_nothing_and_plans_three_people(db, auth, capsys, project):
    seed(db, auth)
    before = fingerprint(db)
    plan = plan_of(db, auth, **GRANT)
    assert fingerprint(db) == before
    assert sorted(item.uid for item in plan.writes) == sorted([ADMIN["uid"], SALES["uid"], THIRD["uid"]])
    assert plan.skipped == []
    assert access_repair.main(["--project", project, "--grant-admin", THIRD["email"], "--code", CODE]) == 0
    printed = capsys.readouterr().out
    assert THIRD["email"] not in printed and ADMIN["email"] not in printed
    assert "ki***@example.test" in printed
    assert fingerprint(db) == before


def test_apply_writes_three_rows_keeps_old_rows_and_uids(db, auth, project):
    seed(db, auth)
    old = {name: db.collection("user_access").document(name).get() for name in ("ADM001", "SM001")}
    accounts = {user.uid: user.email for user in auth.list_users().iterate_all()}
    result = access_repair.apply_repair(db, auth, plan_of(db, auth, **GRANT))
    assert sorted(result["written"]) == sorted([f"user_access/{ADMIN['uid']}", f"user_access/{SALES['uid']}",
                                                f"user_access/{THIRD['uid']}", f"users/{THIRD['uid']}"])
    assert result["changedDuringApply"] == []
    for name, before in old.items():
        now = db.collection("user_access").document(name).get()
        assert now.to_dict() == before.to_dict() and now.update_time == before.update_time
    assert {user.uid: user.email for user in auth.list_users().iterate_all()} == accounts
    admin_row = db.collection("user_access").document(ADMIN["uid"]).get().to_dict()
    assert admin_row["uid"] == ADMIN["uid"] and admin_row["userDocId"] == "ADM001" and admin_row["role"] == "admin"
    assert admin_row["email"] == ADMIN["email"] and admin_row["branchId"] == BRANCH
    third_row = db.collection("user_access").document(THIRD["uid"]).get().to_dict()
    third_profile = db.collection("users").document(THIRD["uid"]).get().to_dict()
    assert third_row["userDocId"] == THIRD["uid"] and third_row["employeeCode"] == CODE
    assert third_row["role"] == "admin" and third_row["status"] == "active" and third_row["branchId"] == BRANCH
    assert third_profile["uid"] == THIRD["uid"] and third_profile["name"] == "Third Admin"
    assert third_profile["email"] == THIRD["email"] and third_profile["employeeCode"] == CODE

    def run_readiness():
        return tenant_readiness.readiness(db, auth_client=auth, packages=load_catalogue(),
                                          budget=tenant_readiness.DEFAULT_MAX_READS, project=project).report

    assert len(plan_access_migration(db)["convertible"]) == 3
    stale = run_readiness()
    assert stale["verdict"] == "blocked"
    assert sorted(blocker.split(" ")[0] for blocker in stale["auth"]["blockers"]) == ["ADM001", "SM001"]
    for name in ("ADM001", "SM001"):
        db.collection("user_access").document(name).delete()
    clean = run_readiness()
    assert clean["auth"]["blockers"] == [] and clean["auth"]["missing"] == 0
    assert clean["people"]["blockers"] == [] and clean["verdict"] == "ready"
    assert len(plan_access_migration(db)["convertible"]) == 3

    again = plan_of(db, auth, **GRANT)
    assert again.writes == []
    assert access_repair.main(["--project", project, "--grant-admin", THIRD["email"], "--code", CODE,
                               "--apply", "--confirm-project", project]) == 3


def test_a_changed_precondition_between_plan_and_apply_is_skipped(db, auth):
    seed(db, auth)
    plan = plan_of(db, auth, **GRANT)
    db.collection("users").document("SM001").update({"name": "changed after the plan"})
    db.collection("user_access").document(THIRD["uid"]).set({"uid": THIRD["uid"]})
    result = access_repair.apply_repair(db, auth, plan)
    assert result["written"] == [f"user_access/{ADMIN['uid']}"]
    assert sorted(result["changedDuringApply"]) == sorted([SALES["uid"], THIRD["uid"]])
    assert not db.collection("user_access").document(SALES["uid"]).get().exists
    assert db.collection("user_access").document(THIRD["uid"]).get().to_dict() == {"uid": THIRD["uid"]}
    assert not db.collection("users").document(THIRD["uid"]).get().exists


def test_an_account_removed_between_plan_and_apply_is_skipped(db, auth):
    seed(db, auth)
    plan = plan_of(db, auth, **GRANT)
    auth.delete_user(SALES["uid"])
    auth.update_user(THIRD["uid"], disabled=True)
    result = access_repair.apply_repair(db, auth, plan)
    assert result["written"] == [f"user_access/{ADMIN['uid']}"]
    assert sorted(result["changedDuringApply"]) == sorted([SALES["uid"], THIRD["uid"]])


def test_other_shapes_are_listed_and_not_written(db, auth):
    seed(db, auth)
    auth.delete_user(SALES["uid"])
    db.collection("users").document("ADM001").update({"uid": "someone-else"})
    db.collection("user_access").document("NOPROFILE").set({"uid": "uid-np", "userDocId": "uid-np", "role": "salesman"})
    auth.create_user(uid="uid-np", email="np@example.test", password=PASSWORD)
    db.collection("user_access").document("uid-fine").set({"uid": "uid-fine", "userDocId": "FINE", "role": "salesman"})
    plan = plan_of(db, auth)
    assert plan.writes == []
    reasons = {item["row"]: item["reason"] for item in plan.skipped}
    assert sorted(reasons) == ["ADM001", "NOPROFILE", "SM001"]
    assert "profile" in reasons["ADM001"] and "profile" in reasons["NOPROFILE"] and "account" in reasons["SM001"]
    before = fingerprint(db)
    assert access_repair.apply_repair(db, auth, plan) == {"written": [], "changedDuringApply": []}
    assert fingerprint(db) == before


def test_a_new_row_that_exists_already_is_not_overwritten(db, auth):
    seed(db, auth)
    db.collection("user_access").document(ADMIN["uid"]).set({"uid": ADMIN["uid"], "note": "keep"})
    plan = plan_of(db, auth)
    assert [item.uid for item in plan.writes] == [SALES["uid"]]
    assert [item["row"] for item in plan.skipped] == ["ADM001"]


@pytest.mark.parametrize("case", ["no-account", "disabled", "row-exists", "profile-exists", "code-used-row",
                                  "code-used-profile", "code-is-doc-id", "no-branch"])
def test_the_grant_is_refused(db, auth, case):
    seed(db, auth)
    grant = dict(GRANT)
    if case == "no-account":
        grant["email"] = "nobody@example.test"
    elif case == "disabled":
        auth.update_user(THIRD["uid"], disabled=True)
    elif case == "row-exists":
        db.collection("user_access").document(THIRD["uid"]).set({"uid": THIRD["uid"], "userDocId": "X1"})
    elif case == "profile-exists":
        db.collection("users").document(THIRD["uid"]).set({"uid": THIRD["uid"]})
    elif case == "code-used-row":
        db.collection("user_access").document("other-uid").set({"employeeCode": CODE, "userDocId": "O1"})
    elif case == "code-used-profile":
        db.collection("users").document("O2").set({"userId": CODE})
    elif case == "code-is-doc-id":
        db.collection("users").document(CODE).set({"name": "someone"})
    elif case == "no-branch":
        for name in ("ADM001", "SM001"):
            db.collection("user_access").document(name).update({"branchId": "", "branch_id": ""})
    before = fingerprint(db)
    with pytest.raises(access_repair.RepairRefused):
        plan_of(db, auth, **grant)
    assert fingerprint(db) == before


def test_the_branch_option_replaces_the_default(db, auth):
    seed(db, auth)
    plan = plan_of(db, auth, **{**GRANT, "branch": "HW9"})
    access_repair.apply_repair(db, auth, plan)
    assert db.collection("user_access").document(THIRD["uid"]).get().to_dict()["branchId"] == "HW9"


def test_cli_refuses_a_wrong_confirmation_and_a_refused_grant(db, auth, project, capsys):
    seed(db, auth)
    before = fingerprint(db)
    assert access_repair.main(["--project", project, "--apply", "--confirm-project", "other"]) == 2
    assert access_repair.main(["--project", project, "--apply"]) == 2
    assert access_repair.main(["--project", project, "--grant-admin", "nobody@example.test", "--code", CODE,
                               "--apply", "--confirm-project", project]) == 2
    assert access_repair.main(["--project", project, "--grant-admin", THIRD["email"]]) == 2
    assert fingerprint(db) == before
    capsys.readouterr()
    assert access_repair.main(["--project", project, "--apply", "--confirm-project", project]) == 0
    printed = json.loads(capsys.readouterr().out)
    assert printed["mode"] == "apply" and len(printed["applied"]["written"]) == 2


from .test_tenant_readiness_emulator import add_swapped_row, access_legacy, fork_profile, make_account, put, seed_world

PEOPLE_BAD = {
    "unknown_role": {"uid": "pp-role", "email": "pp.role@example.test", "code": "S0021", "role": "forklift"},
    "profile_missing": {"uid": "pp-prof", "email": "pp.prof@example.test", "code": "S0022", "role": "salesman"},
    "no_account": {"uid": "pp-noacc", "email": "pp.noacc@example.test", "code": "S0023", "role": "salesman"},
    "two_rows": {"uid": "zz-dup", "email": "pp.dup@example.test", "code": "S0001", "role": "salesman"},
}


def seed_people(db, auth):
    seed_world(db, auth)
    bad = PEOPLE_BAD
    make_account(auth, bad["unknown_role"])
    put(db, "users", "S0021", fork_profile(bad["unknown_role"]))
    put(db, "user_access", "pp-role", access_legacy(bad["unknown_role"]))
    make_account(auth, bad["profile_missing"])
    put(db, "user_access", "pp-prof", access_legacy(bad["profile_missing"]))
    put(db, "users", "S0023", fork_profile(bad["no_account"]))
    put(db, "user_access", "pp-noacc", access_legacy(bad["no_account"]))
    make_account(auth, bad["two_rows"])
    put(db, "user_access", "zz-dup", access_legacy(bad["two_rows"]))


def people_fingerprint(db):
    return {path: value for path, value in fingerprint(db).items() if not path.startswith("user_access_archive/")}


def listed(db, auth):
    return {item["id"]: item for item in access_repair.people_defects(db, auth)}


def shown(db, auth, item_id, fix_id):
    return json.loads(json.dumps(access_repair.preview_fix(db, auth, item_id, fix_id)))


def fix_ids(item):
    return [fix["id"] for fix in item["fixes"]]


def test_the_people_list_names_each_defect_once_and_writes_nothing(db, auth):
    seed_people(db, auth)
    add_swapped_row(db, auth)
    before = fingerprint(db)
    items = listed(db, auth)
    assert fingerprint(db) == before
    assert sorted(items) == ["no_account:pp-noacc", "profile_missing:pp-prof", "swapped_row:SWAP-DOC",
                             "two_rows:zz-dup", "unknown_role:pp-role"]
    for item in items.values():
        assert set(item) == {"id", "rowId", "employeeCode", "name", "defect", "text", "fixes"}
        assert item["text"] and item["employeeCode"] and all(fix["label"] for fix in item["fixes"])
    assert items["swapped_row:SWAP-DOC"]["fixes"] == []
    assert "Prepare moves it" in items["swapped_row:SWAP-DOC"]["text"]
    assert fix_ids(items["unknown_role:pp-role"]) == [
        "set_role:admin", "set_role:branch_manager", "set_role:supervisor", "set_role:salesman", "switch_off"]
    assert fix_ids(items["profile_missing:pp-prof"]) == ["make_profile", "switch_off"]
    assert fix_ids(items["no_account:pp-noacc"]) == ["switch_off"]
    assert fix_ids(items["two_rows:zz-dup"]) == ["switch_off"]
    assert "forklift" in items["unknown_role:pp-role"]["text"]
    assert access_repair.SWITCH_OFF_REASON in lifecycle.DISABLE_REASONS


def test_a_refused_swapped_row_is_listed_with_its_real_defect(db, auth):
    seed_world(db, auth)
    add_swapped_row(db, auth)
    auth.delete_user("hw-x")
    add_swapped_row(db, auth, doc_id="OFF-DOC", uid="hw-y", code="S0010", email="hw.y@example.test")
    db.collection("user_access").document("OFF-DOC").update({"status": "inactive", "isActive": False})
    items = listed(db, auth)
    assert sorted(items) == ["no_account:SWAP-DOC", "switched_off_swapped:OFF-DOC"]
    assert fix_ids(items["no_account:SWAP-DOC"]) == ["switch_off"]
    assert fix_ids(items["switched_off_swapped:OFF-DOC"]) == ["switch_off"]


FIXES = [
    ("unknown_role:pp-role", "set_role:salesman"),
    ("unknown_role:pp-role", "switch_off"),
    ("profile_missing:pp-prof", "make_profile"),
    ("profile_missing:pp-prof", "switch_off"),
    ("no_account:pp-noacc", "switch_off"),
    ("two_rows:zz-dup", "switch_off"),
]


@pytest.mark.parametrize("item_id,fix_id", FIXES)
def test_a_fix_writes_only_what_its_preview_showed(db, auth, item_id, fix_id):
    seed_people(db, auth)
    before = people_fingerprint(db)
    preview = shown(db, auth, item_id, fix_id)
    assert people_fingerprint(db) == before
    assert preview["summary"]
    accounts = {user.uid: user.email for user in auth.list_users().iterate_all()}
    result = access_repair.apply_fix(db, auth, item_id, fix_id, preview, "owner@example.test")
    after = people_fingerprint(db)
    changed = {path for path in after if before.get(path) != after[path]}
    assert changed == {change["path"] for change in preview["changes"]}
    assert sorted(result["written"]) == sorted(changed)
    for change in preview["changes"]:
        update = tenant_snapshot.decode(change["update"], db)
        old = (before.get(change["path"]) or (None, {}))[1] or {}
        new = after[change["path"]][1]
        assert {key for key in {*old, *new} if old.get(key) != new.get(key)} <= set(update)
        assert all(new[key] == value for key, value in update.items())
    left = listed(db, auth).get(item_id)
    assert left is None or fix_id not in fix_ids(left)
    assert {user.uid: user.email for user in auth.list_users().iterate_all()} == accounts


def test_a_role_fix_keeps_the_row_and_profile_in_step(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "unknown_role:pp-role", "set_role:supervisor")
    access_repair.apply_fix(db, auth, "unknown_role:pp-role", "set_role:supervisor", preview, "owner@example.test")
    assert db.collection("user_access").document("pp-role").get().to_dict()["role"] == "supervisor"
    assert db.collection("users").document("S0021").get().to_dict()["role"] == "supervisor"


def test_a_switched_off_person_holds_the_reason_on_the_row_and_profile(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "no_account:pp-noacc", "switch_off")
    access_repair.apply_fix(db, auth, "no_account:pp-noacc", "switch_off", preview, "owner@example.test")
    assert db.collection("user_access").document("pp-noacc").get().to_dict()["disabledReasons"] == ["admin_suspension"]
    assert db.collection("users").document("S0023").get().to_dict()["disabledReasons"] == ["admin_suspension"]


def test_the_profile_fix_builds_the_profile_from_the_row_and_links_it(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "profile_missing:pp-prof", "make_profile")
    access_repair.apply_fix(db, auth, "profile_missing:pp-prof", "make_profile", preview, "owner@example.test")
    profile = db.collection("users").document("S0022").get().to_dict()
    row = db.collection("user_access").document("pp-prof").get().to_dict()
    assert profile["uid"] == "pp-prof" and profile["role"] == "salesman" and profile["employeeCode"] == "S0022"
    assert profile["email"] == "pp.prof@example.test" and row["userDocId"] == "S0022"


def test_a_fix_archives_the_before_image_of_each_changed_document_and_restore_puts_it_back(db, auth):
    seed_people(db, auth)
    before = people_fingerprint(db)
    preview = shown(db, auth, "no_account:pp-noacc", "switch_off")
    result = access_repair.apply_fix(db, auth, "no_account:pp-noacc", "switch_off", preview, "owner@example.test")
    kept = {snapshot.to_dict()["path"]: (snapshot.id, snapshot.to_dict())
            for snapshot in db.collection("user_access_archive").stream()}
    assert sorted(kept) == ["user_access/pp-noacc", "users/S0023"]
    assert sorted(item[0] for item in kept.values()) == sorted(result["archived"])
    for path, (_, entry) in kept.items():
        assert entry["row"] == before[path][1] and entry["reason"] == "before_fix"
        assert entry["fixId"] == "switch_off" and entry["archivedBy"] == "owner@example.test"
    assert {item["reason"] for item in access_migration.archived_rows(db)} == {"before_fix"}
    for archive_id, _ in kept.values():
        access_migration.restore_archived(db, archive_id, "owner@example.test")
    assert people_fingerprint(db).keys() == before.keys()
    for path in before:
        assert people_fingerprint(db)[path][1] == before[path][1]
    assert access_migration.archived_rows(db) == []
    assert "no_account:pp-noacc" in listed(db, auth)


def test_a_restore_of_a_fix_refuses_when_the_record_changed_after_the_fix(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "unknown_role:pp-role", "set_role:salesman")
    result = access_repair.apply_fix(db, auth, "unknown_role:pp-role", "set_role:salesman", preview, "o@example.test")
    db.collection("user_access").document("pp-role").update({"branchId": "HW2"})
    row_archive = next(archive_id for archive_id in result["archived"]
                       if db.collection("user_access_archive").document(archive_id).get().to_dict()["path"]
                       == "user_access/pp-role")
    before = fingerprint(db)
    with pytest.raises(access_migration.RestoreRefused) as refused:
        access_migration.restore_archived(db, row_archive, "o@example.test")
    assert str(refused.value) == "This record changed after the fix. Look at it before you restore."
    assert fingerprint(db) == before


def test_the_profile_made_by_a_fix_is_removed_by_its_restore(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "profile_missing:pp-prof", "make_profile")
    result = access_repair.apply_fix(db, auth, "profile_missing:pp-prof", "make_profile", preview, "o@example.test")
    for archive_id in result["archived"]:
        access_migration.restore_archived(db, archive_id, "o@example.test")
    assert not db.collection("users").document("S0022").get().exists


def test_a_record_changed_after_the_preview_is_refused_with_no_write_and_no_image(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "unknown_role:pp-role", "switch_off")
    db.collection("user_access").document("pp-role").update({"branchId": "HW2"})
    before = fingerprint(db)
    with pytest.raises(access_repair.PeopleRefused) as refused:
        access_repair.apply_fix(db, auth, "unknown_role:pp-role", "switch_off", preview, "owner@example.test")
    assert str(refused.value) == "This record changed since you opened it. Look again before you apply."
    assert fingerprint(db) == before


def test_a_record_changed_during_the_apply_is_refused_inside_the_transaction(db, auth, monkeypatch):
    seed_people(db, auth)
    preview = shown(db, auth, "unknown_role:pp-role", "switch_off")

    class ChangeInTheGap:
        @staticmethod
        def uuid4():
            db.collection("users").document("S0021").update({"name": "changed in the gap"})
            return uuid.uuid4()

    monkeypatch.setattr(access_repair, "uuid", ChangeInTheGap)
    with pytest.raises(access_repair.PeopleRefused, match="changed since you opened it"):
        access_repair.apply_fix(db, auth, "unknown_role:pp-role", "switch_off", preview, "owner@example.test")
    assert "disabledReasons" not in db.collection("user_access").document("pp-role").get().to_dict()
    assert "disabledReasons" not in db.collection("users").document("S0021").get().to_dict()
    assert list(db.collection("user_access_archive").stream()) == []


def test_a_switch_off_is_never_stored_on_a_state_older_than_a_change_made_during_the_apply(db, auth, monkeypatch):
    seed_world(db, auth)
    seed_off_swapped(db, auth)
    row = db.collection("user_access").document("OFF-DOC")
    stored_profile = db.collection("users").document("OFF-DOC")
    row.update({"userDocId": firestore.DELETE_FIELD})
    item_id = "switched_off_swapped:OFF-DOC"
    assert item_id in listed(db, auth)
    preview = shown(db, auth, item_id, "switch_off")
    sent = threading.Event()
    failures = []

    def change_the_profile():
        other = firestore.Client(project=db.project, credentials=AnonymousCredentials())
        sent.set()
        give_up = time.monotonic() + 60
        while time.monotonic() < give_up:
            try:
                other.collection("users").document("OFF-DOC").update({"uid": "somebody-else"})
                return
            except Aborted:
                continue
            except Exception as error:
                failures.append(error)
                return
        failures.append("The change was never stored.")

    writer = threading.Thread(target=change_the_profile)
    encode_changes = access_repair._encoded
    calls = []

    def encoded_then_change(changes):
        calls.append(1)
        if len(calls) == 2:
            writer.start()
            assert sent.wait(10)
            writer.join(2)
        return encode_changes(changes)

    monkeypatch.setattr(access_repair, "_encoded", encoded_then_change)
    refused = False
    try:
        access_repair.apply_fix(db, auth, item_id, "switch_off", preview, "owner@example.test")
    except access_repair.PeopleRefused:
        refused = True
    writer.join(90)
    assert not writer.is_alive() and failures == []
    assert len(calls) >= 2
    assert item_id not in listed(db, auth)
    after = row.get()
    if refused:
        assert "disabledReasons" not in after.to_dict()
        assert list(db.collection("user_access_archive").stream()) == []
    else:
        assert after.to_dict()["disabledReasons"] == ["admin_suspension"]
        assert after.update_time < stored_profile.get().update_time


def test_a_fix_for_a_defect_the_record_no_longer_has_is_refused(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "no_account:pp-noacc", "switch_off")
    make_account(auth, PEOPLE_BAD["no_account"])
    with pytest.raises(access_repair.PeopleRefused):
        access_repair.apply_fix(db, auth, "no_account:pp-noacc", "switch_off", preview, "owner@example.test")
    assert "disabledReasons" not in db.collection("user_access").document("pp-noacc").get().to_dict()
    with pytest.raises(access_repair.PeopleRefused, match="does not belong"):
        access_repair.preview_fix(db, auth, "profile_missing:pp-prof", "set_role:admin")
    with pytest.raises(access_repair.PeopleRefused):
        access_repair.preview_fix(db, auth, "unknown_role:pp-prof", "set_role:admin")


def test_prepare_stops_reporting_a_person_who_was_switched_off(db, auth):
    seed_people(db, auth)
    named = lambda: [text for text in prepare_data.report(db, [], None, auth)["blockers"] if "S0021" in text]
    assert named()
    preview = shown(db, auth, "unknown_role:pp-role", "switch_off")
    access_repair.apply_fix(db, auth, "unknown_role:pp-role", "switch_off", preview, "owner@example.test")
    assert named() == []


def test_prepare_still_reports_a_row_that_holds_the_switch_off_reason_but_still_signs_in(db, auth):
    seed_people(db, auth)
    row = db.collection("user_access").document("pp-role")
    assert access_migration.rules_active(row.get().to_dict())
    row.update({"disabledReasons": [access_repair.SWITCH_OFF_REASON]})
    assert [text for text in prepare_data.report(db, [], None, auth)["blockers"] if "S0021" in text]


def test_a_switched_off_person_no_longer_passes_the_legacy_active_check(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "no_account:pp-noacc", "switch_off")
    access_repair.apply_fix(db, auth, "no_account:pp-noacc", "switch_off", preview, "owner@example.test")
    for collection, doc_id in (("user_access", "pp-noacc"), ("users", "S0023")):
        stored = db.collection(collection).document(doc_id).get().to_dict()
        assert stored["isActive"] is False and stored["status"] == "suspended"
        assert not access_migration.rules_active(stored)


def test_switching_off_the_second_row_of_a_shared_profile_keeps_the_profile_active(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "two_rows:zz-dup", "switch_off")
    access_repair.apply_fix(db, auth, "two_rows:zz-dup", "switch_off", preview, "owner@example.test")
    assert not access_migration.rules_active(db.collection("user_access").document("zz-dup").get().to_dict())
    assert access_migration.rules_active(db.collection("users").document("S0001").get().to_dict())


def test_prepare_finishes_after_the_second_row_of_a_shared_profile_was_switched_off(db, auth):
    seed_world(db, auth)
    make_account(auth, PEOPLE_BAD["two_rows"])
    put(db, "user_access", "zz-dup", access_legacy(PEOPLE_BAD["two_rows"]))
    preview = shown(db, auth, "two_rows:zz-dup", "switch_off")
    access_repair.apply_fix(db, auth, "two_rows:zz-dup", "switch_off", preview, "owner@example.test")
    report = prepare_data.prepare(db, load_catalogue(), None, auth_client=auth)
    assert report["blockers"] == []
    usage = db.collection("config").document("usage").get().to_dict()
    assert "membershipMaintenance" not in usage
    profile = db.collection("users").document("S0001").get().to_dict()
    assert profile["seatHeld"] is True
    assert db.collection("user_access").document("zz-dup").get().to_dict()["seatHeld"] is False
    assert db.collection("user_access").document("hw-s1").get().to_dict()["seatHeld"] is True
    assert access_repair.people_defects(db, auth) == []


def test_a_made_up_two_rows_item_cannot_switch_off_a_healthy_person(db, auth):
    seed_people(db, auth)
    before = fingerprint(db)
    for row_id in ("hw-admin", "hw-s1", "pp-noacc"):
        with pytest.raises(access_repair.PeopleRefused):
            access_repair.preview_fix(db, auth, f"two_rows:{row_id}", "switch_off")
    assert fingerprint(db) == before


@pytest.mark.parametrize("defect", ["switched_off_swapped", "identity_mismatch", "swapped_row_refused"])
def test_a_stale_or_made_up_item_cannot_switch_off_a_healthy_person(db, auth, defect):
    seed_people(db, auth)
    before = fingerprint(db)
    with pytest.raises(access_repair.PeopleRefused):
        access_repair.preview_fix(db, auth, f"{defect}:hw-s1", "switch_off")
    with pytest.raises(access_repair.PeopleRefused):
        access_repair.apply_fix(db, auth, f"{defect}:hw-s1", "switch_off", {"changes": []}, "owner@example.test")
    assert fingerprint(db) == before


def test_the_last_active_administrator_is_never_switched_off(db, auth):
    seed_people(db, auth)
    auth.delete_user("hw-admin")
    assert "no_account:hw-admin" in listed(db, auth)
    before = fingerprint(db)
    with pytest.raises(access_repair.PeopleRefused, match="last active administrator"):
        access_repair.preview_fix(db, auth, "no_account:hw-admin", "switch_off")
    assert fingerprint(db) == before


def test_a_fix_is_refused_while_a_migration_holds_the_barrier(db, auth):
    seed_people(db, auth)
    preview = shown(db, auth, "no_account:pp-noacc", "switch_off")
    db.collection("config").document("usage").set({"membershipMaintenance": {"operationId": "op-1", "writerVersion": 2}})
    before = fingerprint(db)
    with pytest.raises(access_repair.PeopleRefused, match="being prepared"):
        access_repair.apply_fix(db, auth, "no_account:pp-noacc", "switch_off", preview, "owner@example.test")
    assert fingerprint(db) == before


def test_switching_off_a_swapped_row_without_an_account_clears_its_prepare_blocker(db, auth):
    seed_world(db, auth)
    add_swapped_row(db, auth)
    auth.delete_user("hw-x")
    named = lambda: [text for text in prepare_data.report(db, [], None, auth)["blockers"] if "S0009" in text]
    assert named()
    preview = shown(db, auth, "no_account:SWAP-DOC", "switch_off")
    access_repair.apply_fix(db, auth, "no_account:SWAP-DOC", "switch_off", preview, "owner@example.test")
    assert named() == []


@pytest.mark.parametrize("item_id", ["no_account:a/b", "no_account:..", "no_account:", "no_account:__x__"])
def test_an_item_id_that_is_not_one_document_id_is_invalid(db, auth, item_id):
    seed_people(db, auth)
    with pytest.raises(access_repair.PeopleInvalid):
        access_repair.preview_fix(db, auth, item_id, "switch_off")


def test_an_item_id_with_no_row_is_not_found(db, auth):
    seed_people(db, auth)
    with pytest.raises(access_repair.PeopleNotFound):
        access_repair.preview_fix(db, auth, "no_account:nobody", "switch_off")



def seed_off_swapped(db, auth):
    add_swapped_row(db, auth, doc_id="OFF-DOC", uid="hw-y", code="S0010", email="hw.y@example.test")
    db.collection("user_access").document("OFF-DOC").update({"status": "inactive", "isActive": False})
    return "OFF-DOC"


def seed_identity(db, auth, row_id, uid, code, profile_changes):
    person = {"uid": uid, "email": f"{uid}@example.test", "code": code, "role": "salesman"}
    make_account(auth, person)
    profile = {**fork_profile(person), **profile_changes}
    put(db, "users", code, {key: value for key, value in profile.items() if value is not None})
    put(db, "user_access", row_id, access_legacy(person))
    return row_id


def seed_profile_without_uid(db, auth):
    return seed_identity(db, auth, "b-nouid", "b-nouid", "S0041", {"uid": None, "userId": "S0041"})


def seed_profile_names_another_uid(db, auth):
    return seed_identity(db, auth, "b-other", "b-other", "S0042", {"uid": "somebody-else"})


def seed_profile_has_another_role(db, auth):
    return seed_identity(db, auth, "b-role", "b-role", "S0043", {"role": "supervisor", "user_group": "supervisor"})


def seed_row_names_uid_stored_under_another_id(db, auth):
    seed_identity(db, auth, "b-stored-here", "b-names-this", "S0044", {})
    return "b-stored-here"


def seed_link_elsewhere(db, auth):
    add_swapped_row(db, auth)
    db.collection("user_access").document("SWAP-DOC").update({"userDocId": "S0001"})
    return "SWAP-DOC"


def seed_two_uids(db, auth):
    add_swapped_row(db, auth)
    db.collection("user_access").document("SWAP-DOC").update({"user_uid": "hw-other"})
    return "SWAP-DOC"


def seed_damaged_reasons_on_row(db, auth):
    add_swapped_row(db, auth)
    db.collection("user_access").document("SWAP-DOC").update({"disabledReasons": "oops"})
    return "SWAP-DOC"


def seed_damaged_reasons_on_profile(db, auth):
    add_swapped_row(db, auth)
    db.collection("users").document("SWAP-DOC").update({"disabledReasons": "oops"})
    return "SWAP-DOC"


BLOCKING_SHAPES = [
    seed_off_swapped, seed_profile_without_uid, seed_profile_names_another_uid, seed_profile_has_another_role,
    seed_row_names_uid_stored_under_another_id, seed_link_elsewhere, seed_two_uids, seed_damaged_reasons_on_row,
    seed_damaged_reasons_on_profile,
]


@pytest.mark.parametrize("seeder", BLOCKING_SHAPES, ids=lambda seeder: seeder.__name__)
def test_every_blocking_person_row_offers_a_fix_that_lets_prepare_finish(db, auth, seeder):
    seed_world(db, auth)
    row_id = seeder(db, auth)
    assert prepare_data.report(db, [], None, auth)["blockers"]
    [item] = [item for item in access_repair.people_defects(db, auth) if item["rowId"] == row_id]
    assert "switch_off" in fix_ids(item)

    profile_before = {snapshot.id: snapshot.to_dict() for snapshot in db.collection("users").stream()}
    preview = shown(db, auth, item["id"], "switch_off")
    access_repair.apply_fix(db, auth, item["id"], "switch_off", preview, "owner@example.test")
    report = prepare_data.prepare(db, load_catalogue(), None, auth_client=auth)
    assert report["blockers"] == []
    assert "membershipMaintenance" not in (db.collection("config").document("usage").get().to_dict() or {})
    assert access_repair.people_defects(db, auth) == []
    assert not access_migration.rules_active(db.collection("user_access").document(row_id).get().to_dict())
    for profile_id, before in profile_before.items():
        after = db.collection("users").document(profile_id).get().to_dict()
        assert access_migration.rules_active(after) == access_migration.rules_active(before), profile_id

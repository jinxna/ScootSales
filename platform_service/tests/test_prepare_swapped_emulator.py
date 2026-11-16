from __future__ import annotations

import json
import os
import uuid

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import access_migration, prepare_data, tenant_inventory, tenant_readiness
from platform_service.commands import CommandProblem
from platform_service.company_access import project_auth
from platform_service.plans import load_catalogue

from .test_tenant_readiness_emulator import (access_legacy, add_swapped_row, fingerprint, fork_profile, make_account, put,
                                              seed_world)

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

ROW = "SWAP-DOC"
UID = "hw-x"
CODE = "S0009"


@pytest.fixture
def project():
    return f"demo-swapped-{uuid.uuid4().hex[:10]}"


@pytest.fixture
def db(project):
    return firestore.Client(project=project, credentials=AnonymousCredentials())


@pytest.fixture
def auth(project):
    return project_auth(project)


@pytest.fixture
def world(db, auth):
    seed_world(db, auth)
    return add_swapped_row(db, auth)


def prepare_report(db, auth):
    return prepare_data.report(db, load_catalogue(), None, auth_client=auth)


def run_prepare(db, auth):
    return prepare_data.prepare(db, load_catalogue(), None, auth_client=auth)


def test_the_dry_run_lists_the_move_and_writes_nothing(db, auth, world):
    before = fingerprint(db)
    plan = access_migration.plan_access_migration(db, auth)
    [move] = [row for row in plan["convertible"] if row["uid"] == UID]
    assert move["reason"] == "swapped_row" and move["replaces"] == ROW
    assert not any(row["uid"] == ROW for row in plan["cannotConvert"])
    printed = access_migration.report("p", plan, None)["convertible"]
    [entry] = [row for row in printed if row["uid"] == UID]
    assert entry["action"] == "row moved to its sign-in id" and entry["from"] == ROW

    prepared = prepare_report(db, auth)
    assert prepared["blockers"] == [] and prepared["ready"] is True
    assert prepared["moves"] == [{"code": CODE, "rowId": ROW, "uid": UID, "action": "row moved to its sign-in id"}]
    assert prepared["prepared"] is False
    assert not any("without an access record" in note for note in prepared["notes"])
    assert fingerprint(db) == before


def test_prepare_moves_the_row_and_keeps_the_identity(db, auth, world):
    account = auth.get_user(UID)
    profile_before = db.collection("users").document(ROW).get()
    old = db.collection("user_access").document(ROW).get().to_dict()
    result = run_prepare(db, auth)
    assert result["prepared"] is True and result["moves"] == [] and result["blockers"] == []
    assert not db.collection("user_access").document(ROW).get().exists
    row = db.collection("user_access").document(UID).get().to_dict()
    assert row["accessVersion"] == 2 and row["uid"] == UID and row["userDocId"] == ROW
    assert row["role"] == old["role"] == "salesman" and row["employeeCode"] == CODE
    assert row["branchId"] == old["branchId"] == "HW1" and row["status"] == "active"
    assert row["disabledReasons"] == [] and row["seatClass"] == "salesman" and row["seatHeld"] is True
    profile_after = db.collection("users").document(ROW).get()
    assert profile_after.to_dict()["uid"] == UID and profile_after.to_dict()["seatHeld"] is True
    assert profile_before.to_dict().items() <= profile_after.to_dict().items()
    assert auth.get_user(UID).email == account.email and auth.get_user(UID).uid == account.uid
    usage = db.collection("config").document("usage").get().to_dict()
    assert usage["seats"]["salesmen"] == 3

    def people_documents():
        return {path: value for path, value in fingerprint(db).items() if path.split("/")[0] in ("user_access", "users")}

    again = people_documents()
    assert run_prepare(db, auth)["prepared"] is True
    assert people_documents() == again


CHANGED_AFTER_PLAN = {
    "profile": lambda db, auth: db.collection("users").document(ROW).update({"name": "changed after the plan"}),
    "row": lambda db, auth: db.collection("user_access").document(ROW).update({"branchId": "HW2"}),
    "target": lambda db, auth: db.collection("user_access").document(UID).set({"uid": UID, "note": "keep"}),
    "account": lambda db, auth: auth.delete_user(UID),
}


@pytest.mark.parametrize("case", sorted(CHANGED_AFTER_PLAN))
def test_a_precondition_changed_between_plan_and_apply_is_skipped(db, auth, world, case):
    plan = access_migration.plan_access_migration(db, auth)
    CHANGED_AFTER_PLAN[case](db, auth)
    applied = access_migration.apply_plan(db, plan, auth)
    assert UID in applied["changedDuringApply"] and UID not in applied["written"]
    assert db.collection("user_access").document(ROW).get().exists
    target = db.collection("user_access").document(UID).get()
    assert not target.exists or target.to_dict() == {"uid": UID, "note": "keep"}


PARTIAL = {
    "no-account": (lambda db, auth: auth.delete_user(UID), "sign-in account"),
    "target-exists": (lambda db, auth: db.collection("user_access").document(UID).set({"uid": UID}),
                      "already exists"),
    "link-elsewhere": (lambda db, auth: db.collection("user_access").document(ROW).update({"userDocId": "OTHER"}),
                       "another profile"),
    "inactive": (lambda db, auth: db.collection("user_access").document(ROW).update(
        {"status": "inactive", "isActive": False}), "switched off"),
    "profile-other-uid": (lambda db, auth: db.collection("users").document(ROW).update({"uid": "someone-else"}),
                          "stored under the id"),
    "profile-missing": (lambda db, auth: db.collection("users").document(ROW).delete(), "does not exist"),
}


@pytest.mark.parametrize("case", sorted(PARTIAL))
def test_a_partial_shape_is_refused_with_the_real_defect(db, auth, world, case):
    change, expected = PARTIAL[case]
    change(db, auth)
    result = prepare_report(db, auth)
    named = [blocker for blocker in result["blockers"] if CODE in blocker]
    assert len(named) == 1, result["blockers"]
    assert expected in named[0]
    assert result["moves"] == []
    for blocker in result["blockers"]:
        assert "no profile" not in blocker and "Staff page" not in blocker
    before = fingerprint(db)
    with pytest.raises(CommandProblem) as refused:
        run_prepare(db, auth)
    assert expected in str(refused.value)
    assert fingerprint(db) == before
    assert db.collection("user_access").document(ROW).get().exists


def test_two_swapped_rows_are_ready_in_readiness_and_move_together(db, auth):
    seed_world(db, auth)
    add_swapped_row(db, auth, doc_id="user_access", uid="live-adm", code="ADM001", email="live.adm@example.test")
    add_swapped_row(db, auth, doc_id="hAdrXEWlive", uid="live-sm", code="SM001", email="live.sm@example.test")
    report = tenant_readiness.readiness(db, auth_client=auth, packages=load_catalogue(),
                                        budget=tenant_readiness.DEFAULT_MAX_READS, project="p").report
    assert report["verdict"] == "ready" and report["blockers"] == []
    assert report["auth"]["missing"] == 0
    assert report["people"]["inventory"]["legacyAccessRows"]["byReason"] == {}
    assert sorted(move["code"] for move in report["people"]["moves"]) == ["ADM001", "SM001"]
    run_prepare(db, auth)
    assert {snapshot.id for snapshot in db.collection("user_access").stream()} == {
        "hw-admin", "hw-sup", "hw-s1", "hw-s2", "live-adm", "live-sm"}
    after = tenant_readiness.readiness(db, auth_client=auth, packages=load_catalogue(),
                                       budget=tenant_readiness.DEFAULT_MAX_READS, project="p").report
    assert after["verdict"] == "ready" and after["people"]["moves"] == []


def test_the_inventory_command_without_an_auth_client_cannot_confirm_the_account(db, auth, world, project, capsys):
    plan = access_migration.plan_access_migration(db)
    [row] = [row for row in plan["cannotConvert"] if row["uid"] == ROW]
    assert row["reason"] == "swapped_row_auth_unchecked"
    assert tenant_inventory.inventory(db)["legacyAccessRows"]["byReason"] == {"swapped_row_auth_unchecked": 1}
    assert tenant_inventory.inventory(db, auth)["legacyAccessRows"]["byReason"] == {}
    capsys.readouterr()
    assert access_migration.main(["--project", project]) == 0
    assert "swapped_row_auth_unchecked" in json.loads(capsys.readouterr().out)["cannotConvert"][0]["reason"]


def test_the_move_archives_the_old_row_unchanged_and_lists_it(db, auth, world):
    old = db.collection("user_access").document(ROW).get().to_dict()
    run_prepare(db, auth)
    assert not db.collection("user_access").document(ROW).get().exists
    kept = db.collection("user_access_archive").document(ROW).get().to_dict()
    assert kept["row"] == old and kept["reason"] == "swapped_row" and kept["movedTo"] == UID
    assert kept["archivedBy"] == "prepare" and kept["archivedAt"] is not None
    assert access_migration.archived_rows(db) == [
        {"id": ROW, "movedTo": UID, "reason": "swapped_row", "path": None, "fixId": None, "employeeCode": CODE,
         "archivedBy": "prepare"}]


def test_restore_puts_the_old_row_back_exactly_and_removes_the_moved_row(db, auth, world):
    old = db.collection("user_access").document(ROW).get().to_dict()
    account = auth.get_user(UID)
    run_prepare(db, auth)
    result = access_migration.restore_moved_row(db, ROW, "owner@example.test")
    assert result == {"restored": ROW, "removed": UID}
    assert db.collection("user_access").document(ROW).get().to_dict() == old
    assert not db.collection("user_access").document(UID).get().exists
    archived = db.collection("user_access_archive").document(ROW).get().to_dict()
    assert archived["restoredBy"] == "owner@example.test" and archived["restoredAt"] is not None
    assert access_migration.archived_rows(db) == []
    assert auth.get_user(UID).email == account.email and auth.get_user(UID).uid == account.uid
    with pytest.raises(access_migration.RestoreRefused, match="no archived record"):
        access_migration.restore_moved_row(db, ROW, "owner@example.test")
    run_prepare(db, auth)
    assert db.collection("user_access").document(UID).get().to_dict()["userDocId"] == ROW


def test_restore_refuses_when_the_moved_row_changed_after_the_move(db, auth, world):
    run_prepare(db, auth)
    db.collection("user_access").document(UID).update({"branchId": "HW2"})
    before = fingerprint(db)
    with pytest.raises(access_migration.RestoreRefused) as refused:
        access_migration.restore_moved_row(db, ROW, "owner@example.test")
    assert str(refused.value) == "This record changed after the move. Look at it before you restore."
    assert fingerprint(db) == before


def test_restore_refuses_when_a_record_sits_at_the_old_id(db, auth, world):
    run_prepare(db, auth)
    db.collection("user_access").document(ROW).set({"note": "someone made this"})
    with pytest.raises(access_migration.RestoreRefused, match="exists already"):
        access_migration.restore_moved_row(db, ROW, "owner@example.test")
    assert db.collection("user_access").document(ROW).get().to_dict() == {"note": "someone made this"}
    assert db.collection("user_access").document(UID).get().exists


OWN = {"uid": "live-adm", "email": "live.adm@example.test", "code": "ADM001", "role": "admin"}


def add_row_linking_to_its_own_profile(db, auth, profile_role="admin"):
    seed_world(db, auth)
    make_account(auth, OWN)
    put(db, "users", "live-adm", fork_profile({**OWN, "role": profile_role}))
    put(db, "user_access", "user_access", {**access_legacy(OWN), "userDocId": "live-adm"})


def test_a_row_stored_under_another_id_that_links_to_its_own_profile_moves_to_its_sign_in_id(db, auth):
    add_row_linking_to_its_own_profile(db, auth)
    old = db.collection("user_access").document("user_access").get().to_dict()

    prepared = prepare_report(db, auth)
    assert prepared["blockers"] == [] and prepared["ready"] is True
    assert prepared["moves"] == [{"code": "ADM001", "rowId": "user_access", "uid": "live-adm",
                                  "action": "row moved to its sign-in id"}]

    run_prepare(db, auth)
    assert not db.collection("user_access").document("user_access").get().exists
    row = db.collection("user_access").document("live-adm").get().to_dict()
    assert row["accessVersion"] == 2 and row["uid"] == "live-adm" and row["userDocId"] == "live-adm"
    assert row["role"] == "admin" and row["employeeCode"] == "ADM001" and row["status"] == "active"
    kept = db.collection("user_access_archive").document("user_access").get().to_dict()
    assert kept["row"] == old and kept["movedTo"] == "live-adm"
    assert prepare_report(db, auth)["blockers"] == []


def test_a_row_linking_to_its_own_profile_of_another_role_is_not_moved(db, auth):
    add_row_linking_to_its_own_profile(db, auth, profile_role="salesman")
    result = prepare_report(db, auth)
    assert result["moves"] == []
    assert any(blocker.startswith("ADM001:") for blocker in result["blockers"]), result["blockers"]
    before = fingerprint(db)
    with pytest.raises(CommandProblem):
        run_prepare(db, auth)
    assert fingerprint(db) == before


def test_a_profile_made_at_the_row_id_after_the_plan_stops_the_move(db, auth):
    add_row_linking_to_its_own_profile(db, auth)
    plan = access_migration.plan_access_migration(db, auth)
    put(db, "users", "user_access", {"uid": "someone-else"})
    applied = access_migration.apply_plan(db, plan, auth)
    assert "live-adm" in applied["changedDuringApply"] and "live-adm" not in applied["written"]
    assert db.collection("user_access").document("user_access").get().exists
    assert not db.collection("user_access").document("live-adm").get().exists

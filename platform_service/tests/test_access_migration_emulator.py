from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import access_migration, tenant_inventory

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="needs the Firestore emulator"
)

STRICT_ROLES = ("admin", "developer", "branch_manager", "supervisor", "salesman")
CONVERTIBLE = {"uidAdmin", "uidSales", "uidSup", "uidProf", "uidLapse", "uidLapseLinked"}
REFUSED = {
    "uidInactive": "inactive",
    "uidInactiveLinked": "inactive",
    "uidProfInactive": "inactive",
    "uidUnknown": "unknown_role",
    "uidMismatch": "uid_mismatch",
    "uidActorMismatch": "uid_mismatch",
    "uidBroken": "broken_link",
    "uidBadReasons": "invalid_disabled_reasons",
    "uidFuture": "unsupported_access_version",
}
LEGACY_ACCESS_ROWS = {"uidAdmin", "uidSales", "uidSup", "uidLapse", "uidLapseLinked"} | {
    uid for uid in REFUSED if uid != "uidProfInactive"
}


@pytest.fixture
def project():
    return f"demo-access-mig-{uuid.uuid4().hex[:10]}"


@pytest.fixture
def db(project):
    return firestore.Client(project=project, credentials=AnonymousCredentials())


def put(db, collection, doc_id, data):
    db.collection(collection).document(doc_id).set(data)


def seed(db):
    put(db, "user_access", "uidAdmin", {
        "uid": "uidAdmin", "role": "Administrator", "status": "Active", "isActive": "true",
        "branch_id": "B1", "staffId": "E-ADMIN"})
    put(db, "user_access", "uidSales", {"uid": "uidSales", "userDocId": "S002"})
    put(db, "users", "S002", {
        "uid": "uidSales", "role": "Sales Representative", "user_group": "salesman", "is_active": True,
        "status": "active", "branchId": "B1", "salesman_code": "S002"})
    put(db, "user_access", "uidSup", {"uid": "uidSup", "user_doc_id": "SUP1"})
    put(db, "users", "SUP1", {
        "userUid": "uidSup", "user_group": "supervisor", "enabled": 1, "account_status": "active",
        "branch_id": "B2", "employeeCode": "SUP1", "assignedSalesmanCodes": ["S002", "S003"]})
    put(db, "users", "uidProf", {
        "uid": "uidProf", "role": "branch_manager", "status": "active", "isActive": True,
        "branchId": "B3", "employeeCode": "BM1"})
    put(db, "user_access", "uidLapse", {
        "uid": "uidLapse", "role": "admin", "status": "active", "branchId": "B1",
        "employeeCode": "E-LAPSE", "disabledReasons": ["lifecycle_readonly"]})
    put(db, "user_access", "uidLapseLinked", {"uid": "uidLapseLinked", "userDocId": "LL1"})
    put(db, "users", "LL1", {
        "uid": "uidLapseLinked", "role": "salesman", "status": "active", "branchId": "B1",
        "employeeCode": "LL1", "disabledReasons": ["payment_overdue"]})
    put(db, "user_access", "uidInactive", {
        "uid": "uidInactive", "role": "salesman", "status": "suspended", "isActive": False,
        "branchId": "B1", "employeeCode": "E-INACT"})
    put(db, "user_access", "uidInactiveLinked", {"uid": "uidInactiveLinked", "userDocId": "IL1"})
    put(db, "users", "IL1", {
        "uid": "uidInactiveLinked", "role": "salesman", "status": "active", "is_active": False,
        "employeeCode": "IL1"})
    put(db, "users", "uidProfInactive", {
        "uid": "uidProfInactive", "role": "salesman", "status": "inactive", "employeeCode": "PI1"})
    put(db, "user_access", "uidUnknown", {
        "uid": "uidUnknown", "role": "janitor", "status": "active", "employeeCode": "J1"})
    put(db, "user_access", "uidMismatch", {
        "uid": "someoneElse", "role": "admin", "status": "active", "employeeCode": "M1"})
    put(db, "user_access", "uidActorMismatch", {"uid": "uidActorMismatch", "userDocId": "AM1"})
    put(db, "users", "AM1", {
        "uid": "notTheSame", "role": "admin", "status": "active", "employeeCode": "AM1"})
    put(db, "user_access", "uidBroken", {"uid": "uidBroken", "userDocId": "NOPE"})
    put(db, "user_access", "uidBadReasons", {
        "uid": "uidBadReasons", "role": "admin", "status": "active", "employeeCode": "BR1",
        "disabledReasons": "lifecycle_readonly"})
    put(db, "user_access", "uidFuture", {
        "accessVersion": 3, "uid": "uidFuture", "role": "admin", "status": "active"})
    put(db, "user_access", "uidV2", {
        "accessVersion": 2, "uid": "uidV2", "role": "salesman", "status": "active", "branchId": "B1",
        "employeeCode": "V2", "assignedSalesmanCodes": [], "disabledReasons": []})
    put(db, "users", "E99", {"role": "salesman", "status": "active", "employeeCode": "E99"})
    put(db, "users", "OTHER", {"uid": "different", "role": "salesman", "status": "active"})


def seed_orders(db):
    lines = ["P1~Name~2~1500"]
    put(db, "orders", "o1", {"status": "submitted", "commercialSchemaVersion": 1, "commercialLines": lines})
    put(db, "orders", "o2", {"status": "submitted", "items": [{"productId": "P1"}]})
    put(db, "orders", "o3", {"status": "draft", "commercialSchemaVersion": 1, "commercialLines": []})
    put(db, "orders", "o4", {"status": "approved", "commercialSchemaVersion": 2, "commercialLines": lines})


def fingerprint(db):
    result = {}
    for collection in db.collections():
        for snapshot in collection.stream():
            result[f"{collection.id}/{snapshot.id}"] = (snapshot.update_time, snapshot.to_dict())
    return result


def run_worker(monkeypatch, capsys, argv):
    try:
        code = access_migration.main([flag for flag in argv if flag != "--migrate-access-v2"])
    except SystemExit as stop:
        code = stop.code or 0
    captured = capsys.readouterr()
    return code, captured.out, captured.err


def run_inventory(monkeypatch, capsys, project):
    monkeypatch.setattr(sys, "argv", ["tenant_inventory", "--project", project])
    assert tenant_inventory.main() == 0
    return json.loads(capsys.readouterr().out)


def access(db, uid):
    return db.collection("user_access").document(uid).get().to_dict()


def strict_identity(uid, row):
    reasons = row.get("disabledReasons", [])
    if not (
        row.get("uid", "") == uid
        and row.get("status", "") == "active"
        and row.get("role", "") in STRICT_ROLES
        and isinstance(row.get("branchId", ""), str)
        and isinstance(row.get("employeeCode", ""), str)
        and isinstance(reasons, list)
        and len(reasons) == 0
    ):
        return None
    codes = row.get("assignedSalesmanCodes", [])
    return (row["role"], row.get("branchId", ""), row.get("employeeCode", ""),
            codes if isinstance(codes, list) else [])






def test_apply_requires_the_matching_confirmation_project(db, project, monkeypatch, capsys):
    seed(db)
    before = fingerprint(db)
    for extra in ([], ["--confirm-project", "demo-some-other-project"]):
        code, _, err = run_worker(
            monkeypatch, capsys, ["--migrate-access-v2", "--project", project, "--apply", *extra])
        assert code == 2
        assert "confirm" in err.lower()
    assert fingerprint(db) == before


def test_apply_writes_only_convertible_rows_and_keeps_legacy_data(db, project, monkeypatch, capsys):
    seed(db)
    before = fingerprint(db)
    code, out, _ = run_worker(monkeypatch, capsys, [
        "--migrate-access-v2", "--project", project, "--apply", "--confirm-project", project])
    assert code == 0
    assert set(json.loads(out)["applied"]["written"]) == CONVERTIBLE
    after = fingerprint(db)
    for key, snapshot in before.items():
        collection, doc_id = key.split("/")
        if collection == "users" or doc_id not in CONVERTIBLE:
            assert after[key] == snapshot, key
    for uid in CONVERTIBLE:
        stored = after[f"user_access/{uid}"][1]
        assert stored["accessVersion"] == 2
        assert stored["status"] == "active"
        original = before.get(f"user_access/{uid}", (None, {}))[1]
        for field, value in original.items():
            if field not in ("role", "status", "branchId", "employeeCode", "userDocId"):
                assert stored[field] == value, (uid, field)
    assert after["user_access/uidAdmin"][1]["staffId"] == "E-ADMIN"
    assert after["user_access/uidAdmin"][1]["branch_id"] == "B1"
    assert "user_access/uidProfInactive" not in after
    assert "user_access/E99" not in after
    assert "user_access/OTHER" not in after


def test_second_apply_changes_nothing(db):
    seed(db)
    first = access_migration.apply_migration(db)
    assert set(first["written"]) == CONVERTIBLE
    after_first = fingerprint(db)
    second = access_migration.apply_migration(db)
    assert second["written"] == []
    assert fingerprint(db) == after_first
    assert access_migration.plan_access_migration(db)["convertible"] == []






def test_row_changed_after_the_scan_is_not_overwritten(db):
    seed(db)
    plan = access_migration.plan_access_migration(db)
    db.collection("user_access").document("uidAdmin").update({"status": "suspended", "isActive": False})
    db.collection("users").document("uidProf").update({"status": "suspended", "isActive": False})
    result = access_migration.apply_plan(db, plan)
    assert set(result["changedDuringApply"]) == {"uidAdmin", "uidProf"}
    assert "accessVersion" not in access(db, "uidAdmin")
    assert not db.collection("user_access").document("uidProf").get().exists
    assert access(db, "uidSales")["accessVersion"] == 2

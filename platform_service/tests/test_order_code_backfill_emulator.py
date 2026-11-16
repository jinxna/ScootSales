from __future__ import annotations

import json
import os
import uuid

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import order_code_backfill

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="needs the Firestore emulator"
)

FORK_ORDERS = {
    "viaAccess": ("uidA", "E-1001"),
    "viaLink": ("uidB", "E-1002"),
    "viaProfileUid": ("uidC", "E-1003"),
    "viaAccessAgain": ("uidA", "E-1001"),
}


@pytest.fixture
def project():
    return f"demo-order-code-{uuid.uuid4().hex[:10]}"


@pytest.fixture
def db(project):
    return firestore.Client(project=project, credentials=AnonymousCredentials())


def put(db, collection, doc_id, data):
    db.collection(collection).document(doc_id).set(data)


def fork_order(uid, **extra):
    return {"salesmanUid": uid, "salesmanId": "STAFF-777", "status": "submitted", "totalAmount": 12.5,
            "items": [{"productId": "HW-1", "quantity": 2}], **extra}


def seed(db):
    put(db, "user_access", "uidA", {"uid": "uidA", "role": "salesman", "status": "active", "employeeCode": "E-1001"})
    put(db, "user_access", "uidB", {"uid": "uidB", "userDocId": "P2", "role": "salesman", "status": "active"})
    put(db, "users", "P2", {"uid": "uidB", "employeeCode": "E-1002", "staffId": "STAFF-777"})
    put(db, "users", "P3", {"userUid": "uidC", "employeeCode": "E-1003"})
    put(db, "users", "P4a", {"uid": "uidTwo", "employeeCode": "E-2001"})
    put(db, "users", "P4b", {"uid": "uidTwo", "employeeCode": "E-2002"})
    put(db, "user_access", "uidNoCode", {"uid": "uidNoCode", "role": "salesman", "status": "active"})
    for order_id, (uid, _code) in FORK_ORDERS.items():
        put(db, "orders", order_id, fork_order(uid))
    put(db, "orders", "alreadyCamel", fork_order("uidA", salesmanCode="KEEP-1"))
    put(db, "orders", "alreadySnake", fork_order("uidA", salesman_code="KEEP-2"))
    put(db, "orders", "noPerson", fork_order("uidGone"))
    put(db, "orders", "noCode", fork_order("uidNoCode"))
    put(db, "orders", "twoCodes", fork_order("uidTwo"))
    put(db, "orders", "noUid", {"status": "submitted", "salesmanId": "STAFF-777"})


def snapshots(db):
    return {snapshot.id: snapshot for snapshot in db.collection("orders").stream()}


def run(monkeypatch, capsys, project, *extra):
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", project)
    code = order_code_backfill.main(["--project", project, *extra])
    captured = capsys.readouterr()
    return code, (json.loads(captured.out) if captured.out else None), captured.err


def test_dry_run_lists_the_plan_and_writes_nothing(db, project, monkeypatch, capsys):
    seed(db)
    before = snapshots(db)
    code, report, _ = run(monkeypatch, capsys, project)
    after = snapshots(db)
    assert code == 0
    assert report["mode"] == "dry-run"
    assert report["convertible"] == len(FORK_ORDERS)
    assert report["skippedByReason"] == {
        "no person with an employee code for this uid": 2,
        "the person records give different employee codes": 1,
        "the order has no salesman uid": 1,
    }
    assert {item["id"] for item in report["skipped"]} == {"noPerson", "noCode", "twoCodes", "noUid"}
    assert {key: snapshot.update_time for key, snapshot in after.items()} == \
        {key: snapshot.update_time for key, snapshot in before.items()}


@pytest.mark.parametrize("extra", [["--apply"], ["--apply", "--confirm-project", "demo-other"]])
def test_apply_requires_the_matching_confirmation_project(db, project, monkeypatch, capsys, extra):
    seed(db)
    before = {key: snapshot.update_time for key, snapshot in snapshots(db).items()}
    code, report, err = run(monkeypatch, capsys, project, *extra)
    assert code == 2
    assert report is None
    assert "--confirm-project" in err
    assert {key: snapshot.update_time for key, snapshot in snapshots(db).items()} == before


def test_apply_writes_the_employee_code_and_only_that_field(db, project, monkeypatch, capsys):
    seed(db)
    before = {key: snapshot.to_dict() for key, snapshot in snapshots(db).items()}
    code, report, _ = run(monkeypatch, capsys, project, "--apply", "--confirm-project", project)
    assert code == 0
    assert report["applied"] == {"written": len(FORK_ORDERS), "changedDuringApply": []}
    after = {key: snapshot.to_dict() for key, snapshot in snapshots(db).items()}
    assert set(after) == set(before)
    for order_id, (_uid, employee_code) in FORK_ORDERS.items():
        assert after[order_id] == {**before[order_id], "salesmanCode": employee_code}
        assert after[order_id]["salesmanId"] == "STAFF-777"
    untouched = set(before) - set(FORK_ORDERS)
    assert {key: after[key] for key in untouched} == {key: before[key] for key in untouched}


def test_a_second_apply_writes_nothing(db, project, monkeypatch, capsys):
    seed(db)
    run(monkeypatch, capsys, project, "--apply", "--confirm-project", project)
    stamps = {key: snapshot.update_time for key, snapshot in snapshots(db).items()}
    code, report, _ = run(monkeypatch, capsys, project, "--apply", "--confirm-project", project)
    assert code == 0
    assert report["convertible"] == 0
    assert report["applied"] == {"written": 0, "changedDuringApply": []}
    assert {key: snapshot.update_time for key, snapshot in snapshots(db).items()} == stamps


def test_an_order_coded_after_the_scan_is_not_overwritten(db, project):
    seed(db)
    plan = order_code_backfill.plan_code_backfill(db)
    db.collection("orders").document("viaAccess").update({"salesmanCode": "SET-LATER"})
    applied = order_code_backfill.apply_code_backfill(db, plan)
    assert applied == {"written": len(FORK_ORDERS) - 1, "changedDuringApply": ["viaAccess"]}
    assert db.collection("orders").document("viaAccess").get().to_dict()["salesmanCode"] == "SET-LATER"


def test_exit_code_is_3_when_an_order_changed_during_apply(db, project, monkeypatch, capsys):
    seed(db)
    real_plan = order_code_backfill.plan_code_backfill

    def plan_then_change(client):
        plan = real_plan(client)
        client.collection("orders").document("viaLink").update({"salesmanCode": "SET-LATER"})
        return plan

    monkeypatch.setattr(order_code_backfill, "plan_code_backfill", plan_then_change)
    code, report, _ = run(monkeypatch, capsys, project, "--apply", "--confirm-project", project)
    assert code == 3
    assert report["applied"]["changedDuringApply"] == ["viaLink"]


def test_supervisor_team_query_finds_the_fork_orders_after_apply(db, project, monkeypatch, capsys):
    seed(db)
    team = ["E-1001", "E-1002", "E-1003"]
    assert list(db.collection("orders").where("salesmanCode", "in", team).stream()) == []
    run(monkeypatch, capsys, project, "--apply", "--confirm-project", project)
    found = {snapshot.id for snapshot in db.collection("orders").where("salesmanCode", "in", team).stream()}
    assert found == set(FORK_ORDERS)


def test_an_order_whose_salesman_changed_after_the_scan_is_not_written(db, project):
    seed(db)
    plan = order_code_backfill.plan_code_backfill(db)
    db.collection("orders").document("viaAccess").update({"salesmanUid": "uidB"})
    applied = order_code_backfill.apply_code_backfill(db, plan)
    assert applied == {"written": len(FORK_ORDERS) - 1, "changedDuringApply": ["viaAccess"]}
    assert "salesmanCode" not in db.collection("orders").document("viaAccess").get().to_dict()

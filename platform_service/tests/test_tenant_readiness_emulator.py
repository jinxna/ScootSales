from __future__ import annotations

import json
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import migrate_seats, prepare_data, tenant_readiness
from platform_service.company_access import project_auth
from platform_service.plans import load_catalogue

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

BRANCH = "HW1"
PASSWORD = "Passw0rd!2026"
PEOPLE = {
    "admin": {"uid": "hw-admin", "email": "hw.admin@example.test", "code": "A0001", "role": "admin"},
    "sup": {"uid": "hw-sup", "email": "hw.sup@example.test", "code": "SV0001", "role": "supervisor"},
    "s1": {"uid": "hw-s1", "email": "hw.s1@example.test", "code": "S0001", "role": "salesman"},
    "s2": {"uid": "hw-s2", "email": "hw.s2@example.test", "code": "S0002", "role": "salesman"},
}
SHAPE_EXPECTATION = {
    "linked": "ready",
    "uidProfileOnly": "ready",
    "profileWithoutUid": "blocked",
    "userGroupRole": "ready",
    "inactive": "ready",
    "noLink": "blocked",
    "swappedRow": "ready",
}


@pytest.fixture
def project():
    return f"demo-readiness-{uuid.uuid4().hex[:10]}"


@pytest.fixture
def db(project):
    return firestore.Client(project=project, credentials=AnonymousCredentials())


@pytest.fixture
def auth(project):
    return project_auth(project)


def fork_profile(person, **extra):
    salesman = person["role"] == "salesman"
    return {
        "uid": person["uid"], "userId": person["code"], "employeeCode": person["code"],
        "name": f"{person['role']} {person['code']}", "email": person["email"],
        "username": person["email"].split("@")[0], "role": person["role"], "user_group": person["role"],
        "status": "active", "isActive": True, "branchId": BRANCH, "branch_id": BRANCH,
        "supervisorId": "SV0001" if salesman else "", "supervisor_id": "SV0001" if salesman else "",
        "contactNumber": "0123456789", "contact_number": "0123456789", **extra,
    }


def fork_access_v2(person):
    salesman = person["role"] == "salesman"
    row = {
        "accessVersion": 2, "uid": person["uid"], "userDocId": person["code"], "employeeCode": person["code"],
        "userId": person["code"], "email": person["email"], "role": person["role"], "user_group": person["role"],
        "status": "active", "isActive": True, "branchId": BRANCH, "branch_id": BRANCH,
        "supervisorId": "SV0001" if salesman else "", "supervisor_id": "SV0001" if salesman else "",
        "supervisorUid": PEOPLE["sup"]["uid"] if salesman else "",
        "seatClass": "salesperson" if salesman else "free",
        "updatedAt": datetime(2026, 1, 1, tzinfo=timezone.utc),
    }
    if person["role"] == "supervisor":
        row["assignedSalesmanCodes"] = ["S0001", "S0002"]
    return row


def access_legacy(person):
    row = fork_access_v2(person)
    for key in ("accessVersion", "seatClass", "supervisorUid", "updatedAt"):
        row.pop(key, None)
    return row


def put(db, collection, doc_id, data):
    db.collection(collection).document(doc_id).set(data)


def make_account(auth, person):
    auth.create_user(uid=person["uid"], email=person["email"], password=PASSWORD)


def product(product_id, name, **extra):
    return {"productId": product_id, "departmentName": "Hardware", "itemName": name, "itemCode": product_id,
            "sku": product_id, "unitPrice": 12.5, "price": 12.5, "priceGuide": 12.5, "isVisible": True,
            "status": "active", **extra}


def seed_world(db, auth):
    for person in PEOPLE.values():
        make_account(auth, person)
        put(db, "users", person["code"], fork_profile(
            person, **({"assignedSalesmanCodes": ["S0001", "S0002"]} if person["role"] == "supervisor" else {})))
        put(db, "user_access", person["uid"],
            access_legacy(person) if person is PEOPLE["s2"] else fork_access_v2(person))
    put(db, "products", "HW-0001", product("HW-0001", "Wood screw 2in"))
    put(db, "products", "HW-0002", product("HW-0002", "Claw hammer", unitPrice=30.0, price=28.9, priceGuide=28.9))
    put(db, "products", "HW-0003", product("HW-0003", "PVC pipe 20mm"))
    put(db, "products", "HW-0004", product("HW-0004", "Hidden cable tie", isVisible=False))
    put(db, "products", "HW-0005", {**product("", "Loose item"), "productId": "", "barcode": "955000011112"})
    put(db, "products", "HW-0006", {"productId": "HW-0006", "itemName": "Old price item", "isVisible": True,
                                    "sellingPrice": 9.9})
    lines = ["HW-0001~Wood screw~2~1250"]
    put(db, "orders", "o1", {"status": "submitted", "commercialSchemaVersion": 1, "commercialLines": lines})
    put(db, "orders", "o2", {"status": "submitted", "items": [{"productId": "HW-0001"}]})
    put(db, "live_tracking", "hw-s1", {"salesmanUid": "hw-s1", "lat": 1.5, "lng": 110.3})
    put(db, "live_tracking", "hw-s2", {"uid": "hw-s2", "salesmanUid": "hw-s2"})


def add_swapped_row(db, auth, doc_id="SWAP-DOC", uid="hw-x", code="S0009", email="hw.x@example.test"):
    person = {"uid": uid, "email": email, "code": code, "role": "salesman"}
    make_account(auth, person)
    put(db, "users", doc_id, fork_profile(person))
    put(db, "user_access", doc_id, {**access_legacy(person), "userDocId": uid})
    return person


def add_shape(db, auth, shape):
    extra = {"uid": "hw-x", "email": "hw.x@example.test", "code": "S0009", "role": "salesman"}
    if shape == "linked":
        return
    if shape == "swappedRow":
        add_swapped_row(db, auth)
        return
    make_account(auth, extra)
    if shape == "uidProfileOnly":
        put(db, "users", extra["uid"], fork_profile(extra))
    elif shape == "profileWithoutUid":
        profile = fork_profile(extra)
        del profile["uid"]
        put(db, "users", extra["code"], profile)
        put(db, "user_access", extra["uid"], access_legacy(extra))
    elif shape == "userGroupRole":
        profile = fork_profile(extra)
        del profile["role"]
        row = access_legacy(extra)
        del row["role"]
        put(db, "users", extra["code"], profile)
        put(db, "user_access", extra["uid"], row)
    elif shape == "inactive":
        put(db, "users", extra["code"], fork_profile(extra, status="inactive", isActive=False))
        put(db, "user_access", extra["uid"], {**access_legacy(extra), "status": "inactive", "isActive": False})
    elif shape == "noLink":
        row = access_legacy(extra)
        del row["userDocId"]
        put(db, "user_access", extra["uid"], row)
    else:
        raise AssertionError(shape)


def fingerprint(db):
    result = {}
    for collection in db.collections():
        for snapshot in collection.stream():
            result[f"{collection.id}/{snapshot.id}"] = (snapshot.update_time, snapshot.to_dict())
    return result


def run_readiness(db, auth, project, **extra):
    return tenant_readiness.readiness(db, auth_client=auth, packages=load_catalogue(),
                                      budget=tenant_readiness.DEFAULT_MAX_READS, project=project, **extra)


@pytest.mark.parametrize("shape", sorted(SHAPE_EXPECTATION))
def test_verdict_and_blockers_equal_the_prepare_report(db, auth, project, shape):
    seed_world(db, auth)
    add_shape(db, auth, shape)
    result = run_readiness(db, auth, project)
    prepare = prepare_data.report(db, load_catalogue(), None, auth_client=auth)
    assert result.report["people"]["blockers"] == prepare["blockers"]
    assert (result.verdict == "ready") == prepare["ready"]
    assert result.verdict == SHAPE_EXPECTATION[shape]
    assert result.report["auth"]["missing"] == 0
    assert result.report["people"]["notes"] == prepare["notes"]
    assert result.report["people"]["counts"] == prepare["counts"]


def test_a_person_without_an_auth_account_blocks_and_is_named(db, auth, project):
    seed_world(db, auth)
    auth.delete_user("hw-s1")
    result = run_readiness(db, auth, project)
    assert result.verdict == "blocked"
    assert result.report["auth"]["missing"] == 1
    [blocker] = result.report["auth"]["blockers"]
    assert "S0001" in blocker and "user_access/hw-s1" in blocker and "users/S0001" in blocker
    assert result.report["people"]["blockers"] == []
    text = json.dumps(result.report).lower()
    assert PASSWORD.lower() not in text and "passwordhash" not in text


def test_a_profile_that_names_a_uid_needs_an_account_too(db, auth, project):
    seed_world(db, auth)
    put(db, "users", "S0010", fork_profile({**PEOPLE["s1"], "uid": "hw-gone", "code": "S0010"}))
    result = run_readiness(db, auth, project)
    [blocker] = result.report["auth"]["blockers"]
    assert "S0010" in blocker and "users/S0010" in blocker


def test_email_difference_disabled_account_and_stray_account_are_notes(db, auth, project):
    seed_world(db, auth)
    auth.update_user("hw-s1", email="changed@example.test")
    auth.update_user("hw-s2", disabled=True)
    auth.create_user(uid="stray-1", email="stray@example.test", password=PASSWORD)
    result = run_readiness(db, auth, project)
    assert result.verdict == "ready"
    notes = " ".join(result.report["auth"]["notes"])
    assert "S0001" in notes and "email" in notes
    assert "S0002" in notes and "disabled" in notes
    assert result.report["auth"]["withoutRecord"] == 1


def test_facts_of_products_orders_live_tracking_and_config(db, auth, project):
    seed_world(db, auth)
    result = run_readiness(db, auth, project)
    assert result.report["products"] == {"total": 6, "orderable": 5, "hidden": 1, "withBarcode": 1,
                                         "withoutBarcode": 5, "withPriceMismatch": 1, "missingProductId": 1,
                                         "priceOnlyInOldField": 1}
    assert any("1 products have a price only" in note for note in result.report["notes"])
    assert result.report["orders"]["total"] == 2
    assert result.report["orders"]["withoutCapturedLinePrices"] == 1
    assert result.report["liveTracking"]["withoutUid"] == 1
    assert result.report["config"] == {"usage": False, "plan": False, "lifecycle": False}
    assert result.report["budget"]["counts"] == {"user_access": 4, "users": 4, "products": 6, "orders": 2,
                                                 "live_tracking": 2}
    migrate_seats.apply_migration(db, migrate_seats.plan_migration(db))
    assert run_readiness(db, auth, project).report["config"]["usage"] is True


def test_orders_without_a_salesman_code_are_counted_with_the_fix_command(db, auth, project):
    seed_world(db, auth)
    put(db, "orders", "fork1", {"status": "submitted", "salesmanUid": "hw-s1", "salesmanId": "STAFF-9"})
    put(db, "orders", "orphan", {"status": "submitted", "salesmanUid": "nobody"})
    put(db, "orders", "coded", {"status": "submitted", "salesmanUid": "hw-s1", "salesmanCode": "S0001"})
    result = run_readiness(db, auth, project)
    assert result.report["orders"]["withoutSalesmanCode"] == 4
    assert result.verdict == "ready"
    assert any("4 orders have no salesmanCode" in note and f"--project {project}" in note
               and "order_code_backfill" in note for note in result.report["notes"])


def test_readiness_changes_no_document(db, auth, project):
    seed_world(db, auth)
    add_shape(db, auth, "profileWithoutUid")
    before = fingerprint(db)
    reader = tenant_readiness.deployed_rules_reader(project, "(default)", session=FakeSession(RULES_OK))
    run_readiness(db, auth, project, rules_reader=reader, expected_rules="rules_version = '2';\n")
    assert fingerprint(db) == before


def test_module_sources_contain_no_write_call():
    forbidden = re.compile(r"\.set\(|\.update\(|\.delete\(|\.create\(|batch\(|transaction\(")
    for name in ("tenant_readiness.py", "tenant_inventory.py"):
        source = (Path(tenant_readiness.__file__).with_name(name)).read_text(encoding="utf-8")
        assert not forbidden.search(source), name


def test_too_small_a_budget_stops_before_any_stream(db, auth, project, monkeypatch):
    seed_world(db, auth)

    def streamed(*_args, **_kwargs):
        raise AssertionError("a stream was started")

    for name in ("prepare_report", "inventory", "plan_uid_backfill"):
        monkeypatch.setattr(tenant_readiness, name, streamed)
    with pytest.raises(tenant_readiness.ReadBudgetExceeded) as stopped:
        tenant_readiness.readiness(db, auth_client=auth, packages=[], budget=1, project=project)
    assert stopped.value.estimated > 1


def test_cli_exit_codes(db, auth, project, capsys, tmp_path):
    seed_world(db, auth)
    out = tmp_path / "report.json"
    assert tenant_readiness.main(["--project", project, "--out", str(out)]) == 0
    assert json.loads(out.read_text(encoding="utf-8"))["verdict"] == "ready"
    capsys.readouterr()

    assert tenant_readiness.main(["--project", project, "--max-reads", "1"]) == 2
    stopped = json.loads(capsys.readouterr().out)
    assert stopped["verdict"] == "not-run" and stopped["budget"]["maxReads"] == 1

    auth.delete_user("hw-s2")
    assert tenant_readiness.main(["--project", project]) == 1
    assert json.loads(capsys.readouterr().out)["verdict"] == "blocked"

    assert tenant_readiness.main(["--project", project, "--expect-rules", str(tmp_path / "missing.rules")]) == 3


RULES_OK = {
    "projects/P/releases/cloud.firestore": {"name": "projects/P/releases/cloud.firestore",
                                            "rulesetName": "projects/P/rulesets/r1",
                                            "updateTime": "2026-11-01T00:00:00Z"},
    "rulesets/r1": {"source": {"files": [{"name": "firestore.rules", "content": "rules_version = '2';\r\n"}]}},
}


class FakeResponse:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body

    def json(self):
        return self._body


class FakeSession:
    def __init__(self, bodies, status=200):
        self.bodies = bodies
        self.status = status
        self.urls = []

    def get(self, url):
        self.urls.append(url)
        if self.status != 200:
            return FakeResponse(self.status, {})
        key = "rulesets/r1" if "rulesets/" in url else "projects/P/releases/cloud.firestore"
        return FakeResponse(200, self.bodies[key])


def test_rules_are_compared_by_content_not_line_endings():
    session = FakeSession(RULES_OK)
    deployed = tenant_readiness.deployed_rules_reader("P", "(default)", session=session)()
    assert deployed.release == "projects/P/releases/cloud.firestore"
    assert session.urls[0].endswith("/projects/P/releases/cloud.firestore")
    same, _ = tenant_readiness.rules_check(lambda: deployed, "rules_version = '2';\n")
    other, _ = tenant_readiness.rules_check(lambda: deployed, "rules_version = '1';\n")
    assert same["matchesExpected"] is True and same["sha256"] == tenant_readiness.rules_sha256("rules_version = '2';\n")
    assert other["matchesExpected"] is False


def test_rules_without_permission_are_a_note_not_a_crash():
    reader = tenant_readiness.deployed_rules_reader("P", "(default)", session=FakeSession(RULES_OK, status=403))
    section, deployed = tenant_readiness.rules_check(reader, "x")
    assert deployed is None and section["checked"] is False and section["matchesExpected"] is None
    failing = tenant_readiness.deployed_rules_reader("P", "(default)", session=FakeSession(RULES_OK, status=500))
    with pytest.raises(tenant_readiness.RulesReadFailed):
        failing()


def test_named_database_uses_its_own_release():
    session = FakeSession(RULES_OK)
    tenant_readiness.deployed_rules_reader("P", "hardware", session=session)()
    assert session.urls[0].endswith("/releases/cloud.firestore/hardware")


def test_cli_saves_and_compares_rules(db, auth, project, monkeypatch, tmp_path, capsys):
    seed_world(db, auth)
    reader = tenant_readiness.deployed_rules_reader("P", "(default)", session=FakeSession(RULES_OK))
    monkeypatch.setattr(tenant_readiness, "deployed_rules_reader", lambda *_args, **_kwargs: reader)
    expected = tmp_path / "expected.rules"
    expected.write_text("rules_version = '2';\n", encoding="utf-8")
    saved = tmp_path / "saved.rules"
    assert tenant_readiness.main(["--project", project, "--expect-rules", str(expected),
                                  "--save-rules", str(saved)]) == 0
    assert json.loads(capsys.readouterr().out)["rules"]["matchesExpected"] is True
    assert saved.read_bytes() == b"rules_version = '2';\r\n"


def test_a_numeric_text_price_counts_as_a_catalogue_price():
    facts = tenant_readiness.product_facts([
        ("textPrice", {"productId": "A", "unitPrice": "12.50", "sellingPrice": 9}),
        ("oldOnly", {"productId": "B", "sellingPrice": 9}),
        ("wordPrice", {"productId": "C", "price": "ask", "sellingPrice": 9}),
    ])
    assert facts["priceOnlyInOldField"] == 2

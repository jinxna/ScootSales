from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import owner_decision_finders as finders
from platform_service.records import workspace_skeleton

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="needs the Firestore emulator"
)

OUT_DIR = ROOT / "e2e" / "output" / "owner_decision_finders"
NOW = datetime(2026, 11, 15, tzinfo=timezone.utc)
BAD_PAY = "pay_" + "a" * 64
GOOD_PAY = "pay_" + "b" * 64
VOID_PAY = "pay_" + "c" * 64


@pytest.fixture
def project(monkeypatch):
    name = f"demo-finders-{uuid.uuid4().hex[:8]}"
    monkeypatch.setattr(finders.config, "PLATFORM_PROJECT_ID", name)
    return name


@pytest.fixture
def db(project):
    client = firestore.Client(project=project, credentials=AnonymousCredentials())
    yield client
    client.close()


def company(db, tenant, project_id, status="active", workspace=None, code=None):
    db.collection("companies").document(tenant).set({
        "workspace": workspace or tenant, "companyCode": code or tenant.upper(), "status": status,
        "locationKey": f"{project_id}|(default)|-", "version": 1})


def snapshot(db):
    names = ["users", "companies", "company_claims", "quotes", "plans", "subscriptions", "plan_requests",
             "payment_entries", "payment_checks"]
    return {name: {row.id: row.to_dict() for row in db.collection(name).stream()} for name in names}


def run(project, finder, name, extra=()):
    out = OUT_DIR / f"{project}_{name}.json"
    code = finders.main([finder, "--project", project, "--confirm-project", project, "--out", str(out), *extra])
    assert code == 0
    return json.loads(out.read_text(encoding="utf-8"))


def test_generated_accounts_lists_only_generated_ones_and_writes_nothing(db, project):
    db.collection("users").document("bad1").set({"email": "e2e.sales@example.test", "role": "salesman"})
    db.collection("users").document("bad2").set({"email": "x@example.com", "salesman_code": "S-E2E", "companyId": "t1"})
    db.collection("users").document("U-E2E").set({"email": "real@kvd.test"})
    db.collection("users").document("good").set({"email": "ali@kvd.test", "role": "salesman"})
    before = snapshot(db)
    manifest = run(project, "generated-accounts", "accounts")
    assert [row["userId"] for row in manifest["result"]] == ["U-E2E", "bad1", "bad2"]
    assert manifest["readOnly"] is True and manifest["readsUsed"] == 4
    assert manifest["target"]["kind"] == "emulator" and manifest["collectionSizes"] == {"users": 4}
    assert manifest["result"][2]["companyId"] == "t1"
    assert snapshot(db) == before


def test_unchecked_payments_lists_only_the_waiting_one(db, project):
    old = NOW - timedelta(days=30)
    base = {"type": "payment", "tenantId": "t1", "invoiceId": "inv1", "amountMinor": 100, "createdAt": old}
    db.collection("payment_entries").document(BAD_PAY).set({**base, "entryId": BAD_PAY, "revision": 1})
    db.collection("payment_entries").document(GOOD_PAY).set({**base, "entryId": GOOD_PAY, "revision": 2})
    db.collection("payment_checks").document(GOOD_PAY).set({"checked": True})
    db.collection("payment_entries").document(VOID_PAY).set({**base, "entryId": VOID_PAY, "revision": 3})
    void_entry = "void_" + "d" * 64
    db.collection("payment_entries").document(void_entry).set(
        {"type": "void", "tenantId": "t1", "entryId": void_entry, "receiptId": VOID_PAY, "revision": 1})
    before = snapshot(db)
    manifest = run(project, "unchecked-payments", "payments")
    assert [row["entryId"] for row in manifest["result"]] == [BAD_PAY]
    assert snapshot(db) == before


def test_quotes_without_package_lists_only_the_bad_quotes(db, project):
    db.collection("plans").document("P1").set({"planId": "P1"})
    db.collection("plans").document("P2").set({"planId": "P2", "currentVersion": 1})
    db.collection("plans").document("P2").collection("versions").document("1").set(
        {"prices": {"monthly": None, "yearly": None}})
    db.collection("plans").document("P3").set({"planId": "P3", "currentVersion": 1})
    db.collection("plans").document("P3").collection("versions").document("1").set(
        {"prices": {"monthly": 100, "yearly": 960}})
    db.collection("subscriptions").document("t4").set({"planId": "P3", "billingInterval": "monthly"})
    db.collection("quotes").document("q_listed").set(
        {"status": "approved", "billingInterval": "monthly", "tenantId": "t4", "planId": "P1"})
    db.collection("subscriptions").document("t1").set({"planId": "P1", "billingInterval": "monthly"})
    db.collection("subscriptions").document("t2").set({"planId": "P2", "billingInterval": "monthly"})
    db.collection("subscriptions").document("t3").set({"planId": "P2", "billingInterval": "monthly"})
    quote = {"status": "approved", "billingInterval": "monthly"}
    db.collection("quotes").document("q_none").set({**quote, "tenantId": "t1", "planId": None})
    db.collection("quotes").document("q_missing").set({**quote, "tenantId": "t1", "planId": "GONE"})
    db.collection("quotes").document("q_good").set({**quote, "tenantId": "t1", "planId": "P1"})
    db.collection("quotes").document("q_old").set({**quote, "tenantId": "t2", "planId": "P1"})
    db.collection("quotes").document("q_old_but_current_exists").set({**quote, "tenantId": "t3", "planId": "P1"})
    db.collection("quotes").document("q_current").set({**quote, "tenantId": "t3", "planId": "P2"})
    db.collection("plan_requests").document("t1").set(
        {"tenantId": "t1", "status": "requested", "planId": "P2", "interval": "monthly", "createdAt": NOW})
    db.collection("plan_requests").document("t2").set(
        {"tenantId": "t2", "status": "requested", "planId": "P2", "interval": "monthly", "createdAt": NOW})
    before = snapshot(db)
    manifest = run(project, "quotes-without-package", "quotes")
    reasons = {row["quoteId"]: row["reasons"] for row in manifest["result"]["quotes"]}
    assert reasons == {"q_none": ["quote_has_no_package"], "q_missing": ["package_does_not_exist"],
                       "q_old": ["no_approved_quote_for_current_package"]}
    assert [row["requestId"] for row in manifest["result"]["openPackageRequests"]] == ["t1"]
    assert manifest["result"]["openPackageRequests"][0]["createdAt"]
    assert snapshot(db) == before


def test_shared_projects_lists_only_the_shared_project(db, project):
    company(db, "t_a", "proj-shared")
    company(db, "t_b", "proj-shared")
    company(db, "t_c", "proj-own")
    company(db, "t_d", "proj-shared", status="deleted")
    before = snapshot(db)
    manifest = run(project, "shared-projects", "shared")
    assert [row["projectId"] for row in manifest["result"]] == ["proj-shared"]
    assert [row["tenantId"] for row in manifest["result"][0]["companies"]] == ["t_a", "t_b"]
    assert snapshot(db) == before


def test_orphan_claims_lists_only_the_orphans(db, project):
    company(db, "t_live", "proj-live", workspace="live", code="LIVE")
    for claim in ("workspace:live", f"skeleton:{workspace_skeleton('live')}", "code:LIVE", "location:proj-live|(default)|-",
                  "auth:proj-live|-", "project:proj-live"):
        db.collection("company_claims").document(claim).set({"tenantId": "t_live"})
    company(db, "t_gone", "proj-old", status="deleted", workspace="gone", code="GONE")
    for claim in ("workspace:gone", f"skeleton:{workspace_skeleton('gone')}", "code:GONE", "project:proj-old"):
        db.collection("company_claims").document(claim).set({"tenantId": "t_gone"})
    db.collection("company_claims").document("project:proj-ghost").set({"tenantId": "t_missing"})
    before = snapshot(db)
    manifest = run(project, "orphan-claims", "claims")
    assert [row["claimId"] for row in manifest["result"]] == ["project:proj-ghost", "project:proj-old"]
    assert snapshot(db) == before


def test_read_cap_stops_without_a_manifest(db, project, capsys):
    for index in range(5):
        db.collection("users").document(f"u{index}").set({"email": "e2e.x@example.test"})
    out = OUT_DIR / f"{project}_cap.json"
    code = finders.main(["generated-accounts", "--project", project, "--confirm-project", project,
                         "--out", str(out), "--read-cap", "3"])
    assert code == 3 and not out.exists()


def test_generated_accounts_stops_when_users_is_empty(db, project):
    out = OUT_DIR / f"{project}_empty.json"
    code = finders.main(["generated-accounts", "--project", project, "--confirm-project", project, "--out", str(out)])
    assert code == 2 and not out.exists()


def test_central_finder_refuses_a_non_central_project_and_a_large_cap(project):
    out = OUT_DIR / "never.json"
    other = project + "-company"
    assert finders.main(["shared-projects", "--project", other, "--confirm-project", other, "--out", str(out)]) == 2
    assert finders.main(["shared-projects", "--project", project, "--confirm-project", project, "--out", str(out),
                         "--read-cap", "20001"]) == 2
    assert not out.exists()


def test_refuses_without_matching_confirmation_or_an_ignored_path(project):
    out = OUT_DIR / "never.json"
    assert finders.main(["shared-projects", "--project", project, "--confirm-project", "other", "--out", str(out)]) == 2
    assert finders.main(["shared-projects", "--project", project, "--confirm-project", project,
                         "--out", str(ROOT / "scripts" / "manifest.json")]) == 2
    assert not out.exists()

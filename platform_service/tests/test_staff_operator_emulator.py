from __future__ import annotations

import hashlib
import json
import os
import re
import urllib.error
import urllib.request
import time
import uuid
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from fastapi import HTTPException
from firebase_admin import auth as admin_auth
from firebase_admin import exceptions as firebase_exceptions
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import account_links, account_security, auth, company_access, config, lifecycle, staff, staff_api
from platform_service.company_access import platform_project_auth
from platform_service.mail import STAFF_MAIL_TENANT, DeliveryRejected, MailQueue, deliver_mail, mail_params
from platform_service.staff import allowed_domain, staff_id
from platform_service.audit import AuditLog
from platform_service.directory import DirectoryStore
from platform_service.ids import local_date
from platform_service.onboarding import OnboardingDrafts
from platform_service.tenant_readiness import DeployedRules, rules_sha256
from platform_service.operations import OperationStore
from platform_service.project_setup import ProjectSetup
from platform_service.plans import clean_subscription
from platform_service.scheduler import build_scheduler
from platform_service.signing import Keyring, Signer
from platform_service.subscriptions import ACTION_PLAN_PUT, ACTION_SUBSCRIPTION
from platform_service.tests.support import seed_catalogue, seed_subscription, staff_assertion, staff_domains

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"),
    reason="Needs the assigned shared Firestore emulator.",
)

OWNER = "owner@example.com"
OPERATOR = "operator@example.com"
SUPPORT = "support@example.com"
ENGINEER = "engineer@example.com"
UNMAPPED = "unmapped@example.com"
TENANT = "t_northwind"
USAGE = {"usageSchemaVersion": 2, "products": 0, "activeAdmins": 0,
         "seats": {"salesmen": 0, "supervisors": 0, "admins": 0, "branchManagers": 0}}


ROLES = {OWNER: "owner", OPERATOR: "operator", SUPPORT: "support", ENGINEER: "engineer"}


@pytest.fixture(autouse=True)
def staff_settings(monkeypatch):
    monkeypatch.setattr(config, "STAFF_DOMAINS", staff_domains({*ROLES, UNMAPPED}))


@pytest.fixture
def assertion():
    return staff_assertion(ROLES)


def _client_config(sender: str) -> dict:
    return {"apiKey": {"web": "AIza" + "B" * 35}, "appId": {"web": f"1:{sender}:web:cccccccccccccccc"},
            "messagingSenderId": sender}


def _setup(project: str) -> dict:
    return {"location": {"projectId": project, "databaseId": "(default)", "authTenantId": None},
            "locationKind": "managed", "clientConfig": _client_config("333333333333"),
            "rulesVersion": "r1", "releaseRing": "pilot"}


@pytest.fixture
def world(monkeypatch):
    project = f"demo-v4-operator-{uuid.uuid4().hex[:12]}"
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", project)
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    signer = Signer.generate("operator-api-test")
    store = DirectoryStore(db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    company_project = f"demo-northwind-{project[-8:]}"
    new_project = f"demo-newco-{project[-8:]}"
    store.put({
        "tenantId": TENANT, "workspace": "northwind", "legalName": "Northwind Foods Sdn Bhd",
        "companyCode": "northwind", "location": {"projectId": company_project, "databaseId": "(default)",
                                                  "authTenantId": None},
        "locationKind": "byo", "clientConfig": _client_config("222222222222"), "status": "active",
        "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1",
    }, expected_version=0)
    seed_catalogue(db)
    company_dbs = [firestore.Client(project=name, credentials=AnonymousCredentials())
                   for name in (company_project, new_project)]
    for company_db in company_dbs:
        company_db.collection("config").document("usage").set(USAGE)
    operations = OperationStore(db)
    release_rules = DeployedRules("release", "", rules_sha256(
        (staff_api.REPO_ROOT / "admin_dashboard" / "firestore.rules").read_text(encoding="utf-8")), "")
    app = TestClient(staff_api.create_app(store=store, operations=operations, signer=signer, client=db,
                                          rules_reader_for=lambda location: (lambda: release_rules),
                                          connect_web_config_reader=lambda project: _client_config("333333333333"),
                                          connect_rules_reader=lambda project, database: None))
    yield type("World", (), {"db": db, "app": app, "operations": operations, "new_project": new_project,
                             "store": store})
    app.close()

    def clear(collection):
        for document in collection.stream():
            for child in document.reference.collections():
                clear(child)
            document.reference.delete()
    for client in (db, *company_dbs):
        for collection in client.collections():
            clear(collection)
        client.close()


def headers(assertion, email=OWNER, key=None):
    result = assertion(email)
    if key is not None:
        result["Idempotency-Key"] = key
    return result


def ask(world, assertion, action, params, key, *, who=OPERATOR, tenant=TENANT, reason="Client asked for this"):
    body = {"action": action, "reason": reason, "params": params}
    if tenant is not None:
        body["tenantId"] = tenant
    return world.app.post("/staff/v1/approvals", json=body, headers=headers(assertion, who, key))


def decide(world, assertion, approval_id, who=OWNER, verb="approve"):
    return world.app.post(f"/staff/v1/approvals/{approval_id}/{verb}", headers=headers(assertion, who))


def package(plan_id, interval="monthly", expected=0):
    return {"planId": plan_id, "billingInterval": interval, "expectedRevision": expected,
            "reason": "Client asked for this package"}


READS = ["/staff/v1/today", "/staff/v1/plan-requests", "/staff/v1/packages",
         f"/staff/v1/companies/{TENANT}/packages", f"/staff/v1/companies/{TENANT}/operations"]


@pytest.mark.parametrize("path", READS)
def test_operator_reads_are_owner_or_operator_only(world, assertion, path):
    assert world.app.get(path, headers=headers(assertion, OWNER)).status_code == 200
    assert world.app.get(path, headers=headers(assertion, OPERATOR)).status_code == 200
    assert world.app.get(path, headers=headers(assertion, SUPPORT)).status_code == 403
    assert world.app.get(path, headers=headers(assertion, UNMAPPED)).status_code == 403
    assert world.app.get(path).status_code == 401
    assert world.app.get(path, headers={"Authorization": "Bearer firebase-only"}).status_code == 401


def audit_actions(world):
    return {row.to_dict()["action"] for row in world.db.collection("audit_events").stream()}


def draft_body(workspace="newco", **changes):
    return {"legalName": "New Co Trading", "tradingName": "New Co", "workspace": workspace,
            "planId": "STANDARD", "billingInterval": "monthly", "billingEmail": "billing@newco.example",
            "adminName": "Ada Admin", "adminEmail": "admin@newco.example", "adminEmployeeCode": "ADM001", **changes}


def start_draft(world, assertion, key, who=OPERATOR, **changes):
    return world.app.post("/staff/v1/onboarding-drafts", json=draft_body(**changes), headers=headers(assertion, who, key))


def complete(world, assertion, draft_id, key, who=ENGINEER):
    return complete_on(world, assertion, draft_id, key, world.new_project, who)


def test_clerk_starts_a_draft_and_only_the_owner_or_engineer_turns_it_into_a_company(world, assertion):
    assert start_draft(world, assertion, "draft-support-01", SUPPORT).status_code == 403
    assert start_draft(world, assertion, "draft-engineer-01", ENGINEER).status_code == 403
    assert world.app.post("/staff/v1/onboarding-drafts", json=draft_body(),
                          headers={"Idempotency-Key": "draft-anonymous-01"}).status_code == 401
    created = start_draft(world, assertion, "draft-operator-01")
    assert created.status_code == 201, created.text
    draft = created.json()
    assert draft["status"] == "open" and draft["tenantId"] is None and draft["total"] == 8
    assert [step["key"] for step in draft["steps"]] == [
        "details", "project", "people", "package", "payment", "admin", "rules", "open"]
    assert [step["state"] for step in draft["steps"]] == ["green", "red"] + ["grey"] * 6
    assert draft["doneCount"] == 1 and draft["next"]["key"] == "project"
    assert draft["next"]["button"]["id"] == "connect_project" and draft["phase"] == "setup"
    assert world.app.post("/staff/v1/companies", json=draft_body(), headers=headers(assertion, ENGINEER, "old-path-0001")
                          ).status_code in (404, 405)
    assert [row for row in world.db.collection("companies").stream() if "newco" in str(row.to_dict())] == []
    replay = start_draft(world, assertion, "draft-operator-01")
    assert replay.status_code == 201 and replay.json()["draftId"] == draft["draftId"]
    assert start_draft(world, assertion, "draft-operator-01", legalName="Other Co").status_code == 409

    setup_fields = world.app.put(f"/staff/v1/onboarding-drafts/{draft['draftId']}",
                                 json={"location": _setup(world.new_project)["location"]},
                                 headers=headers(assertion, OPERATOR))
    assert setup_fields.status_code == 400 and "engineer" in setup_fields.json()["detail"]
    assert start_draft(world, assertion, "draft-operator-02", setup=_setup(world.new_project)).status_code == 400
    for who in (OPERATOR, SUPPORT):
        assert complete(world, assertion, draft["draftId"], "complete-denied-01", who).status_code == 403, who

    finished = complete(world, assertion, draft["draftId"], "complete-owner-01", OWNER)
    assert finished.status_code == 200, finished.text
    result = finished.json()
    assert result["ok"] is True and result["refusal"] is None and result["retryLater"] is False
    view = world.app.get(f"/staff/v1/onboarding-drafts/{draft['draftId']}", headers=headers(assertion, OWNER)).json()
    assert view["status"] == "completed" and view["tenantId"] == result["tenantId"]
    company = world.db.collection("companies").document(result["tenantId"]).get().to_dict()
    assert company["billingEmail"] == "billing@newco.example" and company["onboardingDraftId"] == draft["draftId"]
    assert json.loads(company["payload"])["status"] == "lead"
    billing_events = [row.to_dict() for row in world.db.collection("audit_events").stream()
                      if row.to_dict()["action"] == "billing_email.changed"]
    assert len(billing_events) == 1 and billing_events[0]["actor"] == OWNER
    assert list(world.db.collection("onboarding_claims").stream()) == []
    again = complete(world, assertion, draft["draftId"], "complete-owner-01", OWNER)
    assert again.status_code == 200 and again.json()["tenantId"] == result["tenantId"]
    repeated = complete(world, assertion, draft["draftId"], "complete-engineer-02")
    assert repeated.status_code == 200, repeated.text
    assert repeated.json()["ok"] is True and repeated.json()["tenantId"] == result["tenantId"]
    assert len([row for row in world.db.collection("companies").stream()
                if row.to_dict().get("workspace") == "newco"]) == 1
    assert len([row for row in world.db.collection("audit_events").stream()
                if row.to_dict()["action"] == "billing_email.changed"]) == 1
    assert start_draft(world, assertion, "draft-operator-03").status_code == 409
    assert {"onboarding.created", "onboarding.completed"} <= audit_actions(world)


def test_after_connect_only_the_administrator_and_trading_name_can_change(world, assertion):
    draft = start_draft(world, assertion, "draft-after-0001", workspace="afterco").json()["draftId"]
    assert complete(world, assertion, draft, "complete-after-0001").status_code == 200
    path = f"/staff/v1/onboarding-drafts/{draft}"
    changed = world.app.put(path, json={"adminEmployeeCode": "ADM777", "adminName": "Bea Admin"},
                            headers=headers(assertion, OPERATOR))
    assert changed.status_code == 200, changed.text
    assert changed.json()["adminEmployeeCode"] == "ADM777" and changed.json()["adminName"] == "Bea Admin"
    assert changed.json()["steps"][0]["state"] == "green"
    refused = world.app.put(path, json={"legalName": "Other Name Sdn Bhd"}, headers=headers(assertion, OPERATOR))
    assert refused.status_code == 409
    assert refused.json()["detail"] == "The project is connected. Only the administrator and trading name can change now."
    assert world.app.get(path, headers=headers(assertion, OWNER)).json()["legalName"] == "New Co Trading"


def complete_on(world, assertion, draft_id, key, project, who=ENGINEER):
    return world.app.post(f"/staff/v1/onboarding-drafts/{draft_id}/connect",
                          json={"projectId": project}, headers=headers(assertion, who, key))


def test_c241_a_second_company_cannot_be_created_on_a_firebase_project_another_company_uses(world, assertion):
    first = start_draft(world, assertion, "draft-c241-0001", workspace="firstco").json()["draftId"]
    done = complete_on(world, assertion, first, "complete-c241-0001", world.new_project)
    assert done.status_code == 200, done.text
    first_tenant = done.json()["tenantId"]
    claim = world.db.collection("company_claims").document(f"project:{world.new_project}").get()
    assert claim.exists and claim.to_dict()["tenantId"] == first_tenant

    second = start_draft(world, assertion, "draft-c241-0002", workspace="secondco").json()["draftId"]
    refused = complete_on(world, assertion, second, "complete-c241-0002", world.new_project)
    assert refused.status_code == 409
    assert "Another company already uses this Firebase project" in refused.json()["refusal"]
    assert "Create a new Firebase project" in refused.json()["refusal"]
    assert world.db.collection("onboarding_drafts").document(second).get().to_dict()["status"] == "open"
    assert [row for row in world.db.collection("companies").stream() if "secondco" in str(row.to_dict())] == []
    other_project = f"demo-secondco-{world.new_project[-8:]}"
    assert complete_on(world, assertion, second, "complete-c241-0003", other_project).status_code == 200




def test_a_company_cannot_be_set_up_on_the_control_centre_firebase_project(world, assertion):
    first = start_draft(world, assertion, "draft-plat-0001", workspace="platco").json()["draftId"]
    refused = complete_on(world, assertion, first, "complete-plat-0001", config.PLATFORM_PROJECT_ID)
    assert refused.status_code == 400
    assert refused.json()["detail"] == (
        "This Firebase project belongs to the Control Centre. Choose the company's own Firebase project.")
    assert [row for row in world.db.collection("companies").stream() if "platco" in str(row.to_dict())] == []
    assert world.db.collection("company_claims").document(f"project:{config.PLATFORM_PROJECT_ID}").get().exists is False
    assert world.db.collection("onboarding_drafts").document(first).get().to_dict()["status"] == "open"
    own = f"demo-platco-{world.new_project[-8:]}"
    assert complete_on(world, assertion, first, "complete-plat-0002", own).status_code == 200
    second = start_draft(world, assertion, "draft-plat-0002", workspace="otherco").json()["draftId"]
    assert complete_on(world, assertion, second, "complete-plat-0003", world.new_project).status_code == 200


def test_c241_two_companies_completed_at_the_same_moment_cannot_both_take_one_project(world, assertion):
    from concurrent.futures import ThreadPoolExecutor
    drafts = [start_draft(world, assertion, f"draft-c241-race{n}", workspace=f"raceco{n}").json()["draftId"]
              for n in (1, 2)]
    project = f"demo-race-{world.new_project[-8:]}"
    def press_until_settled(pair):
        reply = complete_on(world, assertion, pair[1], f"complete-c241-race{pair[0]}", project)
        for _ in range(5):
            if reply.status_code != 202:
                break
            reply = complete_on(world, assertion, pair[1], f"complete-c241-race{pair[0]}", project)
        return reply

    with ThreadPoolExecutor(max_workers=2) as pool:
        replies = list(pool.map(press_until_settled, enumerate(drafts, start=1)))
    assert sorted(reply.status_code for reply in replies) == [200, 409], [reply.text for reply in replies]
    refused = next(reply for reply in replies if reply.status_code == 409)
    assert "Another company already uses this Firebase project" in refused.json()["refusal"]
    holders = {row.to_dict()["tenantId"] for row in world.db.collection("company_claims").stream()
               if row.id == f"project:{project}"}
    assert len(holders) == 1










def plant_checked_payment(world, tenant):
    start = datetime.now(timezone.utc) - timedelta(days=1)
    entry = "pay_" + hashlib.sha256(tenant.encode()).hexdigest()
    world.db.collection("payment_entries").document(entry).set({
        "entryId": entry, "tenantId": tenant, "type": "payment", "revision": 1, "periodStart": start,
        "periodEnd": start + timedelta(days=30), "createdAt": start, "graceEnd": start + timedelta(days=7)})
    world.db.collection("payment_checks").document(entry).set({"tenantId": tenant, "checkedBy": "checker@example.com"})










def test_plan_requests_come_newest_first_in_pages_and_today_counts_every_open_one(world, assertion):
    first = datetime(2026, 11, 1, tzinfo=timezone.utc)
    tenants = ["req_pagereq00", "req_pagereq01", *(f"t_pagereq{number:02d}" for number in range(2, 5))]
    for number, tenant in enumerate(tenants):
        world.db.collection("plan_requests").document(tenant).set({
            "tenantId": tenant, "planId": "STANDARD", "interval": "monthly", "requestKey": f"key-{number}",
            "status": "declined" if number == 0 else "requested", "requestedBy": "uid-1",
            "createdAt": first + timedelta(hours=number // 2)})
    pages = []
    after = None
    while True:
        query = "?limit=2" + (f"&after={after}" if after else "")
        page = world.app.get(f"/staff/v1/plan-requests{query}", headers=headers(assertion, OPERATOR))
        assert page.status_code == 200, page.text
        pages.append(page.json()["requests"])
        after = page.json()["nextAfter"]
        if after is None:
            break
        assert len(pages) < 5
    assert [len(page) for page in pages] == [2, 2, 1]
    rows = [row for page in pages for row in page]
    assert sorted(row["requestId"] for row in rows) == tenants
    assert rows[0]["requestId"] == tenants[4] and rows[-1]["requestId"] in tenants[:2]
    created = [row["createdAt"] for row in rows]
    assert created == sorted(created, reverse=True)
    assert [row["open"] for row in rows].count(True) == 4
    whole = world.app.get("/staff/v1/plan-requests", headers=headers(assertion, OPERATOR)).json()
    assert [row["requestId"] for row in whole["requests"]] == [row["requestId"] for row in rows]
    assert whole["nextAfter"] is None
    for wrong in ("t_nosuchrequest", "a%2Fb"):
        unknown = world.app.get(f"/staff/v1/plan-requests?after={wrong}", headers=headers(assertion, OPERATOR))
        assert unknown.status_code == 400, unknown.text
    assert world.app.get("/staff/v1/plan-requests?limit=0", headers=headers(assertion, OPERATOR)).status_code == 400
    today = world.app.get("/staff/v1/today", headers=headers(assertion, OPERATOR))
    assert today.status_code == 200, today.text
    assert today.json()["planRequests"] == {"open": 4}


def test_package_change_is_upgrade_only_and_support_cannot(world, assertion):
    path = f"/staff/v1/companies/{TENANT}/package"
    denied = world.app.post(path, json=package("STANDARD"), headers=headers(assertion, SUPPORT, "package-support-01"))
    assert denied.status_code == 403
    first = world.app.post(path, json=package("STANDARD"), headers=headers(assertion, OPERATOR, "package-operator-01"))
    assert first.status_code == 200 and first.json()["status"] == "completed", first.text
    listing = world.app.get(f"/staff/v1/companies/{TENANT}/packages", headers=headers(assertion, OPERATOR)).json()
    allowed = {row["planId"]: row["canRequest"] for row in listing["packages"]}
    assert allowed["STARTER"] is False and allowed["PROFESSIONAL"] is True
    lower = world.app.post(path, json=package("STARTER", expected=1), headers=headers(assertion, OPERATOR, "package-operator-02"))
    assert lower.status_code == 409
    assert world.db.collection("subscriptions").document(TENANT).get().to_dict()["planId"] == "STANDARD"








def test_billing_email_changes_only_through_a_second_person(world, assertion):
    path = f"/staff/v1/companies/{TENANT}/billing-email"
    row = lambda: next(item for item in world.app.get("/staff/v1/companies", headers=headers(assertion)).json()["companies"]
                       if item["tenantId"] == TENANT)
    assert row()["billingEmail"] is None
    for email in (OWNER, OPERATOR):
        direct = world.app.put(path, json={"billingEmail": "ap@northwind.example"}, headers=headers(assertion, email))
        assert direct.status_code == 409 and direct.json()["approvalAction"] == "billing_email.change"
    for email in (SUPPORT, UNMAPPED):
        assert world.app.put(path, json={"billingEmail": "ap@northwind.example"},
                             headers=headers(assertion, email)).status_code == 403
    assert world.app.put(path, json={"billingEmail": "ap@northwind.example"}).status_code == 401
    assert "billingEmail" not in world.db.collection("companies").document(TENANT).get().to_dict()
    asked = ask(world, assertion, "billing_email.change", {"billingEmail": " AP@Northwind.example "}, "email-set-001",
                reason="The client moved accounts payable")
    assert asked.status_code == 201, asked.text
    assert decide(world, assertion, asked.json()["approvalId"], OPERATOR).status_code == 409
    done = decide(world, assertion, asked.json()["approvalId"], OWNER)
    assert done.status_code == 200 and done.json()["operation"]["status"] == "completed", done.text
    assert row()["billingEmail"] == "ap@northwind.example"
    assert world.app.get("/staff/v1/companies", headers=headers(assertion, OPERATOR)).json()["companies"][0]["billingEmail"]
    reply = world.app.get("/v1/companies/northwind")
    assert reply.status_code == 200 and "billingEmail" not in reply.text
    assert "billingEmail" not in world.store.get(TENANT)
    clearing = ask(world, assertion, "billing_email.change", {"billingEmail": None}, "email-clear-001", who=OWNER,
                   reason="The client has no accounts payable inbox")
    assert decide(world, assertion, clearing.json()["approvalId"], OPERATOR).status_code == 200
    assert row()["billingEmail"] is None









CENTRAL_PASSWORD = "central-pass-12345"
FOUNDER = "founder@founder.test"
CLERK = "clerk@scoot.test"
FINANCE = "finance@scoot.test"
MISSING_STAFF_ID = "stf_" + "0" * 24


class FakeMail:
    def __init__(self):
        self.sent = []
        self.fail = None

    def send(self, message, idempotency_key):
        if self.fail is not None:
            raise self.fail
        self.sent.append(dict(message))
        return f"fake-{len(self.sent)}"

    def to(self, address):
        return [message for message in self.sent if message["to"] == address]


def auth_call(method, path, body=None):
    request = urllib.request.Request(
        f"http://{os.environ['FIREBASE_AUTH_EMULATOR_HOST']}{path}",
        data=None if body is None else json.dumps(body).encode(), method=method,
        headers={"Content-Type": "application/json", "Authorization": "Bearer owner"})
    return json.loads(urllib.request.urlopen(request).read().decode() or "{}")


def add_user(project, email, password=CENTRAL_PASSWORD):
    auth_call("POST", f"/identitytoolkit.googleapis.com/v1/projects/{project}/accounts",
              {"email": email, "password": password, "emailVerified": True})


def central_token(project, email, password=CENTRAL_PASSWORD):
    return auth_call("POST", "/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake",
                     {"targetProjectId": project, "email": email, "password": password,
                      "returnSecureToken": True})["idToken"]


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def wrong_code(code):
    return f"{(int(code) + 1) % 10 ** 6:06d}"


@pytest.fixture
def secure(monkeypatch):
    project = f"demo-v4-signin-{uuid.uuid4().hex[:12]}"
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", project)
    monkeypatch.setattr(config, "STAFF_DOMAINS", frozenset({"scoot.test"}))
    monkeypatch.setattr(config, "STAFF_BOOTSTRAP_OWNERS", frozenset({FOUNDER}))
    monkeypatch.setattr(config, "STAFF_URL", "https://control.scoot.test")
    monkeypatch.setattr(config, "FINANCE_EMAIL", FINANCE)
    monkeypatch.setattr(config, "MAIL_DAILY_SOFT_CAP", 2)
    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    signer = Signer.generate("signin-test")
    store = DirectoryStore(db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    mail = FakeMail()
    app = TestClient(staff_api.create_app(store=store, operations=OperationStore(db), signer=signer, client=db,
                                          mail_transport=lambda: mail))
    world = type("Secure", (), {"db": db, "app": app, "project": project, "mail": mail})
    add_user(project, FOUNDER)
    yield world
    app.close()
    for collection in db.collections():
        for document in collection.stream():
            document.reference.delete()
    db.close()
    auth_call("DELETE", f"/emulator/v1/projects/{project}/accounts")


def deliver(world, queue=None):
    return deliver_mail(queue or MailQueue(world.db, enabled=True), transport=world.mail)


def retoken(token, **changes):
    claims = jwt.decode(token, options={"verify_signature": False})
    claims.update(changes)
    return jwt.encode(claims, None, algorithm="none")


def sign_in(world, email, *, device="device-a", remember=False):
    token = central_token(world.project, email)
    uid = jwt.decode(token, options={"verify_signature": False})["sub"]
    gate = world.db.collection("staff_login_codes").document(uid)
    if gate.get().exists:
        gate.update({"requestedAt": firestore.DELETE_FIELD, "windowCount": 0})
    extra = {} if device is None else {"X-Staff-Device": device}
    sent = world.app.post("/staff/v1/session/code", headers={**bearer(token), **extra})
    assert sent.status_code == 200, sent.text
    code = re.findall(r"sign-in code is (\d{6})", world.mail.to(email)[-1]["text"])[0]
    done = world.app.post("/staff/v1/session/verify", json={"code": code, **({"remember": True} if remember else {})},
                          headers={**bearer(token), **extra})
    assert done.status_code == 201, done.text
    signed = {**bearer(token), "X-Staff-Session": done.json()["sessionId"], **extra}
    if not remember:
        assert "deviceToken" not in done.json()
        return signed
    return signed, done.json()["deviceToken"]


def trusted(world, email, device_token, *, device="device-a", token=None, password=CENTRAL_PASSWORD):
    return world.app.post("/staff/v1/session/trusted", json={"deviceToken": device_token}, headers={
        **bearer(token or central_token(world.project, email, password)), "X-Staff-Device": device})


def remembered(world):
    return [snapshot.to_dict() for snapshot in world.db.collection("staff_trusted_devices").stream()]


def run_password_watch(world):
    watch_signer = Signer.generate("watch-test")
    store = DirectoryStore(world.db, keyring=Keyring({watch_signer.key_id: watch_signer.public_key()}))
    account_security.watch_passwords(world.db, MailQueue(world.db, enabled=False), directory=store,
                                     access_for=lambda location: None, staff_auth=platform_project_auth)


def onboard(world, owner, email, role, name="Clerk One"):
    invited = world.app.post("/staff/v1/staff", json={"email": email, "name": name, "role": role}, headers=owner)
    assert invited.status_code == 201, invited.text
    deliver(world)
    token = re.findall(r"staffInvite=(stf_[0-9a-f]{24}\.[\w-]+)", world.mail.to(email)[-1]["text"])[0]
    accepted = world.app.post("/staff/v1/invite/accept", json={"token": token, "password": CENTRAL_PASSWORD})
    assert accepted.status_code == 201, accepted.text
    return invited.json()["staffId"]


def notice_texts(world, address):
    return [message["text"] for message in world.mail.to(address) if "security notice" in message["subject"]]




def test_wrong_codes_lock_sign_in_and_the_owner_is_told(secure):
    owner = sign_in(secure, FOUNDER)
    onboard(secure, owner, CLERK, "operator")
    token = central_token(secure.project, CLERK)
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 200
    code = re.findall(r"sign-in code is (\d{6})", secure.mail.to(CLERK)[-1]["text"])[0]
    verify = lambda value: secure.app.post("/staff/v1/session/verify", json={"code": value}, headers=bearer(token))
    for left in (4, 3, 2, 1):
        refused = verify(wrong_code(code))
        assert refused.status_code == 401 and f"{left} tries left" in refused.json()["detail"]
    locked = verify(wrong_code(code))
    assert locked.status_code == 429 and "locked" in locked.json()["detail"]
    assert "(Kuala Lumpur time, UTC+8)" in locked.json()["detail"] and "Z." not in locked.json()["detail"]
    assert verify(code).status_code == 429
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 429
    deliver(secure)
    for address in (FOUNDER, FINANCE):
        assert any("locked" in text and CLERK in text for text in notice_texts(secure, address)), address
    assert not any("locked" in text for text in notice_texts(secure, CLERK))
    assert "staff.locked" in audit_actions(secure)

    uid = jwt.decode(token, options={"verify_signature": False})["sub"]
    secure.db.collection("staff_login_codes").document(uid).update(
        {"lockedUntil": "2020-01-01T00:00:00Z", "requestedAt": firestore.DELETE_FIELD})
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 200
    fresh = re.findall(r"sign-in code is (\d{6})", secure.mail.to(CLERK)[-1]["text"])[0]
    assert verify(fresh).status_code == 201


def test_a_sign_in_code_works_once_and_not_after_it_expires(secure):
    sign_in(secure, FOUNDER)
    token = central_token(secure.project, FOUNDER)
    uid = jwt.decode(token, options={"verify_signature": False})["sub"]
    gate = secure.db.collection("staff_login_codes").document(uid)
    gate.update({"requestedAt": firestore.DELETE_FIELD})
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 200
    code = re.findall(r"sign-in code is (\d{6})", secure.mail.to(FOUNDER)[-1]["text"])[0]
    assert secure.app.post("/staff/v1/session/verify", json={"code": code}, headers=bearer(token)).status_code == 201
    again = secure.app.post("/staff/v1/session/verify", json={"code": code}, headers=bearer(token))
    assert again.status_code == 401
    gate.update({"requestedAt": firestore.DELETE_FIELD})
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 200
    code = re.findall(r"sign-in code is (\d{6})", secure.mail.to(FOUNDER)[-1]["text"])[0]
    gate.update({"expiresAt": "2020-01-01T00:00:00Z"})
    assert secure.app.post("/staff/v1/session/verify", json={"code": code}, headers=bearer(token)).status_code == 401
    too_soon = secure.app.post("/staff/v1/session/code", headers=bearer(token))
    assert too_soon.status_code == 429 and "Wait" in too_soon.json()["detail"]
    for text in ("12345", "abcdef", ""):
        assert secure.app.post("/staff/v1/session/verify", json={"code": text}, headers=bearer(token)).status_code == 400
    assert secure.app.post("/staff/v1/session/verify", json={}, headers=bearer(token)).status_code == 400






def test_fix054_the_only_owner_signs_in_with_a_one_time_backup_code_when_mail_is_down(secure):
    owner = sign_in(secure, FOUNDER)
    codes = secure.app.post("/staff/v1/backup-codes", headers=owner).json()["codes"]
    assert len(codes) == 10
    token = central_token(secure.project, FOUNDER)
    uid = jwt.decode(token, options={"verify_signature": False})["sub"]
    secure.db.collection("staff_login_codes").document(uid).update({"requestedAt": firestore.DELETE_FIELD, "windowCount": 0})
    secure.mail.fail = RuntimeError("mail provider is down")
    down = secure.app.post("/staff/v1/session/code", headers={**bearer(token), "X-Staff-Device": "device-b"})
    assert down.status_code == 503 and "backup code" in down.json()["detail"]
    done = secure.app.post("/staff/v1/session/verify", json={"backupCode": codes[0]},
                           headers={**bearer(token), "X-Staff-Device": "device-b"})
    assert done.status_code == 201 and done.json()["usedBackupCode"] is True and done.json()["backupCodesLeft"] == 9
    again = secure.app.post("/staff/v1/session/verify", json={"backupCode": codes[0]},
                            headers={**bearer(token), "X-Staff-Device": "device-b"})
    assert again.status_code == 401


def _locked_by_wrong_mailed_codes(secure, token):
    verify = lambda body: secure.app.post("/staff/v1/session/verify", json=body, headers=bearer(token))
    uid = jwt.decode(token, options={"verify_signature": False})["sub"]
    secure.db.collection("staff_login_codes").document(uid).update(
        {"requestedAt": firestore.DELETE_FIELD, "windowCount": 0})
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 200
    code = re.findall(r"sign-in code is (\d{6})", secure.mail.to(FOUNDER)[-1]["text"])[0]
    for _ in range(4):
        assert verify({"code": wrong_code(code)}).status_code == 401
    assert verify({"code": wrong_code(code)}).status_code == 429
    return verify, code


def test_fix272_wrong_codes_from_a_password_only_person_do_not_lock_out_a_real_backup_code(secure):
    owner = sign_in(secure, FOUNDER)
    codes = secure.app.post("/staff/v1/backup-codes", headers=owner).json()["codes"]
    stranger = central_token(secure.project, FOUNDER)
    verify, code = _locked_by_wrong_mailed_codes(secure, stranger)
    assert verify({"code": code}).status_code == 429
    assert secure.app.post("/staff/v1/session/code", headers=bearer(stranger)).status_code == 429
    for _ in range(4):
        assert verify({"backupCode": "abcd-2345-wxyz"}).status_code == 401
    assert verify({"backupCode": "abcd-2345-wxyz"}).status_code == 429
    assert verify({"backupCode": "abcd-2345-wxyz"}).status_code == 429
    done = verify({"backupCode": codes[0]})
    assert done.status_code == 201 and done.json()["usedBackupCode"] is True
    assert secure.app.post("/staff/v1/session/code", headers={**bearer(stranger), "X-Staff-Device": "x"}).status_code in (200, 429)
    uid = jwt.decode(stranger, options={"verify_signature": False})["sub"]
    state = secure.db.collection("staff_login_codes").document(uid).get().to_dict()
    assert not state.get("lockedUntil") and not state.get("backupLockedUntil")


def test_fix272_a_backup_lock_does_not_stop_the_mailed_code_lock_from_being_set(secure):
    sign_in(secure, FOUNDER)
    stranger = central_token(secure.project, FOUNDER)
    uid = jwt.decode(stranger, options={"verify_signature": False})["sub"]
    codes = secure.db.collection("staff_login_codes").document(uid)
    codes.update({"requestedAt": firestore.DELETE_FIELD, "windowCount": 0})
    assert secure.app.post("/staff/v1/session/code", headers=bearer(stranger)).status_code == 200
    code = re.findall(r"sign-in code is (\d{6})", secure.mail.to(FOUNDER)[-1]["text"])[0]
    verify = lambda body: secure.app.post("/staff/v1/session/verify", json=body, headers=bearer(stranger))
    for _ in range(4):
        assert verify({"backupCode": "abcd-2345-wxyz"}).status_code == 401
    assert verify({"backupCode": "abcd-2345-wxyz"}).status_code == 429
    for _ in range(4):
        assert verify({"code": wrong_code(code)}).status_code == 401
    assert verify({"code": wrong_code(code)}).status_code == 429
    assert verify({"code": code}).status_code == 429
    state = codes.get().to_dict()
    assert state["lockedUntil"] and state["backupLockedUntil"]


def test_fix273_a_password_step_made_before_a_password_reset_cannot_finish_sign_in_after_it(secure):
    owner = sign_in(secure, FOUNDER)
    codes = secure.app.post("/staff/v1/backup-codes", headers=owner).json()["codes"]
    stolen = central_token(secure.project, FOUNDER)
    claims = jwt.decode(stolen, options={"verify_signature": False})
    stolen = retoken(stolen, auth_time=int(time.time()) - 30)
    platform_project_auth().update_user(claims["sub"], password="second-password-2")
    refused = secure.app.post("/staff/v1/session/verify", json={"backupCode": codes[0]}, headers=bearer(stolen))
    assert refused.status_code == 401 and "password" in refused.json()["detail"]
    assert secure.app.post("/staff/v1/session/code", headers=bearer(stolen)).status_code == 401
    fresh = central_token(secure.project, FOUNDER, "second-password-2")
    done = secure.app.post("/staff/v1/session/verify", json={"backupCode": codes[0]}, headers=bearer(fresh))
    assert done.status_code == 201, done.text


def test_fix274_the_first_password_reset_for_a_person_the_watch_never_saw_ends_their_sessions(secure):
    owner = sign_in(secure, FOUNDER)
    uid = jwt.decode(central_token(secure.project, FOUNDER), options={"verify_signature": False})["sub"]
    time.sleep(1.1)
    platform_project_auth().update_user(uid, password="second-password-2")
    run_password_watch(secure)
    assert secure.app.get("/staff/v1/me", headers=owner).status_code == 401


def test_a_remembered_device_signs_in_with_the_password_alone_and_sends_no_mail(secure):
    sign_in(secure, FOUNDER)
    assert remembered(secure) == []
    _, device_token = sign_in(secure, FOUNDER, remember=True)
    records = remembered(secure)
    assert len(records) == 1 and device_token.split(".")[1] not in json.dumps(records)
    assert parse_days(records[0]["createdAt"], records[0]["expiresAt"]) == 30
    deliver(secure)
    mail_before = len(secure.mail.sent)
    queued_before = len(secure.db.collection("mail_jobs").get())
    done = trusted(secure, FOUNDER, device_token)
    assert done.status_code == 201, done.text
    body = done.json()
    assert body["usedBackupCode"] is False and body["role"] == "owner" and "deviceToken" not in body
    session = {**bearer(central_token(secure.project, FOUNDER)), "X-Staff-Session": body["sessionId"]}
    assert secure.app.get("/staff/v1/me", headers=session).status_code == 200
    deliver(secure)
    assert len(secure.mail.sent) == mail_before
    assert len(secure.db.collection("mail_jobs").get()) == queued_before
    uid = jwt.decode(session["Authorization"].split()[1], options={"verify_signature": False})["sub"]
    state = secure.db.collection("staff_login_codes").document(uid).get().to_dict()
    assert state.get("failures", 0) == 0 and "lockedUntil" not in state
    _, second = sign_in(secure, FOUNDER, remember=True)
    assert len(remembered(secure)) == 1
    assert trusted(secure, FOUNDER, device_token).status_code == 401
    assert trusted(secure, FOUNDER, second).status_code == 201


def parse_days(start, end):
    return (datetime.fromisoformat(end.replace("Z", "+00:00")) - datetime.fromisoformat(start.replace("Z", "+00:00"))).days


def test_a_remembered_device_is_refused_when_any_part_does_not_match_and_wrong_tries_are_limited(secure):
    owner, device_token = sign_in(secure, FOUNDER, remember=True)
    onboard(secure, owner, CLERK, "operator")
    uid = jwt.decode(owner["Authorization"].split()[1], options={"verify_signature": False})["sub"]
    gate = secure.db.collection("staff_login_codes").document(uid)
    stale = retoken(central_token(secure.project, FOUNDER), auth_time=int(time.time()) - 601)
    refused = trusted(secure, FOUNDER, device_token, token=stale)
    assert refused.status_code == 401 and "password" in refused.json()["detail"]
    assert trusted(secure, FOUNDER, "not-a-token").status_code == 401
    assert gate.get().to_dict()["trustedFailures"] == 0
    handle, secret = device_token.split(".")
    wrong = trusted(secure, FOUNDER, f"{handle}.{secret[:-1]}{'A' if secret[-1] != 'A' else 'B'}")
    assert wrong.status_code == 401 and wrong.json()["detail"] == "Enter the emailed code."
    assert trusted(secure, FOUNDER, device_token, device="device-b").status_code == 401
    assert trusted(secure, CLERK, device_token).status_code == 401
    record = secure.db.collection("staff_trusted_devices").document(handle)
    expires = record.get().to_dict()["expiresAt"]
    record.update({"expiresAt": "2020-01-01T00:00:00Z"})
    assert trusted(secure, FOUNDER, device_token).status_code == 401
    record.update({"expiresAt": expires})
    state = gate.get().to_dict()
    assert state["trustedFailures"] == 3 and state.get("failures", 0) == 0 and "lockedUntil" not in state
    assert trusted(secure, FOUNDER, device_token).status_code == 201
    assert gate.get().to_dict()["trustedFailures"] == 0
    deliver(secure)
    mail_before = len(secure.mail.sent)
    for _ in range(5):
        assert trusted(secure, FOUNDER, f"{'0' * 32}.{secret}").status_code == 401
    assert gate.get().to_dict()["trustedLockedUntil"] > "2026"
    assert trusted(secure, FOUNDER, device_token).status_code == 401
    deliver(secure)
    assert len(secure.mail.sent) == mail_before
    sign_in(secure, FOUNDER)
    assert trusted(secure, FOUNDER, device_token).status_code == 201


def test_sign_out_keeps_a_remembered_device_and_sign_out_of_all_devices_forgets_it(secure):
    owner, device_token = sign_in(secure, FOUNDER, remember=True)
    assert secure.app.delete("/staff/v1/sessions/current", headers=owner).status_code == 200
    assert secure.app.get("/staff/v1/me", headers=owner).status_code == 401
    again = trusted(secure, FOUNDER, device_token)
    assert again.status_code == 201, again.text
    owner["X-Staff-Session"] = again.json()["sessionId"]
    assert secure.app.post("/staff/v1/sessions/sign-out-all", headers=owner).status_code == 200
    assert remembered(secure) == []
    assert trusted(secure, FOUNDER, device_token).status_code == 401


def test_a_password_reset_forgets_remembered_devices_at_once_and_the_watch_removes_them(secure):
    owner, device_token = sign_in(secure, FOUNDER, remember=True)
    uid = jwt.decode(owner["Authorization"].split()[1], options={"verify_signature": False})["sub"]
    time.sleep(1.1)
    platform_project_auth().update_user(uid, password="second-password-2")
    assert len(remembered(secure)) == 1
    assert trusted(secure, FOUNDER, device_token, password="second-password-2").status_code == 401
    run_password_watch(secure)
    assert remembered(secure) == []
    assert trusted(secure, FOUNDER, device_token, password="second-password-2").status_code == 401


def test_a_disabled_person_loses_access_at_once(secure):
    owner = sign_in(secure, FOUNDER)
    identifier = onboard(secure, owner, CLERK, "operator")
    clerk, _ = sign_in(secure, CLERK, remember=True)
    assert len(remembered(secure)) == 1
    assert secure.app.get("/staff/v1/onboarding-drafts", headers=clerk).status_code == 200
    assert secure.app.post("/staff/v1/backup-codes", headers=clerk).status_code == 201
    clerk_uid = jwt.decode(clerk["Authorization"].split()[1], options={"verify_signature": False})["sub"]
    assert secure.db.collection("staff_backup_codes").document(identifier).get().exists
    assert secure.db.collection("staff_login_codes").document(clerk_uid).get().exists
    assert secure.app.post(f"/staff/v1/staff/{identifier}/disable", headers=clerk).status_code == 403
    disabled = secure.app.post(f"/staff/v1/staff/{identifier}/disable", headers=owner)
    assert disabled.status_code == 200 and disabled.json()["status"] == "disabled"
    assert not secure.db.collection("staff_backup_codes").document(identifier).get().exists
    assert not secure.db.collection("staff_login_codes").document(clerk_uid).get().exists
    assert remembered(secure) == []
    assert secure.app.get("/staff/v1/onboarding-drafts", headers=clerk).status_code in (401, 403)
    assert secure.app.get("/staff/v1/me", headers=clerk).status_code in (401, 403)
    assert platform_project_auth().get_user_by_email(CLERK).disabled is True
    with pytest.raises(urllib.error.HTTPError):
        central_token(secure.project, CLERK)
    assert secure.db.collection("staff_sessions").where(
        filter=firestore.FieldFilter("email", "==", CLERK)).get()[0].to_dict()["status"] == "ended"
    deliver(secure)
    assert any("turned off" in text for text in notice_texts(secure, CLERK))
    assert any("turned off" in text for text in notice_texts(secure, FINANCE))
    assert "staff.disabled" in audit_actions(secure)
    reinvited = secure.app.post("/staff/v1/staff", json={"email": CLERK, "name": "Clerk One", "role": "support"}, headers=owner)
    assert reinvited.status_code == 201 and reinvited.json()["status"] == "invited"


def test_turning_off_a_person_who_never_accepted_does_not_mail_them(secure):
    owner = sign_in(secure, FOUNDER)
    identifier, token = invite_token(secure, owner)
    disabled = secure.app.post(f"/staff/v1/staff/{identifier}/disable", headers=owner)
    assert disabled.status_code == 200 and disabled.json()["status"] == "disabled"
    deliver(secure)
    assert notice_texts(secure, CLERK) == []
    notices = [text for text in notice_texts(secure, FINANCE) if "turned off" in text]
    assert notices and re.search(r"Time: \d{1,2} [A-Z][a-z]{2} \d{4}, \d{1,2}:\d{2} [ap]m \(GMT\+8\)", notices[-1])
    assert secure.app.post("/staff/v1/invite/check", json={"token": token}).status_code == 404
    shown = mail_params("staff_notice", {"tenantId": STAFF_MAIL_TENANT, "event": "disabled", "person": CLERK,
                                         "actor": FOUNDER, "at": "2026-11-13T06:39:29Z"})
    assert shown["at"] == "13 Nov 2026, 2:39 pm (GMT+8)"


def test_a_role_change_ends_sessions_and_only_the_owner_makes_it(secure):
    owner = sign_in(secure, FOUNDER)
    identifier = onboard(secure, owner, CLERK, "operator")
    clerk = sign_in(secure, CLERK)
    assert secure.app.get("/staff/v1/me", headers=clerk).json()["role"] == "operator"
    path = f"/staff/v1/staff/{identifier}/role"
    assert secure.app.put(path, json={"role": "owner"}, headers=clerk).status_code == 403
    assert secure.app.put(path, json={"role": "janitor"}, headers=owner).status_code == 400
    assert secure.app.put(f"/staff/v1/staff/{MISSING_STAFF_ID}/role", json={"role": "support"}, headers=owner).status_code == 404
    changed = secure.app.put(path, json={"role": "engineer"}, headers=owner)
    assert changed.status_code == 200 and changed.json()["role"] == "engineer"
    assert secure.app.get("/staff/v1/me", headers=clerk).status_code == 401
    assert secure.app.get("/staff/v1/me", headers=sign_in(secure, CLERK)).json()["role"] == "engineer"
    assert secure.app.put(path, json={"role": "engineer"}, headers=owner).status_code == 200
    deliver(secure)
    assert any("changed the role" in text for text in notice_texts(secure, FINANCE))
    assert "staff.role_changed" in audit_actions(secure)
    listed = secure.app.get("/staff/v1/staff", headers=owner)
    assert listed.status_code == 200 and listed.json()["domains"] == ["scoot.test"]
    assert {row["email"]: row["role"] for row in listed.json()["staff"]} == {FOUNDER: "owner", CLERK: "engineer"}
    assert secure.app.get("/staff/v1/staff", headers=sign_in(secure, CLERK)).status_code == 403


def test_the_last_active_owner_cannot_be_demoted_or_disabled(secure):
    owner = sign_in(secure, FOUNDER)
    founder_id = staff_id(FOUNDER)
    assert secure.app.put(f"/staff/v1/staff/{founder_id}/role", json={"role": "operator"}, headers=owner).status_code == 409
    assert secure.app.post(f"/staff/v1/staff/{founder_id}/disable", headers=owner).status_code == 409
    second = onboard(secure, owner, "boss@scoot.test", "owner", "Boss")
    assert secure.app.put(f"/staff/v1/staff/{founder_id}/role", json={"role": "operator"}, headers=owner).status_code == 200
    boss = sign_in(secure, "boss@scoot.test")
    assert secure.app.put(f"/staff/v1/staff/{second}/role", json={"role": "support"}, headers=boss).status_code == 409
    assert secure.app.post(f"/staff/v1/staff/{second}/disable", headers=boss).status_code == 409
    assert secure.app.get("/staff/v1/me", headers=boss).json()["role"] == "owner"


def test_staff_emails_must_use_a_company_domain_except_the_bootstrap_owner_in_the_emulator(secure, monkeypatch):
    owner = sign_in(secure, FOUNDER)
    refused = secure.app.post("/staff/v1/staff", json={"email": "someone@gmail.test", "name": "Some One", "role": "support"},
                              headers=owner)
    assert refused.status_code == 400 and "domain" in refused.json()["detail"]
    onboard(secure, owner, CLERK, "support")
    clerk = sign_in(secure, CLERK)
    monkeypatch.setattr(config, "STAFF_DOMAINS", frozenset({"other.test"}))
    assert secure.app.get("/staff/v1/me", headers=clerk).status_code == 403
    token = central_token(secure.project, CLERK)
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 403
    assert secure.app.get("/staff/v1/me", headers=owner).status_code == 200
    monkeypatch.setattr(config, "STAFF_DOMAINS", frozenset())
    none = secure.app.post("/staff/v1/staff", json={"email": "late@scoot.test", "name": "Late One", "role": "support"},
                           headers=owner)
    assert none.status_code == 400
    assert allowed_domain(FOUNDER) is True
    monkeypatch.setattr(auth, "emulator_mode", lambda: False)
    assert allowed_domain(FOUNDER) is False














def code_state(secure, token):
    return secure.db.collection("staff_login_codes").document(jwt.decode(token, options={"verify_signature": False})["sub"])


def lock_out(secure, token):
    codes = code_state(secure, token)
    if codes.get().exists:
        codes.update({"requestedAt": firestore.DELETE_FIELD, "windowCount": 0})
    assert secure.app.post("/staff/v1/session/code", headers=bearer(token)).status_code == 200
    code = re.findall(r"sign-in code is (\d{6})", secure.mail.to(CLERK)[-1]["text"])[0]
    answer = None
    for _ in range(5):
        answer = secure.app.post("/staff/v1/session/verify", json={"code": wrong_code(code)}, headers=bearer(token))
    assert answer.status_code == 429
    return codes, answer


def locked_notices(secure):
    deliver(secure)
    return sum("locked" in text and CLERK in text for text in notice_texts(secure, FOUNDER))


def test_each_lock_lasts_longer_and_the_owner_is_told_each_time(secure):
    owner = sign_in(secure, FOUNDER)
    onboard(secure, owner, CLERK, "operator")
    token = central_token(secure.project, CLERK)
    for minutes, words in ((15, "15 minutes"), (60, "60 minutes"), (1440, "24 hours"), (1440, "24 hours")):
        codes, answer = lock_out(secure, token)
        assert words in answer.json()["detail"]
        until = datetime.strptime(codes.get().to_dict()["lockedUntil"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        assert timedelta(minutes=minutes - 1) < until - datetime.now(timezone.utc) <= timedelta(minutes=minutes)
        codes.update({"lockedUntil": (datetime.now(timezone.utc) - timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                      "windowCount": 0})
    assert locked_notices(secure) == 4


def test_a_lock_after_a_good_sign_in_does_not_mail_the_owner_twice_in_an_hour(secure):
    owner = sign_in(secure, FOUNDER)
    onboard(secure, owner, CLERK, "operator")
    token = central_token(secure.project, CLERK)
    codes, _ = lock_out(secure, token)
    assert locked_notices(secure) == 1
    codes.update({"lockedUntil": "2020-01-01T00:00:00Z"})
    sign_in(secure, CLERK)
    assert codes.get().to_dict()["lockLevel"] == 0
    _, answer = lock_out(secure, token)
    assert "15 minutes" in answer.json()["detail"]
    assert locked_notices(secure) == 1
    codes.update({"lastLockNoticeAt": "2020-01-01T00:00:00Z", "lockedUntil": "2020-01-01T00:00:00Z"})
    lock_out(secure, token)
    assert locked_notices(secure) == 2










def test_the_bootstrap_list_makes_an_owner_only_when_there_is_none_and_says_so(secure, monkeypatch):
    sign_in(secure, FOUNDER)
    deliver(secure)
    assert any("as an owner from the bootstrap list" in text and FOUNDER in text for text in notice_texts(secure, FOUNDER))
    assert any("as an owner from the bootstrap list" in text for text in notice_texts(secure, FINANCE))
    assert "staff.bootstrapped" in audit_actions(secure)
    second = "second@founder.test"
    monkeypatch.setattr(config, "STAFF_BOOTSTRAP_OWNERS", frozenset({FOUNDER, second}))
    add_user(secure.project, second)
    refused = secure.app.post("/staff/v1/session/code", headers=bearer(central_token(secure.project, second)))
    assert refused.status_code == 403
    assert not secure.db.collection("staff").document(staff_id(second)).get().exists
    assert sign_in(secure, FOUNDER)


def test_the_bootstrap_list_cannot_recreate_an_owner_whose_row_was_lost(secure, monkeypatch):
    sign_in(secure, FOUNDER)
    secure.db.collection("staff").document(staff_id(FOUNDER)).delete()
    second = "second@founder.test"
    monkeypatch.setattr(config, "STAFF_BOOTSTRAP_OWNERS", frozenset({FOUNDER, second}))
    add_user(secure.project, second)
    refused = secure.app.post("/staff/v1/session/code", headers=bearer(central_token(secure.project, second)))
    assert refused.status_code == 403
    assert list(secure.db.collection("staff").stream()) == []




def test_the_bootstrap_audit_event_blocks_a_new_owner_when_the_marker_and_rows_are_lost(secure, monkeypatch):
    sign_in(secure, FOUNDER)
    secure.db.collection("staff_bootstrap").document("owner").delete()
    secure.db.collection("staff").document(staff_id(FOUNDER)).delete()
    second = "second@founder.test"
    monkeypatch.setattr(config, "STAFF_BOOTSTRAP_OWNERS", frozenset({FOUNDER, second}))
    add_user(secure.project, second)
    for email in (second, FOUNDER):
        refused = secure.app.post("/staff/v1/session/code", headers=bearer(central_token(secure.project, email)))
        assert refused.status_code == 403
    assert list(secure.db.collection("staff").stream()) == []


def invite_token(secure, owner, name="Clerk One", email=CLERK):
    invited = secure.app.post("/staff/v1/staff", json={"email": email, "name": name, "role": "operator"}, headers=owner)
    assert invited.status_code == 201, invited.text
    deliver(secure)
    token = re.findall(r"staffInvite=(stf_[0-9a-f]{24}\.[\w-]+)", secure.mail.to(email)[-1]["text"])[0]
    return invited.json()["staffId"], token


def test_an_invitation_survives_a_sign_in_service_failure_and_never_takes_over_an_existing_login(secure, monkeypatch):
    owner = sign_in(secure, FOUNDER)
    helper = "helper@scoot.test"
    identifier, token = invite_token(secure, owner, email=helper)
    monkeypatch.setitem(company_access._AUTH_CLIENTS, (secure.project, None), BrokenAuth())
    failed = secure.app.post("/staff/v1/invite/accept", json={"token": token, "password": CENTRAL_PASSWORD})
    assert failed.status_code == 503 and failed.json()["detail"] == staff.ACCOUNT_NOT_CREATED
    stored = secure.db.collection("staff").document(identifier).get().to_dict()
    assert stored["status"] == "invited" and "acceptNonce" not in stored
    assert secure.app.post("/staff/v1/invite/check", json={"token": token}).status_code == 200
    company_access._AUTH_CLIENTS.pop((secure.project, None))
    accepted = secure.app.post("/staff/v1/invite/accept", json={"token": token, "password": CENTRAL_PASSWORD})
    assert accepted.status_code == 201, accepted.text
    assert central_token(secure.project, helper)
    again = secure.app.post("/staff/v1/invite/accept", json={"token": token, "password": CENTRAL_PASSWORD})
    assert again.status_code == 404
    foreign_password = "foreign-pass-12345"
    add_user(secure.project, CLERK, foreign_password)
    identifier, token = invite_token(secure, owner)
    refused = secure.app.post("/staff/v1/invite/accept", json={"token": token, "password": CENTRAL_PASSWORD})
    assert refused.status_code == 409 and refused.json()["detail"] == "Ask the owner to send a new invitation."
    stored = secure.db.collection("staff").document(identifier).get().to_dict()
    assert stored["status"] == "invited" and "acceptNonce" not in stored
    assert central_token(secure.project, CLERK, foreign_password)
    with pytest.raises(urllib.error.HTTPError):
        central_token(secure.project, CLERK)
    assert secure.app.post("/staff/v1/invite/check", json={"token": token}).status_code == 200


class BrokenAuth:
    def get_user_by_email(self, email):
        raise admin_auth.UserNotFoundError("none")

    def create_user(self, **fields):
        raise firebase_exceptions.UnavailableError("The sign-in service is down.")








def company_base(record):
    return {name: record[name] for name in ("tenantId", "workspace", "legalName", "companyCode", "location",
                                            "locationKind", "clientConfig", "status", "planRef", "releaseRing",
                                            "rulesVersion", "edition") if name in record}


def move_to(world, assertion, tenant, project, key):
    record = world.store.get(tenant)
    return world.app.put(f"/staff/v1/companies/{tenant}",
                         json={"record": {**company_base(record), "location": {**record["location"], "projectId": project}},
                               "expectedVersion": record["version"], "reason": "Fix the project"},
                         headers=headers(assertion, ENGINEER, key))


def project_holders(world, project):
    return {row.to_dict()["tenantId"] for row in world.db.collection("company_claims").stream()
            if row.id == f"project:{project}"}


def lead_on(world, assertion, workspace, project):
    draft = start_draft(world, assertion, f"draft-{workspace}", workspace=workspace).json()["draftId"]
    done = complete_on(world, assertion, draft, f"complete-{workspace}", project)
    assert done.status_code == 200, done.text
    return done.json()["tenantId"]


def test_c241_a_deleted_company_gives_its_project_back(world, assertion):
    typo = f"demo-typo-{world.new_project[-8:]}"
    tenant = lead_on(world, assertion, "typoco", typo)
    assert project_holders(world, typo) == {tenant}
    second = start_draft(world, assertion, "draft-rightco", workspace="rightco").json()["draftId"]
    assert complete_on(world, assertion, second, "complete-rightco-1", typo).status_code == 409
    record = world.store.get(tenant)
    world.store.put({**company_base(record), "status": "deleted"}, expected_version=record["version"])
    assert project_holders(world, typo) == set()
    assert not [row.id for row in world.db.collection("company_claims").stream()
                if row.id.startswith(("location:", "auth:")) and typo in row.id]
    taken = complete_on(world, assertion, second, "complete-rightco-2", typo)
    assert taken.status_code == 200, taken.text
    assert project_holders(world, typo) == {taken.json()["tenantId"]}


def test_c241_two_companies_moving_to_one_project_at_the_same_moment_leave_one_holder(world, assertion):
    from concurrent.futures import ThreadPoolExecutor
    suffix = world.new_project[-8:]
    first = lead_on(world, assertion, "moveone", f"demo-one-{suffix}")
    second = lead_on(world, assertion, "movetwo", f"demo-two-{suffix}")
    target = f"demo-fixed-{suffix}"
    with ThreadPoolExecutor(max_workers=2) as pool:
        replies = list(pool.map(lambda pair: move_to(world, assertion, pair[1], target, f"move-race-000{pair[0]}"),
                                enumerate((first, second), start=1)))
    codes = sorted(reply.status_code for reply in replies)
    assert codes.count(200) == 1 and all(code in (200, 202, 409) for code in codes), [r.text for r in replies]
    holders = project_holders(world, target)
    assert len(holders) == 1
    loser = ({first, second} - holders).pop()
    assert project_holders(world, world.store.get(loser)["location"]["projectId"]) == {loser}




def test_a_complete_stopped_after_the_company_write_finishes_on_the_next_press_and_makes_one_company(
        world, assertion, monkeypatch):
    stuck = start_draft(world, assertion, "draft-r7-stuck001", workspace="stuckco").json()["draftId"]
    real_complete = OnboardingDrafts.complete

    def stop_after_company_write(self, actor, draft_id, tenant_id):
        raise RuntimeError("process stopped after the company write")

    monkeypatch.setattr(OnboardingDrafts, "complete", stop_after_company_write)
    with pytest.raises(RuntimeError):
        complete(world, assertion, stuck, "complete-r7-stuck001")
    tenant = ProjectSetup.tenant_id(stuck, world.new_project)
    assert world.db.collection("companies").document(tenant).get().exists
    view = world.app.get(f"/staff/v1/onboarding-drafts/{stuck}", headers=headers(assertion, OWNER)).json()
    assert view["status"] == "open" and view["tenantId"] is None and view["steps"][1]["state"] == "red"

    monkeypatch.setattr(OnboardingDrafts, "complete", real_complete)
    finished = complete(world, assertion, stuck, "complete-r7-stuck002")
    assert finished.status_code == 200, finished.text
    assert finished.json()["tenantId"] == tenant and finished.json()["ok"] is True
    assert world.db.collection("onboarding_drafts").document(stuck).get().to_dict()["status"] == "completed"
    assert complete(world, assertion, stuck, "complete-r7-stuck003").json()["tenantId"] == tenant
    companies = [row for row in world.db.collection("companies").stream() if row.to_dict().get("workspace") == "stuckco"]
    assert len(companies) == 1
    completed = [row for row in world.db.collection("audit_events").stream()
                 if row.to_dict()["action"] == "onboarding.completed" and row.to_dict().get("tenantId") == tenant]
    assert len(completed) == 1
    project = world.db.collection("onboarding_drafts").document(stuck).get().to_dict()
    assert project["status"] == "completed"
    lifecycle_row = world.db.collection("lifecycle").document(tenant).get().to_dict()
    assert lifecycle_row["state"] == "lead"


def test_a_lock_time_rounds_up_to_the_next_minute_so_the_person_never_returns_too_early():
    from platform_service.staff_signin import _kuala_lumpur_time
    assert _kuala_lumpur_time("2026-11-10T23:59:59Z").startswith("08:00 on 11 November 2026")
    assert _kuala_lumpur_time("2026-11-10T23:59:00Z").startswith("07:59 on 11 November 2026")


def staff_row(secure, identifier):
    return secure.db.collection("staff").document(identifier).get()


def test_owner_removes_a_turned_off_person_and_nothing_that_grants_access_remains(secure, monkeypatch):
    monkeypatch.setattr(config, "MAIL_DAILY_SOFT_CAP", 50)
    owner = sign_in(secure, FOUNDER)
    identifier = onboard(secure, owner, CLERK, "operator", name="Clerk One")
    clerk, _ = sign_in(secure, CLERK, remember=True)
    clerk_uid = jwt.decode(clerk["Authorization"].split()[1], options={"verify_signature": False})["sub"]
    assert secure.app.post(f"/staff/v1/staff/{identifier}/disable", headers=owner).status_code == 200
    secure.db.collection("staff_trusted_devices").document("leftover").set({"uid": clerk_uid, "email": CLERK})
    secure.db.collection("staff_backup_codes").document(identifier).set({"email": CLERK, "hashes": ["x"]})
    secure.db.collection("staff_login_codes").document(clerk_uid).set({"email": CLERK})
    removed = secure.app.post(f"/staff/v1/staff/{identifier}/remove", headers=owner)
    assert removed.status_code == 200, removed.text
    listed = secure.app.get("/staff/v1/staff", headers=owner).json()["staff"]
    assert [row["email"] for row in listed] == [FOUNDER]
    assert not staff_row(secure, identifier).exists
    assert remembered(secure) == []
    assert not secure.db.collection("staff_backup_codes").document(identifier).get().exists
    assert not secure.db.collection("staff_login_codes").document(clerk_uid).get().exists
    with pytest.raises(admin_auth.UserNotFoundError):
        platform_project_auth().get_user_by_email(CLERK)
    assert secure.app.get("/staff/v1/me", headers=clerk).status_code in (401, 403)
    events = [row.to_dict() for row in secure.db.collection("audit_events").stream()
              if row.to_dict()["action"] == "staff.removed"]
    assert len(events) == 1
    assert events[0]["actor"] == FOUNDER and CLERK in events[0]["summary"] and "Clerk One" in events[0]["summary"]
    assert "staff.disabled" in audit_actions(secure)
    again = secure.app.post("/staff/v1/staff", json={"email": CLERK, "name": "Clerk One", "role": "support"},
                            headers=owner)
    assert again.status_code == 201 and again.json()["status"] == "invited", again.text
    deliver(secure)
    invites = [message for message in secure.mail.to(CLERK) if "staffInvite=" in message["text"]]
    token = re.findall(r"staffInvite=(stf_[0-9a-f]{24}\.[\w-]+)", invites[-1]["text"])[0]
    accepted = secure.app.post("/staff/v1/invite/accept", json={"token": token, "password": CENTRAL_PASSWORD})
    assert accepted.status_code == 201, accepted.text
    assert secure.app.get("/staff/v1/me", headers=sign_in(secure, CLERK)).json()["role"] == "support"


def test_a_person_removed_and_invited_again_can_be_changed_turned_off_and_removed_again(secure, monkeypatch):
    monkeypatch.setattr(config, "MAIL_DAILY_SOFT_CAP", 50)
    owner = sign_in(secure, FOUNDER)
    identifier = onboard(secure, owner, CLERK, "operator", name="Clerk One")
    path = f"/staff/v1/staff/{identifier}"
    assert secure.app.put(f"{path}/role", json={"role": "support"}, headers=owner).status_code == 200
    assert secure.app.post(f"{path}/disable", headers=owner).status_code == 200
    assert secure.app.post(f"{path}/remove", headers=owner).status_code == 200
    again = secure.app.post("/staff/v1/staff", json={"email": CLERK, "name": "Clerk One", "role": "operator"},
                            headers=owner)
    assert again.status_code == 201 and again.json()["staffId"] == identifier, again.text
    deliver(secure)
    invites = [message for message in secure.mail.to(CLERK) if "staffInvite=" in message["text"]]
    token = re.findall(r"staffInvite=(stf_[0-9a-f]{24}\.[\w-]+)", invites[-1]["text"])[0]
    accepted = secure.app.post("/staff/v1/invite/accept", json={"token": token, "password": CENTRAL_PASSWORD})
    assert accepted.status_code == 201, accepted.text
    changed = secure.app.put(f"{path}/role", json={"role": "support"}, headers=owner)
    assert changed.status_code == 200, changed.text
    clerk = sign_in(secure, CLERK)
    off = secure.app.post(f"{path}/disable", headers=owner)
    assert off.status_code == 200 and off.json()["status"] == "disabled", off.text
    assert secure.app.post(f"{path}/disable", headers=owner).status_code == 200
    assert secure.app.get("/staff/v1/me", headers=clerk).status_code in (401, 403)
    removed = secure.app.post(f"{path}/remove", headers=owner)
    assert removed.status_code == 200, removed.text
    actions = [row.to_dict()["action"] for row in secure.db.collection("audit_events").stream()]
    assert [actions.count(name) for name in ("staff.role_changed", "staff.disabled", "staff.removed")] == [2, 2, 2]
    deliver(secure)
    notices = notice_texts(secure, FOUNDER)
    assert sum("turned off" in text for text in notices) == 2, notices


def test_remove_is_for_owners_and_only_for_turned_off_other_people(secure):
    owner = sign_in(secure, FOUNDER)
    identifier = onboard(secure, owner, CLERK, "operator")
    clerk = sign_in(secure, CLERK)
    pending, _ = invite_token(secure, owner, name="Pending One", email="pending@scoot.test")
    path = f"/staff/v1/staff/{identifier}/remove"
    assert secure.app.post(path, headers=clerk).status_code == 403
    engineer_id = onboard(secure, owner, "eng@scoot.test", "engineer", name="Eng One")
    engineer = sign_in(secure, "eng@scoot.test")
    assert secure.app.post(f"/staff/v1/staff/{engineer_id}/remove", headers=engineer).status_code == 403
    assert secure.app.post(path, headers=owner).status_code == 409
    assert secure.app.post(f"/staff/v1/staff/{pending}/remove", headers=owner).status_code == 409
    assert secure.app.post(f"/staff/v1/staff/{staff_id(FOUNDER)}/remove", headers=owner).status_code == 409
    assert secure.app.post(f"/staff/v1/staff/{MISSING_STAFF_ID}/remove", headers=owner).status_code == 404
    assert secure.app.post("/staff/v1/staff/not-an-id/remove", headers=owner).status_code == 404
    for row in (identifier, pending, staff_id(FOUNDER), engineer_id):
        assert staff_row(secure, row).exists
    assert secure.app.get("/staff/v1/me", headers=clerk).status_code == 200
    assert "staff.removed" not in audit_actions(secure)


def check_reason(secure, token):
    answer = secure.app.post("/staff/v1/invite/check", json={"token": token})
    assert answer.status_code == 404
    return answer.json()["detail"]


def test_an_unusable_invitation_says_whether_it_expired_was_replaced_or_was_cancelled(secure):
    owner = sign_in(secure, FOUNDER)
    identifier, first = invite_token(secure, owner)
    secure.db.collection("staff").document(identifier).update({"inviteExpiresAt": "2020-01-01T00:00:00Z"})
    assert "expired" in check_reason(secure, first)
    _, second = invite_token(secure, owner)
    assert second != first
    assert secure.app.post("/staff/v1/invite/check", json={"token": second}).status_code == 200
    replaced = check_reason(secure, first)
    assert "newer" in replaced and "expired" not in replaced
    assert secure.app.post(f"/staff/v1/staff/{identifier}/disable", headers=owner).status_code == 200
    cancelled = check_reason(secure, second)
    assert "cancelled" in cancelled
    assert "newer" in check_reason(secure, first)
    garbage = check_reason(secure, f"{identifier}.{'a' * 43}")
    assert all(word not in garbage for word in ("expired", "newer", "cancelled"))
    assert check_reason(secure, "nonsense") == garbage

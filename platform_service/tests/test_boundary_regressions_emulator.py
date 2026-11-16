
from __future__ import annotations

import base64
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config, staff_api
from platform_service.audit import EVENTS, AuditLog, event_hash
from platform_service.commands import CommandProblem
from platform_service.directory import DirectoryError, DirectoryStore
from platform_service.ids import local_date
from platform_service.operations import OperationStore
from platform_service.payments import PaymentLedger
from platform_service.plans import PlanStore, clean_override
from platform_service.ids import command_id
from platform_service.mail import DeliveryRejected, StubTransport, deliver_mail
from platform_service.mail_events import DeliveryEvent, record_event
from platform_service.scheduler import draft_renewal_invoices, staff_open_items
from platform_service.signing import Keyring, Signer, format_timestamp, parse_timestamp
from platform_service.tests.support import (
    CHECKER, CLERK, checked_payment, issued_invoice, payment_ledger, seed_subscription, staff_assertion, staff_domains, unchecked_payment)

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

OWNER = "owner@example.com"
OPERATOR = "operator@example.com"
OPERATOR2 = "operator2@example.com"
ENGINEER = "engineer@example.com"
TENANT = "t_northwind"
OTHER = "t_southridge"
RECEIVED = format_timestamp(datetime.now(timezone.utc))
AMOUNT = 10000
INVOICE = {TENANT: command_id("inv", TENANT, "api-invoice-0001", "invoice.draft"),
           OTHER: command_id("inv", OTHER, "api-invoice-0001", "invoice.draft")}
ROLES = {OWNER: "owner", OPERATOR: "operator", OPERATOR2: "operator", ENGINEER: "engineer"}


def next_period(world, tenant):
    return {"periodStart": world.db.collection("invoices").document(INVOICE[tenant]).get().to_dict()["periodEnd"].strftime(
        "%Y-%m-%dT%H:%M:%SZ")}


def evidence(label, **facts):
    print("EVIDENCE " + label + " | " + " ".join(f"{key}={value!r}" for key, value in facts.items()))


@pytest.fixture(autouse=True)
def staff_settings(monkeypatch):
    monkeypatch.setattr(config, "STAFF_DOMAINS", staff_domains(ROLES))


@pytest.fixture
def assertion():
    return staff_assertion(ROLES)


def client_config():
    return {"apiKey": {"android": "AIza" + "A" * 35, "web": "AIza" + "B" * 35},
            "appId": {"android": "1:222222222222:android:aaaaaaaaaaaaaaaa",
                      "web": "1:222222222222:web:cccccccccccccccc"},
            "messagingSenderId": "222222222222"}


@pytest.fixture
def world(monkeypatch, assertion):
    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    monkeypatch.setenv("PLATFORM_MAIL_TRANSPORT", "stub")
    project = f"demo-regress-{uuid.uuid4().hex[:12]}"
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", project)
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    signer = Signer.generate("regress-test")
    store = DirectoryStore(db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    for tenant, slug in ((TENANT, "northwind"), (OTHER, "southridge")):
        store.put({
            "tenantId": tenant, "workspace": slug, "legalName": f"{slug} Foods Sdn Bhd", "companyCode": slug,
            "location": {"projectId": f"demo-{slug}-{project[-8:]}", "databaseId": "(default)", "authTenantId": None},
            "locationKind": "byo", "clientConfig": client_config(), "status": "live", "planRef": "standard",
            "releaseRing": "general", "rulesVersion": "r1",
        }, expected_version=0)
    app = TestClient(staff_api.create_app(store=store, operations=OperationStore(db), signer=signer, client=db))
    for tenant in (TENANT, OTHER):
        seed_subscription(db, tenant, "P1", billingInterval="monthly")
        drafted = app.post(f"/staff/v1/companies/{tenant}/invoices", json={},
                           headers=headers(assertion, OPERATOR, "api-invoice-0001"))
        assert drafted.status_code == 201 and drafted.json()["invoiceId"] == INVOICE[tenant], drafted.text
        assert app.post(f"/staff/v1/invoices/{INVOICE[tenant]}/issue",
                        headers=headers(assertion, OPERATOR)).status_code == 200
    yield type("World", (), {"db": db, "app": app, "store": store, "project": project})
    app.close()

    def clear(collection):
        for document in collection.stream():
            for child in document.reference.collections():
                clear(child)
            document.reference.delete()
    for collection in db.collections():
        clear(collection)
    db.close()


def headers(assertion, email=OWNER, key=None):
    result = assertion(email)
    if key is not None:
        result["Idempotency-Key"] = key
    return result


def ask(world, assertion, action, params, key, *, who=OPERATOR, tenant=TENANT, reason="Agreed with the client"):
    body = {"action": action, "reason": reason, "params": params}
    if tenant is not None:
        body["tenantId"] = tenant
    return world.app.post("/staff/v1/approvals", json=body, headers=headers(assertion, who, key))


def decide(world, assertion, approval_id, who=OWNER, verb="approve"):
    return world.app.post(f"/staff/v1/approvals/{approval_id}/{verb}", headers=headers(assertion, who))


def payment(tenant=TENANT, **changes):
    return {"amountMinor": AMOUNT, "currency": "MYR", "externalReference": "BANK/REGRESS-001",
            "invoiceId": INVOICE[tenant], "receivedAt": RECEIVED, "reason": "Manual bank confirmation", **changes}


def payment_path(tenant=TENANT):
    return f"/staff/v1/companies/{tenant}/payments"


def lifecycle_path(tenant=TENANT):
    return f"/staff/v1/companies/{tenant}/lifecycle"


def valid_plan_v1():
    return {"name": "Regress Plan", "edition": "basic",
            "limits": {"salesmen": 2, "supervisors": 1, "managers": 1, "products": 60},
            "features": {}, "prices": {"currency": "MYR", "monthly": 100, "yearly": 960},
            "tagline": "T", "highlights": ["x"], "sortOrder": 10, "notes": ""}


def activate_company(world, assertion, reference="REGRESS-ACTIVE"):
    receipt = world.app.post(payment_path(), json=payment(externalReference=reference),
                             headers=headers(assertion, OPERATOR, f"{reference}-pay")).json()
    active = world.app.put(lifecycle_path(), json={"state": "active", "expectedRevision": 0,
                                                   "paymentEntryId": receipt["entryId"],
                                                   "reason": "Paid activation", "ticket": None},
                           headers=headers(assertion, key=f"{reference}-act"))
    assert active.status_code == 200, active.text
    return receipt


def disable_staff(world, email):
    from platform_service.staff import STAFF, staff_id
    world.db.collection(STAFF).document(staff_id(email)).update({"status": "disabled"})



def company_base(record):
    return {key: record[key] for key in ("tenantId", "workspace", "legalName", "companyCode", "location",
                                         "locationKind", "clientConfig", "status", "planRef", "releaseRing",
                                         "rulesVersion")}


def put_company(world, assertion, who, record, version, key, **changes):
    return world.app.put(f"/staff/v1/companies/{TENANT}",
                         json={"record": {**company_base(record), **changes}, "expectedVersion": version,
                               "reason": "Regression"},
                         headers=headers(assertion, who, key))


def test_c1_engineer_cannot_change_owner_only_fields_with_a_setup_change(world, assertion):
    record = world.store.get(TENANT)
    version = record["version"]
    name_only = put_company(world, assertion, ENGINEER, record, version, "c1-control-001",
                            legalName="Renamed by engineer")
    assert name_only.status_code == 403
    combined = put_company(world, assertion, ENGINEER, record, version, "c1-attack-001",
                           legalName="Renamed by engineer", workspace="northwind2", companyCode="nw2",
                           releaseRing="pilot")
    after = world.store.get(TENANT)
    evidence("C1 engineer PUT with a setup change plus owner-only fields", status=combined.status_code,
             detail=combined.json().get("detail"), legalName=after["legalName"], releaseRing=after["releaseRing"])
    assert combined.status_code == 403
    for refused in ("company name", "workspace", "company code"):
        assert refused in combined.json()["detail"]
    assert (after["legalName"], after["workspace"], after["companyCode"], after["releaseRing"]) == (
        record["legalName"], record["workspace"], record["companyCode"], record["releaseRing"])
    assert after["version"] == version
    setup_only = put_company(world, assertion, ENGINEER, record, version, "c1-setup-001", releaseRing="pilot")
    assert setup_only.status_code == 200, setup_only.text
    assert world.store.get(TENANT)["releaseRing"] == "pilot"
    owner = put_company(world, assertion, OWNER, record, version + 1, "c1-owner-001",
                        legalName="Renamed by owner", releaseRing="pilot")
    assert owner.status_code == 200, owner.text
    assert world.store.get(TENANT)["legalName"] == "Renamed by owner"
    again = put_company(world, assertion, ENGINEER, world.store.get(TENANT), version + 2, "c1-nochange-001")
    assert again.status_code == 403 and "Only the owner" in again.json()["detail"]


def test_c2_service_addresses_are_accepted_only_on_known_hosts(world, assertion):
    record = world.store.get(TENANT)
    version = record["version"]
    refused = {
        "https://attacker.example.net/copilot": "attacker.example.net",
        "https://scootsales.my": "scootsales.my",
        "https://evilscootsales.my": "evilscootsales.my",
        "https://scootsales.my.evil.test": "scootsales.my.evil.test",
        "https://scootsales.my@evil.test": None,
        "https://evil.test@scootsales.my": None,
        "http://scootsales.my": None,
        "http://evil.test": None,
        "https://a..scootsales.my": None,
        "https://.scootsales.my": None,
        "https://copilot.scootsales.my:99999": None,
        "https://copilot.scootsales.my/../x": None,
    }
    for number, (url, host) in enumerate(refused.items()):
        for who in (ENGINEER, OWNER):
            for name in ("copilotUrl", "forecastingUrl"):
                put = put_company(world, assertion, who, record, version, f"c2-refuse-{number}-{who[:3]}-{name[:3]}",
                                  services={name: url})
                assert put.status_code == 400, (url, who, name, put.text)
                if host:
                    assert host in put.json()["detail"] and name in put.json()["detail"]
    assert world.store.get(TENANT).get("services", {}) == {}
    assert world.store.get(TENANT)["version"] == version
    for number, url in enumerate(("https://copilot.scootsales.my/v1",
                                  "http://127.0.0.1:8000", "http://localhost:9000")):
        current = world.store.get(TENANT)
        put = put_company(world, assertion, ENGINEER, record, current["version"], f"c2-accept-{number}",
                          services={"copilotUrl": url})
        assert put.status_code == 200, (url, put.text)
        assert world.store.get(TENANT)["services"] == {"copilotUrl": url}


def test_c2_a_record_with_an_older_unknown_host_still_renews_and_can_change_setup(world, assertion):
    record = world.store.get(TENANT)
    legacy = {**company_base(record), "services": {"copilotUrl": "https://old-host.example.net"}}
    world.store.put(legacy, expected_version=record["version"])
    stored = world.store.get(TENANT)
    assert stored["services"] == {"copilotUrl": "https://old-host.example.net"}
    unchanged = world.app.put(
        f"/staff/v1/companies/{TENANT}",
        json={"record": {**legacy, "releaseRing": "pilot"}, "expectedVersion": stored["version"], "reason": "Ring"},
        headers=headers(assertion, ENGINEER, "c2-legacy-001"))
    assert unchanged.status_code == 200, unchanged.text
    moved = world.app.put(
        f"/staff/v1/companies/{TENANT}",
        json={"record": {**legacy, "services": {"copilotUrl": "https://other.example.net"}},
              "expectedVersion": stored["version"] + 1, "reason": "Move"},
        headers=headers(assertion, ENGINEER, "c2-legacy-002"))
    assert moved.status_code == 400 and "other.example.net" in moved.json()["detail"]
    renewed = world.store.get(TENANT)
    assert renewed["services"] == {"copilotUrl": "https://old-host.example.net"}


def test_p2_an_engineer_cannot_change_owner_only_fields_of_a_company_whose_record_has_expired(world, assertion):
    record = world.store.get(TENANT)
    long_ago = datetime.now(timezone.utc) - timedelta(days=400)
    world.store.put(company_base(record), expected_version=record["version"], now=long_ago)
    with pytest.raises(DirectoryError):
        world.store.get(TENANT)
    stored = world.db.collection("companies").document(TENANT).get().to_dict()
    version = stored["version"]
    renamed = put_company(world, assertion, ENGINEER, record, version, "p2-expired-name", legalName="Renamed by engineer")
    assert renamed.status_code == 403 and "company name" in renamed.json()["detail"], renamed.text


def test_c4_staff_session_ends_after_a_password_change(world, monkeypatch):
    import json
    import urllib.request
    from platform_service.company_access import _project_auth as project_auth
    from platform_service.staff import SESSIONS, STAFF, digest, staff_id

    def call(method, url, body=None):
        request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                         method=method, headers={"Content-Type": "application/json",
                                                                 "Authorization": "Bearer owner"})
        return json.loads(urllib.request.urlopen(request).read().decode() or "{}")

    auth_host = os.environ["FIREBASE_AUTH_EMULATOR_HOST"]
    toolkit = f"http://{auth_host}/identitytoolkit.googleapis.com/v1"
    project = world.project
    call("POST", f"{toolkit}/projects/{project}/accounts",
         {"localId": "staff-owner", "email": OWNER, "password": "first-password-1", "emailVerified": True})
    signed = call("POST", f"{toolkit}/accounts:signInWithPassword?key=fake",
                  {"targetProjectId": project, "email": OWNER, "password": "first-password-1", "returnSecureToken": True})
    old_token, old_refresh = signed["idToken"], signed["refreshToken"]
    import time
    time.sleep(1.1)
    now = datetime.now(timezone.utc)
    world.db.collection(STAFF).document(staff_id(OWNER)).set(
        {"email": OWNER, "name": "owner", "role": "owner", "status": "active", "uid": "staff-owner",
         "createdAt": format_timestamp(now)})
    secret = "regress-session-secret-" + uuid.uuid4().hex
    world.db.collection(SESSIONS).document(digest(secret)).set(
        {"uid": "staff-owner", "email": OWNER, "authTime": format_timestamp(now), "createdAt": format_timestamp(now),
         "expiresAt": format_timestamp(now + timedelta(hours=12)), "status": "active", "userAgent": "test",
         "ip": "127.0.0.1", "deviceHash": None})
    staff_headers = {"Authorization": "Bearer " + old_token, "X-Staff-Session": secret}
    before = world.app.get("/staff/v1/me", headers=staff_headers)
    assert before.status_code == 200, before.text
    other_handle = digest("other-session-secret-" + uuid.uuid4().hex)
    world.db.collection(SESSIONS).document(other_handle).set(
        {"uid": "staff-other", "email": OPERATOR, "authTime": format_timestamp(now), "createdAt": format_timestamp(now),
         "expiresAt": format_timestamp(now + timedelta(hours=12)), "status": "active", "userAgent": "test",
         "ip": "127.0.0.1", "deviceHash": None})
    from platform_service.account_security import watch_passwords
    from platform_service.mail import MailQueue
    watch_mail = MailQueue(world.db, enabled=True)

    def watch():
        return watch_passwords(world.db, watch_mail, directory=world.store, access_for=lambda location: None,
                               staff_auth=lambda: project_auth(project))

    watch()
    assert world.app.get("/staff/v1/me", headers=staff_headers).status_code == 200
    project_auth(project).update_user("staff-owner", password="second-password-2")
    watch()
    user = project_auth(project).get_user("staff-owner")
    import base64
    claims = json.loads(base64.urlsafe_b64decode(old_token.split(".")[1] + "==").decode())
    after = world.app.get("/staff/v1/me", headers=staff_headers)
    evidence("C4 old ID token + staff session after password change", status=after.status_code,
             token_iat=claims.get("iat"), tokens_valid_after_ms=user.tokens_valid_after_timestamp)
    try:
        refreshed = call("POST", f"http://{auth_host}/securetoken.googleapis.com/v1/token?key=fake",
                         {"grant_type": "refresh_token", "refresh_token": old_refresh})
        refresh_outcome = "refresh accepted: new id token issued"
        _ = refreshed
    except urllib.error.HTTPError as error:
        refresh_outcome = f"refresh refused: HTTP {error.code}"
    evidence("C4 old refresh token after password change", outcome=refresh_outcome)
    ended = world.app.post("/staff/v1/sessions/sign-out-all", headers=staff_headers)
    control = world.app.get("/staff/v1/me", headers=staff_headers)
    evidence("C4 control sign-out-all then /me", ended=ended.json(), status=control.status_code)
    assert after.status_code == 401
    assert control.status_code == 401
    assert world.db.collection(SESSIONS).document(other_handle).get().to_dict()["status"] == "active"



def solo_void_setup(world, assertion):
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OWNER, "c5-record-001"))
    assert recorded.status_code == 201, recorded.text
    entry = recorded.json()["entryId"]
    assert world.app.get("/staff/v1/approvals", headers=headers(assertion, OPERATOR2)).status_code == 200
    asked = ask(world, assertion, "payment.void", {"receiptId": entry}, "c5-ask-001", who=OPERATOR, reason="Wrong")
    assert asked.status_code == 201, asked.text
    disable_staff(world, OPERATOR)
    disable_staff(world, OPERATOR2)
    return asked.json()["approvalId"]


def test_c5_solo_void_finishes_after_the_requesting_operator_is_turned_off(world, assertion, monkeypatch):
    monkeypatch.setattr(config, "SOLO_OWNER", True)
    approval_id = solo_void_setup(world, assertion)
    solo = world.app.get("/staff/v1/staff", headers=headers(assertion)).json()["soloOwner"]
    decided = decide(world, assertion, approval_id, OWNER)
    stored = world.db.collection("approvals").document(approval_id).get().to_dict()
    voids = [row.to_dict()["type"] for row in world.db.collection("payment_entries").stream()]
    approved_events = [row.to_dict() for row in world.db.collection(EVENTS).stream()
                       if row.to_dict()["action"] == "approval.approved"]
    evidence("C5 owner approves the disabled operator's void request", solo_owner=solo, status=decided.status_code,
             approval_status=stored["status"], executionError=stored.get("executionError"), types=voids)
    assert solo["active"] is True
    assert decided.status_code == 200, decided.text
    assert stored["status"] == "executed" and stored.get("executionError") is None and "void" in voids
    assert stored["soloApproval"] is True
    assert any(event["summary"].startswith("Solo approval") and event["refs"].get("soloApproval") == "true"
               for event in approved_events)
    control_recorded = world.app.post(payment_path(OTHER), json=payment(OTHER, externalReference="BANK/REGRESS-002"),
                                      headers=headers(assertion, OWNER, "c5-record-002"))
    control_ask = ask(world, assertion, "payment.void", {"receiptId": control_recorded.json()["entryId"]},
                      "c5-ask-002", who=OWNER, tenant=OTHER, reason="Wrong")
    control = decide(world, assertion, control_ask.json()["approvalId"], OWNER)
    assert control.status_code == 200
    assert control.json()["approval"]["status"] == "executed"


def test_c5_without_solo_mode_the_owner_still_cannot_void_their_own_payment(world, assertion, monkeypatch):
    monkeypatch.setattr(config, "SOLO_OWNER", False)
    approval_id = solo_void_setup(world, assertion)
    decided = decide(world, assertion, approval_id, OWNER)
    stored = world.db.collection("approvals").document(approval_id).get().to_dict()
    voids = [row.to_dict()["type"] for row in world.db.collection("payment_entries").stream()]
    assert decided.status_code == 409 and "Another person must void this payment." in decided.json()["detail"]
    assert stored["status"] == "requested" and "void" not in voids


def approved_credit_note(world, assertion, key, amount):
    asked = ask(world, assertion, "invoice.credit_note", {"invoiceId": INVOICE[TENANT], "amountMinor": amount},
                key, reason="Goodwill")
    assert asked.status_code == 201, asked.text
    return asked.json()["approvalId"]


def retry_approval(world, assertion, approval_id, who=OWNER):
    return world.app.post(f"/staff/v1/approvals/{approval_id}/retry", headers=headers(assertion, who))


def close_approval(world, assertion, approval_id, who=OWNER, reason="Not needed any more"):
    return world.app.post(f"/staff/v1/approvals/{approval_id}/close", json={"reason": reason},
                          headers=headers(assertion, who))


def test_c10_an_approved_request_whose_work_failed_can_be_tried_again_once_or_closed(world, assertion, monkeypatch):
    from platform_service.invoices import InvoiceBook
    activate_company(world, assertion)
    approval_id = approved_credit_note(world, assertion, "c10-credit-001", 100)
    original = InvoiceBook.credit_note

    def crash(*args, **kwargs):
        raise RuntimeError("simulated server crash during the step")

    monkeypatch.setattr(InvoiceBook, "credit_note", crash)
    failed = decide(world, assertion, approval_id, OWNER)
    stored = world.db.collection("approvals").document(approval_id).get().to_dict()
    operation = world.db.collection("operations").document(stored["operationId"]).get().to_dict()
    assert failed.status_code == 409 and stored["status"] == "approved" and operation["status"] == "failed"
    assert "Try again" in stored["executionError"]
    still = retry_approval(world, assertion, approval_id)
    assert still.status_code == 409
    assert world.db.collection("approvals").document(approval_id).get().to_dict()["status"] == "approved"

    monkeypatch.setattr(InvoiceBook, "credit_note", original)
    assert retry_approval(world, assertion, approval_id, ENGINEER).status_code == 403
    retried = retry_approval(world, assertion, approval_id, OPERATOR)
    assert retried.status_code == 200, retried.text
    assert retried.json()["approval"]["status"] == "executed" and retried.json()["operation"]["status"] == "completed"
    again = retry_approval(world, assertion, approval_id, OWNER)
    assert again.status_code == 200 and again.json()["approval"]["status"] == "executed"
    assert len(list(world.db.collection("credit_notes").stream())) == 1
    final = world.db.collection("approvals").document(approval_id).get().to_dict()
    assert final["status"] == "executed" and final.get("executionError") is None
    assert close_approval(world, assertion, approval_id).status_code == 409
    assert world.app.get("/staff/v1/approvals?status=approved", headers=headers(assertion, OWNER)
                         ).json()["approvals"] == []

    second = approved_credit_note(world, assertion, "c10-credit-002", 150)
    monkeypatch.setattr(InvoiceBook, "credit_note", crash)
    assert decide(world, assertion, second, OWNER).status_code == 409
    monkeypatch.setattr(InvoiceBook, "credit_note", original)
    assert close_approval(world, assertion, second, OWNER, "ab").status_code == 400
    closed = close_approval(world, assertion, second, OPERATOR)
    assert closed.status_code == 200, closed.text
    row = world.db.collection("approvals").document(second).get().to_dict()
    assert row["status"] == "rejected" and row["rejectionReason"].startswith("Closed without finishing")
    assert len(list(world.db.collection("credit_notes").stream())) == 1
    assert retry_approval(world, assertion, second).status_code == 409
    assert close_approval(world, assertion, second).status_code == 409
    waiting = ask(world, assertion, "invoice.credit_note", {"invoiceId": INVOICE[TENANT], "amountMinor": 120},
                  "c10-credit-003", reason="Goodwill").json()["approvalId"]
    assert retry_approval(world, assertion, waiting).status_code == 409
    assert close_approval(world, assertion, waiting).status_code == 409


def test_c10_the_scheduler_finishes_pending_work_of_every_kind(world, assertion, monkeypatch):
    from platform_service.invoices import InvoiceBook
    from platform_service.operations import RetryLater
    captured = []
    monkeypatch.setattr(staff_api, "install_scheduler", lambda app, build: captured.append(build))
    staff_api.create_app(store=world.store, operations=OperationStore(world.db), signer=world.store.signer,
                         client=world.db)
    scheduler = captured[0]()
    assert "recover_operations" in scheduler.job_names()
    activate_company(world, assertion)
    approval_id = approved_credit_note(world, assertion, "c10-credit-sched", 100)
    original = InvoiceBook.credit_note

    def unavailable(*args, **kwargs):
        raise RetryLater("the service is not available")

    monkeypatch.setattr(InvoiceBook, "credit_note", unavailable)
    pending = decide(world, assertion, approval_id, OWNER)
    assert pending.status_code == 202, pending.text
    monkeypatch.setattr(InvoiceBook, "credit_note", original)
    operation_id = world.db.collection("approvals").document(approval_id).get().to_dict()["operationId"]
    world.db.collection("operations").document(operation_id).update({"leaseUntil": datetime(2020, 1, 1, tzinfo=timezone.utc)})
    assert scheduler.run_due(only=["recover_operations"]) == {"recover_operations": "ran"}
    assert world.db.collection("operations").document(operation_id).get().to_dict()["status"] == "completed"
    assert len(list(world.db.collection("credit_notes").stream())) == 1
    listed = world.app.get("/staff/v1/approvals?status=executed", headers=headers(assertion, OWNER)).json()
    assert [row["approvalId"] for row in listed["approvals"]] == [approval_id]


def test_c6_owner_prices_a_new_package_in_two_writes_without_approval(world, assertion):
    priced = {**valid_plan_v1(), "name": "Direct"}
    direct = world.app.put("/staff/v1/plans/DIRECT", json=priced, headers=headers(assertion, OWNER, "c6-direct-001"))
    evidence("C6 control one owner write of a priced new package", status=direct.status_code,
             approvalAction=direct.json().get("approvalAction"))
    unpriced = {**priced, "prices": {"currency": "MYR", "monthly": None, "yearly": None}}
    first = world.app.put("/staff/v1/plans/TWOSTEP", json=unpriced, headers=headers(assertion, OWNER, "c6-step-001"))
    second = world.app.put("/staff/v1/plans/TWOSTEP", json=priced, headers=headers(assertion, OWNER, "c6-step-002"))
    plan = world.db.collection("plans").document("TWOSTEP").get().to_dict()
    current = world.db.collection("plans").document("TWOSTEP").collection("versions").document(
        str(plan["currentVersion"])).get().to_dict()
    approvals = [row.to_dict()["action"] for row in world.db.collection("approvals").stream()]
    evidence("C6 two owner writes: unpriced then priced", first=first.status_code, second=second.status_code,
             currentVersion=plan["currentVersion"], prices=current["prices"], approvals=approvals)
    third = world.app.put("/staff/v1/plans/TWOSTEP", json={**priced, "prices": {"currency": "MYR", "monthly": 150,
                                                                                 "yearly": 1500}},
                          headers=headers(assertion, OWNER, "c6-step-003"))
    evidence("C6 third write changing the price", status=third.status_code,
             approvalAction=third.json().get("approvalAction"))
    assert direct.status_code == 409 and first.status_code == 200 and second.status_code == 200
    assert current["prices"]["monthly"] == 100 and approvals == [] and third.status_code == 409



@pytest.fixture
def sched(monkeypatch):
    from platform_service.tests import test_scheduler_emulator as sched_module
    project = f"demo-regress-sched-{uuid.uuid4().hex[:12]}"
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    state = sched_module.State()
    state.project, state.db = project, db
    state.module = sched_module
    yield state
    db.close()


def queue_invoice_mail(sched, world, key="billing-second-0001"):
    renewal = world.book.create_draft(sched.module.BILLING_TENANT, key,
                                      {"periodStart": world.first["periodEnd"]}, "clerk@example.test")
    world.book.issue(renewal["invoiceId"], "clerk@example.test")
    return world.book.send(renewal["invoiceId"], "clerk@example.test")


def invoice_jobs(world):
    return [row.to_dict() for row in world.db.collection("mail_jobs").stream() if row.to_dict()["kind"] == "invoice"]


def test_c7_invoice_waits_for_its_mail_job_and_a_failed_mail_never_starts_past_due(sched, monkeypatch):
    world = sched.module.build_billing(sched, monkeypatch, checked=True)
    queued = queue_invoice_mail(sched, world)
    jobs = invoice_jobs(world)
    evidence("C7 invoice right after send", status=queued["status"], deliveredAt=queued["deliveredAt"],
             dueAt=queued["dueAt"], delivery=queued["delivery"], mail_job_status=[job["status"] for job in jobs])
    assert queued["status"] == "issued" and queued["deliveredAt"] is None and queued["dueAt"] is None
    assert queued["delivery"]["state"] == "sending" and jobs[0]["status"] == "queued"
    for job in world.db.collection("mail_jobs").stream():
        job.reference.update({"status": "failed", "lastFailure": "simulated bounce"})
    world.now = sched.module.NOW + timedelta(days=15)
    world.scheduler.run_due(only=["past_due"])
    invoice = world.book.get(queued["invoiceId"])
    evidence("C7 after the mail job failed and 15 days passed", invoice_status=invoice["status"],
             lifecycle=sched.module.lifecycle_state(world), delivery=invoice["delivery"],
             operations=[op["reason"] for op in sched.module.scheduler_operations(world)])
    assert invoice["status"] == "issued" and invoice["dueAt"] is None
    assert invoice["delivery"]["state"] == "not_delivered" and "simulated bounce" in invoice["delivery"]["reason"]
    assert sched.module.lifecycle_state(world) == "active"
    again = world.book.send(queued["invoiceId"], "clerk@example.test")
    assert again["delivery"]["state"] == "sending" and len(invoice_jobs(world)) == 2
    deliver_mail(world.book.mail, now=world.now, transport=StubTransport())
    delivered = world.book.get(queued["invoiceId"])
    evidence("C7 after send again and delivery", status=delivered["status"], deliveredAt=delivered["deliveredAt"],
             dueAt=delivered["dueAt"])
    assert delivered["status"] == "sent" and delivered["delivery"]["state"] == "delivered"
    assert delivered["dueAt"] == (parse_timestamp(delivered["deliveredAt"]) + timedelta(days=14)).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    world.now = world.now + timedelta(days=15)
    world.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(world) == "past_due"




def test_c7_lease_recovery_that_cannot_tell_if_the_mail_left_shows_not_delivered_until_confirmed(sched, monkeypatch):
    world = sched.module.build_billing(sched, monkeypatch, checked=True)
    queued = queue_invoice_mail(sched, world)
    job = world.db.collection("mail_jobs").document(invoice_jobs(world)[0]["jobId"])
    job.update({"status": "sending", "attempts": 1, "leaseToken": "dead", "leaseOwner": "dead",
                "leaseExpiresAt": "2020-01-01T00:00:00Z", "providerCallStartedAt": "2026-11-01T12:00:00Z"})
    world.book.mail.recover_expired(sched.module.NOW + timedelta(days=1))
    invoice = world.book.get(queued["invoiceId"])
    assert invoice["status"] == "issued" and invoice["delivery"]["state"] == "not_delivered"
    assert invoice["delivery"]["needsConfirm"] is True
    with pytest.raises(Exception, match="duplicate risk"):
        world.book.send(queued["invoiceId"], "clerk@example.test")
    world.book.send(queued["invoiceId"], "clerk@example.test", confirm_duplicate_risk=True)
    deliver_mail(world.book.mail, now=sched.module.NOW + timedelta(days=1), transport=StubTransport())
    assert world.book.get(queued["invoiceId"])["status"] == "sent"




@pytest.mark.parametrize("who", ["another_person", "solo_owner"])
def test_c9_voiding_the_only_payment_clears_paid_at_and_the_company_lapses_with_a_reason(sched, monkeypatch, who):
    world = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = sched.module.BILLING_TENANT
    ledger = payment_ledger(world.db, world.now)
    receipt = ledger.list_entries(tenant)[0]
    actor, solo = ("owner@example.test", False) if who == "another_person" else (receipt["createdBy"], True)
    before = world.db.collection("invoices").document(world.first["invoiceId"]).get().to_dict()
    void = ledger.correct(tenant, "c9-void-0001", receipt["entryId"], {"reason": "Wrong bank line"}, actor, solo=solo)
    assert void["type"] == "void" and before["paidAt"] is not None
    after = world.db.collection("invoices").document(world.first["invoiceId"]).get().to_dict()
    world.now = sched.module.NOW + timedelta(days=1)
    world.scheduler.run_due(only=["past_due"])
    reasons = [op["reason"] for op in sched.module.scheduler_operations(world)]
    evidence(f"C9 {who} void then scheduler", lifecycle=sched.module.lifecycle_state(world),
             invoice_status=after["status"], paidAt=after["paidAt"], paidMinor=after["paidMinor"], reasons=reasons,
             paid_until=ledger.coverage(tenant, world.now).paid_until)
    assert after["paidAt"] is None and after["paidMinor"] == 0 and after["status"] != "paid"
    assert sched.module.lifecycle_state(world) == "past_due"
    assert reasons == ["A payment was voided and the company has no other paid cover."]


def test_c9_control_unvoided_payment_stays_active_and_lapses_only_when_cover_ends(sched, monkeypatch):
    world = sched.module.build_billing(sched, monkeypatch, checked=True)
    world.now = sched.module.NOW + timedelta(days=1)
    world.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(world) == "active"
    world.now = sched.module.NOW + timedelta(days=120)
    world.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(world) == "past_due"




def test_c14_unchecked_payments_on_fresh_invoices_cannot_extend_the_seven_day_cover(sched, monkeypatch):
    world = sched.module.build_billing(sched, monkeypatch, checked=False)
    tenant = sched.module.BILLING_TENANT
    first = payment_ledger(world.db, world.now).list_entries(tenant)[0]
    world.now = sched.module.NOW + timedelta(days=5)
    world.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(world) == "active"
    world.now = sched.module.NOW + timedelta(days=6)
    first_end = world.book.list_invoices(tenant)[0]["periodEnd"]
    _, invoice = issued_invoice(world.db, tenant, world.now, "c14-roll-0002", period_start=first_end)
    world.db.collection("invoices").document(invoice["invoiceId"]).update({"periodStart": world.now})
    unchecked_payment(world.db, tenant, invoice, world.now, recorder="operator@example.test")
    world.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(world) == "active"
    shown = payment_ledger(world.db, world.now).snapshot(tenant)["cover"]
    world.now = sched.module.NOW + timedelta(days=8)
    world.scheduler.run_due(only=["past_due"])
    reasons = [op["reason"] for op in sched.module.scheduler_operations(world)]
    ledger = payment_ledger(world.db, world.now)
    evidence("C14 day 8 with a second unchecked payment on a fresh invoice", lifecycle=sched.module.lifecycle_state(world),
             reasons=reasons, checkBy=shown["checkBy"], paid_until=ledger.coverage(tenant, world.now).paid_until,
             checked_payments=len(list(world.db.collection("payment_checks").stream())))
    assert shown["checkBy"] == format_timestamp(sched.module.NOW + timedelta(days=7))
    assert sched.module.lifecycle_state(world) == "past_due"
    assert len(reasons) == 1 and "has not been checked" in reasons[0]
    ledger.check(tenant, first["entryId"], first["createdBy"], solo=True)
    solo_check = world.db.collection("payment_checks").document(first["entryId"]).get().to_dict()
    after = ledger.coverage(tenant, world.now)
    assert solo_check.get("soloApproval") is True and first["entryId"] in after.covering_entries
    assert after.paid_until > world.now and first["entryId"] in ledger.snapshot(tenant)["cover"]["coveringEntryIds"]



def test_c8_refused_purge_restores_sign_in_and_the_request_says_why(monkeypatch):
    from platform_service.tests import test_account_deletion_emulator as deletion
    import urllib.request
    host = os.environ["FIRESTORE_EMULATOR_HOST"]
    for project in (config.PLATFORM_PROJECT_ID, deletion.PROJECT):
        urllib.request.urlopen(urllib.request.Request(
            f"http://{host}/emulator/v1/projects/{project}/databases/(default)/documents", method="DELETE")).read()
    deletion._call("DELETE", deletion._auth_url(f"/emulator/v1/projects/{deletion.PROJECT}/accounts"))
    world = deletion.World()
    world.member("admin-a", "admin", "A001", "Alice Admin")
    world.member("sup-a", "supervisor", "V001", "Vikram Supervisor")
    world.member("sales-a", "salesman", "S001", "Aisha Rahman")
    deletion.seed_usage(world.db)
    world.request("sup-a")
    accepted = world.run()
    assert accepted["done"]["accept"] == ["sup-a"] and world.disabled("sup-a") is True
    world.db.collection("user_access").document("sup-a").update({"assignedSalesmanCodes": ["S001"]})
    world.now += timedelta(days=31)
    purge = world.run()
    request = world.request_doc("sup-a")
    evidence("C8 purge refused", refused=purge["refused"], status=request["status"], note=request.get("serverNote"),
             restoredFor_equals_createdAt=request.get("restoredFor") == request.get("createdAt"))
    world.now += timedelta(days=1)
    again = world.run()
    evidence("C8 next worker run", due=again["due"], auth_disabled=world.disabled("sup-a"),
             disabledReasons=world.access_doc("sup-a").get("disabledReasons"))
    world.request("sales-a")
    world.run()
    world.set_status("sales-a", "rejected")
    control = world.run()
    evidence("C8 control: a request the admin rejects is cancelled", done=control["done"]["cancel"],
             auth_disabled=world.disabled("sales-a"))
    assert purge["refused"] == ["sup-a"] and again["due"] == {"accept": [], "cancel": [], "shorten": [], "purge": []}
    assert request["status"] == "rejected" and "salespeople" in request["serverNote"]
    assert request["restoredFor"] == request["createdAt"]
    assert world.disabled("sup-a") is False
    assert "deletion_requested" not in world.access_doc("sup-a").get("disabledReasons", [])
    deletion.sign_in_password(deletion.PROJECT, "sup-a@example.com", deletion.PASSWORD)
    assert control["done"]["cancel"] == ["sales-a"]



def test_c12_quote_prices_only_the_package_it_was_approved_for(world, assertion):
    world.db.collection("subscriptions").document(OTHER).update({"planId": "STARTER", "planVersion": 1})
    drafts = f"/staff/v1/companies/{OTHER}/invoices"
    waiting = world.app.post(drafts, json={}, headers=headers(assertion, OPERATOR, "c12-draft-000"))
    evidence("C12 control draft with no quote", status=waiting.status_code)
    asked = ask(world, assertion, "quote.price", {"amountMinor": 500000, "billingInterval": "monthly"}, "c12-quote-001",
                tenant=OTHER, reason="Agreed on the call for STARTER")
    assert asked.status_code == 201, asked.text
    quote = decide(world, assertion, asked.json()["approvalId"], OWNER)
    assert quote.status_code == 200, quote.text
    stored = [row.to_dict() for row in world.db.collection("quotes").stream()][0]
    same = world.app.post(drafts, json=next_period(world, OTHER), headers=headers(assertion, OPERATOR, "c12-draft-same"))
    evidence("C12 control draft for the package the quote was approved for", status=same.status_code,
             amountMinor=same.json().get("amountMinor"), quote_planId=stored.get("planId"))
    world.db.collection("subscriptions").document(OTHER).update({"planId": "TRIAL", "planVersion": 1})
    draft = world.app.post(drafts, json={}, headers=headers(assertion, OPERATOR, "c12-draft-001"))
    evidence("C12 draft after moving the company to another unpriced package", status=draft.status_code,
             detail=draft.json().get("detail"), quote_planId=stored.get("planId"))
    world.db.collection("subscriptions").document(OTHER).update({"planId": "STARTER", "planVersion": 1})
    world.db.collection("quotes").document(stored["quoteId"]).update({"planId": firestore.DELETE_FIELD})
    old = world.app.post(drafts, json=next_period(world, OTHER), headers=headers(assertion, OPERATOR, "c12-draft-old"))
    evidence("C12 old quote with no package", status=old.status_code, amountMinor=old.json().get("amountMinor"))
    assert waiting.status_code == 409 and stored["planId"] == "STARTER"
    assert same.status_code == 201 and same.json()["amountMinor"] == 500000 and same.json()["quoteId"]
    assert draft.status_code == 409 and "new quote for this package" in draft.json()["detail"]
    assert old.status_code == 201 and old.json()["amountMinor"] == 500000



def plan_current(world, plan_id="P1"):
    plan = world.db.collection("plans").document(plan_id).get().to_dict()
    version = world.db.collection("plans").document(plan_id).collection("versions").document(
        str(plan["currentVersion"])).get().to_dict()
    return plan, version


def test_c13_a_price_approval_changes_only_prices(world, assertion):
    direct = world.app.put("/staff/v1/plans/P1", json={**valid_plan_v1(), "name": "P1"},
                           headers=headers(assertion, OPERATOR, "c13-direct-001"))
    evidence("C13 control operator direct plan write", status=direct.status_code)
    before_plan, before = plan_current(world)
    price_only = {**{key: before[key] for key in ("name", "edition", "limits", "features", "tagline", "highlights",
                                                  "sortOrder", "notes") if key in before},
                  "prices": {"currency": "MYR", "monthly": 101, "yearly": 960}}
    asked = ask(world, assertion, "package.price", {"planId": "P1", "version": price_only}, "c13-ask-001",
                who=OPERATOR, tenant=None, reason="Price review")
    assert asked.status_code == 201, asked.text
    done = decide(world, assertion, asked.json()["approvalId"], OPERATOR2)
    plan, current = plan_current(world)
    evidence("C13 price-only approval by two operators", status=done.status_code, currentVersion=plan["currentVersion"],
             prices=current["prices"], limits=current["limits"], name=current["name"])
    assert direct.status_code == 403 and done.status_code == 200
    assert current["prices"]["monthly"] == 101 and current["limits"] == before["limits"]
    assert current["name"] == before["name"] and plan["visibility"] == before_plan["visibility"]
    base = {key: current[key] for key in ("name", "edition", "limits", "features", "tagline", "highlights",
                                          "sortOrder", "notes") if key in current}
    changes = {"limits": {**base, "limits": {"salesmen": 999, "supervisors": 99, "managers": 99, "products": 9999},
                          "prices": {"currency": "MYR", "monthly": 102, "yearly": 960}},
               "name": {**base, "name": "P1 renamed by operators",
                        "prices": {"currency": "MYR", "monthly": 102, "yearly": 960}}}
    for field, version in changes.items():
        refused = ask(world, assertion, "package.price", {"planId": "P1", "version": version}, f"c13-bad-{field}",
                      who=OPERATOR, tenant=None, reason="Price review")
        evidence(f"C13 request that also changes {field}", status=refused.status_code, detail=refused.json().get("detail"))
        assert refused.status_code == 400 and f"the {field} is also different" in refused.json()["detail"]
    shown = ask(world, assertion, "package.price",
                {"planId": "P1", "version": {**base, "prices": {"currency": "MYR", "monthly": 103, "yearly": 960}},
                 "visibility": "public" if plan["visibility"] != "public" else "private"},
                "c13-bad-visibility", who=OPERATOR, tenant=None, reason="Price review")
    assert shown.status_code == 400 and "the visibility is also different" in shown.json()["detail"]
    ok = ask(world, assertion, "package.price",
             {"planId": "P1", "version": {**base, "prices": {"currency": "MYR", "monthly": 104, "yearly": 960}}},
             "c13-late-tamper", who=OPERATOR, tenant=None, reason="Price review")
    assert ok.status_code == 201, ok.text
    stored = world.db.collection("approvals").document(ok.json()["approvalId"])
    tampered = stored.get().to_dict()["params"]
    tampered["content"] = {**tampered["content"], "name": "Tampered after the request"}
    stored.update({"params": tampered})
    late = decide(world, assertion, ok.json()["approvalId"], OPERATOR2)
    evidence("C13 approval whose stored content was changed after the request", status=late.status_code,
             detail=late.json().get("detail"))
    assert late.status_code == 409 and "the name is also different" in late.json()["detail"]
    assert plan_current(world)[1]["name"] == before["name"] and plan_current(world)[1]["prices"]["monthly"] == 101


def test_c13_creating_a_new_package_through_a_price_approval_is_owner_only(world, assertion):
    new_plan = {**valid_plan_v1(), "name": "Brand new"}
    by_operator = ask(world, assertion, "package.price", {"planId": "BRANDNEW", "version": new_plan}, "c13-new-001",
                      who=OPERATOR, tenant=None, reason="New package")
    by_owner = ask(world, assertion, "package.price", {"planId": "BRANDNEW", "version": new_plan}, "c13-new-002",
                   who=OWNER, tenant=None, reason="New package")
    evidence("C13 new package by approval", operator=by_operator.status_code, owner=by_owner.status_code,
             detail=by_operator.json().get("detail"))
    assert by_operator.status_code == 403 and "Only the owner" in by_operator.json()["detail"]
    assert by_owner.status_code == 201, by_owner.text
    done = decide(world, assertion, by_owner.json()["approvalId"], OPERATOR)
    assert done.status_code == 200, done.text
    assert plan_current(world, "BRANDNEW")[1]["name"] == "Brand new"


def test_n02_an_operator_new_package_request_made_before_the_owner_only_rule_cannot_be_approved(world, assertion):
    new_plan = {**valid_plan_v1(), "name": "Older request"}
    asked = ask(world, assertion, "package.price", {"planId": "OLDREQ", "version": new_plan}, "n02-old-001",
                who=OWNER, tenant=None, reason="New package")
    assert asked.status_code == 201, asked.text
    approval_id = asked.json()["approvalId"]
    world.db.collection("approvals").document(approval_id).update(
        {"requestedBy": OPERATOR, "requestedByPerson": OPERATOR, "requestedByRole": firestore.DELETE_FIELD})
    done = decide(world, assertion, approval_id, OWNER)
    stored = world.db.collection("approvals").document(approval_id).get().to_dict()
    evidence("N-02 old operator package request", status=done.status_code, detail=done.json().get("detail"),
             approval=stored["status"])
    assert done.status_code in (403, 409) and "owner" in done.json()["detail"]
    assert stored["status"] == "requested" and not world.db.collection("plans").document("OLDREQ").get().exists

def test_p4_order_owner_script_matches_the_employee_code_and_skips_a_person_whose_old_code_only_matches(world, capsys):
    import importlib.util
    spec = importlib.util.spec_from_file_location("fill_order_owners", Path.cwd() / "scripts" / "fill_order_owners.py")
    script = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(script)
    db = firestore.Client(project=world.store.get(TENANT)["location"]["projectId"], credentials=AnonymousCredentials())
    db.collection("users").document("ux").set({"salesmanCode": "S01", "employeeCode": "S05", "role": "salesman"})
    db.collection("users").document("uy").set({"employeeCode": "S01", "role": "salesman"})
    db.collection("users").document("uz").set({"employeeCode": "S07", "salesmanCode": "S07", "role": "salesman"})
    db.collection("users").document("uw").set({"salesmanCode": "S09", "role": "salesman"})
    for order_id, code in (("o1", "S01"), ("o2", "S07"), ("o3", "S09")):
        db.collection("orders").document(order_id).set({"salesmanCode": code})
    code = script.main(["--project", db.project, "--apply", "--confirm-project", db.project])
    capsys.readouterr()
    owners = {snapshot.id: snapshot.to_dict().get("salesmanUid") for snapshot in db.collection("orders").stream()}
    assert code == 0 and owners == {"o1": "uy", "o2": "uz", "o3": None}


def test_n02_an_owner_new_package_request_made_before_the_role_was_stored_can_be_approved(world, assertion):
    new_plan = {**valid_plan_v1(), "name": "Owner older request"}
    asked = ask(world, assertion, "package.price", {"planId": "OWNOLD", "version": new_plan}, "n02-owner-001",
                who=OWNER, tenant=None, reason="New package")
    assert asked.status_code == 201, asked.text
    approval_id = asked.json()["approvalId"]
    world.db.collection("approvals").document(approval_id).update({"requestedByRole": firestore.DELETE_FIELD})
    done = decide(world, assertion, approval_id, OPERATOR)
    assert done.status_code == 200, done.text
    assert world.db.collection("plans").document("OWNOLD").get().exists


def test_c15_audit_verify_reports_a_surplus_event_as_broken(world):
    log = AuditLog(world.db)
    day = local_date(datetime.now(timezone.utc))
    first = log.record(actor=OWNER, action="regress.one", tenant_id=None, summary="one", key="regress-1")
    second = log.record(actor=OWNER, action="regress.two", tenant_id=None, summary="two", key="regress-2")
    before = log.verify(day)
    total_before = len(log.day_events(day))
    last = log.day_events(day)[-1]
    forged = {"eventId": "evt_" + "f" * 32, "seq": total_before + 1, "at": second["at"], "day": day,
              "actor": "attacker", "action": "payment.checked", "tenantId": TENANT, "summary": "forged", "refs": {},
              "prevHash": last["hash"]}
    forged["hash"] = event_hash(forged)
    world.db.collection(EVENTS).document(forged["eventId"]).set(forged)
    after = log.verify(day)
    total_after = len(log.day_events(day))
    evidence("C15 verify with a surplus event", ok_before=before["ok"], events_before=before["events"],
             stored_before=total_before, ok_after=after["ok"], events_after=after["events"], stored_after=total_after)
    world.db.collection(EVENTS).document(first["eventId"]).update({"summary": "tampered"})
    control = log.verify(day)
    evidence("C15 control tampered first event", ok=control["ok"], firstBroken=control["firstBroken"])
    assert before["ok"] is True and total_before == total_after - 1
    assert after["ok"] is False and after["firstBroken"]["eventId"] == forged["eventId"]
    assert "does not count" in after["firstBroken"]["reason"]
    assert control["ok"] is False


def test_n28_two_companies_writing_at_once_keep_their_own_chains_and_neither_shows_a_false_break(world, capsys):
    import importlib.util
    import json
    import threading
    from platform_service.audit import CHAIN, GENESIS, STARTS
    spec = importlib.util.spec_from_file_location("start_audit_chains", Path.cwd() / "scripts" / "start_audit_chains.py")
    script = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(script)
    log = AuditLog(world.db)
    now = datetime.now(timezone.utc)
    day = local_date(now)
    old_day = local_date(now - timedelta(days=1))
    old = {"eventId": "evt_" + "0" * 32, "seq": 1, "at": format_timestamp(now - timedelta(days=1)), "day": old_day,
           "actor": OWNER, "action": "regress.shared", "tenantId": TENANT, "summary": "old shared day", "refs": {},
           "prevHash": GENESIS}
    old["hash"] = event_hash(old)
    world.db.collection(EVENTS).document(old["eventId"]).set(old)
    world.db.collection(CHAIN).document(old_day).set({"day": old_day, "count": 1, "lastEventId": old["eventId"],
                                                      "lastHash": old["hash"], "seedHash": GENESIS})
    for chain in ("platform", TENANT, OTHER):
        for name in (f"{day}_{chain}",):
            for event in log.day_events(day, chain):
                world.db.collection(EVENTS).document(event["eventId"]).delete()
            world.db.collection(CHAIN).document(name).delete()
    project = world.db.project
    assert script.main(["--project", project]) == 0
    dry = json.loads(capsys.readouterr().out)
    assert not list(world.db.collection(STARTS).stream())
    assert script.main(["--project", project, "--apply", "--confirm-project", project]) == 0
    applied = json.loads(capsys.readouterr().out)
    assert sorted(applied["written"]) == sorted(["platform", TENANT, OTHER])
    errors, checks = [], {TENANT: [], OTHER: []}

    def write(tenant, count):
        try:
            for number in range(count):
                log.record(actor=OWNER, action="regress.busy", tenant_id=tenant, summary="busy",
                           key=f"n28-{tenant}-{number}")
        except Exception as error:
            errors.append(repr(error))

    writers = [threading.Thread(target=write, args=(TENANT, 15)), threading.Thread(target=write, args=(OTHER, 40))]
    for writer in writers:
        writer.start()
    writers[0].join()
    while writers[1].is_alive():
        checks[TENANT].append(log.verify(day, TENANT)["ok"])
    writers[1].join()
    first, second = log.verify(day, TENANT), log.verify(day, OTHER)
    whole, shared = log.verify(day), log.verify(old_day)
    with capsys.disabled():
        evidence("N-28 per-company chains", dry=[(row["chain"], row["status"]) for row in dry["rows"]],
                 written=applied["written"], errors=errors, checks_during_other_writes=len(checks[TENANT]),
                 all_ok=all(checks[TENANT]), first=first, second=second, whole_ok=whole["ok"], shared=shared)
    assert errors == []
    assert checks[TENANT] and all(checks[TENANT])
    assert first["ok"] and first["events"] == 15 and second["ok"] and second["events"] == 40
    assert {event["tenantId"] for event in log.day_events(day, TENANT)} == {TENANT}
    assert {event["tenantId"] for event in log.day_events(day, OTHER)} == {OTHER}
    assert log.day_events(day, TENANT)[0]["prevHash"] == old["hash"] == log.day_events(day, OTHER)[0]["prevHash"]
    assert whole["ok"] is True and shared["ok"] is True and shared["events"] == 1
    world.db.collection(EVENTS).document(log.day_events(day, OTHER)[3]["eventId"]).update({"summary": "tampered"})
    assert log.verify(day, OTHER)["ok"] is False and log.verify(day, TENANT)["ok"] is True



def test_c16_copilot_budget_gives_each_person_their_own_share_of_the_company_pool():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.voice.dashboard_llm.server.app import COMPANY_FULL, PERSON_FULL, TAKEN, GeminiBudget
    project = f"demo-regress-copilot-{uuid.uuid4().hex[:8]}"
    client = firestore.Client(project=project, credentials=AnonymousCredentials())
    day, next_day, old_day = "2026-11-07", "2026-11-09", "2026-11-08"
    heavy, light, dotted = "heavy", "light", "scope/uid.with.dots"
    client.collection("copilot_budget").document("warm-up").get()

    budget = GeminiBudget(client, flush_seconds=0.2)
    heavy_calls = [budget.take("northwind", False, 10, day, heavy, 3) for _ in range(4)]
    light_call = budget.take("northwind", False, 10, day, light, 3)
    dotted_call = budget.take("northwind", False, 10, day, dotted, 3)
    other_company = budget.take("southridge", False, 10, day, heavy, 3)
    budget.close()
    stored = client.collection("copilot_budget").document(f"northwind_{day}").get().to_dict()
    evidence("C16 GeminiBudget.take per person", person_limit=3, heavy=heavy_calls, light=light_call,
             dotted=dotted_call, other_company=other_company, stored=stored)
    assert heavy_calls == [TAKEN, TAKEN, TAKEN, PERSON_FULL]
    assert light_call == dotted_call == other_company == TAKEN
    assert stored["dashboardCalls"] == 5 and sorted(stored["personCalls"].values()) == [1, 1, 3]

    restarted = GeminiBudget(client, flush_seconds=0.2)
    after_restart = [restarted.take("northwind", False, 10, day, heavy, 3),
                     restarted.take("northwind", False, 10, day, dotted, 3)]
    assert after_restart == [PERSON_FULL, TAKEN]
    restarted.give_back("northwind", False, day, dotted)
    assert restarted.take("northwind", False, 10, next_day, heavy, 3) == TAKEN
    restarted.close()
    after_give_back = client.collection("copilot_budget").document(f"northwind_{day}").get().to_dict()
    evidence("C16 give_back returns one call and one person count", stored=after_give_back)
    assert after_give_back["dashboardCalls"] == 5 and sorted(after_give_back["personCalls"].values()) == [1, 1, 3]

    client.collection("copilot_budget").document(f"northwind_{old_day}").set(
        {"company": "northwind", "day": old_day, "dashboardCalls": 4, "salesmanCalls": 0})
    counted_before = GeminiBudget(client, flush_seconds=0.2)
    room = [counted_before.take("northwind", False, 6, old_day, heavy, 3) for _ in range(3)]
    counted_before.close()
    client.close()
    assert room == [TAKEN, TAKEN, COMPANY_FULL]


class Recording:
    def __init__(self):
        self.to = []
        self.messages = []

    def verify(self):
        return None

    def send(self, message, key):
        self.to.append(message["to"])
        self.messages.append(message)
        return "provider-" + key[:12]


class Rejecting(Recording):
    def send(self, message, key):
        raise DeliveryRejected("550 mailbox unavailable", retryable=False)


def bounce_event(job, key, status="hard_bounce", at=None, reason="no such mailbox"):
    return DeliveryEvent(key=key, status=status, at=format_timestamp(at), email=job["recipient"], message_id="",
                         job_hint=job["jobId"], reason=reason)


def reasons_of(sched, world):
    return [op["reason"] for op in sched.module.scheduler_operations(world)]




def test_f40_a_company_that_already_lapsed_stays_lapsed_when_the_delivered_invoice_bounces(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    queued = queue_invoice_mail(sched, w)
    deliver_mail(w.book.mail, now=w.now, transport=Recording())
    assert w.book.get(queued["invoiceId"])["status"] == "sent"
    w.now = sched.module.NOW + timedelta(days=15)
    w.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(w) == "past_due"
    assert record_event(w.db, bounce_event(invoice_jobs(w)[0], "f40-bounce-late", at=w.now)) == "accepted"
    invoice = w.book.get(queued["invoiceId"])
    w.scheduler.run_due(only=["past_due"])
    assert invoice["status"] == "issued" and invoice["delivery"]["state"] == "not_delivered"
    assert sched.module.lifecycle_state(w) == "past_due"






def test_f40_control_send_again_while_the_first_email_is_still_waiting_makes_no_second_mail(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = sched.module.BILLING_TENANT
    queued = queue_invoice_mail(sched, w)
    w.db.collection("companies").document(tenant).update({"billingEmail": "corrected@example.test"})
    w.book.send(queued["invoiceId"], "clerk@example.test")
    assert len(invoice_jobs(w)) == 1 and invoice_jobs(w)[0]["recipient"] == "billing@example.test"






def quoted_company(sched, w, plan_id):
    tenant = sched.module.BILLING_TENANT
    w.db.collection("subscriptions").document(tenant).update({
        "planId": "STARTER", "planVersion": 1, "updatedAt": sched.module.NOW - timedelta(days=1),
        "planSetAt": sched.module.NOW - timedelta(days=1)})
    row = {"quoteId": "quote_" + "b" * 32, "tenantId": tenant, "amountMinor": 500000, "currency": "MYR",
           "billingInterval": "monthly", "status": "approved", "createdAt": sched.module.NOW}
    if plan_id is not None:
        row["planId"] = plan_id
    w.db.collection("quotes").document(row["quoteId"]).set(row)
    w.now = sched.module.NOW + timedelta(days=20)
    return tenant


def test_fix028_an_invoice_fully_covered_by_a_credit_note_is_closed_and_its_period_gets_a_new_renewal_draft(
        sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    w.now = sched.module.NOW + timedelta(days=20)
    assert draft_renewal_invoices(w.db, w.book, now=w.now)["drafted"] == 1
    renewal = next(row for row in w.book.list_invoices(sched.module.BILLING_TENANT) if row["status"] == "draft")
    issued = w.book.issue(renewal["invoiceId"], "clerk@example.test")
    w.book.credit_note(issued["invoiceId"], "fix028-credit-0001",
                       {"amountMinor": issued["amountMinor"], "reason": "Billed in error"}, "owner@example.test")
    closed = w.book.get(issued["invoiceId"])
    counts = draft_renewal_invoices(w.db, w.book, now=w.now)
    drafts = [row for row in w.book.list_invoices(sched.module.BILLING_TENANT) if row["status"] == "draft"]
    evidence("FIX-028 fully credited renewal", status=closed["status"], counts=counts, drafts=len(drafts))
    assert closed["status"] == "void" and closed["outstandingMinor"] == 0
    assert counts["drafted"] == 1 and len(drafts) == 1 and drafts[0]["invoiceId"] != issued["invoiceId"]


def test_fix028_a_credited_invoice_with_a_waiting_payment_closes_when_that_payment_is_voided(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = sched.module.BILLING_TENANT
    w.now = sched.module.NOW + timedelta(days=20)
    assert draft_renewal_invoices(w.db, w.book, now=w.now)["drafted"] == 1
    issued = w.book.issue(next(r for r in w.book.list_invoices(tenant) if r["status"] == "draft")["invoiceId"], CLERK)
    waiting = unchecked_payment(w.db, tenant, issued, w.now)
    w.book.credit_note(issued["invoiceId"], "fix028-wait-0001",
                       {"amountMinor": issued["amountMinor"], "reason": "Billed in error"}, "owner@example.test")
    assert w.book.get(issued["invoiceId"])["status"] == "issued"
    with pytest.raises(CommandProblem, match="Credit notes already cover this invoice"):
        payment_ledger(w.db, w.now).record(
            tenant, "n24-second-0001",
            {"amountMinor": issued["amountMinor"], "currency": "MYR", "externalReference": "BANK/N24-SECOND",
             "invoiceId": issued["invoiceId"], "receivedAt": format_timestamp(w.now), "reason": "Bank statement"},
            CLERK)
    payment_ledger(w.db, w.now).correct(tenant, "fix028-void-0001", waiting["entryId"],
                                        {"reason": "Credited instead"}, CHECKER)
    counts = [draft_renewal_invoices(w.db, w.book, now=w.now) for _ in range(2)]
    rows = w.book.list_invoices(tenant)
    evidence("FIX-028 waiting payment voided", status=w.book.get(issued["invoiceId"])["status"], counts=counts)
    assert w.book.get(issued["invoiceId"])["status"] == "void"
    assert [c["drafted"] for c in counts] == [1, 0]
    assert len([r for r in rows if r["status"] == "draft"]) == 1


def test_fix028_a_draft_the_owner_voids_keeps_stopping_its_period(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = sched.module.BILLING_TENANT
    w.now = sched.module.NOW + timedelta(days=20)
    assert draft_renewal_invoices(w.db, w.book, now=w.now)["drafted"] == 1
    draft = next(r for r in w.book.list_invoices(tenant) if r["status"] == "draft")
    w.book.void_draft(draft["invoiceId"], "owner@example.test")
    before = len(w.book.list_invoices(tenant))
    counts = [draft_renewal_invoices(w.db, w.book, now=w.now) for _ in range(2)]
    rows = w.book.list_invoices(tenant)
    evidence("FIX-028 voided draft", counts=counts, rows=len(rows))
    assert len(rows) == before and not [r for r in rows if r["status"] == "draft"]
    assert [c["drafted"] for c in counts] == [0, 0]
    manual = w.book.issue(w.book.create_draft(tenant, "n23-manual-0001", {"periodStart": draft["periodStart"]},
                                              CLERK)["invoiceId"], CLERK)
    w.book.credit_note(manual["invoiceId"], "n23-credit-0001",
                       {"amountMinor": manual["amountMinor"], "reason": "Billed in error"}, "owner@example.test")
    after = draft_renewal_invoices(w.db, w.book, now=w.now)
    evidence("N-23 credited manual invoice after a stop", counts=after,
             drafts=len([r for r in w.book.list_invoices(tenant) if r["status"] == "draft"]))
    assert after["drafted"] == 0 and not [r for r in w.book.list_invoices(tenant) if r["status"] == "draft"]


@pytest.mark.parametrize("plan_id", [None, "STARTER"])
def test_f42_a_quote_for_the_current_package_or_with_no_package_drafts_the_renewal(sched, monkeypatch, plan_id):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    quoted_company(sched, w, plan_id)
    counts = draft_renewal_invoices(w.db, w.book, now=w.now)
    evidence("F42 renewal draft", plan_id=plan_id, counts=counts)
    assert counts["drafted"] == 1 and counts["blocked"] == 0
    assert list(w.db.collection("renewal_blocks").stream()) == []






@pytest.mark.parametrize("solo", [False, True])
def test_f42_approving_a_quote_request_made_before_the_change_records_the_current_package(world, assertion, monkeypatch, solo):
    monkeypatch.setattr(config, "SOLO_OWNER", solo)
    world.db.collection("subscriptions").document(OTHER).update({"planId": "STARTER", "planVersion": 1})
    who = OWNER if solo else OPERATOR
    asked = ask(world, assertion, "quote.price", {"amountMinor": 500000, "billingInterval": "monthly"}, "f42-quote-001",
                who=who, tenant=OTHER, reason="Agreed with the client")
    assert asked.status_code == 201, asked.text
    stored = world.db.collection("approvals").document(asked.json()["approvalId"])
    params = stored.get().to_dict()["params"]
    params.pop("planId")
    stored.update({"params": params})
    if solo:
        disable_staff(world, OPERATOR)
    done = decide(world, assertion, asked.json()["approvalId"], OWNER)
    quote = [row.to_dict() for row in world.db.collection("quotes").stream()]
    draft = world.app.post(f"/staff/v1/companies/{OTHER}/invoices", json=next_period(world, OTHER),
                           headers=headers(assertion, OWNER if solo else OPERATOR, "f42-draft-001"))
    evidence("F42 pending request approved", solo=solo, approve=done.status_code, detail=done.json().get("detail"),
             quote_plan=[row.get("planId") for row in quote], draft=draft.status_code)
    assert done.status_code == 200 and [row.get("planId") for row in quote] == ["STARTER"]
    assert draft.status_code == 201


def legacy_payment_without_invoice(db, tenant, moment):
    entry_id = "pay_" + "a" * 64
    db.collection("payment_entries").document(entry_id).set({
        "entryId": entry_id, "tenantId": tenant, "type": "payment", "amountMinor": 100, "currency": "MYR",
        "periodStart": moment, "periodEnd": moment + timedelta(days=30), "createdAt": moment,
        "createdBy": "legacy@example.test", "externalReference": "LEGACY/1", "receivedAt": format_timestamp(moment),
        "reason": "Legacy", "revision": 0, "payloadHash": "x" * 64})
    return entry_id


def test_f46_a_payment_with_no_invoice_neither_gives_cover_nor_starts_the_seven_days(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = sched.module.BILLING_TENANT
    stray = legacy_payment_without_invoice(w.db, tenant, sched.module.NOW - timedelta(days=200))
    w.now = sched.module.NOW + timedelta(days=40)
    _, invoice = issued_invoice(w.db, tenant, w.now, "f46-fresh-0001", period_start=format_timestamp(w.now))
    fresh = unchecked_payment(w.db, tenant, invoice, w.now, recorder="operator@example.test")
    ledger = payment_ledger(w.db, w.now)
    cover = ledger.coverage(tenant, w.now)
    shown = ledger.snapshot(tenant)["cover"]
    waiting = [row["entryId"] for row in ledger.awaiting_check()]
    evidence("F46 payment with no invoice", covering=cover.covering_entries, checkBy=shown["checkBy"], waiting=waiting)
    assert stray not in cover.covering_entries and stray not in waiting
    assert fresh["entryId"] in cover.covering_entries and fresh["entryId"] in waiting
    assert shown["checkBy"] == format_timestamp(w.now + timedelta(days=7))


def test_f46_control_an_old_unchecked_payment_with_an_invoice_still_makes_a_fresh_payment_lapse(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=False)
    tenant = sched.module.BILLING_TENANT
    w.now = sched.module.NOW + timedelta(days=90)
    _, invoice = issued_invoice(w.db, tenant, w.now, "f46-fresh-0002", period_start=format_timestamp(w.now))
    fresh = unchecked_payment(w.db, tenant, invoice, w.now, recorder="operator@example.test")
    ledger = payment_ledger(w.db, w.now)
    old = ledger.list_entries(tenant)[0]["entryId"]
    assert old in [row["entryId"] for row in ledger.awaiting_check()]
    assert fresh["entryId"] not in ledger.coverage(tenant, w.now).covering_entries
    w.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(w) == "past_due"


def delivery_of(w, queued):
    return w.book.get(queued["invoiceId"])


def accepted_invoice(sched, w):
    queued = queue_invoice_mail(sched, w)
    deliver_mail(w.book.mail, now=w.now, transport=Recording())
    return queued




def test_n04_an_invoice_email_sent_again_more_than_20_times_shows_delivered_once_it_arrives(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    queued = queue_invoice_mail(sched, w)
    for _ in range(21):
        for row in w.db.collection("mail_jobs").stream():
            job = row.to_dict()
            if job["kind"] == "invoice" and not job.get("retriedAs"):
                row.reference.update({"status": "failed", "lastFailure": "simulated failure"})
        w.book.send(queued["invoiceId"], CLERK)
    deliver_mail(w.book.mail, now=w.now, transport=Recording())
    invoice = w.book.get(queued["invoiceId"])
    evidence("N-04 after 21 resends", jobs=len(invoice_jobs(w)), status=invoice["status"],
             delivery=invoice["delivery"])
    assert len(invoice_jobs(w)) == 22
    assert invoice["status"] == "sent" and invoice["delivery"]["state"] == "delivered"


def test_b2_a_complaint_after_delivery_does_not_clear_the_due_date_but_still_blocks_the_address(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    queued = accepted_invoice(sched, w)
    job = invoice_jobs(w)[0]
    record_event(w.db, bounce_event(job, "b2-delivered", status="delivered", at=w.now, reason=""))
    before = delivery_of(w, queued)
    w.now = sched.module.NOW + timedelta(days=13)
    assert record_event(w.db, bounce_event(job, "b2-complaint", status="spam", at=w.now, reason="")) == "accepted"
    after = delivery_of(w, queued)
    evidence("B2 complaint after delivery", before=before["dueAt"], after=after["dueAt"], delivery=after["delivery"])
    assert after["status"] == "sent" and after["dueAt"] == before["dueAt"] and after["delivery"]["state"] == "delivered"
    suppressed = [row.to_dict() for row in w.db.collection("mail_suppressions").stream()]
    assert [row["reason"] for row in suppressed] == ["spam"]




def test_b3_a_bounced_renewal_bill_stops_the_company_going_past_due_when_cover_ends_and_reaches_staff(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    queued = accepted_invoice(sched, w)
    record_event(w.db, bounce_event(invoice_jobs(w)[0], "b3-hard", at=w.now))
    assert delivery_of(w, queued)["delivery"]["state"] == "not_delivered"
    w.now = sched.module.NOW + timedelta(days=35)
    w.scheduler.run_due(only=["past_due"])
    counts = staff_open_items(w.db, payment_ledger(w.db, w.now), w.now, None)
    evidence("B3 bounced bill, cover ended", lifecycle=sched.module.lifecycle_state(w), reasons=reasons_of(sched, w),
             counts=counts)
    assert sched.module.lifecycle_state(w) == "active" and reasons_of(sched, w) == []
    assert counts["invoicesToSend"] == 1


def test_b4_a_company_past_due_for_an_overdue_bill_returns_to_active_when_that_bill_bounces(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    queued = accepted_invoice(sched, w)
    w.now = sched.module.NOW + timedelta(days=15)
    w.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(w) == "past_due"
    assert "after delivery" in w.store.get(sched.module.BILLING_TENANT)["reason"]
    record_event(w.db, bounce_event(invoice_jobs(w)[0], "b4-hard", at=w.now))
    w.now += timedelta(hours=1)
    w.scheduler.run_due(only=["past_due"])
    stored = w.store.get(sched.module.BILLING_TENANT)
    audits = [row.to_dict() for row in w.db.collection("audit_events").stream()
              if row.to_dict().get("action") == "lifecycle.transitioned"
              and row.to_dict()["refs"].get("previousState") == "past_due"]
    evidence("B4 lapsed then bounce", lifecycle=stored["state"], reason=stored["reason"], audits=len(audits))
    assert stored["state"] == "active" and "after delivery" not in stored["reason"]
    assert len(audits) == 1 and audits[0]["refs"]["state"] == "active"
    w.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(w) == "active"


def test_n01_a_past_due_company_whose_overdue_bill_bounces_after_cover_ended_loses_the_after_delivery_reason(
        sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    accepted_invoice(sched, w)
    w.now = sched.module.NOW + timedelta(days=35)
    w.scheduler.run_due(only=["past_due"])
    before = w.store.get(sched.module.BILLING_TENANT)
    assert before["state"] == "past_due" and "after delivery" in before["reason"]
    record_event(w.db, bounce_event(invoice_jobs(w)[0], "n01-hard", at=w.now))
    w.now += timedelta(hours=1)
    w.scheduler.run_due(only=["past_due"])
    stored = w.store.get(sched.module.BILLING_TENANT)
    evidence("N-01 bounce after cover ended", state=stored["state"], reason=stored["reason"])
    assert stored["state"] == "past_due" and stored["graceEndsAt"] == before["graceEndsAt"]
    assert "after delivery" not in stored["reason"] and "not delivered" in stored["reason"]
    w.scheduler.run_due(only=["past_due"])
    assert w.store.get(sched.module.BILLING_TENANT)["reason"] == stored["reason"]


@pytest.mark.parametrize("solo", [False, True])
def test_n01_only_a_bounced_bill_says_not_delivered_and_the_reason_returns_once_the_bill_is_delivered(
        sched, monkeypatch, solo):
    monkeypatch.setattr(config, "SOLO_OWNER", solo)
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant, other = sched.module.BILLING_TENANT, "t_n01other"
    _, other_first = issued_invoice(w.db, other, sched.module.NOW, "n01-other-first-0001")
    receipt = checked_payment(w.db, other, other_first, sched.module.NOW)
    w.store.transition(other, "active", operation_id="n01-other-activate", actor="owner@example.test",
                       reason="Paid", ticket=None, now=sched.module.NOW, activation_receipt_id=receipt["entryId"])
    w.now = sched.module.NOW + timedelta(days=35)
    w.store.transition(other, "past_due", operation_id="n01-other-past-due", actor="scheduler",
                       reason="Paid cover ended on 2026-11-30.", ticket=None, now=w.now)
    w.scheduler.run_due(only=["past_due"])
    lapsed, other_lapsed = w.store.get(tenant), w.store.get(other)
    queued = queue_invoice_mail(sched, w)
    w.now += timedelta(hours=1, minutes=1)
    w.scheduler.run_due(only=["past_due"])
    sending = w.store.get(tenant)
    deliver_mail(w.book.mail, now=w.now, transport=Recording())
    record_event(w.db, bounce_event(invoice_jobs(w)[0], "n01-resend-hard", at=w.now))
    w.now += timedelta(hours=1, minutes=1)
    w.scheduler.run_due(only=["past_due"])
    bounced = w.store.get(tenant)
    for row in list(w.db.collection("mail_suppressions").stream()):
        row.reference.delete()
    w.book.send(queued["invoiceId"], CLERK)
    deliver_mail(w.book.mail, now=w.now, transport=Recording())
    w.now += timedelta(hours=1, minutes=1)
    w.scheduler.run_due(only=["past_due"])
    delivered, other_after = w.store.get(tenant), w.store.get(other)
    evidence("N-01 sending, bounced, delivered", lapsed=lapsed["reason"], sending=sending["reason"],
             bounced=bounced["reason"], delivered=delivered["reason"],
             invoice=w.book.get(queued["invoiceId"])["delivery"]["state"], other=other_after["reason"])
    assert lapsed["state"] == "past_due" and sending["reason"] == lapsed["reason"]
    assert "not delivered" in bounced["reason"] and bounced["graceEndsAt"] == lapsed["graceEndsAt"]
    assert w.book.get(queued["invoiceId"])["delivery"]["state"] == "delivered"
    assert delivered["state"] == "past_due" and delivered["reason"] == lapsed["reason"]
    assert delivered["graceEndsAt"] == lapsed["graceEndsAt"]
    assert other_lapsed == other_after and "not delivered" not in other_after["reason"]


@pytest.mark.parametrize("solo", [False, True])
def test_b13_a_void_of_an_unchecked_payment_lapses_the_company_and_the_correct_payment_returns_it_to_active(sched, monkeypatch, solo):
    monkeypatch.setattr(config, "SOLO_OWNER", solo)
    w = sched.module.build_billing(sched, monkeypatch, checked=False)
    tenant = sched.module.BILLING_TENANT
    ledger = payment_ledger(w.db, w.now)
    first_entry = ledger.list_entries(tenant)[0]
    ledger.correct(tenant, "b13-void-0001", first_entry["entryId"], {"reason": "Typing mistake"},
                   first_entry["createdBy"] if solo else "owner@example.test", solo=solo)
    w.now = sched.module.NOW + timedelta(hours=1)
    w.scheduler.run_due(only=["past_due"])
    assert sched.module.lifecycle_state(w) == "past_due"
    assert len(sched.module.mails(w, "past_due")) == 1
    row = w.db.collection("invoices").document(w.first["invoiceId"]).get().to_dict()
    entry = payment_ledger(w.db, w.now).record(tenant, "b13-record-0002", {
        "amountMinor": row["amountMinor"], "currency": "MYR", "externalReference": "BANK/B13-RIGHT",
        "invoiceId": w.first["invoiceId"], "receivedAt": format_timestamp(w.now), "reason": "Right line"},
        "operator@example.test")
    payment_ledger(w.db, w.now).check(tenant, entry["entryId"], "checker@example.test")
    w.now += timedelta(hours=1)
    w.scheduler.run_due(only=["past_due"])
    stored = w.store.get(tenant)
    evidence("B13 correct payment after a void", solo=solo, lifecycle=stored["state"], reason=stored["reason"])
    assert stored["state"] == "active" and "voided" not in stored["reason"]
    assert len(sched.module.mails(w, "past_due")) == 1


def test_b10_the_emails_tab_retry_of_an_invoice_job_uses_the_current_billing_email_and_the_resend_date(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = sched.module.BILLING_TENANT
    queued = queue_invoice_mail(sched, w)
    deliver_mail(w.book.mail, now=w.now, transport=Rejecting())
    first = invoice_jobs(w)[0]
    w.db.collection("companies").document(tenant).update({"billingEmail": "corrected@example.test"})
    w.now = sched.module.NOW + timedelta(days=20)
    w.book.mail.retry(tenant, first["jobId"], "clerk@example.test")
    transport = Recording()
    deliver_mail(w.book.mail, now=w.now, transport=transport)
    invoice = delivery_of(w, queued)
    sent = [job for job in invoice_jobs(w) if job["status"] == "sent"][0]
    evidence("B10 retry from the company Emails tab", mailed_to=transport.to, stored_due=invoice["dueAt"],
             mailed_due=sent["payload"]["dueAt"])
    assert transport.to == ["corrected@example.test"] and invoice["status"] == "sent"
    assert sent["payload"]["dueAt"] == local_date(w.now + timedelta(days=14)) == invoice["dueAt"][:10]
    assert base64.b64decode(sent["attachment"]["content"]).startswith(b"%PDF")




def test_b12_a_quote_with_no_package_does_not_price_a_package_the_company_moved_to_after_the_quote(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = quoted_company(sched, w, None)
    w.db.collection("subscriptions").document(tenant).update({
        "planId": "TRIAL", "planVersion": 1, "updatedAt": sched.module.NOW + timedelta(days=2),
        "planSetAt": sched.module.NOW + timedelta(days=2)})
    counts = draft_renewal_invoices(w.db, w.book, now=w.now)
    block = w.db.collection("renewal_blocks").document(tenant).get().to_dict()
    evidence("B12 planless quote after a package change", counts=counts, reason=block and block["reason"])
    assert counts["drafted"] == 0 and counts["blocked"] == 1
    assert [row for row in w.book.list_invoices(tenant) if row["status"] == "draft"] == []


def test_b12_an_approved_override_on_the_same_package_keeps_the_quote_with_no_package(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    tenant = quoted_company(sched, w, None)
    moment = sched.module.NOW + timedelta(days=2)
    override = clean_override({"limits": {"salesmen": 8}, "reason": "Two extra reps for the trade fair",
                               "expiresAt": format_timestamp(moment + timedelta(days=7))},
                              now=moment, actor="ops@example.test")
    PlanStore(w.db).apply_subscription_change(tenant, override, operation_id="b12-override-0001", now=moment)
    counts = draft_renewal_invoices(w.db, w.book, now=w.now)
    drafts = [row["amountMinor"] for row in w.book.list_invoices(tenant) if row["status"] == "draft"]
    evidence("B12 same-package override after a planless quote", counts=counts, drafts=drafts)
    assert counts["drafted"] == 1 and drafts == [500000]




OTHER_TENANT = "t_otherco"


def add_second_company(sched, w):
    signer = Signer.generate("scheduler-other")
    directory = DirectoryStore(w.db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    directory.put({
        "tenantId": OTHER_TENANT, "workspace": "otherco", "legalName": "Other Co Sdn Bhd",
        "companyCode": "otherco", "location": {"projectId": f"demo-oc-{w.project[-8:]}",
                                                "databaseId": "(default)", "authTenantId": None},
        "locationKind": "byo",
        "clientConfig": {"apiKey": {"web": "AIza" + "C" * 35}, "appId": {"web": "1:333333333333:web:dddddddddddddddd"},
                         "messagingSenderId": "333333333333"},
        "status": "live", "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1",
    }, expected_version=0, now=sched.module.NOW)
    directory.set_billing_email(OTHER_TENANT, "billing@other.example.test")
    _, first = issued_invoice(w.db, OTHER_TENANT, sched.module.NOW, "other-first-0001")
    receipt = checked_payment(w.db, OTHER_TENANT, first, sched.module.NOW)
    w.store.transition(OTHER_TENANT, "active", operation_id="other-activate-0001", actor="owner@example.test",
                       reason="Paid", ticket=None, now=sched.module.NOW, activation_receipt_id=receipt["entryId"])
    return first


def state_of(w, tenant):
    return w.store.get(tenant)["state"]


def test_two_companies_a_bounce_a_lapse_and_a_payment_in_one_company_never_change_the_other(sched, monkeypatch):
    w = sched.module.build_billing(sched, monkeypatch, checked=True)
    other_first = add_second_company(sched, w)
    mine = sched.module.BILLING_TENANT
    queued = accepted_invoice(sched, w)
    record_event(w.db, bounce_event(invoice_jobs(w)[0], "two-co-bounce", at=w.now))
    w.now = sched.module.NOW + timedelta(days=35)
    w.scheduler.run_due(only=["past_due"])
    evidence("TWO COMPANIES bounced bill and lapse", billing=state_of(w, mine), other=state_of(w, OTHER_TENANT))
    assert state_of(w, mine) == "active"
    assert state_of(w, OTHER_TENANT) == "past_due"
    assert "Paid cover ended" in w.store.get(OTHER_TENANT)["reason"]
    counts = staff_open_items(w.db, payment_ledger(w.db, w.now), w.now, None)
    assert counts["invoicesToSend"] == 1 and counts["companiesPastDue"] == 1
    w.now += timedelta(hours=2)
    _, renewal = issued_invoice(w.db, OTHER_TENANT, w.now, "other-renew-0002", period_start=other_first["periodEnd"])
    checked_payment(w.db, OTHER_TENANT, renewal, w.now)
    w.scheduler.run_due(only=["past_due"])
    assert state_of(w, OTHER_TENANT) == "active"
    assert state_of(w, mine) == "active"
    assert delivery_of(w, queued)["delivery"]["state"] == "not_delivered"
    after = staff_open_items(w.db, payment_ledger(w.db, w.now), w.now, None)
    assert after["invoicesToSend"] == 1 and after["companiesPastDue"] == 0




def test_c16_a_damaged_copilot_person_record_never_gives_extra_calls():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.voice.dashboard_llm.server.app import COMPANY_FULL, PERSON_FULL, TAKEN, GeminiBudget
    project = f"demo-regress-copilot-damaged-{uuid.uuid4().hex[:8]}"
    client = firestore.Client(project=project, credentials=AnonymousCredentials())
    day, limit = "2026-11-07", 3
    client.collection("copilot_budget").document(f"northwind_{day}").set(
        {"company": "northwind", "day": day, "dashboardCalls": 2, "salesmanCalls": 0,
         "personCalls": {"full": limit, "garbled": "abc", "negative": -4, "unset": None}})
    for company, damaged in (("southridge", ["not", "a", "map"]), ("eastbay", "text"), ("westfield", 7)):
        client.collection("copilot_budget").document(f"{company}_{day}").set(
            {"company": company, "day": day, "dashboardCalls": 9, "salesmanCalls": 0, "personCalls": damaged})
    budget = GeminiBudget(client, flush_seconds=0.2)
    outcomes = {
        "full": budget.take("northwind", False, 10, day, "full", limit),
        "valid_newcomer": budget.take("northwind", False, 10, day, "newcomer", limit),
        "garbled": budget.take("northwind", False, 10, day, "garbled", limit),
        "negative": budget.take("northwind", False, 10, day, "negative", limit),
        "unset": budget.take("northwind", False, 10, day, "unset", limit),
    }
    company_level = {company: [budget.take(company, False, 10, day, "anyone", limit) for _ in range(2)]
                     for company in ("southridge", "eastbay", "westfield")}
    budget.close()
    stored = client.collection("copilot_budget").document(f"northwind_{day}").get().to_dict()
    evidence("C16 damaged personCalls", outcomes=outcomes, company_level=company_level, stored=stored)
    client.close()
    assert outcomes["full"] == PERSON_FULL
    assert set(outcomes.values()) - {PERSON_FULL} == {TAKEN}
    assert stored["dashboardCalls"] == 6 and stored["personCalls"]["full"] == limit
    assert all(result == [TAKEN, COMPANY_FULL] for result in company_level.values())

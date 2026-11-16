
















from __future__ import annotations

import base64
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore
from google.cloud.firestore_v1.query import Query

from platform_service import config, staff_api
from platform_service.company_access import company_access
from platform_service.directory import DirectoryStore
from platform_service.mail import MailQueue, StubTransport, deliver_mail
from platform_service.operations import OperationStore
from platform_service.payments import PaymentLedger
from platform_service.ids import command_id
from platform_service.signing import Keyring, Signer, format_timestamp
from platform_service.tests.support import seed_subscription, staff_assertion, staff_domains

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"),
    reason="Needs the assigned shared Firestore emulator.",
)

OWNER = "owner@example.com"
OPERATOR = "operator@example.com"
SUPPORT = "support@example.com"
ENGINEER = "engineer@example.com"
OWNER_SECOND_LOGIN = "owner.second@example.com"
THIRD_APPROVER = "third@example.com"
UNMAPPED = "unmapped@example.com"
TENANT = "t_northwind"
OTHER = "t_southridge"
RECEIVED = format_timestamp(datetime.now(timezone.utc))
AMOUNT = 10000
INVOICE = {TENANT: command_id("inv", TENANT, "api-invoice-0001", "invoice.draft"),
           OTHER: command_id("inv", OTHER, "api-invoice-0001", "invoice.draft")}


ROLES = {OWNER: "owner", OPERATOR: "operator", SUPPORT: "support", ENGINEER: "engineer",
         OWNER_SECOND_LOGIN: "operator", THIRD_APPROVER: "operator"}


@pytest.fixture(autouse=True)
def staff_settings(monkeypatch):
    monkeypatch.setattr(config, "STAFF_DOMAINS", staff_domains({*ROLES, UNMAPPED}))


@pytest.fixture
def assertion():
    return staff_assertion(ROLES)


@pytest.fixture
def world(monkeypatch, assertion):
    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    monkeypatch.setenv("PLATFORM_MAIL_TRANSPORT", "stub")
    project = f"demo-v4-payment-api-{uuid.uuid4().hex[:12]}"
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", project)
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    signer = Signer.generate("payment-api-test")
    store = DirectoryStore(db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    for tenant, slug in ((TENANT, "northwind"), (OTHER, "southridge")):
        company_project = f"demo-{slug}-{project[-8:]}"
        store.put({
            "tenantId": tenant, "workspace": slug, "legalName": f"{slug} Foods Sdn Bhd",
            "companyCode": slug, "location": {"projectId": company_project,
            "databaseId": "(default)", "authTenantId": None}, "locationKind": "byo",
            "clientConfig": {"apiKey": {"android": "AIza" + "A" * 35,
                                           "web": "AIza" + "B" * 35},
                             "appId": {"android": "1:222222222222:android:aaaaaaaaaaaaaaaa",
                                       "web": "1:222222222222:web:cccccccccccccccc"},
                             "messagingSenderId": "222222222222",
                             "storageBucket": f"{company_project}.firebasestorage.app"},
            "status": "live", "planRef": "standard", "releaseRing": "general",
            "rulesVersion": "r1",
        }, expected_version=0)
    app = TestClient(staff_api.create_app(
        store=store, operations=OperationStore(db), signer=signer, client=db,
    ))
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


def price_only_version(world, plan_id, monthly, yearly):
    plan = world.db.collection("plans").document(plan_id).get().to_dict()
    current = world.db.collection("plans").document(plan_id).collection("versions").document(
        str(plan["currentVersion"])).get().to_dict()
    kept = ("name", "edition", "limits", "quotaSchemaVersion", "features", "tagline", "highlights", "sortOrder", "notes")
    return {**{key: current[key] for key in kept if key in current},
            "prices": {"currency": "MYR", "monthly": monthly, "yearly": yearly}}


def approved(world, assertion, action, params, key, *, requester=OPERATOR, approver=OWNER, tenant=TENANT,
             reason="Agreed with the client"):
    asked = ask(world, assertion, action, params, key, who=requester, tenant=tenant, reason=reason)
    assert asked.status_code == 201, asked.text
    return decide(world, assertion, asked.json()["approvalId"], approver)


def void_by_approval(world, assertion, entry_id, key, *, tenant=TENANT, requester=OPERATOR, approver=OWNER,
                     reason="Wrong"):
    return approved(world, assertion, "payment.void", {"receiptId": entry_id}, key,
                    requester=requester, approver=approver, tenant=tenant, reason=reason)


def payment(tenant=TENANT, **changes):
    return {"amountMinor": AMOUNT, "currency": "MYR",
            "externalReference": "BANK/API-TRANSFER-001",
            "invoiceId": INVOICE[tenant],
            "receivedAt": RECEIVED,
            "reason": "Manual bank confirmation", **changes}


def payment_path(tenant=TENANT):
    return f"/staff/v1/companies/{tenant}/payments"


def lifecycle_path(tenant=TENANT):
    return f"/staff/v1/companies/{tenant}/lifecycle"


def valid_plan_v1():
    return {
        "name": "API Permission Plan", "edition": "basic",
        "limits": {"salesmen": 2, "supervisors": 1, "managers": 1, "products": 60},
        "features": {}, "prices": {"currency": "MYR", "monthly": 100, "yearly": 960},
        "tagline": "T", "highlights": ["x"], "sortOrder": 10, "notes": "",
    }


def test_payment_routes_are_staff_only(world, assertion):
    path = payment_path()
    assert world.app.get(path, headers=headers(assertion)).status_code == 200
    assert world.app.get(path).status_code == 401
    assert world.app.get(path, headers={"Authorization": "Bearer firebase-only"}).status_code == 401
    assert world.app.post(path, json=payment(), headers=headers(assertion, key="payment-key-001")).status_code == 201


@pytest.mark.parametrize("email", [SUPPORT, UNMAPPED])
def test_support_and_unmapped_staff_are_refused(world, assertion, email):
    response = world.app.get(payment_path(), headers=headers(assertion, email))
    assert response.status_code == 403


def test_operator_can_record_and_void_only_what_another_person_recorded(world, assertion):
    posted = world.app.post(payment_path(), json=payment(),
                            headers=headers(assertion, OPERATOR, "operator-pay-001"))
    assert posted.status_code == 201
    receipt = posted.json()
    assert receipt["createdBy"] == OPERATOR
    direct = world.app.post(f"{payment_path()}/{receipt['entryId']}/void",
                            json={"reason": "Correction"},
                            headers=headers(assertion, OPERATOR, "operator-void-001"))
    assert direct.status_code == 409 and direct.json()["approvalAction"] == "payment.void"
    own_request = ask(world, assertion, "payment.void", {"receiptId": receipt["entryId"]}, "operator-void-ask-001")
    assert own_request.status_code == 201
    assert decide(world, assertion, own_request.json()["approvalId"], OPERATOR).status_code == 409
    owner_payment = world.app.post(payment_path(OTHER), json=payment(OTHER, externalReference="BANK/OWNER-OTHER"),
                                   headers=headers(assertion, OWNER, "owner-pay-0001"))
    assert owner_payment.status_code == 201
    recorder_cannot_decide = ask(world, assertion, "payment.void", {"receiptId": owner_payment.json()["entryId"]},
                                 "operator-void-002", tenant=OTHER)
    assert recorder_cannot_decide.status_code == 409
    assert "cannot approve its void" in recorder_cannot_decide.json()["detail"]
    operator_void = void_by_approval(world, assertion, owner_payment.json()["entryId"], "operator-void-003",
                                     tenant=OTHER, requester=OWNER, approver=OPERATOR)
    assert operator_void.status_code == 200 and operator_void.json()["operation"]["status"] == "completed"
    entries = world.app.get(payment_path(OTHER), headers=headers(assertion)).json()["entries"]
    assert [entry["createdBy"] for entry in entries if entry["type"] == "void"] == [OPERATOR]
    support_request = ask(world, assertion, "payment.void", {"receiptId": receipt["entryId"]}, "support-void-001",
                          who=SUPPORT)
    assert support_request.status_code == 403
    retired = world.app.post(f"{payment_path()}/review", json={"expectedRevision": 1, "reason": "Checked"},
                             headers=headers(assertion, OWNER, "owner-review-001"))
    assert retired.status_code in (404, 405)





def test_fix_297_a_void_the_non_recorder_asks_for_is_decided_by_another_approver_and_the_recorder_sees_no_approve(
        world, assertion):
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OWNER, "fix297-record"))
    assert recorded.status_code == 201, recorded.text
    entry = recorded.json()["entryId"]
    stuck = ask(world, assertion, "payment.void", {"receiptId": entry}, "fix297-ask-alone", who=OPERATOR)
    assert stuck.status_code == 409
    assert "Ask them to request it" in stuck.json()["detail"]
    assert world.app.get("/staff/v1/approvals", headers=headers(assertion, THIRD_APPROVER)).status_code == 200
    asked = ask(world, assertion, "payment.void", {"receiptId": entry}, "fix297-ask", who=OPERATOR)
    assert asked.status_code == 201, asked.text
    approval_id = asked.json()["approvalId"]
    can_decide = {who: world.app.get(f"/staff/v1/approvals/{approval_id}", headers=headers(assertion, who)).json()["canDecide"]
                  for who in (OWNER, OPERATOR, THIRD_APPROVER)}
    assert can_decide == {OWNER: False, OPERATOR: False, THIRD_APPROVER: True}
    done = decide(world, assertion, approval_id, THIRD_APPROVER)
    assert done.status_code == 200 and done.json()["operation"]["status"] == "completed"


@pytest.mark.parametrize("solo_setting", [True, False])
def test_fix_297_d_a_void_is_refused_when_the_only_other_approver_is_the_recorders_second_login(
        world, assertion, monkeypatch, solo_setting):
    monkeypatch.setattr(config, "SOLO_OWNER", solo_setting)
    same_person_login(world, assertion, OWNER_SECOND_LOGIN, OWNER)
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OWNER, "fix297d-record"))
    assert recorded.status_code == 201, recorded.text
    asked = ask(world, assertion, "payment.void", {"receiptId": recorded.json()["entryId"]}, "fix297d-ask", who=OPERATOR)
    assert asked.status_code == 409
    assert "Ask them to request it" in asked.json()["detail"]
    assert world.db.collection("approvals").get() == []


@pytest.mark.parametrize("solo_setting", [True, False])
def test_screens_read_what_each_caller_may_do_from_the_server_in_each_company(
        world, assertion, monkeypatch, solo_setting):
    monkeypatch.setattr(config, "SOLO_OWNER", solo_setting)
    world.db.collection("invoices").document(INVOICE[OTHER]).update(
        {"status": "sent", "dueAt": datetime.now(timezone.utc) + timedelta(days=14)})
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OPERATOR, "may-do-001"))
    assert recorded.status_code == 201, recorded.text
    entry = recorded.json()["entryId"]
    for who, may_check in ((OPERATOR, False), (OWNER, True)):
        listed = world.app.get(payment_path(), headers=headers(assertion, who)).json()["entries"]
        assert [(row["entryId"], row["canCheck"]) for row in listed] == [(entry, may_check)]
        waiting = world.app.get("/staff/v1/payments/to-check", headers=headers(assertion, who)).json()["payments"]
        assert [(row["entryId"], row["canCheck"]) for row in waiting] == [(entry, may_check)]
        assert world.app.get(payment_path(OTHER), headers=headers(assertion, who)).json()["entries"] == []
        invoices = {row["tenantId"]: row for row in world.app.get(
            "/staff/v1/invoices", headers=headers(assertion, who)).json()["invoices"]}
        assert [invoices[TENANT][name] for name in ("pendingEntryId", "graceUsed", "canExtend")] == [entry, True, False]
        assert [invoices[OTHER][name] for name in ("pendingEntryId", "graceUsed", "canExtend")] == [None, False, True]
        one = world.app.get(f"/staff/v1/invoices/{INVOICE[OTHER]}", headers=headers(assertion, who)).json()
        assert (one["pendingEntryId"], one["graceUsed"], one["canExtend"]) == (None, False, True)
    drafted = world.app.post("/staff/v1/onboarding-drafts", json={"legalName": "May Do Trading", "workspace": "maydo"},
                             headers=headers(assertion, OPERATOR, "may-do-draft"))
    assert drafted.status_code == 201, drafted.text
    assert drafted.json()["canExtend"] is False
    for who, may_extend in ((OPERATOR, False), (OWNER, True)):
        drafts = world.app.get("/staff/v1/onboarding-drafts", headers=headers(assertion, who)).json()["drafts"]
        assert [row["canExtend"] for row in drafts] == [may_extend]
        one = world.app.get(f"/staff/v1/onboarding-drafts/{drafted.json()['draftId']}", headers=headers(assertion, who))
        assert one.json()["canExtend"] is may_extend
    checked = world.app.post(f"{payment_path()}/{entry}/check", headers=headers(assertion, OWNER))
    assert checked.status_code == 200, checked.text
    listed = world.app.get(payment_path(), headers=headers(assertion, OWNER)).json()["entries"]
    assert [row["canCheck"] for row in listed] == [False]


def test_record_retry_is_immutable_and_changed_payload_conflicts(world, assertion):
    key = "retry-payment-001"
    first = world.app.post(payment_path(), json=payment(), headers=headers(assertion, key=key))
    replay = world.app.post(payment_path(), json=payment(), headers=headers(assertion, key=key))
    changed = world.app.post(payment_path(), json=payment(amountMinor=12501),
                             headers=headers(assertion, key=key))
    assert first.status_code == replay.status_code == 201
    assert replay.json() == first.json()
    assert changed.status_code == 409
    listed = world.app.get(payment_path(), headers=headers(assertion))
    assert len(listed.json()["entries"]) == 1


def test_directory_and_receipt_boundaries_prevent_cross_company_access(world, assertion):
    missing = world.app.get(payment_path("t_unknown"), headers=headers(assertion))
    assert missing.status_code == 404
    posted = world.app.post(payment_path(), json=payment(),
                            headers=headers(assertion, key="boundary-pay-001"))
    assert posted.status_code == 201
    receipt_id = posted.json()["entryId"]
    other_listing = world.app.get(payment_path(OTHER), headers=headers(assertion))
    assert other_listing.status_code == 200
    assert other_listing.json()["entries"] == []
    cross_void = ask(world, assertion, "payment.void", {"receiptId": receipt_id}, "cross-void-001",
                     tenant=OTHER, reason="Wrong company")
    assert cross_void.status_code == 409
    original = world.app.get(payment_path(), headers=headers(assertion)).json()["entries"]
    assert len(original) == 1 and original[0]["entryId"] == receipt_id
















def test_payment_and_activation_are_separate_and_activation_needs_usable_coverage(world, assertion):
    other = world.app.post(
        payment_path(OTHER),
        json=payment(OTHER, externalReference="LIFECYCLE-WRONG-TENANT"),
        headers=headers(assertion, OPERATOR, "lifecycle-other-payment"),
    ).json()
    assert world.app.get(lifecycle_path(), headers=headers(assertion, OPERATOR)).status_code == 404
    wrong_tenant = world.app.put(
        lifecycle_path(),
        json={"state": "active", "expectedRevision": 0,
              "paymentEntryId": other["entryId"], "reason": "Paid activation", "ticket": None},
        headers=headers(assertion, OPERATOR, "lifecycle-other-set"),
    )
    voided = world.app.post(
        payment_path(),
        json=payment(externalReference="LIFECYCLE-VOIDED"),
        headers=headers(assertion, OPERATOR, "lifecycle-voided-pay"),
    ).json()
    assert void_by_approval(world, assertion, voided["entryId"], "lifecycle-voided-void").status_code == 200
    voided_set = world.app.put(
        lifecycle_path(),
        json={"state": "active", "expectedRevision": 0,
              "paymentEntryId": voided["entryId"], "reason": "Paid activation", "ticket": None},
        headers=headers(assertion, OPERATOR, "lifecycle-voided-set"),
    )
    assert wrong_tenant.status_code == voided_set.status_code == 409
    assert world.app.get(lifecycle_path(), headers=headers(assertion)).status_code == 404

















def test_a_payment_recorded_again_after_a_void_cannot_activate_before_it_is_checked(world, assertion):
    first = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OPERATOR, "regrace-pay-001"))
    assert void_by_approval(world, assertion, first.json()["entryId"], "regrace-void-001",
                            reason="Wrong reference").status_code == 200
    again = world.app.post(payment_path(), json=payment(externalReference="BANK/REGRACE"),
                           headers=headers(assertion, OPERATOR, "regrace-pay-002"))
    assert again.status_code == 201
    activate = {"state": "active", "expectedRevision": 0, "paymentEntryId": again.json()["entryId"],
                "reason": "Paid activation", "ticket": None}
    refused = world.app.put(lifecycle_path(), json=activate, headers=headers(assertion, OPERATOR, "regrace-act-001"))
    assert refused.status_code == 409
    assert world.app.post(f"{payment_path()}/{again.json()['entryId']}/check",
                          headers=headers(assertion)).status_code == 200
    allowed = world.app.put(lifecycle_path(), json=activate, headers=headers(assertion, OPERATOR, "regrace-act-002"))
    assert allowed.status_code == 200, allowed.text






def test_credit_notes_need_a_second_person_and_draft_voids_are_owner_only(world, assertion):
    body = {"amountMinor": 2500, "reason": "Goodwill"}
    path = f"/staff/v1/invoices/{INVOICE[TENANT]}"
    for email in (OPERATOR, OWNER):
        direct = world.app.post(f"{path}/credit-notes", json=body, headers=headers(assertion, email, f"credit-{email}"))
        assert direct.status_code == 409 and direct.json()["approvalAction"] == "invoice.credit_note"
    assert world.app.post(f"{path}/credit-notes", json=body,
                          headers=headers(assertion, SUPPORT, "credit-support-001")).status_code == 403
    created = approved(world, assertion, "invoice.credit_note", {"invoiceId": INVOICE[TENANT], "amountMinor": 2500},
                       "credit-owner-001", reason="Goodwill")
    assert created.status_code == 200 and created.json()["operation"]["status"] == "completed"
    too_much = ask(world, assertion, "invoice.credit_note", {"invoiceId": INVOICE[TENANT], "amountMinor": 7501},
                   "credit-owner-002", reason="Too much")
    assert too_much.status_code == 409
    shown = world.app.get(path, headers=headers(assertion)).json()
    assert shown["outstandingMinor"] == 7500 and len(shown["creditNotes"]) == 1
    later_day = (datetime.now(timezone.utc) + timedelta(days=45)).strftime("%Y-%m-%dT00:00:00Z")
    draft = world.app.post(f"/staff/v1/companies/{TENANT}/invoices", json={"periodStart": later_day},
                           headers=headers(assertion, OPERATOR, "api-invoice-0003")).json()
    draft_path = f"/staff/v1/invoices/{draft['invoiceId']}/void"
    assert world.app.post(draft_path, headers=headers(assertion, OPERATOR)).status_code == 403
    voided = world.app.post(draft_path, headers=headers(assertion))
    assert voided.status_code == 200 and voided.json()["status"] == "void" and voided.json()["number"] is None
    assert voided.json()["voidedBy"] == OWNER and voided.json()["createdBy"] == OPERATOR


def activate_company(world, assertion, reference="APPROVAL-ACTIVE"):
    receipt = world.app.post(payment_path(), json=payment(externalReference=reference),
                             headers=headers(assertion, OPERATOR, f"{reference}-pay")).json()
    active = world.app.put(
        lifecycle_path(),
        json={"state": "active", "expectedRevision": 0, "paymentEntryId": receipt["entryId"],
              "reason": "Paid activation", "ticket": None},
        headers=headers(assertion, key=f"{reference}-act"))
    assert active.status_code == 200, active.text
    return receipt


def lifecycle_now(world, assertion):
    return world.app.get(lifecycle_path(), headers=headers(assertion)).json()["lifecycle"]


def operations_of(world, action):
    return [row.to_dict() for row in world.db.collection("operations").stream() if row.to_dict()["action"] == action]


def test_a_suspension_needs_a_second_person_and_runs_exactly_once(world, assertion):
    activate_company(world, assertion)
    body = {"state": "suspended", "expectedRevision": 1, "paymentEntryId": None, "reason": "Unpaid", "ticket": None}
    for role, email in (("owner", OWNER), ("operator", OPERATOR)):
        direct = world.app.put(lifecycle_path(), json=body, headers=headers(assertion, email, f"suspend-direct-{role}"))
        assert direct.status_code == 409 and direct.json()["approvalAction"] == "lifecycle.suspend"
    assert lifecycle_now(world, assertion)["state"] == "active"
    asked = ask(world, assertion, "lifecycle.suspend", {"expectedRevision": 1}, "suspend-ask-001",
                reason="Three invoices unpaid")
    assert asked.status_code == 201, asked.text
    approval = asked.json()
    assert (approval["status"], approval["requestedBy"], approval["tenantId"]) == ("requested", OPERATOR, TENANT)
    assert approval["canDecide"] is False
    replay = ask(world, assertion, "lifecycle.suspend", {"expectedRevision": 1}, "suspend-ask-001",
                 reason="Three invoices unpaid")
    assert replay.status_code == 201 and replay.json()["approvalId"] == approval["approvalId"]
    self_approval = decide(world, assertion, approval["approvalId"], OPERATOR)
    assert self_approval.status_code == 409 and self_approval.json()["detail"] == "Another person must approve this."
    assert decide(world, assertion, approval["approvalId"], SUPPORT).status_code == 403
    assert decide(world, assertion, approval["approvalId"], UNMAPPED).status_code == 403
    assert lifecycle_now(world, assertion)["state"] == "active"
    seen = world.app.get(f"/staff/v1/approvals/{approval['approvalId']}", headers=headers(assertion, OWNER)).json()
    assert seen["canDecide"] is True and seen["canReject"] is True
    done = decide(world, assertion, approval["approvalId"], OWNER)
    assert done.status_code == 200, done.text
    assert done.json()["approval"]["status"] == "executed" and done.json()["operation"]["status"] == "completed"
    assert done.json()["approval"]["decidedBy"] == OWNER
    retry = decide(world, assertion, approval["approvalId"], OWNER)
    assert retry.status_code == 200
    assert retry.json()["operation"]["operationId"] == done.json()["operation"]["operationId"]
    assert lifecycle_now(world, assertion)["state"] == "suspended" and lifecycle_now(world, assertion)["revision"] == 2
    assert len(operations_of(world, "lifecycle.transition")) == 2
    assert world.store.get(TENANT)["status"] == "live"
    mine = world.app.get("/staff/v1/approvals?scope=mine", headers=headers(assertion, OPERATOR)).json()
    others = world.app.get("/staff/v1/approvals?scope=others", headers=headers(assertion, OPERATOR)).json()
    assert [row["approvalId"] for row in mine["approvals"]] == [approval["approvalId"]] and others["approvals"] == []
    executed = world.app.get("/staff/v1/approvals?status=executed", headers=headers(assertion, OWNER)).json()
    assert [row["approvalId"] for row in executed["approvals"]] == [approval["approvalId"]]
    assert world.app.get("/staff/v1/approvals", headers=headers(assertion, SUPPORT)).status_code == 403


def test_reactivation_after_a_suspension_needs_a_second_person_too(world, assertion):
    receipt = activate_company(world, assertion)
    suspended = approved(world, assertion, "lifecycle.suspend", {"expectedRevision": 1}, "react-suspend-001",
                         reason="Unpaid")
    assert suspended.status_code == 200, suspended.text
    body = {"state": "active", "expectedRevision": 2, "paymentEntryId": receipt["entryId"], "reason": "Paid",
            "ticket": None}
    direct = world.app.put(lifecycle_path(), json=body, headers=headers(assertion, OWNER, "react-direct-001"))
    assert direct.status_code == 409 and direct.json()["approvalAction"] == "lifecycle.reactivate"
    params = {"expectedRevision": 2, "paymentEntryId": receipt["entryId"]}
    assert ask(world, assertion, "lifecycle.reactivate", {"expectedRevision": 2}, "react-ask-000").status_code == 400
    back = approved(world, assertion, "lifecycle.reactivate", params, "react-ask-001", reason="Paid in full")
    assert back.status_code == 200, back.text
    assert lifecycle_now(world, assertion)["state"] == "active"








def test_extension_is_fourteen_days_and_once_per_invoice(world, assertion):
    world.db.collection("companies").document(TENANT).update({"billingEmail": "billing@northwind.test"})
    sent = world.app.post(f"/staff/v1/invoices/{INVOICE[TENANT]}/send", headers=headers(assertion, OPERATOR))
    assert sent.status_code == 200, sent.text
    deliver_mail(MailQueue(world.db, enabled=True), transport=StubTransport())
    world.app.get(f"/staff/v1/invoices/{INVOICE[TENANT]}", headers=headers(assertion, OPERATOR))
    before = world.db.collection("invoices").document(INVOICE[TENANT]).get().to_dict()["dueAt"]
    too_long = ask(world, assertion, "invoice.extension", {"invoiceId": INVOICE[TENANT], "days": 15}, "ext-ask-000")
    assert too_long.status_code == 400
    done = approved(world, assertion, "invoice.extension", {"invoiceId": INVOICE[TENANT]}, "ext-ask-001",
                    reason="The client pays on the 20th")
    assert done.status_code == 200, done.text
    after = world.db.collection("invoices").document(INVOICE[TENANT]).get().to_dict()
    assert after["dueAt"] - before == timedelta(days=14) and after["extendedDays"] == 14
    assert after["extendedBy"] == OWNER
    again = ask(world, assertion, "invoice.extension", {"invoiceId": INVOICE[TENANT]}, "ext-ask-002")
    assert again.status_code == 409


def test_a_quoted_price_and_a_package_price_change_need_a_second_person(world, assertion):
    world.db.collection("subscriptions").document(OTHER).update({"planId": "STARTER", "planVersion": 1})
    fixed = ask(world, assertion, "quote.price", {"amountMinor": 500000, "billingInterval": "monthly"}, "quote-ask-000",
                tenant=TENANT)
    assert fixed.status_code == 409
    drafts = f"/staff/v1/companies/{OTHER}/invoices"
    typed = world.app.post(drafts, json={"amountMinor": 1}, headers=headers(assertion, OPERATOR, "quote-draft-001"))
    assert typed.status_code == 400
    waiting = world.app.post(drafts, json={}, headers=headers(assertion, OPERATOR, "quote-draft-002"))
    assert waiting.status_code == 409 and "Set a price for this package on the Packages page first" in waiting.text
    quote = approved(world, assertion, "quote.price", {"amountMinor": 500000, "billingInterval": "monthly"},
                     "quote-ask-001", tenant=OTHER, reason="Agreed on the call")
    assert quote.status_code == 200, quote.text
    renewal_start = format_timestamp(world.db.collection("invoices").document(INVOICE[OTHER]).get().to_dict()["periodEnd"])
    priced_draft = world.app.post(drafts, json={"periodStart": renewal_start}, headers=headers(assertion, OPERATOR, "quote-draft-003"))
    assert priced_draft.status_code == 201, priced_draft.text
    assert priced_draft.json()["amountMinor"] == 500000 and priced_draft.json()["quoteId"]
    quotes = [row.to_dict() for row in world.db.collection("quotes").stream()]
    assert len(quotes) == 1 and quotes[0]["amountMinor"] == 500000 and quotes[0]["approvedBy"] == OWNER
    version = {**valid_plan_v1(), "name": "P1", "prices": {"currency": "MYR", "monthly": 250, "yearly": 2400}}
    direct = world.app.put("/staff/v1/plans/P1", json=version,
                           headers={**headers(assertion, OWNER), "Idempotency-Key": "package-direct-001"})
    assert direct.status_code == 409 and direct.json()["approvalAction"] == "package.price"
    priced = approved(world, assertion, "package.price",
                      {"planId": "P1", "version": price_only_version(world, "P1", 250, 2400)}, "package-ask-001",
                      tenant=None, reason="Annual price review")
    assert priced.status_code == 200, priced.text
    assert world.db.collection("plans").document("P1").get().to_dict()["currentVersion"] == 2


def audit_actions(world):
    return {row.to_dict()["action"] for row in world.db.collection("audit_events").stream()}


def today_in_kuala_lumpur():
    return (datetime.now(timezone.utc) + timedelta(hours=8)).date().isoformat()




def test_a_removed_audit_event_is_reported_in_its_company_chain(world, assertion):
    activate_company(world, assertion)
    events = sorted((row for row in world.db.collection("audit_events").stream()
                     if row.to_dict().get("chain") == TENANT), key=lambda row: row.to_dict()["seq"])
    last = events[-1]
    last.reference.delete()
    result = world.app.get(f"/staff/v1/audit-events/verify?day={today_in_kuala_lumpur()}",
                           headers=headers(assertion, OPERATOR)).json()
    assert result["ok"] is False and result["firstBroken"]["seq"] == len(events)
    assert result["firstBroken"]["chain"] == TENANT




def test_the_first_audit_page_is_logged_once_and_later_pages_are_not(world, assertion):
    activate_company(world, assertion)

    def viewed():
        return [row.to_dict() for row in world.db.collection("audit_events").stream()
                if row.to_dict()["action"] == "audit.viewed"]

    first = world.app.get(f"/staff/v1/audit-events?limit=1&tenantId={TENANT}", headers=headers(assertion, OPERATOR))
    assert first.status_code == 200 and first.json()["nextAfter"]
    assert [row["actor"] for row in viewed()] == [OPERATOR]
    assert viewed()[0].get("tenantId") is None and viewed()[0]["refs"]["tenantFilter"] == TENANT
    second = world.app.get(f"/staff/v1/audit-events?limit=1&after={first.json()['nextAfter']}",
                           headers=headers(assertion, OPERATOR))
    assert second.status_code == 200
    assert len(viewed()) == 1


def test_audit_export_is_owner_only_formula_safe_and_itself_audited(world, assertion):
    activate_company(world, assertion)
    log_before = len(list(world.db.collection("audit_events").stream()))
    for email in (OPERATOR, SUPPORT, ENGINEER):
        denied = world.app.post("/staff/v1/audit-events/export", json={"format": "json"}, headers=headers(assertion, email))
        assert denied.status_code == 403, email
    assert world.app.post("/staff/v1/audit-events/export", json={"format": "xml"},
                          headers=headers(assertion, OWNER)).status_code == 400
    assert len(list(world.db.collection("audit_events").stream())) == log_before
    exported = world.app.post("/staff/v1/audit-events/export", json={"format": "json", "tenantId": TENANT},
                              headers=headers(assertion, OWNER))
    assert exported.status_code == 200 and exported.json()["count"] > 0
    assert {event["tenantId"] for event in exported.json()["events"]} == {TENANT}
    assert "audit.exported" in audit_actions(world)
    recorded = [row.to_dict() for row in world.db.collection("audit_events").stream()
                if row.to_dict()["action"] == "audit.exported"]
    assert len(recorded) == 1 and recorded[0]["actor"] == OWNER and recorded[0]["refs"]["format"] == "json"
    first_event = world.db.collection("audit_events").document(exported.json()["events"][0]["eventId"])
    first_event.update({"summary": "=HYPERLINK(\"http://evil.example\")"})
    csv_export = world.app.post("/staff/v1/audit-events/export", json={"format": "csv", "tenantId": TENANT},
                                headers=headers(assertion, OWNER))
    assert csv_export.status_code == 200 and "attachment" in csv_export.headers["content-disposition"]
    body = csv_export.content.decode("utf-8-sig")
    assert body.splitlines()[0].startswith("eventId,seq,at,day,actor,action")
    assert "'=HYPERLINK" in body
    assert sum(1 for row in world.db.collection("audit_events").stream() if row.to_dict()["action"] == "audit.exported") == 2




def put_plan(world, assertion, plan_id, version, key, who=OWNER, **extra):
    return world.app.put(f"/staff/v1/plans/{plan_id}", json={**version, **extra},
                         headers={**headers(assertion, who), "Idempotency-Key": key})


def test_a_subscription_cannot_be_set_directly_and_private_plans_cannot_be_assigned(world, assertion):
    from platform_service.plans import PlanStore
    from platform_service.tests.support import make_plan
    make_plan(world.db, "SECRET", salesmen=50, supervisors=10, managers=10, products=500)
    before = world.db.collection("subscriptions").document(TENANT).get().to_dict()
    body = {"planId": "SECRET", "status": "active", "billingInterval": "monthly"}
    for email in (OWNER, OPERATOR):
        direct = world.app.put(f"/staff/v1/companies/{TENANT}/subscription", json=body,
                               headers=headers(assertion, email, f"sub-direct-{email[:3]}"))
        assert direct.status_code == 409, direct.text
    assert world.app.put(f"/staff/v1/companies/{TENANT}/subscription", json=body,
                         headers=headers(assertion, SUPPORT, "sub-direct-sup")).status_code == 403
    private = world.app.post(f"/staff/v1/companies/{TENANT}/package",
                             json={"planId": "SECRET", "billingInterval": "monthly",
                                   "expectedRevision": before["revision"], "reason": "Cheaper"},
                             headers=headers(assertion, OPERATOR, "pkg-private-001"))
    assert private.status_code in (400, 404, 409), private.text
    assert world.db.collection("subscriptions").document(TENANT).get().to_dict() == before
    assert PlanStore(world.db).get_plan("SECRET")["visibility"] == "private"




def test_a_price_request_goes_stale_when_the_package_moves_on(world, assertion):
    version = price_only_version(world, "P1", 250, 2400)
    asked = ask(world, assertion, "package.price", {"planId": "P1", "version": version}, "stale-plan-001",
                tenant=None, reason="Annual price review")
    assert asked.status_code == 201, asked.text
    other = price_only_version(world, "P1", 300, 2900)
    assert approved(world, assertion, "package.price", {"planId": "P1", "version": other}, "stale-plan-002",
                    tenant=None, reason="Another review").status_code == 200
    stale = decide(world, assertion, asked.json()["approvalId"], OWNER)
    assert stale.status_code == 409 and "changed" in stale.json()["detail"]
    assert world.db.collection("plans").document("P1").get().to_dict()["currentVersion"] == 2


def test_a_billing_email_request_goes_stale_when_the_email_changes_first(world, assertion):
    world.db.collection("companies").document(TENANT).update({"billingEmail": "old@northwind.test"})
    asked = ask(world, assertion, "billing_email.change", {"billingEmail": "new@northwind.test"}, "stale-email-001")
    assert asked.status_code == 201
    world.db.collection("companies").document(TENANT).update({"billingEmail": "other@northwind.test"})
    stale = decide(world, assertion, asked.json()["approvalId"], OWNER)
    assert stale.status_code == 409 and "changed" in stale.json()["detail"]
    assert world.db.collection("companies").document(TENANT).get().to_dict()["billingEmail"] == "other@northwind.test"








def log_day(moment):
    return (moment + timedelta(hours=8)).date().isoformat()






def test_the_first_price_of_a_package_needs_no_approval_but_a_change_does(world, assertion):
    unpriced = {**valid_plan_v1(), "name": "First", "prices": {"currency": "MYR", "monthly": None, "yearly": None}}
    plan_path = "/staff/v1/plans/FIRST"
    created = world.app.put(plan_path, json=unpriced, headers=headers(assertion, OWNER, "first-plan-001"))
    assert created.status_code == 200, created.text
    first = {**unpriced, "prices": {"currency": "MYR", "monthly": 300, "yearly": 3000}}
    asked = ask(world, assertion, "package.price", {"planId": "FIRST", "version": first}, "first-ask-001",
                who=OWNER, tenant=None)
    assert asked.status_code == 400
    by_operator = world.app.put(plan_path, json=first, headers=headers(assertion, OPERATOR, "first-price-000"))
    assert by_operator.status_code == 403
    priced = world.app.put(plan_path, json=first, headers=headers(assertion, OWNER, "first-price-001"))
    assert priced.status_code == 200, priced.text
    plan = world.db.collection("plans").document("FIRST").get().to_dict()
    version = world.db.collection("plans").document("FIRST").collection("versions").document(
        str(plan["currentVersion"])).get().to_dict()
    assert plan["currentVersion"] == 2 and version["prices"]["monthly"] == 300
    changed = {**first, "prices": {"currency": "MYR", "monthly": 350, "yearly": 3000}}
    direct = world.app.put(plan_path, json=changed, headers=headers(assertion, OWNER, "first-price-002"))
    assert direct.status_code == 409 and direct.json()["approvalAction"] == "package.price"
    removed = {**first, "prices": {"currency": "MYR", "monthly": None, "yearly": None}}
    cleared = world.app.put(plan_path, json=removed, headers=headers(assertion, OWNER, "first-price-003"))
    assert cleared.status_code == 409 and cleared.json()["approvalAction"] == "package.price"
    assert world.db.collection("plans").document("FIRST").get().to_dict()["currentVersion"] == 2


def only_the_owner_approves(world):
    from platform_service.staff import STAFF, staff_id
    world.db.collection(STAFF).document(staff_id(OPERATOR)).update({"status": "disabled"})


def solo_events(world):
    return [row.to_dict() for row in world.db.collection("audit_events").stream()
            if row.to_dict().get("refs", {}).get("soloApproval") == "true"]


@pytest.mark.parametrize("solo_setting, operator_active, allowed", [
    (True, False, True), (False, False, False), (True, True, False)])
def test_a_solo_owner_checks_their_own_payment_only_with_the_setting_and_one_approver(
        world, assertion, monkeypatch, solo_setting, operator_active, allowed):
    monkeypatch.setattr(config, "SOLO_OWNER", solo_setting)
    if not operator_active:
        only_the_owner_approves(world)
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OWNER, "solo-record-001"))
    assert recorded.status_code == 201, recorded.text
    entry = recorded.json()["entryId"]
    waiting = world.app.get("/staff/v1/payments/to-check", headers=headers(assertion)).json()["payments"]
    assert [row["canCheck"] for row in waiting] == [allowed]
    listed = world.app.get(payment_path(), headers=headers(assertion)).json()["entries"]
    assert [row["canCheck"] for row in listed] == [allowed]
    staff = world.app.get("/staff/v1/staff", headers=headers(assertion)).json()["soloOwner"]
    assert staff == {"enabled": solo_setting, "approvers": 2 if operator_active else 1, "active": allowed}
    checked = world.app.post(f"{payment_path()}/{entry}/check", headers=headers(assertion))
    if not allowed:
        assert checked.status_code == 409 and checked.json()["detail"] == "Another person must check this payment."
        assert solo_events(world) == []
        return
    assert checked.status_code == 200 and checked.json()["checkedBy"] == OWNER, checked.text
    events = solo_events(world)
    assert [(row["action"], row["summary"].startswith("Solo approval: ")) for row in events] == [
        ("payment.checked", True)]
    active = world.app.put(
        lifecycle_path(), json={"state": "active", "expectedRevision": 0, "paymentEntryId": entry,
                                "reason": "Paid activation", "ticket": None},
        headers=headers(assertion, OWNER, "solo-activate-001"))
    assert active.status_code == 200, active.text
    assert lifecycle_now(world, assertion)["state"] == "active"






def test_a_price_set_while_a_first_price_was_in_flight_is_not_replaced_without_approval(world):
    from platform_service.commands import CommandProblem
    from platform_service.plans import PlanStore
    store = PlanStore(world.db)
    unpriced = {**valid_plan_v1(), "name": "Race", "prices": {"currency": "MYR", "monthly": None, "yearly": None}}
    store.write_version("RACE", unpriced, created_by=OWNER, price_locked=True)
    store.write_version("RACE", {**unpriced, "prices": {"currency": "MYR", "monthly": 300, "yearly": None}},
                        created_by=OWNER, price_locked=True)
    for prices in ({"currency": "MYR", "monthly": 350, "yearly": None},
                   {"currency": "MYR", "monthly": None, "yearly": None}):
        with pytest.raises(CommandProblem, match="needs approval"):
            store.write_version("RACE", {**unpriced, "prices": prices}, created_by=OWNER, price_locked=True)
    assert store.get_plan("RACE")["currentVersion"] == 2


@pytest.mark.parametrize("solo_setting, allowed", [(True, True), (False, False)])
def test_a_solo_owner_voids_a_payment_they_recorded_only_with_the_setting(world, assertion, monkeypatch,
                                                                            solo_setting, allowed):
    monkeypatch.setattr(config, "SOLO_OWNER", solo_setting)
    only_the_owner_approves(world)
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OWNER, "solo-void-record"))
    assert recorded.status_code == 201, recorded.text
    voided = void_by_approval(world, assertion, recorded.json()["entryId"], "solo-void-ask",
                              requester=OWNER, approver=OWNER)
    if not allowed:
        assert voided.status_code == 409, voided.text
        return
    assert voided.status_code == 200 and voided.json()["approval"]["status"] == "executed", voided.text
    assert ("approval.approved", True) in [(row["action"], row["summary"].startswith("Solo approval: "))
                                           for row in solo_events(world)]


def activate_company_of(world, assertion, tenant):
    receipt = world.app.post(payment_path(tenant), json=payment(tenant, externalReference=f"ACT-{tenant}"),
                             headers=headers(assertion, OPERATOR, f"act-pay-{tenant}")).json()
    active = world.app.put(
        lifecycle_path(tenant),
        json={"state": "active", "expectedRevision": 0, "paymentEntryId": receipt["entryId"],
              "reason": "Paid activation", "ticket": None},
        headers=headers(assertion, key=f"act-life-{tenant}"))
    assert active.status_code == 200, active.text


def same_person_login(world, assertion, email, like):
    import jwt
    from platform_service.staff import SESSIONS, STAFF, digest, staff_id
    assertion(like)
    uid = world.db.collection(STAFF).document(staff_id(like)).get().to_dict()["uid"]
    sent = assertion(email)
    world.db.collection(STAFF).document(staff_id(email)).update({"uid": uid})
    world.db.collection(SESSIONS).document(digest(sent["X-Staff-Session"])).update({"uid": uid})
    claims = jwt.decode(sent["Authorization"][len("Bearer "):], options={"verify_signature": False})
    sent["Authorization"] = "Bearer " + jwt.encode({**claims, "sub": uid}, None, algorithm="none")
    return sent


@pytest.mark.parametrize("solo_setting", [True, False])
def test_fix_275_a_staff_idempotency_key_cannot_block_an_approval_in_either_company(world, assertion, monkeypatch,
                                                                                      solo_setting):
    monkeypatch.setattr(config, "SOLO_OWNER", solo_setting)
    for tenant in (TENANT, OTHER):
        activate_company_of(world, assertion, tenant)
    asked = {tenant: ask(world, assertion, "lifecycle.suspend", {"expectedRevision": 1}, f"fix275-ask-{tenant}",
                         tenant=tenant) for tenant in (TENANT, OTHER)}
    for tenant, response in asked.items():
        assert response.status_code == 201, response.text
        blocker = {"state": "past_due", "expectedRevision": 9, "paymentEntryId": None,
                   "reason": "Blocker", "ticket": None}
        world.app.put(lifecycle_path(tenant), json=blocker,
                      headers=headers(assertion, OPERATOR, response.json()["approvalId"]))
    for tenant, response in asked.items():
        done = decide(world, assertion, response.json()["approvalId"], OWNER)
        assert done.status_code == 200, done.text
        assert done.json()["approval"]["status"] == "executed" and done.json()["operation"]["status"] == "completed"
        assert world.app.get(lifecycle_path(tenant), headers=headers(assertion)).json()["lifecycle"]["state"] == "suspended"


@pytest.mark.parametrize("solo_setting", [True, False])
def test_fix_276_one_person_with_two_staff_logins_cannot_void_their_own_payment(world, assertion, monkeypatch,
                                                                                  solo_setting):
    monkeypatch.setattr(config, "SOLO_OWNER", solo_setting)
    second = same_person_login(world, assertion, OWNER_SECOND_LOGIN, OWNER)
    assert world.app.get("/staff/v1/approvals", headers=headers(assertion, THIRD_APPROVER)).status_code == 200
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OWNER, "fix276-record"))
    assert recorded.status_code == 201, recorded.text
    entry = recorded.json()["entryId"]
    own_check = world.app.post(f"{payment_path()}/{entry}/check", headers=second)
    assert own_check.status_code == 409 and own_check.json()["detail"] == "Another person must check this payment."
    asked = ask(world, assertion, "payment.void", {"receiptId": entry}, "fix276-ask", who=OPERATOR)
    assert asked.status_code == 201, asked.text
    refused = world.app.post(f"/staff/v1/approvals/{asked.json()['approvalId']}/approve", headers=second)
    assert refused.status_code == 409, refused.text
    assert refused.json()["detail"] == "Another person must void this payment."
    kinds = [row["type"] for row in world.app.get(payment_path(), headers=headers(assertion)).json()["entries"]]
    assert kinds.count("void") == 0
    other = decide(world, assertion, asked.json()["approvalId"], OWNER)
    assert other.status_code == 409 and other.json()["detail"] == "Another person must void this payment."


@pytest.mark.parametrize("solo_setting", [True, False])
def test_fix_277_a_second_approver_who_joins_during_a_check_ends_solo_checking(world, assertion, monkeypatch,
                                                                                  solo_setting):
    from platform_service.staff import STAFF, staff_id
    monkeypatch.setattr(config, "SOLO_OWNER", solo_setting)
    only_the_owner_approves(world)
    recorded = world.app.post(payment_path(), json=payment(), headers=headers(assertion, OWNER, "fix277-record"))
    assert recorded.status_code == 201, recorded.text
    entry = recorded.json()["entryId"]
    original = PaymentLedger.check

    def check_after_the_operator_joins(self, *args, **kwargs):
        world.db.collection(STAFF).document(staff_id(OPERATOR)).update({"status": "active"})
        return original(self, *args, **kwargs)

    monkeypatch.setattr(PaymentLedger, "check", check_after_the_operator_joins)
    checked = world.app.post(f"{payment_path()}/{entry}/check", headers=headers(assertion))
    assert checked.status_code == 409 and checked.json()["detail"] == "Another person must check this payment."
    assert solo_events(world) == []


def test_fix_294_the_engineer_sees_the_true_company_status_in_the_list(world, assertion):
    activate_company_of(world, assertion, TENANT)
    for who in (OPERATOR, ENGINEER):
        rows = world.app.get("/staff/v1/companies", headers=headers(assertion, who)).json()["companies"]
        assert {row["tenantId"]: row["lifecycleState"] for row in rows}[TENANT] == "active"


def test_fix_303_the_settings_list_of_approvals_names_every_action_the_server_approves(world, assertion):
    listed = world.app.get("/staff/v1/approval-actions", headers=headers(assertion, ENGINEER)).json()["actions"]
    assert len(listed) == 11
    for phrase in ("expiring a company", "quoted prices", "package overrides", "package prices", "payment voids"):
        assert phrase in listed

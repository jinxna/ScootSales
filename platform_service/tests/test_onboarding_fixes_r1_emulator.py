from __future__ import annotations

import hashlib
import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from platform_service.commands import CommandProblem
from platform_service.invoices import issued_period_refusal
from platform_service.signing import format_timestamp
from platform_service.tests import test_staff_operator_emulator as operator
from platform_service.tests.test_onboarding_first_admin_emulator import (
    company_of,
    invite_secret,
    paid_company,
    step_of,
)
from platform_service.tests.test_staff_operator_emulator import assertion, staff_settings, world

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)


def draft_view(world, assertion, draft_id):
    return world.app.get(f"/staff/v1/onboarding-drafts/{draft_id}", headers=operator.headers(assertion)).json()


def invoice_of(world, tenant):
    return next(row.to_dict() for row in world.db.collection("invoices").stream()
                if row.to_dict()["tenantId"] == tenant)


def plant_payment(world, tenant, invoice_id, *, suffix, checked=False, voided=False, start_days=-1):
    start = datetime.now(timezone.utc) + timedelta(days=start_days)
    entry = "pay_" + hashlib.sha256(f"{tenant}{suffix}".encode()).hexdigest()
    world.db.collection("payment_entries").document(entry).set({
        "entryId": entry, "tenantId": tenant, "type": "payment", "revision": 1, "invoiceId": invoice_id,
        "periodStart": start, "periodEnd": start + timedelta(days=30), "createdAt": start,
        "graceEnd": start + timedelta(days=7), "createdBy": "recorder@example.com"})
    if checked:
        world.db.collection("payment_checks").document(entry).set(
            {"tenantId": tenant, "checkedBy": "checker@example.com"})
    if voided:
        void = "void_" + hashlib.sha256(f"{tenant}{suffix}v".encode()).hexdigest()
        world.db.collection("payment_entries").document(void).set({
            "entryId": void, "tenantId": tenant, "type": "void", "receiptId": entry, "revision": 2,
            "createdAt": start, "createdBy": "recorder@example.com"})
    return entry


def test_step_five_offers_check_payment_only_when_a_live_payment_waits_for_a_check(world, assertion, paid_company):
    draft_id, tenant = paid_company("five@newco.example")
    invoice_id = invoice_of(world, tenant)["invoiceId"]
    assert step_of(draft_view(world, assertion, draft_id), "payment")["button"]["id"] == "record_payment"

    plant_payment(world, tenant, invoice_id, suffix="voided", voided=True)
    assert step_of(draft_view(world, assertion, draft_id), "payment")["button"]["id"] == "record_payment"

    plant_payment(world, tenant, invoice_id, suffix="old", checked=True, start_days=-90)
    assert step_of(draft_view(world, assertion, draft_id), "payment")["button"]["id"] == "record_payment"

    plant_payment(world, tenant, invoice_id, suffix="waiting")
    assert step_of(draft_view(world, assertion, draft_id), "payment")["button"]["id"] == "check_payment"


def test_a_connected_draft_without_a_billing_email_can_get_one(world, assertion):
    draft_id = operator.start_draft(world, assertion, "billing-fix-0001", workspace="billfix").json()["draftId"]
    assert operator.complete(world, assertion, draft_id, "billing-fix-connect", operator.OWNER).status_code == 200
    world.db.collection("onboarding_drafts").document(draft_id).update({"billingEmail": None})
    assert step_of(draft_view(world, assertion, draft_id), "details")["state"] == "red"
    fixed = world.app.put(f"/staff/v1/onboarding-drafts/{draft_id}", json={"billingEmail": "pay@billfix.example"},
                          headers=operator.headers(assertion, operator.OPERATOR))
    assert fixed.status_code == 200, fixed.text
    assert step_of(fixed.json(), "details")["state"] == "green"


def test_issuing_and_resending_wait_for_the_earlier_steps(world, assertion, paid_company):
    draft_id, tenant = paid_company("gate@newco.example")
    invoice_id = invoice_of(world, tenant)["invoiceId"]
    world.db.collection("onboarding_drafts").document(draft_id).update({"billingEmail": None})
    issue = world.app.post(f"/staff/v1/invoices/{invoice_id}/issue", headers=operator.headers(assertion, operator.OPERATOR))
    assert issue.status_code == 409 and "Step 1 (Company details)" in issue.json()["detail"]
    resend = world.app.post(f"/staff/v1/onboarding-drafts/{draft_id}/first-admin/resend",
                            headers=operator.headers(assertion, operator.OPERATOR))
    assert resend.status_code == 409 and "Step 1 (Company details)" in resend.json()["detail"]


def test_the_list_shows_an_open_company_as_done_without_reading_its_facts(world, assertion, paid_company):
    done_draft, done_tenant = paid_company("done@newco.example")
    world.db.collection("lifecycle").document(done_tenant).set({"state": "active"})
    listed = {row["draftId"]: row for row in world.app.get(
        "/staff/v1/onboarding-drafts", headers=operator.headers(assertion)).json()["drafts"]}
    assert listed[done_draft]["doneCount"] == 8 and listed[done_draft]["phase"] == "working"


def test_the_list_stops_reading_at_the_first_step_that_is_not_green(world, assertion):
    waiting = operator.start_draft(world, assertion, "list-wait-0001", workspace="listwait").json()["draftId"]
    assert operator.complete(world, assertion, waiting, "list-wait-connect", operator.OWNER).status_code == 200
    row = next(item for item in world.app.get("/staff/v1/onboarding-drafts",
                                              headers=operator.headers(assertion)).json()["drafts"]
               if item["draftId"] == waiting)
    first = row["next"]["n"]
    assert first >= 3
    assert all(step["fact"] == f"Waiting for step {first}." for step in row["steps"][first:])


def stall(world, draft_id, tenant="t_stalled0000000000000000"):
    world.db.collection("onboarding_drafts").document(draft_id).update(
        {"status": "completing", "completingTenant": tenant})


def test_a_draft_left_in_completing_without_a_company_can_be_edited_extended_and_cancelled(world, assertion):
    draft_id = operator.start_draft(world, assertion, "stalled-0001", workspace="stalled").json()["draftId"]
    stall(world, draft_id)
    path = f"/staff/v1/onboarding-drafts/{draft_id}"
    edited = world.app.put(path, json={"adminName": "Fixed Name"}, headers=operator.headers(assertion, operator.OPERATOR))
    assert edited.status_code == 200 and edited.json()["adminName"] == "Fixed Name"
    extended = world.app.post(f"{path}/extend", headers=operator.headers(assertion, operator.OWNER))
    assert extended.status_code == 200, extended.text
    cancelled = world.app.post(f"{path}/cancel", headers=operator.headers(assertion, operator.OPERATOR))
    assert cancelled.status_code == 200 and cancelled.json()["status"] == "cancelled"


def test_a_completing_draft_whose_company_exists_stays_closed_to_edits(world, assertion):
    draft_id = operator.start_draft(world, assertion, "stalled-0002", workspace="stalled2").json()["draftId"]
    tenant = "t_stalled2000000000000000"
    world.db.collection("companies").document(tenant).set({"tenantId": tenant})
    stall(world, draft_id, tenant)
    refused = world.app.post(f"/staff/v1/onboarding-drafts/{draft_id}/cancel",
                             headers=operator.headers(assertion, operator.OPERATOR))
    assert refused.status_code == 409


def test_finishing_a_failed_package_reports_the_parts_instead_of_crashing(world, assertion):
    draft_id = operator.start_draft(world, assertion, "finish-0001", workspace="finishco").json()["draftId"]
    made = operator.complete(world, assertion, draft_id, "finish-connect", operator.OWNER)
    tenant = made.json()["tenantId"]
    target = company_of(world)
    target.db.collection("config").document("plan").set({"revision": 99, "planId": "STANDARD", "planVersion": 1})
    key = uuid.uuid4().hex
    applied = world.app.post(
        f"/staff/v1/companies/{tenant}/package",
        json={"planId": "STANDARD", "billingInterval": "monthly", "expectedRevision": 0, "reason": "Chosen"},
        headers=operator.headers(assertion, operator.OPERATOR, f"finish-{key}"))
    assert applied.status_code == 409, applied.text
    operation_id = applied.json()["operationId"]
    step = step_of(draft_view(world, assertion, draft_id), "package")
    assert step["button"]["id"] == "finish_package" and step["operationId"] == operation_id

    retried = world.app.post(f"/staff/v1/operations/{operation_id}/retry", headers=operator.headers(assertion))
    assert retried.status_code == 409, retried.text
    assert retried.json()["operationId"] == operation_id and "parts" in retried.json()

    target.db.collection("config").document("plan").delete()
    done = world.app.post(f"/staff/v1/operations/{operation_id}/retry", headers=operator.headers(assertion))
    assert done.status_code == 200 and done.json()["status"] == "completed", done.text


def test_the_people_fix_route_answers_400_for_a_bad_id_and_404_for_a_missing_row(world, assertion):
    path = "/staff/v1/companies/t_northwind/people-fixes"
    bad = world.app.post(path, json={"itemId": "no_account:", "fixId": "switch_off"},
                         headers=operator.headers(assertion, operator.OWNER))
    assert bad.status_code == 400, bad.text
    missing = world.app.post(path, json={"itemId": "no_account:ghost", "fixId": "switch_off"},
                             headers=operator.headers(assertion, operator.OWNER))
    assert missing.status_code == 404, missing.text
    wrong_fix = world.app.post(path, json={"itemId": "no_account:ghost", "fixId": "make_profile"},
                               headers=operator.headers(assertion, operator.OWNER))
    assert wrong_fix.status_code == 409, wrong_fix.text


class RefusingBook:
    def __init__(self, message, listed=()):
        self.message = message
        self.listed = list(listed)

    def list_invoices(self, tenant_id):
        return self.listed

    def create_draft(self, tenant_id, key, body, actor):
        raise CommandProblem(self.message)


def test_a_renewal_invoice_that_already_exists_is_skipped_quietly_and_other_refusals_still_block(world, assertion):
    from platform_service.scheduler import RENEWAL_BLOCKS, draft_renewal_invoices

    tenant = "t_northwind"
    world.db.collection("lifecycle").document(tenant).set({"state": "active"})
    began = datetime.now(timezone.utc) - timedelta(days=25)
    entry = "pay_" + hashlib.sha256(b"renewal").hexdigest()
    world.db.collection("payment_entries").document(entry).set({
        "entryId": entry, "tenantId": tenant, "type": "payment", "revision": 1, "invoiceId": "inv_x",
        "periodStart": began, "periodEnd": began + timedelta(days=30), "createdAt": began,
        "graceEnd": began + timedelta(days=7)})
    world.db.collection("payment_checks").document(entry).set({"tenantId": tenant, "checkedBy": "c@example.com"})
    now = datetime.now(timezone.utc)

    issued = {"status": "issued", "periodStart": format_timestamp(began + timedelta(days=30))}
    quiet = draft_renewal_invoices(world.db, RefusingBook(issued_period_refusal("INV-0001"), [issued]), now=now)
    assert quiet["blocked"] == 0 and quiet["skipped"] == 1
    assert list(world.db.collection(RENEWAL_BLOCKS).stream()) == []

    loud = draft_renewal_invoices(world.db, RefusingBook("The company has no price."), now=now)
    assert loud["blocked"] == 1
    assert [row.to_dict()["reason"] for row in world.db.collection(RENEWAL_BLOCKS).stream()] == [
        "The company has no price."]


def test_a_billing_email_fixed_on_a_connected_draft_reaches_the_company_record(world, assertion, paid_company):
    draft_id, tenant = paid_company("billing.owner@newco.example")
    company = world.db.collection("companies").document(tenant)
    assert company.get().to_dict()["billingEmail"] == "billing@newco.example"
    fixed = world.app.put(f"/staff/v1/onboarding-drafts/{draft_id}", json={"billingEmail": "ap@newco.example"},
                          headers=operator.headers(assertion, operator.OPERATOR))
    assert fixed.status_code == 200, fixed.text
    assert company.get().to_dict()["billingEmail"] == "ap@newco.example"
    changed = [row.to_dict() for row in world.db.collection("audit_events").stream()
               if row.to_dict()["action"] == "billing_email.changed" and row.to_dict().get("tenantId") == tenant]
    assert any(event["actor"] == operator.OPERATOR for event in changed)
    same = world.app.put(f"/staff/v1/onboarding-drafts/{draft_id}", json={"billingEmail": "ap@newco.example"},
                         headers=operator.headers(assertion, operator.OPERATOR))
    assert same.status_code == 200 and company.get().to_dict()["billingEmail"] == "ap@newco.example"
    after_same = [row.to_dict() for row in world.db.collection("audit_events").stream()
                  if row.to_dict()["action"] == "billing_email.changed" and row.to_dict().get("tenantId") == tenant]
    assert len(after_same) == len(changed)
    third = world.app.put(f"/staff/v1/onboarding-drafts/{draft_id}", json={"billingEmail": "ar@newco.example"},
                          headers=operator.headers(assertion, operator.OPERATOR))
    assert third.status_code == 200 and company.get().to_dict()["billingEmail"] == "ar@newco.example"
    after_third = [row.to_dict() for row in world.db.collection("audit_events").stream()
                   if row.to_dict()["action"] == "billing_email.changed" and row.to_dict().get("tenantId") == tenant]
    assert len(after_third) == len(changed) + 1


def test_saving_the_draft_billing_email_again_repairs_a_company_record_left_behind(world, assertion, paid_company):
    draft_id, tenant = paid_company("billing.owner@oldco.example")
    company = world.db.collection("companies").document(tenant)
    world.db.collection("onboarding_drafts").document(draft_id).update({"billingEmail": "ap@oldco.example"})
    assert company.get().to_dict()["billingEmail"] == "billing@newco.example"
    saved = world.app.put(f"/staff/v1/onboarding-drafts/{draft_id}", json={"billingEmail": "ap@oldco.example"},
                          headers=operator.headers(assertion, operator.OPERATOR))
    assert saved.status_code == 200, saved.text
    assert company.get().to_dict()["billingEmail"] == "ap@oldco.example"

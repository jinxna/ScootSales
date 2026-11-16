from __future__ import annotations

import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest
from google.api_core.exceptions import Aborted

from platform_service import lifecycle, staff_api, subscriptions
from platform_service.ids import command_id
from platform_service.invoices import InvoiceBook
from platform_service.mail import MailQueue
from platform_service.operations import MAX_RECOVERY_ATTEMPTS, OperationStore, RetryLater, Step
from platform_service.tests.test_boundary_regressions_emulator import (  # noqa: F401
    INVOICE, OPERATOR, OTHER, OWNER, TENANT, activate_company, approved_credit_note, ask, assertion, close_approval,
    decide, headers, pytestmark, retry_approval, staff_settings, world)

LONG_AGO = datetime(2020, 1, 1, tzinfo=timezone.utc)


def crash(*args, **kwargs):
    raise RuntimeError("simulated crash in the step")


def approval_row(world, approval_id):
    return world.db.collection("approvals").document(approval_id).get().to_dict()


def operation_row(world, operation_id):
    return world.db.collection("operations").document(operation_id).get().to_dict()


def approval_view(world, assertion, approval_id):
    return world.app.get(f"/staff/v1/approvals/{approval_id}", headers=headers(assertion, OWNER)).json()


def note_exists(world, approval_id):
    operation_id = approval_row(world, approval_id)["operationId"]
    note_id = command_id("cn", INVOICE[TENANT], operation_id, "invoice.credit")
    return world.db.collection("credit_notes").document(note_id).get().exists


def build_scheduler(world, monkeypatch):
    captured = []
    monkeypatch.setattr(staff_api, "install_scheduler", lambda app, build: captured.append(build))
    staff_api.create_app(store=world.store, operations=OperationStore(world.db), signer=world.store.signer,
                         client=world.db)
    return captured[0]()


def failed_credit_note(world, assertion, monkeypatch, key, amount=10):
    approval_id = approved_credit_note(world, assertion, key, amount)
    original = InvoiceBook.credit_note
    monkeypatch.setattr(InvoiceBook, "credit_note", crash)
    assert decide(world, assertion, approval_id, OWNER).status_code == 409
    monkeypatch.setattr(InvoiceBook, "credit_note", original)
    return approval_id


def billing_change_stopped_after_the_email_changed(world, assertion, monkeypatch):
    world.store.set_billing_email(TENANT, "old@northwind.test")
    approval_id = ask(world, assertion, "billing_email.change", {"billingEmail": "new@northwind.test"},
                      "half-billing").json()["approvalId"]
    original = MailQueue.enqueue_or_report
    monkeypatch.setattr(MailQueue, "enqueue_or_report", crash)
    assert decide(world, assertion, approval_id, OWNER).status_code == 409
    monkeypatch.setattr(MailQueue, "enqueue_or_report", original)
    return approval_id


def test_c10_a_half_done_request_cannot_be_closed_and_try_again_finishes_it(world, assertion, monkeypatch):
    approval_id = billing_change_stopped_after_the_email_changed(world, assertion, monkeypatch)
    view = approval_view(world, assertion, approval_id)
    assert view["status"] == "approved" and view["canClose"] is False and view["appliedSteps"]
    closed = close_approval(world, assertion, approval_id, OPERATOR)
    assert closed.status_code == 409
    assert "Part of this change is already done" in closed.json()["detail"]
    assert approval_row(world, approval_id)["status"] == "approved"
    retried = retry_approval(world, assertion, approval_id, OWNER)
    assert retried.status_code == 200, retried.text
    assert retried.json()["approval"]["status"] == "executed"
    kinds = [job.to_dict().get("kind") for job in world.db.collection("mail_jobs").stream()]
    assert world.store.billing_email(TENANT) == "new@northwind.test" and kinds.count("billing_email_changed") == 1




def approved_without_operation(world, assertion, key):
    activate_company(world, assertion, f"LEGACY-{key}")
    approval_id = approved_credit_note(world, assertion, key, 10)
    operation_id = staff_api.operation_id_for("invoice.credit_note", approval_id)
    world.db.collection("approvals").document(approval_id).update(
        {"status": "approved", "decidedBy": OWNER, "decidedByPerson": OWNER,
         "decidedAt": datetime.now(timezone.utc), "operationId": operation_id})
    assert world.db.collection("operations").document(operation_id).get().exists is False
    return approval_id




def test_c10_retry_close_and_recovery_at_the_same_moment_never_both_close_and_apply(world, assertion, monkeypatch):
    activate_company(world, assertion)
    both = []
    ends = []
    for number in range(6):
        approval_id = failed_credit_note(world, assertion, monkeypatch, f"race-free-{number:03d}")
        barrier = threading.Barrier(3)

        def go(action):
            barrier.wait()
            if action == "retry":
                return retry_approval(world, assertion, approval_id, OWNER).status_code
            if action == "close":
                return close_approval(world, assertion, approval_id, OPERATOR).status_code
            return world.app.post("/staff/v1/operations/recover", headers=headers(assertion, OWNER)).status_code

        with ThreadPoolExecutor(max_workers=3) as pool:
            codes = list(pool.map(go, ["retry", "close", "recover"]))
        status = approval_row(world, approval_id)["status"]
        applied = note_exists(world, approval_id)
        ends.append((codes, status, applied))
        if status == "rejected" and applied:
            both.append(approval_id)
    print("RACE", ends, flush=True)
    assert not both
    assert all(status in ("rejected", "executed") and applied == (status == "executed") for _, status, applied in ends)


def test_c10_one_companys_poison_request_does_not_delay_or_change_another_companys_recovery(
        world, assertion, monkeypatch):
    from platform_service.tests.test_boundary_regressions_emulator import OTHER
    activate_company(world, assertion)
    original = InvoiceBook.credit_note
    flaky = {"other_calls": 0}

    def picky(self, invoice_id, key, body, actor, **kwargs):
        if invoice_id == INVOICE[TENANT]:
            raise RetryLater("The first company project cannot be reached yet.")
        flaky["other_calls"] += 1
        if flaky["other_calls"] == 1:
            raise RetryLater("The second company project is slow once.")
        return original(self, invoice_id, key, body, actor, **kwargs)

    monkeypatch.setattr(InvoiceBook, "credit_note", picky)
    poison = approved_credit_note(world, assertion, "two-poison-001", 10)
    good = ask(world, assertion, "invoice.credit_note", {"invoiceId": INVOICE[OTHER], "amountMinor": 10},
               "two-good-0001", tenant=OTHER, reason="Goodwill").json()["approvalId"]
    assert decide(world, assertion, poison, OWNER).status_code == 202
    assert decide(world, assertion, good, OWNER).status_code == 202
    poison_op = approval_row(world, poison)["operationId"]
    good_op = approval_row(world, good)["operationId"]
    for _ in range(MAX_RECOVERY_ATTEMPTS):
        world.db.collection("operations").document(poison_op).update({"leaseUntil": LONG_AGO})
        world.app.post("/staff/v1/operations/recover", headers=headers(assertion, OWNER))
    assert operation_row(world, poison_op)["status"] == "failed"
    assert any(row.to_dict()["action"] == "operation.failed" and row.to_dict()["refs"]["operationId"] == poison_op
               for row in world.db.collection("audit_events").stream())
    listed = world.app.get("/staff/v1/approvals?status=approved", headers=headers(assertion, OWNER)).json()["approvals"]
    shown = next(item for item in listed if item["approvalId"] == poison)
    assert "several tries" in shown["executionError"] and shown["canClose"] is True
    assert operation_row(world, good_op)["status"] == "completed"
    assert not operation_row(world, good_op).get("recoveryAttempts")
    assert approval_view(world, assertion, good)["status"] == "executed"
    assert close_approval(world, assertion, poison, OPERATOR).status_code == 200
    closed_view = approval_view(world, assertion, poison)
    assert closed_view["status"] == "rejected" and closed_view["closedBy"] and closed_view["closedAt"]
    assert approval_view(world, assertion, good)["status"] == "executed"
    assert world.db.collection("credit_notes").where("invoiceId", "==", INVOICE[OTHER]).get()
    assert not world.db.collection("credit_notes").where("invoiceId", "==", INVOICE[TENANT]).get()


def test_c10_work_that_is_done_but_not_marked_cannot_be_closed_and_try_again_finishes_it(world, assertion, monkeypatch):
    approval_id = approved_credit_note(world, assertion, "unmarked-0001", 10)
    original = OperationStore._mark_done
    fired = {"count": 0}

    def busy_once(self, reference, name, result):
        if fired["count"] == 0:
            fired["count"] += 1
            raise Aborted("Transaction lock timeout")
        return original(self, reference, name, result)

    monkeypatch.setattr(OperationStore, "_mark_done", busy_once)
    assert decide(world, assertion, approval_id, OWNER).status_code in (202, 409)
    monkeypatch.setattr(OperationStore, "_mark_done", original)
    assert note_exists(world, approval_id)
    shown = approval_view(world, assertion, approval_id)
    assert shown["canClose"] is False and shown["appliedSteps"]
    refused = close_approval(world, assertion, approval_id, OPERATOR)
    assert refused.status_code == 409 and "already done" in refused.json()["detail"]
    assert approval_row(world, approval_id)["status"] == "approved"
    assert retry_approval(world, assertion, approval_id, OWNER).status_code == 200
    assert approval_view(world, assertion, approval_id)["status"] == "executed"
    assert len(world.db.collection("credit_notes").where("invoiceId", "==", INVOICE[TENANT]).get()) == 1


@pytest.mark.parametrize("kind", ["invoice.credit_note", "plan.override"])
def test_c10_a_step_that_stalls_past_its_lease_cannot_save_work_after_the_change_was_closed(
        world, assertion, monkeypatch, kind):
    if kind == "plan.override":
        activate_company(world, assertion)
        expires = (datetime.now(timezone.utc) + timedelta(days=9)).strftime("%Y-%m-%dT%H:%M:%SZ")
        approval_id = ask(world, assertion, kind, {"expiresAt": expires, "limits": {"salesmen": 7}},
                          "stalled-override").json()["approvalId"]
    else:
        approval_id = approved_credit_note(world, assertion, "stalled-0001", 10)
    take_lease, run = OperationStore._take_lease, OperationStore.run
    stalled, release = threading.Event(), threading.Event()

    def short_lease(self, reference, steps, now):
        self._lease = timedelta(seconds=1)
        return take_lease(self, reference, steps, now)

    def stalled_run(self, operation_id, steps, *, now=None):
        first = steps[0]

        def slow_apply(context):
            time.sleep(1.6)
            stalled.set()
            release.wait(60)
            return first.apply(context)

        return run(self, operation_id, [Step(first.name, slow_apply, first.check), *steps[1:]], now=now)

    monkeypatch.setattr(OperationStore, "_take_lease", short_lease)
    monkeypatch.setattr(OperationStore, "run", stalled_run)
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(decide, world, assertion, approval_id, OWNER)
        assert stalled.wait(60)
        closed = close_approval(world, assertion, approval_id, OPERATOR)
        release.set()
        approved = pending.result(120)
    assert closed.status_code == 200
    assert approved.status_code == 409 and "closed before its work started" in approved.json()["detail"]
    assert approval_row(world, approval_id)["status"] == "rejected"
    assert not note_exists(world, approval_id)

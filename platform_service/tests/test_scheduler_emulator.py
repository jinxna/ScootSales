from __future__ import annotations

import json
import os
import time
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config
from platform_service import company_access as company_access_module
from platform_service.company_access import CompanyUnreachable, company_access
from platform_service.directory import DirectoryStore
from platform_service.gps_purge import purge_old_positions, purge_old_positions_by_part
from platform_service.invoices import InvoiceBook, invoice_delivery
from platform_service.lifecycle import LifecycleService, LifecycleStore
from platform_service.mail import MailQueue, StubTransport, deliver_mail
from platform_service.operations import OperationStore
from platform_service.plans import PlanStore
from platform_service.scheduler import Job, Scheduler, build_scheduler, draft_renewal_invoices, install
from platform_service.signing import Keyring, Signer, format_timestamp
from platform_service.tests.support import (
    checked_payment, issued_invoice, seed_subscription, unchecked_payment)
from platform_service.tests.test_mail_queue_emulator import invite_payload

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Needs the Firestore emulator.")

NOW = datetime(2026, 11, 1, 12, 0, tzinfo=timezone.utc)


class Crash(BaseException):
    pass


class State:
    def __init__(self):
        self.now = NOW


@pytest.fixture
def world():
    project = f"demo-v5-sched-{uuid.uuid4().hex[:12]}"
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    state = State()
    state.project = project
    state.db = db

    def make(jobs, owner="replica-a", **options):
        return Scheduler(db, jobs, project_id=project, owner=owner, clock=lambda: state.now, **options)

    state.make = make
    yield state
    db.close()


def counting(name, interval=60, lease=120, action=None):
    calls = []

    def run():
        calls.append(1)
        return action() if action else {"ran": len(calls)}

    return Job(name, interval, lease, run), calls


def test_lease_prevents_two_replicas_running_the_same_job_at_once(world):
    other_results = []
    job, calls = counting("mail", action=lambda: other_results.append(second.run_due()))
    first = world.make([job], owner="replica-a")
    second = world.make([job], owner="replica-b")
    first.run_due()
    assert len(calls) == 1
    assert other_results == [{"mail": "not_due"}]






def test_fix145_a_job_that_is_still_running_keeps_its_lease_so_another_process_cannot_start_it(world):
    real = lambda: datetime.now(timezone.utc)
    seen = []

    def long():
        time.sleep(5)
        seen.append(rival.run_due())

    rival = Scheduler(world.db, [Job("mail", 60, 3, lambda: None)], project_id=world.project, owner="replica-b",
                      clock=real)
    Scheduler(world.db, [Job("mail", 60, 3, long)], project_id=world.project, owner="replica-a", clock=real).run_due()
    assert seen == [{"mail": "not_due"}]


def test_fix145_a_hung_job_stops_renewing_its_lease_after_its_maximum_run_time_so_another_process_takes_over(world):
    real = lambda: datetime.now(timezone.utc)
    seen, taken = [], []

    def hung():
        for _ in range(24):
            time.sleep(0.5)
            seen.append(rival.run_due()["mail"])

    rival = Scheduler(world.db, [Job("mail", 60, 3, lambda: taken.append(1))], project_id=world.project,
                      owner="replica-b", clock=real)
    Scheduler(world.db, [Job("mail", 60, 3, hung, max_run_seconds=4)], project_id=world.project,
              owner="replica-a", clock=real).run_due()
    assert seen[:6] == ["not_due"] * 6 and "ran" in seen and taken == [1]
    lease = world.db.collection("scheduler_leases").document("mail").get().to_dict()
    assert lease["lastRunOwner"] == "replica-b"


def test_slow_worker_cannot_overwrite_the_state_of_the_replica_that_took_over(world):
    rivals = []

    def slow():
        world.now = NOW + timedelta(seconds=300)
        rivals.append(taker.run_due())
        world.now = NOW + timedelta(seconds=310)

    slow_job, _ = counting("mail", action=slow)
    fast_job, fast_calls = counting("mail")
    taker = world.make([fast_job], owner="replica-b")
    world.make([slow_job], owner="replica-a").run_due()
    state = world.db.collection("scheduler_leases").document("mail").get().to_dict()
    assert rivals == [{"mail": "ran"}] and len(fast_calls) == 1
    assert state["lastRunOwner"] == "replica-b"














def tenant_client():
    project = f"demo-v5-gps-{uuid.uuid4().hex[:12]}"
    return firestore.Client(project=project, credentials=AnonymousCredentials())


def position(db, doc_id, age_days, collection="gps_tracking", field="timestamp"):
    db.collection(collection).document(doc_id).set(
        {"uid": "u1", "latitude": 1.5, "longitude": 110.3, field: NOW - age_days})


def remaining(db, collection="gps_tracking"):
    return sorted(snapshot.id for snapshot in db.collection(collection).stream())


def test_purge_deletes_positions_older_than_thirty_days_and_keeps_newer_ones():
    db = tenant_client()
    position(db, "age-29", timedelta(days=29))
    position(db, "age-29-23h", timedelta(days=29, hours=23))
    position(db, "age-30-exactly", timedelta(days=30))
    position(db, "age-31", timedelta(days=31))
    position(db, "age-200", timedelta(days=200))
    deleted = purge_old_positions(db, now=NOW)
    assert deleted == 2
    assert remaining(db) == ["age-29", "age-29-23h", "age-30-exactly"]
    db.close()






@pytest.mark.parametrize("days", [0, -5, True, 2.5])
def test_purge_refuses_a_retention_that_could_delete_everything(days):
    db = tenant_client()
    position(db, "fresh", timedelta(days=1))
    with pytest.raises(ValueError):
        purge_old_positions(db, now=NOW, retention_days=days)
    assert remaining(db) == ["fresh"]
    db.close()


def test_fix005_sent_and_failed_mail_and_old_rate_limits_are_deleted_after_thirty_days(world):
    world.now = NOW
    old, fresh = NOW - timedelta(days=31), NOW - timedelta(days=5)
    for tenant in ("t_alpha", "t_beta"):
        for name, status, moment in (("sent-old", "sent", old), ("failed-old", "failed", old),
                                     ("sent-new", "sent", fresh), ("queued-old", "queued", old),
                                     ("held-old", "held", old)):
            world.db.collection("mail_jobs").document(f"{tenant}-{name}").set(
                {"tenantId": tenant, "status": status, "updatedAt": format_timestamp(moment)})
        world.db.collection("rate_limits").document(f"{tenant}-old").set({"count": 1, "expiresAt": old})
        world.db.collection("rate_limits").document(f"{tenant}-new").set({"count": 1, "expiresAt": NOW + timedelta(hours=1)})
    scheduler = build_scheduler(world.db, project_id=world.project, clock=lambda: world.now)
    assert scheduler.run_due(only=["retention"]) == {"retention": "ran"}
    kept = sorted(row.id for row in world.db.collection("mail_jobs").stream())
    assert kept == sorted(f"{t}-{n}" for t in ("t_alpha", "t_beta") for n in ("sent-new", "queued-old", "held-old"))
    assert sorted(row.id for row in world.db.collection("rate_limits").stream()) == ["t_alpha-new", "t_beta-new"]


def test_fix268_kept_mail_rows_at_the_head_of_the_scan_do_not_stop_the_purge_for_other_companies(world, monkeypatch):
    from platform_service import scheduler as scheduler_module
    monkeypatch.setattr(scheduler_module, "RETENTION_SCAN_LIMIT", 4)
    monkeypatch.setattr(scheduler_module, "RETENTION_BATCH", 2)
    oldest, old = NOW - timedelta(days=60), NOW - timedelta(days=40)
    for index in range(5):
        world.db.collection("mail_jobs").document(f"t_alpha-invoice-{index}").set(
            {"tenantId": "t_alpha", "status": "sent", "kind": "invoice",
             "updatedAt": format_timestamp(oldest + timedelta(minutes=index))})
    world.db.collection("mail_jobs").document("t_beta-sent-old").set(
        {"tenantId": "t_beta", "status": "sent", "kind": "invitation", "updatedAt": format_timestamp(old)})
    scheduler = build_scheduler(world.db, project_id=world.project, clock=lambda: world.now)
    assert scheduler.run_due(only=["retention"]) == {"retention": "ran"}
    assert sorted(row.id for row in world.db.collection("mail_jobs").stream()) == sorted(
        f"t_alpha-invoice-{index}" for index in range(5))


BILLING_TENANT = "t_billingco"


def build_billing(world, monkeypatch, *, checked, start=NOW):
    monkeypatch.setattr(config, "OPS_EMAIL", "")
    signer = Signer.generate("scheduler-billing")
    directory = DirectoryStore(world.db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    directory.put({
        "tenantId": BILLING_TENANT, "workspace": "billingco", "legalName": "Billing Co Sdn Bhd",
        "companyCode": "billingco", "location": {"projectId": f"demo-bc-{world.project[-8:]}",
                                                  "databaseId": "(default)", "authTenantId": None},
        "locationKind": "byo",
        "clientConfig": {"apiKey": {"web": "AIza" + "B" * 35}, "appId": {"web": "1:222222222222:web:cccccccccccccccc"},
                         "messagingSenderId": "222222222222"},
        "status": "live", "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1",
    }, expected_version=0, now=start)
    directory.set_billing_email(BILLING_TENANT, "billing@example.test")
    mail = MailQueue(world.db, clock=lambda: world.now, enabled=True)
    store = LifecycleStore(world.db)
    service = LifecycleService(world.db, OperationStore(world.db), directory, store, access_for=company_access,
                               clock=lambda: world.now, mail=mail)
    _, first = issued_invoice(world.db, BILLING_TENANT, start, "billing-first-0001")
    book = InvoiceBook(world.db, PlanStore(world.db), clock=lambda: world.now, mail=mail)
    record = checked_payment if checked else unchecked_payment
    receipt = record(world.db, BILLING_TENANT, first, start)
    store.transition(BILLING_TENANT, "active", operation_id="billing-activate-0001", actor="owner@example.test",
                     reason="Paid", ticket=None, now=start, activation_receipt_id=receipt["entryId"])
    world.now, world.start = start, start
    world.book, world.service, world.store, world.first, world.receipt = book, service, store, first, receipt
    world.scheduler = build_scheduler(world.db, project_id=world.project, lifecycle=service, invoices=book,
                                      clock=lambda: world.now)
    return world


@pytest.fixture
def billing(world, monkeypatch):
    return build_billing(world, monkeypatch, checked=True)


@pytest.fixture
def recent_billing(world, monkeypatch):
    start = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(days=20)
    return build_billing(world, monkeypatch, checked=True, start=start)


@pytest.fixture
def unchecked_billing(world, monkeypatch):
    return build_billing(world, monkeypatch, checked=False)


def lifecycle_state(world):
    return world.store.get(BILLING_TENANT)["state"]


def mails(world, kind):
    return [row.to_dict() for row in world.db.collection("mail_jobs").stream() if row.to_dict()["kind"] == kind]


def scheduler_operations(world):
    return [row.to_dict() for row in world.db.collection("operations").stream()
            if row.to_dict()["actor"] == "scheduler"]


def delivered_unpaid_renewal(world, key="billing-second-0001", period_start=None):
    renewal = world.book.create_draft(BILLING_TENANT, key,
                                      {"periodStart": period_start or world.first["periodEnd"]}, "clerk@example.test")
    world.book.issue(renewal["invoiceId"], "clerk@example.test")
    world.book.send(renewal["invoiceId"], "clerk@example.test")
    deliver_mail(world.book.mail, now=world.now, transport=StubTransport())
    return world.book.get(renewal["invoiceId"])




def test_company_goes_past_due_fourteen_days_after_delivery_once_and_is_never_suspended(billing):
    world = billing
    renewal = delivered_unpaid_renewal(world)
    assert renewal["dueAt"] == format_timestamp(world.now + timedelta(days=14))
    world.now = NOW + timedelta(days=13)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "active" and mails(world, "past_due") == []
    world.now = NOW + timedelta(days=15)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"
    notices = mails(world, "past_due")
    assert len(notices) == 1 and notices[0]["recipient"] == "billing@example.test"
    assert "amountMinor" not in notices[0]["payload"]
    operations = scheduler_operations(world)
    assert len(operations) == 1
    assert operations[0]["action"] == "lifecycle.transition" and operations[0]["status"] == "completed"
    assert operations[0]["params"]["state"] == "past_due" and operations[0]["tenantId"] == BILLING_TENANT
    for days in (16, 40, 120):
        world.now = NOW + timedelta(days=days)
        world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due" and len(mails(world, "past_due")) == 1
    assert len(scheduler_operations(world)) == 1


def test_a_checked_payment_for_the_newest_invoice_keeps_the_company_active(billing):
    world = billing
    renewal = delivered_unpaid_renewal(world)
    world.now = NOW + timedelta(days=5)
    checked_payment(world.db, BILLING_TENANT, renewal, world.now)
    world.now = NOW + timedelta(days=30)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "active" and mails(world, "past_due") == []


def test_fix033_a_staff_set_past_due_company_is_active_again_after_a_checked_payment(billing):
    world = billing
    renewal = delivered_unpaid_renewal(world)
    world.now = NOW + timedelta(days=15)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"
    world.db.collection("lifecycle").document(BILLING_TENANT).update({"updatedBy": "staff@example.test"})
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"
    checked_payment(world.db, BILLING_TENANT, renewal, world.now)
    world.now += timedelta(hours=2)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "active"


def test_fix033_an_unchecked_payment_for_today_keeps_a_past_due_company_past_due_even_with_a_checked_future_payment(billing):
    world = billing
    world.now = NOW + timedelta(days=20)
    renewal = delivered_unpaid_renewal(world)
    world.now = NOW + timedelta(days=35)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"
    future = world.book.create_draft(BILLING_TENANT, "billing-future-0001",
                                     {"periodStart": renewal["periodEnd"]}, "clerk@example.test")
    future = world.book.issue(future["invoiceId"], "clerk@example.test")
    checked_payment(world.db, BILLING_TENANT, future, world.now)
    unchecked_payment(world.db, BILLING_TENANT, renewal, world.now)
    world.now += timedelta(hours=2)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"


def test_an_older_overdue_invoice_counts_even_when_a_newer_invoice_is_paid(billing):
    world = billing
    renewal = delivered_unpaid_renewal(world)
    world.now = NOW + timedelta(days=5)
    newer = delivered_unpaid_renewal(world, "billing-third-0001", renewal["periodEnd"])
    checked_payment(world.db, BILLING_TENANT, newer, world.now)
    world.now = NOW + timedelta(days=15)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"


def test_an_invoice_that_was_never_delivered_cannot_make_a_company_past_due(billing):
    world = billing
    draft = world.book.create_draft(BILLING_TENANT, "billing-second-0002", {"periodStart": world.first["periodEnd"]},
                                    "clerk@example.test")
    world.book.issue(draft["invoiceId"], "clerk@example.test")
    world.now = NOW + timedelta(days=25)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "active"






def test_a_later_lapse_after_reactivation_is_not_blocked_by_the_old_operation(recent_billing):
    world = recent_billing
    delivered_unpaid_renewal(world)
    world.now = world.start + timedelta(days=15)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"
    world.store.transition(BILLING_TENANT, "active", operation_id="billing-reactivate-1", actor="owner@example.test",
                           reason="Paid", ticket=None, now=world.now, activation_receipt_id=world.receipt["entryId"])
    assert lifecycle_state(world) == "active"
    world.now += timedelta(hours=1)
    world.scheduler.run_due(only=["past_due"])
    assert lifecycle_state(world) == "past_due"
    operations = scheduler_operations(world)
    assert len(operations) == 2 and {row["status"] for row in operations} == {"completed"}




def test_a_company_project_that_cannot_be_reached_keeps_the_transition_pending_until_it_can(billing):
    world = billing
    delivered_unpaid_renewal(world)
    world.now = NOW + timedelta(days=15)
    reachable = world.service.access_for

    def unreachable(location):
        raise CompanyUnreachable("No service account key is set up for this company project.")

    world.service.access_for = unreachable
    world.scheduler.run_due(only=["past_due"])
    assert [row["status"] for row in scheduler_operations(world)] == ["pending"]
    assert world.store.get(BILLING_TENANT)["state"] == "past_due"
    world.service.access_for = reachable
    projected = company_access(world.service.directory.get(BILLING_TENANT)["location"]).db.collection(
        "config").document("lifecycle")
    assert not projected.get().exists
    world.scheduler.run_due(only=["projection_reconcile"])
    assert projected.get().to_dict()["state"] == "past_due"
    world.now += timedelta(hours=2)
    world.scheduler.run_due(only=["past_due"])
    assert [row["status"] for row in scheduler_operations(world)] == ["completed"]




def test_fix005_a_bounced_invoice_still_says_the_mail_came_back_after_the_mail_purge(billing):
    world = billing
    renewal = delivered_unpaid_renewal(world)
    for row in world.db.collection("mail_jobs").stream():
        if row.to_dict().get("kind") == "invoice":
            row.reference.update({"deliveryStatus": "hard_bounce"})
    before = invoice_delivery(MailQueue(world.db, enabled=False), world.book.get(renewal["invoiceId"]))
    assert before["state"] == "not_delivered" and before["jobStatus"] == "sent"
    world.now = NOW + timedelta(days=31)
    world.scheduler.run_due(only=["retention"])
    after = invoice_delivery(MailQueue(world.db, enabled=False), world.book.get(renewal["invoiceId"]))
    assert after == before


def test_renewal_invoice_is_drafted_once_fourteen_days_before_the_checked_paid_to_date(billing):
    world = billing
    paid_to = datetime.strptime(world.first["periodEnd"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    world.now = paid_to - timedelta(days=15)
    world.scheduler.run_due(only=["invoice_drafts"])
    assert [row for row in world.book.list_invoices(BILLING_TENANT) if row["status"] == "draft"] == []
    world.now = paid_to - timedelta(days=13)
    world.scheduler.run_due(only=["invoice_drafts"])
    drafts = [row for row in world.book.list_invoices(BILLING_TENANT) if row["status"] == "draft"]
    assert len(drafts) == 1
    assert drafts[0]["periodStart"] == world.first["periodEnd"] and drafts[0]["amountMinor"] == 10000
    assert drafts[0]["number"] is None and drafts[0]["createdBy"] == "scheduler"
    world.now = paid_to - timedelta(days=10)
    world.scheduler.run_due(only=["invoice_drafts"])
    assert len(world.book.list_invoices(BILLING_TENANT)) == 2




def test_t9h_a_renewal_that_overlaps_a_later_invoice_period_is_shown_as_a_renewal_block(billing):
    world = billing
    paid_to = datetime.strptime(world.first["periodEnd"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    world.now = paid_to - timedelta(days=13)
    world.book.create_draft(BILLING_TENANT, "t9h-later-0001",
                            {"periodStart": format_timestamp(paid_to + timedelta(days=2))}, "clerk@example.test")
    counts = draft_renewal_invoices(world.db, world.book, now=world.now)
    block = world.db.collection("renewal_blocks").document(BILLING_TENANT).get().to_dict()
    assert counts == {"drafted": 0, "skipped": 0, "blocked": 1, "errors": 0}
    assert block is not None and block["reason"].startswith("An invoice already exists for this period")
    assert len(world.book.list_invoices(BILLING_TENANT)) == 2


def test_t9h_a_later_invoice_after_a_gap_does_not_block_the_renewal(billing):
    world = billing
    paid_to = datetime.strptime(world.first["periodEnd"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    world.now = paid_to - timedelta(days=13)
    world.book.create_draft(BILLING_TENANT, "t9h-after-gap-0001",
                            {"periodStart": format_timestamp(paid_to + timedelta(days=40))}, "clerk@example.test")
    counts = draft_renewal_invoices(world.db, world.book, now=world.now)
    assert counts == {"drafted": 1, "skipped": 0, "blocked": 0, "errors": 0}
    assert world.db.collection("renewal_blocks").document(BILLING_TENANT).get().to_dict() is None
    starts = sorted(row["periodStart"] for row in world.book.list_invoices(BILLING_TENANT) if row["status"] == "draft")
    assert starts[0] == world.first["periodEnd"]


def test_t9h_a_renewal_whose_start_day_already_has_an_invoice_is_skipped_without_a_block(billing):
    world = billing
    paid_to = datetime.strptime(world.first["periodEnd"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    world.now = paid_to - timedelta(days=13)
    assert draft_renewal_invoices(world.db, world.book, now=world.now)["drafted"] == 1
    draft = next(row for row in world.book.list_invoices(BILLING_TENANT) if row["status"] == "draft")
    world.book.issue(draft["invoiceId"], "clerk@example.test")
    counts = draft_renewal_invoices(world.db, world.book, now=world.now)
    assert counts == {"drafted": 0, "skipped": 1, "blocked": 0, "errors": 0}
    assert world.db.collection("renewal_blocks").document(BILLING_TENANT).get().to_dict() is None
    assert len(world.book.list_invoices(BILLING_TENANT)) == 2


def order_export(db, doc_id, age_days):
    db.collection("purge_exports").document(doc_id).set({
        "collectionName": "orders",
        "createdAt": NOW - timedelta(days=age_days),
        "orders": {"o1": {"retailerName": "Shop", "latitude": 1.5, "longitude": 110.3,
                          "locationEvidence": {"latitude": 1.5, "longitude": 110.3, "source": "gps"}}},
        "csv": "docId,latitude,locationEvidence,longitude,retailerName\no1,1.5,\"{latitude: 1.5}\",110.3,Shop\n",
    })

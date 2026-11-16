from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service.mail import (
    BrevoTransport, DeliveryRejected, MailQueue, MailUncertain, StubTransport, address_key, attachment, build_message,
    build_transport, deliver_mail,
)


pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Needs the Firestore emulator.")

NOW = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)
TENANT = "t_mailalpha"
OTHER = "t_mailbravo"


@pytest.fixture
def world():
    project = f"demo-v4-mail-{uuid.uuid4().hex[:12]}"
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    state = SimpleNamespace(db=db, now=NOW)
    state.queue = MailQueue(db, clock=lambda: state.now, enabled=True, max_attempts=3)
    yield state
    db.close()


def invite_payload(tenant_id=TENANT, **changes):
    return {"tenantId": tenant_id, "companyName": "Northwind Foods", "inviteUrl": "https://example.test/i/abc",
            "expiresAt": "2026-11-01T00:00:00Z", **changes}


def test_fix139_the_provider_gets_the_checked_one_line_value_not_the_raw_one():
    transport = StubTransport(ids={"invitation": 7})
    message = build_message("invitation", "person@example.test",
                            invite_payload(companyName="  Northwind Foods\n", expiresAt="2026-11-01T00:00:00Z"))
    transport.send(message, "fix139-key")
    sent = transport.sent[0]
    assert sent["request"]["params"]["companyName"] == "Northwind Foods"


def test_enqueue_is_tenant_scoped_and_idempotent(world):
    first = world.queue.enqueue(TENANT, "mail-invite-key-001", "invitation", "person@example.test",
                                invite_payload(), "admin-1")
    retry = world.queue.enqueue(TENANT, "mail-invite-key-001", "invitation", "person@example.test",
                                invite_payload(), "admin-1")
    with pytest.raises(ValueError):
        world.queue.enqueue(TENANT, "mail-invite-key-001", "invitation", "other@example.test",
                            invite_payload(), "admin-1")
    with pytest.raises(LookupError):
        world.queue.get(OTHER, first["jobId"])
    assert retry == first
    assert world.queue.get(TENANT, first["jobId"]) == first
    assert len(list(world.db.collection("mail_jobs").stream())) == 1




def test_transient_delivery_failure_retries_without_duplicate_job_or_delivery(world):
    job = world.queue.enqueue(TENANT, "mail-retry-key-001", "invitation", "person@example.test",
                              invite_payload(), "admin-1")
    fake = FakeTransport([DeliveryRejected("temporary", retryable=True), "provider-1"])
    first = world.queue.deliver(TENANT, job["jobId"], "worker-1", fake)
    world.now = NOW.replace(minute=2)
    second = world.queue.deliver(TENANT, job["jobId"], "worker-1", fake)
    assert first["status"] == "queued"
    assert second["status"] == "sent"
    assert len(fake.messages) == 2
    assert world.queue.get(TENANT, job["jobId"])["attempts"] == 2


def test_permanent_failure_stops_and_ambiguous_result_is_not_retried(world):
    permanent = world.queue.enqueue(TENANT, "mail-fail-key-001", "invitation", "person@example.test",
                                    invite_payload(), "admin-1")
    failed = world.queue.deliver(TENANT, permanent["jobId"], "worker-1",
                                 FakeTransport([DeliveryRejected("bad sender", retryable=False)]))
    assert failed["status"] == "failed"
    assert failed["attempts"] == 1
    uncertain = world.queue.enqueue(TENANT, "mail-uncertain-key-001", "invitation", "person@example.test",
                                    invite_payload(), "admin-1")
    transport = FakeTransport([MailUncertain("connection lost after request")])
    result = world.queue.deliver(TENANT, uncertain["jobId"], "worker-1", transport)
    with pytest.raises(ValueError):
        world.queue.deliver(TENANT, uncertain["jobId"], "worker-1", transport)
    assert result["status"] == "uncertain"
    assert len(transport.messages) == 1




NOTICE_PAYLOADS = {
    "plan_request_received": {"tenantId": TENANT, "companyName": "<Northwind> & Co", "planName": "Growth",
                              "interval": "yearly"},
    "plan_request_notice": {"tenantId": TENANT, "companyName": "<Northwind> & Co", "requesterEmail": "a@example.test",
                            "planName": "Growth", "interval": "monthly", "requestedAt": "2026-11-01T12:00:00Z"},
    "renewal_reminder": {"tenantId": TENANT, "companyName": "<Northwind> & Co", "expiresAt": "2026-11-14"},
    "status_changed": {"tenantId": TENANT, "companyName": "<Northwind> & Co", "status": "suspended"},
    "past_due": {"tenantId": TENANT, "companyName": "<Northwind> & Co"},
}








def test_active_delivery_lease_blocks_a_second_worker(world):
    job = world.queue.enqueue(TENANT, "mail-lease-key-001", "invitation", "person@example.test",
                              invite_payload(), "admin-1")
    transport = ReentrantTransport(lambda: world.queue.deliver(
        TENANT, job["jobId"], "worker-2", FakeTransport(["duplicate"])))
    sent = world.queue.deliver(TENANT, job["jobId"], "worker-1", transport)
    assert sent["status"] == "sent"
    assert transport.second_result == "blocked"


def receipt_payload(tenant_id=TENANT, **changes):
    return {"tenantId": tenant_id, "companyName": "Northwind Foods", "invoiceReference": "INV-10", "receiptNumber": "RCT-2026-000001",
            "amountMinor": 12345, "currency": "MYR", "paidAt": "2026-10-30T10:00:00Z", **changes}


def test_receipt_for_another_tenant_is_rejected_and_never_listed_across_tenants(world):
    with pytest.raises(ValueError):
        world.queue.enqueue(TENANT, "mail-receipt-key-001", "receipt", "billing@example.test",
                            receipt_payload(OTHER), "staff-1")
    assert list(world.db.collection("mail_jobs").stream()) == []
    job = world.queue.enqueue(TENANT, "mail-receipt-key-002", "receipt", "billing@example.test",
                              receipt_payload(), "staff-1")
    assert world.queue.list_jobs(OTHER) == {"jobs": [], "nextAfter": None}
    assert world.queue.list_jobs(TENANT)["jobs"] == [job]










def queue_two_jobs(world):
    first = world.queue.enqueue(TENANT, "mail-tick-key-001", "invitation", "person@example.test",
                                invite_payload(), "admin-1")
    second = world.queue.enqueue(OTHER, "mail-tick-key-002", "invitation", "other@example.test",
                                 invite_payload(OTHER), "admin-1")
    return first["jobId"], second["jobId"]


def test_delivery_tick_sends_each_queued_job_once_across_tenants(world):
    first, second = queue_two_jobs(world)
    fake = FakeTransport(["provider-1", "provider-2"])
    tick = deliver_mail(world.queue, now=world.now, limit=10, transport=fake)
    again = deliver_mail(world.queue, now=world.now, limit=10, transport=fake)
    assert sorted(tick["sent"]) == sorted([first, second])
    assert again["sent"] == [] and again["failed"] == []
    assert len(fake.messages) == 2
    assert world.queue.get(TENANT, first)["status"] == "sent"
    assert world.queue.get(OTHER, second)["status"] == "sent"










def stuck_sending(world, key, *, started, attempts=1):
    job = world.queue.enqueue(TENANT, key, "invitation", "person@example.test", invite_payload(), "admin-1")
    reference = world.db.collection("mail_jobs").document(job["jobId"])
    reference.update({"status": "sending", "attempts": attempts, "leaseToken": "dead-worker",
                      "leaseOwner": "dead-worker", "leaseExpiresAt": "2026-10-30T12:02:00Z",
                      "providerCallStartedAt": "2026-10-30T12:00:01Z" if started else None})
    return job["jobId"]




def test_expired_sending_lease_after_provider_call_becomes_uncertain_and_is_not_resent(world):
    job_id = stuck_sending(world, "mail-stuck-key-002", started=True)
    world.now = NOW + timedelta(minutes=3)
    result = world.queue.recover_expired()
    row = world.queue.get(TENANT, job_id)
    fake = FakeTransport(["must-not-send"])
    assert result["uncertain"] == [job_id]
    assert row["status"] == "uncertain" and "unknown" in row["lastFailure"]
    assert deliver_mail(world.queue, now=world.now, transport=fake)["sent"] == [] and fake.messages == []






def test_recovery_by_two_replicas_changes_the_job_once(world):
    job_id = stuck_sending(world, "mail-stuck-key-005", started=False)
    world.now = NOW + timedelta(minutes=3)
    other = MailQueue(world.db, clock=lambda: world.now, enabled=True, max_attempts=3)
    first = world.queue.recover_expired()
    second = other.recover_expired()
    assert first["requeued"] == [job_id] and second["requeued"] == []


class Interrupt(BaseException):
    pass


class CrashingTransport:
    def send(self, message, idempotency_key):
        raise Interrupt()










class FakeTransport:
    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.messages = []

    def send(self, message, idempotency_key):
        self.messages.append((message, idempotency_key))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class ReentrantTransport:
    def __init__(self, second_delivery):
        self.second_delivery = second_delivery
        self.second_result = None

    def send(self, message, idempotency_key):
        with pytest.raises(ValueError):
            self.second_delivery()
        self.second_result = "blocked"
        return "provider-once"




ACCOUNT_PAYLOADS = {
    "password_reset": {"tenantId": TENANT, "accountName": "<Northwind> & Co",
                       "resetUrl": "https://auth.example.test/action?mode=resetPassword&oobCode=abc"},
    "email_verification": {"tenantId": TENANT, "accountName": "<Northwind> & Co",
                           "verifyUrl": "https://auth.example.test/action?mode=verifyEmail&oobCode=abc"},
    "signin_alert": {"tenantId": TENANT, "accountName": "<Northwind> & Co", "device": "Chrome on Windows",
                     "at": "2026-11-03T08:00:00Z"},
    "password_changed": {"tenantId": TENANT, "accountName": "<Northwind> & Co", "at": "2026-11-03T08:00:00Z"},
}


def test_fix260_one_company_reaching_its_mail_cap_holds_only_its_own_mail_and_staff_codes_still_go():
    project = f"demo-v4-mail-{uuid.uuid4().hex[:12]}"
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    queue = MailQueue(db, clock=lambda: NOW, enabled=True, daily_cap=5, hard_cap=6,
                      company_soft_cap=2, company_hard_cap=3, staff_reserve=2)
    transport = StubTransport()
    third = "t_mailcharlie"

    def company_mail(tenant, key):
        return queue.send_now(tenant, key, "invitation", "person@example.test", invite_payload(tenant), "admin-1",
                              transport)

    def staff_code(key):
        return queue.send_now("t_platform", key, "staff_signin_code", "owner@example.test",
                              {"tenantId": "t_platform", "code": "123456", "minutes": 10}, "staff", transport)

    assert [company_mail(TENANT, f"fix260-a-{n}")["status"] for n in range(3)] == ["sent", "sent", "held"]
    assert [company_mail(OTHER, f"fix260-b-{n}")["status"] for n in range(3)] == ["sent", "sent", "held"]
    assert company_mail(third, "fix260-c-0")["heldReason"] == "daily_cap"
    assert [staff_code(f"fix260-s-{n}")["status"] for n in range(3)] == ["sent", "sent", "held"]
    own = {row.id: row.to_dict()["sent"] for row in db.collection("mail_daily").stream()}
    assert own == {"2026-10-30": 6, f"2026-10-30__{TENANT}": 2, f"2026-10-30__{OTHER}": 2,
                   "2026-10-30__t_platform": 2}
    db.close()


def test_fix269_two_sends_in_flight_together_cannot_pass_the_company_cap():
    import threading
    project = f"demo-v4-mail-{uuid.uuid4().hex[:12]}"
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    queue = MailQueue(db, clock=lambda: NOW, enabled=True, company_soft_cap=1, company_hard_cap=1)
    first_in_flight, release_first = threading.Event(), threading.Event()
    provider_calls = []

    class Gate:
        def send(self, message, idempotency_key):
            provider_calls.append(idempotency_key)
            first_in_flight.set()
            assert release_first.wait(20)
            return "provider-slow"

    first = queue.enqueue(TENANT, "fix269-key-0001", "invitation", "one@example.test", invite_payload(), "admin-1")
    worker = threading.Thread(target=lambda: queue.deliver(TENANT, first["jobId"], "w1", Gate()))
    worker.start()
    assert first_in_flight.wait(20)
    result = queue.send_now(TENANT, "fix269-key-0002", "invitation", "two@example.test", invite_payload(),
                            "admin-1", StubTransport())
    release_first.set()
    worker.join(20)
    assert result["status"] == "held" and result["heldReason"] == "daily_cap"
    assert len(provider_calls) == 1
    db.close()

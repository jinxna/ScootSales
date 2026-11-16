from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config
from platform_service.commands import CommandProblem
from platform_service.directory import DirectoryStore
from platform_service.lifecycle import LifecycleService, LifecycleStore
from platform_service.mail import MailQueue
from platform_service.operations import OperationContext, OperationStore
from platform_service.payments import PaymentLedger
from platform_service.plans import PlanStore
from platform_service.scheduler import send_renewal_reminders
from platform_service.signing import Keyring, Signer, format_timestamp
from platform_service.tests.support import checked_payment, issued_invoice, seed_catalogue, unchecked_payment

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Needs the Firestore emulator.")

NOW = datetime.now(timezone.utc).replace(microsecond=0)


def day(days):
    last_paid_day = NOW + timedelta(days=days) - timedelta(days=1)
    return last_paid_day.astimezone(timezone(timedelta(hours=8))).strftime("%Y-%m-%d")
TENANT = "t_mailtenant"


class BrokenQueue:
    enabled = True

    def enqueue_or_report(self, *args, **kwargs):
        raise RuntimeError("queue is down")


@pytest.fixture
def world(monkeypatch):
    project = f"demo-v5-companymail-{uuid.uuid4().hex[:10]}"
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    signer = Signer.generate("company-mail-test")
    directory = DirectoryStore(db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    directory.put({
        "tenantId": TENANT, "workspace": "mailtenant", "legalName": "Mail <Tenant> & Sons Sdn Bhd",
        "companyCode": "mailtenant", "location": {"projectId": f"demo-mt-{project[-8:]}", "databaseId": "(default)",
                                                   "authTenantId": None},
        "locationKind": "byo",
        "clientConfig": {"apiKey": {"web": "AIza" + "B" * 35}, "appId": {"web": "1:222222222222:web:cccccccccccccccc"},
                         "messagingSenderId": "222222222222"},
        "status": "live", "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1",
    }, expected_version=0, now=NOW)
    state = SimpleNamespace(db=db, directory=directory, now=NOW)
    state.mail = MailQueue(db, clock=lambda: state.now, enabled=True)
    state.ledger = PaymentLedger(db, clock=lambda: state.now, mail=MailQueue(db, enabled=False))
    state.lifecycle = LifecycleStore(db)
    monkeypatch.setattr(config, "OPS_EMAIL", "clerk@scoot.example")
    yield state
    db.close()


def jobs(world, kind=None):
    rows = [row.to_dict() for row in world.db.collection("mail_jobs").stream()]
    return [row for row in rows if kind is None or row["kind"] == kind]


def set_billing_email(world, email="billing@example.test"):
    world.db.collection("companies").document(TENANT).update({"billingEmail": email})


def pay(world, key, days_left, *, started_days_ago=20):
    _, invoice = issued_invoice(
        world.db, TENANT, NOW, key, period_start=format_timestamp(NOW - timedelta(days=started_days_ago)),
        period_end=format_timestamp(NOW + timedelta(days=days_left)))
    return checked_payment(world.db, TENANT, invoice, NOW)


def activate(world, receipt):
    world.lifecycle.transition(TENANT, "active", operation_id="act-" + receipt["entryId"][:20],
                               actor="owner@example.test", reason="Paid", ticket=None, now=NOW,
                               activation_receipt_id=receipt["entryId"])


def create_plan_request(world):
    seed_catalogue(world.db)
    store = PlanStore(world.db)
    request = store.create_plan_request(tenant_id=TENANT, plan_id="STANDARD", interval="yearly",
                                        requested_by="admin-a", key="request-key-0001", now=NOW)
    return store, request


def request_doc(world, request_id):
    return world.db.collection("plan_requests").document(request_id).get().to_dict()




def test_ops_notice_is_sent_at_most_once_a_day_for_each_company(world):
    store, request = create_plan_request(world)
    store.mail_plan_request(world.mail, request=request, company_name="Mail Tenant", requester_email="admin@example.test")
    world.db.collection("plan_requests").document(TENANT).update({"status": "declined"})
    later = NOW + timedelta(hours=2)
    second = store.create_plan_request(tenant_id=TENANT, plan_id="PROFESSIONAL", interval="monthly",
                                       requested_by="admin-a", key="request-key-0003", now=later)
    assert second["created"] and second["notice"] is False
    store.mail_plan_request(world.mail, request=second, company_name="Mail Tenant", requester_email="admin@example.test")
    assert len(jobs(world, "plan_request_notice")) == 1 and len(jobs(world, "plan_request_received")) == 2
    assert request_doc(world, TENANT)["mail"]["notice"]["status"] == "skipped"
    world.db.collection("plan_requests").document(TENANT).update({"status": "declined"})
    next_day = store.create_plan_request(tenant_id=TENANT, plan_id="STANDARD", interval="monthly",
                                         requested_by="admin-a", key="request-key-0004",
                                         now=NOW + timedelta(hours=25))
    assert next_day["notice"] is True










def test_reminder_is_sent_once_at_fourteen_days_with_escaped_content(world):
    set_billing_email(world)
    activate(world, pay(world, "pay-key-0001", 13))
    first = send_renewal_reminders(world.db, world.mail, now=NOW)
    again = send_renewal_reminders(world.db, world.mail, now=NOW + timedelta(hours=20))
    rows = jobs(world, "renewal_reminder")
    assert first["queued"] == 1 and again["queued"] == 0 and len(rows) == 1
    assert rows[0]["recipient"] == "billing@example.test"
    assert rows[0]["payload"]["expiresAt"] == day(13)
    notice = world.db.collection("renewal_reminders").document(f"{TENANT}_{day(13)}_14").get().to_dict()
    assert notice["status"] == "queued" and notice["jobId"] == rows[0]["jobId"]
















def lifecycle_service(world, mail):
    return LifecycleService(world.db, OperationStore(world.db), world.directory, world.lifecycle,
                            access_for=lambda _: None, clock=lambda: NOW, mail=mail)


def move(world, service, state, operation, revision, receipt=None):
    steps = service.transition_steps()
    params = {"tenantId": TENANT, "state": state, "requestedBy": "owner@example.test", "reason": "Test",
              "ticket": None, "expectedRevision": revision, "paymentEntryId": receipt}
    context = OperationContext(operation_id=operation, tenant_id=TENANT, params=params, results={})
    written = steps[0].apply(context)
    later = OperationContext(operation_id=operation, tenant_id=TENANT, params=params,
                             results={"write_lifecycle": written})
    synced = steps[2].apply(later)
    steps[3].apply(later)
    return synced


def status_jobs(world):
    return [(row["payload"]["status"], row["recipient"]) for row in jobs(world, "status_changed")]

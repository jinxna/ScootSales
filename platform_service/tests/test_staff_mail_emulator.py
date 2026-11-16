from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config, staff_api
from platform_service.directory import DirectoryStore
from platform_service.mail import MailQueue
from platform_service.operations import OperationStore
from platform_service.signing import Keyring, Signer
from platform_service.tests.test_staff_operator_emulator import (
    OPERATOR,
    OWNER,
    SUPPORT,
    UNMAPPED,
    _client_config,
    assertion,
    headers,
    staff_settings,
)

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"),
    reason="Needs the assigned shared Firestore emulator.",
)

TENANT = "t_mailpanel"
OTHER = "t_mailother"
LINK = "https://example.test/i/one-time-code-123"
BASE = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)


def company_record(tenant_id: str, workspace: str, project: str) -> dict:
    return {
        "tenantId": tenant_id, "workspace": workspace, "legalName": f"{workspace} Foods Sdn Bhd",
        "companyCode": workspace, "location": {"projectId": project, "databaseId": "(default)", "authTenantId": None},
        "locationKind": "byo", "clientConfig": _client_config("222222222222"), "status": "active",
        "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1",
    }


@pytest.fixture
def world(monkeypatch):
    project = f"demo-v5-staffmail-{uuid.uuid4().hex[:12]}"
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", project)
    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    monkeypatch.setenv("PLATFORM_MAIL_TRANSPORT", "stub")
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    signer = Signer.generate("staff-mail-test")
    store = DirectoryStore(db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    store.put(company_record(TENANT, "mailpanel", f"demo-mp-{project[-8:]}"), expected_version=0)
    store.put(company_record(OTHER, "mailother", f"demo-mo-{project[-8:]}"), expected_version=0)
    app = TestClient(staff_api.create_app(store=store, operations=OperationStore(db), signer=signer, client=db))
    state = type("World", (), {"db": db, "app": app, "tick": 0})
    state.queue = MailQueue(db, clock=lambda: BASE + timedelta(minutes=state.tick), enabled=True, max_attempts=3)
    yield state
    app.close()
    for collection in db.collections():
        for document in collection.stream():
            document.reference.delete()
    db.close()


def add_job(world, key, *, tenant=TENANT, status="queued", failure=None, minutes=0):
    world.tick = minutes
    payload = {"tenantId": tenant, "companyName": "Northwind Foods", "inviteUrl": LINK,
               "expiresAt": "2026-11-05T00:00:00Z"}
    job = world.queue.enqueue(tenant, key, "invitation", "person@example.test", payload, "admin-1")
    if status != "queued":
        world.db.collection("mail_jobs").document(job["jobId"]).update(
            {"status": status, "attempts": 1, "lastFailure": failure})
    return job["jobId"]


def jobs_path(tenant=TENANT):
    return f"/staff/v1/companies/{tenant}/mail-jobs"


def stored(world, job_id):
    return world.db.collection("mail_jobs").document(job_id).get().to_dict()


def count(world):
    return len(list(world.db.collection("mail_jobs").stream()))








def test_every_mail_route_is_owner_or_operator_only(world, assertion):
    job = add_job(world, "mailpanel-key-000", status="failed", failure="x")
    calls = [("get", jobs_path(), None), ("post", f"{jobs_path()}/{job}/retry", {}),
             ("post", f"{jobs_path()}/{job}/handled", None)]
    for method, path, body in calls:
        send = getattr(world.app, method)
        kwargs = {} if body is None else {"json": body}
        assert send(path, headers=headers(assertion, SUPPORT), **kwargs).status_code == 403, path
        assert send(path, headers=headers(assertion, UNMAPPED), **kwargs).status_code == 403, path
        assert send(path, **kwargs).status_code == 401, path
    assert count(world) == 1
    assert "retriedAs" not in stored(world, job) and "handledAt" not in stored(world, job)




def test_double_retry_returns_the_same_new_job_and_creates_no_second_one(world, assertion):
    job = add_job(world, "mailpanel-key-000", status="failed", failure="x")
    first = world.app.post(f"{jobs_path()}/{job}/retry", json={}, headers=headers(assertion))
    second = world.app.post(f"{jobs_path()}/{job}/retry", json={}, headers=headers(assertion, OPERATOR))
    assert first.status_code == 201 and second.status_code in (200, 201)
    assert second.json()["job"]["jobId"] == first.json()["job"]["jobId"]
    assert count(world) == 2




def test_retry_of_an_uncertain_job_needs_explicit_duplicate_risk_confirmation(world, assertion):
    job = add_job(world, "mailpanel-key-000", status="uncertain", failure="Outcome unknown.")
    path = f"{jobs_path()}/{job}/retry"
    for body in ({}, {"confirmDuplicateRisk": False}):
        refused = world.app.post(path, json=body, headers=headers(assertion))
        assert refused.status_code == 409 and "duplicate" in refused.text.lower()
    assert world.app.post(path, json={"confirmDuplicateRisk": "yes"}, headers=headers(assertion)).status_code == 400
    assert world.app.post(path, json={"other": 1}, headers=headers(assertion)).status_code == 400
    assert count(world) == 1 and "retriedAs" not in stored(world, job)
    accepted = world.app.post(path, json={"confirmDuplicateRisk": True}, headers=headers(assertion))
    assert accepted.status_code == 201 and count(world) == 2
    assert stored(world, job)["retriedAs"] == accepted.json()["job"]["jobId"]


def test_retry_and_handled_never_cross_tenants_and_unknown_jobs_are_404(world, assertion):
    foreign = add_job(world, "mailother-key-000", tenant=OTHER, status="failed", failure="x")
    for action, body in (("retry", {}), ("handled", None)):
        kwargs = {} if body is None else {"json": body}
        assert world.app.post(f"{jobs_path()}/{foreign}/{action}", headers=headers(assertion), **kwargs).status_code == 404
        assert world.app.post(f"{jobs_path()}/{'a' * 64}/{action}", headers=headers(assertion), **kwargs).status_code == 404
        assert world.app.post(f"{jobs_path()}/short/{action}", headers=headers(assertion), **kwargs).status_code == 404
    assert count(world) == 1 and "retriedAs" not in stored(world, foreign) and "handledAt" not in stored(world, foreign)






SECRET = "brevo-webhook-secret-" + "x" * 16


class ReceiptTransport:
    def __init__(self):
        self.sent = []

    def send(self, message, idempotency_key):
        self.sent.append(idempotency_key)
        return f"<{idempotency_key[:12]}@smtp-relay.example.test>"


def sent_job(world, key, transport):
    job = add_job(world, key)
    world.tick = 60 * 24 * 365
    assert world.queue.deliver(TENANT, job, "worker-1", transport)["status"] == "sent"
    return job


def brevo(world, events, secret=SECRET, scheme="Bearer"):
    return world.app.post("/v1/mail/brevo-events", json=events, headers={"Authorization": f"{scheme} {secret}"})


def bounce(job, event="hard_bounce", ts=1793361600, **changes):
    return {"event": event, "email": "person@example.test", "message-id": f"<{job[:12]}@smtp-relay.example.test>",
            "ts_event": ts, "reason": "mailbox unknown", "X-Mailin-custom": job, **changes}


def test_mail_events_need_the_configured_shared_secret(world, monkeypatch):
    transport = ReceiptTransport()
    job = sent_job(world, "mailpanel-key-000", transport)
    monkeypatch.delenv("PLATFORM_BREVO_WEBHOOK_SECRET", raising=False)
    assert brevo(world, bounce(job)).status_code == 503
    monkeypatch.setenv("PLATFORM_BREVO_WEBHOOK_SECRET", "short")
    assert brevo(world, bounce(job), secret="short").status_code == 503
    monkeypatch.setenv("PLATFORM_BREVO_WEBHOOK_SECRET", SECRET)
    assert brevo(world, bounce(job), secret=SECRET + "y").status_code == 401
    assert world.app.post("/v1/mail/brevo-events", json=bounce(job)).status_code == 401
    assert "deliveryStatus" not in stored(world, job)
    import base64
    basic = base64.b64encode(f"brevo:{SECRET}".encode()).decode()
    assert brevo(world, bounce(job, event="delivered"), secret=basic, scheme="Basic").json()["accepted"] == 1

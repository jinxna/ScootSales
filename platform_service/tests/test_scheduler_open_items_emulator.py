from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config
from platform_service.mail import MailQueue
from platform_service.payments import PaymentLedger
from platform_service.scheduler import expire_support_grants, staff_open_items

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"),
    reason="Needs the assigned shared Firestore emulator.",
)

OWNER = "owner@example.com"
OPERATOR = "operator@example.com"
NOW = datetime(2026, 11, 15, 4, 0, tzinfo=timezone.utc)


@pytest.fixture
def db():
    client = firestore.Client(project=f"demo-open-items-{uuid.uuid4().hex[:10]}", credentials=AnonymousCredentials())
    yield client
    for collection in client.collections():
        for document in collection.stream():
            document.reference.delete()
    client.close()


def staff(db, email, role):
    db.collection("staff").document(email).set({"email": email, "role": role, "status": "active"})


def request_by(db, email):
    db.collection("approvals").document(uuid.uuid4().hex).set(
        {"status": "requested", "requestedBy": email, "expiresAt": NOW + timedelta(days=1)})


def open_items(db, person):
    return staff_open_items(db, PaymentLedger(db, clock=lambda: NOW, mail=MailQueue(db, enabled=False)), NOW, person)


def test_a_solo_owner_sees_their_own_pending_request_counted(db, monkeypatch):
    monkeypatch.setattr(config, "SOLO_OWNER", True)
    staff(db, OWNER, "owner")
    request_by(db, OWNER)
    assert open_items(db, OWNER)["approvalsWaiting"] == 1


def test_with_two_approvers_a_person_does_not_count_their_own_request(db, monkeypatch):
    monkeypatch.setattr(config, "SOLO_OWNER", True)
    staff(db, OWNER, "owner")
    staff(db, OPERATOR, "operator")
    request_by(db, OWNER)
    assert open_items(db, OWNER)["approvalsWaiting"] == 0
    assert open_items(db, OPERATOR)["approvalsWaiting"] == 1


def test_a_support_grant_past_its_expiry_becomes_expired_and_a_live_one_stays_active(db):
    grants = db.collection("support_grants")
    grants.document("past").set({"status": "active", "revision": 1, "expiresAt": NOW - timedelta(minutes=1)})
    grants.document("live").set({"status": "active", "revision": 1, "expiresAt": NOW + timedelta(minutes=30)})
    grants.document("revoked").set({"status": "revoked", "revision": 2, "expiresAt": NOW - timedelta(minutes=1)})
    assert expire_support_grants(db, now=NOW) == {"expired": 1}
    assert expire_support_grants(db, now=NOW) == {"expired": 0}
    states = {row.id: row.to_dict()["status"] for row in grants.stream()}
    assert states == {"past": "expired", "live": "active", "revoked": "revoked"}

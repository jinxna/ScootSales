from __future__ import annotations

import base64
import json
import os
import time
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config, staff_api
from platform_service.directory import DirectoryStore
from platform_service.signing import Keyring, Signer, format_timestamp
from platform_service.tests.test_api_emulator import bearer, id_token

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)


def _segment(value):
    return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=").decode()


def stale_token(project, uid):
    now = int(time.time())
    return ".".join(
        [
            _segment({"alg": "none", "typ": "JWT"}),
            _segment(
                {
                    "aud": project,
                    "iss": f"https://securetoken.google.com/{project}",
                    "sub": uid,
                    "iat": now,
                    "exp": now + 300,
                    "auth_time": now - 900,
                    "firebase": {"sign_in_provider": "password"},
                }
            ),
            "",
        ]
    )


@pytest.fixture
def world(monkeypatch):
    suffix = uuid.uuid4().hex[:8]
    platform_project = f"demo-sp-pf-{suffix}"
    company_project = f"demo-sp-co-{suffix}"
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", platform_project)
    platform = firestore.Client(project=platform_project, credentials=AnonymousCredentials())
    company = firestore.Client(project=company_project, credentials=AnonymousCredentials())
    signer = Signer.generate("support-consent-test")
    store = DirectoryStore(platform, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)
    store.put({
        "tenantId": "t_northwind", "workspace": "northwind", "legalName": "Northwind Foods Sdn Bhd",
        "companyCode": "northwind",
        "location": {"projectId": company_project, "databaseId": "(default)", "authTenantId": None},
        "locationKind": "byo",
        "clientConfig": {"apiKey": {"web": "AIza" + "B" * 35}, "appId": {"web": "1:222222222222:web:cccccccccccccccc"},
                         "messagingSenderId": "222222222222"},
        "status": "live", "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1",
    }, expected_version=0)
    platform.collection("lifecycle").document("t_northwind").set({"state": "active", "revision": 1})
    company.collection("user_access").document("same-uid").set(
        {"accessVersion": 2, "uid": "same-uid", "status": "active", "role": "admin"})
    company.collection("user_access").document("sales-support").set(
        {"accessVersion": 2, "uid": "sales-support", "status": "active", "role": "salesman"})
    app = TestClient(staff_api.create_app(store=store, client=platform, signer=signer))
    yield type("World", (), {"app": app, "platform": platform, "company": company, "project": company_project,
                             "now": datetime.now(timezone.utc),
                             "directory": store})
    app.close()
    for client in (platform, company):
        for collection in client.collections():
            for document in collection.stream():
                document.reference.delete()
        client.close()


def create_grant(world, token, key="support-grant-create"):
    return world.app.post(
        "/v1/w/northwind/support-grants",
        headers={**bearer(token), "Idempotency-Key": key},
        json={
            "staffEmail": "e2e.support@example.test",
            "scope": "diagnostics",
            "reason": "Investigate synchronization failure",
            "expiresAt": format_timestamp(world.now + timedelta(minutes=45)),
        },
    )


def test_only_fresh_active_admin_can_create_an_idempotent_grant(world):
    admin = id_token(world.project, "same-uid")
    salesman = id_token(world.project, "sales-support")
    first = create_grant(world, admin)
    replay = create_grant(world, admin)
    changed = world.app.post(
        "/v1/w/northwind/support-grants",
        headers={**bearer(admin), "Idempotency-Key": "support-grant-create"},
        json={
            "staffEmail": "other.support@example.test",
            "scope": "diagnostics",
            "reason": "Changed intent",
            "expiresAt": format_timestamp(world.now + timedelta(minutes=45)),
        },
    )
    assert first.status_code == replay.status_code == 201
    assert replay.json() == first.json()
    assert changed.status_code == 409
    assert create_grant(world, salesman, "support-salesman-denied").status_code == 403
    assert create_grant(world, stale_token(world.project, "same-uid"), "support-stale-denied").status_code == 403
    assert world.app.post("/v1/w/northwind/support-grants", json={}).status_code == 401
    assert world.platform.collection("support_grants").document(first.json()["grantId"]).get().exists




def mounted_home(world):
    from fastapi import FastAPI, Header

    from platform_service import auth, staff_capabilities

    app = FastAPI()

    def verified_staff(x_test_email: str = Header(), x_test_role: str = Header()) -> auth.StaffIdentity:
        return auth.StaffIdentity(email=x_test_email, subject="uid-" + x_test_email, role=x_test_role)

    staff_capabilities.install_support_routes(
        app, database=world.platform, directory=world.directory, verified_staff=verified_staff)
    return TestClient(app)

from __future__ import annotations

import os
import uuid

import pytest
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config, staff_api
from platform_service.directory import DirectoryStore
from platform_service.plans import PlanStore, clean_version
from platform_service.signing import Keyring, Signer
from platform_service.tests.test_payments_api_emulator import ROLES, headers
from platform_service.tests.support import seed_usage, staff_assertion, staff_domains

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"),
    reason="Needs the assigned shared Firestore emulator.",
)

STARTER = {
    "name": "Starter", "edition": "basic", "quotaSchemaVersion": 2,
    "limits": {"salesmen": 5, "supervisors": 1, "admins": 1, "branchManagers": 1, "products": 100},
    "features": {}, "prices": None,
}


@pytest.fixture
def assertion(monkeypatch):
    monkeypatch.setattr(config, "STAFF_DOMAINS", staff_domains(ROLES))
    return staff_assertion(ROLES)


@pytest.fixture
def central(monkeypatch):
    project = f"demo-central-boundary-{uuid.uuid4().hex[:10]}"
    company_project = f"demo-northwind-{project[-8:]}"
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", project)
    monkeypatch.setattr(config, "OPERATION_LEASE_SECONDS", -1)
    platform = firestore.Client(project=project, credentials=AnonymousCredentials())
    company = firestore.Client(project=company_project, credentials=AnonymousCredentials())
    signer = Signer.generate("central-boundary-test")
    keyring = Keyring({signer.key_id: signer.public_key()})
    store = DirectoryStore(platform, keyring=keyring, signer=signer)
    record = {
        "tenantId": "t_northwind", "workspace": "northwind", "legalName": "Northwind Foods Sdn Bhd",
        "companyCode": "northwind",
        "location": {"projectId": company_project, "databaseId": "(default)", "authTenantId": None},
        "locationKind": "byo",
        "clientConfig": {"apiKey": {"web": "AIza" + "B" * 35}, "appId": {"web": "1:222222222222:web:cccccccccccccccc"},
                         "messagingSenderId": "222222222222"},
        "status": "live", "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1",
    }
    store.put(record, expected_version=0)
    seed_usage(company)
    PlanStore(platform).write_version("STARTER", clean_version(STARTER), created_by="fixture")
    app = TestClient(staff_api.create_app(store=store, client=platform, signer=signer))
    yield type("Central", (), {"app": app, "store": store, "platform": platform, "company": company,
                               "keyring": keyring, "record": record})
    app.close()
    for client in (platform, company):
        for collection in client.collections():
            for document in collection.stream():
                document.reference.delete()
        client.close()


def subscription():
    return {"planId": "STARTER", "billingInterval": "monthly", "expectedRevision": 0, "reason": "Signed agreement"}


def test_staff_subscription_projects_straight_into_the_company_project(central, assertion):
    response = central.app.post("/staff/v1/companies/t_northwind/package", json=subscription(),
                                headers=headers(assertion, key="central-subscription001"))
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "completed"
    projected = central.company.collection("config").document("plan").get().to_dict()
    assert projected["limits"]["salesmen"] == 5
    assert PlanStore(central.platform).get_subscription("t_northwind")["revision"] == 1




def test_code_lookup_returns_only_matching_signed_record_and_closes_bulk_discovery(central):
    central.store.put({**central.record, "services": {"forecastingUrl": "http://127.0.0.1:18793"}}, expected_version=1)
    response = central.app.get("/v1/companies/northwind")
    assert response.status_code == 200, response.text
    verified = central.keyring.verify(response.json(), kind="scoot.directory.record.v1")
    assert verified["companyCode"] == "northwind" and verified["tenantId"] == "t_northwind"
    assert verified["services"] == {"forecastingUrl": "http://127.0.0.1:18793"}
    assert "apiContractVersion" not in verified and "companies" not in verified
    assert central.app.get("/v1/companies/southridge").status_code == 404
    assert central.app.get("/v1/registry").status_code == 404

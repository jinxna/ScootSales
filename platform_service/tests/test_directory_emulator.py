from __future__ import annotations

import itertools
import json
import os
import urllib.request
from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Needs the Firestore emulator."
)

from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config
from platform_service.records import RecordError
from platform_service.directory import (
    CLAIMS,
    COMPANIES,
    DirectoryError,
    DirectoryStore,
)
from platform_service.signing import (
    RECORD_KIND,
    Keyring,
    Signer,
)

_counter = itertools.count(1)


@pytest.fixture(autouse=True)
def clean_database():
    host = os.environ["FIRESTORE_EMULATOR_HOST"]
    url = (
        f"http://{host}/emulator/v1/projects/{config.PLATFORM_PROJECT_ID}"
        "/databases/(default)/documents"
    )
    urllib.request.urlopen(urllib.request.Request(url, method="DELETE")).read()


@pytest.fixture
def client():
    return firestore.Client(
        project=config.PLATFORM_PROJECT_ID, credentials=AnonymousCredentials()
    )


@pytest.fixture
def signer():
    return Signer.generate("test-key-1")


@pytest.fixture
def keyring(signer):
    return Keyring({signer.key_id: signer.public_key()})


@pytest.fixture
def store(client, signer, keyring):
    return DirectoryStore(client, keyring=keyring, signer=signer)


def make_record(**overrides):
    n = next(_counter)
    tag = f"{n:04d}"
    record = {
        "tenantId": f"t_tenant{tag}",
        "workspace": f"acme{'abcdefghjkmnpqrtuvwxyz'[n % 22]}{'bdfghjkmnpqrtuvwxz'[n % 18]}{tag}",
        "legalName": f"Acme Foods {tag} Sdn Bhd",
        "companyCode": None,
        "location": {
            "projectId": f"proj{'bdfghjkmnpqrtuvwxz'[n % 18]}{'bdfghjkmnpqrtuvwxz'[(n * 5) % 18]}-{tag}",
            "databaseId": "(default)",
            "authTenantId": None,
        },
        "locationKind": "byo",
        "clientConfig": {
            "apiKey": {
                "android": "AIza" + "A" * 35,
                "web": "AIza" + "B" * 35,
            },
            "appId": {
                "android": "1:222222222222:android:aaaaaaaaaaaaaaaa",
                "web": "1:222222222222:web:cccccccccccccccc",
            },
            "messagingSenderId": "222222222222",
            "storageBucket": f"proj-{tag}.firebasestorage.app",
        },
        "status": "active",
        "planRef": "standard",
        "releaseRing": "general",
        "rulesVersion": "r1",
    }
    record.update(overrides)
    record["companyCode"] = record["companyCode"] or record["workspace"]
    return record


def raw_doc(client, tenant_id):
    return client.collection(COMPANIES).document(tenant_id)


def claim_ids(client):
    return {doc.id for doc in client.collection(CLAIMS).stream()}


def test_create_then_update_with_correct_versions(store, keyring):
    record = make_record()
    first = store.put(record, expected_version=0)
    assert keyring.verify(first, kind=RECORD_KIND)["version"] == 1

    changed = {**record, "legalName": "Acme Foods Renamed"}
    second = store.put(changed, expected_version=1)
    payload = keyring.verify(second, kind=RECORD_KIND)
    assert payload["version"] == 2
    assert store.get(record["tenantId"])["legalName"] == "Acme Foods Renamed"
    assert store.get("t_nobody00") is None


def test_stale_expected_version_is_refused(store):
    record = make_record()
    with pytest.raises(DirectoryError, match="stale version"):
        store.put(record, expected_version=1)
    store.put(record, expected_version=0)
    store.put({**record, "legalName": "Second"}, expected_version=1)
    with pytest.raises(DirectoryError, match="stale version"):
        store.put({**record, "legalName": "Old editor"}, expected_version=1)
    with pytest.raises(DirectoryError, match="stale version"):
        store.put(record, expected_version=0)
    assert store.get(record["tenantId"])["legalName"] == "Second"


def test_duplicate_workspace_is_refused(store, client):
    first = make_record()
    store.put(first, expected_version=0)
    other = make_record(workspace=first["workspace"])
    with pytest.raises(DirectoryError, match="workspace:"):
        store.put(other, expected_version=0)
    assert raw_doc(client, other["tenantId"]).get().exists is False










def test_refused_write_leaves_no_claims_behind(store, client):
    first = make_record()
    store.put(first, expected_version=0)
    before = claim_ids(client)
    clash = make_record(workspace=first["workspace"])
    with pytest.raises(DirectoryError):
        store.put(clash, expected_version=0)
    assert claim_ids(client) == before
    assert raw_doc(client, clash["tenantId"]).get().exists is False






def test_tampered_payload_is_detected(store, client):
    record = make_record()
    store.put(record, expected_version=0)
    ref = raw_doc(client, record["tenantId"])
    payload = json.loads(ref.get().to_dict()["payload"])
    payload["status"] = "deleted"
    payload["clientConfig"]["messagingSenderId"] = "999999999999"
    ref.update({"payload": json.dumps(payload, sort_keys=True, separators=(",", ":"))})
    with pytest.raises(DirectoryError, match="verification"):
        store.get(record["tenantId"])
    with pytest.raises(DirectoryError):
        store.get_envelope_by_code(record["companyCode"])
    with pytest.raises(DirectoryError):
        store.list_records()
    with pytest.raises(DirectoryError):
        store.find_by_location(**{
            "project_id": record["location"]["projectId"],
        })
    with pytest.raises(DirectoryError):
        store.put({**record, "legalName": "Edited"}, expected_version=1)






















def test_a_second_company_cannot_use_a_project_even_with_another_auth_tenant(store):
    plain = make_record(
        location={"projectId": "shared-proj", "databaseId": "(default)", "authTenantId": None}
    )
    scoped = make_record(
        location={"projectId": "shared-proj", "databaseId": "(default)", "authTenantId": "tenant-q7"}
    )
    store.put(plain, expected_version=0)
    with pytest.raises(DirectoryError, match="Already claimed by another company"):
        store.put(scoped, expected_version=0)
    assert store.find_by_location("shared-proj", "(default)", "tenant-q7") is None

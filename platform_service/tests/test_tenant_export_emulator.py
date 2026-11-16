from __future__ import annotations

import gc
import os
import hashlib
import json
import tempfile
import tracemalloc
import uuid
import zipfile
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import tenant_export

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="needs the Firestore emulator"
)


@pytest.fixture
def db():
    client = firestore.Client(project=f"demo-export-{uuid.uuid4().hex[:8]}", credentials=AnonymousCredentials())
    yield client
    client.close()


def seed(db, rows, collection="orders"):
    batch = db.batch()
    for index in range(rows):
        batch.set(db.collection(collection).document(f"d{index:06d}"),
                  {"n": index, "note": "x" * 1500 + str(index), "tag": f"t{index % 7}"})
        if (index + 1) % 400 == 0:
            batch.commit()
            batch = db.batch()
    batch.commit()


def exporter(db):
    return tenant_export.TenantExporter(SimpleNamespace(db=db), db, "t_exportone")


def test_the_package_hashes_match_and_memory_does_not_grow_with_the_collection(db):
    seed(db, 2500)
    gc.collect()
    tracemalloc.start()
    package, digest, size = exporter(db).build("uid-1")
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    assert peak < 8_000_000
    with package:
        archive = zipfile.ZipFile(package)
        manifest = json.loads(archive.read("manifest.json"))["collections"]["orders"]
        payload = archive.read("data/orders.json")
        table = archive.read("data/orders.csv")
        assert manifest["count"] == 2500 == len(json.loads(payload))
        assert manifest["jsonSha256"] == hashlib.sha256(payload).hexdigest()
        assert manifest["csvSha256"] == hashlib.sha256(table).hexdigest()
        assert table.startswith(b"\xef\xbb\xbfdocumentId,n,note,tag") and table.count(b"\r\n") == 2501
        assert json.loads(archive.read("data/retailers.json")) == [] and archive.read("data/retailers.csv") == b"\xef\xbb\xbf"
    assert db.collection("export_audit").document(digest).get().to_dict()["bytes"] == size

from __future__ import annotations

import json
import os
import uuid

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import sheet_prices

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="needs the Firestore emulator"
)

SHEETS = "retailer_score_sheet_settings"


@pytest.fixture
def project():
    return f"demo-sheet-prices-{uuid.uuid4().hex[:10]}"


@pytest.fixture
def db(project):
    client = firestore.Client(project=project, credentials=AnonymousCredentials())
    yield client
    client.close()


def seed(db):
    db.collection("products").document("P1").set({"productId": "P1", "unitPrice": 5.0})
    db.collection("products").document("P2").set({"productId": "P2", "unitPrice": 10.0, "price": 10.0})
    db.collection("products").document("P3").set({"productId": "P3", "price": 7.5})
    db.collection("products").document("P4").set({"productId": "P4", "unitPrice": 2.0, "sku": "SKU-4"})
    sheets = db.collection(SHEETS)
    sheets.document("R_frozen").set({
        "retailerId": "R_frozen", "sheetName": "Frozen", "updatedAt": "keep-me",
        "productOverrides": {
            "P1": {"unitPrice": 5.0, "price": 5.0, "packingSize": "12s", "sortOrder": 3},
            "P2": {"unitPrice": 10.01, "price": 10.01, "sortOrder": 4},
            "P3": {"unitPrice": "7.50", "price": 7.5},
            "SKU-4": {"unitPrice": 2.0, "price": 2.0, "barcode": "123"},
        }})
    sheets.document("R_mixed").set({
        "retailerId": "R_mixed",
        "productOverrides": {
            "P1": {"unitPrice": 5.0, "price": 5.5},
            "P2": {"unitPrice": 9.99, "price": 9.99},
            "GONE": {"unitPrice": 1.0, "price": 1.0},
            "P3": {"packingSize": "6s"},
        }})
    sheets.document("R_empty").set({"retailerId": "R_empty", "sheetName": "No overrides"})
    sheets.document("R_clean").set({
        "retailerId": "R_clean", "productOverrides": {"P1": {"unitPrice": 5.01, "price": 5.01}}})


def snapshot_of(db):
    return {s.id: s.to_dict() for s in db.collection(SHEETS).stream()}


def run(argv, project, capsys):
    code = sheet_prices.main(["--project", project, *argv])
    out = capsys.readouterr()
    return code, out.out, out.err




def test_apply_needs_the_matching_confirmation(db, project, capsys):
    seed(db)
    before = snapshot_of(db)
    code, _, err = run(["--apply"], project, capsys)
    assert code == 2 and "confirm" in err.lower()
    code, _, err = run(["--apply", "--confirm-project", project + "-other"], project, capsys)
    assert code == 2 and "confirm" in err.lower()
    assert snapshot_of(db) == before


def test_apply_removes_only_prices_equal_to_the_master_and_keeps_every_sheet(db, project, capsys):
    seed(db)
    before = snapshot_of(db)
    code, out, _ = run(["--apply", "--confirm-project", project], project, capsys)
    report = json.loads(out)
    assert code == 0 and report["dryRun"] is False
    assert report["pricesRemoved"] == 6 and report["overridesEqualMaster"] == 3
    after = snapshot_of(db)
    assert set(after) == set(before)
    frozen = after["R_frozen"]["productOverrides"]
    assert frozen["P1"] == {"packingSize": "12s", "sortOrder": 3}
    assert frozen["P2"] == {"unitPrice": 10.01, "price": 10.01, "sortOrder": 4}
    assert frozen["P3"] == {}
    assert frozen["SKU-4"] == {"barcode": "123"}
    assert after["R_frozen"]["updatedAt"] == "keep-me" and after["R_frozen"]["sheetName"] == "Frozen"
    assert after["R_mixed"] == before["R_mixed"]
    assert after["R_empty"] == before["R_empty"]
    assert after["R_clean"] == before["R_clean"]

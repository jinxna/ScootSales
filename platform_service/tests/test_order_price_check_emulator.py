from __future__ import annotations

import base64
import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import order_price_check as module
from platform_service.order_price_check import STATE, check_orders

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Needs the Firestore emulator.")

NOW = datetime(2026, 11, 1, 12, 0, tzinfo=timezone.utc)
SUBMITTED = NOW - timedelta(minutes=5)
LONG_AGO = NOW - timedelta(days=30)


@pytest.fixture
def db():
    project = f"demo-v5-price-{uuid.uuid4().hex[:12]}"
    client = firestore.Client(project=project, credentials=AnonymousCredentials())
    yield client
    client.close()


def product(db, product_id, price=None, *, key="unitPrice", updated=LONG_AGO, **fields):
    data = {"productName": product_id, **fields}
    if price is not None:
        data[key] = price
    if updated is not None:
        data["updatedAt"] = updated
    db.collection("products").document(product_id).set(data)


def sheet(db, retailer, overrides, *, updated=LONG_AGO):
    data = {"productOverrides": overrides}
    if updated is not None:
        data["updatedAt"] = updated
    db.collection("retailer_score_sheet_settings").document(retailer).set(data)


def line(product_id, quantity, unit_sen):
    name = base64.urlsafe_b64encode(product_id.encode()).decode().rstrip("=")
    return f"{product_id}~{name}~{quantity}~{unit_sen}"


def order(db, order_id, lines, *, total=None, retailer="R1", submitted=SUBMITTED, **fields):
    sums = sum(int(text.split("~")[2]) * int(text.split("~")[3]) for text in lines if text.count("~") == 3)
    data = {"orderId": order_id, "retailerId": retailer, "status": "submitted", "submittedAt": submitted,
            "totalPrice": (sums / 100) if total is None else total, "totalProducts": len(lines),
            "commercialSchemaVersion": 1, "commercialLines": lines, "note": "keep me", **fields}
    retailer_ref = db.collection("retailers").document(retailer)
    if not retailer_ref.get().exists:
        retailer_ref.set({"retailerId": retailer})
    db.collection("orders").document(order_id).set(data)
    return data


def stamp(db, order_id):
    return db.collection("orders").document(order_id).get().to_dict().get("serverPriceCheck")


def run(db, **options):
    return check_orders(db, now=NOW, **options)


def test_sheet_price_is_expected_and_matching_order_is_ok(db):
    product(db, "P1", 10.0)
    sheet(db, "R1", {"P1": {"unitPrice": 8.5}})
    order(db, "o1", [line("P1", 3, 850)])
    run(db)
    check = stamp(db, "o1")
    assert check["status"] == "ok" and check["reason"] is None and check["version"] == 1
    assert check["expectedTotalSen"] == 2550 and check["submittedTotalSen"] == 2550
    assert check["lines"] == [] and check["checkedAt"] == NOW


def test_master_price_charged_when_the_sheet_overrides_is_a_mismatch(db):
    product(db, "P1", 10.0)
    sheet(db, "R1", {"P1": {"unitPrice": 8.5}})
    order(db, "o1", [line("P1", 3, 1000)])
    run(db)
    check = stamp(db, "o1")
    assert check["status"] == "mismatch"
    assert check["lines"] == [{"productId": "P1", "quantity": 3, "submittedUnitSen": 1000, "expectedUnitSen": 850}]
    assert check["expectedTotalSen"] == 2550 and check["submittedTotalSen"] == 3000








def test_quantity_is_multiplied_and_a_wrong_stored_total_is_a_mismatch(db):
    product(db, "P1", 2.5)
    product(db, "P2", 1.0)
    order(db, "good", [line("P1", 4, 250), line("P2", 7, 100)])
    order(db, "bad-total", [line("P1", 4, 250), line("P2", 7, 100)], total=10.0)
    run(db)
    assert stamp(db, "good")["status"] == "ok" and stamp(db, "good")["expectedTotalSen"] == 1700
    bad = stamp(db, "bad-total")
    assert bad["status"] == "mismatch" and bad["lines"] == []
    assert bad["expectedTotalSen"] == 1700 and bad["submittedTotalSen"] == 1000








def test_price_changed_after_submission_is_unverifiable_not_a_false_mismatch(db):
    product(db, "P1", 12.0, updated=NOW - timedelta(minutes=1))
    product(db, "P2", 9.0, updated=None)
    sheet(db, "R1", {}, updated=LONG_AGO)
    order(db, "o1", [line("P1", 1, 1000)])
    order(db, "o2", [line("P2", 1, 800)])
    run(db)
    assert stamp(db, "o1")["status"] == "unverifiable" and stamp(db, "o1")["reason"] == "prices_changed_after_submission"
    assert stamp(db, "o1")["lines"] == []
    assert stamp(db, "o2")["status"] == "unverifiable"












def test_second_run_writes_nothing_and_never_overwrites_a_stamp(db):
    product(db, "P1", 10.0)
    order(db, "o1", [line("P1", 1, 1000)])
    run(db)
    reference = db.collection("orders").document("o1")
    first = reference.get()
    product(db, "P1", 99.0)
    result = run(db)
    again = reference.get()
    assert result["checked"] == 0
    assert again.update_time == first.update_time and again.to_dict() == first.to_dict()










def failing_once(monkeypatch, order_id, times=1):
    from platform_service import order_price_check as module

    real = module.price_order
    remaining = {"count": times}

    def flaky(data, book, now):
        if data.get("orderId") == order_id and remaining["count"] > 0:
            remaining["count"] -= 1
            raise RuntimeError("price book unavailable")
        return real(data, book, now)

    monkeypatch.setattr(module, "price_order", flaky)








def test_order_recreated_during_the_run_gets_no_result_from_the_old_version(db, monkeypatch):
    product(db, "P1", 10.0)
    order(db, "same", [line("P1", 1, 1000)])
    real = module.price_order

    def recreate(data, book, now):
        result = real(data, book, now)
        if data.get("note") == "keep me":
            db.collection("orders").document("same").delete()
            order(db, "same", [line("P1", 1, 500)], note="second version")
        return result

    monkeypatch.setattr(module, "price_order", recreate)
    run(db)
    assert stamp(db, "same") is None
    run(db)
    assert stamp(db, "same")["submittedTotalSen"] == 500


def test_overlapping_run_cannot_lower_the_stored_attempts(db, monkeypatch):
    product(db, "P1", 10.0)
    order(db, "race", [line("P1", 1, 1000)])
    real = module.price_order

    def other_run_counts_an_attempt(data, book, now):
        if data.get("orderId") == "race":
            db.collection("orders").document("race").update(
                {"serverPriceCheck": {"status": "pending_retry", "attempts": 2, "version": 1}})
            raise RuntimeError("price book unavailable")
        return real(data, book, now)

    monkeypatch.setattr(module, "price_order", other_run_counts_an_attempt)
    run(db)
    assert stamp(db, "race")["attempts"] == 2






def named_item(name, product_id="P1"):
    return {"productId": product_id, "name": name, "productName": name}


def named_line(product_id, name, quantity, unit_sen):
    encoded = base64.urlsafe_b64encode(name.encode()).decode().rstrip("=")
    return f"{product_id}~{encoded}~{quantity}~{unit_sen}"












def test_one_unknown_product_does_not_hide_a_wrong_price_or_name(db):
    product(db, "P1", 1.0, productName="Cheap Salt")
    order(db, "price", [named_line("P1", "Cheap Salt", 1, 50), named_line("GONE", "Gone", 1, 100)])
    order(db, "name", [named_line("P1", "Costly Cognac", 1, 100), named_line("GONE", "Gone", 1, 100)])
    order(db, "plain", [named_line("P1", "Cheap Salt", 1, 100), named_line("GONE", "Gone", 1, 100)])
    run(db)
    assert stamp(db, "price")["status"] == "mismatch" and stamp(db, "price")["reason"] == "price_differs"
    assert stamp(db, "price")["lines"] == [{"productId": "P1", "quantity": 1, "submittedUnitSen": 50, "expectedUnitSen": 100}]
    assert stamp(db, "name")["status"] == "mismatch" and stamp(db, "name")["reason"] == "name_differs"
    assert stamp(db, "plain")["status"] == "unverifiable" and stamp(db, "plain")["reason"] == "product_missing"








def test_a_retailer_that_does_not_exist_is_never_ok(db):
    product(db, "P1", 1.0, productName="Cheap Salt")
    db.collection("orders").document("made_up").set({
        "orderId": "made_up", "retailerId": "no-such-retailer", "status": "submitted", "submittedAt": SUBMITTED,
        "totalPrice": 1.0, "totalProducts": 1, "commercialSchemaVersion": 1,
        "commercialLines": [named_line("P1", "Cheap Salt", 1, 100)], "retailerName": "Grand Hypermarket",
        "outlet": "Grand Hypermarket", "items": [named_item("Cheap Salt")]})
    run(db)
    check = stamp(db, "made_up")
    assert check["status"] == "unverifiable" and check["reason"] == "retailer_missing"
    assert check["expectedTotalSen"] == 100

import json
import os
import sys
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace

from google.cloud import firestore

if os.environ.get("FIRESTORE_EMULATOR_HOST", "").rsplit(":", 1)[0] not in ("127.0.0.1", "localhost", "[::1]"):
    sys.exit("Refusing to run: FIRESTORE_EMULATOR_HOST must name a local emulator, so no test reaches a real project.")
db = firestore.Client(project=os.environ["RULES_TEST_PROJECT"])


def rows(name):
    return [{**snapshot.to_dict(), "docId": snapshot.id} for snapshot in db.collection(name).stream()]


def price():
    from platform_service.order_price_check import check_orders

    counts = check_orders(db)
    orders = {}
    for snapshot in db.collection("orders").stream():
        stamp = (snapshot.to_dict() or {}).get("serverPriceCheck") or {}
        orders[snapshot.id] = {"status": stamp.get("status"), "reason": stamp.get("reason"),
                               "names": [entry.get("kind") for entry in stamp.get("names") or []]}
    return {"counts": counts, "orders": orders}


def ranking(order_id, retailer_id):
    from forecasting.ai_service.generator import _last_order_date_by_retailer, build_generation
    from forecasting.ai_service.normalization import normalize_firestore_inputs

    order = {**db.collection("orders").document(order_id).get().to_dict(), "docId": order_id}
    products = rows("products")
    retailers = rows("retailers")
    users = rows("users")
    as_of = datetime.now(timezone.utc).date() + timedelta(days=7)

    def case(orders):
        data = normalize_firestore_inputs(
            orders=orders, products=products, retailers=retailers, users=users, as_of=as_of)
        series = [item for item in data.series if item.retailer_id == retailer_id]
        result = {
            "seriesForRetailer": len(series),
            "seriesOwnerCode": series[0].salesman_code if series else None,
            "seriesQuantity": sum(point.quantity for point in series[0].observations) if series else 0,
            "lastContactSet": retailer_id in _last_order_date_by_retailer(orders, as_of=as_of),
        }
        generated = build_generation(
            data, as_of=as_of, run_id="regression", generated_at=datetime.now(timezone.utc), orders=orders)
        ranked = None
        for document in generated.priority_rankings:
            if document.get("salesmanCode") != "S002":
                continue
            for entry in document.get("ranking") or []:
                if isinstance(entry, dict) and entry.get("retailerId") == retailer_id:
                    ranked = entry
        result["rankedUnderOwner"] = ranked is not None
        result["rankedEntryValues"] = {
            key: value for key, value in (ranked or {}).items() if isinstance(value, (int, float, bool))}
        return result

    return {
        "none": case([]),
        "submitted": case([order]),
        "rejected": case([{**order, "status": "rejected"}]),
    }


def lapse(good_uid, bad_uid, bad_profile):
    from platform_service.lifecycle import TenantLifecycle

    service = TenantLifecycle(SimpleNamespace(db=db))
    service.project({
        "tenantId": "t_regressrules", "state": "suspended", "revision": 1,
        "stateSince": datetime(2026, 11, 1, tzinfo=timezone.utc), "graceEndsAt": None,
        "windowEndsAt": datetime(2026, 11, 3, tzinfo=timezone.utc),
        "retentionEndsAt": datetime(2026, 11, 30, tzinfo=timezone.utc),
    })
    out = {}
    for uid in (good_uid, bad_uid):
        reference = db.collection("user_access").document(uid)
        added = service._add_reason(reference, 1, "billing_lapse")
        data = reference.get().to_dict() or {}
        out[uid] = {"added": added, "accessVersion": data.get("accessVersion"), "disabledReasons": data.get("disabledReasons")}
    out["profile"] = (db.collection("users").document(bad_profile).get().to_dict() or {}).get("disabledReasons")
    return out


COMMANDS = {"price": price, "ranking": ranking, "lapse": lapse}

if __name__ == "__main__":
    print(json.dumps(COMMANDS[sys.argv[1]](*sys.argv[2:]), default=str))

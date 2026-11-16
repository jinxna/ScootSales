from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Mapping

from google.cloud import firestore

from .migrate_seats import _client

SHEETS = "retailer_score_sheet_settings"
PRODUCTS = "products"
PRODUCT_KEYS = ("productId", "itemId", "sku", "productCode", "itemCode", "barcode")
MASTER_PRICE_KEYS = ("unitPrice", "price")
SHEET_PRICE_KEYS = ("unitPrice", "price")


def _sen(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    else:
        try:
            number = float(str(value).replace("RM", "").replace(",", "").strip())
        except ValueError:
            return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return round(number * 100)


def master_prices(db: Any) -> dict[str, int | None]:
    prices: dict[str, set[int]] = {}
    for snapshot in db.collection(PRODUCTS).stream():
        data = snapshot.to_dict() or {}
        sen = next((_sen(data[key]) for key in MASTER_PRICE_KEYS if data.get(key) is not None), None)
        aliases = {snapshot.id} | {data[key] for key in PRODUCT_KEYS if isinstance(data.get(key), str) and data[key]}
        for alias in aliases:
            prices.setdefault(alias, set()).add(sen if sen is not None and sen > 0 else -1)
    return {alias: (next(iter(values)) if len(values) == 1 and -1 not in values else None)
            for alias, values in prices.items()}


def _frozen_keys(override: Mapping[str, Any], master: int | None) -> tuple[str, list[str]]:
    present = [key for key in SHEET_PRICE_KEYS if override.get(key) is not None]
    if not present:
        return "none", []
    if master is None:
        return "withoutMaster", []
    values = {_sen(override[key]) for key in present}
    if len(values) != 1:
        return "disagreeing", []
    return ("equal", present) if values == {master} else ("different", [])


def plan_sheet(data: Mapping[str, Any], masters: Mapping[str, int | None]) -> dict[str, Any]:
    overrides = data.get("productOverrides")
    plan: dict[str, Any] = {"remove": {}, "withoutMaster": 0, "disagreeing": 0}
    if not isinstance(overrides, Mapping):
        return plan
    for product_id, override in overrides.items():
        if not isinstance(override, Mapping):
            continue
        state, keys = _frozen_keys(override, masters.get(product_id))
        if state == "equal":
            plan["remove"][product_id] = keys
        elif state == "withoutMaster":
            plan["withoutMaster"] += 1
        elif state == "disagreeing":
            plan["disagreeing"] += 1
    return plan


def scan(db: Any) -> dict[str, Any]:
    masters = master_prices(db)
    sheets: dict[str, dict[str, Any]] = {}
    scanned = 0
    without_master = disagreeing = 0
    for snapshot in db.collection(SHEETS).stream():
        scanned += 1
        plan = plan_sheet(snapshot.to_dict() or {}, masters)
        without_master += plan["withoutMaster"]
        disagreeing += plan["disagreeing"]
        if plan["remove"]:
            sheets[snapshot.id] = plan["remove"]
    return {"masters": masters, "sheets": sheets, "scanned": scanned,
            "withoutMaster": without_master, "disagreeing": disagreeing}


def apply_plan(db: Any, scanned: Mapping[str, Any]) -> dict[str, int]:
    removed = changed = 0
    for sheet_id in scanned["sheets"]:
        ref = db.collection(SHEETS).document(sheet_id)

        @firestore.transactional
        def clean(transaction: firestore.Transaction) -> int:
            snapshot = ref.get(transaction=transaction)
            if not snapshot.exists:
                return -1
            data = snapshot.to_dict() or {}
            fresh = plan_sheet(data, scanned["masters"])["remove"]
            if not fresh:
                return 0
            overrides = {key: dict(value) if isinstance(value, Mapping) else value
                         for key, value in data["productOverrides"].items()}
            count = 0
            for product_id, keys in fresh.items():
                for key in keys:
                    del overrides[product_id][key]
                    count += 1
            transaction.update(ref, {"productOverrides": overrides})
            return count

        result = clean(db.transaction())
        if result <= 0:
            changed += 1
        else:
            removed += result
    return {"pricesRemoved": removed, "changedDuringApply": changed}


def report(project: str, scanned: Mapping[str, Any], applied: Mapping[str, int] | None) -> dict[str, Any]:
    result = {
        "projectId": project,
        "dryRun": applied is None,
        "sheetsScanned": scanned["scanned"],
        "sheetsAffected": len(scanned["sheets"]),
        "overridesEqualMaster": sum(len(overrides) for overrides in scanned["sheets"].values()),
        "overridesWithoutMaster": scanned["withoutMaster"],
        "overridesWithDisagreeingPrices": scanned["disagreeing"],
        "affectedSheetIds": sorted(scanned["sheets"]),
    }
    if applied is not None:
        result.update(applied)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Remove sheet prices that equal the master price.")
    parser.add_argument("--project", required=True, help="tenant Firebase project ID")
    parser.add_argument("--database", default="(default)", help="Firestore database ID")
    parser.add_argument("--apply", action="store_true", help="write the changes (default: print only)")
    parser.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    args = parser.parse_args(argv)
    if args.apply and args.confirm_project != args.project:
        print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
        return 2
    db = _client(args.project, args.database)
    if args.apply and args.confirm_project != db.project:
        print("--confirm-project does not match the opened project.", file=sys.stderr)
        return 2
    scanned = scan(db)
    applied = apply_plan(db, scanned) if args.apply else None
    print(json.dumps(report(db.project, scanned, applied), indent=2, sort_keys=True))
    return 3 if applied and applied["changedDuringApply"] else 0


if __name__ == "__main__":
    sys.exit(main())

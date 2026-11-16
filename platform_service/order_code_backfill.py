from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from typing import Any, Mapping

from google.cloud import firestore

from .access_migration import LINK_KEYS, UID_KEYS, _identity, _text
from .migrate_seats import _client

CODE_FIELD = "salesmanCode"
ORDER_FIELDS = (CODE_FIELD, "salesman_code", "salesmanUid", "salesman_uid")


def has_code(order: Mapping[str, Any]) -> bool:
    return bool(_text(order, CODE_FIELD, "salesman_code").strip())


def person_codes(uid: str, access_rows: Mapping[str, Mapping[str, Any]],
                 profiles: Mapping[str, Mapping[str, Any]]) -> set[str]:
    sources: list[Mapping[str, Any]] = []
    access = access_rows.get(uid)
    if access is not None:
        sources.append(access)
        link_id = _text(access, *LINK_KEYS).strip()
        if link_id in profiles:
            sources.append(profiles[link_id])
    sources.extend(profile for profile in profiles.values() if _text(profile, *UID_KEYS) == uid)
    return {code for code in (_identity(source)["employeeCode"].strip() for source in sources) if code}


def plan_code_backfill(db: Any, access_rows: Mapping[str, Mapping[str, Any]] | None = None,
                       profiles: Mapping[str, Mapping[str, Any]] | None = None) -> dict[str, list[Any]]:
    if access_rows is None:
        access_rows = {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection("user_access").stream()}
    if profiles is None:
        profiles = {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection("users").stream()}
    codes_by_uid: dict[str, set[str]] = {}
    convertible: list[dict[str, str]] = []
    skipped: list[dict[str, str]] = []
    for snapshot in db.collection("orders").select(list(ORDER_FIELDS)).stream():
        data = snapshot.to_dict() or {}
        if has_code(data):
            continue
        uid = _text(data, "salesmanUid", "salesman_uid").strip()
        if not uid:
            skipped.append({"id": snapshot.id, "reason": "the order has no salesman uid"})
            continue
        if uid not in codes_by_uid:
            codes_by_uid[uid] = person_codes(uid, access_rows, profiles)
        codes = codes_by_uid[uid]
        if not codes:
            skipped.append({"id": snapshot.id, "reason": "no person with an employee code for this uid"})
        elif len(codes) > 1:
            skipped.append({"id": snapshot.id, "reason": "the person records give different employee codes"})
        else:
            convertible.append({"id": snapshot.id, "uid": uid, "code": next(iter(codes))})
    return {"convertible": convertible, "skipped": skipped}


def apply_code_backfill(db: Any, plan: Mapping[str, list[Any]]) -> dict[str, Any]:
    written = 0
    changed: list[str] = []
    for entry in plan["convertible"]:
        reference = db.collection("orders").document(entry["id"])

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                return False
            data = snapshot.to_dict() or {}
            if has_code(data) or _text(data, "salesmanUid", "salesman_uid").strip() != entry["uid"]:
                return False
            transaction.update(reference, {CODE_FIELD: entry["code"]})
            return True

        if write(db.transaction()):
            written += 1
        else:
            changed.append(entry["id"])
    return {"written": written, "changedDuringApply": changed}


def summary(plan: Mapping[str, list[Any]]) -> dict[str, Any]:
    reasons = Counter(item["reason"] for item in plan["skipped"])
    return {"convertible": len(plan["convertible"]), "skipped": plan["skipped"], "skippedByReason": dict(reasons)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Add the salesperson employee code to orders that have none.")
    parser.add_argument("--project", required=True, help="company Firebase project ID")
    parser.add_argument("--database", default="(default)", help="Firestore database ID")
    parser.add_argument("--apply", action="store_true", help="write the orders (default: print only)")
    parser.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    args = parser.parse_args(argv)
    if args.apply and args.confirm_project != args.project:
        print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
        return 2
    db = _client(args.project, args.database)
    if args.apply and args.confirm_project != db.project:
        print("--confirm-project does not match the opened project.", file=sys.stderr)
        return 2
    plan = plan_code_backfill(db)
    applied = apply_code_backfill(db, plan) if args.apply else None
    print(json.dumps({"project": db.project, "mode": "apply" if applied is not None else "dry-run",
                      **summary(plan), **({"applied": applied} if applied is not None else {})},
                     indent=2, sort_keys=True))
    return 3 if applied and applied["changedDuringApply"] else 0


if __name__ == "__main__":
    sys.exit(main())

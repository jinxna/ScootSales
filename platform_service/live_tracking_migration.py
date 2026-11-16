from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from google.cloud import firestore

from .migrate_seats import _client

COLLECTION = "live_tracking"


def _owner(data: dict[str, Any]) -> Any:
    return data.get("salesmanUid") or data.get("userUid")


def plan_uid_backfill(db: firestore.Client) -> dict[str, list[Any]]:
    convertible: list[str] = []
    skipped: list[dict[str, str]] = []
    for snapshot in db.collection(COLLECTION).stream():
        data = snapshot.to_dict() or {}
        if "uid" in data:
            continue
        if _owner(data) == snapshot.id:
            convertible.append(snapshot.id)
        else:
            skipped.append({"id": snapshot.id, "reason": "salesmanUid does not match the document ID"})
    return {"convertible": convertible, "skipped": skipped}


def apply_uid_backfill(db: firestore.Client, plan: dict[str, list[Any]]) -> dict[str, Any]:
    written = 0
    changed: list[str] = []
    for uid in plan["convertible"]:
        reference = db.collection(COLLECTION).document(uid)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool:
            snapshot = reference.get(transaction=transaction)
            data = snapshot.to_dict() or {}
            if not snapshot.exists or "uid" in data or _owner(data) != uid:
                return False
            transaction.update(reference, {"uid": uid})
            return True

        if write(db.transaction()):
            written += 1
        else:
            changed.append(uid)
    return {"written": written, "changedDuringApply": changed}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Add the owner uid to live_tracking rows written before work sessions.")
    parser.add_argument("--project", required=True, help="company Firebase project ID")
    parser.add_argument("--database", default="(default)", help="Firestore database ID")
    parser.add_argument("--apply", action="store_true", help="write the rows (default: print only)")
    parser.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    args = parser.parse_args(argv)
    if args.apply and args.confirm_project != args.project:
        print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
        return 2
    db = _client(args.project, args.database)
    if args.apply and args.confirm_project != db.project:
        print("--confirm-project does not match the opened project.", file=sys.stderr)
        return 2
    plan = plan_uid_backfill(db)
    applied = apply_uid_backfill(db, plan) if args.apply else None
    print(json.dumps({"project": db.project, "mode": "apply" if applied is not None else "dry-run",
                      **plan, **({"applied": applied} if applied is not None else {})}, indent=2, sort_keys=True))
    return 3 if applied and applied["changedDuringApply"] else 0


if __name__ == "__main__":
    sys.exit(main())

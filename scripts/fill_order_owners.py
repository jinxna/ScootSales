from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from google.cloud import firestore

from platform_service import config

OWNER_FIELDS = ("salesmanUid", "salesman_uid", "uid", "userUid", "submittedByUid", "createdByUid")
CONTROL_CENTRE_MARKERS = ("scheduler_leases", "lifecycle")


def text(data: dict[str, Any], *names: str) -> str:
    for name in names:
        value = data.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def is_control_centre(db: firestore.Client) -> bool:
    if db.project.lower() == (config.PLATFORM_PROJECT_ID or "").lower():
        return True
    return any(list(db.collection(name).limit(1).stream()) for name in CONTROL_CENTRE_MARKERS)


def plan(db: firestore.Client) -> list[dict[str, Any]]:
    holders: dict[str, list[str]] = {}
    for snapshot in db.collection("users").stream():
        code = text(snapshot.to_dict() or {}, "employeeCode")
        if code:
            holders.setdefault(code, []).append(snapshot.id)
    rows = []
    for snapshot in db.collection("orders").stream():
        data = snapshot.to_dict() or {}
        if text(data, *OWNER_FIELDS):
            continue
        code = text(data, "salesmanCode", "salesman_code")
        uids = sorted(holders.get(code, [])) if code else []
        status = "no_code" if not code else "fill" if len(uids) == 1 else "no_person" if not uids else "ambiguous"
        rows.append({"orderId": snapshot.id, "salesmanCode": code or None, "status": status,
                     "salesmanUid": uids[0] if status == "fill" else None, "peopleWithCode": uids})
    return sorted(rows, key=lambda row: row["orderId"])


def fill(db: firestore.Client, row: dict[str, Any]) -> bool:
    reference = db.collection("orders").document(row["orderId"])

    @firestore.transactional
    def write(transaction: firestore.Transaction) -> bool:
        data = reference.get(transaction=transaction).to_dict() or {}
        if text(data, *OWNER_FIELDS) or text(data, "salesmanCode", "salesman_code") != row["salesmanCode"]:
            return False
        transaction.update(reference, {"salesmanUid": row["salesmanUid"]})
        return True

    return write(db.transaction(max_attempts=10))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="List the orders of one company that have no owner id, with the one person who holds the "
                    "order's salesman code, and write that owner with --apply. Orders whose code no person or more "
                    "than one person holds are listed and never changed. The default is a dry run that writes "
                    "nothing.")
    parser.add_argument("--project", required=True, help="the company's Firebase project ID")
    parser.add_argument("--apply", action="store_true", help="write the owner of the orders marked fill")
    parser.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    args = parser.parse_args(argv)
    if args.apply and args.confirm_project != args.project:
        print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
        return 2
    db = firestore.Client(project=args.project)
    if args.apply and args.confirm_project != db.project:
        print("--confirm-project does not match the opened project.", file=sys.stderr)
        return 2
    if is_control_centre(db):
        print("This is the Control Centre project. Run this script on one company's project.", file=sys.stderr)
        return 2
    found = plan(db)
    report: dict[str, Any] = {"project": db.project, "mode": "apply" if args.apply else "dry-run",
                              "orders": found, "count": len(found)}
    if args.apply:
        due = [row for row in found if row["status"] == "fill"]
        written = [row["orderId"] for row in due if fill(db, row)]
        report["written"] = written
        report["changedDuringApply"] = [row["orderId"] for row in due if row["orderId"] not in written]
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    return 3 if args.apply and report["changedDuringApply"] else 0


if __name__ == "__main__":
    sys.exit(main())

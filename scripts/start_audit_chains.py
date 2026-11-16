from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from google.cloud import firestore

from platform_service.audit import CHAIN, DIGESTS, GENESIS, PLATFORM_CHAIN, STARTS, chain_doc_id
from platform_service.directory import COMPANIES
from platform_service.ids import local_date, utc_now


def last_shared_seal(db: firestore.Client, today: str) -> tuple[str | None, str]:
    days = sorted(snapshot.id for snapshot in db.collection(CHAIN).stream()
                  if "chain" not in (snapshot.to_dict() or {}) and snapshot.id <= today)
    if not days:
        return None, GENESIS
    day = days[-1]
    digest = db.collection(DIGESTS).document(day).get()
    sealed = (digest.to_dict() or {}).get("headHash") if digest.exists else None
    if sealed:
        return day, sealed
    return day, (db.collection(CHAIN).document(day).get().to_dict() or {}).get("lastHash", GENESIS)


def plan(db: firestore.Client, today: str) -> list[dict[str, Any]]:
    seeded_from, seed = last_shared_seal(db, today)
    chains = [PLATFORM_CHAIN, *sorted(snapshot.id for snapshot in db.collection(COMPANIES).stream())]
    rows = []
    for chain in chains:
        if db.collection(STARTS).document(chain).get().exists:
            status = "started"
        elif db.collection(CHAIN).document(chain_doc_id(today, chain)).get().exists:
            status = "has_events_today"
        else:
            status = "start"
        rows.append({"chain": chain, "fromDay": today, "seedHash": seed, "seededFromDay": seeded_from,
                     "status": status})
    return rows


def start(db: firestore.Client, row: dict[str, Any]) -> bool:
    start_ref = db.collection(STARTS).document(row["chain"])
    head_ref = db.collection(CHAIN).document(chain_doc_id(row["fromDay"], row["chain"]))

    @firestore.transactional
    def write(transaction: firestore.Transaction) -> bool:
        if start_ref.get(transaction=transaction).exists or head_ref.get(transaction=transaction).exists:
            return False
        transaction.create(start_ref, {key: row[key] for key in ("chain", "fromDay", "seedHash", "seededFromDay")})
        return True

    return write(db.transaction(max_attempts=10))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Start one audit chain for each company and one for the platform, each linked to the last "
                    "hash of the old shared chain. The default is a dry run that writes nothing. Emulator only.")
    parser.add_argument("--project", required=True, help="the Control Centre Firebase project ID")
    parser.add_argument("--apply", action="store_true", help="write the chain starts of the rows marked start")
    parser.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    args = parser.parse_args(argv)
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print("This script runs only against the Firestore emulator. Set FIRESTORE_EMULATOR_HOST.", file=sys.stderr)
        return 2
    if args.apply and args.confirm_project != args.project:
        print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
        return 2
    db = firestore.Client(project=args.project)
    if not list(db.collection(COMPANIES).limit(1).stream()):
        print("This project has no company directory. Run this script on the Control Centre project.",
              file=sys.stderr)
        return 2
    found = plan(db, local_date(utc_now()))
    report: dict[str, Any] = {"project": db.project, "mode": "apply" if args.apply else "dry-run", "rows": found}
    if args.apply:
        due = [row for row in found if row["status"] == "start"]
        written = [row["chain"] for row in due if start(db, row)]
        report["written"] = written
        report["changedDuringApply"] = [row["chain"] for row in due if row["chain"] not in written]
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    return 3 if args.apply and report["changedDuringApply"] else 0


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter

PROGRESS = "route_plan_progress"
DEFAULT_READ_CAP = 5000
MAX_READ_CAP = 20000


def count(db: firestore.Client, days: int, read_cap: int) -> dict:
    since = datetime.now(timezone.utc) - timedelta(days=days)
    query = db.collection(PROGRESS).where(filter=FieldFilter("lastHeartbeatAt", ">=", since)).limit(read_cap + 1)
    reads = 0
    salesmen: set[str] = set()
    for doc in query.stream():
        reads += 1
        if reads > read_cap:
            break
        salesmen.add(str(doc.to_dict().get("salesmanUid")))
    return {
        "project": db.project,
        "windowDays": days,
        "readsUsed": min(reads, read_cap),
        "readCap": read_cap,
        "capReached": reads > read_cap,
        "withRecentHeartbeat": min(reads, read_cap),
        "distinctSalesmenWithHeartbeat": len(salesmen),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Count recent route heartbeats. Read only.")
    parser.add_argument("--project", required=True)
    parser.add_argument("--confirm-project", required=True)
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--read-cap", type=int, default=DEFAULT_READ_CAP)
    args = parser.parse_args(argv)
    if args.confirm_project != args.project:
        print("--confirm-project must equal --project.", file=sys.stderr)
        return 2
    if not 1 <= args.read_cap <= MAX_READ_CAP:
        print(f"--read-cap must be from 1 to {MAX_READ_CAP}.", file=sys.stderr)
        return 2
    report = count(firestore.Client(project=args.project), args.days, args.read_cap)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 3 if report["capReached"] else 0


if __name__ == "__main__":
    sys.exit(main())

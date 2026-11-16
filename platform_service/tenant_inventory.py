from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from typing import Any

from firebase_admin import auth as admin_auth

from .access_migration import plan_access_migration
from .migrate_seats import _client


def _split(plan: dict[str, Any], source: str) -> dict[str, Any]:
    convertible = sum(1 for row in plan["convertible"] if row["source"] == source)
    refused = Counter(row["reason"] for row in plan["cannotConvert"] if row["source"] == source)
    return {"total": convertible + sum(refused.values()), "convertible": convertible, "byReason": dict(refused)}


def has_captured_line_prices(order: dict[str, Any]) -> bool:
    version = order.get("commercialSchemaVersion")
    lines = order.get("commercialLines")
    return type(version) is int and version >= 1 and isinstance(lines, list) and len(lines) > 0


def inventory(db: Any, auth_client: admin_auth.Client | None = None) -> dict[str, Any]:
    plan = plan_access_migration(db, auth_client)
    total = 0
    missing: Counter[str] = Counter()
    for snapshot in db.collection("orders").select(["commercialSchemaVersion", "commercialLines", "status"]).stream():
        total += 1
        data = snapshot.to_dict() or {}
        if not has_captured_line_prices(data):
            missing[str(data.get("status", ""))] += 1
    return {
        "legacyAccessRows": _split(plan, "access"),
        "uidOnlyProfiles": _split(plan, "uid_profile"),
        "v2Rows": plan["alreadyV2"],
        "unlinkedProfiles": len(plan["unlinkedProfiles"]),
        "orders": {
            "total": total,
            "withoutCapturedLinePrices": sum(missing.values()),
            "withoutCapturedLinePricesByStatus": dict(missing),
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only access and order inventory of a tenant project.")
    parser.add_argument("--project", required=True, help="tenant Firebase project ID")
    parser.add_argument("--database", default="(default)", help="Firestore database ID")
    args = parser.parse_args(argv)
    print(json.dumps({"project": args.project, **inventory(_client(args.project, args.database))},
                     indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

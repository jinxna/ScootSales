from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

BACKFILL_HELP = """Stamp the canonical owner key onto legacy orders.

The mobile order history reads `orders where salesmanUid == <signed-in uid>`.
Orders written before the owner key became mandatory carry only an employee code
(`staffId` / `employeeCode` / `salesmanCode`), so the salesperson who placed
them cannot see them. This script stamps `salesmanUid` on exactly those
documents, and only when the document's own code resolves to one profile.

Safety
------
* Dry run by default. `--apply` requires `--project dev|demo` and the matching
  `--confirm APPLY-<project id>` token, the same shape the AI runner uses, and
  the same client helper, so the demo target is loopback-only and a real target
  needs real credentials.
* The only fields written are `salesmanUid`, `salesmanCode` (when the order
  has none, copied from its own `salesmanId` / `staffId`, so supervisor scoping
  can find it), `identityBackfill` and `identityBackfilledAt`. Nothing is
  deleted and no other field is touched.
* Idempotent: a document that already carries `salesmanUid` is skipped, so a
  second run writes nothing at all.
* A code that resolves to no profile, or to more than one uid, is skipped; so is
  a branch mismatch and any `isDemo` record.

Usage
-----
    python admin_dashboard/scripts/backfill_order_identity.py
    python admin_dashboard/scripts/backfill_order_identity.py --apply --project \
        demo --confirm APPLY-demo-fyp-a
"""

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from forecasting.ai_service.repository import (  # noqa: E402
    RUNNER_PROJECT_IDS,
    create_firestore_client,
)

BACKFILL_VERSION = "order-identity-backfill/1.0.0"
TARGET_COLLECTION = "orders"
PROFILE_COLLECTIONS = ("users", "user_access")
DEFAULT_ORDER_CAP = 20000

CODE_FIELDS = (
    "staffId",
    "employeeCode",
    "employee_code",
    "salesmanCode",
    "salesman_code",
    "salesmanId",
)
UID_FIELDS = ("uid", "userUid", "salesmanUid", "submittedByUid")
BRANCH_FIELDS = ("branchId", "branch_id")


@dataclass(frozen=True)
class Decision:
    order_id: str
    action: str
    reason: str
    uid: str = ""
    code: str = ""


def _first_text(record: Mapping[str, Any], fields: Sequence[str]) -> str:
    for field in fields:
        value = record.get(field)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return ""


def _all_text(record: Mapping[str, Any], fields: Sequence[str]) -> set[str]:
    values: set[str] = set()
    for field in fields:
        value = record.get(field)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            values.add(text)
    return values


def _looks_like_auth_uid(value: str) -> bool:
    return len(value) >= 20 and value.isalnum()


def profile_uid(profile: Mapping[str, Any]) -> str:
    declared = _first_text(profile, UID_FIELDS)
    if declared:
        return declared
    document_id = str(profile.get("docId") or "").strip()
    if not document_id:
        return ""
    if str(profile.get("collection") or "") == "user_access":
        return document_id
    return document_id if _looks_like_auth_uid(document_id) else ""


def plan_identity_backfill(
    orders: Iterable[Mapping[str, Any]],
    profiles: Iterable[Mapping[str, Any]],
) -> tuple[Decision, ...]:
    uid_by_code: dict[str, set[str]] = {}
    branch_by_uid: dict[str, str] = {}
    for profile in profiles:
        uid = profile_uid(profile)
        if not uid:
            continue
        for code in _all_text(profile, CODE_FIELDS):
            uid_by_code.setdefault(code, set()).add(uid)
        branch = _first_text(profile, BRANCH_FIELDS)
        if branch:
            branch_by_uid.setdefault(uid, branch)

    decisions: list[Decision] = []
    ordered = sorted(
        orders,
        key=lambda row: str(row.get("docId") or row.get("orderId") or ""),
    )
    for order in ordered:
        order_id = str(order.get("docId") or order.get("orderId") or "")
        if _first_text(order, ("salesmanUid",)):
            decisions.append(Decision(order_id, "skip", "already_has_owner"))
            continue
        if order.get("isDemo") is True:
            decisions.append(Decision(order_id, "skip", "demo_record"))
            continue
        code = _first_text(order, CODE_FIELDS)
        if not code:
            decisions.append(Decision(order_id, "skip", "no_employee_code"))
            continue
        candidates = sorted(uid_by_code.get(code, set()))
        if not candidates:
            decisions.append(Decision(order_id, "skip", "unresolved_code", code=code))
            continue
        if len(candidates) > 1:
            decisions.append(Decision(order_id, "skip", "ambiguous_code", code=code))
            continue
        uid = candidates[0]
        order_branch = _first_text(order, BRANCH_FIELDS)
        profile_branch = branch_by_uid.get(uid, "")
        if order_branch and profile_branch and order_branch != profile_branch:
            decisions.append(
                Decision(order_id, "skip", "branch_mismatch", uid=uid, code=code)
            )
            continue
        decisions.append(Decision(order_id, "stamp", "stamped", uid=uid, code=code))
    return tuple(decisions)


def plan_code_backfill(orders: Iterable[Mapping[str, Any]]) -> dict[str, str]:
    stamps: dict[str, str] = {}
    for order in orders:
        if order.get("isDemo") is True:
            continue
        if _first_text(order, ("salesmanCode", "salesman_code")):
            continue
        code = _first_text(order, ("salesmanId", "salesman_id", "staffId", "employeeCode"))
        order_id = str(order.get("docId") or order.get("orderId") or "")
        if code and order_id:
            stamps[order_id] = code
    return stamps


def _profile_rows(db: Any) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for collection in PROFILE_COLLECTIONS:
        for snapshot in db.collection(collection).stream():
            data = dict(snapshot.to_dict() or {})
            data["docId"] = snapshot.id
            data["collection"] = collection
            rows.append(data)
    return rows


def _order_rows(db: Any, cap: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for snapshot in db.collection(TARGET_COLLECTION).limit(cap).stream():
        data = dict(snapshot.to_dict() or {})
        data["docId"] = snapshot.id
        rows.append(data)
    return rows


def _summarise(decisions: Sequence[Decision], show: int) -> str:
    counts: dict[str, int] = {}
    for decision in decisions:
        counts[decision.reason] = counts.get(decision.reason, 0) + 1
    lines = [f"{TARGET_COLLECTION} documents inspected: {len(decisions)}"]
    for reason in sorted(counts):
        lines.append(f"  {reason}: {counts[reason]}")
    stamps = [row for row in decisions if row.action == "stamp"]
    if stamps and show:
        lines.append(f"first {min(show, len(stamps))} of {len(stamps)} to stamp:")
        for row in stamps[:show]:
            lines.append(f"  {row.order_id} -> salesmanUid {row.uid} (code {row.code})")
    return "\n".join(lines)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=BACKFILL_HELP.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", dest="dry_run", action="store_true", default=True)
    mode.add_argument("--apply", dest="dry_run", action="store_false")
    parser.add_argument("--project", choices=tuple(RUNNER_PROJECT_IDS))
    parser.add_argument("--confirm")
    parser.add_argument("--service-account")
    parser.add_argument("--max-orders", type=int, default=DEFAULT_ORDER_CAP)
    parser.add_argument("--show", type=int, default=20)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.dry_run:
        if args.confirm:
            raise SystemExit("--confirm is accepted only with --apply")
    else:
        if not args.project:
            raise SystemExit("--apply requires --project dev or --project demo")
        expected = f"APPLY-{RUNNER_PROJECT_IDS[args.project]}"
        if args.confirm != expected:
            raise SystemExit(f"--apply for {args.project} requires --confirm {expected}")

    target = RUNNER_PROJECT_IDS[args.project] if args.project else None
    db = create_firestore_client(args.service_account, target)

    orders = _order_rows(db, args.max_orders)
    decisions = plan_identity_backfill(orders, _profile_rows(db))
    print(_summarise(decisions, args.show))

    stamps = [row for row in decisions if row.action == "stamp"]
    code_stamps = plan_code_backfill(orders)
    print(f"{TARGET_COLLECTION} documents to stamp with salesmanCode: {len(code_stamps)}")
    if args.dry_run:
        print("\nDRY RUN - nothing was written. Re-run with --apply to stamp.")
        return 0
    if not stamps and not code_stamps:
        print("\nNothing to stamp.")
        return 0

    stamped_at = datetime.now(timezone.utc).isoformat()
    writes: dict[str, dict[str, str]] = {}
    for decision in stamps:
        writes[decision.order_id] = {"salesmanUid": decision.uid}
    for order_id, code in code_stamps.items():
        writes.setdefault(order_id, {})["salesmanCode"] = code
    batch = db.batch()
    pending = 0
    for order_id, fields in writes.items():
        batch.set(
            db.collection(TARGET_COLLECTION).document(order_id),
            {
                **fields,
                "identityBackfill": BACKFILL_VERSION,
                "identityBackfilledAt": stamped_at,
            },
            merge=True,
        )
        pending += 1
        if pending == 400:
            batch.commit()
            batch = db.batch()
            pending = 0
    if pending:
        batch.commit()
    print(f"\nStamped {len(writes)} document(s) with {BACKFILL_VERSION}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

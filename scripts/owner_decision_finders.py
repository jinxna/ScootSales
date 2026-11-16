from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from google.cloud import firestore

from platform_service import config
from platform_service.payments import CHECKS, ENTRIES, _voided_ids, is_waiting_for_check
from platform_service.plans import PLAN_REQUESTS, PLANS, SUBSCRIPTIONS, PlanStore
from platform_service.records import workspace_skeleton

DEFAULT_READ_CAP = 5000
MAX_READ_CAP = 20000
CENTRAL = frozenset({"unchecked-payments", "quotes-without-package", "shared-projects", "orphan-claims"})
DEFAULT_DATABASE = "(default)"
EMULATOR_VOLATILE = ROOT / "e2e" / "output"
GENERATED_DOMAINS = ("example.test", "example.com")
GENERATED_PREFIX = "e2e."
GENERATED_CODE = re.compile(r"-e2e$", re.IGNORECASE)
RELEASED_ON_DELETE = ("location:", "auth:", "project:")


class ReadCapReached(Exception):
    pass


class Reader:
    def __init__(self, db: firestore.Client, cap: int) -> None:
        self.db = db
        self.cap = cap
        self.reads = 0
        self.sizes: dict[str, int] = {}

    def stream(self, collection: str) -> list[Any]:
        remaining = self.cap - self.reads
        if remaining <= 0:
            raise ReadCapReached(collection)
        rows = list(self.db.collection(collection).limit(remaining + 1).stream())
        if len(rows) > remaining:
            self.reads = self.cap
            raise ReadCapReached(collection)
        self.reads += max(len(rows), 1)
        self.sizes[collection] = len(rows)
        return rows


def current_list_price(reader: Reader, plan_id: str, plan_rows: dict[str, dict[str, Any]], interval: Any) -> Any:
    version = plan_rows.get(plan_id, {}).get("currentVersion")
    if version is None:
        return None
    if reader.reads >= reader.cap:
        raise ReadCapReached("plans versions")
    reader.reads += 1
    row = reader.db.collection(PLANS).document(plan_id).collection("versions").document(str(version)).get().to_dict() or {}
    return (row.get("prices") or {}).get(interval)


def company_index(reader: Reader) -> list[dict[str, Any]]:
    rows = []
    for snapshot in reader.stream("companies"):
        data = snapshot.to_dict() or {}
        key = str(data.get("locationKey") or "")
        parts = key.split("|")
        rows.append({"tenantId": snapshot.id, "workspace": data.get("workspace"), "companyCode": data.get("companyCode"),
                     "status": data.get("status"), "locationKey": key, "projectId": parts[0] or None,
                     "authTenantId": parts[2] if len(parts) > 2 and parts[2] != "-" else None})
    return rows


def find_generated_accounts(reader: Reader) -> list[dict[str, Any]]:
    found = []
    for snapshot in reader.stream("users"):
        data = snapshot.to_dict() or {}
        email = str(data.get("email") or "").strip().lower()
        signals = []
        if email.endswith(tuple("@" + domain for domain in GENERATED_DOMAINS)):
            signals.append("generated_email_domain")
        if email.startswith(GENERATED_PREFIX):
            signals.append("e2e_email_prefix")
        for field in ("code", "userCode", "employeeCode", "employee_code", "salesmanCode", "salesman_code",
                      "staffId", "staff_id", "companyCode"):
            if GENERATED_CODE.search(str(data.get(field) or "")):
                signals.append(f"e2e_code:{field}")
        if GENERATED_CODE.search(snapshot.id):
            signals.append("e2e_code:docId")
        if signals:
            found.append({"userId": snapshot.id, "companyId": data.get("companyId") or data.get("tenantId"), "email": email or None, "role": data.get("role") or data.get("user_group"),
                          "signals": signals})
    return sorted(found, key=lambda row: row["userId"])


def find_unchecked_payments(reader: Reader, now: datetime) -> list[dict[str, Any]]:
    rows = [{**(snapshot.to_dict() or {}), "_id": snapshot.id} for snapshot in reader.stream(ENTRIES)]
    checks = {snapshot.id for snapshot in reader.stream(CHECKS)}
    voided_by_tenant: dict[Any, set[Any]] = {}
    found = []
    for row in rows:
        tenant = row.get("tenantId")
        if tenant not in voided_by_tenant:
            voided_by_tenant[tenant] = _voided_ids(rows, tenant)
        if not is_waiting_for_check(row, checks, voided_by_tenant[tenant]):
            continue
        created = row.get("createdAt")
        age = (now - created).days if isinstance(created, datetime) else None
        found.append({"entryId": row.get("entryId") or row["_id"], "tenantId": tenant, "invoiceId": row.get("invoiceId"),
                      "amountMinor": row.get("amountMinor"), "createdBy": row.get("createdBy"),
                      "createdAt": created.isoformat() if isinstance(created, datetime) else None, "ageDays": age})
    return sorted(found, key=lambda row: (str(row["tenantId"]), str(row["entryId"])))


def find_quotes_without_package(reader: Reader) -> dict[str, Any]:
    plan_rows = {snapshot.id: snapshot.to_dict() or {} for snapshot in reader.stream(PLANS)}
    plan_ids = set(plan_rows)
    subscriptions = {snapshot.id: snapshot.to_dict() or {} for snapshot in reader.stream(SUBSCRIPTIONS)}
    quotes = []
    stored = [(snapshot.id, snapshot.to_dict() or {}) for snapshot in reader.stream("quotes")]
    approved = [row for _, row in stored if row.get("status") == "approved"]
    for quote_id, row in stored:
        if row.get("status") != "approved":
            continue
        reasons = []
        plan_id = row.get("planId")
        if not plan_id:
            reasons.append("quote_has_no_package")
        elif plan_id not in plan_ids:
            reasons.append("package_does_not_exist")
        subscription = subscriptions.get(row.get("tenantId")) or {}
        current = subscription.get("planId")
        if plan_id and plan_id in plan_ids and current and current in plan_ids and not any(
                other.get("tenantId") == row.get("tenantId") and other.get("status") == "approved"
                and other.get("planId") == current and other.get("billingInterval") == subscription.get("billingInterval")
                for other in approved) and current_list_price(
                    reader, current, plan_rows, subscription.get("billingInterval")) is None:
            reasons.append("no_approved_quote_for_current_package")
        if reasons:
            created = row.get("createdAt")
            quotes.append({"quoteId": quote_id, "tenantId": row.get("tenantId"), "planId": plan_id,
                           "currentPlanId": current, "billingInterval": row.get("billingInterval"),
                           "amountMinor": row.get("amountMinor"), "reasons": reasons,
                           "createdAt": created.isoformat() if isinstance(created, datetime) else None})
    requests = []
    for snapshot in reader.stream(PLAN_REQUESTS):
        row = snapshot.to_dict() or {}
        if row.get("status") == "requested" and not PlanStore.request_is_met(row, subscriptions.get(snapshot.id) or {}):
            created = row.get("createdAt")
            requests.append({"requestId": snapshot.id, "tenantId": row.get("tenantId"), "planId": row.get("planId"),
                             "interval": row.get("interval"),
                             "createdAt": created.isoformat() if isinstance(created, datetime) else None})
    return {"quotes": sorted(quotes, key=lambda row: row["quoteId"]),
            "openPackageRequests": sorted(requests, key=lambda row: row["requestId"])}


def find_shared_projects(reader: Reader) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = {}
    for company in company_index(reader):
        if company["status"] == "deleted" or not company["projectId"]:
            continue
        groups.setdefault(company["projectId"], []).append(
            {key: company[key] for key in ("tenantId", "workspace", "companyCode", "status", "authTenantId")})
    return [{"projectId": project, "companies": sorted(rows, key=lambda row: row["tenantId"])}
            for project, rows in sorted(groups.items()) if len(rows) > 1]


def expected_claims(company: dict[str, Any]) -> set[str]:
    claims = set()
    if company["workspace"]:
        claims |= {f"workspace:{company['workspace']}", f"skeleton:{workspace_skeleton(company['workspace'])}"}
    if company["companyCode"]:
        claims.add(f"code:{company['companyCode']}")
    if company["status"] != "deleted" and company["projectId"]:
        auth = f"{company['projectId']}|{company['authTenantId'] or '-'}"
        claims |= {f"location:{company['locationKey']}", f"auth:{auth}", f"project:{company['projectId']}"}
    return claims


def find_orphan_claims(reader: Reader) -> list[dict[str, Any]]:
    companies = {company["tenantId"]: company for company in company_index(reader)}
    found = []
    for snapshot in reader.stream("company_claims"):
        tenant = (snapshot.to_dict() or {}).get("tenantId")
        company = companies.get(tenant)
        if company is None:
            reason = "company_record_missing"
        elif snapshot.id not in expected_claims(company):
            reason = ("released_claim_kept_after_delete" if company["status"] == "deleted"
                      and snapshot.id.startswith(RELEASED_ON_DELETE) else "claim_does_not_match_company")
        else:
            continue
        found.append({"claimId": snapshot.id, "tenantId": tenant, "reason": reason,
                      "companyStatus": company["status"] if company else None})
    return sorted(found, key=lambda row: row["claimId"])


FINDERS: dict[str, Callable[[Reader, datetime], Any]] = {
    "generated-accounts": lambda reader, now: find_generated_accounts(reader),
    "unchecked-payments": find_unchecked_payments,
    "quotes-without-package": lambda reader, now: find_quotes_without_package(reader),
    "shared-projects": lambda reader, now: find_shared_projects(reader),
    "orphan-claims": lambda reader, now: find_orphan_claims(reader),
}


def is_git_ignored(path: Path) -> bool:
    result = subprocess.run(["git", "check-ignore", "-q", str(path)], cwd=ROOT, capture_output=True)
    return result.returncode == 0


def count_of(result: Any) -> int:
    return sum(len(value) for value in result.values()) if isinstance(result, dict) else len(result)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read-only finders that list records needing an owner decision and write a manifest. "
                    "The four central finders need PLATFORM_PROJECT_ID set to the central project id for a live run. "
                    "Nothing in the database is changed.")
    parser.add_argument("finder", choices=sorted(FINDERS))
    parser.add_argument("--project", required=True)
    parser.add_argument("--confirm-project", required=True)
    parser.add_argument("--out", required=True, help="manifest path inside a git-ignored folder")
    parser.add_argument("--read-cap", type=int, default=DEFAULT_READ_CAP)
    parser.add_argument("--database", default=DEFAULT_DATABASE,
                        help="database to read; for generated-accounts use the database in the company's locationKey")
    args = parser.parse_args(argv)
    if args.confirm_project != args.project:
        print("--confirm-project must equal --project.", file=sys.stderr)
        return 2
    if not 1 <= args.read_cap <= MAX_READ_CAP:
        print(f"--read-cap must be from 1 to {MAX_READ_CAP}.", file=sys.stderr)
        return 2
    emulator = bool(os.environ.get("FIRESTORE_EMULATOR_HOST"))
    if args.finder in CENTRAL and args.project != config.PLATFORM_PROJECT_ID:
        print(f"{args.finder} reads the central project {config.PLATFORM_PROJECT_ID}, not {args.project}. "
              "A live run must set PLATFORM_PROJECT_ID to the central project id.", file=sys.stderr)
        return 2
    out = Path(args.out).resolve()
    if not emulator and EMULATOR_VOLATILE in (out, *out.parents):
        print("e2e/output/ is wiped at every E2E start; use qa_artifacts/owner_decisions/ for a live run.", file=sys.stderr)
        return 2
    if not is_git_ignored(out):
        print("--out must be inside a git-ignored folder, for example qa_artifacts/owner_decisions/.", file=sys.stderr)
        return 2
    db = firestore.Client(project=args.project, database=args.database)
    reader = Reader(db, args.read_cap)
    now = datetime.now(timezone.utc)
    try:
        result = FINDERS[args.finder](reader, now)
    except ReadCapReached as stopped:
        print(f"Stopped at the read cap of {args.read_cap} while reading {stopped}. No manifest written.", file=sys.stderr)
        return 3
    if args.finder == "generated-accounts" and not reader.sizes.get("users"):
        print("The users collection is empty here. This is probably not a company project; no manifest written.",
              file=sys.stderr)
        return 2
    manifest = {"finder": args.finder, "project": db.project, "generatedAt": now.isoformat(), "readOnly": True,
                "target": {"project": db.project, "database": args.database, "kind": "emulator" if emulator else "live"},
                "collectionSizes": reader.sizes,
                "notCovered": ["Auth users that have no users document"] if args.finder == "generated-accounts" else [],
                "readsUsed": reader.reads, "count": count_of(result), "result": result}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True, default=str), encoding="utf-8")
    print(f"{args.finder}: {manifest['count']} record(s) need a decision; {reader.reads} read(s) used; manifest {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

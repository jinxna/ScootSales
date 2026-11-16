from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from math import ceil
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

from firebase_admin import auth as admin_auth
from firebase_admin.exceptions import FirebaseError
from google.auth.exceptions import GoogleAuthError
from google.oauth2 import service_account

from . import config
from .access_migration import UID_KEYS, _text, rules_active
from .company_access import UNREACHABLE, project_auth
from .live_tracking_migration import plan_uid_backfill
from .migrate_seats import _canonical_role, _client
from .order_code_backfill import plan_code_backfill
from .orderable import _text as _plain_text
from .orderable import is_orderable
from .plans import load_catalogue
from .prepare_data import report as prepare_report
from .tenant_inventory import inventory

COUNTED = ("user_access", "users", "products", "orders", "live_tracking")
DEFAULT_MAX_READS = 20000
CONFIG_DOCUMENTS = ("usage", "plan", "lifecycle")
PRICE_FIELDS = ("unitPrice", "price", "priceGuide")
OLD_PRICE_FIELDS = ("sellingPrice", "selling_price", "unit_price")
BARCODE_FIELDS = ("barcode", "itemBarcode")
AUTH_BATCH = 100
RULES_API = "https://firebaserules.googleapis.com/v1"
RULES_SCOPE = "https://www.googleapis.com/auth/cloud-platform"


class ReadBudgetExceeded(Exception):
    def __init__(self, estimated: int, allowed: int) -> None:
        super().__init__(f"A full scan needs about {estimated} reads. The limit is {allowed}. Nothing was read.")
        self.estimated = estimated
        self.allowed = allowed


class RulesReadFailed(Exception):
    pass


@dataclass(frozen=True)
class DeployedRules:
    release: str
    updated_at: str
    sha256: str
    source: str


@dataclass(frozen=True)
class Readiness:
    report: dict[str, Any]
    deployed: DeployedRules | None

    @property
    def verdict(self) -> str:
        return self.report["verdict"]

    @property
    def blockers(self) -> list[str]:
        return self.report["blockers"]


def normalized(source: str) -> str:
    return source.replace("\r\n", "\n")


def rules_sha256(source: str) -> str:
    return hashlib.sha256(normalized(source).encode("utf-8")).hexdigest()


def count_documents(db: Any) -> dict[str, int]:
    return {name: int(db.collection(name).count().get()[0][0].value) for name in COUNTED}


def estimate_reads(counts: Mapping[str, int]) -> int:
    access, users, products = counts["user_access"], counts["users"], counts["products"]
    counting = sum(max(1, ceil(counts[name] / 1000)) for name in COUNTED)
    fixed = 1 + 1 + len(CONFIG_DOCUMENTS)
    return 5 * access + 4 * users + 2 * products + 2 * counts["orders"] + counts["live_tracking"] + counting + fixed


def _number_or_text(value: Any) -> Any:
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, (int, float)):
        return float(value)
    text = _plain_text(value)
    try:
        return float(text)
    except ValueError:
        return text


def _is_price(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, (int, float)):
        return True
    if not isinstance(value, str):
        return False
    try:
        float(value.strip())
    except ValueError:
        return False
    return True


def product_facts(products: Iterable[tuple[str, Mapping[str, Any]]]) -> dict[str, int]:
    facts = {"total": 0, "orderable": 0, "hidden": 0, "withBarcode": 0, "withoutBarcode": 0,
             "withPriceMismatch": 0, "missingProductId": 0, "priceOnlyInOldField": 0}
    for doc_id, data in products:
        facts["total"] += 1
        facts["orderable" if is_orderable(data, doc_id) else "hidden"] += 1
        has_barcode = any(_plain_text(data.get(key)) for key in BARCODE_FIELDS)
        facts["withBarcode" if has_barcode else "withoutBarcode"] += 1
        prices = {_number_or_text(data[key]) for key in PRICE_FIELDS if data.get(key) is not None}
        if len(prices) > 1:
            facts["withPriceMismatch"] += 1
        has_catalogue_price = any(_is_price(data.get(key)) for key in PRICE_FIELDS)
        if not has_catalogue_price and any(data.get(key) is not None for key in OLD_PRICE_FIELDS):
            facts["priceOnlyInOldField"] += 1
        if not _plain_text(data.get("productId")):
            facts["missingProductId"] += 1
    return facts


def _person_code(data: Mapping[str, Any], fallback: str) -> str:
    return _text(data, "employeeCode", "staffId") or _text(data, "salesmanCode", "salesman_code") or fallback


def _emails(data: Mapping[str, Any]) -> set[str]:
    email = _text(data, "email", "email").strip().lower()
    return {email} if email else set()


def sign_in_targets(access_rows: Mapping[str, Mapping[str, Any]], profiles: Mapping[str, Mapping[str, Any]],
                    moved_rows: Mapping[str, str] | None = None) -> dict[str, dict[str, Any]]:
    targets: dict[str, dict[str, Any]] = {}
    moved_rows = moved_rows or {}

    def target(uid: str) -> dict[str, Any]:
        return targets.setdefault(uid, {"code": "", "documents": [], "emails": set(), "active": False})

    for row_id, row in access_rows.items():
        uid = moved_rows.get(row_id, row_id)
        entry = target(uid)
        link_id = _text(row, "userDocId", "user_doc_id")
        entry["documents"].append(f"user_access/{row_id}")
        entry["code"] = entry["code"] or _person_code(row, link_id)
        entry["active"] = entry["active"] or rules_active(row)
        entry["emails"] |= _emails(row)
    for profile_id, profile in profiles.items():
        uid = _text(profile, *UID_KEYS)
        if not uid:
            continue
        entry = target(uid)
        entry["documents"].append(f"users/{profile_id}")
        entry["code"] = entry["code"] or _person_code(profile, profile_id)
        entry["active"] = entry["active"] or rules_active(profile)
        entry["emails"] |= _emails(profile)
    return targets


def auth_facts(access_rows: Mapping[str, Mapping[str, Any]], profiles: Mapping[str, Mapping[str, Any]],
               client: admin_auth.Client, moved_rows: Mapping[str, str] | None = None) -> dict[str, Any]:
    targets = sign_in_targets(access_rows, profiles, moved_rows)
    uids = sorted(targets)
    found: dict[str, Any] = {}
    for start in range(0, len(uids), AUTH_BATCH):
        result = client.get_users([admin_auth.UidIdentifier(uid) for uid in uids[start:start + AUTH_BATCH]])
        found = {**found, **{user.uid: user for user in result.users}}
    blockers: list[str] = []
    notes: list[str] = []
    for uid in uids:
        entry = targets[uid]
        where = ", ".join(entry["documents"])
        who = entry["code"] or "A person without an employee code"
        user = found.get(uid)
        if user is None:
            blockers.append(f"{who} ({where}) has no sign-in account in Firebase Auth. "
                            "Create the account again or remove this person, then check again.")
            continue
        auth_email = (user.email or "").strip().lower()
        if entry["emails"] and auth_email not in entry["emails"]:
            notes.append(f"{who} ({where}): the sign-in email is not the email saved on the person.")
        if user.disabled and entry["active"]:
            notes.append(f"{who} ({where}) is active but the sign-in account is disabled.")
    extra = sum(1 for user in client.list_users().iterate_all() if user.uid not in targets)
    if extra:
        notes.append(f"{extra} sign-in accounts have no access record and no profile. Nobody can use them in this company.")
    return {"checked": len(uids), "missing": len(blockers), "withoutRecord": extra,
            "blockers": blockers, "notes": notes}


def rules_check(reader: Callable[[], DeployedRules | None], expected: str | None) -> tuple[dict[str, Any], DeployedRules | None]:
    deployed = reader()
    if deployed is None:
        return {"checked": False, "matchesExpected": None,
                "note": "The deployed rules could not be read. The key needs the Firebase Rules Viewer role."}, None
    section: dict[str, Any] = {"checked": True, "release": deployed.release, "updatedAt": deployed.updated_at,
                               "sha256": deployed.sha256, "matchesExpected": None}
    if expected is not None:
        section["expectedSha256"] = rules_sha256(expected)
        section["matchesExpected"] = normalized(deployed.source) == normalized(expected)
    return section, deployed


def readiness(db: Any, *, auth_client: admin_auth.Client, packages: Sequence[Mapping[str, Any]], budget: int,
              project: str = "", rules_reader: Callable[[], DeployedRules | None] | None = None,
              expected_rules: str | None = None) -> Readiness:
    counts = count_documents(db)
    estimated = estimate_reads(counts)
    if estimated > budget:
        raise ReadBudgetExceeded(estimated, budget)
    rules_section: dict[str, Any] = {"checked": False}
    deployed: DeployedRules | None = None
    if rules_reader is not None:
        rules_section, deployed = rules_check(rules_reader, expected_rules)

    prepared = prepare_report(db, packages, None, auth_client)
    inventory_facts = inventory(db, auth_client)
    access_rows = {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection("user_access").stream()}
    profiles = {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection("users").stream()}
    products = [(snapshot.id, snapshot.to_dict() or {}) for snapshot in db.collection("products").stream()]
    tracking = plan_uid_backfill(db)
    order_codes = plan_code_backfill(db, access_rows, profiles)
    without_code = len(order_codes["convertible"]) + len(order_codes["skipped"])
    present = {name: bool(db.collection("config").document(name).get().exists) for name in CONFIG_DOCUMENTS}

    roles: dict[str, int] = {}
    for row in access_rows.values():
        role = _canonical_role(row) or "unknown"
        roles[role] = roles.get(role, 0) + 1
    report_products = product_facts(products)
    auth_section = auth_facts(access_rows, profiles, auth_client, {move["rowId"]: move["uid"] for move in prepared["moves"]})
    blockers = [*prepared["blockers"], *auth_section["blockers"]]
    notes = [*prepared["notes"], *auth_section["notes"]]
    old_price = report_products["priceOnlyInOldField"]
    if old_price:
        notes.append(f"{old_price} products have a price only in sellingPrice, selling_price or unit_price. "
                     "The dashboard shows them without a price until the price is saved again.")
    if without_code:
        target = project or "PROJECT"
        notes.append(f"{without_code} orders have no salesmanCode, so supervisor team lists miss them. "
                     f"Fix: python -m platform_service.order_code_backfill --project {target} "
                     f"--apply --confirm-project {target}")
    if rules_section.get("matchesExpected") is False:
        notes.append("The deployed rules are not the expected rules.")
    if rules_section.get("note"):
        notes.append(rules_section["note"])

    report = {
        "project": project,
        "budget": {"counts": counts, "estimatedReads": estimated, "maxReads": budget},
        "people": {"counts": prepared["counts"], "roles": dict(sorted(roles.items())), "blockers": prepared["blockers"],
                   "notes": prepared["notes"], "fit": prepared["fit"], "moves": prepared["moves"],
                   "inventory": {key: inventory_facts[key] for key in
                                 ("legacyAccessRows", "uidOnlyProfiles", "v2Rows", "unlinkedProfiles")}},
        "auth": auth_section,
        "products": report_products,
        "orders": {**inventory_facts["orders"], "withoutSalesmanCode": without_code},
        "liveTracking": {"withoutUid": len(tracking["convertible"]) + len(tracking["skipped"]),
                         "convertible": len(tracking["convertible"]), "skipped": tracking["skipped"]},
        "config": present,
        "rules": rules_section,
        "notes": notes,
        "blockers": blockers,
        "verdict": "blocked" if blockers else "ready",
    }
    return Readiness(report, deployed)


def _rules_credentials(project: str) -> Any:
    key_file = Path(config.COMPANY_CREDENTIALS_DIR) / f"{project}.json" if config.COMPANY_CREDENTIALS_DIR else None
    if key_file is not None and key_file.is_file():
        return service_account.Credentials.from_service_account_file(str(key_file), scopes=[RULES_SCOPE])
    import google.auth

    return google.auth.default(scopes=[RULES_SCOPE])[0]


def deployed_rules_reader(project: str, database: str, session: Any = None) -> Callable[[], DeployedRules | None]:
    def read() -> DeployedRules | None:
        http = session
        if http is None:
            from google.auth.transport.requests import AuthorizedSession

            http = AuthorizedSession(_rules_credentials(project))
        release_name = "cloud.firestore" if database == "(default)" else f"cloud.firestore/{database}"
        release = http.get(f"{RULES_API}/projects/{project}/releases/{release_name}")
        if release.status_code in (403, 404):
            return None
        if release.status_code != 200:
            raise RulesReadFailed(f"The rules release could not be read (status {release.status_code}).")
        release_body = release.json()
        ruleset = http.get(f"{RULES_API}/{release_body['rulesetName']}")
        if ruleset.status_code != 200:
            raise RulesReadFailed(f"The rules source could not be read (status {ruleset.status_code}).")
        files = ruleset.json().get("source", {}).get("files", [])
        source = "\n".join(item.get("content", "") for item in files)
        return DeployedRules(release_body["name"], release_body.get("updateTime", ""), rules_sha256(source), source)

    return read


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only readiness report of a company project.")
    parser.add_argument("--project", required=True, help="company Firebase project ID")
    parser.add_argument("--database", default="(default)", help="Firestore database ID")
    parser.add_argument("--expect-rules", help="file with the rules the project should run")
    parser.add_argument("--save-rules", help="write the deployed rules source to this file")
    parser.add_argument("--max-reads", type=int, default=DEFAULT_MAX_READS, help="most Firestore reads allowed")
    parser.add_argument("--out", help="also write the report to this JSON file")
    args = parser.parse_args(argv)
    expected = None
    if args.expect_rules:
        try:
            expected = Path(args.expect_rules).read_text(encoding="utf-8")
        except OSError as error:
            print(f"The rules file cannot be read: {error}", file=sys.stderr)
            return 3
    reader = deployed_rules_reader(args.project, args.database) if (args.expect_rules or args.save_rules) else None
    try:
        db = _client(args.project, args.database)
        result = readiness(db, auth_client=project_auth(args.project), packages=load_catalogue(),
                           budget=args.max_reads, project=args.project, rules_reader=reader,
                           expected_rules=expected)
    except ReadBudgetExceeded as error:
        print(json.dumps({"project": args.project, "verdict": "not-run", "error": str(error),
                          "budget": {"estimatedReads": error.estimated, "maxReads": error.allowed}},
                         indent=2, sort_keys=True))
        return 2
    except (*UNREACHABLE, FirebaseError, GoogleAuthError, RulesReadFailed, RuntimeError, OSError) as error:
        print(f"The project could not be read: {error}", file=sys.stderr)
        return 3
    if args.save_rules:
        if result.deployed is None:
            print("The deployed rules could not be read, so nothing was saved.", file=sys.stderr)
            return 3
        Path(args.save_rules).write_text(result.deployed.source, encoding="utf-8", newline="\n")
    text = json.dumps(result.report, indent=2, sort_keys=True)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    print(text)
    return 0 if result.verdict == "ready" else 1


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Sequence

from firebase_admin import auth as admin_auth
from firebase_admin.exceptions import FirebaseError
from google.auth.exceptions import GoogleAuthError
from google.cloud import firestore

from . import prepare_data
from .access_migration import ARCHIVE, BEFORE_FIX, LINK_KEYS, UID_KEYS, _account_exists, _text, rules_active
from .commands import CommandProblem
from .company_access import UNREACHABLE, project_auth
from .migrate_seats import SWITCH_OFF_REASON, _canonical_role, _client, plan_migration
from .seats import MAINTENANCE, seat_class_for_role, usage_ref
from .tenant_snapshot import encode

CODE_FIELDS = (("employeeCode", "staffId"), ("salesmanCode", "salesman_code"), ("userId", "user_id"))


class RepairRefused(Exception):
    pass


@dataclass(frozen=True)
class Grant:
    email: str
    code: str
    name: str | None = None
    branch: str | None = None


@dataclass(frozen=True)
class PlannedPerson:
    kind: str
    uid: str
    label: str
    email: str
    documents: Mapping[str, Mapping[str, Any]]
    expected: Mapping[str, Mapping[str, Any] | None]
    code: str | None
    needs_enabled_account: bool


@dataclass(frozen=True)
class RepairPlan:
    writes: list[PlannedPerson]
    skipped: list[dict[str, str]]


def mask_email(email: str) -> str:
    local, _, domain = email.partition("@")
    return f"{local[:2]}***@{domain}"


def _account(auth_client: admin_auth.Client, uid: str) -> Any:
    try:
        return auth_client.get_user(uid)
    except admin_auth.UserNotFoundError:
        return None


def _uses_code(doc_id: str, data: Mapping[str, Any], code: str) -> bool:
    wanted = code.strip().casefold()
    if doc_id.casefold() == wanted:
        return True
    return any(_text(data, *pair).strip().casefold() == wanted for pair in CODE_FIELDS)


def _code_in_use(db: Any, code: str, transaction: Any = None) -> bool:
    for name in ("user_access", "users"):
        for snapshot in db.collection(name).stream(transaction=transaction):
            if _uses_code(snapshot.id, snapshot.to_dict() or {}, code):
                return True
    return False


def _swapped(db: Any, auth_client: admin_auth.Client) -> tuple[list[PlannedPerson], list[dict[str, str]]]:
    rows = {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection("user_access").stream()}
    profiles = {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection("users").stream()}
    writes: list[PlannedPerson] = []
    skipped: list[dict[str, str]] = []
    claimed: set[str] = set()

    def skip(row_id: str, reason: str) -> None:
        skipped.append({"row": row_id, "reason": reason})

    for row_id, data in sorted(rows.items()):
        uid = _text(data, *UID_KEYS).strip()
        if uid == row_id:
            continue
        if not uid:
            skip(row_id, "The row has no uid.")
        elif data.get("accessVersion") is not None:
            skip(row_id, "The row is not a legacy row.")
        elif uid in claimed:
            skip(row_id, "Another row names the same uid.")
        elif (account := _account(auth_client, uid)) is None:
            skip(row_id, "The uid has no sign-in account in Firebase Auth.")
        elif uid in rows:
            skip(row_id, f"user_access/{uid} exists already.")
        elif row_id not in profiles or _text(profiles[row_id], *UID_KEYS).strip() != uid:
            skip(row_id, f"The profile users/{row_id} does not exist or has another uid, so the row is not a swapped row.")
        else:
            claimed.add(uid)
            writes.append(PlannedPerson(
                kind="swapped", uid=uid, label=row_id, email=_text(data, "email", "email") or account.email or "",
                documents={f"user_access/{uid}": {**data, "userDocId": row_id}},
                expected={f"user_access/{row_id}": data, f"users/{row_id}": profiles[row_id],
                          f"user_access/{uid}": None},
                code=None, needs_enabled_account=False))
    return writes, skipped


def _existing_branch(db: Any) -> str:
    branches = set()
    for snapshot in db.collection("user_access").stream():
        data = snapshot.to_dict() or {}
        branch = _text(data, "branchId", "branch_id").strip()
        if branch and _canonical_role(data) == "admin":
            branches.add(branch)
    if len(branches) != 1:
        raise RepairRefused("The branch of the administrators is not one single branch. Pass --branch.")
    return next(iter(branches))


def _grant(db: Any, auth_client: admin_auth.Client, grant: Grant) -> tuple[PlannedPerson | None, dict[str, str] | None]:
    email = grant.email.strip().lower()
    code = grant.code.strip()
    if not code:
        raise RepairRefused("The employee code is empty.")
    try:
        account = auth_client.get_user_by_email(email)
    except admin_auth.UserNotFoundError:
        raise RepairRefused("No sign-in account has this email.") from None
    if account.disabled:
        raise RepairRefused("The sign-in account is disabled.")
    uid = account.uid
    access = db.collection("user_access").document(uid).get()
    profile = db.collection("users").document(uid).get()
    if access.exists and profile.exists:
        stored = access.to_dict() or {}
        if _text(stored, "userDocId", "user_doc_id") == uid and _text(stored, "employeeCode", "staffId") == code:
            return None, {"row": uid, "reason": "The administrator exists already."}
    if access.exists or profile.exists:
        raise RepairRefused(f"user_access/{uid} or users/{uid} exists already.")
    if _code_in_use(db, code):
        raise RepairRefused("The employee code is used by a row or a profile.")
    branch = (grant.branch or "").strip() or _existing_branch(db)
    local = email.partition("@")[0]
    identity = {
        "userId": code, "employeeCode": code, "email": account.email or email, "role": "admin", "user_group": "admin",
        "status": "active", "isActive": True, "branchId": branch, "branch_id": branch,
        "supervisorId": "", "supervisor_id": "",
    }
    name = (grant.name or "").strip() or account.display_name or local
    return PlannedPerson(
        kind="grant-admin", uid=uid, label=code, email=account.email or email,
        documents={f"users/{uid}": {"uid": uid, "name": name, "username": local, **identity},
                   f"user_access/{uid}": {"uid": uid, "userDocId": uid, **identity}},
        expected={f"users/{uid}": None, f"user_access/{uid}": None},
        code=code, needs_enabled_account=True), None


def plan_repair(db: Any, auth_client: admin_auth.Client, grant: Grant | None = None) -> RepairPlan:
    granted, granted_skip = _grant(db, auth_client, grant) if grant is not None else (None, None)
    writes, skipped = _swapped(db, auth_client)
    if granted is not None:
        writes.append(granted)
    if granted_skip is not None:
        skipped.append(granted_skip)
    return RepairPlan(writes, skipped)


def _account_still_fits(auth_client: admin_auth.Client, person: PlannedPerson) -> bool:
    account = _account(auth_client, person.uid)
    return account is not None and not (person.needs_enabled_account and account.disabled)


def apply_repair(db: Any, auth_client: admin_auth.Client, plan: RepairPlan) -> dict[str, list[str]]:
    written: list[str] = []
    changed: list[str] = []

    @firestore.transactional
    def write(transaction: firestore.Transaction, person: PlannedPerson) -> bool:
        for path, expected in person.expected.items():
            snapshot = db.document(path).get(transaction=transaction)
            if (snapshot.to_dict() if snapshot.exists else None) != expected:
                return False
        if person.code is not None and _code_in_use(db, person.code, transaction):
            return False
        for path, data in person.documents.items():
            transaction.set(db.document(path), data)
        return True

    for person in plan.writes:
        if _account_still_fits(auth_client, person) and write(db.transaction(), person):
            written.extend(person.documents)
        else:
            changed.append(person.uid)
    return {"written": written, "changedDuringApply": changed}


def report(project: str, plan: RepairPlan, applied: Mapping[str, list[str]] | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "project": project,
        "mode": "apply" if applied is not None else "dry-run",
        "people": [{"kind": person.kind, "uid": person.uid, "label": person.label,
                    "email": mask_email(person.email), "documents": sorted(person.documents)}
                   for person in plan.writes],
        "skipped": plan.skipped,
    }
    if applied is not None:
        result["applied"] = dict(applied)
    return result


PEOPLE_ROLES = ("admin", "branch_manager", "supervisor", "salesman")
PROFILE_KEYS = ("userId", "employeeCode", "email", "role", "user_group", "status", "isActive", "branchId",
                "branch_id", "supervisorId", "supervisor_id", "assignedSalesmanCodes")
CHANGED_SINCE_OPEN = "This record changed since you opened it. Look again before you apply."
PREPARE_MOVES = "Prepare moves it to its sign-in id."
SWITCH_OFF_FIX = {"id": "switch_off", "label": "Switch this person off"}
ROLE_FIXES = [{"id": f"set_role:{role}", "label": f"Make this person a {role.replace('_', ' ')}"} for role in PEOPLE_ROLES]
FIXES_FOR = {
    "unknown_role": {"switch_off", *(f"set_role:{role}" for role in PEOPLE_ROLES)},
    "profile_missing": {"switch_off", "make_profile"},
    "no_account": {"switch_off"},
    "two_rows": {"switch_off"},
    "switched_off_swapped": {"switch_off"},
    "identity_mismatch": {"switch_off"},
    "swapped_row_refused": {"switch_off"},
}
ROW_ONLY_SWITCH_OFF = {"two_rows", "switched_off_swapped", "identity_mismatch", "swapped_row_refused"}
REREAD_DEFECTS = {"switched_off_swapped", "identity_mismatch", "swapped_row_refused"}
REFUSED_DEFECT = {
    "swapped_row_no_account": "no_account",
    "swapped_row_target_exists": "two_rows",
    "swapped_row_duplicate": "two_rows",
    "unknown_role": "unknown_role",
    "inactive": "switched_off_swapped",
}


class PeopleRefused(CommandProblem):
    pass


class PeopleInvalid(PeopleRefused):
    pass


class PeopleNotFound(PeopleRefused):
    pass


def _fixes(defect: str) -> list[dict[str, str]]:
    return {
        "unknown_role": [*ROLE_FIXES, SWITCH_OFF_FIX],
        "profile_missing": [{"id": "make_profile", "label": "Make the profile from the row"}, SWITCH_OFF_FIX],
        "no_account": [SWITCH_OFF_FIX],
        "two_rows": [SWITCH_OFF_FIX],
        "switched_off_swapped": [SWITCH_OFF_FIX],
        "identity_mismatch": [SWITCH_OFF_FIX],
        "swapped_row_refused": [SWITCH_OFF_FIX],
    }.get(defect, [])


def _person_name(row_id: str, row: Mapping[str, Any], profiles: Mapping[str, Mapping[str, Any]]) -> str:
    profile = profiles.get(_text(row, *LINK_KEYS)) or profiles.get(row_id) or {}
    return _text(profile, "name", "name") or _text(row, "name", "name") or _text(row, "email", "email") or row_id


def _switched_off_already(row: Mapping[str, Any]) -> bool:
    reasons = row.get("disabledReasons")
    return isinstance(reasons, list) and SWITCH_OFF_REASON in reasons


def _row_item(row_id: str, rows: Mapping[str, Mapping[str, Any]], profiles: Mapping[str, Mapping[str, Any]],
              defect: str, text: str) -> dict[str, Any]:
    row = rows.get(row_id, {})
    return {"id": f"{defect}:{row_id}", "rowId": row_id,
            "employeeCode": _text(row, "employeeCode", "staffId") or row_id,
            "name": _person_name(row_id, row, profiles), "defect": defect, "text": text,
            "fixes": [fix for fix in _fixes(defect) if not (fix["id"] == "switch_off" and _switched_off_already(row))]}


def _blocker_text(key: str, row_id: str, rows: Mapping[str, Mapping[str, Any]],
                  profiles: Mapping[str, Mapping[str, Any]]) -> str:
    only = {"maintenance": False, "unknownRole": [], "profileMissing": [], "identityAnomalies": [], key: [row_id]}
    [text] = prepare_data.blockers_of(only, rows, profiles)
    return text.removesuffix(f" {prepare_data.ENGINEER}")


def people_defects(db: Any, auth_client: admin_auth.Client | None, *,
                   transaction: Any = None) -> list[dict[str, Any]]:
    plan = plan_migration(db, transaction=transaction)
    found = prepare_data.survey(db, auth_client, transaction=transaction)
    rows = {row_id: snapshot.to_dict() or {} for row_id, snapshot in found["rows"].items()}
    profiles = {profile_id: snapshot.to_dict() or {} for profile_id, snapshot in found["profiles"].items()}
    items: list[dict[str, Any]] = []
    for move in found["moves"]:
        items.append(_row_item(move["replaces"], rows, profiles, "swapped_row", PREPARE_MOVES))
    handled = {move["replaces"] for move in found["moves"]}
    for refused in found["refused"]:
        handled.add(refused["uid"])
        defect = REFUSED_DEFECT.get(refused["reason"], "swapped_row_refused")
        items.append(_row_item(refused["uid"], rows, profiles, defect,
                               prepare_data.refusal_blockers([refused])[0]))
    for key, kind in (("unknownRole", "unknown_role"), ("profileMissing", "profile_missing"),
                      ("identityAnomalies", "identity_mismatch")):
        for row_id in plan[key]:
            if row_id in handled:
                continue
            text = _blocker_text(key, row_id, rows, profiles)
            defect = "two_rows" if kind == "identity_mismatch" and "already uses the profile" in text else kind
            items.append(_row_item(row_id, rows, profiles, defect, text))
    if auth_client is not None:
        for row_id, row in sorted(rows.items()):
            switched_off = SWITCH_OFF_REASON in (row.get("disabledReasons") or []) or not rules_active(row)
            uid = _text(row, *UID_KEYS).strip() or row_id
            if row_id not in handled and not switched_off and not _account_exists(auth_client, uid):
                items.append(_row_item(row_id, rows, profiles, "no_account",
                                       f"{_text(row, 'employeeCode', 'staffId') or row_id}: the person has no "
                                       "sign-in account in Firebase Auth."))
    return sorted(items, key=lambda item: (item["rowId"], item["defect"]))


def _change(path: str, before: Mapping[str, Any] | None, update: Mapping[str, Any]) -> dict[str, Any]:
    return {"path": path, "before": before, "update": dict(update)}


def _switched_off(row_path: str, row: Mapping[str, Any], replace_damaged: bool = False) -> dict[str, Any]:
    reasons = row.get("disabledReasons", [])
    if not isinstance(reasons, list) and replace_damaged:
        reasons = []
    if not isinstance(reasons, list):
        raise PeopleRefused("The list of switch-off reasons of this record is damaged. Ask the Scoot engineer.")
    if SWITCH_OFF_REASON in reasons:
        raise PeopleRefused("This person is switched off already. Look again.")
    return _change(row_path, row, {"disabledReasons": sorted([*reasons, SWITCH_OFF_REASON]),
                                   "status": "suspended", "isActive": False})


def _profile_id_for(read: Callable[[str], Any], row_id: str, row: Mapping[str, Any]) -> str:
    link = _text(row, *LINK_KEYS)
    if link:
        return link
    code = _text(row, "employeeCode", "staffId").strip()
    return code if code and "/" not in code and read(f"users/{code}") is None else (_text(row, *UID_KEYS) or row_id)


FIRESTORE_RESERVED_ID = re.compile(r"^__.*__$")


def _checked_row_id(item_id: str) -> tuple[str, str]:
    defect, _, row_id = item_id.partition(":")
    if (not row_id or "/" in row_id or row_id in (".", "..") or FIRESTORE_RESERVED_ID.match(row_id)
            or len(row_id.encode("utf-8")) > 1500):
        raise PeopleInvalid("This person id is not valid. Look again.")
    return defect, row_id


def _first_user_of_link(rows: Mapping[str, Mapping[str, Any]], link: str) -> str | None:
    for row_id, row in sorted(rows.items()):
        if _text(row, *LINK_KEYS) == link and seat_class_for_role(_canonical_role(row)) is not None:
            return row_id
    return None


def _two_rows_exist(rows: Mapping[str, Mapping[str, Any]], row_id: str, row: Mapping[str, Any]) -> bool:
    link = _text(row, *LINK_KEYS)
    if link and _first_user_of_link(rows, link) not in (None, row_id):
        return True
    uid = _text(row, *UID_KEYS).strip()
    return bool(uid) and uid != row_id and (uid in rows or any(
        other_id < row_id and _text(other, *UID_KEYS).strip() == uid for other_id, other in rows.items()))


def _other_active_admin_exists(rows: Mapping[str, Mapping[str, Any]], row_id: str) -> bool:
    return any(other_id != row_id and _canonical_role(other) == "admin" and rules_active(other)
               and not _switched_off_already(other) for other_id, other in rows.items())


def _changes(db: Any, transaction: Any, auth_client: admin_auth.Client | None, item_id: str,
             fix_id: str) -> list[dict[str, Any]]:
    defect, row_id = _checked_row_id(item_id)
    if fix_id not in FIXES_FOR.get(defect, set()):
        raise PeopleRefused("This fix does not belong to this problem. Look again.")
    read = _reader(db, transaction)
    row_path = f"user_access/{row_id}"
    row = read(row_path)
    if row is None:
        raise PeopleNotFound(CHANGED_SINCE_OPEN)
    link = _text(row, *LINK_KEYS)
    profile_path = f"users/{link}" if link and "/" not in link else None
    profile = read(profile_path) if profile_path else None
    known_role = seat_class_for_role(_canonical_role(row)) is not None
    if defect == "unknown_role" and known_role:
        raise PeopleRefused(CHANGED_SINCE_OPEN)
    if defect == "profile_missing" and (profile is not None or not known_role):
        raise PeopleRefused(CHANGED_SINCE_OPEN)
    if defect == "no_account" and (auth_client is None or _account_exists(auth_client, _text(row, *UID_KEYS) or row_id)):
        raise PeopleRefused(CHANGED_SINCE_OPEN)
    if defect in REREAD_DEFECTS and item_id not in {
            item["id"] for item in people_defects(db, auth_client, transaction=transaction)}:
        raise PeopleRefused(CHANGED_SINCE_OPEN)
    if defect == "two_rows" or fix_id == "switch_off":
        rows = {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection("user_access").stream(transaction=transaction)}
        if defect == "two_rows" and not _two_rows_exist(rows, row_id, row):
            raise PeopleRefused(CHANGED_SINCE_OPEN)
        if fix_id == "switch_off" and _canonical_role(row) == "admin" and rules_active(row) and not _other_active_admin_exists(rows, row_id):
            raise PeopleRefused("This person is the last active administrator. Make another administrator first.")
    if fix_id == "switch_off":
        changes = [_switched_off(row_path, row, defect == "swapped_row_refused")]
        if profile is not None and profile_path and defect not in ROW_ONLY_SWITCH_OFF:
            changes.append(_switched_off(profile_path, profile))
        return changes
    if fix_id.startswith("set_role:"):
        role = fix_id.partition(":")[2]
        update = {"role": role, **({"user_group": role} if "user_group" in row else {})}
        changes = [_change(row_path, row, update)]
        if profile is not None and profile_path:
            changes.append(_change(profile_path, profile, {"role": role, **({"user_group": role} if "user_group" in profile else {})}))
        return changes
    profile_id = _profile_id_for(read, row_id, row)
    if read(f"users/{profile_id}") is not None:
        raise PeopleRefused("A profile exists already at the id this record would use. Ask the Scoot engineer.")
    uid = _text(row, *UID_KEYS).strip() or row_id
    email = _text(row, "email", "email")
    code = _text(row, "employeeCode", "staffId")
    made = {key: row[key] for key in PROFILE_KEYS if key in row}
    made.update({"uid": uid, "name": _text(row, "name", "name") or code or uid,
                 "username": email.partition("@")[0] or uid})
    changes = [_change(f"users/{profile_id}", None, made)]
    if link != profile_id:
        key = "user_doc_id" if "user_doc_id" in row and "userDocId" not in row else "userDocId"
        changes.insert(0, _change(row_path, row, {key: profile_id}))
    return changes


def _encoded(changes: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    return [{key: encode(value) for key, value in change.items()} for change in changes]


def _shown(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value, default=str)


def _summary(changes: Sequence[Mapping[str, Any]]) -> list[str]:
    lines = []
    for change in changes:
        before = change["before"]
        if before is None:
            lines.append(f"Creates {change['path']} with {', '.join(sorted(change['update']))}.")
            continue
        for key, value in change["update"].items():
            lines.append(f"{change['path']}: {key} changes from {_shown(before.get(key))} to {_shown(value)}.")
    return lines


def _reader(db: Any, transaction: Any = None) -> Callable[[str], Any]:
    def read(path: str) -> Any:
        snapshot = db.document(path).get(transaction=transaction)
        return snapshot.to_dict() or {} if snapshot.exists else None
    return read


def preview_fix(db: Any, auth_client: admin_auth.Client | None, item_id: str, fix_id: str) -> dict[str, Any]:
    changes = _changes(db, None, auth_client, item_id, fix_id)
    return {"itemId": item_id, "fixId": fix_id, "changes": _encoded(changes), "summary": _summary(changes)}


def apply_fix(db: Any, auth_client: admin_auth.Client | None, item_id: str, fix_id: str,
              expected: Mapping[str, Any], actor: str) -> dict[str, Any]:
    shown = expected.get("changes")
    if _encoded(_changes(db, None, auth_client, item_id, fix_id)) != shown:
        raise PeopleRefused(CHANGED_SINCE_OPEN)
    archive_ids = [f"fix-{uuid.uuid4().hex}" for _ in shown]

    @firestore.transactional
    def write(transaction: firestore.Transaction) -> list[str]:
        held = usage_ref(db).get(transaction=transaction)
        if held.exists and (held.to_dict() or {}).get(MAINTENANCE):
            raise PeopleRefused("The company data is being prepared. Try again when it has finished.")
        changes = _changes(db, transaction, auth_client, item_id, fix_id)
        if _encoded(changes) != shown:
            raise PeopleRefused(CHANGED_SINCE_OPEN)
        for archive_id, change in zip(archive_ids, changes):
            transaction.set(db.collection(ARCHIVE).document(archive_id), {
                "path": change["path"], "row": change["before"], "update": change["update"],
                "archivedAt": firestore.SERVER_TIMESTAMP, "archivedBy": actor, "reason": BEFORE_FIX,
                "fixId": fix_id, "itemId": item_id,
            })
            transaction.set(db.document(change["path"]), change["update"], merge=True)
        return [change["path"] for change in changes]

    return {"written": write(db.transaction()), "archived": archive_ids, "by": actor}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Repair swapped staff rows and add a first administrator.")
    parser.add_argument("--project", required=True, help="company Firebase project ID")
    parser.add_argument("--database", default="(default)", help="Firestore database ID")
    parser.add_argument("--grant-admin", metavar="EMAIL", help="email of an existing sign-in account to make an admin")
    parser.add_argument("--code", help="employee code of the new admin")
    parser.add_argument("--name", help="display name of the new admin")
    parser.add_argument("--branch", help="branch ID of the new admin (default: the branch of the admins)")
    parser.add_argument("--apply", action="store_true", help="write the documents (default: print only)")
    parser.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    args = parser.parse_args(argv)
    if args.apply and args.confirm_project != args.project:
        print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
        return 2
    if bool(args.grant_admin) != bool(args.code) or (args.name or args.branch) and not args.grant_admin:
        print("--grant-admin and --code go together. --name and --branch need --grant-admin.", file=sys.stderr)
        return 2
    grant = Grant(args.grant_admin, args.code, args.name, args.branch) if args.grant_admin else None
    try:
        db = _client(args.project, args.database)
        if args.apply and args.confirm_project != db.project:
            print("--confirm-project does not match the opened project.", file=sys.stderr)
            return 2
        auth_client = project_auth(args.project)
        plan = plan_repair(db, auth_client, grant)
        applied = apply_repair(db, auth_client, plan) if args.apply and plan.writes else None
    except RepairRefused as error:
        print(str(error), file=sys.stderr)
        return 2
    except (*UNREACHABLE, FirebaseError, GoogleAuthError, RuntimeError, OSError) as error:
        print(f"The project could not be read: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report(db.project, plan, applied), indent=2, sort_keys=True))
    if not plan.writes:
        return 3
    return 4 if applied and applied["changedDuringApply"] else 0


if __name__ == "__main__":
    sys.exit(main())

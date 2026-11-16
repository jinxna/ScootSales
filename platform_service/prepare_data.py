from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping, Sequence

from firebase_admin import auth as admin_auth

from .access_migration import LINK_KEYS, MOVED, UID_KEYS, _identity, _text, apply_convertible, plan_swapped_rows
from .commands import CommandProblem, UsageMissing
from .migrate_seats import STILL_RUNNING, _canonical_role, apply_migration, lease_is_fresh, plan_migration
from .seats import POOL_LABELS, POOLS, project_counts, seat_class_for_role

COUNT_LABELS = {**POOL_LABELS, "admins": "Admins", "branchManagers": "Branch managers"}
CHECK_TIMEOUT_SECONDS = 5
PREPARING = ("A preparation of this company is not finished. If it is running, wait until it finishes, then check "
             "again. If it stopped half-way, an owner can resume it in step 3 of the company setup.")


def _count(count: int, word: str) -> str:
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


SWAPPED_REFUSALS = {
    "swapped_row_no_account": "has no sign-in account in Firebase Auth, so its record cannot be moved to its sign-in id. "
                              "Create the account again or remove this person",
    "swapped_row_target_exists": "has a record stored under the wrong id, and a record already exists at the sign-in id. "
                                 "Remove one of the two records",
    "swapped_row_link_elsewhere": "has a record that links to another profile than the one stored under its id. "
                                  "Correct the link or remove the record",
    "swapped_row_duplicate": "shares its sign-in id with another record stored under the wrong id. Remove one of the records",
    "swapped_row_auth_unchecked": "has a record stored under the wrong id, and the sign-in accounts could not be checked. "
                                  "Press Prepare company data again",
    "inactive": "is switched off, so the record stored under the wrong id is not moved. Switch the person on or remove the record",
    "unknown_role": "has a record stored under the wrong id with a role Scoot does not know. Correct the role or remove the record",
    "uid_mismatch": "has a record stored under the wrong id that names two different sign-in ids. Correct the record or remove it",
    "invalid_disabled_reasons": "has a record stored under the wrong id with a damaged list of switch-off reasons. "
                                "Correct the record or remove it",
}
ENGINEER = "Ask the Scoot engineer to correct or remove it, then check again."
MOVED_DURING_PREPARE = ("A staff record changed while the company was being prepared. "
                        "Press Prepare company data again.")


def _label(row_id: str, row: Mapping[str, Any]) -> str:
    return _identity(row)["employeeCode"] or row_id


def _stored_under(row_id: str, row: Mapping[str, Any]) -> str:
    uid = _text(row, *UID_KEYS).strip()
    if uid and uid != row_id:
        return f" The record is stored under the id {row_id} but names the uid {uid}."
    return ""


def _identity_defect(row_id: str, row: Mapping[str, Any], profiles: Mapping[str, Mapping[str, Any]],
                     first_user: Mapping[str, str]) -> str:
    link = _text(row, *LINK_KEYS)
    stored = profiles.get(link, {})
    uid_of_row = row.get("uid") if row.get("accessVersion") == 2 else row.get("uid", row_id)
    if first_user.get(link, row_id) != row_id:
        return f"another record already uses the profile {link}."
    if uid_of_row != row_id:
        return f"the record names the uid {uid_of_row} but is stored under the id {row_id}."
    if stored.get("uid") != row_id:
        return f"the profile {link} names another uid."
    if _canonical_role(stored) != _canonical_role(row):
        return f"the profile {link} has another role than the record."
    return "the record and its profile do not match."


def blockers_of(plan: Mapping[str, Any], rows: Mapping[str, Mapping[str, Any]],
                profiles: Mapping[str, Mapping[str, Any]]) -> list[str]:
    found: list[str] = []
    if plan["maintenance"]:
        found.append(PREPARING)
    first_user: dict[str, str] = {}
    for row_id, row in sorted(rows.items()):
        link = _text(row, *LINK_KEYS)
        if seat_class_for_role(_canonical_role(row)) is not None and link in profiles:
            first_user.setdefault(link, row_id)
    for row_id in plan["unknownRole"]:
        row = rows.get(row_id, {})
        role = _canonical_role(row)
        what = f"the role {role} is not a role Scoot knows." if role else "the record has no role."
        found.append(f"{_label(row_id, row)}: {what}{_stored_under(row_id, row)} {ENGINEER}")
    for row_id in plan["profileMissing"]:
        row = rows.get(row_id, {})
        link = _text(row, *LINK_KEYS)
        what = (f"the record links to the profile {link}, and that profile does not exist."
                if link else "the record has no link to a profile.")
        found.append(f"{_label(row_id, row)}: {what}{_stored_under(row_id, row)} {ENGINEER}")
    for row_id in plan["identityAnomalies"]:
        row = rows.get(row_id, {})
        found.append(f"{_label(row_id, row)}: {_identity_defect(row_id, row, profiles, first_user)} {ENGINEER}")
    return found


def survey(db: Any, auth_client: admin_auth.Client | None, *, transaction: Any = None) -> dict[str, Any]:
    rows = {snapshot.id: snapshot for snapshot in db.collection("user_access").stream(transaction=transaction)}
    profiles = {snapshot.id: snapshot for snapshot in db.collection("users").stream(transaction=transaction)}
    moves, refused = plan_swapped_rows(rows, profiles, auth_client)
    return {"rows": rows, "profiles": profiles, "moves": moves, "refused": refused}


def refusal_blockers(refused: Sequence[Mapping[str, Any]]) -> list[str]:
    return [f"{row['code']}: the person {SWAPPED_REFUSALS[row['reason']]}, then check again."
            for row in refused]


def fit_of(counts: Mapping[str, int], package: Mapping[str, Any]) -> dict[str, Any]:
    schema = package.get("quotaSchemaVersion", 1)
    shown = project_counts(counts, 2, schema)
    exceeded = []
    for key, limit in package["limits"].items():
        if limit is not None and shown[key] > limit:
            exceeded.append(f"{shown[key]} {COUNT_LABELS[key].lower()}, {package['name']} allows {limit}")
    return {"planId": package["planId"], "name": package["name"], "fits": not exceeded, "exceeded": exceeded}


def report(db: Any, packages: Sequence[Mapping[str, Any]], current_plan_id: str | None,
           auth_client: admin_auth.Client | None = None) -> dict[str, Any]:
    plan = plan_migration(db)
    found = survey(db, auth_client)
    handled = {move["replaces"] for move in found["moves"]} | {row["uid"] for row in found["refused"]}
    open_plan = {**plan, **{key: [item for item in plan[key] if item not in handled]
                            for key in ("unknownRole", "profileMissing", "identityAnomalies", "profilesWithoutAccess")}}
    rows = {row_id: snapshot.to_dict() or {} for row_id, snapshot in found["rows"].items()}
    profiles = {profile_id: snapshot.to_dict() or {} for profile_id, snapshot in found["profiles"].items()}
    counts = {key: plan["usage"][key] for key in (*POOLS, "products")}
    notes = []
    if open_plan["profilesWithoutAccess"]:
        notes.append(f"{_count(len(open_plan['profilesWithoutAccess']), 'profile')} without an access record. "
                     "It is not given access. Invite the person again if they need it.")
    blockers = [*blockers_of(open_plan, rows, profiles), *refusal_blockers(found["refused"])]
    moves = [{"code": move["code"], "rowId": move["replaces"], "uid": move["uid"], "action": MOVED}
             for move in found["moves"]]
    running = lease_is_fresh(plan["maintenance"], datetime.now(timezone.utc))
    return {
        "counts": counts,
        "changes": {"accessRecords": len(plan["accessChanges"]), "profiles": len(plan["profileChanges"])},
        "moves": moves,
        "halfDone": bool(plan["maintenance"]) and not running,
        "running": running,
        "prepared": (not plan["usageChanged"] and not plan["accessChanges"] and not plan["profileChanges"]
                     and not moves and not blockers and not plan["maintenance"]),
        "blockers": blockers,
        "notes": notes,
        "ready": not blockers,
        "currentPlanId": current_plan_id,
        "fit": [fit_of(counts, package) for package in packages],
    }


def prepare(db: Any, packages: Sequence[Mapping[str, Any]], current_plan_id: str | None,
            auth_client: admin_auth.Client | None = None) -> dict[str, Any]:
    before = report(db, packages, current_plan_id, auth_client)
    if before["blockers"]:
        raise CommandProblem(" ".join(before["blockers"]))
    outcome = apply_convertible(db, survey(db, auth_client)["moves"], auth_client)
    if outcome["changedDuringApply"]:
        raise CommandProblem(MOVED_DURING_PREPARE)
    try:
        apply_migration(db, plan_migration(db))
    except UsageMissing:
        raise CommandProblem(PREPARING) from None
    return report(db, packages, current_plan_id, auth_client)


def resume(db: Any, packages: Sequence[Mapping[str, Any]], current_plan_id: str | None,
           auth_client: admin_auth.Client | None = None) -> dict[str, Any]:
    held = plan_migration(db)["maintenance"]
    if not held:
        raise CommandProblem("No preparation is waiting to be resumed.")
    if lease_is_fresh(held, datetime.now(timezone.utc)):
        raise CommandProblem(STILL_RUNNING)
    token = held.get("operationId") if isinstance(held, Mapping) else None
    if not token:
        raise CommandProblem("The half-done preparation cannot be resumed from this screen: send the company name "
                             "to the Scoot engineer.")
    before = report(db, packages, current_plan_id, auth_client)
    blockers = [text for text in before["blockers"] if text != PREPARING]
    if blockers:
        raise CommandProblem(" ".join(blockers))
    outcome = apply_convertible(db, survey(db, auth_client)["moves"], auth_client)
    if outcome["changedDuringApply"]:
        raise CommandProblem(MOVED_DURING_PREPARE)
    apply_migration(db, plan_migration(db), resume_operation=token)
    return report(db, packages, current_plan_id, auth_client)

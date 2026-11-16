from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from typing import Any, Callable, Mapping

from firebase_admin import auth as admin_auth
from google.cloud import firestore

from .commands import CommandProblem
from .migrate_seats import SWITCH_OFF_REASON, _canonical_role, _client, _truthy

V2_ROLES = ("admin", "developer", "branch_manager", "supervisor", "salesman")
LINK_KEYS = ("userDocId", "user_doc_id")
UID_KEYS = ("uid", "userUid")
SWAPPED = "swapped_row"
MOVED = "row moved to its sign-in id"
ARCHIVE = "user_access_archive"
SEAT_KEYS = frozenset({"seatClass", "seatHeld"})
CHANGED_AFTER_MOVE = "This record changed after the move. Look at it before you restore."


class RestoreRefused(CommandProblem):
    pass


def rules_active(data: Mapping[str, Any]) -> bool:
    flag = next((data[key] for key in ("isActive", "is_active", "active", "enabled") if key in data), True)
    state = next((data[key] for key in ("status", "accountStatus", "account_status") if key in data), "active")
    return (_truthy(flag) or (flag is None and data.get("active", False) is True)) and state in ("active", "Active")


def _text(data: Mapping[str, Any], camel: str, snake: str) -> str:
    for key in (camel, snake):
        value = data.get(key)
        if isinstance(value, str):
            return value
    return ""


def _identity(actor: Mapping[str, Any]) -> dict[str, Any]:
    code = _text(actor, "employeeCode", "staffId") or _text(actor, "salesmanCode", "salesman_code")
    codes = actor.get("assignedSalesmanCodes")
    return {
        "role": _canonical_role(actor),
        "branchId": _text(actor, "branchId", "branch_id"),
        "employeeCode": code,
        "assignedSalesmanCodes": codes if isinstance(codes, list) else [],
    }


def _disabled_reasons(*sources: Mapping[str, Any]) -> list[Any] | None:
    merged: list[Any] = []
    for source in sources:
        if "disabledReasons" not in source:
            continue
        reasons = source["disabledReasons"]
        if not isinstance(reasons, list):
            return None
        merged.extend(reason for reason in reasons if reason not in merged)
    return merged


def _v2_fields(uid: str, actor: Mapping[str, Any], reasons: list[Any], link_id: str | None) -> dict[str, Any]:
    identity = _identity(actor)
    fields: dict[str, Any] = {
        "accessVersion": 2,
        "uid": uid,
        "status": "active",
        "role": identity["role"],
        "branchId": identity["branchId"],
        "employeeCode": identity["employeeCode"],
        "disabledReasons": reasons,
    }
    if identity["role"] == "supervisor" or identity["assignedSalesmanCodes"]:
        fields["assignedSalesmanCodes"] = identity["assignedSalesmanCodes"]
    if link_id:
        fields["userDocId"] = link_id
    return fields


def _judge(uid: str, access: Mapping[str, Any] | None, profile: Mapping[str, Any] | None,
           link_id: str | None) -> tuple[dict[str, Any] | None, str | None]:
    actor = profile if profile is not None else access
    if access is not None and (access.get("uid", uid) != uid or access.get("user_uid", uid) != uid):
        return None, "uid_mismatch"
    if profile is not None and access is not None and any(key in profile for key in UID_KEYS) \
            and _text(profile, "uid", "userUid") != uid:
        return None, "uid_mismatch"
    if not ((access is None or rules_active(access)) and rules_active(actor)):
        return None, "inactive"
    if _identity(actor)["role"] not in V2_ROLES:
        return None, "unknown_role"
    reasons = _disabled_reasons(*(source for source in (access, profile) if source is not None))
    if reasons is None:
        return None, "invalid_disabled_reasons"
    return _v2_fields(uid, actor, reasons, link_id), None


def judge_access_row(uid: str, data: Mapping[str, Any],
                     profile_for: Callable[[str], Any]) -> tuple[dict[str, Any] | None, str | None, Any]:
    if data.get("accessVersion") is not None:
        return None, "unsupported_access_version", None
    link_id = _text(data, "userDocId", "user_doc_id")
    profile = None
    if any(key in data for key in LINK_KEYS):
        profile = profile_for(link_id) if link_id and "/" not in link_id else None
        if profile is None or not profile.exists:
            return None, "broken_link", None
    fields, reason = _judge(uid, data, (profile.to_dict() or {}) if profile else None, link_id or None)
    return fields, reason, profile


def _stamps(*snapshots: Any) -> list[tuple[Any, Any]]:
    return [(snapshot.reference, snapshot.update_time) for snapshot in snapshots if snapshot is not None]


def plan_lifecycle_access(db: Any) -> dict[str, Any]:
    from .lifecycle import ACCESS_FOR_STATE, LAPSED_STATES, drain_length

    snapshot = db.collection("config").document("lifecycle").get()
    if not snapshot.exists:
        return {"status": "missing", "fields": {}, "guard": None}
    data = snapshot.to_dict() or {}
    state = data.get("state")
    if state not in ACCESS_FOR_STATE:
        return {"status": "unknown_state", "fields": {}, "guard": None}
    if data.get("access") is not None:
        return {"status": "present", "fields": {}, "guard": None}
    fields: dict[str, Any] = {"access": ACCESS_FOR_STATE[state]}
    since = data.get("stateSince")
    if state in LAPSED_STATES and data.get("cutAt") is None and data.get("drainUntil") is None             and isinstance(since, datetime):
        fields.update({"cutAt": since, "drainUntil": since + drain_length()})
    return {"status": "planned", "fields": fields, "guard": (snapshot.reference, snapshot.update_time)}


def _account_exists(auth_client: admin_auth.Client, uid: str) -> bool:
    try:
        auth_client.get_user(uid)
    except admin_auth.UserNotFoundError:
        return False
    return True


def _same_person(row: Mapping[str, Any], profile: Mapping[str, Any]) -> bool:
    mine, theirs = _identity(row), _identity(profile)
    return all(mine[key] == theirs[key] for key in ("role", "employeeCode", "branchId"))


def plan_swapped_rows(access: Mapping[str, Any], profiles: Mapping[str, Any],
                      auth_client: admin_auth.Client | None) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    moves: list[dict[str, Any]] = []
    refused: list[dict[str, Any]] = []
    claimed: set[str] = set()
    for row_id, snapshot in sorted(access.items()):
        data = snapshot.to_dict() or {}
        uid = _text(data, *UID_KEYS).strip()
        own = profiles.get(uid) if row_id not in profiles and _text(data, *LINK_KEYS) == uid else None
        profile_id = uid if own is not None and _same_person(data, own.to_dict() or {}) else row_id
        profile = profiles.get(profile_id)
        profile_data = (profile.to_dict() or {}) if profile is not None else {}
        reasons = data.get("disabledReasons")
        if data.get("accessVersion") is not None or not uid or uid == row_id \
                or _text(profile_data, *UID_KEYS).strip() != uid \
                or (isinstance(reasons, list) and SWITCH_OFF_REASON in reasons):
            continue
        fields, reason = _judge(uid, data, profile_data, profile_id)
        if _text(data, *LINK_KEYS) not in ("", uid, row_id):
            reason = "swapped_row_link_elsewhere"
        elif uid in access:
            reason = "swapped_row_target_exists"
        elif uid in claimed:
            reason = "swapped_row_duplicate"
        elif fields is None:
            pass
        elif auth_client is None:
            reason = "swapped_row_auth_unchecked"
        elif not _account_exists(auth_client, uid):
            reason = "swapped_row_no_account"
        else:
            reason = None
        code = _text(profile_data, "employeeCode", "staffId") or row_id
        if reason is not None:
            refused.append({"uid": row_id, "source": "access", "reason": reason, "code": code})
            continue
        claimed.add(uid)
        moves.append({
            "uid": uid, "source": "access", "reason": SWAPPED, "replaces": row_id, "code": code,
            "original": data,
            "base": {key: value for key, value in data.items() if key != "user_doc_id"},
            "fields": fields,
            "guards": _stamps(snapshot, profile) + [(snapshot.reference.parent.document(uid), None)]
            + ([(profile.reference.parent.document(row_id), None)] if profile_id != row_id else []),
        })
    return moves, refused


def plan_access_migration(db: Any, auth_client: admin_auth.Client | None = None) -> dict[str, Any]:
    profiles = {snapshot.id: snapshot for snapshot in db.collection("users").stream()}
    access = {snapshot.id: snapshot for snapshot in db.collection("user_access").stream()}
    moves, refused = plan_swapped_rows(access, profiles, auth_client)
    swapped_ids = {move["replaces"] for move in moves} | {row["uid"] for row in refused}
    convertible: list[dict[str, Any]] = list(moves)
    cannot: list[dict[str, Any]] = list(refused)
    already_v2 = 0
    access_ids: set[str] = set()
    linked_ids: set[str] = set()
    for uid, snapshot in access.items():
        data = snapshot.to_dict() or {}
        access_ids.add(uid)
        link_id = _text(data, "userDocId", "user_doc_id")
        if link_id:
            linked_ids.add(link_id)
        if uid in swapped_ids:
            continue
        if data.get("accessVersion") == 2:
            already_v2 += 1
            continue
        fields, reason, profile = judge_access_row(uid, data, profiles.get)
        entry = {"uid": uid, "source": "access"}
        if fields is None:
            cannot.append({**entry, "reason": reason})
        else:
            convertible.append({**entry, "fields": fields, "guards": _stamps(snapshot, profile)})
    unlinked: list[str] = []
    for profile_id, profile in sorted(profiles.items()):
        if profile_id in access_ids or profile_id in linked_ids:
            continue
        data = profile.to_dict() or {}
        if not (any(key in data for key in UID_KEYS) and _text(data, "uid", "userUid") == profile_id):
            unlinked.append(profile_id)
            continue
        entry = {"uid": profile_id, "source": "uid_profile"}
        fields, reason = _judge(profile_id, None, data, profile_id)
        if fields is None:
            cannot.append({**entry, "reason": reason})
        else:
            convertible.append({
                **entry,
                "fields": fields,
                "guards": _stamps(profile) + [(db.collection("user_access").document(profile_id), None)],
            })
    return {
        "convertible": convertible,
        "cannotConvert": cannot,
        "alreadyV2": already_v2,
        "unlinkedProfiles": unlinked,
        "lifecycle": plan_lifecycle_access(db),
    }


def apply_convertible(db: Any, entries: list[Mapping[str, Any]],
                      auth_client: admin_auth.Client | None = None,
                      actor: str = "prepare") -> dict[str, list[str]]:
    written: list[str] = []
    changed: list[str] = []

    @firestore.transactional
    def convert(transaction: firestore.Transaction, entry: Mapping[str, Any]) -> bool:
        for reference, scanned in entry["guards"]:
            if reference.get(transaction=transaction).update_time != scanned:
                return False
        target = db.collection("user_access").document(entry["uid"])
        if "replaces" in entry:
            archive = db.collection(ARCHIVE).document(entry["replaces"])
            kept = archive.get(transaction=transaction)
            if kept.exists and not (kept.to_dict() or {}).get("restoredAt"):
                return False
            moved = {**entry["base"], **entry["fields"]}
            transaction.set(target, moved)
            transaction.set(archive, {
                "row": entry["original"], "archivedAt": firestore.SERVER_TIMESTAMP, "archivedBy": actor,
                "reason": SWAPPED, "movedTo": entry["uid"], "movedRow": moved,
            })
            transaction.delete(db.collection("user_access").document(entry["replaces"]))
        else:
            transaction.set(target, entry["fields"], merge=True)
        return True

    for entry in entries:
        account_gone = "replaces" in entry and (auth_client is None or not _account_exists(auth_client, entry["uid"]))
        (written if not account_gone and convert(db.transaction(), entry) else changed).append(entry["uid"])
    return {"written": written, "changedDuringApply": changed}


def _comparable(row: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in row.items() if key not in SEAT_KEYS}


def restore_moved_row(db: Any, old_id: str, actor: str) -> dict[str, str]:
    archive = db.collection(ARCHIVE).document(old_id)
    old = db.collection("user_access").document(old_id)

    @firestore.transactional
    def put_back(transaction: firestore.Transaction) -> str:
        kept = archive.get(transaction=transaction)
        if not kept.exists or (kept.to_dict() or {}).get("restoredAt"):
            raise RestoreRefused("There is no archived record to restore.")
        entry = kept.to_dict() or {}
        moved = db.collection("user_access").document(entry["movedTo"])
        current = moved.get(transaction=transaction)
        if old.get(transaction=transaction).exists:
            raise RestoreRefused("A record exists already at the old id. Look at it before you restore.")
        if not current.exists or _comparable(current.to_dict() or {}) != _comparable(entry["movedRow"]):
            raise RestoreRefused(CHANGED_AFTER_MOVE)
        transaction.set(old, entry["row"])
        transaction.delete(moved)
        transaction.update(archive, {"restoredAt": firestore.SERVER_TIMESTAMP, "restoredBy": actor})
        return entry["movedTo"]

    return {"restored": old_id, "removed": put_back(db.transaction())}


FIX_CHANGED = "This record changed after the fix. Look at it before you restore."
BEFORE_FIX = "before_fix"


def restore_fix_change(db: Any, archive_id: str, actor: str) -> dict[str, str]:
    archive = db.collection(ARCHIVE).document(archive_id)

    @firestore.transactional
    def put_back(transaction: firestore.Transaction) -> str:
        kept = archive.get(transaction=transaction)
        entry = kept.to_dict() or {}
        if not kept.exists or entry.get("restoredAt") or entry.get("reason") != BEFORE_FIX:
            raise RestoreRefused("There is no archived record to restore.")
        target = db.document(entry["path"])
        current = target.get(transaction=transaction)
        expected = {**(entry["row"] or {}), **entry["update"]}
        if not current.exists or (current.to_dict() or {}) != expected:
            raise RestoreRefused(FIX_CHANGED)
        if entry["row"] is None:
            transaction.delete(target)
        else:
            transaction.set(target, entry["row"])
        transaction.update(archive, {"restoredAt": firestore.SERVER_TIMESTAMP, "restoredBy": actor})
        return entry["path"]

    return {"restored": archive_id, "path": put_back(db.transaction())}


def restore_archived(db: Any, archive_id: str, actor: str) -> dict[str, str]:
    kept = db.collection(ARCHIVE).document(archive_id).get()
    if kept.exists and (kept.to_dict() or {}).get("reason") == BEFORE_FIX:
        return restore_fix_change(db, archive_id, actor)
    return restore_moved_row(db, archive_id, actor)


def archived_rows(db: Any) -> list[dict[str, Any]]:
    found = []
    for snapshot in db.collection(ARCHIVE).stream():
        data = snapshot.to_dict() or {}
        if data.get("restoredAt"):
            continue
        row = data.get("row") or {}
        found.append({"id": snapshot.id, "movedTo": data.get("movedTo"), "reason": data.get("reason"),
                      "path": data.get("path"), "fixId": data.get("fixId"),
                      "employeeCode": _text(row, "employeeCode", "staffId") or snapshot.id,
                      "archivedBy": data.get("archivedBy")})
    return sorted(found, key=lambda item: item["id"])


def apply_plan(db: Any, plan: Mapping[str, Any],
               auth_client: admin_auth.Client | None = None) -> dict[str, list[str]]:
    result = apply_convertible(db, list(plan["convertible"]), auth_client)

    @firestore.transactional
    def stamp(transaction: firestore.Transaction, lifecycle: Mapping[str, Any]) -> bool:
        reference, scanned = lifecycle["guard"]
        if reference.get(transaction=transaction).update_time != scanned:
            return False
        transaction.update(reference, dict(lifecycle["fields"]))
        return True

    lifecycle = plan.get("lifecycle") or {}
    if lifecycle.get("status") == "planned":
        result["written" if stamp(db.transaction(), lifecycle) else "changedDuringApply"].append("config/lifecycle")
    return result


def apply_migration(db: Any, auth_client: admin_auth.Client | None = None) -> dict[str, list[str]]:
    return apply_plan(db, plan_access_migration(db, auth_client), auth_client)


def report(project: str, plan: Mapping[str, Any], applied: Mapping[str, list[str]] | None) -> dict[str, Any]:
    cannot = list(plan["cannotConvert"])
    summary = {
        "legacyAccessRows": sum(1 for row in [*plan["convertible"], *cannot]
                                if row["source"] == "access"),
        "uidOnlyProfiles": sum(1 for row in [*plan["convertible"], *cannot]
                               if row["source"] == "uid_profile"),
        "alreadyV2": plan["alreadyV2"],
        "convertible": len(plan["convertible"]),
        "cannotConvert": len(cannot),
        "unlinkedProfiles": len(plan["unlinkedProfiles"]),
    }
    result: dict[str, Any] = {
        "project": project,
        "mode": "apply" if applied is not None else "dry-run",
        "summary": summary,
        "convertible": [
            {key: row["fields"][key] for key in ("role", "branchId", "employeeCode", "disabledReasons")}
            | {"uid": row["uid"], "source": row["source"]}
            | ({"reason": SWAPPED, "action": MOVED, "from": row["replaces"]} if "replaces" in row else {})
            for row in plan["convertible"]
        ],
        "cannotConvert": cannot,
        "unlinkedProfiles": plan["unlinkedProfiles"],
        "lifecycle": {
            "status": (plan.get("lifecycle") or {}).get("status", "missing"),
            "fields": {key: value.isoformat() if isinstance(value, datetime) else value
                       for key, value in ((plan.get("lifecycle") or {}).get("fields") or {}).items()},
        },
    }
    if applied is not None:
        result["applied"] = dict(applied)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Rewrite legacy access rows as v2 rows.")
    parser.add_argument("--project", required=True, help="tenant Firebase project ID")
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
    plan = plan_access_migration(db)
    applied = apply_plan(db, plan) if args.apply else None
    print(json.dumps(report(db.project, plan, applied), indent=2, sort_keys=True))
    return 3 if applied and applied["changedDuringApply"] else 0


if __name__ == "__main__":
    sys.exit(main())

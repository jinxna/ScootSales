from __future__ import annotations

import argparse
import os
import socket
import sys
import uuid
from datetime import datetime, timezone
from typing import Any, Mapping

from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from . import config
from .orderable import is_orderable
from .commands import CommandProblem, UsageMissing
from .seats import MAINTENANCE, POOLS, active_admin, counts_of, pool_for_role, seat_class_for_role, usage_ref

SWITCH_OFF_REASON = "admin_suspension"
EMULATOR_ENV = "FIRESTORE_EMULATOR_HOST"
_BATCH = 400
STILL_RUNNING = "A preparation of this company is running now. Wait until it finishes, then check again."
LEASE_LOST = "Another run took over this preparation. This run stopped and wrote nothing more."


def lease_is_fresh(marker: Any, now: datetime) -> bool:
    lease = marker.get("lease") if isinstance(marker, Mapping) else None
    beat = lease.get("heartbeatAt") if isinstance(lease, Mapping) else None
    return isinstance(beat, datetime) and (now - beat).total_seconds() < config.OPERATION_LEASE_SECONDS


def _canonical_role(data: Mapping[str, Any]) -> str:
    if data.get("accessVersion") == 2:
        raw = data.get("role")
        return raw if isinstance(raw, str) else ""
    raw = data.get("role") if isinstance(data.get("role"), str) else data.get("user_group")
    role = raw.lower().replace(" ", "_") if isinstance(raw, str) else ""
    return {"administrator": "admin", "sales_representative": "salesman"}.get(role, role)


def _truthy(flag: Any) -> bool:
    return flag is True or flag == 1 or (isinstance(flag, str) and flag.lower() in ("true", "1", "yes"))


def _signs_in(data: Mapping[str, Any]) -> bool:
    if data.get("accessVersion") == 2:
        return data.get("status") == "active"
    flag = True
    for key in ("isActive", "is_active", "active", "enabled"):
        if key in data:
            flag = data[key]
            break
    state = "active"
    for key in ("status", "accountStatus", "account_status"):
        if key in data:
            state = data[key]
            break
    return _truthy(flag) and state in ("active", "Active")


def plan_migration(db: Any, *, transaction: Any = None) -> dict[str, Any]:
    access_changes: list[dict[str, Any]] = []
    profile_changes: list[dict[str, Any]] = []
    unknown_role: list[str] = []
    profile_missing: list[str] = []
    identity_anomalies: list[str] = []
    linked: set[str] = set()
    active_linked: set[str] = set()
    profile_owner: dict[str, tuple[bool, dict[str, Any], Mapping[str, Any]]] = {}
    seats = {pool: 0 for pool in POOLS}
    active_admins = 0
    reservations = {pool: 0 for pool in POOLS}
    for snapshot in db.collection("user_access").stream(transaction=transaction):
        data = snapshot.to_dict() or {}
        role = _canonical_role(data)
        seat_class = seat_class_for_role(role)
        reasons = data.get("disabledReasons")
        switched_off = isinstance(reasons, list) and SWITCH_OFF_REASON in reasons and not _signs_in(data)
        if seat_class is None:
            if not switched_off:
                unknown_role.append(snapshot.id)
            continue
        pending = data.get("invitationState") == "pending" and data.get("seatHeld") is not False
        held = role != "developer" and (_signs_in(data) or pending)
        pool = pool_for_role(role)
        if held and pool:
            seats[pool] += 1
            if pending:
                reservations[pool] += 1
        if active_admin({**data, "role": role, "status": "active" if _signs_in(data) else "inactive"}):
            active_admins += 1
        fields = {"seatClass": seat_class, "seatHeld": held}
        if data.get("seatClass") != seat_class or data.get("seatHeld") is not held:
            access_changes.append({"uid": snapshot.id, "role": role, **fields})
        profile_id = data.get("userDocId")
        profile = (db.collection("users").document(profile_id).get(transaction=transaction)
                   if isinstance(profile_id, str) and profile_id else None)
        if profile is None or not profile.exists:
            if not switched_off:
                profile_missing.append(snapshot.id)
            continue
        stored = profile.to_dict() or {}
        access_uid = data.get("uid") if data.get("accessVersion") == 2 else data.get("uid", snapshot.id)
        if not switched_off and (profile_id in active_linked or access_uid != snapshot.id
                                 or stored.get("uid") != snapshot.id or _canonical_role(stored) != role):
            identity_anomalies.append(snapshot.id)
        linked.add(profile_id)
        if not switched_off:
            active_linked.add(profile_id)
        owner = profile_owner.get(profile_id)
        if owner is None or (owner[0] and not switched_off):
            profile_owner[profile_id] = (switched_off, fields, stored)
    for profile_id, (_, fields, stored) in profile_owner.items():
        if stored.get("seatClass") != fields["seatClass"] or stored.get("seatHeld") is not fields["seatHeld"]:
            profile_changes.append({"profileId": profile_id, **fields})
    profiles_without_access = sorted(
        snapshot.id for snapshot in db.collection("users").stream(transaction=transaction) if snapshot.id not in linked
    )
    products = sum(
        1
        for snapshot in db.collection("products").stream()
        if is_orderable(snapshot.to_dict() or {}, snapshot.id)
    )
    planned_usage = {**seats, "products": products}
    stored_usage = usage_ref(db).get()
    before = stored_usage.to_dict() or {} if stored_usage.exists else {}
    try:
        before_counts = counts_of({key: value for key, value in before.items() if key != MAINTENANCE})
    except UsageMissing:
        before_counts = None
    return {
        "accessChanges": access_changes,
        "profileChanges": profile_changes,
        "unknownRole": sorted(unknown_role),
        "profileMissing": sorted(profile_missing),
        "profilesWithoutAccess": profiles_without_access,
        "identityAnomalies": sorted(identity_anomalies),
        "before": before_counts,
        "beforeUsageSchemaVersion": before.get("usageSchemaVersion", 1) if before else None,
        "beforeActiveAdmins": before.get("activeAdmins"),
        "usageSchemaVersion": 2,
        "activeAdmins": active_admins,
        "reservations": reservations,
        "maintenance": before.get(MAINTENANCE),
        "usage": planned_usage,
        "usageChanged": (before.get("usageSchemaVersion") != 2 or before_counts != planned_usage
                         or before.get("activeAdmins") != active_admins),
    }


def apply_migration(db: Any, plan: dict[str, Any], *, resume_operation: str | None = None) -> None:
    def validate(candidate: Mapping[str, Any]) -> None:
        if candidate["unknownRole"] or candidate["profileMissing"] or candidate["identityAnomalies"]:
            raise CommandProblem("Fix unknown roles and inconsistent identity links before migration.")

    validate(plan_migration(db))
    token = resume_operation or uuid.uuid4().hex
    owner = f"{socket.gethostname()}:{os.getpid()}:{uuid.uuid4().hex}"
    reference = usage_ref(db)

    def owned_marker(data: Mapping[str, Any]) -> dict[str, Any]:
        marker = data.get(MAINTENANCE)
        lease = marker.get("lease") if isinstance(marker, Mapping) else None
        if not isinstance(lease, Mapping) or marker.get("operationId") != token or lease.get("owner") != owner:
            raise CommandProblem(LEASE_LOST)
        return {**marker, "lease": {**lease, "heartbeatAt": datetime.now(timezone.utc)}}

    @firestore.transactional
    def freeze(transaction: firestore.Transaction) -> None:
        data = reference.get(transaction=transaction).to_dict() or {}
        marker = data.get(MAINTENANCE)
        now = datetime.now(timezone.utc)
        if resume_operation:
            if (not isinstance(marker, Mapping) or marker.get("operationId") != resume_operation
                    or marker.get("writerVersion") != 2):
                raise CommandProblem("Resume requires the exact reviewed maintenance operation ID and writer version 2.")
            if lease_is_fresh(marker, now):
                raise CommandProblem(STILL_RUNNING)
        elif marker:
            raise UsageMissing("A migration barrier is held. Inspect dry-run diagnostics and use a reviewed, project-confirmed --resume-operation.")
        lease = {"owner": owner, "startedAt": now, "heartbeatAt": now}
        transaction.set(reference, {MAINTENANCE: {"operationId": token, "writerVersion": 2, "lease": lease}},
                        merge=True)

    @firestore.transactional
    def write_owned(transaction: firestore.Transaction, chunk: list[tuple[Any, dict[str, Any]]]) -> None:
        marker = owned_marker(reference.get(transaction=transaction).to_dict() or {})
        for target, fields in chunk:
            transaction.update(target, fields)
        transaction.update(reference, {MAINTENANCE: marker})

    @firestore.transactional
    def store_usage(transaction: firestore.Transaction, counted: Mapping[str, Any]) -> None:
        marker = owned_marker(reference.get(transaction=transaction).to_dict() or {})
        usage = counted["usage"]
        transaction.set(
            reference,
            {
                "usageSchemaVersion": 2,
                "seats": {pool: usage[pool] for pool in POOLS},
                "products": usage["products"],
                "activeAdmins": counted["activeAdmins"],
                MAINTENANCE: marker,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            },
        )

    @firestore.transactional
    def release(transaction: firestore.Transaction, plan: Mapping[str, Any]) -> None:
        data = reference.get(transaction=transaction).to_dict() or {}
        owned_marker(data)
        native = {key: value for key, value in data.items() if key != MAINTENANCE}
        if counts_of(native) != plan["usage"] or native.get("activeAdmins") != plan["activeAdmins"]:
            raise CommandProblem("Usage changed during migration; the maintenance barrier remains held.")
        transaction.update(reference, {MAINTENANCE: firestore.DELETE_FIELD})

    @firestore.transactional
    def stop_lease(transaction: firestore.Transaction) -> None:
        marker = (reference.get(transaction=transaction).to_dict() or {}).get(MAINTENANCE)
        lease = marker.get("lease") if isinstance(marker, Mapping) else None
        if isinstance(lease, Mapping) and marker.get("operationId") == token and lease.get("owner") == owner:
            transaction.update(reference, {MAINTENANCE: {**marker, "lease": {**lease, "heartbeatAt": None}}})

    freeze(db.transaction())
    try:
        plan = plan_migration(db)
        validate(plan)
        writes: list[tuple[Any, dict[str, Any]]] = []
        for change in plan["accessChanges"]:
            fields = {"seatClass": change["seatClass"], "seatHeld": change["seatHeld"]}
            writes.append((db.collection("user_access").document(change["uid"]), fields))
        for change in plan["profileChanges"]:
            fields = {"seatClass": change["seatClass"], "seatHeld": change["seatHeld"]}
            writes.append((db.collection("users").document(change["profileId"]), fields))
        for start in range(0, len(writes), _BATCH):
            write_owned(db.transaction(), writes[start : start + _BATCH])
        store_usage(db.transaction(), plan)
        verified = plan_migration(db)
        validate(verified)
        if verified["usageChanged"] or verified["accessChanges"] or verified["profileChanges"]:
            raise CommandProblem("Migration verification failed; the maintenance barrier remains held.")
        release(db.transaction(), plan)
    except Exception:
        stop_lease(db.transaction())
        raise


def print_plan(plan: dict[str, Any]) -> None:
    for change in plan["accessChanges"]:
        print(
            f"user_access/{change['uid']} role={change['role']} "
            f"seatClass={change['seatClass']} seatHeld={str(change['seatHeld']).lower()}"
        )
    for change in plan["profileChanges"]:
        print(
            f"users/{change['profileId']} seatClass={change['seatClass']} "
            f"seatHeld={str(change['seatHeld']).lower()}"
        )
    for uid in plan["unknownRole"]:
        print(f"skipped user_access/{uid}: unknown role")
    for uid in plan["profileMissing"]:
        print(f"no profile for user_access/{uid}")
    for profile_id in plan["profilesWithoutAccess"]:
        print(f"users/{profile_id} has no access record (not created; invite again)")
    for uid in plan["identityAnomalies"]:
        print(f"inconsistent identity link for user_access/{uid}")
    print(f"before={plan['before']} usageSchemaVersion={plan['beforeUsageSchemaVersion']} activeAdmins={plan['beforeActiveAdmins']}")
    print(f"after usageSchemaVersion=2 activeAdmins={plan['activeAdmins']} reservations={plan['reservations']}")
    if plan["maintenance"]:
        print(f"maintenance={plan['maintenance']}; review failure before project-confirmed --resume-operation")
    usage = plan["usage"]
    print(
        "config/usage "
        + " ".join(f"{key}={usage[key]}" for key in (*POOLS, "products"))
        + ("" if plan["usageChanged"] else " (unchanged)")
    )


def _client(project: str, database: str) -> Any:
    return firestore.Client(
        project=project,
        database=database,
        credentials=AnonymousCredentials() if os.environ.get(EMULATOR_ENV) else None,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Add seat fields and usage counters to a company project.")
    parser.add_argument("--project", required=True, help="company Firebase project ID")
    parser.add_argument("--database", default="(default)", help="Firestore database ID")
    parser.add_argument("--apply", action="store_true", help="write the changes (default: print only)")
    parser.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    parser.add_argument("--writer-version", type=int, help="deployed barrier-aware writer version (2)")
    parser.add_argument("--old-operations-drained", action="store_true", help="confirm old writer operations are drained")
    parser.add_argument("--resume-operation", help="resume only this reviewed held maintenance operation ID")
    args = parser.parse_args(argv)
    if args.resume_operation and not args.apply:
        print("--resume-operation requires --apply and matching --confirm-project.", file=sys.stderr)
        return 2

    if args.apply and args.confirm_project != args.project:
        print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
        return 2
    if args.apply and not os.environ.get(EMULATOR_ENV) and (
        args.writer_version != 2 or not args.old_operations_drained
    ):
        print("Production apply requires writer version 2 and drained old operations.", file=sys.stderr)
        return 2
    db = _client(args.project, args.database)
    plan = plan_migration(db)
    print_plan(plan)
    if not args.apply:
        print("Dry run: nothing was written.")
        return 0
    if plan["unknownRole"] or plan["profileMissing"] or plan["identityAnomalies"]:
        print("Fix the accounts with an unknown role first; nothing was written.", file=sys.stderr)
        return 3
    try:
        apply_migration(db, plan, resume_operation=args.resume_operation)
    except (CommandProblem, UsageMissing) as error:
        print(str(error), file=sys.stderr)
        return 3
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import argparse
import base64
import calendar
import json
import math
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Mapping

from google.api_core.datetime_helpers import DatetimeWithNanoseconds
from google.api_core.exceptions import GoogleAPICallError
from google.cloud import firestore
from google.cloud.firestore_v1 import DocumentReference, GeoPoint

from .migrate_seats import _client

SNAPSHOT_COLLECTIONS = ("user_access", "users", "config")
MOVE_CONFIG = ("config/usage", "config/plan", "config/lifecycle")
MOVE_FIELDS = frozenset({"seatClass", "seatHeld", "accessVersion", "uid", "status", "role", "branchId",
                         "employeeCode", "assignedSalesmanCodes", "disabledReasons", "userDocId"})
FORMAT = 1
DEFAULT_MAX_READS = 20000


class SnapshotProblem(Exception):
    pass


class ReadBudgetTooSmall(SnapshotProblem):
    pass


@dataclass(frozen=True)
class Snapshot:
    project: str
    database: str
    taken_at: str
    documents: Mapping[str, Mapping[str, Any]]


@dataclass(frozen=True)
class RestorePlan:
    unchanged: tuple[str, ...]
    restore: Mapping[str, Any]
    skipped: Mapping[str, tuple[str, ...]]
    not_in_snapshot: tuple[str, ...]
    remove_config: Mapping[str, Any]


def encode(value: Any) -> Any:
    if isinstance(value, datetime):
        seconds = calendar.timegm(value.astimezone(timezone.utc).utctimetuple())
        nanos = (value.nanosecond if isinstance(value, DatetimeWithNanoseconds) else 0) or value.microsecond * 1000
        return {"$timestamp": [seconds, nanos]}
    if isinstance(value, GeoPoint):
        return {"$geopoint": [value.latitude, value.longitude]}
    if isinstance(value, DocumentReference):
        return {"$ref": value.path}
    if isinstance(value, bytes):
        return {"$bytes": base64.b64encode(value).decode("ascii")}
    if isinstance(value, float) and not math.isfinite(value):
        return {"$float": "nan" if math.isnan(value) else "inf" if value > 0 else "-inf"}
    if isinstance(value, dict):
        return {"$map": {key: encode(item) for key, item in value.items()}}
    if isinstance(value, (list, tuple)):
        return [encode(item) for item in value]
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    raise SnapshotProblem(f"A value of type {type(value).__name__} cannot be saved.")


def decode(value: Any, db: Any) -> Any:
    if isinstance(value, list):
        return [decode(item, db) for item in value]
    if not isinstance(value, dict):
        return value
    if set(value) == {"$map"}:
        return {key: decode(item, db) for key, item in value["$map"].items()}
    if set(value) == {"$timestamp"}:
        seconds, nanos = value["$timestamp"]
        base = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=seconds)
        return DatetimeWithNanoseconds(base.year, base.month, base.day, base.hour, base.minute, base.second,
                                       tzinfo=timezone.utc, nanosecond=nanos)
    if set(value) == {"$geopoint"}:
        return GeoPoint(*value["$geopoint"])
    if set(value) == {"$ref"}:
        return db.document(value["$ref"])
    if set(value) == {"$bytes"}:
        return base64.b64decode(value["$bytes"])
    if set(value) == {"$float"}:
        return float(value["$float"])
    raise SnapshotProblem("The snapshot file has a value that is not known.")


def _paths(snapshot: Any) -> str:
    return snapshot.reference.path


def count_reads(db: Any) -> int:
    counts = [int(db.collection(name).count().get()[0][0].value) for name in SNAPSHOT_COLLECTIONS]
    return sum(counts) + sum(max(1, math.ceil(count / 1000)) for count in counts)


def save(db: Any, *, max_reads: int = DEFAULT_MAX_READS) -> Snapshot:
    estimated = count_reads(db)
    if estimated > max_reads:
        raise ReadBudgetTooSmall(f"A full copy needs about {estimated} reads. The limit is {max_reads}. Nothing was read.")
    documents: dict[str, Mapping[str, Any]] = {}
    for name in SNAPSHOT_COLLECTIONS:
        for snapshot in db.collection(name).stream():
            documents[_paths(snapshot)] = {"updateTime": encode(snapshot.update_time),
                                           "data": encode(snapshot.to_dict() or {})}
    return Snapshot(db.project, db._database, datetime.now(timezone.utc).isoformat(), documents)


def write_file(snapshot: Snapshot, path: Path) -> None:
    body = {"format": FORMAT, "project": snapshot.project, "database": snapshot.database,
            "takenAt": snapshot.taken_at, "documents": snapshot.documents}
    path.write_text(json.dumps(body, indent=1, sort_keys=True), encoding="utf-8")


def read_file(path: Path) -> Snapshot:
    try:
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SnapshotProblem(f"The snapshot file cannot be read: {error}") from None
    if not isinstance(body, dict) or body.get("format") != FORMAT:
        raise SnapshotProblem("The file is not a snapshot of this tool.")
    texts = all(isinstance(body.get(key), str) and body[key] for key in ("project", "database", "takenAt"))
    documents = body.get("documents")
    if not texts or not isinstance(documents, dict) or not all(_is_document(path, entry)
                                                                  for path, entry in documents.items()):
        raise SnapshotProblem("The snapshot file is damaged: a part is missing or has the wrong shape.")
    return Snapshot(body["project"], body["database"], body["takenAt"], documents)


def _is_document(path: Any, entry: Any) -> bool:
    return (isinstance(path, str) and isinstance(entry, dict) and isinstance(entry.get("data"), dict)
            and isinstance(entry["data"].get("$map"), dict))


_MISSING = {"$missing": True}


def _data_of(entry: Mapping[str, Any]) -> dict[str, Any]:
    return entry["data"]["$map"]


def _differs_outside_move(saved: Mapping[str, Any], live: Mapping[str, Any]) -> tuple[str, ...]:
    keys = (set(saved) | set(live)) - MOVE_FIELDS
    return tuple(sorted(key for key in keys if saved.get(key, _MISSING) != live.get(key, _MISSING)))


def plan_restore(db: Any, snapshot: Snapshot, *, remove_move_config: bool) -> RestorePlan:
    live: dict[str, Any] = {}
    for name in SNAPSHOT_COLLECTIONS:
        for stored in db.collection(name).stream():
            live[_paths(stored)] = stored
    unchanged: list[str] = []
    restore: dict[str, Any] = {}
    skipped: dict[str, tuple[str, ...]] = {}
    for path, entry in sorted(snapshot.documents.items()):
        current = live.get(path)
        if current is None:
            skipped[path] = ("deleted since the snapshot",)
            continue
        live_data = encode(current.to_dict() or {})["$map"]
        saved_data = _data_of(entry)
        if live_data == saved_data:
            unchanged.append(path)
            continue
        if path.startswith("config/"):
            skipped[path] = tuple(sorted(key for key in set(saved_data) | set(live_data)
                                         if saved_data.get(key, _MISSING) != live_data.get(key, _MISSING)))
            continue
        other = _differs_outside_move(saved_data, live_data)
        if other:
            skipped[path] = other
            continue
        restore[path] = (current.update_time, sorted(key for key in MOVE_FIELDS
                                                      if saved_data.get(key, _MISSING) != live_data.get(key, _MISSING)))
    extra = sorted(path for path in live if path not in snapshot.documents)
    remove = {path: live[path].update_time for path in extra if path in MOVE_CONFIG} if remove_move_config else {}
    kept = tuple(path for path in extra if path not in remove)
    return RestorePlan(tuple(unchanged), restore, skipped, kept, remove)


def apply_restore(db: Any, snapshot: Snapshot, plan: RestorePlan) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {"restored": [], "deleted": [], "changedDuringApply": []}

    @firestore.transactional
    def put_back(transaction: firestore.Transaction, path: str, guard: Any, fields: list[str]) -> bool:
        reference = db.document(path)
        current = reference.get(transaction=transaction)
        if not current.exists or current.update_time != guard:
            return False
        saved = decode(snapshot.documents[path]["data"], db)
        transaction.update(reference, {key: saved[key] if key in saved else firestore.DELETE_FIELD
                                       for key in fields})
        return True

    @firestore.transactional
    def remove(transaction: firestore.Transaction, path: str, guard: Any) -> bool:
        reference = db.document(path)
        current = reference.get(transaction=transaction)
        if not current.exists or current.update_time != guard:
            return False
        transaction.delete(reference)
        return True

    for path, (guard, fields) in plan.restore.items():
        (result["restored"] if put_back(db.transaction(), path, guard, fields)
         else result["changedDuringApply"]).append(path)
    for path, guard in plan.remove_config.items():
        (result["deleted"] if remove(db.transaction(), path, guard) else result["changedDuringApply"]).append(path)
    return result


def report(project: str, plan: RestorePlan, applied: Mapping[str, list[str]] | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "project": project,
        "mode": "apply" if applied is not None else "dry-run",
        "unchanged": list(plan.unchanged),
        "wouldRestore": sorted(plan.restore),
        "wouldDelete": sorted(plan.remove_config),
        "skippedChangedElsewhere": {path: list(fields) for path, fields in plan.skipped.items()},
        "keptNotInSnapshot": list(plan.not_in_snapshot),
    }
    if applied is not None:
        result["applied"] = dict(applied)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Save and restore the before-image of a company project.")
    sub = parser.add_subparsers(dest="command", required=True)
    saving = sub.add_parser("save", help="write every document of user_access, users and config to a file")
    restoring = sub.add_parser("restore", help="put the move's fields back (dry run unless --apply)")
    for command in (saving, restoring):
        command.add_argument("--project", required=True, help="company Firebase project ID")
        command.add_argument("--database", default="(default)", help="Firestore database ID")
    saving.add_argument("--out", required=True, help="snapshot file to write")
    saving.add_argument("--max-reads", type=int, default=DEFAULT_MAX_READS, help="most Firestore reads allowed")
    restoring.add_argument("--from", dest="source", required=True, help="snapshot file to read")
    restoring.add_argument("--apply", action="store_true", help="write the documents (default: print only)")
    restoring.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    restoring.add_argument("--remove-move-config", action="store_true",
                           help="delete config/usage, config/plan and config/lifecycle that the snapshot did not have")
    args = parser.parse_args(argv)
    try:
        if args.command == "save":
            db = _client(args.project, args.database)
            snapshot = save(db, max_reads=args.max_reads)
            write_file(snapshot, Path(args.out))
            print(json.dumps({"project": snapshot.project, "documents": len(snapshot.documents), "file": args.out},
                             indent=2, sort_keys=True))
            return 0
        if args.apply and args.confirm_project != args.project:
            print("--apply needs --confirm-project equal to --project.", file=sys.stderr)
            return 2
        snapshot = read_file(Path(args.source))
        if snapshot.project != args.project or snapshot.database != args.database:
            print("The snapshot belongs to another project or database. Nothing was changed.", file=sys.stderr)
            return 2
        db = _client(args.project, args.database)
        plan = plan_restore(db, snapshot, remove_move_config=args.remove_move_config)
        applied = apply_restore(db, snapshot, plan) if args.apply else None
        print(json.dumps(report(args.project, plan, applied), indent=2, sort_keys=True))
        skipped = bool(plan.skipped) or bool(applied and applied["changedDuringApply"])
        return 3 if skipped else 0
    except SnapshotProblem as error:
        print(str(error), file=sys.stderr)
        return 2 if isinstance(error, ReadBudgetTooSmall) else 1
    except (GoogleAPICallError, OSError, RuntimeError) as error:
        print(f"The project could not be read: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

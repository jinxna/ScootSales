from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from forecasting.ai_core import HUMAN_FIELDS

from scripts.ai_simulation.cli import _client, _encode, write_json
from scripts.ai_simulation.inputs import SimulationError

FORMAT = 1
COPY_KIND = "job-output-copy"
CHANGES_KIND = "job-changes"
DEFAULT_CAP = 20000
KUCHING = timedelta(hours=8)

AI_RUN_COLLECTIONS = (
    "ai_runs",
    "retailer_item_patterns",
    "ai_insights",
    "weekly_ai_summaries",
    "retailer_segments",
    "retailer_memory",
    "visit_briefs",
    "dashboard_notifications",
    "retailer_priority_rankings",
)
FORECAST_PUSH_COLLECTIONS = ("demand_forecasts", "forecast_training_runs", "forecast_imports")
JOB_COLLECTIONS = AI_RUN_COLLECTIONS + FORECAST_PUSH_COLLECTIONS
RUN_COLLECTION = "ai_runs"
STALE_COLLECTIONS = tuple(name for name in AI_RUN_COLLECTIONS if name != RUN_COLLECTION)
RUN_STAMP_FIELD = "sourceRunId"
RUN_STAMPS = {RUN_COLLECTION: "runId", **{name: RUN_STAMP_FIELD for name in STALE_COLLECTIONS}}
JOB = "job"
OTHER_WRITER = "otherWriter"
NOT_STAMPED = "notStamped"
OWNERS = (JOB, OTHER_WRITER, NOT_STAMPED)
PROVENANCE_STATEMENT = "Derived from simulated history. Not production evidence."
WEEK_FIELDS = ("weekStart", "lastObservedWeekStart", "periodStart", "asOf")
PERSON_FIELDS = frozenset(HUMAN_FIELDS - {"status"})
NEW_INSIGHT_STATUS = "new"


class Store(Protocol):
    def count(self, collection: str) -> int: ...

    def list(self, collection: str) -> Iterator[tuple[str, dict[str, Any], Any]]: ...


def _fields(data: Mapping[str, Any]) -> dict[str, Any]:
    return _encode(dict(data))["$map"]


class FirestoreStore:
    def __init__(self, db: Any):
        self.db = db

    def count(self, collection: str) -> int:
        return int(self.db.collection(collection).count().get()[0][0].value)

    def list(self, collection: str) -> Iterator[tuple[str, dict[str, Any], Any]]:
        for snapshot in self.db.collection(collection).stream():
            yield snapshot.id, _fields(snapshot.to_dict() or {}), _encode(snapshot.update_time)


def open_store(project: str) -> Store:
    return FirestoreStore(_client(project))


def fingerprint(data: Mapping[str, Any]) -> str:
    body = json.dumps(data, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def read_counts(store: Store, collections: tuple[str, ...], cap: int) -> dict[str, int]:
    counts = {name: store.count(name) for name in collections}
    total = sum(counts.values())
    if total > cap:
        raise SimulationError(
            f"The job-output collections hold {total} documents. The cap is {cap}. Nothing was read or written."
        )
    return counts


def read_documents(store: Store, collections: tuple[str, ...], cap: int) -> dict[str, dict[str, Any]]:
    read_counts(store, collections, cap)
    return {
        f"{name}/{doc_id}": {"data": data, "updateTime": update_time}
        for name in collections
        for doc_id, data, update_time in store.list(name)
    }


def take_copy(store: Store, project: str, out: Path, cap: int, now: datetime) -> dict[str, Any]:
    if out.exists():
        raise SimulationError(f"{out} exists. Use another file so the earlier copy is not lost.")
    documents = read_documents(store, JOB_COLLECTIONS, cap)
    body = {
        "format": FORMAT,
        "kind": COPY_KIND,
        "project": project,
        "takenAt": now.isoformat(),
        "documents": documents,
    }
    write_json(out, body)
    return {
        "project": project,
        "file": str(out),
        "documents": len(documents),
        "perCollection": {name: sum(1 for path in documents if path.startswith(name + "/")) for name in JOB_COLLECTIONS},
    }


def _empty_counts() -> dict[str, int]:
    return {"created": 0, "changed": 0, "unchanged": 0, "removed": 0}


def person_state(collection: str, data: Mapping[str, Any]) -> dict[str, Any]:
    state = {field: data.get(field) for field in sorted(PERSON_FIELDS) if _marked(data.get(field))}
    if collection == "ai_insights" and data.get("status") not in (None, "", NEW_INSIGHT_STATUS):
        state["status"] = data["status"]
    if collection == "dashboard_notifications":
        state.update({field: data[field] for field in ("read", "readAt") if _marked(data.get(field))})
    return state


def owner_of(path: str, old: Mapping[str, Any] | None, new: Mapping[str, Any] | None, job_run_id: str) -> str:
    collection = path.split("/", 1)[0]
    stamp = RUN_STAMPS.get(collection)
    if stamp is None:
        return NOT_STAMPED
    if new is None or new["data"].get(stamp) != job_run_id:
        return OTHER_WRITER
    before = person_state(collection, old["data"]) if old is not None else {}
    return JOB if person_state(collection, new["data"]) == before else OTHER_WRITER


def build_diff(
    before: Mapping[str, Any], store: Store, project: str, cap: int, now: datetime, job_run_id: str,
) -> dict[str, Any]:
    if before.get("kind") != COPY_KIND or before.get("format") != FORMAT:
        raise SimulationError("The file is not a copy made by this tool.")
    if before["project"] != project:
        raise SimulationError(f"The copy is of {before['project']}, not {project}.")
    if not isinstance(job_run_id, str) or not job_run_id.strip():
        raise SimulationError("Name the run id of the weekly job with --job-run-id.")
    after = read_documents(store, JOB_COLLECTIONS, cap)
    previous = before["documents"]
    rows: list[dict[str, Any]] = []
    for path in sorted(set(previous) | set(after)):
        old, new = previous.get(path), after.get(path)
        row: dict[str, Any] = {"path": path, "collection": path.split("/", 1)[0]}
        if old is None:
            row.update(status="created", afterSha=fingerprint(new["data"]), afterUpdateTime=new["updateTime"])
        elif new is None:
            row.update(
                status="removed", before=old["data"], beforeSha=fingerprint(old["data"]),
                beforeUpdateTime=old["updateTime"], afterUpdateTime=None,
            )
        elif fingerprint(old["data"]) == fingerprint(new["data"]):
            row.update(status="unchanged", afterSha=fingerprint(new["data"]), afterUpdateTime=new["updateTime"])
        else:
            row.update(
                status="changed", before=old["data"], beforeSha=fingerprint(old["data"]),
                beforeUpdateTime=old["updateTime"], afterSha=fingerprint(new["data"]),
                afterUpdateTime=new["updateTime"],
            )
        if row["status"] != "unchanged":
            row["owner"] = owner_of(path, old, new, job_run_id)
        rows.append(row)
    counts = {name: _empty_counts() for name in JOB_COLLECTIONS}
    for row in rows:
        counts[row["collection"]][row["status"]] += 1
    return {
        "format": FORMAT,
        "kind": CHANGES_KIND,
        "mode": "diff",
        "project": project,
        "jobRunId": job_run_id,
        "takenAt": before["takenAt"],
        "diffAt": now.isoformat(),
        "counts": counts,
        "owners": {owner: [row["path"] for row in rows if row.get("owner") == owner] for owner in OWNERS},
        "documents": rows,
    }


def _ids_by_collection(rows: list[Mapping[str, Any]], owner: str) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for row in rows:
        if row.get("owner") == owner:
            found.setdefault(row["collection"], []).append(row["path"].split("/", 1)[1])
    return {name: sorted(ids) for name, ids in sorted(found.items())}


def build_provenance(
    manifests: list[tuple[Path, Mapping[str, Any]]], diff: Mapping[str, Any], copy_file: Path, diff_file: Path,
) -> dict[str, Any]:
    if not manifests:
        raise SimulationError("Name each applied simulation manifest with --simulation-manifest.")
    for path, body in manifests:
        if body.get("kind") != "created" or body.get("mode") != "apply":
            raise SimulationError(f"{path} is not the manifest of an applied simulation write.")
        if body.get("project") != diff["project"]:
            raise SimulationError(f"{path} belongs to {body.get('project')}, not {diff['project']}.")
    for key in ("batchId", "seed", "firstCutoff"):
        values = {json.dumps(body.get(key)) for _, body in manifests}
        if len(values) != 1:
            raise SimulationError(f"The simulation manifests do not share one {key}: {sorted(values)}.")
    first = manifests[0][1]
    rows = diff["documents"]
    return {
        "statement": PROVENANCE_STATEMENT,
        "project": diff["project"],
        "simulationBatchId": first["batchId"],
        "seed": first["seed"],
        "firstCutoff": first["firstCutoff"],
        "cutoffs": sorted({body["cutoff"] for _, body in manifests}),
        "writeSets": [body.get("writeSet") for _, body in manifests],
        "sourceManifests": [str(path) for path, _ in manifests],
        "jobRunId": diff["jobRunId"],
        "copyFile": str(copy_file),
        "diffFile": str(diff_file),
        "takenAt": diff["takenAt"],
        "diffAt": diff["diffAt"],
        "affectedOutputs": _ids_by_collection(rows, JOB),
        "unstampedChanges": _ids_by_collection(rows, NOT_STAMPED),
        "changedByAnotherWriter": _ids_by_collection(rows, OTHER_WRITER),
    }


def _week_label(value: Any) -> str | None:
    if isinstance(value, dict) and "$timestamp" in value:
        moment = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=value["$timestamp"][0])
        return (moment + KUCHING).date().isoformat()
    if isinstance(value, str) and value:
        return value[:10]
    return None


def _empty(value: Any) -> bool:
    return value is None or value == "" or value == [] or value == {}


def _marked(value: Any) -> bool:
    return not _empty(value) and value is not False


def person_touched(collection: str, data: Mapping[str, Any]) -> bool:
    if any(not _empty(data.get(field)) for field in PERSON_FIELDS):
        return True
    if collection == "ai_insights":
        return data.get("status") not in (None, "", NEW_INSIGHT_STATUS)
    if collection == "dashboard_notifications":
        return data.get("read") is True or not _empty(data.get("readAt"))
    return False


def _moment(value: Any) -> tuple[int, int]:
    if isinstance(value, dict) and "$timestamp" in value:
        return tuple(value["$timestamp"])
    return (-1, 0)


def run_ages(store: Store) -> tuple[str, set[str], set[str]]:
    runs = [
        (_moment(data.get("startedAt")), doc_id, data.get("runId") or doc_id, data.get("status"))
        for doc_id, data, _ in store.list(RUN_COLLECTION)
    ]
    completed = [run for run in runs if run[3] == "completed"]
    if not completed:
        raise SimulationError("No completed run is in ai_runs. Nothing can be called stale.")
    newest = max(completed)
    newer = {run[2] for run in runs if run[:2] > newest[:2]}
    return newest[2], newer, {run[2] for run in runs}


def stale_report(store: Store, cap: int) -> dict[str, Any]:
    read_counts(store, (RUN_COLLECTION, *STALE_COLLECTIONS), cap)
    run_id, newer, known = run_ages(store)
    collections: dict[str, Any] = {}
    for name in STALE_COLLECTIONS:
        touched = unstamped = 0
        lists: dict[str, list[str]] = {key: [] for key in ("stale", "heldPersonField", "fromNewerUnfinishedRun", "fromUnknownRun")}
        weeks: set[str] = set()
        for doc_id, data, _ in store.list(name):
            stamp = data.get(RUN_STAMP_FIELD)
            path = f"{name}/{doc_id}"
            if stamp is None:
                unstamped += 1
                continue
            if stamp == run_id:
                touched += 1
                continue
            if stamp in newer:
                lists["fromNewerUnfinishedRun"].append(path)
                continue
            if stamp not in known:
                lists["fromUnknownRun"].append(path)
                continue
            lists["heldPersonField" if person_touched(name, data) else "stale"].append(path)
            weeks.update(label for field in WEEK_FIELDS if (label := _week_label(data.get(field))))
        collections[name] = {"touchedByNewestRun": touched, "unstamped": unstamped, **lists, "weeks": sorted(weeks)}
    return {"newestRunId": run_id, "newerUnfinishedRuns": sorted(newer), "collections": collections}


def _print(body: Mapping[str, Any]) -> None:
    print(json.dumps(body, indent=2, sort_keys=True, default=str))


def _read_json(path: Path) -> dict[str, Any]:
    try:
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SimulationError(f"{path} cannot be read: {error}") from None
    if not isinstance(body, dict):
        raise SimulationError(f"{path} does not hold one JSON object.")
    return body


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Copy and compare the documents the weekly AI job and the forecast push write, and report "
                    "output that the newest completed run did not touch. Every command only reads the database. "
                    "There is no undo of job outputs: undo the simulated orders, then let one weekly job run.")
    sub = parser.add_subparsers(dest="command", required=True)
    copying = sub.add_parser("copy", help="save every job-output document to a file; read only")
    copying.add_argument("--project", required=True)
    copying.add_argument("--out", required=True)
    copying.add_argument("--cap", type=int, default=DEFAULT_CAP)
    diffing = sub.add_parser("diff", help="after the job: mark each document created, changed, unchanged or removed, "
                                          "and by whom; write the provenance file")
    diffing.add_argument("--before", required=True)
    diffing.add_argument("--project", required=True)
    diffing.add_argument("--out", required=True)
    diffing.add_argument("--job-run-id", required=True, help="runId of the weekly job run in ai_runs")
    diffing.add_argument("--simulation-manifest", action="append", required=True,
                         help="applied manifest of the simulation write; repeat for each write set")
    diffing.add_argument("--provenance", required=True, help="provenance file to write")
    diffing.add_argument("--cap", type=int, default=DEFAULT_CAP)
    staling = sub.add_parser("stale", help="report output the newest completed run did not touch; read only")
    staling.add_argument("--project", required=True)
    staling.add_argument("--out")
    staling.add_argument("--cap", type=int, default=DEFAULT_CAP)
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    try:
        if args.command == "copy":
            _print(take_copy(open_store(args.project), args.project, Path(args.out), args.cap, now))
            return 0
        if args.command == "diff":
            out, provenance_path, copy_path = Path(args.out), Path(args.provenance), Path(args.before)
            for path in (out, provenance_path):
                if path.exists():
                    raise SimulationError(f"{path} exists. Use another file.")
            manifests = [(Path(path), _read_json(Path(path))) for path in args.simulation_manifest]
            before = _read_json(copy_path)
            manifest = build_diff(before, open_store(args.project), args.project, args.cap, now, args.job_run_id)
            provenance = build_provenance(manifests, manifest, copy_path, out)
            write_json(out, manifest)
            write_json(provenance_path, provenance)
            _print({"project": args.project, "file": args.out, "provenance": args.provenance,
                    "counts": manifest["counts"], "owners": {key: len(value) for key, value in manifest["owners"].items()}})
            return 0
        report = stale_report(open_store(args.project), args.cap)
        if args.out:
            write_json(Path(args.out), {"project": args.project, **report})
        _print({
            "project": args.project, "newestRunId": report["newestRunId"],
            "newerUnfinishedRuns": report["newerUnfinishedRuns"],
            "collections": {
                name: {key: (len(value) if isinstance(value, list) and key != "weeks" else value) for key, value in body.items()}
                for name, body in report["collections"].items()
            },
        })
        return 0
    except SimulationError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

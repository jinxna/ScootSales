from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import sys
import uuid
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from forecasting.ai_core.calendar import week_start

from scripts.ai_simulation.inputs import (
    EXPORT_COLLECTIONS,
    EXPORT_FORMAT,
    Company,
    SimulationError,
    assign_areas,
    canonical,
    load_export,
    load_roster,
    not_active_shops,
    people_by_uid,
    resolve_team,
    simulated_shops,
)
from scripts.ai_simulation.simulate import (
    APPROVAL_COLLECTIONS,
    ROUTE_COLLECTIONS,
    Settings,
    Simulation,
    publication_key_id,
    purchase_order_busiest_week,
    simulate,
)
from scripts.ai_simulation.staff_plan import shop_assignment_plan, staff_move_plan

MANIFEST_FORMAT = 1
JOURNAL_SUFFIX = ".journal"
WRITE_ID_FIELD = "simulationWriteId"
WRITE_SETS = {
    "orders": ("orders", *APPROVAL_COLLECTIONS),
    "routes": (*ROUTE_COLLECTIONS, "conversation_outcomes"),
}
ROUTE_GROUP_COLLECTIONS = frozenset(WRITE_SETS["routes"])
EXPORT_LIMIT = 5000
EMULATOR_ENV = "FIRESTORE_EMULATOR_HOST"
EMULATOR_PROJECT_PREFIX = "demo-"
CHECK_BY_HAND = "check_by_hand"
PAIRED_COLLECTIONS = ("orders", "purchase_orders")
DEFAULT_MAX_WRITES = 3000
FREE_DAILY_QUOTA = {"reads": 50000, "writes": 20000}
LIVE_ROUTE_STATUSES = ("approved", "published")
PHONE_ROUTE_LIMIT = 30
SCORECARD_WINDOW_DAYS = 56
SCORECARD_MIN_DECIDED = 3
KEPT_REAL_PLAN = "kept the real plan"
DRAFT_ROUTE_STATUSES = ("", "draft")
DATE_ONLY = re.compile(r"\d{4}-\d{2}-\d{2}")
PHONE_NOTE = (
    "The simulated plans are published plans of past weeks. The route screen and the home card offer only the "
    "current and coming weeks, so a past plan is not offered as today's route. The phone reads at most 30 published "
    "plans in id order, not newest first. When real plus simulated plans pass 30, a real current route can disappear "
    "from the phone. Undo the routes set before the earliest undoBy."
)
ORDER_LIMIT_NOTE = (
    "The order count is read once before the creates and once after them. The lock file stops a second write "
    "on the same journal only. A write from another journal, or a phone that submits orders during the write, "
    "can take the company over the limit. ordersAfter and overLimitBy show the result."
)


class Store(Protocol):
    def create(self, path: str, data: Mapping[str, Any]) -> Any | None: ...

    def read(self, path: str) -> tuple[Mapping[str, Any], Any] | None: ...

    def delete_group(self, expected: Mapping[str, Any | None]) -> bool: ...

    def order_count(self) -> int: ...

    def route_plans(self) -> list[tuple[str, Mapping[str, Any]]]: ...


class RouteReader(Protocol):
    def read(self, path: str) -> tuple[Mapping[str, Any], Any] | None: ...

    def route_plans(self) -> list[tuple[str, Mapping[str, Any]]]: ...


class ExportReader:
    def __init__(self, company: Company):
        self.documents = company.documents

    def read(self, path: str) -> tuple[Mapping[str, Any], Any] | None:
        found = self.documents.get(path)
        return (found, None) if found is not None else None

    def route_plans(self) -> list[tuple[str, Mapping[str, Any]]]:
        return [
            (path.split("/", 1)[1], data) for path, data in sorted(self.documents.items())
            if path.startswith("route_plans/")
        ]


class FirestoreStore:
    def __init__(self, db: Any):
        self.db = db

    def create(self, path: str, data: Mapping[str, Any]) -> Any | None:
        from google.api_core.exceptions import AlreadyExists

        try:
            return self.db.document(path).create(dict(data)).update_time
        except AlreadyExists:
            return None

    def read(self, path: str) -> tuple[Mapping[str, Any], Any] | None:
        snapshot = self.db.document(path).get()
        return (snapshot.to_dict() or {}, snapshot.update_time) if snapshot.exists else None

    def delete_group(self, expected: Mapping[str, Any | None]) -> bool:
        from google.cloud import firestore

        references = {path: self.db.document(path) for path in expected}

        @firestore.transactional
        def remove(transaction: Any) -> bool:
            for path, reference in references.items():
                current = reference.get(transaction=transaction)
                wanted = expected[path]
                if current.exists != (wanted is not None) or (current.exists and current.update_time != wanted):
                    return False
            for path, reference in references.items():
                if expected[path] is not None:
                    transaction.delete(reference, option=self.db.write_option(last_update_time=expected[path]))
            return True

        return remove(self.db.transaction())

    def order_count(self) -> int:
        return int(self.db.collection("orders").count().get()[0][0].value)

    def route_plans(self) -> list[tuple[str, Mapping[str, Any]]]:
        rows = [
            (snapshot.id, snapshot.to_dict() or {})
            for snapshot in self.db.collection("route_plans").limit(EXPORT_LIMIT + 1).stream()
        ]
        if len(rows) > EXPORT_LIMIT:
            raise SimulationError(f"route_plans holds more than {EXPORT_LIMIT} documents. Nothing was written.")
        return rows


def _encode(value: Any) -> Any:
    from platform_service.tenant_snapshot import encode

    return encode(value)


def fingerprint(data: Mapping[str, Any]) -> str:
    content = {key: value for key, value in data.items() if key != WRITE_ID_FIELD}
    body = json.dumps(_encode(content), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def order_group(path: str) -> str | None:
    collection, doc_id = path.split("/", 1)
    if collection in PAIRED_COLLECTIONS:
        return doc_id
    return None


def group_paths(path: str) -> tuple[str, ...]:
    group = order_group(path)
    if group is None:
        return (path,)
    return tuple(f"{collection}/{group}" for collection in PAIRED_COLLECTIONS)


def document_group(path: str, data: Mapping[str, Any]) -> str | None:
    if path.split("/", 1)[0] in ROUTE_GROUP_COLLECTIONS:
        return str(data["planId"])
    return order_group(path)


def unit_of(row: Mapping[str, Any]) -> str:
    return row.get("group") or order_group(row["path"]) or row["path"]


def _held_groups(reasons: Mapping[str, list[dict[str, str]]]) -> list[dict[str, Any]]:
    return [
        {"group": unit, "members": members}
        for unit, members in sorted(reasons.items())
        if "/" not in unit
    ]


def planned_documents(
    simulation: Simulation, write_set: str, *, skipped_groups: frozenset[str] = frozenset(),
) -> dict[str, Mapping[str, Any]]:
    names = WRITE_SETS[write_set]
    rows = [
        (f"{collection}/{doc_id}", data)
        for collection in names
        for doc_id, data in sorted(simulation.documents[collection].items())
        if document_group(f"{collection}/{doc_id}", data) not in skipped_groups
    ]
    rows.sort(key=lambda row: (document_group(*row) or "", names.index(row[0].split("/", 1)[0])))
    return dict(rows)


def plan_week(plan_id: str, value: Any) -> date:
    if isinstance(value, date):
        return week_start(value)
    written = value.strip() if isinstance(value, str) else ""
    try:
        if DATE_ONLY.fullmatch(written):
            return week_start(date.fromisoformat(written))
        moment = datetime.fromisoformat(written.replace("Z", "+00:00"))
        if moment.tzinfo is None:
            raise ValueError("a time with no zone")
        return week_start(moment)
    except ValueError as error:
        raise SimulationError(
            f"The real plan {plan_id} has a weekStart the tool cannot read ({value!r}), so its week cannot be "
            "checked against the simulated weeks. Nothing was written."
        ) from error


def route_clashes(simulation: Simulation, reader: RouteReader, now: datetime) -> dict[str, Any]:
    plans = simulation.documents["route_plans"]
    simulated = {(plan["salesmanUid"], week_start(plan["weekStart"])): plan_id for plan_id, plan in plans.items()}
    kept: list[dict[str, Any]] = []
    drafts: list[str] = []
    stored = reader.route_plans()
    reads = max(1, len(stored))
    every = [(plan_id, data) for plan_id, data in stored if not data.get("simulationBatchId")]
    phone: dict[str, dict[str, int]] = {}
    for person in simulation.team.salespeople:
        real = {
            plan_id: data for plan_id, data in every
            if data.get("salesmanUid") == person.uid or canonical(data.get("salesmanCode")) == canonical(person.code)
        }
        own = sum(1 for week_uid in simulated if week_uid[0] == person.uid)
        published = sum(1 for data in real.values() if canonical(data.get("status")) == "published")
        phone[person.code] = {"realPublishedPlans": published, "simulatedPlans": own}
        for plan_id, data in sorted(real.items()):
            week = plan_week(plan_id, data.get("weekStart"))
            simulated_id = simulated.get((person.uid, week))
            if simulated_id is None:
                continue
            status = canonical(data.get("status"))
            live = status in LIVE_ROUTE_STATUSES
            if not live:
                reads += 1
                live = reader.read(f"route_plan_progress/{plan_id}_{person.uid}") is not None
            if live:
                kept.append({
                    "salesmanUid": person.uid, "weekStart": week.isoformat(), "realPlanId": plan_id,
                    "simulatedPlanId": simulated_id, "why": KEPT_REAL_PLAN,
                })
            else:
                label = "draft" if status in DRAFT_ROUTE_STATUSES else f"{status} plan"
                drafts.append(f"real {label} in a simulated week: {plan_id}, {week.isoformat()}")
    taken = {row["simulatedPlanId"] for row in kept}
    for (uid, week), plan_id in sorted(simulated.items()):
        if plan_id in taken:
            continue
        key_id = publication_key_id(uid, week)
        reads += 1
        key = reader.read(f"route_plan_publication_keys/{key_id}")
        if key is not None and key[0].get("simulationBatchId") != simulation.settings.batch:
            kept.append({
                "salesmanUid": uid, "weekStart": week.isoformat(), "realKeyId": key_id,
                "simulatedPlanId": plan_id, "why": KEPT_REAL_PLAN,
            })
    kept_simulated = Counter(uid for uid, _ in {(row["salesmanUid"], row["simulatedPlanId"]) for row in kept})
    this_week = week_start(now)
    for person in simulation.team.salespeople:
        counts = phone[person.code]
        written = counts["simulatedPlans"] - kept_simulated[person.uid]
        counts["phoneHeadroom"] = PHONE_ROUTE_LIMIT - (counts["realPublishedPlans"] + written)
        counts["undoBy"] = (this_week + timedelta(weeks=max(counts["phoneHeadroom"], 0))).isoformat()
    over = sorted(
        code for code, counts in phone.items()
        if counts["realPublishedPlans"] + counts["simulatedPlans"] > PHONE_ROUTE_LIMIT
    )
    if over:
        raise SimulationError(
            f"The phones of {', '.join(over)} would hold more than {PHONE_ROUTE_LIMIT} published plans, so the "
            "current plan could drop out of the phone's list. Nothing was written."
        )
    return {"kept": kept, "drafts": drafts, "reads": reads, "phone": phone}


def scorecard_preview(
    planned: Mapping[str, Mapping[str, Any]], simulation: Simulation, now: datetime,
) -> list[dict[str, Any]]:
    start = now - timedelta(days=SCORECARD_WINDOW_DAYS)
    progress = [
        data for path, data in planned.items()
        if path.startswith("route_plan_progress/") and start <= data["updatedAt"] <= now
    ]
    stops: dict[str, list[Mapping[str, Any]]] = {}
    for path, data in planned.items():
        if path.startswith("route_stop_progress/") and start <= data["arrivedAt"] <= now:
            stops.setdefault(data["planId"], []).append(data)
    rows = []
    for person in simulation.team.salespeople:
        statuses = Counter(
            str(stop.get("status", "")).strip().lower()
            for doc in progress
            if doc.get("salesmanUid") == person.uid or str(doc.get("salesmanCode", "")).lower() == person.code.lower()
            for stop in stops.get(doc["planId"], [])
            if stop.get("stopId") and stop.get("retailerId")
        )
        decided = statuses["completed"] + statuses["skipped"]
        rows.append({
            "salesmanCode": person.code,
            "decidedVisits": decided,
            "completed": statuses["completed"],
            "skipped": statuses["skipped"],
            "completionRate": round(statuses["completed"] / decided, 3) if decided >= SCORECARD_MIN_DECIDED else None,
            "asOf": now.isoformat(),
        })
    return rows


def write_cost(planned_count: int, reads_before: int, max_writes: int) -> dict[str, Any]:
    return {
        "documents": planned_count,
        "writes": planned_count,
        "readsAtApply": reads_before + planned_count,
        "undoReads": 2 * planned_count,
        "undoDeletes": planned_count,
        "maxWrites": max_writes,
        "freeDailyQuota": dict(FREE_DAILY_QUOTA),
    }


def route_summary(
    clash: Mapping[str, Any], planned: Mapping[str, Mapping[str, Any]], simulation: Simulation, now: datetime,
) -> dict[str, Any]:
    return {
        "keptRealPlans": clash["kept"],
        "realDraftsInSimulatedWeeks": clash["drafts"],
        "scorecardPreview": scorecard_preview(planned, simulation, now),
        "phone": {"note": PHONE_NOTE, "plansPerSalesperson": clash["phone"]},
    }


def check_max_writes(planned_count: int, max_writes: int) -> None:
    if planned_count > max_writes:
        raise SimulationError(
            f"The set would write {planned_count} documents, above --max-writes {max_writes}. Nothing was written."
        )


def build_manifest(
    simulation: Simulation, write_set: str, project: str, existing: Mapping[str, str], *,
    skipped_groups: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    documents = []
    for path, data in planned_documents(simulation, write_set, skipped_groups=skipped_groups).items():
        mark = fingerprint(data)
        found = existing.get(path)
        status = "create" if found is None else "exists_same" if found == mark else "exists_different"
        documents.append({"path": path, "sha256": mark, "status": status, "group": document_group(path, data)})
    settings = simulation.settings
    return {
        "format": MANIFEST_FORMAT,
        "kind": "created",
        "writeSet": write_set,
        "project": project,
        "batchId": settings.batch,
        "mode": "dry-run",
        "dataLabel": "simulated",
        "seed": settings.seed,
        "firstCutoff": settings.first_cutoff.isoformat(),
        "cutoff": settings.cutoff.isoformat(),
        "counts": {
            status: sum(1 for row in documents if row["status"] == status)
            for status in ("create", "exists_same", "exists_different")
        },
        "story": {
            "stoppedShops": [list(pair) for pair in simulation.story.stops],
            "recoveredShop": list(simulation.story.recovered),
        },
        "checks": simulation.checks,
        "documents": documents,
    }


def export_existing(company: Company, simulation: Simulation, write_set: str) -> dict[str, str]:
    return {
        path: fingerprint(company.documents[path])
        for path in planned_documents(simulation, write_set)
        if path in company.documents
    }


def journal_path(manifest: Path) -> Path:
    return manifest.with_name(manifest.name + JOURNAL_SUFFIX)


def _append(handle: Any, row: Mapping[str, Any]) -> None:
    handle.write(json.dumps(row, sort_keys=True) + "\n")
    handle.flush()
    os.fsync(handle.fileno())


def read_journal(path: Path) -> tuple[dict[str, Any] | None, dict[str, dict[str, Any]], list[str]]:
    lines = path.read_text(encoding="utf-8").split("\n")
    good: list[str] = []
    rows: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            if any(rest.strip() for rest in lines[index + 1:]):
                raise SimulationError(f"The journal {path} is damaged at line {index + 1}. Nothing was changed.")
            break
        good.append(line)
    header = rows[0] if rows and rows[0].get("t") == "header" else None
    if rows and header is None:
        raise SimulationError(f"The journal {path} does not start with a header. Nothing was changed.")
    state: dict[str, dict[str, Any]] = {}
    for row in rows[1:]:
        kind, doc = row.get("t"), row.get("path")
        if kind == "intent":
            state[doc] = {"status": "pending", "sha256": row["sha256"], **({"group": row["group"]} if row.get("group") else {})}
        elif kind == "done":
            state[doc] = {**state.get(doc, {"sha256": row.get("sha256", "")}), "status": "written", "updateTime": row["updateTime"]}
        elif kind == "skipped":
            state[doc] = {**state.get(doc, {"sha256": ""}), "status": "skipped"}
        elif kind == "unproven":
            state[doc] = {**state.get(doc, {"sha256": ""}), "status": CHECK_BY_HAND, **({"why": row["why"]} if "why" in row else {})}
        elif kind == "gone":
            state[doc] = {**state.get(doc, {"sha256": ""}), "status": "deleted"}
        elif kind == "absent":
            state.pop(doc, None)
        else:
            raise SimulationError(f"The journal {path} holds an unknown line type: {kind}.")
    return header, state, good


def manifest_from_journal(path: Path) -> dict[str, Any]:
    header, state, _ = read_journal(path)
    if header is None:
        raise SimulationError(f"The journal {path} is empty. No document was created from it.")
    documents = [
        {"path": doc, "sha256": entry.get("sha256", ""), "status": entry["status"],
         **({"group": entry["group"]} if entry.get("group") else {}),
         **({"updateTime": entry["updateTime"]} if entry["status"] == "written" else {})}
        for doc, entry in sorted(state.items())
        if entry["status"] != "skipped"
    ]
    return {
        **{key: header[key] for key in ("format", "kind", "writeSet", "project", "batchId", "dataLabel", "seed", "firstCutoff", "cutoff")},
        **({"runId": header["runId"]} if _is_run_id(header.get("runId")) else {}),
        "mode": "apply",
        "counts": {
            status: sum(1 for row in documents if row["status"] == status)
            for status in ("written", "pending", CHECK_BY_HAND)
        },
        "documents": documents,
    }


@contextlib.contextmanager
def _exclusive(journal: Path) -> Iterator[None]:
    lock = journal.with_name(journal.name + ".lock")
    journal.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        raise SimulationError(
            f"Another write holds {lock}. If no write is running, delete that lock file and run again."
        ) from None
    try:
        os.write(descriptor, str(os.getpid()).encode("ascii"))
        yield
    finally:
        os.close(descriptor)
        lock.unlink()


def _is_run_id(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def _header(simulation: Simulation, write_set: str, project: str) -> dict[str, Any]:
    settings = simulation.settings
    return {
        "t": "header", "runId": uuid.uuid4().hex, "format": MANIFEST_FORMAT, "kind": "created", "writeSet": write_set, "project": project,
        "batchId": settings.batch, "dataLabel": "simulated", "seed": settings.seed,
        "firstCutoff": settings.first_cutoff.isoformat(), "cutoff": settings.cutoff.isoformat(),
    }


def _check_resume(header: Mapping[str, Any], wanted: Mapping[str, Any], path: Path) -> None:
    if not _is_run_id(header.get("runId")):
        raise SimulationError(
            f"The journal {path} has no run id, so it cannot prove which documents it created. "
            "Nothing was written. Use a new --manifest path."
        )
    for key in ("format", "kind", "writeSet", "project", "batchId", "seed", "firstCutoff"):
        if header.get(key) != wanted[key]:
            raise SimulationError(
                f"The journal {path} belongs to another run: {key} is {header.get(key)!r}, this run has {wanted[key]!r}. "
                "Nothing was written."
            )


UNPROVEN_REASON = "carries this run id, but no commit of it is in the journal: check it by hand"
REPLACED_REASON = "created by this run, but written again since its journaled commit: check it by hand"


def _resolve_pending(store: Store, journal: Any, state: dict[str, dict[str, Any]], run_id: str) -> None:
    for doc, entry in sorted(state.items()):
        if entry["status"] != "pending":
            continue
        found = store.read(doc)
        if found is None:
            _append(journal, {"t": "absent", "path": doc})
            del state[doc]
        elif found[0].get(WRITE_ID_FIELD) == run_id:
            _append(journal, {"t": "unproven", "path": doc})
            state[doc] = {**entry, "status": CHECK_BY_HAND}
        else:
            _append(journal, {"t": "skipped", "path": doc})
            state[doc] = {**entry, "status": "skipped"}


def apply_manifest(
    store: Store, simulation: Simulation, write_set: str, project: str, *,
    now: datetime, order_limit: int, journal: Path, max_writes: int = DEFAULT_MAX_WRITES,
) -> dict[str, Any]:
    clash = route_clashes(simulation, store, now) if write_set == "routes" else None
    skipped = frozenset(row["simulatedPlanId"] for row in clash["kept"]) if clash else frozenset()
    planned = planned_documents(simulation, write_set, skipped_groups=skipped)
    check_max_writes(len(planned), max_writes)
    late = [
        path for path, data in planned.items()
        if any(isinstance(value, datetime) and value > now for value in data.values())
    ]
    if late:
        raise SimulationError(f"{len(late)} records are dated after now. Nothing was written. First: {late[0]}")
    wanted = _header(simulation, write_set, project)
    with _exclusive(journal):
        state: dict[str, dict[str, Any]] = {}
        resumed = False
        run_id = wanted["runId"]
        if journal.exists():
            header, state, good = read_journal(journal)
            if header is None:
                journal.unlink()
            else:
                _check_resume(header, wanted, journal)
                resumed = True
                run_id = header["runId"]
                temporary = journal.with_name(journal.name + ".tmp")
                temporary.write_text("".join(line + "\n" for line in good), encoding="utf-8")
                os.replace(temporary, journal)
        with journal.open("a", encoding="utf-8") as handle:
            if resumed:
                _resolve_pending(store, handle, state, run_id)
            manifest = build_manifest(simulation, write_set, project, {}, skipped_groups=skipped)
            manifest["mode"] = "apply"
            manifest["runId"] = run_id
            listed = {row["path"] for row in manifest["documents"]}
            manifest["documents"].extend(
                {"path": doc, "sha256": entry.get("sha256", ""), "status": "create", "group": entry.get("group")}
                for doc, entry in sorted(state.items())
                if entry["status"] in ("written", "deleted", CHECK_BY_HAND) and doc not in listed
            )
            reasons: dict[str, list[dict[str, str]]] = {}
            for row in manifest["documents"]:
                doc = row["path"]
                entry = state.get(doc)
                found = store.read(doc)
                if found is None:
                    if entry is None or entry["status"] not in ("written", "deleted"):
                        continue
                    row["status"] = "deleted"
                    if entry["status"] == "written":
                        _append(handle, {"t": "gone", "path": doc})
                        state[doc] = {**entry, "status": "deleted"}
                    why = "created by this run and deleted since"
                elif found[0].get(WRITE_ID_FIELD) != run_id:
                    same = fingerprint(found[0]) == row["sha256"]
                    row["status"] = "exists_same" if same else "exists_different"
                    if entry is not None and entry["status"] == "written":
                        _append(handle, {"t": "skipped", "path": doc})
                        state[doc] = {**entry, "status": "skipped"}
                    why = "not owned by this run, same content" if same else "not owned by this run, other content"
                elif entry is not None and entry["status"] == "written":
                    if _encode(found[1]) == entry["updateTime"]:
                        row["status"] = "written"
                        row["updateTime"] = entry["updateTime"]
                        continue
                    _append(handle, {"t": "unproven", "path": doc, "why": REPLACED_REASON})
                    state[doc] = {**entry, "status": CHECK_BY_HAND, "why": REPLACED_REASON}
                    row["status"] = CHECK_BY_HAND
                    why = REPLACED_REASON
                else:
                    row["status"] = CHECK_BY_HAND
                    why = entry.get("why", UNPROVEN_REASON) if entry is not None else UNPROVEN_REASON
                reasons.setdefault(unit_of(row), []).append({"path": doc, "state": why})
            orders_before = 0
            if write_set == "orders":
                creates = sum(
                    1 for row in manifest["documents"]
                    if row["status"] == "create" and row["path"].startswith("orders/")
                    and order_group(row["path"]) not in reasons
                )
                orders_before = store.order_count()
                total = orders_before + creates
                if total > order_limit:
                    raise SimulationError(
                        f"The company would hold {total} orders. The limit is {order_limit}. Nothing was written."
                    )
            if not resumed:
                _append(handle, wanted)
            for row in manifest["documents"]:
                if row["status"] != "create":
                    continue
                unit = unit_of(row)
                if unit in reasons:
                    row["status"] = "held_back"
                    continue
                _append(handle, {"t": "intent", "path": row["path"], "sha256": row["sha256"],
                                 **({"group": row["group"]} if row.get("group") else {})})
                update_time = store.create(row["path"], {**planned[row["path"]], WRITE_ID_FIELD: run_id})
                if update_time is None:
                    found = store.read(row["path"])
                    if found is not None and found[0].get(WRITE_ID_FIELD) == run_id:
                        _append(handle, {"t": "unproven", "path": row["path"]})
                        row["status"] = CHECK_BY_HAND
                        reasons.setdefault(unit, []).append({"path": row["path"], "state": UNPROVEN_REASON})
                        continue
                    _append(handle, {"t": "skipped", "path": row["path"]})
                    same = found is not None and fingerprint(found[0]) == row["sha256"]
                    row["status"] = "exists_same" if same else "exists_different"
                    reasons.setdefault(unit, []).append({
                        "path": row["path"],
                        "state": "taken by another writer during this write, " + ("same content" if same else "other content"),
                    })
                    continue
                row["updateTime"] = _encode(update_time)
                _append(handle, {"t": "done", "path": row["path"], "updateTime": row["updateTime"]})
                row["status"] = "written"
            manifest["heldGroups"] = _held_groups(reasons)
            if write_set == "orders":
                orders_after = store.order_count()
                manifest["orderLimit"] = {
                    "limit": order_limit,
                    "ordersBefore": orders_before,
                    "ordersAfter": orders_after,
                    "overLimitBy": max(0, orders_after - order_limit),
                    "note": ORDER_LIMIT_NOTE,
                }
    if clash is not None:
        manifest.update(route_summary(clash, planned, simulation, now))
    manifest["cost"] = write_cost(len(planned), clash["reads"] if clash else 0, max_writes)
    manifest["counts"] = {
        status: sum(1 for row in manifest["documents"] if row["status"] == status)
        for status in ("written", "exists_same", "exists_different")
    }
    for status in ("deleted", "held_back", CHECK_BY_HAND):
        found = sum(1 for row in manifest["documents"] if row["status"] == status)
        if found:
            manifest["counts"][status] = found
    return manifest


UNDO_KEPT_BACK = ("skippedChanged", "existsNotOwned", "keptWithChangedPartner", "changedDuringUndo", "checkByHand")


def undo_manifest(store: Store | None, manifest: Mapping[str, Any]) -> dict[str, Any]:
    from platform_service.tenant_snapshot import decode

    written = [row for row in manifest["documents"] if row["status"] == "written"]
    unproven = [row for row in manifest["documents"] if row["status"] in ("pending", CHECK_BY_HAND)]
    run_id = manifest.get("runId")
    if (written or unproven) and not _is_run_id(run_id):
        raise SimulationError(
            "This manifest has no run id, so it cannot prove which documents it created. Nothing was deleted."
        )
    report: dict[str, Any] = {
        "project": manifest["project"],
        "batchId": manifest["batchId"],
        "writeSet": manifest["writeSet"],
        "mode": "dry-run" if store is None else "apply",
        "wouldDelete": [row["path"] for row in written],
        "checkByHand": [row["path"] for row in unproven],
        "notWrittenByThisManifest": sum(
            1 for row in manifest["documents"] if row["status"] not in ("written", "pending", CHECK_BY_HAND)
        ),
    }
    if store is None:
        return report
    rows = {row["path"]: row for row in written}
    members_of: dict[str, list[str]] = {}
    for row in manifest["documents"]:
        if row.get("group"):
            members_of.setdefault(row["group"], []).append(row["path"])
    units: dict[str, tuple[str, ...]] = {}
    for path, row in rows.items():
        unit = unit_of(row)
        units.setdefault(unit, tuple(members_of[unit]) if row.get("group") else group_paths(path))
    deleted: list[str] = []
    skipped: list[str] = []
    already_gone: list[str] = []
    not_owned: list[str] = []
    kept: list[str] = []
    raced: list[str] = []
    reasons: dict[str, list[dict[str, str]]] = {}
    for unit, members in units.items():
        expected: dict[str, Any | None] = {}
        for path in members:
            found = store.read(path)
            row = rows.get(path)
            if found is None:
                expected[path] = None
                if row is not None and row["status"] == "written":
                    already_gone.append(path)
            elif found[0].get(WRITE_ID_FIELD) != run_id:
                not_owned.append(path)
                reasons.setdefault(unit, []).append({"path": path, "state": "not owned by this run"})
            elif row is not None and found[1] == decode(row["updateTime"], None):
                expected[path] = found[1]
            else:
                skipped.append(path)
                state = "created by this run and changed since" if row is not None else "carries this run id, not recorded as written"
                reasons.setdefault(unit, []).append({"path": path, "state": state})
        mine = [path for path, update_time in expected.items() if update_time is not None]
        if unit in reasons:
            kept.extend(mine)
        elif mine and store.delete_group(expected):
            deleted.extend(mine)
        elif mine:
            raced.extend(mine)
            reasons[unit] = [{"path": path, "state": "the group changed while undo ran"} for path in mine]
    report["deleted"] = deleted
    report["skippedChanged"] = skipped
    report["alreadyGone"] = already_gone
    report["existsNotOwned"] = not_owned
    report["keptWithChangedPartner"] = sorted(kept)
    report["changedDuringUndo"] = sorted(raced)
    report["heldGroups"] = _held_groups(reasons)
    return report


def write_json(path: Path, body: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(body, indent=1, sort_keys=True, default=str), encoding="utf-8")
    os.replace(temporary, path)


def _manifest_mode(manifest_path: Path) -> Any:
    body = json.loads(manifest_path.read_text(encoding="utf-8"))
    return body.get("mode") if isinstance(body, dict) else None


def refuse_overwrite(manifest_path: Path, *, applying: bool) -> None:
    journal = journal_path(manifest_path)
    if journal.exists() and journal.stat().st_size > 0 and not applying:
        raise SimulationError(f"{journal} holds the record of an earlier write. Use another manifest path, or run with --apply to resume it.")
    if applying or not manifest_path.exists():
        if applying and manifest_path.exists() and not (journal.exists() and journal.stat().st_size > 0):
            if _manifest_mode(manifest_path) == "dry-run":
                raise SimulationError(
                    f"{manifest_path}: This file is a dry-run plan. Use a new --manifest path for --apply, or delete it."
                )
            raise SimulationError(f"{manifest_path} exists without its journal. Use another manifest path.")
        return
    if _manifest_mode(manifest_path) == "apply":
        raise SimulationError(f"{manifest_path} is the manifest of an applied write. Use another manifest path.")


def _client(project: str) -> Any:
    from platform_service.migrate_seats import _client as open_client

    from scripts.fill_order_owners import is_control_centre

    on_emulator = bool(os.environ.get(EMULATOR_ENV))
    if on_emulator != project.startswith(EMULATOR_PROJECT_PREFIX):
        raise SimulationError(
            f"{EMULATOR_ENV} is set and the project {project} does not begin with {EMULATOR_PROJECT_PREFIX}: "
            "the command would reach the emulator, not the project. Nothing was read or written."
            if on_emulator else
            f"The project {project} is an emulator project, but {EMULATOR_ENV} is not set. Nothing was read or written."
        )
    db = open_client(project, "(default)")
    if db.project != project:
        raise SimulationError("The opened project is not the named project.")
    if is_control_centre(db):
        raise SimulationError("This is the Control Centre project. Use one company's project.")
    return db


def export_company(db: Any, path: Path) -> dict[str, int]:
    collections: dict[str, dict[str, Any]] = {}
    for name in EXPORT_COLLECTIONS:
        documents = {
            snapshot.id: _encode(snapshot.to_dict() or {})
            for snapshot in db.collection(name).limit(EXPORT_LIMIT + 1).stream()
        }
        if len(documents) > EXPORT_LIMIT:
            raise SimulationError(f"{name} holds more than {EXPORT_LIMIT} documents. Nothing was saved.")
        collections[name] = documents
    write_json(path, {
        "format": EXPORT_FORMAT,
        "project": db.project,
        "takenAt": datetime.now(timezone.utc).isoformat(),
        "collections": collections,
    })
    return {name: len(documents) for name, documents in collections.items()}


def _monday(value: str) -> date:
    return date.fromisoformat(value)


def _settings(args: argparse.Namespace, now: datetime) -> Settings:
    first = args.first_cutoff or week_start(now)
    return Settings(first_cutoff=first, cutoff=args.cutoff or first, seed=args.seed)


def _simulation(args: argparse.Namespace, now: datetime) -> tuple[Company, Simulation]:
    company = load_export(Path(args.export))
    team = resolve_team(company, load_roster(Path(args.roster)))
    return company, simulate(company, team, _settings(args, now), now=now)


def _not_active_shops(simulation: Simulation) -> list[dict[str, Any]]:
    orders = Counter(order["retailerId"] for order in simulation.documents["orders"].values())
    shops = [plan.row for plan in simulation.shops.values()]
    owners = {key: plan.person for key, plan in simulation.shops.items()}
    return [{**row, "orders": orders[row["shopId"]]} for row in not_active_shops(shops, owners)]


def _named(rows: list[dict[str, Any]], company: Company) -> list[dict[str, Any]]:
    people = people_by_uid(company)
    return [
        {**row, **{
            key.replace("Uid", "Name"): people[row[key]].name
            for key in ("salespersonUid", "toSupervisorUid", "salesmanUid")
            if isinstance(row.get(key), str) and row[key] in people
        }}
        for row in rows
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Simulated history for one company: orders, past visits and no-sale reasons, made from an "
                    "export file of its real shops, products and staff. Every command is a dry run unless it "
                    "gets --apply with --confirm-project. Simulated data is never a real client result.")
    sub = parser.add_subparsers(dest="command", required=True)
    exporting = sub.add_parser("export", help="read one company's shops, products, staff and orders into a file")
    exporting.add_argument("--project", required=True, help="the company's Firebase project ID")
    exporting.add_argument("--out", required=True, help="export file to write (keep it outside git)")
    structure = sub.add_parser("structure", help="print the staff moves and the shop assignments; writes nothing")
    writing = sub.add_parser("write", help="plan one write set and save its manifest; writes only with --apply")
    for command in (structure, writing):
        command.add_argument("--export", required=True, help="export file made by the export command")
        command.add_argument("--roster", required=True, help="roster file with the staff of the story (outside git)")
    structure.add_argument("--out", help="file for the plan; it holds ids and codes, no names")
    writing.add_argument("--set", dest="write_set", required=True, choices=sorted(WRITE_SETS))
    writing.add_argument("--manifest", required=True, help="manifest file to write")
    writing.add_argument("--seed", type=int, default=7)
    writing.add_argument("--first-cutoff", type=_monday, help="first Monday of the story (default: this week)")
    writing.add_argument("--cutoff", type=_monday, help="Monday to generate up to (a later one adds one week)")
    writing.add_argument("--apply", action="store_true", help="create the documents (default: dry run)")
    writing.add_argument("--confirm-project", help="repeat the export's project ID to confirm --apply")
    writing.add_argument("--max-writes", type=int, default=DEFAULT_MAX_WRITES,
                         help=f"refuse a set that would write more documents (default {DEFAULT_MAX_WRITES})")
    undoing = sub.add_parser("undo", help="delete what one manifest wrote; writes only with --apply")
    undoing.add_argument("--manifest", required=True, help="manifest file of an applied write")
    undoing.add_argument("--apply", action="store_true", help="delete the documents (default: dry run)")
    undoing.add_argument("--confirm-project", help="repeat the manifest's project ID to confirm --apply")
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    try:
        if args.command == "export":
            counts = export_company(_client(args.project), Path(args.out))
            print(json.dumps({"project": args.project, "file": args.out, "documents": counts}, indent=2, sort_keys=True))
            return 0
        if args.command == "structure":
            company = load_export(Path(args.export))
            team = resolve_team(company, load_roster(Path(args.roster)))
            shops = simulated_shops(company, team, Settings(week_start(now), week_start(now)).shops_per_salesperson)
            plan = {
                "project": company.project,
                "mode": "dry-run",
                "staffMoves": staff_move_plan(company, team),
                "shopAssignments": shop_assignment_plan(shops, assign_areas(shops, team)),
            }
            if args.out:
                write_json(Path(args.out), plan)
            shown = {**plan, "staffMoves": {**plan["staffMoves"], "steps": _named(plan["staffMoves"]["steps"], company)},
                     "shopAssignments": _named(plan["shopAssignments"], company)}
            print(json.dumps(shown, indent=2, sort_keys=True, default=str))
            return 3 if plan["staffMoves"]["blocked"] else 0
        if args.command == "write":
            company, simulation = _simulation(args, now)
            if args.apply and args.confirm_project != company.project:
                print("--apply needs --confirm-project equal to the export's project.", file=sys.stderr)
                return 2
            manifest_path = Path(args.manifest)
            refuse_overwrite(manifest_path, applying=args.apply)
            if args.apply:
                journal = journal_path(manifest_path)
                try:
                    manifest = apply_manifest(
                        FirestoreStore(_client(company.project)), simulation, args.write_set, company.project,
                        now=now, order_limit=simulation.settings.order_limit, journal=journal,
                        max_writes=args.max_writes,
                    )
                except SimulationError:
                    raise
                except Exception:
                    if journal.exists() and journal.stat().st_size > 0:
                        write_json(manifest_path, manifest_from_journal(journal))
                    raise
            else:
                clash = route_clashes(simulation, ExportReader(company), now) if args.write_set == "routes" else None
                skipped = frozenset(row["simulatedPlanId"] for row in clash["kept"]) if clash else frozenset()
                planned = planned_documents(simulation, args.write_set, skipped_groups=skipped)
                check_max_writes(len(planned), args.max_writes)
                manifest = build_manifest(
                    simulation, args.write_set, company.project, export_existing(company, simulation, args.write_set),
                    skipped_groups=skipped,
                )
                if clash is not None:
                    manifest.update(route_summary(clash, planned, simulation, now))
                manifest["cost"] = write_cost(len(planned), clash["reads"] if clash else 0, args.max_writes)
            if args.write_set == "orders":
                manifest["purchaseOrderBusiestWeek"] = purchase_order_busiest_week(company, simulation)
            manifest["notActiveShops"] = _not_active_shops(simulation)
            write_json(manifest_path, manifest)
            print(json.dumps({key: manifest[key] for key in (
                "project", "mode", "writeSet", "batchId", "dataLabel", "cutoff", "counts", "story", "checks",
                "purchaseOrderBusiestWeek", "orderLimit", "heldGroups", "notActiveShops", "cost", "keptRealPlans",
                "realDraftsInSimulatedWeeks", "scorecardPreview", "phone",
            ) if key in manifest}, indent=2, sort_keys=True))
            counts = manifest["counts"]
            over_limit = manifest.get("orderLimit", {}).get("overLimitBy")
            held = (
                counts.get("exists_different") or counts.get("held_back") or counts.get(CHECK_BY_HAND)
                or manifest.get("heldGroups") or over_limit
            )
            return 3 if held else 0
        undo_path = Path(args.manifest)
        manifest = (
            manifest_from_journal(undo_path) if undo_path.name.endswith(JOURNAL_SUFFIX)
            else json.loads(undo_path.read_text(encoding="utf-8"))
        )
        if manifest.get("format") != MANIFEST_FORMAT or manifest.get("kind") != "created":
            print("The file is not a manifest of this tool.", file=sys.stderr)
            return 2
        if args.apply and args.confirm_project != manifest["project"]:
            print("--apply needs --confirm-project equal to the manifest's project.", file=sys.stderr)
            return 2
        store = FirestoreStore(_client(manifest["project"])) if args.apply else None
        report = undo_manifest(store, manifest)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 3 if any(report.get(key) for key in UNDO_KEPT_BACK) else 0
    except SimulationError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from platform_service import config

ORDERS = "orders"
PURCHASE_ORDERS = "purchase_orders"
USERS = "users"
ACCESS = "user_access"
PEOPLE = (USERS, ACCESS)
TOKEN = re.compile(r"synthetic-sales-[0-9]+")
UNSAFE_ID = re.compile(r"[/\x00-\x1f\x7f]")
MARKER_FIELDS = ("syntheticBatchId", "simulationBatchId")
SYNTHETIC_ORIGIN = "synthetic_history"
SALESPERSON_FIELDS = ("salesmanUid", "salesman_uid", "salesmanId", "salesman_id")
DATE_FIELDS = ("submittedAt", "createdAt")
ORDERS_PER_BATCH = 200
REREAD_TRIES = 3
DEFAULT_MAX_READS = 8000
DEFAULT_MAX_DELETES = 12000
SIGN_IN_MARGIN = timedelta(minutes=10)
FIRESTORE_EMULATOR = "FIRESTORE_EMULATOR_HOST"
AUTH_EMULATOR = "FIREBASE_AUTH_EMULATOR_HOST"
CONTROL_CENTRE_PROJECTS = frozenset({"demo-scoot-platform", config.PLATFORM_PROJECT_ID.strip().lower()})
LOG_NAME = "delete-log.jsonl"
ROUTE_PLANS = "route_plans"
PLAN_ROWS = ("route_plan_progress", "route_stop_progress")
HISTORY = (*PLAN_ROWS, ROUTE_PLANS, "conversation_outcomes", PURCHASE_ORDERS)
JOB_OUTPUTS = ("ai_insights", "retailer_priority_rankings", "visit_briefs", "retailer_item_patterns",
               "weekly_ai_summaries", "retailer_segments", "retailer_memory")
RETAILERS = "retailers"
PRODUCTS = "products"
DEMO = (RETAILERS, PRODUCTS)
RELATED = (*HISTORY, *JOB_OUTPUTS, *DEMO)
VISITS = "visits"
DEMO_ID = re.compile(r"AI1_[A-Za-z0-9_]+")
DEMO_FLAG = "isDemo"
NAME_FIELDS = ("retailerName", "productName", "name", "itemName")
RELATED_DATE_FIELDS = ("date", "weekStart", "submittedAt", "createdAt", "generatedAt", "updatedAt")
RELATED_PER_BATCH = 400
COUNT_PAGE = 1000
DEFAULT_RELATED_MAX_READS = 6000
DEFAULT_RELATED_MAX_DELETES = 1500
RELATED_LOG_NAME = "delete-related-log.jsonl"


class CleanupError(Exception):
    pass


class Refused(Exception):
    pass


class ServiceError(Exception):
    pass


class QuotaExhausted(ServiceError):
    pass


class ReadLimit(ServiceError):
    pass


class Store(Protocol):
    project: str
    reads: int

    def stream(self, collection: str, limit: int) -> Iterator[tuple[str, Mapping[str, Any], Any]]: ...

    def read(self, collection: str, doc_id: str) -> tuple[Mapping[str, Any], Any] | None: ...

    def delete_batch(self, items: list[tuple[str, str, Any]]) -> None: ...


class RelatedStore(Store, Protocol):
    def count(self, collection: str) -> int: ...

    def first_equal(self, collection: str, name: str, value: str) -> str | None: ...


class AuthStore(Protocol):
    def list_uids(self) -> list[str]: ...

    def get(self, uid: str) -> tuple[str, int | None] | None: ...

    def delete(self, uid: str) -> None: ...


class FirestoreStore:
    def __init__(self, db: Any):
        self.db = db
        self.project = db.project
        self.reads = 0

    def stream(self, collection: str, limit: int) -> Iterator[tuple[str, Mapping[str, Any], Any]]:
        from google.api_core import exceptions as google_errors

        try:
            for snapshot in self.db.collection(collection).limit(limit).stream():
                self.reads += 1
                yield snapshot.id, snapshot.to_dict() or {}, snapshot.update_time
        except google_errors.ResourceExhausted as error:
            raise QuotaExhausted(f"reading {collection}: {error}") from error
        except google_errors.GoogleAPIError as error:
            raise ServiceError(f"reading {collection}: {error}") from error

    def read(self, collection: str, doc_id: str) -> tuple[Mapping[str, Any], Any] | None:
        from google.api_core import exceptions as google_errors

        self.reads += 1
        try:
            snapshot = self.db.collection(collection).document(doc_id).get()
        except google_errors.ResourceExhausted as error:
            raise QuotaExhausted(f"reading {collection}/{doc_id}: {error}") from error
        except google_errors.GoogleAPIError as error:
            raise ServiceError(f"reading {collection}/{doc_id}: {error}") from error
        return (snapshot.to_dict() or {}, snapshot.update_time) if snapshot.exists else None

    def delete_batch(self, items: list[tuple[str, str, Any]]) -> None:
        from google.api_core import exceptions as google_errors

        batch = self.db.batch()
        for collection, doc_id, update_time in items:
            reference = self.db.collection(collection).document(doc_id)
            if update_time is None:
                batch.delete(reference)
            else:
                batch.delete(reference, option=self.db.write_option(last_update_time=update_time))
        try:
            batch.commit()
        except (google_errors.FailedPrecondition, google_errors.NotFound) as error:
            raise Refused(str(error)) from error
        except google_errors.ResourceExhausted as error:
            raise QuotaExhausted(str(error)) from error
        except google_errors.GoogleAPIError as error:
            raise ServiceError(str(error)) from error

    def count(self, collection: str) -> int:
        with _service_errors(f"counting {collection}"):
            found = int(self.db.collection(collection).count().get()[0][0].value)
        self.reads += max(1, -(-found // COUNT_PAGE))
        return found

    def first_equal(self, collection: str, name: str, value: str) -> str | None:
        from google.cloud import firestore

        self.reads += 1
        query = self.db.collection(collection).where(filter=firestore.FieldFilter(name, "==", value)).limit(1)
        with _service_errors(f"querying {collection}"):
            found = [snapshot.id for snapshot in query.stream()]
        return found[0] if found else None


@contextlib.contextmanager
def _service_errors(label: str) -> Iterator[None]:
    from google.api_core import exceptions as google_errors

    try:
        yield
    except google_errors.ResourceExhausted as error:
        raise QuotaExhausted(f"{label}: {error}") from error
    except google_errors.GoogleAPIError as error:
        raise ServiceError(f"{label}: {error}") from error


class FirebaseAuthStore:
    def __init__(self, project: str):
        import firebase_admin
        from firebase_admin import auth, exceptions

        name = f"synthetic-cleanup-{project}"
        try:
            self.app = firebase_admin.get_app(name)
        except ValueError:
            self.app = firebase_admin.initialize_app(options={"projectId": project}, name=name)
        if self.app.project_id != project:
            raise CleanupError(f"The sign-in app opened {self.app.project_id}, not {project}. Nothing was deleted.")
        self.auth = auth
        self.errors = exceptions.FirebaseError

    def list_uids(self) -> list[str]:
        try:
            return [record.uid for record in self.auth.list_users(app=self.app).iterate_all()]
        except self.errors as error:
            raise ServiceError(f"listing sign-in accounts: {error}") from error

    def get(self, uid: str) -> tuple[str, int | None] | None:
        try:
            record = self.auth.get_user(uid, app=self.app)
        except self.auth.UserNotFoundError:
            return None
        except self.errors as error:
            raise ServiceError(f"reading sign-in account {uid}: {error}") from error
        return record.uid, record.user_metadata.last_sign_in_timestamp

    def delete(self, uid: str) -> None:
        try:
            self.auth.delete_user(uid, app=self.app)
        except self.auth.UserNotFoundError:
            return
        except self.errors as error:
            raise ServiceError(f"deleting sign-in account {uid}: {error}") from error


def is_token(value: Any) -> bool:
    return isinstance(value, str) and TOKEN.fullmatch(value) is not None


def safe_id(doc_id: str) -> bool:
    return doc_id not in ("", ".", "..") and UNSAFE_ID.search(doc_id) is None


def marker(data: Mapping[str, Any]) -> str | None:
    for name in MARKER_FIELDS:
        value = data.get(name)
        if isinstance(value, str) and value.strip():
            return f"{name}={value}"
    if data.get("dataOrigin") == SYNTHETIC_ORIGIN:
        return f"dataOrigin={SYNTHETIC_ORIGIN}"
    return None


def month_of(data: Mapping[str, Any]) -> str:
    for name in DATE_FIELDS:
        value = data.get(name)
        if isinstance(value, (datetime, date)):
            return value.isoformat()[:7]
        if isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}.*", value):
            return value[:7]
    return "no date"


Row = tuple[str, Mapping[str, Any], Any]


@dataclass
class Plan:
    orders: dict[str, Any]
    people: dict[str, dict[str, Any]]
    summary: dict[str, Any] = field(default_factory=dict)


def classify(orders: list[Row], users: list[Row], access: list[Row]) -> Plan:
    marked: dict[str, Any] = {}
    values: Counter[str] = Counter()
    months: Counter[str] = Counter()
    unsafe: list[str] = []
    under_token = 0
    for doc_id, data, update_time in orders:
        found = marker(data)
        if found is None:
            under_token += any(is_token(data.get(name)) for name in SALESPERSON_FIELDS)
        elif not safe_id(doc_id):
            unsafe.append(doc_id)
        else:
            marked[doc_id] = update_time
            values[found] += 1
            months[month_of(data)] += 1
    read = {USERS: users, ACCESS: access}
    people = {name: {doc_id: update_time for doc_id, _, update_time in read[name] if is_token(doc_id)} for name in PEOPLE}
    planned = {"orders": len(marked), "purchaseOrderDeletesSent": len(marked),
               **{name: len(people[name]) for name in PEOPLE}}
    summary = {
        "orders": {"total": len(orders), "marked": len(marked), "unmarked": len(orders) - len(marked)},
        "markedByValue": [[value, count] for value, count in sorted(values.items(), key=lambda item: (-item[1], item[0]))[:10]],
        "markedByMonth": dict(sorted(months.items())),
        "unsafeOrderIds": sorted(unsafe),
        "tokenPeople": {name: sorted(people[name]) for name in PEOPLE},
        "keptPeople": {name: len(read[name]) - len(people[name]) for name in PEOPLE},
        "unmarkedOrdersUnderATokenSalesperson": under_token,
        "plannedDeletes": {**planned, "total": sum(planned.values())},
    }
    return Plan(marked, people, summary)


def _stream_all(store: Store, collection: str, max_reads: int) -> list[Row]:
    room = max_reads - store.reads
    rows = list(store.stream(collection, room)) if room > 0 else []
    if len(rows) >= room:
        raise ReadLimit(f"Stopped: reading {collection} would pass --max-reads {max_reads} "
                        f"({store.reads} reads used). Nothing was deleted by this step.")
    return rows


def inventory(store: Store, *, max_reads: int) -> Plan:
    orders = _stream_all(store, ORDERS, max_reads)
    users = _stream_all(store, USERS, max_reads)
    access = _stream_all(store, ACCESS, max_reads)
    plan = classify(orders, users, access)
    plan.summary["readsUsed"] = store.reads
    return plan


def summary_text(project: str, summary: Mapping[str, Any]) -> str:
    orders, planned = summary["orders"], summary["plannedDeletes"]
    lines = [f"Synthetic clean-up summary for {project}",
             f"Orders: {orders['total']} in all, {orders['marked']} marked as synthetic (to delete), "
             f"{orders['unmarked']} not marked (kept).",
             "Marked orders by marker value (top 10):"]
    lines += [f"  {value}: {count}" for value, count in summary["markedByValue"]]
    lines.append("Marked orders by month:")
    lines += [f"  {month}: {count}" for month, count in summary["markedByMonth"].items()]
    lines.append(f"Marked orders kept because their id is unsafe: {summary['unsafeOrderIds'] or 'none'}")
    for name in PEOPLE:
        ids = summary["tokenPeople"][name]
        lines.append(f"{name} to delete ({len(ids)}): {', '.join(ids) or 'none'}")
        lines.append(f"{name} kept: {summary['keptPeople'][name]}")
    lines.append(f"Orders kept that are not marked but name a synthetic-sales salesperson "
                 f"(for your later decision): {summary['unmarkedOrdersUnderATokenSalesperson']}")
    lines.append(f"Planned deletes: {planned['orders']} orders, {planned['purchaseOrderDeletesSent']} purchase order "
                 f"deletes (one per order, sent even when none exists), {planned['users']} users, "
                 f"{planned['user_access']} user_access, {planned['total']} in all.")
    lines.append(f"Reads used: {summary['readsUsed']}")
    return "\n".join(lines) + "\n"


@dataclass
class Run:
    store: Store
    max_reads: int
    record: Callable[[Mapping[str, Any]], None]
    report: dict[str, Any]

    def reread(self, collection: str, doc_id: str) -> tuple[Mapping[str, Any], Any] | None:
        if self.store.reads + 1 > self.max_reads:
            raise ReadLimit(f"Stopped: the next read would pass --max-reads {self.max_reads}. "
                            "Run inventory again for the new counts, then delete with them.")
        self.report["rereads"] += 1
        return self.store.read(collection, doc_id)

    def send(self, kind: str, items: list[tuple[str, str, Any]], ids: list[str]) -> bool:
        try:
            self.store.delete_batch(items)
        except Refused as error:
            self.record({"t": "refused", "kind": kind, "ids": ids, "reason": str(error)[:300]})
            return False
        except QuotaExhausted:
            self.record({"t": "notDeleted", "kind": kind, "ids": ids, "reason": "quota"})
            raise
        except ServiceError as error:
            self.report["unanswered"] += ids
            self.record({"t": "unanswered", "kind": kind, "ids": ids, "reason": str(error)[:300]})
            raise
        return True

    def orders(self, chunk: list[tuple[str, Any]]) -> None:
        ids = [doc_id for doc_id, _ in chunk]
        items = [item for doc_id, update_time in chunk
                 for item in ((ORDERS, doc_id, update_time), (PURCHASE_ORDERS, doc_id, None))]
        if self.send(ORDERS, items, ids):
            self.report["deleted"]["orders"] += len(ids)
            self.record({"t": "deleted", "orders": ids})
        elif len(chunk) > 1:
            self.orders(chunk[:len(chunk) // 2])
            self.orders(chunk[len(chunk) // 2:])
        else:
            self.changed_order(ids[0])

    def changed_order(self, doc_id: str) -> None:
        for _ in range(REREAD_TRIES):
            found = self.reread(ORDERS, doc_id)
            if found is None:
                self.report["goneBeforeDelete"].append(doc_id)
                self.record({"t": "gone", "orders": [doc_id]})
                return
            if marker(found[0]) is None:
                self.report["keptAfterReread"].append(doc_id)
                self.record({"t": "kept", "orders": [doc_id], "reason": "the marker is gone"})
                return
            if self.send(ORDERS, [(ORDERS, doc_id, found[1]), (PURCHASE_ORDERS, doc_id, None)], [doc_id]):
                self.report["deleted"]["orders"] += 1
                self.report["deletedAfterReread"].append(doc_id)
                self.record({"t": "deleted", "orders": [doc_id], "afterReread": True})
                return
        self.report["keptAfterReread"].append(doc_id)
        self.record({"t": "kept", "orders": [doc_id], "reason": f"changed again in {REREAD_TRIES} reads"})

    def people(self, rows: list[tuple[str, str, Any]]) -> None:
        ids = [f"{collection}/{doc_id}" for collection, doc_id, _ in rows]
        if self.send(USERS, rows, ids):
            for collection, _, _ in rows:
                self.report["deleted"][collection] += 1
            self.record({"t": "deleted", "people": ids})
        elif len(rows) > 1:
            self.people(rows[:len(rows) // 2])
            self.people(rows[len(rows) // 2:])
        else:
            self.changed_person(*rows[0][:2])

    def changed_person(self, collection: str, doc_id: str) -> None:
        for _ in range(REREAD_TRIES):
            found = self.reread(collection, doc_id)
            if found is None:
                self.record({"t": "gone", "people": [f"{collection}/{doc_id}"]})
                return
            if self.send(USERS, [(collection, doc_id, found[1])], [f"{collection}/{doc_id}"]):
                self.report["deleted"][collection] += 1
                self.record({"t": "deleted", "people": [f"{collection}/{doc_id}"], "afterReread": True})
                return
        self.report["keptAfterReread"].append(f"{collection}/{doc_id}")
        self.record({"t": "kept", "people": [f"{collection}/{doc_id}"], "reason": f"changed again in {REREAD_TRIES} reads"})

    def related(self, chunk: list[tuple[str, str, Any]], decide: Callable[[str, str, Mapping[str, Any]], bool]) -> None:
        paths = [f"{collection}/{doc_id}" for collection, doc_id, _ in chunk]
        if self.send("related", chunk, paths):
            for collection, _, _ in chunk:
                self.report["deleted"][collection] += 1
            self.record({"t": "deleted", "documents": paths})
        elif len(chunk) > 1:
            self.related(chunk[:len(chunk) // 2], decide)
            self.related(chunk[len(chunk) // 2:], decide)
        else:
            self.changed_related(chunk[0][0], chunk[0][1], decide)

    def changed_related(self, collection: str, doc_id: str,
                        decide: Callable[[str, str, Mapping[str, Any]], bool]) -> None:
        path = f"{collection}/{doc_id}"
        for _ in range(REREAD_TRIES):
            found = self.reread(collection, doc_id)
            if found is None:
                self.report["goneBeforeDelete"].append(path)
                self.record({"t": "gone", "documents": [path]})
                return
            if not decide(collection, doc_id, found[0]):
                self.report["keptAfterReread"].append(path)
                self.record({"t": "kept", "documents": [path], "reason": "no longer deletable by its own content"})
                return
            if self.send("related", [(collection, doc_id, found[1])], [path]):
                self.report["deleted"][collection] += 1
                self.report["deletedAfterReread"].append(path)
                self.record({"t": "deleted", "documents": [path], "afterReread": True})
                return
        self.report["keptAfterReread"].append(path)
        self.record({"t": "kept", "documents": [path], "reason": f"changed again in {REREAD_TRIES} reads"})

    def sign_in_accounts(self, auth: AuthStore, started: datetime) -> None:
        latest = int((started - SIGN_IN_MARGIN).timestamp() * 1000)
        for uid in [uid for uid in auth.list_uids() if is_token(uid)]:
            if any(self.reread(collection, uid) is not None for collection in PEOPLE):
                self.report["authRefused"][uid] = "a profile exists now"
                continue
            found = auth.get(uid)
            if found is None:
                continue
            if found[0] != uid:
                self.report["authRefused"][uid] = "the fetched account has another uid"
                continue
            if found[1] is not None and found[1] > latest:
                self.report["authRefused"][uid] = "signed in less than 10 minutes before this run, or during it"
                continue
            auth.delete(uid)
            self.report["authDeleted"].append(uid)
            self.record({"t": "authDeleted", "uid": uid})


def delete(store: Store, auth: AuthStore | None, *, expect_orders: int, expect_users: int, max_deletes: int,
           max_reads: int, started: datetime, record: Callable[[Mapping[str, Any]], None],
           say: Callable[[str], None]) -> dict[str, Any]:
    plan = inventory(store, max_reads=max_reads)
    say(summary_text(store.project, plan.summary))
    planned = plan.summary["plannedDeletes"]["total"]
    found_orders, found_users = len(plan.orders), len(plan.people[USERS])
    if found_orders != expect_orders or found_users != expect_users:
        raise CleanupError(f"Refused: this read found {found_orders} marked orders and {found_users} synthetic users, "
                           f"not the expected {expect_orders} and {expect_users}. Nothing was deleted.")
    if planned > max_deletes:
        raise CleanupError(f"Refused: {planned} deletes are planned, more than --max-deletes {max_deletes}. "
                           "Nothing was deleted.")
    report: dict[str, Any] = {"project": store.project, "summary": plan.summary, "stopped": None,
                              "deleted": {"orders": 0, USERS: 0, ACCESS: 0}, "rereads": 0, "unanswered": [],
                              "goneBeforeDelete": [], "keptAfterReread": [], "deletedAfterReread": [],
                              "authDeleted": [], "authRefused": {}}
    run = Run(store, max_reads, record, report)
    record({"t": "start", "project": store.project, "startedAt": started.isoformat(), "summary": plan.summary})
    orders = sorted(plan.orders.items())
    people = sorted((collection, doc_id, update_time) for collection in PEOPLE
                    for doc_id, update_time in plan.people[collection].items())
    try:
        for start in range(0, len(orders), ORDERS_PER_BATCH):
            run.orders(orders[start:start + ORDERS_PER_BATCH])
        if people:
            run.people(people)
        if auth is not None:
            run.sign_in_accounts(auth, started)
    except ReadLimit as error:
        report["stopped"] = str(error)
    except QuotaExhausted as error:
        report["stopped"] = (f"Stopped: the daily quota is used up ({error}). The failed batch was not deleted. "
                             "Run inventory again after the quota resets, then delete with the new counts.")
    except ServiceError as error:
        report["stopped"] = (f"Stopped by a service error: {error}. The last batch may or may not be deleted. "
                             "Run inventory again for the new counts, then delete with them.")
    report["readsUsed"] = store.reads
    record({"t": "end", "deleted": report["deleted"], "stopped": report["stopped"], "readsUsed": store.reads})
    return report


def history_marker(data: Mapping[str, Any]) -> str | None:
    value = data.get("syntheticBatchId")
    if isinstance(value, str) and value.strip():
        return f"syntheticBatchId={value}"
    if data.get("dataOrigin") == SYNTHETIC_ORIGIN:
        return f"dataOrigin={SYNTHETIC_ORIGIN}"
    return None


def is_demo(doc_id: str, data: Mapping[str, Any]) -> bool:
    return DEMO_ID.fullmatch(doc_id) is not None and data.get(DEMO_FLAG) is True


def names(value: Any, doc_id: str) -> bool:
    if isinstance(value, str):
        return value == doc_id or value.endswith("/" + doc_id)
    if isinstance(value, Mapping):
        return any(names(key, doc_id) or names(item, doc_id) for key, item in value.items())
    if isinstance(value, (list, tuple)):
        return any(names(item, doc_id) for item in value)
    path = getattr(value, "path", None)
    return isinstance(path, str) and names(path, doc_id)


def related_deletable(collection: str, doc_id: str, data: Mapping[str, Any], held: Mapping[tuple[str, str], str]) -> bool:
    if not safe_id(doc_id):
        return False
    if collection in DEMO:
        return is_demo(doc_id, data) and (collection, doc_id) not in held
    return collection in RELATED and history_marker(data) is not None


def related_date(data: Mapping[str, Any]) -> str | None:
    for name in RELATED_DATE_FIELDS:
        value = data.get(name)
        if isinstance(value, (datetime, date)):
            return value.isoformat()[:10]
        if isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}.*", value):
            return value[:10]
    return None


def display_name(data: Mapping[str, Any]) -> str:
    return next((data[name] for name in NAME_FIELDS if isinstance(data.get(name), str)), "")


@dataclass
class RelatedPlan:
    deletes: dict[str, dict[str, Any]]
    held: dict[tuple[str, str], str]
    summary: dict[str, Any] = field(default_factory=dict)


def holders(rows: Mapping[str, list[Row]], visited: Mapping[str, str]) -> dict[tuple[str, str], str]:
    kept = [(f"{ORDERS}/{doc_id}", data) for doc_id, data, _ in rows[ORDERS]]
    kept += [(f"{collection}/{doc_id}", data) for collection in HISTORY for doc_id, data, _ in rows[collection]
             if history_marker(data) is None or not safe_id(doc_id)]
    held: dict[tuple[str, str], str] = {}
    for collection in DEMO:
        for doc_id, data, _ in rows[collection]:
            if not (safe_id(doc_id) and is_demo(doc_id, data)):
                continue
            holder = next((path for path, record in kept if names(record, doc_id)), None)
            if holder is None and collection == RETAILERS:
                holder = visited.get(doc_id)
            if holder is not None:
                held[(collection, doc_id)] = holder
    return held


def classify_related(rows: Mapping[str, list[Row]], visited: Mapping[str, str]) -> RelatedPlan:
    held = holders(rows, visited)
    deletes: dict[str, dict[str, Any]] = {collection: {} for collection in RELATED}
    collections: dict[str, Any] = {}
    unsafe: dict[str, list[str]] = {}
    simulation: Counter[str] = Counter()
    demo_names: dict[str, list[list[str]]] = {collection: [] for collection in DEMO}
    for collection in RELATED:
        dates = []
        for doc_id, data, update_time in rows[collection]:
            if related_deletable(collection, doc_id, data, held):
                deletes[collection][doc_id] = update_time
                dates += [found for found in [related_date(data)] if found]
                if collection in DEMO:
                    demo_names[collection].append([doc_id, display_name(data)])
            elif collection not in DEMO and history_marker(data) is not None:
                unsafe.setdefault(collection, []).append(doc_id)
            elif collection not in DEMO and isinstance(data.get("simulationBatchId"), str) \
                    and data["simulationBatchId"].strip():
                simulation[collection] += 1
        collections[collection] = {"total": len(rows[collection]), "delete": len(deletes[collection]),
                                   "kept": len(rows[collection]) - len(deletes[collection]),
                                   "firstDate": min(dates) if dates else None, "lastDate": max(dates) if dates else None}
    plans = set(deletes[ROUTE_PLANS])
    without_plan, on_plan = [], []
    for collection in PLAN_ROWS:
        for doc_id, data, _ in rows[collection]:
            if doc_id in deletes[collection]:
                if data.get("planId") not in plans:
                    without_plan.append(f"{collection}/{doc_id}")
            elif any(doc_id.startswith(plan + "_") for plan in plans):
                on_plan.append(f"{collection}/{doc_id}")
    planned = {collection: len(deletes[collection]) for collection in RELATED}
    summary = {
        "collections": collections,
        "demoToDelete": {collection: sorted(demo_names[collection]) for collection in DEMO},
        "demoKept": {collection: sorted([doc_id, holder] for (name, doc_id), holder in held.items() if name == collection)
                     for collection in DEMO},
        "markedRowsWithoutAMarkedPlan": sorted(without_plan),
        "unmarkedRowsOnAMarkedPlan": sorted(on_plan),
        "unmarkedJobOutputsKept": sum(collections[collection]["kept"] for collection in JOB_OUTPUTS),
        "simulationMarkedKept": dict(sorted(simulation.items())),
        "unsafeIds": {collection: sorted(ids) for collection, ids in sorted(unsafe.items())},
        "plannedDeletes": {**planned, "total": sum(planned.values())},
    }
    return RelatedPlan(deletes, held, summary)


def inventory_related(store: RelatedStore, *, max_reads: int) -> RelatedPlan:
    counts = {collection: store.count(collection) for collection in (*RELATED, ORDERS)}
    if store.reads + sum(counts.values()) > max_reads:
        raise ReadLimit(f"Refused: the counts {counts} need {sum(counts.values())} reads after {store.reads} count "
                        f"reads, more than --max-reads {max_reads}. Nothing was read or deleted.")
    rows: dict[str, list[Row]] = {}
    for collection, counted in counts.items():
        rows[collection] = list(store.stream(collection, counted + 1))
        if len(rows[collection]) > counted:
            raise ServiceError(f"{collection} grew between the count and the read. Nothing was deleted.")
    visited: dict[str, str] = {}
    for doc_id, data, _ in rows[RETAILERS]:
        if safe_id(doc_id) and is_demo(doc_id, data):
            if store.reads + 1 > max_reads:
                raise ReadLimit(f"Stopped: the visit check of {doc_id} would pass --max-reads {max_reads}. "
                                "Nothing was deleted.")
            found = store.first_equal(VISITS, "retailerId", doc_id)
            if found is not None:
                visited[doc_id] = f"{VISITS}/{found}"
    plan = classify_related(rows, visited)
    plan.summary["countsBeforeRead"] = counts
    plan.summary["readsUsed"] = store.reads
    return plan


def related_summary_text(project: str, summary: Mapping[str, Any]) -> str:
    lines = [f"Synthetic related-records summary for {project}",
             "Per collection: total, to delete (own synthetic marker, or AI1_ demo record with isDemo true and not "
             "named by a kept record), kept, date range of the deletes:"]
    for collection, row in summary["collections"].items():
        lines.append(f"  {collection}: {row['total']} in all, {row['delete']} to delete, {row['kept']} kept, "
                     f"dates {row['firstDate'] or '-'} to {row['lastDate'] or '-'}")
    for collection in DEMO:
        named = summary["demoToDelete"][collection]
        lines.append(f"Demo {collection} to delete ({len(named)}): "
                     f"{', '.join(f'{doc_id} ({name})' for doc_id, name in named) or 'none'}")
        kept = summary["demoKept"][collection]
        lines.append(f"Demo {collection} kept because a kept record names them ({len(kept)}): "
                     f"{', '.join(f'{doc_id} (named by {holder})' for doc_id, holder in kept) or 'none'}")
    lines.append(f"Marked progress rows deleted whose plan is not deleted (report only): "
                 f"{', '.join(summary['markedRowsWithoutAMarkedPlan']) or 'none'}")
    lines.append(f"Unmarked progress rows kept on a deleted plan (report only, for your decision): "
                 f"{', '.join(summary['unmarkedRowsOnAMarkedPlan']) or 'none'}")
    lines.append(f"Unmarked weekly job outputs kept (the next weekly job replaces them): "
                 f"{summary['unmarkedJobOutputsKept']}")
    lines.append(f"Kept documents with only the simulation marker simulationBatchId (the demo simulation; phase 1 "
                 f"deleted such orders, this command keeps them): {summary['simulationMarkedKept'] or 'none'}")
    lines.append(f"Marked documents kept because their id is unsafe: {summary['unsafeIds'] or 'none'}")
    lines.append(f"Planned deletes: {summary['plannedDeletes']['total']} "
                 f"({', '.join(f'{name} {count}' for name, count in summary['plannedDeletes'].items() if count and name != 'total') or 'none'})")
    lines.append(f"Counts before the read: {summary['countsBeforeRead']}")
    lines.append(f"Reads used: {summary['readsUsed']}")
    return "\n".join(lines) + "\n"


def delete_related(store: RelatedStore, *, expect: Mapping[str, int], max_deletes: int = DEFAULT_RELATED_MAX_DELETES,
                   max_reads: int, started: datetime, record: Callable[[Mapping[str, Any]], None],
                   say: Callable[[str], None]) -> dict[str, Any]:
    plan = inventory_related(store, max_reads=max_reads)
    say(related_summary_text(store.project, plan.summary))
    found = {collection: len(ids) for collection, ids in plan.deletes.items() if ids}
    wanted = {collection: count for collection, count in expect.items() if count}
    if found != wanted:
        raise CleanupError(f"Refused: this read found {found} to delete, not the expected {wanted}. Nothing was deleted.")
    planned = plan.summary["plannedDeletes"]["total"]
    if planned > max_deletes:
        raise CleanupError(f"Refused: {planned} deletes are planned, more than --max-deletes {max_deletes}. "
                           "Nothing was deleted.")
    report: dict[str, Any] = {"project": store.project, "summary": plan.summary, "stopped": None,
                              "deleted": {collection: 0 for collection in RELATED}, "rereads": 0, "unanswered": [],
                              "goneBeforeDelete": [], "keptAfterReread": [], "deletedAfterReread": []}
    run = Run(store, max_reads, record, report)
    record({"t": "start", "project": store.project, "startedAt": started.isoformat(), "summary": plan.summary})
    items = [(collection, doc_id, update_time) for collection in RELATED
             for doc_id, update_time in sorted(plan.deletes[collection].items())]

    def decide(collection: str, doc_id: str, data: Mapping[str, Any]) -> bool:
        return related_deletable(collection, doc_id, data, plan.held)

    try:
        for start in range(0, len(items), RELATED_PER_BATCH):
            run.related(items[start:start + RELATED_PER_BATCH], decide)
    except ReadLimit as error:
        report["stopped"] = f"{error} Run inventory-related again for the new counts."
    except QuotaExhausted as error:
        report["stopped"] = (f"Stopped: the daily quota is used up ({error}). The failed batch was not deleted. "
                             "Run inventory-related again after the quota resets, then delete with the new counts.")
    except ServiceError as error:
        report["stopped"] = (f"Stopped by a service error: {error}. The last batch may or may not be deleted. "
                             "Run inventory-related again for the new counts, then delete with them.")
    report["readsUsed"] = store.reads
    record({"t": "end", "deleted": report["deleted"], "stopped": report["stopped"], "readsUsed": store.reads})
    return report


def expected_count(text: str) -> tuple[str, int]:
    found = re.fullmatch(r"([a-z_]+)=([0-9]+)", text)
    if found is None or found.group(1) not in RELATED:
        raise argparse.ArgumentTypeError(f"{text!r} is not <collection>=<count> for one of: {', '.join(RELATED)}")
    return found.group(1), int(found.group(2))


def check_environment(project: str, env: Mapping[str, str], *, auth_needed: bool, auth_injected: bool) -> None:
    if project.strip().lower() in CONTROL_CENTRE_PROJECTS:
        raise CleanupError(f"{project} is the Control Centre project. Use one company's project.")
    if project.startswith("demo-"):
        if not env.get(FIRESTORE_EMULATOR):
            raise CleanupError(f"{project} is a demo project but {FIRESTORE_EMULATOR} is not set.")
        if auth_needed and not auth_injected and not env.get(AUTH_EMULATOR):
            raise CleanupError(f"{project} is a demo project but {AUTH_EMULATOR} is not set.")
    elif FIRESTORE_EMULATOR in env or AUTH_EMULATOR in env:
        raise CleanupError(f"{project} is a live project but an emulator variable is set "
                           f"({FIRESTORE_EMULATOR} or {AUTH_EMULATOR}). Unset both.")


def open_firestore(project: str) -> Store:
    from google.auth.credentials import AnonymousCredentials
    from google.cloud import firestore

    emulator = bool(os.environ.get(FIRESTORE_EMULATOR))
    return FirestoreStore(firestore.Client(project=project, database="(default)",
                                           credentials=AnonymousCredentials() if emulator else None))


def outside_git(path: Path) -> Path:
    resolved = path.resolve()
    repository = Path(__file__).resolve().parents[2]
    for folder in (resolved, *resolved.parents):
        if folder == repository or ((folder / ".git").exists() and folder != Path.home().resolve()):
            raise CleanupError(f"{path} is inside the git folder {folder}. Use a folder outside git.")
    return resolved


@contextlib.contextmanager
def exclusive(folder: Path) -> Iterator[None]:
    lock = folder / "delete.lock"
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        raise CleanupError(f"Another delete holds {lock}. If none is running, delete that lock file and run again.") from None
    try:
        os.write(descriptor, str(os.getpid()).encode("ascii"))
        yield
    finally:
        os.close(descriptor)
        lock.unlink()


def append(handle: Any, row: Mapping[str, Any]) -> None:
    handle.write(json.dumps(row, sort_keys=True, default=str) + "\n")
    handle.flush()
    os.fsync(handle.fileno())


def write_atomic(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


HELP = """Delete the synthetic orders and the synthetic salespeople from one company's Firestore project.

Only these documents are ever deleted:
  orders/<id> whose own document has syntheticBatchId or simulationBatchId as a non-blank string, or dataOrigin
  exactly synthetic_history; with it, in the same batch, purchase_orders/<same id> (never read: the dashboard
  stores an order's purchase order under the order's id, and a delete of a missing document does nothing);
  users/<uid> and user_access/<uid> where <uid> is exactly synthetic-sales-<digits>; with --delete-auth, the
  sign-in account of such a uid when neither profile exists now.
The tool reads only orders, users and user_access, and the profiles of the sign-in accounts it may delete.

inventory reads and prints the summary. It writes nothing to the database. It writes summary.json and
summary.txt to --out (a folder outside git) for the record.

delete reads everything again itself, prints the summary, refuses before the first write when the marked orders
are not --expect-orders, the synthetic users documents are not --expect-users, or the planned deletes are above
--max-deletes, then deletes at once. Each order delete carries the update time this run read; an order changed
since is read again and deleted only when it still has its marker. delete-log.jsonl in --out records what happened;
nothing reads it. After a stop, run inventory again and give delete the new counts.

inventory-related and delete-related (phase 2) work the same way on a closed list of other collections:
  route_plan_progress, route_stop_progress, route_plans, conversation_outcomes, purchase_orders and the weekly job
  outputs ai_insights, retailer_priority_rankings, visit_briefs, retailer_item_patterns, weekly_ai_summaries,
  retailer_segments, retailer_memory: a document is deleted only when it has syntheticBatchId as a non-blank
  string or dataOrigin exactly synthetic_history. simulationBatchId alone does not count here.
  retailers/<id> and products/<id>: deleted only when <id> is AI1_ followed by letters, digits or underscores,
  isDemo is true, and no order, no unmarked document of the five collections above and (for a shop) no visit names it.
They also read orders (to see which demo records a real order names) and query visits by retailerId, one query
per demo shop. They count every collection first and refuse when the reads would pass --max-reads.
delete-related needs one --expect <collection>=<count> for each collection with deletes, refuses before the first
write when any count differs or the deletes pass --max-deletes, then deletes in batches of up to 400, each delete
with the update time this run read. A changed document is read again and judged from its content.
delete-related-log.jsonl in --out records what happened; nothing reads it.

Exit codes: 0 done, 1 refused, 2 wrong arguments, 3 done with something kept or refused, 4 stopped early."""


def main(argv: list[str] | None = None, *, env: Mapping[str, str] = os.environ,
         open_store: Callable[[str], Store] = open_firestore,
         open_auth: Callable[[str], AuthStore] | None = None,
         now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> int:
    parser = argparse.ArgumentParser(description=HELP, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("inventory", "delete", "inventory-related", "delete-related"):
        command = sub.add_parser(name)
        command.add_argument("--project", required=True)
        command.add_argument("--out", required=True, help="folder outside git")
        command.add_argument("--max-reads", type=int,
                             default=DEFAULT_RELATED_MAX_READS if name.endswith("related") else DEFAULT_MAX_READS)
    for name in ("delete", "delete-related"):
        removing = sub.choices[name]
        removing.add_argument("--confirm-project", required=True)
        removing.add_argument("--apply", action="store_true", required=True)
        removing.add_argument("--no-backup", action="store_true", required=True)
    related = sub.choices["delete-related"]
    related.add_argument("--expect", type=expected_count, action="append", default=[])
    related.add_argument("--max-deletes", type=int, default=DEFAULT_RELATED_MAX_DELETES)
    removing = sub.choices["delete"]
    removing.add_argument("--expect-orders", type=int, required=True)
    removing.add_argument("--expect-users", type=int, required=True)
    removing.add_argument("--max-deletes", type=int, default=DEFAULT_MAX_DELETES)
    removing.add_argument("--delete-auth", action="store_true")
    args = parser.parse_args(argv)
    expect: dict[str, int] = {}
    for name, count in getattr(args, "expect", []):
        if name in expect:
            parser.error(f"--expect names {name} twice.")
        expect[name] = count
    if args.command in ("delete", "delete-related") and args.confirm_project != args.project:
        print("--confirm-project must equal --project.", file=sys.stderr)
        return 2
    again = "inventory-related" if args.command.endswith("related") else "inventory"
    started = now()
    try:
        auth_needed = args.command == "delete" and args.delete_auth
        check_environment(args.project, env, auth_needed=auth_needed, auth_injected=open_auth is not None)
        out = outside_git(Path(args.out))
        out.mkdir(parents=True, exist_ok=True)
        store = open_store(args.project)
        if store.project != args.project:
            raise CleanupError(f"The opened project is {store.project}, not {args.project}. Nothing was read.")
        if args.command == "inventory":
            summary = inventory(store, max_reads=args.max_reads).summary
            write_atomic(out / "summary.json", json.dumps(summary, indent=1, sort_keys=True))
            write_atomic(out / "summary.txt", summary_text(args.project, summary))
            print(summary_text(args.project, summary))
            return 0
        if args.command == "inventory-related":
            summary = inventory_related(store, max_reads=args.max_reads).summary
            write_atomic(out / "related-summary.json", json.dumps(summary, indent=1, sort_keys=True))
            write_atomic(out / "related-summary.txt", related_summary_text(args.project, summary))
            print(related_summary_text(args.project, summary))
            return 0
        if args.command == "delete-related":
            with exclusive(out), (out / RELATED_LOG_NAME).open("a", encoding="utf-8") as handle:
                report = delete_related(store, expect=expect, max_deletes=args.max_deletes, max_reads=args.max_reads,
                                        started=started, record=lambda row: append(handle, row), say=print)
            unsafe = report["summary"]["unsafeIds"]
        else:
            auth = (open_auth or FirebaseAuthStore)(args.project) if auth_needed else None
            with exclusive(out), (out / LOG_NAME).open("a", encoding="utf-8") as handle:
                report = delete(store, auth, expect_orders=args.expect_orders, expect_users=args.expect_users,
                                max_deletes=args.max_deletes, max_reads=args.max_reads, started=started,
                                record=lambda row: append(handle, row), say=print)
            unsafe = report["summary"]["unsafeOrderIds"] or report["authRefused"]
    except CleanupError as error:
        print(str(error), file=sys.stderr)
        return 1
    except ServiceError as error:
        print(f"Stopped before any delete: {error} Run {again} again, then delete with its counts.", file=sys.stderr)
        return 4
    print(json.dumps({key: value for key, value in report.items() if key != "summary"}, indent=2, sort_keys=True))
    if report["stopped"]:
        print(report["stopped"], file=sys.stderr)
        return 4
    return 3 if report["keptAfterReread"] or unsafe else 0


if __name__ == "__main__":
    sys.exit(main())

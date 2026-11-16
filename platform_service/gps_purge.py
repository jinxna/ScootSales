from __future__ import annotations

import csv
import io
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Iterator

from google.api_core import exceptions
from google.cloud import firestore

from . import config

POSITIONS = "gps_tracking"
LIVE = "live_tracking"
USERS = "users"
STOP_PROGRESS = "route_stop_progress"
ORDERS = "orders"
PLAN_PROGRESS = "route_plan_progress"
EXPORTS = "purge_exports"

_LOG = logging.getLogger(__name__)

_POSITION_CLOCKS = ("timestamp", "deviceCapturedAt", "capturedAt")
_LIVE_CLOCKS = ("timestamp", "serverReceivedAt", "deviceCapturedAt", "lastSeen", "updatedAt")
_LIVE_FIX_FIELDS = ("latitude", "longitude", "gpsLatitude", "gpsLongitude", "location", "accuracy", "accuracyMeters")
_USER_FIX_FIELDS = ("lastLatitude", "lastLongitude", "lastLocationCapturedAt", "currentLatitude", "currentLongitude")
_USER_CLOCKS = ("lastLocationCapturedAt", "lastSeen")
_USER_FIX_PROBES = ("lastLatitude", "currentLatitude")
_ORDER_CLOCKS = ("locationCapturedAt", "submittedAt", "createdAt")
_ORDER_FIX_FIELDS = ("latitude", "longitude", "gpsLatitude", "gpsLongitude", "location", "locationCapturedAt")
_ORDER_EVIDENCE_FIELDS = ("latitude", "longitude")
_ORDER_FIX_PROBES = ("latitude", "longitude", "gpsLatitude", "gpsLongitude",
                     "locationEvidence.latitude", "locationEvidence.longitude")
_LEGACY_ARRIVAL_CLOCKS = ("arrivedAt", "deviceCapturedAt")
_EXPORTED_SOURCES = (POSITIONS, LIVE)
_EARLIEST = datetime(1, 1, 2, tzinfo=timezone.utc)
_UNBOUNDED_LATITUDE = -1000
_SUMMED_EXCLUDED = ("failed", "users_skipped")
_ARRIVAL_CLOCKS = ("arrivalDeviceCapturedAt", "arrivalDeviceOccurredAt", "arrivedAt", "updatedAt")
_ARRIVAL_FIELDS = ("arrivalLatitude", "arrivalLongitude", "arrivalAccuracyMeters")
_LEGACY_ARRIVAL_FIELDS = ("latitude", "longitude", "accuracyMeters")
_CONFLICTS = (exceptions.FailedPrecondition, exceptions.Aborted)
_ORDER_ID_START = "order_"
_ORDER_ID_END = "order`"


def _whole_days(value: Any, name: str) -> int:
    if type(value) is not int or value < 1:
        raise ValueError(f"{name} must be a whole number of days, at least 1.")
    return value


def _first_moment(data: dict[str, Any], names: tuple[str, ...]) -> datetime | None:
    for name in names:
        value = data.get(name)
        if isinstance(value, datetime):
            return value
    return None


def _position_moment(data: dict[str, Any]) -> datetime | None:
    stamped = data.get("timestamp")
    if isinstance(stamped, datetime):
        return stamped
    return _first_moment(data, ("deviceCapturedAt", "capturedAt"))


def _is_order_evidence(snapshot: Any, data: dict[str, Any]) -> bool:
    return snapshot.id.startswith("order_") or "lastOrderId" in data or "orderId" in data


def _pages(query: Any, size: int) -> Iterator[list[Any]]:
    last = None
    while True:
        rows = list((query if last is None else query.start_after(last)).limit(size).stream())
        if not rows:
            return
        yield rows
        if len(rows) < size:
            return
        last = rows[-1]


def _clear(db: firestore.Client, items: list[tuple[Any, dict[str, Any]]]) -> int:
    def write(batch_items: list[tuple[Any, dict[str, Any]]]) -> None:
        batch = db.batch()
        for snapshot, updates in batch_items:
            batch.update(snapshot.reference, updates, option=db.write_option(last_update_time=snapshot.update_time))
        batch.commit()

    if not items:
        return 0
    try:
        write(items)
        return len(items)
    except _CONFLICTS:
        cleared = 0
        for item in items:
            try:
                write([item])
                cleared += 1
            except _CONFLICTS:
                continue
        return cleared


def _count(query: Any) -> int:
    return query.count().get()[0][0].value


def _present(collection: Any, name: str, low: Any, operator: str = ">") -> Any:
    return collection.where(filter=firestore.FieldFilter(name, operator, low))


def _positions_lack_server_timestamp(db: firestore.Client) -> bool:
    positions = db.collection(POSITIONS)
    return _count(positions) != _count(_present(positions, "timestamp", _EARLIEST))


def _orders_lack_capture_stamp(db: firestore.Client) -> bool:
    orders = db.collection(ORDERS)
    stamped = _count(_present(orders, "locationCapturedAt", _EARLIEST))
    probes = [_present(orders, name, _UNBOUNDED_LATITUDE) for name in _ORDER_FIX_PROBES]
    probes.append(_present(orders, "location", firestore.GeoPoint(-90, -180), ">="))
    return any(_count(probe) > stamped for probe in probes)


def _position_queries(db: firestore.Client, clock: str, cutoff: datetime, order_cutoff: datetime) -> list[Any]:
    positions = db.collection(POSITIONS)
    start = positions.document(_ORDER_ID_START)
    end = positions.document(_ORDER_ID_END)

    def window(moment: datetime, *bounds: tuple[str, Any]) -> Any:
        query = positions.where(filter=firestore.FieldFilter(clock, "<", moment))
        for operator, reference in bounds:
            query = query.where(filter=firestore.FieldFilter("__name__", operator, reference))
        return query.order_by(clock).order_by("__name__")

    return [window(cutoff, ("<", start)),
            window(order_cutoff, (">=", start), ("<", end)),
            window(cutoff, (">=", end))]


def _purge_positions(db: firestore.Client, cutoff: datetime, order_cutoff: datetime, size: int) -> dict[str, int]:
    counts = {"positions_deleted": 0, "order_positions_deleted": 0}
    clocks = _POSITION_CLOCKS if _positions_lack_server_timestamp(db) else _POSITION_CLOCKS[:1]
    for clock in clocks:
        for query in _position_queries(db, clock, cutoff, order_cutoff):
            for rows in _pages(query, size):
                batch = db.batch()
                writes = 0
                for row in rows:
                    data = row.to_dict() or {}
                    moment = _position_moment(data)
                    if moment is None:
                        continue
                    order = _is_order_evidence(row, data)
                    if moment >= (order_cutoff if order else cutoff):
                        continue
                    batch.delete(row.reference)
                    writes += 1
                    counts["order_positions_deleted" if order else "positions_deleted"] += 1
                if writes:
                    batch.commit()
    return counts


def _purge_live_fixes(db: firestore.Client, cutoff: datetime, size: int) -> dict[str, int]:
    cleared = 0
    for rows in _pages(db.collection(LIVE), size):
        items = []
        for row in rows:
            data = row.to_dict() or {}
            moment = _first_moment(data, _LIVE_CLOCKS)
            present = [name for name in _LIVE_FIX_FIELDS if name in data]
            if moment is not None and moment < cutoff and present:
                items.append((row, {name: firestore.DELETE_FIELD for name in present}))
        cleared += _clear(db, items)
    return {"live_tracking_cleared": cleared}


def _purge_user_fixes(db: firestore.Client, cutoff: datetime, size: int) -> dict[str, int]:
    cleared = 0
    skipped: set[str] = set()
    users = db.collection(USERS)
    queries = [_present(users, name, _UNBOUNDED_LATITUDE) for name in _USER_FIX_PROBES]
    queries.append(users.where(filter=firestore.FieldFilter("lastLocationCapturedAt", "<", cutoff)))
    for query in queries:
        for rows in _pages(query, size):
            items = []
            for row in rows:
                data = row.to_dict() or {}
                present = [name for name in _USER_FIX_FIELDS if name in data]
                if not present:
                    continue
                moment = _first_moment(data, _USER_CLOCKS) or row.update_time
                if moment is None:
                    skipped.add(row.id)
                elif moment < cutoff:
                    items.append((row, {name: firestore.DELETE_FIELD for name in present}))
            cleared += _clear(db, items)
    return {"users_cleared": cleared, "users_skipped": len(skipped)}


def _order_fix_clears(data: dict[str, Any]) -> dict[str, Any]:
    updates: dict[str, Any] = {name: firestore.DELETE_FIELD for name in _ORDER_FIX_FIELDS if name in data}
    evidence = data.get("locationEvidence")
    if isinstance(evidence, dict):
        updates.update({f"locationEvidence.{name}": firestore.DELETE_FIELD
                        for name in _ORDER_EVIDENCE_FIELDS if name in evidence})
    return updates


def _purge_order_fixes(db: firestore.Client, order_cutoff: datetime, size: int) -> dict[str, int]:
    cleared = 0
    clocks = _ORDER_CLOCKS if _orders_lack_capture_stamp(db) else _ORDER_CLOCKS[:1]
    for clock in clocks:
        query = db.collection(ORDERS).where(filter=firestore.FieldFilter(clock, "<", order_cutoff))
        for rows in _pages(query, size):
            items = []
            for row in rows:
                data = row.to_dict() or {}
                moment = _first_moment(data, _ORDER_CLOCKS)
                updates = _order_fix_clears(data)
                if updates and moment is not None and moment < order_cutoff:
                    items.append((row, updates))
            cleared += _clear(db, items)
    return {"orders_cleared": cleared}


def _purge_arrival_fixes(db: firestore.Client, cutoff: datetime, size: int) -> dict[str, int]:
    cleared = 0
    query = db.collection(STOP_PROGRESS).where(filter=firestore.FieldFilter("arrivalLatitude", ">", -1000))
    for rows in _pages(query, size):
        items = []
        for row in rows:
            data = row.to_dict() or {}
            moment = _first_moment(data, _ARRIVAL_CLOCKS)
            if moment is None or moment >= cutoff:
                continue
            updates: dict[str, Any] = {name: firestore.DELETE_FIELD for name in _ARRIVAL_FIELDS if name in data}
            legacy = data.get("legacyArrivalEvidence")
            if isinstance(legacy, dict):
                updates.update({f"legacyArrivalEvidence.{name}": firestore.DELETE_FIELD
                                for name in _LEGACY_ARRIVAL_FIELDS if name in legacy})
            items.append((row, updates))
        cleared += _clear(db, items)
    return {"arrivals_cleared": cleared}


def _purge_legacy_arrivals(db: firestore.Client, cutoff: datetime, size: int) -> dict[str, int]:
    cleared = 0
    query = _present(db.collection(PLAN_PROGRESS), "stopProgress", {}, ">")
    for rows in _pages(query, size):
        items = []
        for row in rows:
            data = row.to_dict() or {}
            entries = data.get("stopProgress")
            if not isinstance(entries, dict):
                continue
            updates: dict[str, Any] = {}
            for stop_id, entry in entries.items():
                evidence = entry.get("arrivalEvidence") if isinstance(entry, dict) else None
                if not isinstance(evidence, dict):
                    continue
                moment = (_first_moment(entry, _LEGACY_ARRIVAL_CLOCKS) or _first_moment(evidence, ("deviceCapturedAt",))
                          or _first_moment(data, ("updatedAt",)))
                if moment is None or moment >= cutoff:
                    continue
                for name in _LEGACY_ARRIVAL_FIELDS:
                    if name in evidence:
                        updates[db.field_path("stopProgress", str(stop_id), "arrivalEvidence", name)] = firestore.DELETE_FIELD
            if updates:
                items.append((row, updates))
        cleared += _clear(db, items)
    return {"legacy_arrivals_cleared": cleared}


def _export_has_order_rows(data: dict[str, Any]) -> bool:
    text = data.get("csv")
    if not isinstance(text, str):
        return False
    rows = list(csv.DictReader(io.StringIO(text)))
    return any(
        str(row.get("docId") or "").startswith("order_") or row.get("orderId") or row.get("lastOrderId")
        for row in rows
    )


def _purge_exports(db: firestore.Client, cutoff: datetime, order_cutoff: datetime, size: int) -> dict[str, int]:
    deleted = 0
    query = db.collection(EXPORTS).where(filter=firestore.FieldFilter("collectionName", "in", list(_EXPORTED_SOURCES)))
    for rows in _pages(query, size):
        batch = db.batch()
        writes = 0
        for row in rows:
            data = row.to_dict() or {}
            moment = _first_moment(data, ("createdAt",))
            limit = order_cutoff if _export_has_order_rows(data) else cutoff
            if moment is not None and moment < limit:
                batch.delete(row.reference)
                writes += 1
        if writes:
            batch.commit()
            deleted += writes
    return {"exports_deleted": deleted}


def _csv_without_coordinates(text: str) -> str:
    rows = list(csv.reader(io.StringIO(text)))
    if not rows:
        return text
    blank = {index for index, name in enumerate(rows[0]) if name in _ORDER_FIX_FIELDS or name == "locationEvidence"}
    output = io.StringIO()
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(rows[0])
    for row in rows[1:]:
        writer.writerow(["" if index in blank else cell for index, cell in enumerate(row)])
    return output.getvalue()


def _order_without_coordinates(order: Any) -> Any:
    if not isinstance(order, dict):
        return order
    kept = {name: value for name, value in order.items() if name not in _ORDER_FIX_FIELDS}
    evidence = kept.get("locationEvidence")
    if isinstance(evidence, dict):
        kept["locationEvidence"] = {name: value for name, value in evidence.items()
                                    if name not in _ORDER_EVIDENCE_FIELDS}
    return kept


def _strip_order_export(data: dict[str, Any]) -> dict[str, Any]:
    updates: dict[str, Any] = {"coordinatesStrippedAt": firestore.SERVER_TIMESTAMP}
    orders = data.get("orders")
    if isinstance(orders, dict):
        updates["orders"] = {order_id: _order_without_coordinates(order) for order_id, order in orders.items()}
    if isinstance(data.get("csv"), str):
        updates["csv"] = _csv_without_coordinates(data["csv"])
    return updates


def _purge_order_exports(db: firestore.Client, order_cutoff: datetime, size: int) -> dict[str, int]:
    cleared = 0
    query = db.collection(EXPORTS).where(filter=firestore.FieldFilter("collectionName", "==", ORDERS))
    for rows in _pages(query, size):
        items = []
        for row in rows:
            data = row.to_dict() or {}
            moment = _first_moment(data, ("createdAt",))
            if moment is not None and moment < order_cutoff and "coordinatesStrippedAt" not in data:
                items.append((row, _strip_order_export(data)))
        cleared += _clear(db, items)
    return {"order_exports_stripped": cleared}


def purge_old_positions_by_part(db: firestore.Client, *, now: datetime | None = None,
                                retention_days: int | None = None, batch_size: int = 400,
                                order_retention_days: int | None = None) -> dict[str, Any]:
    days = _whole_days(config.GPS_RETENTION_DAYS if retention_days is None else retention_days, "GPS retention")
    order_days = _whole_days(
        config.ORDER_GPS_RETENTION_DAYS if order_retention_days is None else order_retention_days,
        "Order GPS retention")
    if type(batch_size) is not int or not 1 <= batch_size <= 500:
        raise ValueError("batch_size must be between 1 and 500.")
    moment = now or datetime.now(timezone.utc)
    cutoff = moment - timedelta(days=days)
    order_cutoff = moment - timedelta(days=max(days, order_days))
    parts: list[tuple[str, Callable[[], dict[str, int]]]] = [
        (POSITIONS, lambda: _purge_positions(db, cutoff, order_cutoff, batch_size)),
        (LIVE, lambda: _purge_live_fixes(db, cutoff, batch_size)),
        (USERS, lambda: _purge_user_fixes(db, cutoff, batch_size)),
        (STOP_PROGRESS, lambda: _purge_arrival_fixes(db, cutoff, batch_size)),
        (ORDERS, lambda: _purge_order_fixes(db, order_cutoff, batch_size)),
        (PLAN_PROGRESS, lambda: _purge_legacy_arrivals(db, cutoff, batch_size)),
        (EXPORTS, lambda: _purge_exports(db, cutoff, order_cutoff, batch_size)),
        (ORDERS + "_exports", lambda: _purge_order_exports(db, order_cutoff, batch_size)),
    ]
    result: dict[str, Any] = {"positions_deleted": 0, "order_positions_deleted": 0, "live_tracking_cleared": 0,
                              "users_cleared": 0, "users_skipped": 0, "arrivals_cleared": 0, "orders_cleared": 0,
                              "legacy_arrivals_cleared": 0, "exports_deleted": 0, "order_exports_stripped": 0, "failed": []}
    for name, run in parts:
        try:
            result.update(run())
        except Exception:
            _LOG.exception("GPS retention part %s failed.", name)
            result["failed"].append(name)
    return result


def purge_old_positions(db: firestore.Client, *, now: datetime | None = None,
                        retention_days: int | None = None, batch_size: int = 400) -> int:
    result = purge_old_positions_by_part(db, now=now, retention_days=retention_days, batch_size=batch_size)
    _LOG.info("GPS retention: %s", result)
    if result["failed"]:
        raise RuntimeError("GPS retention parts failed: " + ", ".join(result["failed"]))
    return sum(value for key, value in result.items() if key not in _SUMMED_EXCLUDED)

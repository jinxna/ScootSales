from __future__ import annotations

import hashlib
import json
import logging
import math
import random
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from google.api_core.exceptions import GoogleAPICallError, InvalidArgument, OutOfRange
from google.cloud import firestore
from google.cloud.firestore import GeoPoint

from . import auth, config
from .account_links import RATE_LIMITS
from .company_access import UNREACHABLE, CompanyAccess
from .directory import DirectoryError, DirectoryStore
from .lifecycle import (
    ACCESS,
    HELD_SESSIONS,
    LAPSE_REASONS,
    LIFECYCLE,
    LIVE_TRACKING,
    READ_ONLY_REASON,
    lifecycle_view,
)
from .order_price_check import parse_commercial_lines
from .tenancy import TenantContext, ensure_signed_in, resolve_tenant

SKEW = timedelta(minutes=5)
CLOCK_TOLERANCE = timedelta(hours=24)
SESSION_START_LAG = timedelta(days=7)
REPLACED_ROUTE_WINDOW = timedelta(hours=24)
MAX_ITEMS = 50
MAX_BODY_BYTES = 2560 * 1024
BODY_LIMIT_TEXT = "Held work is limited to 2.5 MB."
RECEIPTS = "held_work_receipts"
AUDIT_LOGS = "system_audit_logs"
_LOG = logging.getLogger(__name__)
SOURCE = "held_work"
HELD_FOR_REVIEW = "held_for_review"
REVIEW_UNKNOWN_SESSION = "session_unknown_before_pause"
REVIEW_UNKNOWN_SESSION_TEXT = (
    "Held for your decision. The company was paused when this order reached the server, and the server had no "
    "record of the salesperson's work session from before the pause. The phone says the order was made before the "
    "pause, but the server cannot confirm it. Approve it only if you know the work was done before the pause. "
    "Reject it if not."
)
KINDS = ("session_start", "stop_event", "order")
STOP_STATUSES = ("arrived", "completed", "skipped")
COMPANY_REASONS = LAPSE_REASONS | {READ_ONLY_REASON}
_NO_STORE = {"Cache-Control": "no-store"}
_SESSION_ID = re.compile(r"^[0-9a-f]{32}$")
_ITEM_ID = re.compile(r"^(?!__)[^/\s]{1,300}$")
_PLAN_ID = re.compile(r"^[^/\s]{1,200}$")
_ORDER_UID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_ORDER_PLAN = re.compile(r"^[A-Za-z0-9_-]{1,100}$")
_ORDER_STOP = re.compile(r"^[A-Za-z0-9_-]{1,300}$")
_COMMERCIAL_LINE = re.compile(r"[A-Za-z0-9_-]{1,200}~[A-Za-z0-9_-]{1,800}~[1-9][0-9]{0,2}~[1-9][0-9]{0,8}")
_STOP_PAYLOAD_SERVER_KEYS = frozenset({
    "planId", "salesmanUid", "salesmanCode", "branchId", "stopId", "retailerId", "lifecycleSchemaVersion", "status",
    "eventId", "workSessionId", "workSessionGeneration", "sessionEventSequence", "deviceOccurredAt", "receivedAt",
    "updatedAt", "arrivedAt", "arrivalEventId", "arrivalWorkSessionId", "arrivalWorkSessionGeneration",
    "arrivalSessionEventSequence", "arrivalDeviceOccurredAt", "arrivalReceivedAt", "completedAt", "skippedAt",
    "serverReceivedAt", "source", "legacyArrivalEvidence", "retailerName",
})
_ARRIVAL_KEYS = frozenset({
    "arrivalMode", "arrivalFailureCode", "overrideReasonCode", "overrideNote", "arrivalLatitude",
    "arrivalLongitude", "arrivalAccuracyMeters", "arrivalDeviceCapturedAt", "arrivalIsMocked", "arrivalDistanceMeters",
    "retailerCoordinateRevision", "retailerCoordinateSource", "coordinateReferenceMode", "coordinateSnapshotAt",
    "coordinateCheckedAt", "notes",
})
_MANUAL_NUMBERS = ("arrivalLatitude", "arrivalLongitude", "arrivalAccuracyMeters", "arrivalDistanceMeters")
_ARRIVAL_MOMENTS = ("arrivalDeviceCapturedAt", "coordinateSnapshotAt", "coordinateCheckedAt")
_SKIP_KEYS = frozenset({"skipReason", "notes"})
_COMPLETE_KEYS = frozenset({"notes"})
_FAILURE_CODES = frozenset({
    "disabled_by_user", "service_disabled", "permission_denied", "permission_denied_forever", "unavailable",
    "invalid_coordinates", "stale", "inaccurate", "mocked", "missing_retailer_coordinates", "outside_radius",
})
_OVERRIDE_CODES = frozenset({
    "gps_unavailable", "retailer_coordinates_incorrect", "manager_approved_exception", "safety_or_access_issue",
})
_ORDER_SERVER_KEYS = frozenset({
    "orderId", "uid", "userUid", "salesmanUid", "submittedByUid", "createdByUid", "salesmanCode", "branchId",
    "branch_id", "status", "submittedAt", "createdAt", "updatedAt", "location", "locationCapturedAt", "source",
    "serverReceivedAt",
})
_ORDER_CREATE_KEYS = frozenset({
    "orderId", "visitId", "visitSource", "routePlanId", "routeStopId", "retailerId", "retailerName", "outlet", "uid",
    "userUid", "salesmanUid", "salesmanEmail", "salesmanId", "salesmanCode", "salesmanName", "submittedByUid",
    "createdByUid", "branchId", "supervisorId", "totalProducts", "totalBoxes", "totalPrice", "submittedAt", "createdAt",
    "updatedAt", "status", "items", "commercialSchemaVersion", "commercialLines", "signatureTimestamps",
    "locationEvidence", "latitude", "longitude", "gpsLatitude", "gpsLongitude", "location", "locationCapturedAt",
    "accuracy", "accuracyMeters", "deviceCapturedAt", "isMocked", "locationVerification",
})
_ORDER_NAME_KEYS = ("retailerName", "outlet", "salesmanName", "salesmanEmail", "supervisorId", "visitId")
_SIGNATURE_STAMPS = re.compile(r"^[0-9 /:.TZ|-]{0,1000}$")
_FAILURE_CODE = re.compile(r"^[a-z_]{0,40}$")
_ORDER_COORDINATE_KEYS = ("latitude", "longitude", "gpsLatitude", "gpsLongitude", "location")
_ORDER_LOCATION_KEYS = (
    "latitude", "longitude", "gpsLatitude", "gpsLongitude", "location", "accuracy", "accuracyMeters",
    "deviceCapturedAt", "isMocked", "locationVerification", "locationEvidence",
)
_FIX_KEYS = ("latitude", "longitude", "accuracyMeters", "deviceCapturedAt", "isMocked")
_EARTH_RADIUS_METERS = 6371008.8


class Refused(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def _result(item_id: str, outcome: str, reason: str | None = None, stored_as: str | None = None) -> dict[str, Any]:
    entry = {"id": item_id, "outcome": outcome}
    if reason is not None:
        entry["reason"] = reason
    if stored_as is not None:
        entry["storedAs"] = stored_as
    return entry


def _number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _text(data: Mapping[str, Any], camel: str, snake: str) -> str:
    for key in (camel, snake):
        value = data.get(key)
        if isinstance(value, str):
            return value
    return ""


def _moment(value: Any) -> datetime:
    if isinstance(value, datetime) and value.tzinfo is not None:
        return value
    if not isinstance(value, str) or len(value) > 40:
        raise Refused("invalid")
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if moment.tzinfo is None:
            raise Refused("invalid")
        return moment.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise Refused("invalid") from None


def _nonnegative(value: Any) -> int:
    return value if _integer(value) and value >= 0 else 0


def receipt_id(uid: str, item_id: str) -> str:
    return f"{len(uid)}.{uid}.{item_id}"


def own_order_id(uid: str, item_id: str) -> str:
    return f"{uid}~{item_id}"


def identity_path_part(value: str) -> str:
    return value.replace("%", "%25").replace("/", "%2F")


def canonical_stop_id(plan_id: str, uid: str, stop_id: str) -> str:
    return f"{identity_path_part(plan_id)}_{identity_path_part(uid)}_{identity_path_part(stop_id)}"


def distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi, dlmb = math.radians(lat2 - lat1), math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlmb / 2) ** 2
    return 2 * _EARTH_RADIUS_METERS * math.asin(min(1.0, math.sqrt(a)))


def _valid_coordinates(latitude: Any, longitude: Any) -> bool:
    return (_number(latitude) and -90 <= latitude <= 90 and _number(longitude) and -180 <= longitude <= 180
            and not (latitude == 0 and longitude == 0))


def _route_open(route: Mapping[str, Any], progress: Mapping[str, Any] | None, now: datetime) -> bool:
    replaced_at = route.get("replacedAt")
    return route.get("status") == "published" or (
        route.get("status") == "archived" and isinstance(replaced_at, datetime)
        and now < replaced_at + REPLACED_ROUTE_WINDOW
        and progress is not None and progress.get("status") in ("in_progress", "completed"))


def _route_owned(route: Mapping[str, Any], uid: str, code: str, progress: Mapping[str, Any] | None,
                 now: datetime) -> bool:
    return _route_open(route, progress, now) and (
        _text(route, "salesmanUid", "salesman_uid") == uid
        or (code != "" and _text(route, "salesmanCode", "salesman_code") == code)
    )


def _route_stop_id(stop: Mapping[str, Any], day_id: str) -> str:
    explicit = stop.get("stopId", stop.get("stop_id"))
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip()
    retailer = stop.get("retailerId", stop.get("retailer_id"))
    retailer = retailer.strip() if isinstance(retailer, str) else ""
    sequence = stop.get("sequence")
    sequence = int(sequence) if _number(sequence) else 0
    return f"{day_id or 'day'}_{sequence}_{retailer or 'retailer'}"


def route_retailer_name(route: Mapping[str, Any], stop_id: str) -> str:
    days = route.get("days")
    for day in days if isinstance(days, list) else []:
        if not isinstance(day, dict) or not isinstance(day.get("stops"), list):
            continue
        day_id = day.get("dayId", day.get("day_id"))
        day_id = day_id.strip() if isinstance(day_id, str) else ""
        for stop in day["stops"]:
            if isinstance(stop, dict) and _route_stop_id(stop, day_id) == stop_id:
                name = stop.get("retailerName")
                return name.strip() if isinstance(name, str) and name.strip() else "Retailer"
    return "Retailer"


def session_pre_cut(session: Mapping[str, Any], cut: datetime) -> bool:
    started, device = session.get("serverStartedAt"), session.get("deviceAt")
    if isinstance(started, datetime):
        return started < cut
    return isinstance(device, datetime) and device <= cut + SKEW


def session_pre_reactivation(session: Mapping[str, Any], reactivated: datetime) -> bool:
    started, device = session.get("serverStartedAt"), session.get("deviceAt")
    if isinstance(started, datetime):
        return started < reactivated
    return isinstance(device, datetime) and device < reactivated + SKEW


def session_floor(session: Mapping[str, Any]) -> datetime | None:
    started, device = session.get("serverStartedAt"), session.get("deviceAt")
    started = started if isinstance(started, datetime) else None
    device = device if isinstance(device, datetime) else None
    if started is None:
        return device
    if device is None or device >= started:
        return started
    return max(device, started - SESSION_START_LAG)


def before_session(session: Mapping[str, Any], moment: datetime) -> bool:
    floor = session_floor(session)
    return floor is not None and moment < floor - CLOCK_TOLERANCE


def drain_decision(stamp: Mapping[str, Any], session: Mapping[str, Any], device_at: datetime | None,
                   now: datetime) -> str | None:
    cut = stamp.get("cutAt")
    if not isinstance(cut, datetime):
        return "not_paused"
    reactivated = stamp.get("reactivatedAt")
    if stamp.get("access") == "open":
        if not isinstance(reactivated, datetime) or reactivated <= cut:
            return "not_paused"
        if not session_pre_reactivation(session, reactivated):
            return "not_paused"
    else:
        drain_until = stamp.get("drainUntil")
        if not isinstance(drain_until, datetime) or now >= drain_until:
            return "drain_closed"
    if not session_pre_cut(session, cut):
        return "session_after_cut"
    if device_at is not None and device_at > cut + SKEW:
        return "after_cut"
    if device_at is not None and before_session(session, device_at):
        return "before_session"
    return None


class HeldWork:
    def __init__(self, directory: DirectoryStore, access_for: Callable[[Mapping[str, Any]], CompanyAccess],
                 clock: Callable[[], datetime], database: Any = None) -> None:
        self.directory = directory
        self.access_for = access_for
        self.clock = clock
        self.database = database

    def _quota(self, context: TenantContext) -> Any:
        digest = hashlib.sha256(f"{context.tenant_id}|{context.uid}".encode()).hexdigest()[:32]
        return self.database.collection(RATE_LIMITS).document(f"held_{digest}_{self.clock().strftime('%Y%m%d%H')}")

    def _wait(self) -> HTTPException:
        now = self.clock()
        wait = max(1, 3600 - now.minute * 60 - now.second)
        return HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "This phone has sent a lot of held work in the last hour. Nothing was lost. "
            "It will be sent again automatically in a few minutes.",
            headers={"Retry-After": str(wait), **_NO_STORE})

    @staticmethod
    def _busy() -> HTTPException:
        return HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "The server is busy just now. Nothing was lost. The phone will try again in a few seconds.",
            headers={"Retry-After": "5", **_NO_STORE})

    def _admit(self, context: TenantContext) -> None:
        if self.database is None:
            return
        try:
            used = int((self._quota(context).get().to_dict() or {}).get("count") or 0)
        except Exception:
            _LOG.exception("The held-work hourly count could not be read; the request is refused for now.")
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE,
                "Held work could not be checked just now. Nothing was lost. It will be sent again automatically.",
                headers={"Retry-After": "30", **_NO_STORE}) from None
        if used >= config.HELD_WORK_ITEMS_PER_HOUR:
            raise self._wait()

    def reserve(self, context: TenantContext, count: int) -> Any:
        if self.database is None:
            return None
        reference = self._quota(context)
        expires = self.clock() + timedelta(hours=2)

        @firestore.transactional
        def take(transaction: firestore.Transaction) -> bool:
            used = int((reference.get(transaction=transaction).to_dict() or {}).get("count") or 0)
            if used >= config.HELD_WORK_ITEMS_PER_HOUR:
                return False
            transaction.set(reference, {"count": used + count, "expiresAt": expires}, merge=True)
            return True

        taken = None
        try:
            for attempt in range(5):
                try:
                    taken = take(self.database.transaction(max_attempts=10))
                    break
                except ValueError as error:
                    if not isinstance(error.__cause__, GoogleAPICallError):
                        raise
                    if attempt == 4:
                        raise self._busy() from None
                    time.sleep(0.05 * (attempt + 1) + random.random() * 0.05)
        except HTTPException:
            raise
        except Exception:
            _LOG.exception("The held-work hourly count could not be reserved; the request is refused for now.")
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE,
                "Held work could not be checked just now. Nothing was lost. It will be sent again automatically.",
                headers={"Retry-After": "30", **_NO_STORE}) from None
        if not taken:
            raise self._wait()
        return reference

    @staticmethod
    def refund(reservation: Any, count: int) -> None:
        if reservation is None or count <= 0:
            return
        try:
            reservation.set({"count": firestore.Increment(-count)}, merge=True)
        except Exception:
            _LOG.exception("The held-work hourly count could not be refunded.")

    @staticmethod
    def unspent(results: list[dict[str, Any]]) -> int:
        return sum(1 for row in results if row["outcome"] in ("retry_later", "duplicate"))

    def admit(self, workspace: str, who: auth.ClientIdentity) -> TenantContext:
        context = resolve_tenant(who, self.directory, workspace=workspace, any_state=True,
                                 access_for=None)
        self._admit(context)
        return context

    def handle(self, context: TenantContext, who: auth.ClientIdentity, items: list[Any]) -> dict[str, Any]:
        try:
            state = self.directory.lifecycle_state(context.tenant_id)
        except DirectoryError as error:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                                "The company directory could not be verified.") from error
        ordered = sorted(items, key=lambda item: 0 if isinstance(item, dict) and item.get("kind") == "session_start" else 1)
        try:
            access = self.access_for(context.record["location"])
            ensure_signed_in(who, access)
            lifecycle_ref = access.db.collection("config").document(LIFECYCLE)
            access_ref = access.db.collection(ACCESS).document(context.uid)
            snapshots = {snapshot.reference.path: snapshot for snapshot in access.db.get_all([lifecycle_ref, access_ref])}
            stamp = snapshots[lifecycle_ref.path].to_dict() or {}
            actor = self._salesperson(snapshots[access_ref.path], context.uid)
        except UNREACHABLE:
            return {"lifecycle": lifecycle_view(state, None),
                    "results": [_result(self._item_id(item), "retry_later", "company_unreachable") for item in ordered]}
        results = []
        unreachable = False
        for item in ordered:
            item_id = self._item_id(item)
            if unreachable:
                results.append(_result(item_id, "retry_later", "company_unreachable"))
                continue
            try:
                results.append(self._one(access, context, actor, item, item_id))
            except (InvalidArgument, OutOfRange):
                results.append(_result(item_id, "rejected", "save_failed"))
            except UNREACHABLE:
                unreachable = True
                results.append(_result(item_id, "retry_later", "company_unreachable"))
            except Exception:
                _LOG.exception("Held item %s failed unexpectedly; the phone keeps it and sends it again.", item_id)
                results.append(_result(item_id, "retry_later", "server_error"))
        return {"lifecycle": lifecycle_view(state, stamp), "results": results}

    @staticmethod
    def _item_id(item: Any) -> str:
        value = item.get("id") if isinstance(item, dict) else None
        return value if isinstance(value, str) else ""

    @staticmethod
    def _salesperson(snapshot: Any, uid: str) -> dict[str, Any]:
        data = snapshot.to_dict() or {}
        reasons = data.get("disabledReasons", [])
        if not (
            snapshot.exists
            and data.get("accessVersion") == 2
            and data.get("uid") == uid
            and data.get("status") == "active"
            and data.get("role") == "salesman"
            and data.get("invitationState") not in ("pending", "revoked")
            and isinstance(reasons, list)
            and set(reasons) <= COMPANY_REASONS
        ):
            raise HTTPException(status.HTTP_403_FORBIDDEN,
                                "Only an active salesperson of this company can send held work.")
        code, branch = data.get("employeeCode", ""), data.get("branchId", "")
        return {"code": code if isinstance(code, str) else "", "branch": branch if isinstance(branch, str) else ""}

    def _one(self, access: CompanyAccess, context: TenantContext, actor: Mapping[str, Any], item: Any,
             item_id: str) -> dict[str, Any]:
        if not isinstance(item, dict) or not _ITEM_ID.fullmatch(item_id) or item_id in (".", ".."):
            return _result(item_id, "rejected", "invalid")
        try:
            parsed = self._parse(item, item_id)
        except Refused as refused:
            self._receipt(access, context.uid, item_id, item.get("kind"), "rejected", refused.reason)
            return _result(item_id, "rejected", refused.reason)
        writer = {"session_start": self._session_start, "stop_event": self._stop_event, "order": self._order}
        db = access.db

        @firestore.transactional
        def run(transaction: firestore.Transaction) -> dict[str, Any]:
            receipt_ref = db.collection(RECEIPTS).document(receipt_id(context.uid, item_id))
            legacy_ref = db.collection(RECEIPTS).document(item_id)
            lifecycle_ref = db.collection("config").document(LIFECYCLE)
            snapshots = {snapshot.reference.path: snapshot for snapshot in transaction.get_all(
                [receipt_ref, legacy_ref, lifecycle_ref, *self._known_refs(db, context.uid, parsed)])}

            def read(reference: Any) -> Any:
                if reference.path in snapshots:
                    return snapshots[reference.path]
                return reference.get(transaction=transaction)

            receipt = snapshots[receipt_ref.path]
            legacy = snapshots[legacy_ref.path]
            if receipt.exists and (receipt.to_dict() or {}).get("outcome") == "accepted":
                transaction.update(receipt_ref, {"lastSeenAt": firestore.SERVER_TIMESTAMP,
                                                 "attempts": firestore.Increment(1)})
                kept = receipt.to_dict() or {}
                return _result(item_id, "duplicate", stored_as=kept.get("storedAs") or (item_id if parsed["kind"] == "order" else None))
            earlier = legacy.to_dict() or {}
            if legacy.exists and earlier.get("uid") == context.uid and earlier.get("outcome") == "accepted":
                return _result(item_id, "duplicate", stored_as=item_id if parsed["kind"] == "order" else None)
            stamp = snapshots[lifecycle_ref.path].to_dict() or {}
            try:
                outcome = writer[parsed["kind"]](transaction, db, context.uid, actor, parsed, stamp, read)
            except Refused as refused:
                return self._decide(transaction, receipt_ref, context.uid, parsed, "rejected", refused.reason)
            return self._decide(transaction, receipt_ref, context.uid, parsed, outcome, None)

        try:
            return run(db.transaction(max_attempts=5))
        except ValueError as error:
            if isinstance(error.__cause__, GoogleAPICallError):
                return _result(item_id, "retry_later", "busy")
            raise

    @staticmethod
    def _known_refs(db: Any, uid: str, parsed: Mapping[str, Any]) -> list[Any]:
        references = [db.collection(LIVE_TRACKING).document(uid),
                      db.collection(HELD_SESSIONS).document(f"{uid}_{parsed['workSessionId']}")]
        if parsed["kind"] == "stop_event":
            plan_id = parsed["planId"]
            references += [db.collection("route_stop_progress").document(canonical_stop_id(plan_id, uid, parsed["stopId"])),
                           db.collection("route_plan_progress").document(f"{plan_id}_{uid}"),
                           db.collection("route_plans").document(plan_id)]
        elif parsed["kind"] == "order":
            plan_id = parsed["payload"].get("routePlanId")
            references += [db.collection("orders").document(parsed["id"]),
                           db.collection("orders").document(own_order_id(uid, parsed["id"]))]
            if isinstance(plan_id, str) and _ORDER_PLAN.fullmatch(plan_id):
                references += [db.collection("route_plans").document(plan_id),
                               db.collection("route_plan_progress").document(f"{plan_id}_{uid}")]
        return references

    @staticmethod
    def _decide(transaction: firestore.Transaction, reference: Any, uid: str, parsed: Mapping[str, Any],
                outcome: str, reason: str | None) -> dict[str, Any]:
        record = {
            "uid": uid,
            "kind": parsed["kind"],
            "workSessionId": parsed["workSessionId"],
            "deviceAt": parsed["deviceAt"],
            "outcome": outcome,
            "reason": reason,
            "decidedAt": firestore.SERVER_TIMESTAMP,
            "attempts": firestore.Increment(1),
        }
        if outcome == "accepted":
            record.update({key: parsed[key] for key in ("storedAs", "deviceTimeOnly") if key in parsed})
        transaction.set(reference, record, merge=True)
        return _result(parsed["id"], outcome, reason, parsed.get("storedAs"))

    @staticmethod
    def _receipt(access: CompanyAccess, uid: str, item_id: str, kind: Any, outcome: str, reason: str) -> None:
        reference = access.db.collection(RECEIPTS).document(receipt_id(uid, item_id))

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            snapshot = reference.get(transaction=transaction)
            if snapshot.exists:
                return
            transaction.set(reference, {"uid": uid, "kind": kind if kind in KINDS else None, "outcome": outcome,
                                        "reason": reason, "decidedAt": firestore.SERVER_TIMESTAMP, "attempts": 1})

        write(access.db.transaction(max_attempts=5))

    @staticmethod
    def _parse(item: Mapping[str, Any], item_id: str) -> dict[str, Any]:
        kind = item.get("kind")
        if kind not in KINDS:
            raise Refused("invalid")
        session_id = item.get("workSessionId")
        generation = item.get("workSessionGeneration")
        if not isinstance(session_id, str) or not _SESSION_ID.fullmatch(session_id):
            raise Refused("invalid")
        if not _integer(generation) or generation < 1:
            raise Refused("invalid")
        parsed = {"id": item_id, "kind": kind, "workSessionId": session_id, "workSessionGeneration": generation,
                  "deviceAt": _moment(item.get("deviceAt"))}
        if kind == "session_start":
            if set(item) - {"kind", "id", "workSessionId", "workSessionGeneration", "deviceAt"} or item_id != session_id:
                raise Refused("invalid")
            return parsed
        payload = item.get("payload", {})
        if not isinstance(payload, dict):
            raise Refused("invalid")
        parsed["payload"] = payload
        if kind == "order":
            if set(item) - {"kind", "id", "workSessionId", "workSessionGeneration", "deviceAt", "payload"} \
                    or "~" in item_id:
                raise Refused("invalid")
            return parsed
        allowed = {"kind", "id", "workSessionId", "workSessionGeneration", "deviceAt", "planId", "stopId", "status",
                   "sessionEventSequence", "payload"}
        plan_id, stop_id = item.get("planId"), item.get("stopId")
        stop_status, sequence = item.get("status"), item.get("sessionEventSequence")
        if (set(item) - allowed or not isinstance(plan_id, str) or not _PLAN_ID.fullmatch(plan_id)
                or not isinstance(stop_id, str) or not 1 <= len(stop_id) <= 300 or stop_status not in STOP_STATUSES
                or not _integer(sequence) or sequence < 1):
            raise Refused("invalid")
        if item_id != f"{session_id}_{stop_id}_{stop_status}" or len(item_id) > 100:
            raise Refused("invalid")
        parsed.update({"planId": plan_id, "stopId": stop_id, "status": stop_status, "sessionEventSequence": sequence})
        return parsed

    @staticmethod
    def _session(read: Callable[[Any], Any], db: Any, uid: str, parsed: Mapping[str, Any]) -> dict[str, Any]:
        session_id = parsed["workSessionId"]
        live = read(db.collection(LIVE_TRACKING).document(uid)).to_dict() or {}
        held = read(db.collection(HELD_SESSIONS).document(f"{uid}_{session_id}")).to_dict() or {}
        session: dict[str, Any] = {"serverStartedAt": held.get("serverStartedAt"), "deviceAt": held.get("deviceAt"),
                                   "generation": held.get("workSessionGeneration")}
        if live.get("activeSessionId") == session_id:
            if isinstance(live.get("workSessionStartedAt"), datetime):
                session["serverStartedAt"] = live["workSessionStartedAt"]
            session["generation"] = live.get("activeSessionGeneration")
        if session["generation"] is not None and session["generation"] != parsed["workSessionGeneration"]:
            raise Refused("invalid")
        return session

    def _session_start(self, transaction: firestore.Transaction, db: Any, uid: str, actor: Mapping[str, Any],
                       parsed: Mapping[str, Any], stamp: Mapping[str, Any], read: Callable[[Any], Any]) -> str:
        reference = db.collection(HELD_SESSIONS).document(f"{uid}_{parsed['workSessionId']}")
        session = self._session(read, db, uid, parsed)
        recorded = session.get("deviceAt")
        if isinstance(recorded, datetime):
            if recorded != parsed["deviceAt"]:
                raise Refused("invalid")
            return "duplicate"
        started = session.get("serverStartedAt")
        if isinstance(started, datetime) and parsed["deviceAt"] < started - SESSION_START_LAG:
            raise Refused("before_session")
        candidate = {**session, "deviceAt": parsed["deviceAt"]}
        reason = drain_decision(stamp, candidate, None, self.clock())
        if reason is not None:
            raise Refused(reason)
        device_only = not isinstance(started, datetime)
        transaction.set(reference, {"uid": uid, "workSessionId": parsed["workSessionId"],
                                    "workSessionGeneration": parsed["workSessionGeneration"],
                                    "deviceAt": parsed["deviceAt"], "recordedAt": firestore.SERVER_TIMESTAMP,
                                    "deviceTimeOnly": device_only},
                        merge=True)
        if device_only:
            parsed["deviceTimeOnly"] = True
            transaction.set(db.collection(AUDIT_LOGS).document(f"held_session_{uid}_{parsed['workSessionId']}"), {
                "action": "held_work_device_time_only",
                "entityType": HELD_SESSIONS,
                "entityId": f"{uid}_{parsed['workSessionId']}",
                "summary": "Held work was accepted for a work session that has no start time recorded by the server. "
                           "The start time came only from the phone.",
                "actorUid": uid, "actorEmail": "", "actorName": "", "actorRole": "salesman",
                "metadata": {"workSessionId": parsed["workSessionId"], "deviceAt": parsed["deviceAt"].isoformat()},
                "createdAt": firestore.SERVER_TIMESTAMP,
            }, merge=True)
        return "accepted"

    def _stop_event(self, transaction: firestore.Transaction, db: Any, uid: str, actor: Mapping[str, Any],
                    parsed: Mapping[str, Any], stamp: Mapping[str, Any], read: Callable[[Any], Any]) -> str:
        plan_id, stop_id, stop_status = parsed["planId"], parsed["stopId"], parsed["status"]
        stop_ref = db.collection("route_stop_progress").document(canonical_stop_id(plan_id, uid, stop_id))
        parent_ref = db.collection("route_plan_progress").document(f"{plan_id}_{uid}")
        route_ref = db.collection("route_plans").document(plan_id)
        stop_snapshot = read(stop_ref)
        prior = stop_snapshot.to_dict() if stop_snapshot.exists else None
        if prior is not None and parsed["id"] in (prior.get("eventId"), prior.get("arrivalEventId")):
            if prior.get("salesmanUid") != uid:
                raise Refused("invalid")
            return "duplicate"
        parent_snapshot = read(parent_ref)
        route_snapshot = read(route_ref)
        session = self._session(read, db, uid, parsed)
        now = self.clock()
        reason = drain_decision(stamp, session, parsed["deviceAt"], now)
        if reason is not None:
            raise Refused(reason)
        if not isinstance(session.get("serverStartedAt"), datetime):
            parsed["deviceTimeOnly"] = True
        route = route_snapshot.to_dict() or {}
        code, branch = actor["code"], _text(route, "branchId", "branch_id")
        stop_ids = route.get("stopIds")
        retailer_ids = route.get("stopRetailerIds")
        parent = parent_snapshot.to_dict() or {}
        started = parent if parent_snapshot.exists else None
        if not route_snapshot.exists or not _route_owned(route, uid, code, started, now) or not isinstance(stop_ids, list) \
                or stop_id not in stop_ids or not isinstance(retailer_ids, dict) \
                or not isinstance(retailer_ids.get(stop_id), str) or not retailer_ids[stop_id]:
            raise Refused("not_on_plan")
        retailer_id = retailer_ids[stop_id]
        week = route.get("weekStart")
        if "weekStart" in route and not (isinstance(week, datetime) and now >= week):
            raise Refused("invalid")
        if (not code or not parent_snapshot.exists or parent.get("progressId") != f"{plan_id}_{uid}"
                or parent.get("salesmanUid") != uid or parent.get("planId") != plan_id
                or _text(parent, "salesmanCode", "salesman_code") != code
                or _text(parent, "branchId", "branch_id") != branch
                or len(set(stop_ids)) != len(stop_ids) or not 0 < len(stop_ids) <= 100):
            raise Refused("invalid")
        entries = parent.get("stopProgress", {})
        entry = entries.get(stop_id, {}) if isinstance(entries, dict) else {}
        entry = entry if isinstance(entry, dict) else {}
        if entry.get("status") in ("completed", "skipped") or (prior or {}).get("status") in ("completed", "skipped"):
            raise Refused("invalid")
        document = self._stop_document(transaction, db, uid, code, branch, retailer_id, route, parent, entry, prior,
                                       parsed, now)
        patch = self._parent_patch(parent, stop_ids, parsed)
        document.update({"serverReceivedAt": firestore.SERVER_TIMESTAMP, "source": SOURCE})
        transaction.set(stop_ref, document)
        transaction.update(parent_ref, patch)
        return "accepted"

    def _stop_document(self, transaction: firestore.Transaction, db: Any, uid: str, code: str, branch: str,
                       retailer_id: str, route: Mapping[str, Any], parent: Mapping[str, Any],
                       entry: Mapping[str, Any], prior: Mapping[str, Any] | None, parsed: Mapping[str, Any],
                       now: datetime) -> dict[str, Any]:
        stop_status, device_at = parsed["status"], parsed["deviceAt"]
        payload = {key: value for key, value in parsed["payload"].items() if key not in _STOP_PAYLOAD_SERVER_KEYS}
        allowed = {"arrived": _ARRIVAL_KEYS, "completed": _COMPLETE_KEYS, "skipped": _SKIP_KEYS}[stop_status]
        if set(payload) - allowed:
            raise Refused("invalid")
        if "notes" in payload and not (isinstance(payload["notes"], str) and len(payload["notes"]) <= 2000):
            raise Refused("invalid")
        if prior is None:
            if stop_status == "completed" and entry.get("status") != "arrived":
                raise Refused("invalid")
        elif stop_status == "arrived" or prior.get("status") != "arrived" or not self._monotonic(prior, parsed):
            raise Refused("invalid")
        document = dict(prior or {})
        document.update({
            "lifecycleSchemaVersion": 2, "planId": parsed["planId"], "salesmanUid": uid, "salesmanCode": code,
            "branchId": branch, "stopId": parsed["stopId"], "retailerId": retailer_id,
            "retailerName": route_retailer_name(route, parsed["stopId"]), "status": stop_status,
            "eventId": parsed["id"], "workSessionId": parsed["workSessionId"],
            "workSessionGeneration": parsed["workSessionGeneration"],
            "sessionEventSequence": parsed["sessionEventSequence"], "deviceOccurredAt": device_at,
            "receivedAt": firestore.SERVER_TIMESTAMP, "updatedAt": firestore.SERVER_TIMESTAMP,
        })
        if stop_status == "arrived":
            if parent.get("selectedStopId") != parsed["stopId"]:
                raise Refused("invalid")
            document.update(self._arrival_evidence(transaction, db, payload, retailer_id, route, parsed, now))
            document.update({
                "arrivedAt": device_at, "arrivalEventId": parsed["id"],
                "arrivalWorkSessionId": parsed["workSessionId"],
                "arrivalWorkSessionGeneration": parsed["workSessionGeneration"],
                "arrivalSessionEventSequence": parsed["sessionEventSequence"],
                "arrivalDeviceOccurredAt": device_at, "arrivalReceivedAt": firestore.SERVER_TIMESTAMP,
            })
            return document
        if stop_status == "skipped":
            reason = payload.get("skipReason")
            if not isinstance(reason, str) or not 1 <= len(reason) <= 300:
                raise Refused("invalid")
            document["skippedAt"] = device_at
        else:
            document["completedAt"] = device_at
        document.update(payload)
        if prior is None:
            self._import_legacy_arrival(document, entry)
        return document

    @staticmethod
    def _monotonic(prior: Mapping[str, Any], parsed: Mapping[str, Any]) -> bool:
        old_generation = prior.get("workSessionGeneration", 0)
        old_sequence = prior.get("sessionEventSequence", 0)
        if not _integer(old_generation) or not _integer(old_sequence):
            return False
        generation = parsed["workSessionGeneration"]
        return generation >= old_generation and (
            generation > old_generation
            or (parsed["workSessionId"] == prior.get("workSessionId") and parsed["sessionEventSequence"] > old_sequence)
        )

    @staticmethod
    def _import_legacy_arrival(document: dict[str, Any], entry: Mapping[str, Any]) -> None:
        if "arrivalMode" in document or entry.get("status") != "arrived":
            return
        evidence = entry.get("arrivalEvidence")
        if isinstance(evidence, dict):
            document["legacyArrivalEvidence"] = dict(evidence)
            for source, target in (("mode", "arrivalMode"), ("failureCode", "arrivalFailureCode"),
                                   ("overrideReasonCode", "overrideReasonCode"), ("overrideNote", "overrideNote")):
                if evidence.get(source) is not None:
                    document[target] = evidence[source]
            for source, target in (("latitude", "arrivalLatitude"), ("longitude", "arrivalLongitude"),
                                   ("accuracyMeters", "arrivalAccuracyMeters"),
                                   ("distanceMeters", "arrivalDistanceMeters"), ("isMocked", "arrivalIsMocked")):
                if source in evidence:
                    document[target] = evidence[source]
            if evidence.get("deviceCapturedAt") is not None:
                document["arrivalDeviceCapturedAt"] = evidence["deviceCapturedAt"]
        if entry.get("arrivedAt") is not None:
            document["arrivedAt"] = entry["arrivedAt"]

    @staticmethod
    def _arrival_evidence(transaction: firestore.Transaction, db: Any, payload: Mapping[str, Any], retailer_id: str,
                          route: Mapping[str, Any], parsed: Mapping[str, Any], now: datetime) -> dict[str, Any]:
        evidence = dict(payload)
        for key in _ARRIVAL_MOMENTS:
            if key in evidence:
                evidence[key] = _moment(evidence[key])
        mode = evidence.get("arrivalMode")
        revision, source = evidence.get("retailerCoordinateRevision"), evidence.get("retailerCoordinateSource")
        if not isinstance(revision, str) or not isinstance(source, str):
            raise Refused("invalid")
        if mode == "manual_unverified":
            note = evidence.get("overrideNote")
            if not (evidence.get("coordinateReferenceMode") == "unverified" and revision == "" and source == ""
                    and evidence.get("arrivalFailureCode") in _FAILURE_CODES
                    and evidence.get("overrideReasonCode") in _OVERRIDE_CODES
                    and isinstance(note, str) and 3 <= len(note) <= 300
                    and all(_number(evidence[key]) for key in _MANUAL_NUMBERS if key in evidence)
                    and isinstance(evidence.get("arrivalIsMocked", False), bool)):
                raise Refused("invalid")
            return evidence
        if mode != "location_verified":
            raise Refused("invalid")
        reference = evidence.get("coordinateReferenceMode")
        latitude, longitude = evidence.get("arrivalLatitude"), evidence.get("arrivalLongitude")
        accuracy, distance = evidence.get("arrivalAccuracyMeters"), evidence.get("arrivalDistanceMeters")
        if not (reference in ("current_retailer", "published_snapshot_offline") and 1 <= len(revision) <= 1024
                and len(source) <= 100 and _valid_coordinates(latitude, longitude)
                and _number(accuracy) and 0 <= accuracy <= 25 and _number(distance) and 0 <= distance <= 75
                and evidence.get("arrivalDeviceCapturedAt") == parsed["deviceAt"]
                and evidence.get("arrivalIsMocked") is False and "arrivalFailureCode" not in evidence):
            raise Refused("invalid")
        if reference == "current_retailer":
            checked = evidence.get("coordinateCheckedAt")
            if not isinstance(checked, datetime) or checked > now + timedelta(minutes=60):
                raise Refused("invalid")
            retailer_snapshot = db.collection("retailers").document(retailer_id).get(transaction=transaction)
            retailer = retailer_snapshot.to_dict() or {}
            status_text = retailer.get("coordinateStatus", "")
            review_text = retailer.get("coordinateReviewStatus", "")
            if not isinstance(status_text, str) or not isinstance(review_text, str):
                raise Refused("invalid")
            coordinate_status, review_status = status_text.lower(), review_text.lower()
            coordinate_source = retailer.get("coordinateSource", "")
            target_lat = next((retailer[key] for key in ("latitude", "lat", "gpsLatitude", "gps_latitude")
                               if key in retailer), None)
            target_lng = next((retailer[key] for key in ("longitude", "lng", "gpsLongitude", "gps_longitude")
                               if key in retailer), None)
            verified = coordinate_status == "verified" or (coordinate_status == "" and (
                review_status in ("reviewed", "verified") or coordinate_source == "admin_review"))
            if not (verified and _valid_coordinates(target_lat, target_lng) and coordinate_source == source):
                raise Refused("invalid")
        else:
            snapshot_at = evidence.get("coordinateSnapshotAt")
            published = route.get("publishedAt")
            snapshots = route.get("stopCoordinateSnapshots", {})
            snapshot = snapshots.get(parsed["stopId"], {}) if isinstance(snapshots, dict) else {}
            if not (isinstance(snapshot_at, datetime) and isinstance(published, datetime) and snapshot_at == published
                    and snapshot_at <= now and isinstance(snapshot, dict)
                    and snapshot.get("retailerId", "") == retailer_id
                    and isinstance(snapshot.get("coordinateStatus", ""), str)
                    and snapshot.get("coordinateStatus", "").lower() == "verified"
                    and _valid_coordinates(snapshot.get("latitude"), snapshot.get("longitude"))
                    and snapshot.get("coordinateRevision", "") == revision
                    and snapshot.get("coordinateSource", "") == source):
                raise Refused("invalid")
            target_lat, target_lng = snapshot["latitude"], snapshot["longitude"]
        if distance_meters(latitude, longitude, target_lat, target_lng) > 75:
            raise Refused("invalid")
        return evidence

    @staticmethod
    def _parent_patch(parent: Mapping[str, Any], stop_ids: list[Any], parsed: Mapping[str, Any]) -> dict[str, Any]:
        stop_id, stop_status = parsed["stopId"], parsed["status"]
        generation, sequence = parsed["workSessionGeneration"], parsed["sessionEventSequence"]
        old_status = parent.get("status")
        session_state = parent.get("routeSessionState", "untracked")
        handled = parent.get("handledStopIds", [])
        if not isinstance(handled, list) or len(set(map(str, handled))) != len(handled):
            raise Refused("invalid")
        patch: dict[str, Any] = {
            "lastStopWriteStopId": stop_id, "lastStopWriteStatus": stop_status, "lastStopWriteEventId": parsed["id"],
            "lastStopWriteWorkSessionGeneration": generation, "lastStopWriteSequence": sequence,
            "updatedAt": firestore.SERVER_TIMESTAMP, "lastSyncedAt": firestore.SERVER_TIMESTAMP,
        }
        old_generation = _nonnegative(parent.get("lastSummaryWorkSessionGeneration"))
        old_sequence = _nonnegative(parent.get("lastSummaryEventSequence"))
        if generation > old_generation or (generation == old_generation and sequence > old_sequence):
            patch.update({"lastStopId": stop_id, "lastStopStatus": stop_status, "lastStopEventId": parsed["id"],
                          "lastSummaryWorkSessionGeneration": generation, "lastSummaryEventSequence": sequence})
        if stop_status == "arrived":
            next_status = "in_progress"
        else:
            if stop_id in handled:
                raise Refused("invalid")
            handled = [*handled, stop_id]
            if not set(handled) <= set(stop_ids):
                raise Refused("invalid")
            patch["handledStopIds"] = handled
            next_status = "completed" if set(handled) >= set(stop_ids) else "in_progress"
            if parent.get("selectedStopId") == stop_id:
                revision = parent.get("selectionRevision", 0)
                if not _integer(revision):
                    raise Refused("invalid")
                patch["selectedStopId"] = firestore.DELETE_FIELD
                patch["selectionRevision"] = revision + 1
        if old_status == "in_progress" and next_status == "completed":
            if session_state in ("active", "paused"):
                patch["routeSessionState"] = "completed"
            elif session_state not in ("completed", "untracked"):
                raise Refused("invalid")
        elif old_status == "accepted" and next_status == "in_progress":
            if session_state not in ("active", "untracked"):
                raise Refused("invalid")
        elif old_status == "accepted" and next_status == "completed":
            if session_state not in ("active", "untracked"):
                raise Refused("invalid")
            if session_state == "active":
                patch["routeSessionState"] = "completed"
            if parent.get("startedAt") is None:
                patch["startedAt"] = firestore.SERVER_TIMESTAMP
        elif old_status != next_status or old_status != "in_progress":
            raise Refused("invalid")
        patch["status"] = next_status
        return patch

    def _order(self, transaction: firestore.Transaction, db: Any, uid: str, actor: Mapping[str, Any],
               parsed: Mapping[str, Any], stamp: Mapping[str, Any], read: Callable[[Any], Any]) -> str:
        stored_id = parsed["id"]
        existing = read(db.collection("orders").document(stored_id))
        if existing.exists:
            if (existing.to_dict() or {}).get("salesmanUid") == uid:
                parsed["storedAs"] = stored_id
                return "duplicate"
            stored_id = own_order_id(uid, parsed["id"])
            if read(db.collection("orders").document(stored_id)).exists:
                parsed["storedAs"] = stored_id
                return "duplicate"
        reference = db.collection("orders").document(stored_id)
        payload = parsed["payload"]
        self._check_order_shape(payload)
        route_snapshot = progress_snapshot = None
        plan_id = payload.get("routePlanId")
        if isinstance(plan_id, str) and _ORDER_PLAN.fullmatch(plan_id):
            route_snapshot = read(db.collection("route_plans").document(plan_id))
            progress_snapshot = read(db.collection("route_plan_progress").document(f"{plan_id}_{uid}"))
        session = self._session(read, db, uid, parsed)
        now = self.clock()
        reason = drain_decision(stamp, session, parsed["deviceAt"], now)
        if reason is not None:
            raise Refused(reason)
        device_time_only = not isinstance(session.get("serverStartedAt"), datetime)
        order = self._order_document(uid, actor, parsed, route_snapshot, progress_snapshot, now)
        order["orderId"] = stored_id
        if device_time_only:
            order.update({"status": HELD_FOR_REVIEW, "reviewReason": REVIEW_UNKNOWN_SESSION,
                          "reviewNote": REVIEW_UNKNOWN_SESSION_TEXT})
        transaction.create(reference, order)
        parsed["storedAs"] = stored_id
        if device_time_only:
            parsed["deviceTimeOnly"] = True
        return "accepted"

    @staticmethod
    def _order_document(uid: str, actor: Mapping[str, Any], parsed: Mapping[str, Any], route_snapshot: Any,
                        progress_snapshot: Any, now: datetime) -> dict[str, Any]:
        payload = parsed["payload"]
        if "serverPriceCheck" in payload:
            raise Refused("invalid")
        has_coordinates = any(key in payload for key in _ORDER_COORDINATE_KEYS)
        order = {key: value for key, value in payload.items() if key not in _ORDER_SERVER_KEYS}
        if "deviceCapturedAt" in order:
            order["deviceCapturedAt"] = _moment(order["deviceCapturedAt"])
        evidence = order.get("locationEvidence")
        if isinstance(evidence, dict):
            evidence = dict(evidence)
            if "deviceCapturedAt" in evidence:
                evidence["deviceCapturedAt"] = _moment(evidence["deviceCapturedAt"])
            order["locationEvidence"] = evidence
        code, branch = actor["code"], actor["branch"]
        order.update({
            "orderId": parsed["id"], "uid": uid, "userUid": uid, "salesmanUid": uid, "submittedByUid": uid,
            "createdByUid": uid, "salesmanCode": code, "status": "submitted",
            "submittedAt": firestore.SERVER_TIMESTAMP, "createdAt": firestore.SERVER_TIMESTAMP,
            "updatedAt": firestore.SERVER_TIMESTAMP, "serverReceivedAt": firestore.SERVER_TIMESTAMP, "source": SOURCE,
        })
        if branch:
            order["branchId"] = branch
        scoped = _text(order, "salesmanCode", "salesman_code") or _text(order, "salesmanId", "salesman_id") or _text(
            order, "staffId", "employeeCode")
        if scoped != code:
            raise Refused("invalid")
        HeldWork._check_order_commercials(order)
        if order.get("visitSource") == "assigned_route" or "routePlanId" in order or "routeStopId" in order:
            HeldWork._check_assigned_order(uid, code, order, parsed["id"], route_snapshot, progress_snapshot, now)
        elif parsed["id"].startswith("ORD-V2-"):
            raise Refused("invalid")
        if has_coordinates:
            latitude, longitude = order.get("latitude"), order.get("longitude")
            if not _valid_coordinates(latitude, longitude):
                raise Refused("invalid")
            order["location"] = GeoPoint(latitude, longitude)
            order["locationCapturedAt"] = firestore.SERVER_TIMESTAMP
            HeldWork._check_order_location(order, now)
        elif "locationEvidence" in order:
            evidence = order["locationEvidence"]
            if not isinstance(evidence, dict) or evidence.get("mode") != "not_verified":
                raise Refused("invalid")
            if any(key in evidence for key in _FIX_KEYS) and not HeldWork._valid_fix(evidence, 10000, now):
                raise Refused("invalid")
        return order

    @staticmethod
    def _check_order_shape(payload: Mapping[str, Any]) -> None:
        names = [payload.get(key, "") for key in _ORDER_NAME_KEYS]
        stamps = payload.get("signatureTimestamps", {})
        evidence = payload.get("locationEvidence", {})
        if not (set(payload) <= _ORDER_CREATE_KEYS
                and all(isinstance(name, str) for name in names) and sum(map(len, names)) <= 2000
                and isinstance(payload.get("salesmanId", ""), str) and len(payload.get("salesmanId", "")) <= 100
                and isinstance(stamps, dict) and len(stamps) <= 30
                and all(isinstance(stamp, str) for stamp in stamps.values())
                and _SIGNATURE_STAMPS.fullmatch("|".join(stamps.values()))
                and isinstance(evidence, dict)
                and isinstance(evidence.get("failureCode", ""), str)
                and _FAILURE_CODE.fullmatch(evidence.get("failureCode", ""))):
            raise Refused("invalid")

    @staticmethod
    def _check_order_commercials(order: Mapping[str, Any]) -> None:
        retailer_id, items, lines = order.get("retailerId"), order.get("items"), order.get("commercialLines")
        total_boxes, total_price = order.get("totalBoxes"), order.get("totalPrice")
        if not (order.get("visitSource") in ("assigned_route", "personal_planner")
                and isinstance(retailer_id, str) and retailer_id.strip() and len(retailer_id) <= 200
                and isinstance(items, list) and 1 <= len(items) <= 25
                and isinstance(lines, list) and all(isinstance(line, str) for line in lines)
                and order.get("commercialSchemaVersion") == 1 and 1 <= len(lines) <= 25
                and len(",".join(lines)) <= 25500 and all(_COMMERCIAL_LINE.fullmatch(line) for line in lines)
                and parse_commercial_lines(order)[0] is not None
                and len(lines) == len(items) and order.get("totalProducts") == len(lines)
                and _integer(total_boxes) and 1 <= total_boxes <= 24975
                and _number(total_price) and 0 < total_price <= 10_000_000):
            raise Refused("invalid")

    @staticmethod
    def _check_assigned_order(uid: str, code: str, order: Mapping[str, Any], order_id: str, route_snapshot: Any,
                              progress_snapshot: Any, now: datetime) -> None:
        plan_id, stop_id = order.get("routePlanId"), order.get("routeStopId")
        if not (order.get("visitSource") == "assigned_route" and _ORDER_UID.fullmatch(uid)
                and isinstance(plan_id, str) and _ORDER_PLAN.fullmatch(plan_id)
                and isinstance(stop_id, str) and _ORDER_STOP.fullmatch(stop_id)
                and order_id == f"ORD-V2-{uid}.{plan_id}.{stop_id}"):
            raise Refused("invalid")
        route = route_snapshot.to_dict() if route_snapshot is not None and route_snapshot.exists else None
        progress = progress_snapshot.to_dict() if progress_snapshot is not None and progress_snapshot.exists else None
        if route is None or not _route_owned(route, uid, code, progress, now):
            raise Refused("not_on_plan")
        retailer_ids = route.get("stopRetailerIds")
        if "stopRetailerIds" in route and not (isinstance(retailer_ids, dict)
                                               and retailer_ids.get(stop_id, "") == order["retailerId"]):
            raise Refused("not_on_plan")

    @staticmethod
    def _valid_fix(data: Mapping[str, Any], max_accuracy: float, now: datetime) -> bool:
        accuracy, captured = data.get("accuracyMeters"), data.get("deviceCapturedAt")
        return (_valid_coordinates(data.get("latitude"), data.get("longitude"))
                and _number(accuracy) and 0 <= accuracy <= max_accuracy
                and isinstance(captured, datetime) and captured <= now + timedelta(minutes=5)
                and isinstance(data.get("isMocked"), bool))

    @staticmethod
    def _check_order_location(order: Mapping[str, Any], now: datetime) -> None:
        evidence = order.get("locationEvidence")
        if not (all(key in order for key in _ORDER_LOCATION_KEYS)
                and HeldWork._valid_fix(order, 100, now)
                and order.get("gpsLatitude") == order["latitude"] and order.get("gpsLongitude") == order["longitude"]
                and _number(order.get("accuracy")) and order["accuracy"] == order["accuracyMeters"]
                and order.get("isMocked") is False
                and order.get("locationVerification") in ("device_captured", "location_verified")
                and isinstance(evidence, dict) and evidence.get("mode") == order["locationVerification"]
                and all(evidence.get(key) == order[key] for key in _FIX_KEYS)):
            raise Refused("invalid")


def install_held_work_route(
    app: FastAPI,
    *,
    directory: DirectoryStore,
    access_for: Callable[[Mapping[str, Any]], CompanyAccess],
    identity: Callable[..., auth.ClientIdentity],
    database: Any = None,
    clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
) -> None:
    service = HeldWork(directory, access_for, clock, database)

    @app.post("/v1/w/{workspace}/held-work")
    async def held_work(workspace: str, request: Request,
                        who: auth.ClientIdentity = Depends(identity)) -> JSONResponse:
        context = await run_in_threadpool(service.admit, workspace, who)
        declared = request.headers.get("content-length")
        if declared is not None and (not declared.isdigit() or int(declared) > MAX_BODY_BYTES):
            raise HTTPException(413, BODY_LIMIT_TEXT)
        received = bytearray()
        async for chunk in request.stream():
            received += chunk
            if len(received) > MAX_BODY_BYTES:
                raise HTTPException(413, BODY_LIMIT_TEXT)
        raw = bytes(received)
        try:
            body = await run_in_threadpool(json.loads, raw)
        except ValueError:
            raise HTTPException(422, "The body must be JSON.") from None
        items = body.get("items") if isinstance(body, dict) else None
        if not isinstance(body, dict) or set(body) != {"items"} or not isinstance(items, list) \
                or not 1 <= len(items) <= MAX_ITEMS:
            raise HTTPException(422,
                                f"Send 1 to {MAX_ITEMS} held items in an items list.")
        reservation = await run_in_threadpool(service.reserve, context, len(items))
        try:
            result = await run_in_threadpool(service.handle, context, who, items)
        except BaseException:
            await run_in_threadpool(service.refund, reservation, len(items))
            raise
        await run_in_threadpool(service.refund, reservation, service.unspent(result["results"]))
        return JSONResponse(result, headers=_NO_STORE)

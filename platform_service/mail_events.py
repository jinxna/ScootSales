from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Mapping

from fastapi import Body, Depends, FastAPI, HTTPException, Request, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from google.cloud import firestore

from . import auth
from .audit import AuditLog
from .mail import (DELIVERY_EVENTS, DELIVERY_FAILED, PERMANENT_FAILURES, STAFF_MAIL_TENANT, SUPPRESSIONS, MailQueue, address_key,
                   company_contact, company_suppression_key)
from .signing import format_timestamp
from .staff import mask

WEBHOOK_SECRET_ENV = "PLATFORM_BREVO_WEBHOOK_SECRET"
PROCESSED = "mail_events"
DELIVERY_STATUSES = frozenset({"delivered", "soft_bounce", "hard_bounce", "blocked", "spam", "invalid_email"})
SUPPRESSING = PERMANENT_FAILURES
MAX_EVENTS = 100
EVENT_HISTORY = 20
MIN_SECRET = 24
_JOB = re.compile(r"^[0-9a-f]{64}$")
_CAMEL = re.compile(r"(?<!^)(?=[A-Z])")
_NO_STORE = {"Cache-Control": "no-store"}


@dataclass(frozen=True)
class DeliveryEvent:
    key: str
    status: str
    at: str
    email: str
    message_id: str
    job_hint: str
    reason: str


def webhook_secret() -> str:
    secret = os.environ.get(WEBHOOK_SECRET_ENV, "").strip()
    return secret if len(secret) >= MIN_SECRET else ""


def _presented_secret(header: str | None) -> str:
    scheme, _, value = (header or "").partition(" ")
    if scheme.lower() == "bearer":
        return value.strip()
    if scheme.lower() == "basic":
        try:
            decoded = base64.b64decode(value.strip(), validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError):
            return ""
        return decoded.partition(":")[2]
    return ""


def _moment(raw: Mapping[str, Any]) -> datetime | None:
    for name, scale in (("ts_epoch", 1000), ("ts_event", 1), ("ts", 1)):
        value = raw.get(name)
        if type(value) is int and value > 0:
            try:
                return datetime.fromtimestamp(value / scale, tz=timezone.utc)
            except (OverflowError, OSError, ValueError):
                return None
    return None


def parse_event(raw: Any, received: datetime) -> DeliveryEvent | None:
    if not isinstance(raw, Mapping) or not isinstance(raw.get("event"), str):
        return None
    status_name = _CAMEL.sub("_", raw["event"].strip()).lower()
    if status_name not in DELIVERY_STATUSES:
        return None
    message_id = raw.get("message-id", raw.get("messageId", ""))
    hint = raw.get("X-Mailin-custom", "")
    email = raw.get("email", "")
    if not all(isinstance(value, str) for value in (message_id, hint, email)):
        return None
    message_id = message_id.strip().strip("<>")[:300]
    hint = hint.strip()[:128]
    if not message_id and not _JOB.fullmatch(hint):
        return None
    moment = _moment(raw) or received
    reason = raw.get("reason")
    identity = json.dumps([status_name, message_id, hint, email.strip().lower(), format_timestamp(moment)])
    return DeliveryEvent(key=hashlib.sha256(identity.encode("utf-8")).hexdigest(), status=status_name,
                         at=format_timestamp(moment), email=email.strip().lower()[:320], message_id=message_id,
                         job_hint=hint, reason=reason.strip()[:200] if isinstance(reason, str) else "")


def _job_reference(db: firestore.Client, event: DeliveryEvent) -> Any | None:
    jobs = db.collection("mail_jobs")
    if _JOB.fullmatch(event.job_hint):
        reference = jobs.document(event.job_hint)
        if reference.get().exists:
            return reference
    if not event.message_id:
        return None
    for candidate in (event.message_id, f"<{event.message_id}>"):
        for snapshot in jobs.where(filter=firestore.FieldFilter("providerMessageId", "==", candidate)).limit(2).stream():
            return snapshot.reference
    return None


def record_event(db: firestore.Client, event: DeliveryEvent) -> str:
    reference = _job_reference(db, event)
    if reference is None:
        return "ignored"
    marker = db.collection(PROCESSED).document(event.key)

    @firestore.transactional
    def write(transaction: firestore.Transaction) -> str:
        if marker.get(transaction=transaction).exists:
            return "duplicate"
        job = reference.get(transaction=transaction).to_dict() or {}
        if not job or (event.email and job.get("recipient") != event.email):
            return "ignored"
        address = address_key(job["recipient"])
        suppression_ref = db.collection(SUPPRESSIONS).document(
            company_suppression_key(job["tenantId"], address) if event.status == "spam" else address)
        suppression = suppression_ref.get(transaction=transaction).to_dict() or {}
        history = [*(job.get("deliveryEvents") or []), {"event": event.status, "at": event.at, "reason": event.reason}]
        changes: dict[str, Any] = {"deliveryEvents": history[-EVENT_HISTORY:]}
        if event.status in DELIVERY_EVENTS and job.get("deliveryStatus") not in DELIVERY_FAILED and (
                event.status in DELIVERY_FAILED or (job.get("deliveryStatusAt") or "") <= event.at):
            changes.update({"deliveryStatus": event.status, "deliveryStatusAt": event.at,
                            "deliveryReason": event.reason})
        transaction.update(reference, changes)
        transaction.create(marker, {"jobId": job["jobId"], "event": event.status, "at": event.at,
                                    "recordedAt": format_timestamp(datetime.now(timezone.utc))})
        if event.status in SUPPRESSING and (suppression.get("liftedAt") or "") < event.at:
            active = suppression.get("status") == "active"
            transaction.set(suppression_ref, {
                "suppressionId": suppression_ref.id, "addressKey": address, "status": "active", "reason": event.status,
                "recipientHint": mask(job["recipient"]), "tenantId": job["tenantId"], "jobId": job["jobId"],
                "kind": job["kind"], "since": suppression["since"] if active else event.at,
                "lastEventAt": max(event.at, suppression.get("lastEventAt") or ""),
                "liftedAt": suppression.get("liftedAt"), "liftedBy": suppression.get("liftedBy"),
                "liftReason": suppression.get("liftReason")})
        return "accepted"

    return write(db.transaction(max_attempts=10))


def suppression_view(data: Mapping[str, Any], company_name: str) -> dict[str, Any]:
    return {"suppressionId": data["suppressionId"], "recipient": data["recipientHint"], "reason": data["reason"],
            "since": data["since"], "lastEventAt": data["lastEventAt"], "tenantId": data["tenantId"],
            "companyName": company_name, "kind": data["kind"], "status": data["status"],
            "liftedAt": data.get("liftedAt"), "liftedBy": data.get("liftedBy")}


def install_mail_event_routes(app: FastAPI, *, database: firestore.Client, audit: AuditLog,
                              operator_staff: Callable[..., auth.StaffIdentity]) -> None:
    names: dict[str, str] = {}

    def company_name(tenant_id: str) -> str:
        if tenant_id == STAFF_MAIL_TENANT:
            return "Control Centre"
        if tenant_id not in names:
            contact = company_contact(database, tenant_id)
            names[tenant_id] = contact[0] if contact else tenant_id
        return names[tenant_id]

    @app.post("/v1/mail/brevo-events")
    async def brevo_events(request: Request) -> JSONResponse:
        secret = webhook_secret()
        if not secret:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Mail events are not set up.")
        if not hmac.compare_digest(_presented_secret(request.headers.get("authorization")).encode("utf-8"),
                                   secret.encode("utf-8")):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Mail events need the shared secret.")
        try:
            body = await request.json()
        except ValueError:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Send JSON.") from None
        rows = body if isinstance(body, list) else [body]
        if len(rows) > MAX_EVENTS:
            raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, f"Send at most {MAX_EVENTS} events.")
        received = datetime.now(timezone.utc)

        def record_all() -> dict[str, int]:
            counts = {"accepted": 0, "duplicate": 0, "ignored": 0}
            for raw in rows:
                event = parse_event(raw, received)
                counts["ignored" if event is None else record_event(database, event)] += 1
            return counts

        return JSONResponse(await run_in_threadpool(record_all), headers=_NO_STORE)

    @app.get("/staff/v1/mail/suppressions")
    def list_suppressions(_: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        rows = [snapshot.to_dict() or {} for snapshot in database.collection(SUPPRESSIONS).where(
            filter=firestore.FieldFilter("status", "==", "active")).stream()]
        rows.sort(key=lambda row: (row.get("lastEventAt", ""), row.get("suppressionId", "")), reverse=True)
        return JSONResponse({"suppressions": [suppression_view(row, company_name(row["tenantId"])) for row in rows]},
                            headers=_NO_STORE)

    @app.post("/staff/v1/mail/suppressions/{suppression_id}/lift")
    def lift_suppression(suppression_id: str, body: dict[str, Any] = Body(...),
                         who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        reason = body.get("reason")
        if set(body) != {"reason"} or not isinstance(reason, str) or not 3 <= len(reason.strip()) <= 500:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Give a reason of 3 to 500 characters.")
        if not _JOB.fullmatch(suppression_id):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Unknown blocked address.")
        reference = database.collection(SUPPRESSIONS).document(suppression_id)
        moment = datetime.now(timezone.utc)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            current = reference.get(transaction=transaction).to_dict()
            if not current:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Unknown blocked address.")
            if current["status"] != "active":
                return current
            tenant_id = None if current["tenantId"] == STAFF_MAIL_TENANT else current["tenantId"]
            staged = audit.stage(transaction, moment, tenant_id=tenant_id)
            changes = {"status": "lifted", "liftedAt": format_timestamp(moment), "liftedBy": who.email,
                       "liftReason": reason.strip()}
            transaction.update(reference, changes)
            staged.add(actor=who.email, action="mail.suppression_lifted", tenant_id=tenant_id,
                       key=f"lift:{suppression_id}:{changes['liftedAt']}",
                       summary=f"Mail to {current['recipientHint']} is allowed again after a {current['reason']} event.",
                       refs={"suppressionId": suppression_id, "reason": reason.strip()})
            return {**current, **changes}

        lifted = write(database.transaction(max_attempts=10))
        if lifted.get("liftedBy") == who.email and lifted["liftedAt"] == format_timestamp(moment):
            MailQueue(database).release_unblocked(lifted.get("addressKey") or suppression_id, moment)
        return JSONResponse({"suppression": suppression_view(lifted, company_name(lifted["tenantId"]))},
                            headers=_NO_STORE)

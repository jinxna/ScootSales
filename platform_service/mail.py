from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol
from urllib.parse import urlsplit

import requests
from google.cloud import firestore

from . import auth, config, mail_render
from .ids import DUE_DAYS, KUALA_LUMPUR, local_date
from .signing import SignatureError, parse_timestamp


_EMAIL = re.compile(r"^[^\s@<>]{1,64}@[^\s@<>.]+(?:\.[^\s@<>.]+)+$")
_KEY = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
_TENANT = re.compile(r"^t_[a-z0-9]{6,32}$")
_JOB = re.compile(r"^[0-9a-f]{64}$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_CODE = re.compile(r"^\d{6}$")
_INTERVALS = frozenset({"monthly", "yearly"})
KINDS = frozenset(name for name in mail_render.template_names() if not name.startswith(f"{mail_render.STATUS_KIND}_")
                  ) | {mail_render.STATUS_KIND}
URGENT_KINDS = frozenset({"staff_signin_code", "invitation_email_code", "staff_notice", "staff_invite", "password_reset", "email_verification",
                          "signin_alert", "password_changed"})
ONE_TIME_KINDS = frozenset({"staff_signin_code", "invitation_email_code", "password_reset", "email_verification"})
SECRET_FIELDS = {"staff_signin_code": "code", "invitation_email_code": "code", "staff_invite": "inviteUrl", "password_reset": "resetUrl",
                 "email_verification": "verifyUrl"}
LINK_FIELDS = ("inviteUrl", "resetUrl", "verifyUrl")
SUPPRESSIONS = "mail_suppressions"
PERMANENT_FAILURES = frozenset({"hard_bounce", "blocked", "spam", "invalid_email"})
DELIVERY_FAILED = frozenset({"hard_bounce", "blocked", "invalid_email"})
DELIVERY_DELAYED = "soft_bounce"
DELIVERY_EVENTS = DELIVERY_FAILED | {DELIVERY_DELAYED, "delivered"}
_BOUNCE_REASONS = {
    "hard_bounce": "The address does not exist or refused the email.",
    "blocked": "The mail provider blocked the address.",
    "invalid_email": "The address is not valid."}
_JOB_PROBLEMS = {"held": "The email is on hold.", "failed": "The email could not be delivered.",
                 "uncertain": "The mail provider may or may not have delivered the email."}
ATTACHMENT_MAX_BYTES = 1_000_000
_ATTACHMENT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.pdf$")
_LOOPBACK = frozenset({"127.0.0.1", "localhost", "::1"})
DAILY_COUNTERS = "mail_daily"
NOT_SENT = frozenset({"queued", "failed", "held"})
STAFF_MAIL_TENANT = "t_platform"
TEMPLATE_IDS_ENV = "PLATFORM_BREVO_TEMPLATE_IDS"
STUB_FILE_ENV = "PLATFORM_MAIL_STUB_FILE"
STUB_DOWN_SUFFIX = ".down"
HELD_DAILY_CAP = "daily_cap"
HELD_TEMPLATE_MISSING = "template_missing"
HELD_PROVIDER_UNAVAILABLE = "provider_unavailable"
HELD_RECIPIENT_SUPPRESSED = "recipient_suppressed"
HELD_REASONS = (HELD_DAILY_CAP, HELD_TEMPLATE_MISSING, HELD_PROVIDER_UNAVAILABLE, HELD_RECIPIENT_SUPPRESSED)
STAFF_NOTICES = {
    "locked": "Sign-in for {person} is locked for {span} after too many wrong codes.",
    "backup_used": "{person} signed in to the Control Centre with a backup code.",
    "backup_created": "New backup codes were created for {person}.",
    "invited": "{actor} invited {person} to the Control Centre.",
    "bootstrapped": "{person} was added to the Control Centre as an owner from the bootstrap list.",
    "accepted": "{person} accepted an invitation to the Control Centre.",
    "role_changed": "{actor} changed the role of {person} in the Control Centre.",
    "disabled": "{actor} turned off the Control Centre account of {person}.",
}
DIGEST_COUNTS = ("paymentsToCheck", "approvalsWaiting", "invoicesToIssue", "invoicesToSend", "companiesPastDue",
                 "companiesGraceOver")
_PAYLOAD_FIELDS = {
    "invitation": ("companyName", "inviteUrl", "expiresAt"),
    "invoice": ("companyName", "invoiceNumber", "amountMinor", "currency", "periodStart", "periodEnd", "dueAt"),
    "receipt": ("companyName", "invoiceReference", "receiptNumber", "amountMinor", "currency", "paidAt"),
    "plan_request_received": ("companyName", "planName", "interval"),
    "plan_request_declined": ("companyName", "planName", "reason"),
    "plan_request_approved": ("companyName", "planName", "interval"),
    "plan_request_notice": ("companyName", "requesterEmail", "planName", "interval", "requestedAt"),
    "renewal_reminder": ("companyName", "expiresAt"),
    "past_due": ("companyName",),
    "billing_email_changed": ("companyName", "newEmailHint"),
    "status_changed": ("companyName", "status"),
    "account_deletion_notice": ("companyName", "requestedAt", "deleteAfter"),
    "staff_digest": ("date", "counts"),
    "audit_anchor": ("day", "count", "headHash"),
    "staff_signin_code": ("code", "minutes"),
    "invitation_email_code": ("code", "minutes"),
    "staff_notice": ("event", "person", "actor", "at"),
    "staff_invite": ("inviteUrl", "expiresAt", "role", "invitedBy"),
    "password_reset": ("accountName", "resetUrl"),
    "email_verification": ("accountName", "verifyUrl"),
    "signin_alert": ("accountName", "device", "at"),
    "password_changed": ("accountName", "at"),
}
_DATE_FIELDS = {
    "renewal_reminder": ("expiresAt",),
    "account_deletion_notice": ("requestedAt", "deleteAfter"),
    "staff_digest": ("date",),
    "audit_anchor": ("day",),
    "invoice": ("periodStart", "periodEnd", "dueAt"),
}
_TIME_FIELDS = {
    "invitation": ("expiresAt",),
    "plan_request_notice": ("requestedAt",),
    "staff_notice": ("at",),
    "staff_invite": ("expiresAt",),
    "signin_alert": ("at",),
    "password_changed": ("at",),
}
_MAX_PAYLOAD = 16_384


class DeliveryRejected(RuntimeError):
    def __init__(self, message: str, *, retryable: bool):
        super().__init__(message)
        self.retryable = retryable


class MailUncertain(RuntimeError):
    pass


class MailHeld(RuntimeError):
    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason


class MailConfigError(RuntimeError):
    pass


class DailyMailLimitReached(ValueError):
    pass


class MailTransport(Protocol):
    def send(self, message: Mapping[str, Any], idempotency_key: str) -> str: ...


def delivery_outcome(job: Mapping[str, Any]) -> tuple[str, str | None]:
    status, event = job["status"], job.get("deliveryStatus")
    detail = f" ({job['deliveryReason']})" if job.get("deliveryReason") else ""
    if event in DELIVERY_FAILED:
        return "not_delivered", f"The email was accepted but then came back. {_BOUNCE_REASONS[event]}{detail}"
    if event == DELIVERY_DELAYED and status == "sent":
        return "not_delivered", f"The email was accepted, but delivery was delayed.{detail}"
    if event == "delivered" and status in ("sent", "uncertain"):
        return "delivered", None
    if status in _JOB_PROBLEMS:
        return "not_delivered", _JOB_PROBLEMS[status] + (f" {job['lastFailure']}" if job.get("lastFailure") else "")
    return ("delivered", None) if status == "sent" else ("sending", None)


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def address_key(recipient: str) -> str:
    return hashlib.sha256(recipient.strip().lower().encode("utf-8")).hexdigest()


def company_suppression_key(tenant_id: str, address: str) -> str:
    return hashlib.sha256(f"{tenant_id}:{address}".encode("utf-8")).hexdigest()


def active_suppression(db: firestore.Client, tenant_id: str, recipient: str,
                       transaction: firestore.Transaction | None = None) -> dict[str, Any]:
    address = address_key(recipient)
    for key in (address, company_suppression_key(tenant_id, address)):
        record = db.collection(SUPPRESSIONS).document(key).get(transaction=transaction).to_dict() or {}
        if record.get("status") == "active":
            return record
    return {}


def _link_ok(link: Any) -> bool:
    if not isinstance(link, str):
        return False
    if link.startswith("https://"):
        return True
    parts = urlsplit(link)
    return auth.emulator_mode() and parts.scheme == "http" and parts.hostname in _LOOPBACK


def attachment(name: str, content: bytes, content_type: str = "application/pdf") -> dict[str, Any]:
    if not isinstance(name, str) or not _ATTACHMENT_NAME.fullmatch(name):
        raise ValueError("Attachment name must be a plain .pdf file name.")
    if not isinstance(content, bytes) or not 0 < len(content) <= ATTACHMENT_MAX_BYTES:
        raise ValueError("Attachment is empty or too large.")
    return {"name": name, "contentType": content_type, "content": base64.b64encode(content).decode("ascii"),
            "size": len(content), "sha256": hashlib.sha256(content).hexdigest()}


def _checked_attachment(value: Any) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, Mapping) or set(value) != {"name", "contentType", "content", "size", "sha256"}:
        raise ValueError("Attachment has the wrong fields.")
    try:
        content = base64.b64decode(value["content"], validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("Attachment content is not base64.") from error
    rebuilt = attachment(value["name"], content, value["contentType"])
    if rebuilt != dict(value):
        raise ValueError("Attachment size or checksum does not match its content.")
    return rebuilt


def _digest(value: Mapping[str, Any]) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _amount(body: Mapping[str, Any]) -> str:
    minor = body["amountMinor"]
    if type(minor) is not int or minor <= 0 or minor > 2**53 - 1 or body["currency"] != "MYR":
        raise ValueError("Amount or currency is invalid.")
    return f"MYR {minor / 100:.2f}"


def _digest_params(body: Mapping[str, Any]) -> dict[str, Any]:
    counts = body["counts"]
    if (not isinstance(counts, Mapping) or not set(counts) <= set(DIGEST_COUNTS)
            or any(type(number) is not int or not 0 <= number <= 1_000_000 for number in counts.values())):
        raise ValueError("Digest counts must be whole numbers.")
    return {"date": body["date"], **{name: counts.get(name, 0) for name in DIGEST_COUNTS}}


def local_time(value: Any) -> str:
    try:
        moment = parse_timestamp(value).astimezone(KUALA_LUMPUR)
    except SignatureError:
        raise ValueError("Times must look like 2026-12-31T08:00:00Z.") from None
    meridiem = "am" if moment.hour < 12 else "pm"
    return f"{moment.day} {moment:%b %Y}, {moment.hour % 12 or 12}:{moment:%M} {meridiem} (GMT+8)"


def _notice_params(body: Mapping[str, Any]) -> dict[str, Any]:
    event = body["event"]
    if event not in STAFF_NOTICES:
        raise ValueError("Staff notice event is not supported.")
    minutes = body.get("minutes", 15)
    if type(minutes) is not int or not 1 <= minutes <= 10_080:
        raise ValueError("Staff notice minutes are invalid.")
    span = f"{minutes // 60} hours" if minutes >= 120 else f"{minutes} minutes"
    sentence = STAFF_NOTICES[event].format(person=body["person"], actor=body["actor"], span=span)
    return {"sentence": sentence, "at": body["at"]}


def mail_params(kind: str, payload: Mapping[str, Any]) -> dict[str, Any]:
    if kind not in KINDS:
        raise ValueError("Unsupported mail template.")
    if not isinstance(payload, Mapping) or not _TENANT.fullmatch(str(payload.get("tenantId", ""))):
        raise ValueError("Message payload must contain a valid tenantId.")
    body = {name: value for name, value in payload.items() if name != "tenantId"}
    fields = set(_PAYLOAD_FIELDS[kind])
    if set(body) not in ((fields, fields | {"minutes"}) if kind == "staff_notice" else (fields,)):
        raise ValueError(f"Mail kind '{kind}' requires exactly the approved template fields.")
    if kind in ("invoice", "receipt"):
        params = {name: value for name, value in body.items() if name not in ("amountMinor", "currency")}
        params["amount"] = _amount(body)
    elif kind == "staff_digest":
        params = _digest_params(body)
    elif kind == "staff_notice":
        params = _notice_params(body)
    else:
        params = dict(body)
    if any(name in params and not _link_ok(params[name]) for name in LINK_FIELDS):
        raise ValueError("Mail links must use HTTPS.")
    if "interval" in params and params["interval"] not in _INTERVALS:
        raise ValueError("Billing interval is monthly or yearly.")
    if any(not (isinstance(params[name], str) and _DATE.fullmatch(params[name])) for name in _DATE_FIELDS.get(kind, ())):
        raise ValueError("Dates must look like 2026-12-31.")
    for name in _TIME_FIELDS.get(kind, ()):
        params[name] = local_time(params[name])
    if kind in ("staff_signin_code", "invitation_email_code") and (not isinstance(params["code"], str) or not _CODE.fullmatch(params["code"])
                                        or type(params["minutes"]) is not int or not 1 <= params["minutes"] <= 60):
        raise ValueError("Sign-in code fields are invalid.")
    if kind == "audit_anchor" and (not isinstance(params["headHash"], str) or not _JOB.fullmatch(params["headHash"])
                                   or type(params["count"]) is not int or not 0 <= params["count"] <= 10_000_000):
        raise ValueError("Audit anchor fields are invalid.")
    return params


def build_message(kind: str, recipient: str, payload: Mapping[str, Any],
                  attached: Mapping[str, Any] | None = None) -> dict[str, Any]:
    if not isinstance(recipient, str) or not _EMAIL.fullmatch(recipient.strip()):
        raise ValueError("Enter a valid mail recipient.")
    params = mail_params(kind, payload)
    subject, html, text = mail_render.render(kind, params)
    message = {"to": recipient.strip().lower(), "kind": kind, "params": params, "subject": subject, "html": html,
               "text": text, "tenantId": payload["tenantId"]}
    checked = _checked_attachment(attached)
    if checked is not None:
        message["attachment"] = checked
    return message


def template_ids() -> dict[str, int]:
    raw = os.environ.get(TEMPLATE_IDS_ENV, "").strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except ValueError as error:
        raise MailConfigError(f"{TEMPLATE_IDS_ENV} is not valid JSON.") from error
    if (not isinstance(parsed, dict)
            or any(type(value) is not int or value < 1 or not isinstance(name, str) for name, value in parsed.items())):
        raise MailConfigError(f"{TEMPLATE_IDS_ENV} must map template names to positive whole numbers.")
    return parsed


def template_payload(message: Mapping[str, Any], idempotency_key: str, ids: Mapping[str, int]) -> tuple[str, dict[str, Any]]:
    name, params = mail_render.checked_values(message["kind"], message["params"])
    template_id = ids.get(name)
    if template_id is None and ids:
        raise MailHeld(HELD_TEMPLATE_MISSING, f"No Brevo template id is set for '{name}'.")
    request = {"templateId": template_id, "params": params, "to": [{"email": message["to"]}],
               "headers": {"X-Mail-Job": idempotency_key, "X-Mailin-custom": idempotency_key}}
    if message.get("attachment"):
        request["attachment"] = [{"name": message["attachment"]["name"], "content": message["attachment"]["content"]}]
    return name, request


class BrevoTransport:
    def __init__(self, *, api_key: str | None = None, ids: Mapping[str, int] | None = None,
                 enabled: bool | None = None, timeout_seconds: float = 10.0):
        self.enabled = enabled if enabled is not None else os.environ.get("PLATFORM_MAIL_ENABLED", "").lower() == "true"
        self.api_key = api_key if api_key is not None else os.environ.get("BREVO_API_KEY", "")
        self.ids = dict(ids) if ids is not None else template_ids()
        self.timeout_seconds = timeout_seconds

    @property
    def ready(self) -> bool:
        return bool(self.enabled and self.api_key)

    def verify(self) -> None:
        if not self.api_key:
            raise MailConfigError("Mail is enabled with the Brevo transport but BREVO_API_KEY is not set.")
        missing = [name for name in mail_render.template_names() if name not in self.ids]
        if missing:
            raise MailConfigError(f"{TEMPLATE_IDS_ENV} has no Brevo template id for: {', '.join(missing)}.")

    def send(self, message: Mapping[str, Any], idempotency_key: str) -> str:
        if not self.enabled:
            raise RuntimeError("Transactional mail delivery is disabled.")
        if not self.api_key:
            raise MailHeld(HELD_PROVIDER_UNAVAILABLE, "The Brevo API key is not set.")
        _, payload = template_payload(message, idempotency_key, self.ids)
        try:
            response = requests.post("https://api.brevo.com/v3/smtp/email", json=payload,
                                     headers={"api-key": self.api_key, "accept": "application/json"},
                                     timeout=self.timeout_seconds)
        except requests.RequestException as error:
            raise MailUncertain("Provider request outcome is unknown.") from error
        if response.status_code >= 500:
            raise MailUncertain("Provider server response does not confirm acceptance or rejection.")
        if response.status_code in (401, 403):
            raise MailHeld(HELD_PROVIDER_UNAVAILABLE, "Provider refused the account key.")
        if response.status_code == 429:
            raise DeliveryRejected("Provider rate limited the request.", retryable=True)
        if not response.ok:
            raise DeliveryRejected("Provider rejected the request.", retryable=False)
        try:
            message_id = response.json().get("messageId")
        except (ValueError, AttributeError):
            raise MailUncertain("Provider accepted the request without a readable receipt.") from None
        if not isinstance(message_id, str) or not message_id:
            raise MailUncertain("Provider accepted the request without a readable receipt.")
        return message_id


class StubTransport:
    def __init__(self, *, path: str | os.PathLike[str] | None = None, ids: Mapping[str, int] | None = None):
        chosen = path if path is not None else os.environ.get(STUB_FILE_ENV, "").strip()
        self.path = Path(chosen) if chosen else None
        self.ids = dict(ids) if ids is not None else template_ids()
        self.sent: list[dict[str, Any]] = []

    def verify(self) -> None:
        return None

    def send(self, message: Mapping[str, Any], idempotency_key: str) -> str:
        if self.path is not None and Path(f"{self.path}{STUB_DOWN_SUFFIX}").exists():
            raise DeliveryRejected("The mail stub is not reachable.", retryable=True)
        name, request = template_payload(message, idempotency_key, self.ids)
        subject, html, text = mail_render.render(message["kind"], message["params"])
        message_id = f"{idempotency_key}@scoot.localhost"
        record = {"id": uuid.uuid4().hex, "messageId": message_id, "createdAt": _timestamp(_utc_now()),
                  "from": os.environ.get("PLATFORM_MAIL_SENDER", "").strip() or "noreply@scoot.localhost",
                  "template": name, "request": request, "rendered": {"subject": subject, "html": html, "text": text}}
        attached = message.get("attachment")
        if attached:
            record["attachments"] = [{"name": attached["name"], "size": attached["size"], "sha256": attached["sha256"],
                                      "file": self._keep(idempotency_key, attached)}]
        self.sent.append(record)
        if self.path is not None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        return message_id

    def _keep(self, idempotency_key: str, attached: Mapping[str, Any]) -> str | None:
        if self.path is None:
            return None
        folder = Path(f"{self.path}.attachments")
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / f"{idempotency_key[:16]}-{attached['name']}"
        target.write_bytes(base64.b64decode(attached["content"]))
        return str(target)


def build_transport(name: str | None = None) -> MailTransport:
    selected = (name if name is not None else os.environ.get("PLATFORM_MAIL_TRANSPORT", "")).strip().lower() or "brevo"
    if selected == "brevo":
        return BrevoTransport()
    if selected == "stub":
        return StubTransport()
    raise ValueError("PLATFORM_MAIL_TRANSPORT must be brevo or stub.")


def require_mail_ready(transport: MailTransport) -> None:
    problems = mail_render.check_templates()
    if problems:
        raise MailConfigError("The mail templates are not consistent: " + "; ".join(problems))
    verify = getattr(transport, "verify", None)
    if verify is not None:
        verify()


class MailQueue:
    def __init__(self, db: firestore.Client, *, clock: Callable[[], datetime] = _utc_now,
                 enabled: bool | None = None, max_attempts: int = 5, lease_seconds: int = 120,
                 daily_cap: int | None = None, hard_cap: int | None = None,
                 company_soft_cap: int | None = None, company_hard_cap: int | None = None,
                 staff_reserve: int | None = None):
        if type(max_attempts) is not int or not 1 <= max_attempts <= 10:
            raise ValueError("max_attempts must be between 1 and 10.")
        if type(lease_seconds) is not int or not 30 <= lease_seconds <= 600:
            raise ValueError("lease_seconds must be between 30 and 600.")
        self.db = db
        self.clock = clock
        self.enabled = enabled if enabled is not None else os.environ.get("PLATFORM_MAIL_ENABLED", "").lower() == "true"
        self.max_attempts = max_attempts
        self.lease_seconds = lease_seconds
        self.daily_cap = config.MAIL_DAILY_SOFT_CAP if daily_cap is None else daily_cap
        self.hard_cap = config.MAIL_DAILY_HARD_CAP if hard_cap is None else hard_cap
        self.company_soft_cap = config.MAIL_COMPANY_SOFT_CAP if company_soft_cap is None else company_soft_cap
        self.company_hard_cap = config.MAIL_COMPANY_HARD_CAP if company_hard_cap is None else company_hard_cap
        self.staff_reserve = config.MAIL_STAFF_RESERVE if staff_reserve is None else staff_reserve
        self.refreshers: dict[str, Callable[[Mapping[str, Any]], dict[str, Any]]] = {}

    def _counter(self, moment: datetime) -> Any:
        return self.db.collection(DAILY_COUNTERS).document(local_date(moment))

    def _tenant_counter(self, moment: datetime, tenant_id: str) -> Any:
        return self.db.collection(DAILY_COUNTERS).document(f"{local_date(moment)}__{tenant_id}")

    def _count(self, transaction: firestore.Transaction, job: Mapping[str, Any], stamp: str, delta: int) -> None:
        day = job["countedOn"]
        counters = (self.db.collection(DAILY_COUNTERS).document(day),
                    self.db.collection(DAILY_COUNTERS).document(f"{day}__{job['tenantId']}"))
        before = [(counter.get(transaction=transaction).to_dict() or {}).get("sent", 0) for counter in counters]
        for counter, sent_before in zip(counters, before):
            transaction.set(counter, {"sent": max(0, sent_before + delta), "updatedAt": stamp})

    def _blocked(self, kind: str | None, tenant_id: str, total: int, own: int) -> bool:
        urgent = kind in URGENT_KINDS
        if tenant_id == STAFF_MAIL_TENANT:
            return total >= (self.hard_cap if urgent else self.daily_cap)
        if total >= self.hard_cap - self.staff_reserve:
            return True
        return own >= (self.company_hard_cap if urgent else self.company_soft_cap)

    def _sent_today(self, moment: datetime, tenant_id: str,
                    transaction: firestore.Transaction | None = None) -> tuple[int, int]:
        counts = []
        for reference in (self._counter(moment), self._tenant_counter(moment, tenant_id)):
            snapshot = reference.get(transaction=transaction) if transaction else reference.get()
            counts.append((snapshot.to_dict() or {}).get("sent", 0))
        return counts[0], counts[1]

    def send_now(self, tenant_id: str, idempotency_key: str, kind: str, recipient: str,
                 payload: Mapping[str, Any], actor: str, transport: MailTransport) -> dict[str, Any]:
        queued = self.enqueue_or_report(tenant_id, idempotency_key, kind, recipient, payload, actor)
        if queued["status"] != "queued":
            return queued
        try:
            job = self.deliver(tenant_id, queued["jobId"], "inline", transport)
        except DailyMailLimitReached as error:
            return {"status": "held", "heldReason": HELD_DAILY_CAP, "reason": str(error)[:300], "jobId": queued["jobId"]}
        except (LookupError, ValueError) as error:
            return {"status": "queued", "reason": str(error)[:300], "jobId": queued["jobId"]}
        return {"status": job["status"], "heldReason": job["heldReason"], "reason": job["lastFailure"],
                "jobId": job["jobId"]}

    def enqueue(self, tenant_id: str, idempotency_key: str, kind: str, recipient: str,
                payload: Mapping[str, Any], actor: str, *, attached: Mapping[str, Any] | None = None) -> dict[str, Any]:
        if not self.enabled:
            raise RuntimeError("Transactional mail delivery is disabled.")
        if not _TENANT.fullmatch(tenant_id) or not _KEY.fullmatch(idempotency_key):
            raise ValueError("Tenant ID or idempotency key is invalid.")
        if not isinstance(actor, str) or not actor.strip() or len(actor) > 320:
            raise ValueError("Mail job actor is invalid.")
        message = build_message(kind, recipient, payload, attached)
        if message["tenantId"] != tenant_id:
            raise ValueError("Mail job tenant does not match its message payload.")
        if len(str(payload).encode("utf-8")) > _MAX_PAYLOAD:
            raise ValueError("Mail job payload is too large.")
        job_id = hashlib.sha256(f"{tenant_id}\x00{idempotency_key}".encode()).hexdigest()
        reference = self.db.collection("mail_jobs").document(job_id)
        fingerprint = _intent_hash(tenant_id, kind, message["to"], payload)
        now = _timestamp(self.clock())

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            if snapshot.exists:
                existing = snapshot.to_dict() or {}
                if existing.get("intentHash") != fingerprint:
                    raise ValueError("Idempotency key was already used for different mail content.")
                return self._public(existing)
            job = {"jobId": job_id, "tenantId": tenant_id, "kind": kind, "recipient": message["to"],
                   "payload": dict(payload), "actor": actor.strip(), "intentHash": fingerprint,
                   "status": "queued", "attempts": 0, "maxAttempts": self.max_attempts,
                   "createdAt": now, "updatedAt": now, "nextAttemptAt": now,
                   "providerMessageId": None, "lastFailure": None, "leaseToken": None,
                   "leaseExpiresAt": None}
            if "attachment" in message:
                job["attachment"] = message["attachment"]
            transaction.create(reference, job)
            return self._public(job)

        return write(self.db.transaction(max_attempts=10))

    def enqueue_or_report(self, tenant_id: str, idempotency_key: str, kind: str, recipient: str,
                          payload: Mapping[str, Any], actor: str, *,
                          attached: Mapping[str, Any] | None = None) -> dict[str, Any]:
        if not self.enabled:
            return {"status": "disabled", "reason": "Transactional mail delivery is disabled.", "jobId": None}
        try:
            job = self.enqueue(tenant_id, idempotency_key, kind, recipient, payload, actor, attached=attached)
        except ValueError as error:
            return {"status": "rejected", "reason": str(error)[:300], "jobId": None}
        except Exception as error:
            return {"status": "error", "reason": f"Mail queue failed: {type(error).__name__}", "jobId": None}
        return {"status": "queued", "reason": None, "jobId": job["jobId"]}

    def list_jobs(self, tenant_id: str, *, limit: int = 50, after: str | None = None) -> dict[str, Any]:
        if not isinstance(tenant_id, str) or not _TENANT.fullmatch(tenant_id):
            raise ValueError("Tenant ID is invalid.")
        if type(limit) is not int or not 1 <= limit <= 200:
            raise ValueError("limit must be between 1 and 200.")
        if after is not None and (not isinstance(after, str) or not _JOB.fullmatch(after)):
            raise ValueError("after must be a job ID from a previous page.")
        rows = [snapshot.to_dict() or {} for snapshot in self.db.collection("mail_jobs").where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream()]
        rows = sorted((row for row in rows if row.get("tenantId") == tenant_id),
                      key=lambda row: (row.get("createdAt", ""), row["jobId"]), reverse=True)
        if after is not None:
            position = next((index for index, row in enumerate(rows) if row["jobId"] == after), None)
            if position is None:
                raise ValueError("after must be a job ID from a previous page.")
            rows = rows[position + 1:]
        return {"jobs": [self._public(row) for row in rows[:limit]],
                "nextAfter": rows[limit - 1]["jobId"] if len(rows) > limit else None}

    def _held_rows(self, reason: str | None = None) -> list[dict[str, Any]]:
        query = self.db.collection("mail_jobs").where(filter=firestore.FieldFilter("status", "==", "held"))
        if reason is not None:
            query = query.where(filter=firestore.FieldFilter("heldReason", "==", reason))
        rows = [snapshot.to_dict() or {} for snapshot in query.stream()]
        return sorted(rows, key=lambda row: (row.get("heldAt", ""), row["jobId"]))

    def attention_jobs(self, limit: int | None = 200) -> list[dict[str, Any]]:
        rows = []
        for status in ("failed", "uncertain"):
            rows += [snapshot.to_dict() or {} for snapshot in self.db.collection("mail_jobs").where(
                filter=firestore.FieldFilter("status", "==", status)).stream()]
        rows = [row for row in rows if not row.get("retriedAs") and not row.get("handledAt")]
        rows.sort(key=lambda row: (row.get("createdAt", ""), row["jobId"]), reverse=True)
        return [self._public(row) for row in rows[:limit]]

    def held_jobs(self, limit: int = 200) -> list[dict[str, Any]]:
        return [self._public(row) for row in reversed(self._held_rows())][:limit]

    def tenant_of(self, job_id: str) -> str:
        if not isinstance(job_id, str) or not _JOB.fullmatch(job_id):
            raise LookupError("Mail job was not found.")
        snapshot = self.db.collection("mail_jobs").document(job_id).get()
        tenant_id = (snapshot.to_dict() or {}).get("tenantId") if snapshot.exists else None
        if not isinstance(tenant_id, str):
            raise LookupError("Mail job was not found.")
        return tenant_id

    def release_held(self, now: datetime, limit: int = 50) -> list[str]:
        total, _ = self._sent_today(now, STAFF_MAIL_TENANT)
        own_sent: dict[str, int] = {}
        released: list[str] = []
        released_by: dict[str, int] = {}
        waiting = [row for row in self._held_rows(HELD_DAILY_CAP)
                   if row.get("kind") not in ONE_TIME_KINDS and not row.get("handledAt")]
        stamp = _timestamp(now)
        for row in waiting[:limit]:
            tenant_id = row["tenantId"]
            if tenant_id not in own_sent:
                own_sent[tenant_id] = self._sent_today(now, tenant_id)[1]
            if self._blocked(row.get("kind"), tenant_id, total + len(released),
                             own_sent[tenant_id] + released_by.get(tenant_id, 0)):
                continue
            reference = self.db.collection("mail_jobs").document(row["jobId"])

            @firestore.transactional
            def write(transaction: firestore.Transaction) -> bool:
                job = reference.get(transaction=transaction).to_dict() or {}
                if job.get("status") != "held" or job.get("heldReason") != HELD_DAILY_CAP or job.get("handledAt"):
                    return False
                transaction.update(reference, {"status": "queued", "updatedAt": stamp, "nextAttemptAt": stamp,
                                               "heldReason": firestore.DELETE_FIELD, "heldAt": firestore.DELETE_FIELD})
                return True

            if write(self.db.transaction(max_attempts=10)):
                released.append(row["jobId"])
                released_by[tenant_id] = released_by.get(tenant_id, 0) + 1
        return released

    def release_unblocked(self, address: str, now: datetime) -> list[str]:
        stamp = _timestamp(now)
        released: list[str] = []
        for row in self._held_rows(HELD_RECIPIENT_SUPPRESSED):
            if (address_key(row["recipient"]) != address or row.get("kind") in ONE_TIME_KINDS
                    or row.get("handledAt")):
                continue
            reference = self.db.collection("mail_jobs").document(row["jobId"])

            @firestore.transactional
            def write(transaction: firestore.Transaction) -> bool:
                job = reference.get(transaction=transaction).to_dict() or {}
                if (job.get("status") != "held" or job.get("heldReason") != HELD_RECIPIENT_SUPPRESSED
                        or job.get("handledAt")):
                    return False
                if active_suppression(self.db, job["tenantId"], job["recipient"], transaction):
                    return False
                transaction.update(reference, {"status": "queued", "attempts": 0, "updatedAt": stamp,
                                               "nextAttemptAt": stamp, "heldReason": firestore.DELETE_FIELD,
                                               "heldAt": firestore.DELETE_FIELD})
                return True

            if write(self.db.transaction(max_attempts=10)):
                released.append(row["jobId"])
        return released

    def retry(self, tenant_id: str, job_id: str, actor: str, *,
              confirm_duplicate_risk: bool = False) -> tuple[dict[str, Any], bool]:
        if not self.enabled:
            raise RuntimeError("Transactional mail delivery is disabled.")
        if not isinstance(tenant_id, str) or not _TENANT.fullmatch(tenant_id):
            raise ValueError("Tenant ID is invalid.")
        if not isinstance(job_id, str) or not _JOB.fullmatch(job_id):
            raise LookupError("Mail job was not found.")
        if not isinstance(actor, str) or not actor.strip() or len(actor) > 320:
            raise ValueError("Mail job actor is invalid.")
        collection = self.db.collection("mail_jobs")
        reference = collection.document(job_id)
        new_id = hashlib.sha256(f"{tenant_id}\x00retry-{job_id}".encode()).hexdigest()
        new_reference = collection.document(new_id)
        now = _timestamp(self.clock())
        stored = reference.get().to_dict() or {}
        refresh = self.refreshers.get(stored.get("kind")) if stored.get("tenantId") == tenant_id else None
        fresh = refresh(stored) if refresh is not None and not stored.get("retriedAs") else None

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> tuple[dict[str, Any], bool]:
            snapshot = reference.get(transaction=transaction)
            job = snapshot.to_dict() if snapshot.exists else None
            if not job or job.get("tenantId") != tenant_id:
                raise LookupError("Mail job was not found.")
            message = None if fresh is None else build_message(
                job["kind"], fresh["recipient"], fresh["payload"], fresh.get("attached"))
            changed = {} if message is None else {
                "recipient": message["to"], "payload": dict(fresh["payload"]),
                "intentHash": _intent_hash(tenant_id, job["kind"], message["to"], fresh["payload"]),
                **({"attachment": message["attachment"]} if "attachment" in message else {})}
            if job["status"] == "held":
                if job["kind"] in ONE_TIME_KINDS:
                    raise ValueError("A one-time code or link cannot be sent again. Ask the person to start again.")
                released = {"status": "queued", "attempts": 0, "updatedAt": now, "nextAttemptAt": now,
                            "lastFailure": None, "releasedBy": actor.strip(), "releasedAt": now}
                transaction.update(reference, {**released, **changed, "heldReason": firestore.DELETE_FIELD,
                                               "heldAt": firestore.DELETE_FIELD})
                return self._public({**job, **released, **changed, "heldReason": None, "heldAt": None}), False
            if job.get("retriedAs"):
                replacement = collection.document(job["retriedAs"]).get(transaction=transaction).to_dict()
                if replacement:
                    return self._public(replacement), False
            bounced = fresh is not None and job["status"] == "sent" and delivery_outcome(job)[0] == "not_delivered"
            if job["status"] not in ("failed", "uncertain") and not bounced:
                raise ValueError("Only a held, failed or uncertain mail job can be retried.")
            if job["status"] == "uncertain" and confirm_duplicate_risk is not True:
                raise ValueError("The provider may already have sent this mail. "
                                 "Confirm the duplicate risk to send it again.")
            content = {"recipient": job["recipient"], "payload": job["payload"], "intentHash": job["intentHash"],
                       **({"attachment": job["attachment"]} if job.get("attachment") else {}), **changed}
            replacement = {"jobId": new_id, "tenantId": tenant_id, "kind": job["kind"], "actor": actor.strip(),
                           "status": "queued", "attempts": 0, "maxAttempts": self.max_attempts, "createdAt": now,
                           "updatedAt": now, "nextAttemptAt": now, "providerMessageId": None, "lastFailure": None,
                           "leaseToken": None, "leaseExpiresAt": None, "retryOf": job_id, **content}
            transaction.create(new_reference, replacement)
            transaction.update(reference, {"retriedAs": new_id, "retriedAt": now, "retriedBy": actor.strip()})
            return self._public(replacement), True

        return write(self.db.transaction(max_attempts=10))

    def mark_handled(self, tenant_id: str, job_id: str, actor: str) -> dict[str, Any]:
        if not isinstance(tenant_id, str) or not _TENANT.fullmatch(tenant_id):
            raise ValueError("Tenant ID is invalid.")
        if not isinstance(job_id, str) or not _JOB.fullmatch(job_id):
            raise LookupError("Mail job was not found.")
        if not isinstance(actor, str) or not actor.strip() or len(actor) > 320:
            raise ValueError("Mail job actor is invalid.")
        reference = self.db.collection("mail_jobs").document(job_id)
        now = _timestamp(self.clock())

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            job = snapshot.to_dict() if snapshot.exists else None
            if not job or job.get("tenantId") != tenant_id:
                raise LookupError("Mail job was not found.")
            if job["status"] not in ("held", "failed", "uncertain"):
                raise ValueError("Only a held, failed or uncertain mail job can be marked handled.")
            if job.get("handledAt"):
                return self._public(job)
            changes = {"handledAt": now, "handledBy": actor.strip()}
            transaction.update(reference, changes)
            return self._public({**job, **changes})

        return write(self.db.transaction(max_attempts=10))

    def due_jobs(self, now: datetime, limit: int) -> list[tuple[str, str]]:
        stamp = _timestamp(now)
        rows = [snapshot.to_dict() or {} for snapshot in self.db.collection("mail_jobs").where(
            filter=firestore.FieldFilter("status", "==", "queued")).stream()]
        due = [row for row in rows if row.get("nextAttemptAt", stamp) <= stamp
               and row.get("attempts", 0) < row.get("maxAttempts", 0)]
        due.sort(key=lambda row: (row.get("createdAt", ""), row["jobId"]))
        return [(row["tenantId"], row["jobId"]) for row in due[:limit]]

    def get(self, tenant_id: str, job_id: str) -> dict[str, Any]:
        snapshot = self.db.collection("mail_jobs").document(job_id).get()
        data = snapshot.to_dict() if snapshot.exists else None
        if not data or data.get("tenantId") != tenant_id:
            raise LookupError("Mail job was not found.")
        return self._public(data)

    def deliver(self, tenant_id: str, job_id: str, worker_id: str, transport: MailTransport) -> dict[str, Any]:
        if not self.enabled:
            raise RuntimeError("Transactional mail delivery is disabled.")
        reference = self.db.collection("mail_jobs").document(job_id)
        token = secrets.token_urlsafe(24)
        now_dt = self.clock()
        now = _timestamp(now_dt)

        @firestore.transactional
        def claim(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            job = snapshot.to_dict() if snapshot.exists else None
            if not job or job.get("tenantId") != tenant_id:
                raise LookupError("Mail job was not found.")
            if job["status"] != "queued":
                raise ValueError("Mail job is not available for delivery.")
            if job["attempts"] >= job["maxAttempts"]:
                raise ValueError("Mail job has reached its retry limit.")
            if job["nextAttemptAt"] > now:
                raise ValueError("Mail job retry time has not arrived.")
            suppression = active_suppression(self.db, tenant_id, job["recipient"], transaction)
            if suppression:
                job.update(_hold_changes(job, HELD_RECIPIENT_SUPPRESSED,
                                         f"The address is blocked after a {suppression.get('reason')} event.", now))
                transaction.set(reference, job)
                return job
            if self._blocked(job.get("kind"), tenant_id, *self._sent_today(now_dt, tenant_id, transaction)):
                job.update(_hold_changes(job, HELD_DAILY_CAP, "The daily mail limit is reached.", now))
                transaction.set(reference, job)
                return job
            job["countedOn"] = local_date(now_dt)
            self._count(transaction, job, now, 1)
            job["status"] = "sending"
            job["attempts"] += 1
            job["leaseToken"] = token
            job["leaseOwner"] = worker_id
            job["leaseExpiresAt"] = _timestamp(now_dt + timedelta(seconds=self.lease_seconds))
            job["providerCallStartedAt"] = None
            job["updatedAt"] = job["startedAt"] = now
            if job["kind"] == "invoice":
                job["payload"] = {**job["payload"], "dueAt": local_date(now_dt + timedelta(days=DUE_DAYS))}
            transaction.set(reference, job)
            return job

        job = claim(self.db.transaction(max_attempts=10))
        if job["status"] == "held" and job["heldReason"] == HELD_DAILY_CAP:
            raise DailyMailLimitReached("The daily mail limit is reached. This message waits for tomorrow.")
        if job["status"] == "held":
            return self._public(job)
        try:
            message = build_message(job["kind"], job["recipient"], job["payload"], job.get("attachment"))
        except ValueError as error:
            return self._finish(reference, token, "failed", now_dt,
                                failure=f"Message could not be rendered: {str(error)[:200]}")
        self._mark_provider_call(reference, token, now_dt)
        try:
            provider_id = transport.send(message, job["jobId"])
        except MailHeld as error:
            return self._finish(reference, token, "held", now_dt, failure=str(error)[:300], held_reason=error.reason)
        except DeliveryRejected as error:
            status = "queued" if error.retryable and job["attempts"] < job["maxAttempts"] else "failed"
            delay = min(60, 2 ** job["attempts"]) if status == "queued" else 0
            return self._finish(reference, token, status, now_dt, failure=str(error)[:300], delay=delay)
        except MailUncertain as error:
            return self._finish(reference, token, "uncertain", now_dt, failure=str(error)[:300])
        except Exception as error:
            return self._finish(reference, token, "uncertain", now_dt,
                                failure=f"Transport outcome is unknown: {type(error).__name__}")
        if not isinstance(provider_id, str) or not provider_id:
            return self._finish(reference, token, "uncertain", now_dt, failure="Provider receipt is missing.")
        return self._finish(reference, token, "sent", now_dt, provider_message_id=provider_id)

    def _mark_provider_call(self, reference: Any, token: str, now_dt: datetime) -> None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            snapshot = reference.get(transaction=transaction)
            job = snapshot.to_dict() if snapshot.exists else None
            if not job or job.get("leaseToken") != token or job.get("status") != "sending":
                raise ValueError("Mail delivery lease was lost.")
            transaction.update(reference, {"providerCallStartedAt": _timestamp(now_dt)})

        write(self.db.transaction(max_attempts=10))

    def recover_expired(self, now: datetime | None = None, limit: int = 50) -> dict[str, list[str]]:
        moment = now or self.clock()
        stamp = _timestamp(moment)
        rows = [snapshot.to_dict() or {} for snapshot in self.db.collection("mail_jobs").where(
            filter=firestore.FieldFilter("status", "==", "sending")).stream()]
        expired = sorted((row for row in rows if (row.get("leaseExpiresAt") or "") <= stamp),
                         key=lambda row: (row.get("updatedAt", ""), row["jobId"]))
        result: dict[str, list[str]] = {"requeued": [], "uncertain": [], "failed": []}
        for row in expired[:limit]:
            outcome = self._recover(self.db.collection("mail_jobs").document(row["jobId"]), moment)
            if outcome:
                result[outcome].append(row["jobId"])
        return result

    def _recover(self, reference: Any, moment: datetime) -> str | None:
        stamp = _timestamp(moment)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> str | None:
            snapshot = reference.get(transaction=transaction)
            job = snapshot.to_dict() if snapshot.exists else None
            if not job or job.get("status") != "sending" or (job.get("leaseExpiresAt") or "") > stamp:
                return None
            if job.get("providerCallStartedAt"):
                status, outcome = "uncertain", "uncertain"
                failure = "Worker lease expired after the provider call started; the delivery outcome is unknown."
            elif job["attempts"] >= job["maxAttempts"]:
                status, outcome = "failed", "failed"
                failure = "Worker lease expired before the provider call started and no attempts are left."
            else:
                status, outcome = "queued", "requeued"
                failure = "Worker lease expired before the provider call started."
            changes = {"status": status, "updatedAt": stamp, "lastFailure": failure, "leaseToken": None,
                       "leaseOwner": None, "leaseExpiresAt": None, "providerCallStartedAt": None}
            if status != "queued":
                changes.update(_scrubbed(job, status))
            if status in NOT_SENT and job.get("countedOn"):
                self._count(transaction, job, stamp, -1)
                changes["countedOn"] = firestore.DELETE_FIELD
            if status == "queued":
                changes["nextAttemptAt"] = stamp
            transaction.update(reference, changes)
            return outcome

        return write(self.db.transaction(max_attempts=10))

    def _finish(self, reference: Any, token: str, status: str, now_dt: datetime, *,
                failure: str | None = None, delay: int = 0, provider_message_id: str | None = None,
                held_reason: str | None = None) -> dict[str, Any]:
        now = _timestamp(now_dt)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            job = snapshot.to_dict() if snapshot.exists else None
            if not job or job.get("leaseToken") != token:
                raise ValueError("Mail delivery lease was lost.")
            if status != "queued":
                job.update(_scrubbed(job, status))
            if status in NOT_SENT and job.get("countedOn"):
                self._count(transaction, job, now, -1)
                job.pop("countedOn")
            job.pop("heldReason", None)
            job.pop("heldAt", None)
            job.update({"status": status, "updatedAt": now, "lastFailure": failure,
                        "providerMessageId": provider_message_id, "leaseToken": None,
                        "leaseExpiresAt": None, "leaseOwner": None, "providerCallStartedAt": None})
            if status == "held":
                job.update({"heldReason": held_reason, "heldAt": now})
            if delay:
                job["nextAttemptAt"] = _timestamp(now_dt + timedelta(seconds=delay))
            transaction.set(reference, job)
            return self._public(job)

        return write(self.db.transaction(max_attempts=10))

    @staticmethod
    def _public(job: Mapping[str, Any]) -> dict[str, Any]:
        fields = ("jobId", "tenantId", "kind", "recipient", "status", "attempts", "maxAttempts",
                  "createdAt", "updatedAt", "nextAttemptAt", "providerMessageId", "lastFailure",
                  "retryOf", "retriedAs", "handledAt", "handledBy", "heldReason", "heldAt",
                  "deliveryStatus", "deliveryStatusAt", "deliveryReason", "startedAt")
        return {**{name: job.get(name) for name in fields},
                "attachmentName": (job.get("attachment") or {}).get("name")}


def _intent_hash(tenant_id: str, kind: str, recipient: str, payload: Mapping[str, Any]) -> str:
    secret_field = SECRET_FIELDS.get(kind)
    return _digest({"tenantId": tenant_id, "kind": kind, "recipient": recipient,
                    "payload": {name: value for name, value in payload.items() if name != secret_field}})


def _scrubbed(job: Mapping[str, Any], status: str) -> dict[str, Any]:
    field = SECRET_FIELDS.get(job.get("kind"))
    if field is None or (status == "held" and job.get("kind") not in ONE_TIME_KINDS):
        return {}
    return {"payload": {**job["payload"], field: "removed"}}


def _hold_changes(job: Mapping[str, Any], reason: str, failure: str, now: str) -> dict[str, Any]:
    return {**_scrubbed(job, "held"), "status": "held", "heldReason": reason, "heldAt": now, "updatedAt": now,
            "lastFailure": failure, "leaseToken": None, "leaseOwner": None, "leaseExpiresAt": None,
            "providerCallStartedAt": None}


def company_contact(db: firestore.Client, tenant_id: str) -> tuple[str, str | None] | None:
    data = db.collection("companies").document(tenant_id).get().to_dict() or {}
    try:
        payload = json.loads(data.get("payload") or "")
    except ValueError:
        return None
    name = payload.get("legalName") if isinstance(payload, dict) and payload.get("tenantId") == tenant_id else None
    if not isinstance(name, str) or not name.strip():
        return None
    email = data.get("billingEmail")
    return name, (email if isinstance(email, str) and email.strip() else None)


def deliver_mail(queue: MailQueue, *, now: datetime | None = None, limit: int = 50,
                 transport: MailTransport | None = None, worker_id: str = "mail-tick") -> dict[str, Any]:
    result: dict[str, Any] = {"sent": [], "failed": [], "queued": [], "uncertain": [], "held": [], "skipped": None}
    if not queue.enabled:
        result["skipped"] = "Transactional mail delivery is disabled."
        return result
    transport = transport or build_transport()
    if isinstance(transport, BrevoTransport) and not transport.ready:
        result["skipped"] = "Transactional mail sender configuration is incomplete."
        return result
    moment = now or queue.clock()
    result["recovered"] = {name: len(ids) for name, ids in queue.recover_expired(moment).items()}
    result["released"] = len(queue.release_held(moment))
    for tenant_id, job_id in queue.due_jobs(moment, limit):
        try:
            job = queue.deliver(tenant_id, job_id, worker_id, transport)
        except DailyMailLimitReached:
            result["held"].append(job_id)
            continue
        except (LookupError, ValueError):
            continue
        result[job["status"]].append(job_id)
    return result

from __future__ import annotations

import hashlib
import os
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from firebase_admin import auth as admin_auth
from google.cloud import firestore

import logging

from . import config
from .audit import AuditLog
from .commands import CommandProblem
from .access_migration import judge_access_row
from .company_access import CompanyAccess, retry_while_unreachable
from .directory import DirectoryError, DirectoryStore
from .operations import OperationContext, OperationStore, RetryLater, Step
from .mail import MailQueue, company_contact
from .payments import PaymentLedger
from .signing import encode_payload


LIFECYCLE = "lifecycle"
ACCESS = "user_access"
USERS = "users"
LIVE_TRACKING = "live_tracking"
HELD_SESSIONS = "held_work_sessions"
ACCESS_FOR_STATE = {
    "active": "open",
    "past_due": "open",
    "suspended": "readonly",
    "expired": "readonly",
    "cancelled": "closed",
    "lead": "closed",
}
ACCESS_VALUES = frozenset(ACCESS_FOR_STATE.values())
ACCESS_FIELDS = frozenset({"access", "accessRevision", "cutAt", "drainUntil", "reactivatedAt"})
DRAIN_SECONDS_SETTING = "PLATFORM_HELD_WORK_DRAIN_SECONDS"
COMPANY_PAUSED = "company_paused"
LAPSE_REASONS = frozenset({"billing_lapse", "trial_expired", "cancelled"})
READ_ONLY_REASON = "lifecycle_readonly"
DELETION_REASON = "deletion_requested"
DISABLE_REASONS = frozenset({*LAPSE_REASONS, READ_ONLY_REASON, "admin_suspension", DELETION_REASON})
SERVING_STATES = frozenset({"active", "past_due"})
LAPSED_STATES = {"suspended": "billing_lapse", "expired": "trial_expired", "cancelled": "cancelled"}
RETENTION = timedelta(days=config.ENDED_COMPANY_RETENTION_DAYS)
ROWS_PER_TRANSACTION = 100
AUTH_WORKERS = 4
_ACCESS_ROW_FIELDS = ["role", "user_group", "disabledReasons", "accessVersion", "userDocId"]
_PROFILE_ROW_FIELDS = ["role", "user_group", "disabledReasons"]
_READ_ONLY_ROLES = ("admin", "developer")
STATES = frozenset(
    {"lead", "active", "past_due", "suspended", "expired", "cancelled"}
)
LIFECYCLES = "lifecycle"
LIFECYCLE_RECEIPTS = "lifecycle_operation_receipts"
STATUS_NOTICES = "status_notices"
ALLOWED_TRANSITIONS = {
    "lead": frozenset({"active"}),
    "active": frozenset({"past_due", "suspended", "cancelled"}),
    "past_due": frozenset({"active", "suspended", "expired"}),
    "suspended": frozenset({"active", "cancelled", "expired"}),
    "expired": frozenset({"active", "cancelled"}),
    "cancelled": frozenset({"active"}),
}
_ALLOWED = ALLOWED_TRANSITIONS
FIRST_STATES = frozenset({"lead", "active"})
_TENANT = re.compile(r"^t_[a-z0-9]{6,32}$")
_ID = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
_PAYMENT = re.compile(r"^pay_[0-9a-f]{64}$")
ACTION_LIFECYCLE = "lifecycle.transition"
_RECORD_META = frozenset({"kind", "version", "issuedAt", "expiresAt"})
_FIELDS = frozenset(
    {
        "tenantId",
        "state",
        "revision",
        "stateSince",
        "graceEndsAt",
        "windowEndsAt",
        "retentionEndsAt",
    }
)


def lapse_reason(result: Mapping[str, Any]) -> str:
    state = result["state"]
    if state == "expired" and result.get("activationReceiptId"):
        return "billing_lapse"
    return LAPSED_STATES[state]


class LifecycleConflict(Exception):
    pass


def _record_status(state: str) -> str:
    return "lead" if state == "lead" else "live"


def _moment(value: Any, name: str, *, optional: bool = False) -> datetime | None:
    if value is None and optional:
        return None
    if not isinstance(value, datetime) or value.tzinfo is None:
        raise LifecycleConflict(f"{name} must be an aware timestamp.")
    return value


def clean_projection(value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping) or set(value) != _FIELDS:
        raise LifecycleConflict("The lifecycle projection fields are invalid.")
    tenant_id = value.get("tenantId")
    state = value.get("state")
    revision = value.get("revision")
    if not isinstance(tenant_id, str) or not _TENANT.fullmatch(tenant_id):
        raise LifecycleConflict("The lifecycle tenant is invalid.")
    if state not in STATES:
        raise LifecycleConflict("The lifecycle state is invalid.")
    if type(revision) is not int or revision < 1:
        raise LifecycleConflict("The lifecycle revision is invalid.")
    return {
        "tenantId": tenant_id,
        "state": state,
        "revision": revision,
        "stateSince": _moment(value.get("stateSince"), "stateSince"),
        "graceEndsAt": _moment(value.get("graceEndsAt"), "graceEndsAt", optional=True),
        "windowEndsAt": _moment(value.get("windowEndsAt"), "windowEndsAt", optional=True),
        "retentionEndsAt": _moment(
            value.get("retentionEndsAt"), "retentionEndsAt", optional=True
        ),
    }


def drain_length() -> timedelta:
    raw = os.environ.get(DRAIN_SECONDS_SETTING, "").strip() or "86400"
    if not raw.isdigit() or int(raw) < 1:
        raise RuntimeError(f"{DRAIN_SECONDS_SETTING} must be a positive number of seconds.")
    return timedelta(seconds=int(raw))


def projection_part(value: Mapping[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if key not in ACCESS_FIELDS}


def iso_moment(value: Any) -> str | None:
    if not isinstance(value, datetime) or value.tzinfo is None:
        return None
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def lifecycle_view(state: Any, stamp: Mapping[str, Any] | None) -> dict[str, Any]:
    stamp = stamp or {}
    if state not in STATES:
        state = stamp.get("state") if stamp.get("state") in STATES else None
    access = stamp.get("access")
    if access not in ACCESS_VALUES:
        access = ACCESS_FOR_STATE.get(state, "closed")
    view: dict[str, Any] = {"state": state, "access": access}
    for name in ("cutAt", "drainUntil", "reactivatedAt"):
        moment = iso_moment(stamp.get(name))
        if moment is not None:
            view[name] = moment
    return view


def _reasons(value: Any) -> list[str]:
    if not isinstance(value, list) or len(value) > len(DISABLE_REASONS):
        raise LifecycleConflict("The account disable reasons are invalid.")
    if any(reason not in DISABLE_REASONS for reason in value) or len(set(value)) != len(value):
        raise LifecycleConflict("The account disable reasons are invalid.")
    return sorted(value)


def _text(value: Any, name: str, maximum: int) -> str:
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= maximum:
        raise LifecycleConflict(f"{name} must be nonempty text of at most {maximum} characters.")
    return value.strip()


class LifecycleStore:
    def __init__(self, client: firestore.Client, audit: AuditLog | None = None) -> None:
        self.client = client
        self.audit = audit if audit is not None else AuditLog(client)

    def get(self, tenant_id: str) -> dict[str, Any] | None:
        self._tenant(tenant_id)
        snapshot = self.client.collection(LIFECYCLES).document(tenant_id).get()
        return snapshot.to_dict() if snapshot.exists else None

    def result_for(self, tenant_id: str, operation_id: str) -> dict[str, Any] | None:
        self._tenant(tenant_id)
        if not isinstance(operation_id, str) or not _ID.fullmatch(operation_id):
            raise LifecycleConflict("The lifecycle operation identity is invalid.")
        receipt = self.client.collection(LIFECYCLE_RECEIPTS).document(
            hashlib.sha256(f"{tenant_id}\n{operation_id}".encode("utf-8")).hexdigest()
        )
        snapshot = receipt.get()
        return (snapshot.to_dict() or {}).get("result") if snapshot.exists else None

    def transition(
        self,
        tenant_id: str,
        state: str,
        *,
        operation_id: str,
        actor: str,
        reason: str,
        ticket: str | None,
        now: datetime,
        expected_revision: int | None = None,
        activation_receipt_id: str | None = None,
        seal: Callable[[firestore.Transaction], None] | None = None,
    ) -> dict[str, Any]:
        self._tenant(tenant_id)
        if state not in STATES:
            raise LifecycleConflict("The lifecycle state is invalid.")
        if not isinstance(operation_id, str) or not _ID.fullmatch(operation_id):
            raise LifecycleConflict("The lifecycle operation identity is invalid.")
        actor = _text(actor, "actor", 254)
        reason = _text(reason, "reason", 500)
        if ticket is not None:
            ticket = _text(ticket, "ticket", 100)
        if not isinstance(now, datetime) or now.tzinfo is None:
            raise LifecycleConflict("now must be an aware timestamp.")
        if expected_revision is not None and (
            type(expected_revision) is not int or expected_revision < 0
        ):
            raise LifecycleConflict("expectedRevision must be a non-negative integer.")
        if activation_receipt_id is not None and (
            not isinstance(activation_receipt_id, str)
            or not _PAYMENT.fullmatch(activation_receipt_id)
        ):
            raise LifecycleConflict("The activation payment receipt is invalid.")
        intent = {
            "tenantId": tenant_id,
            "state": state,
            "actor": actor,
            "reason": reason,
            "ticket": ticket,
            "expectedRevision": expected_revision,
            "activationReceiptId": activation_receipt_id,
        }
        intent_hash = hashlib.sha256(encode_payload(intent).encode("utf-8")).hexdigest()
        reference = self.client.collection(LIFECYCLES).document(tenant_id)
        receipt = self.client.collection(LIFECYCLE_RECEIPTS).document(
            hashlib.sha256(f"{tenant_id}\n{operation_id}".encode("utf-8")).hexdigest()
        )

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            prior = receipt.get(transaction=transaction)
            if prior.exists:
                data = prior.to_dict() or {}
                if data.get("intentHash") != intent_hash:
                    raise LifecycleConflict(
                        "The lifecycle operation already has a different intent."
                    )
                return data["result"]
            snapshot = reference.get(transaction=transaction)
            current = snapshot.to_dict() if snapshot.exists else None
            revision = current.get("revision", 0) if current else 0
            if type(revision) is not int or revision < 0:
                raise LifecycleConflict("The stored lifecycle revision is invalid.")
            if expected_revision is not None and expected_revision != revision:
                raise LifecycleConflict("The lifecycle changed. Reload it and try again.")
            if current is None:
                if state not in FIRST_STATES:
                    raise LifecycleConflict("The first lifecycle state must be lead or active.")
            elif state not in _ALLOWED.get(current.get("state"), frozenset()):
                raise LifecycleConflict("That lifecycle transition is not allowed.")
            if state == "active":
                if activation_receipt_id is None:
                    raise LifecycleConflict(
                        "Activation requires a current, explicit, unvoided coverage receipt."
                    )
                covering = PaymentLedger(self.client).coverage(
                    tenant_id, now, transaction=transaction
                ).covering_entries
                if activation_receipt_id not in covering:
                    raise LifecycleConflict(
                        "Activation requires a current, explicit, unvoided coverage receipt."
                    )
            grace = now + timedelta(days=14) if state == "past_due" else None
            window = now + timedelta(days=3) if state in {"suspended", "expired"} else None
            retention = now + RETENTION if state in LAPSED_STATES else None
            if current and current.get("state") in LAPSED_STATES and state in LAPSED_STATES:
                window = current.get("windowEndsAt") if state in {"suspended", "expired"} else None
                retention = current.get("retentionEndsAt") or retention
            result = {
                "tenantId": tenant_id,
                "state": state,
                "previousState": current.get("state") if current else None,
                "revision": revision + 1,
                "stateSince": now,
                "graceEndsAt": grace,
                "windowEndsAt": window,
                "retentionEndsAt": retention,
                "reason": reason,
                "ticket": ticket,
                "updatedBy": actor,
                "updatedAt": now,
                "lastOperationId": operation_id,
                "activationReceiptId": activation_receipt_id
                if state == "active" else (current or {}).get("activationReceiptId"),
            }
            staged = self.audit.stage(transaction, now, tenant_id=tenant_id)
            transaction.set(reference, result)
            transaction.create(
                receipt,
                {
                    "tenantId": tenant_id,
                    "operationId": operation_id,
                    "intentHash": intent_hash,
                    "result": result,
                },
            )
            staged.add(actor=actor, action="lifecycle.transitioned", tenant_id=tenant_id,
                       key=f"lifecycle:{tenant_id}:{operation_id}",
                       summary=f"Company moved from {result['previousState'] or 'new'} to {state}.",
                       refs={"state": state, "previousState": result["previousState"],
                             "revision": result["revision"], "operationId": operation_id})
            if seal is not None:
                seal(transaction)
            return result

        return write(self.client.transaction(max_attempts=10))

    def restate_past_due(self, tenant_id: str, reason: str, *, expected_revision: int, actor: str,
                         now: datetime) -> bool:
        self._tenant(tenant_id)
        reason = _text(reason, "reason", 500)
        reference = self.client.collection(LIFECYCLES).document(tenant_id)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool:
            current = reference.get(transaction=transaction).to_dict() or {}
            if (current.get("state") != "past_due" or current.get("revision") != expected_revision
                    or current.get("reason") == reason):
                return False
            staged = self.audit.stage(transaction, now, tenant_id=tenant_id)
            transaction.update(reference, {"reason": reason, "updatedBy": actor, "updatedAt": now})
            staged.add(actor=actor, action="lifecycle.reason_changed", tenant_id=tenant_id,
                       key=f"lifecycle-reason:{tenant_id}:r{expected_revision}:{now.isoformat()}",
                       summary="The past due reason changed.",
                       refs={"state": "past_due", "revision": expected_revision})
            return True

        return write(self.client.transaction(max_attempts=10))

    @staticmethod
    def projection(value: Mapping[str, Any]) -> dict[str, Any]:
        return clean_projection({key: value.get(key) for key in _FIELDS})

    @staticmethod
    def _tenant(tenant_id: str) -> None:
        if not isinstance(tenant_id, str) or not _TENANT.fullmatch(tenant_id):
            raise LifecycleConflict("The lifecycle tenant is invalid.")


class LifecycleService:
    def __init__(
        self,
        platform: firestore.Client,
        runner: OperationStore,
        directory: DirectoryStore,
        store: LifecycleStore,
        *,
        access_for: Callable[[Mapping[str, Any]], CompanyAccess],
        clock: Callable[[], datetime],
        mail: MailQueue | None = None,
    ) -> None:
        self.platform = platform
        self.runner = runner
        self.directory = directory
        self.store = store
        self.access_for = access_for
        self.clock = clock
        self.mail = mail

    def recovery_actions(self) -> dict[str, list[Step]]:
        return {ACTION_LIFECYCLE: self.transition_steps()}

    def reconcile_projections(self) -> dict[str, list[str]]:
        reconciled: list[str] = []
        failed: list[str] = []
        for snapshot in self.platform.collection(LIFECYCLES).stream():
            tenant_id = snapshot.id
            try:
                projection = self.store.projection(snapshot.to_dict() or {})
                with retry_while_unreachable():
                    tenant = TenantLifecycle(self._company_access(tenant_id))
                    try:
                        projected = tenant.current()["revision"]
                    except LifecycleConflict:
                        projected = 0
                    if projected > projection["revision"]:
                        continue
                    if projected == projection["revision"] and tenant.access_stamped(
                        projection["state"], projection["revision"]
                    ):
                        continue
                    tenant.project(projection)
                    tenant.enforce(projection["state"], projection["revision"], self.clock(),
                                   lapse_reason(snapshot.to_dict() or {}) if projection["state"] in LAPSED_STATES else None)
                reconciled.append(tenant_id)
            except Exception as error:
                logging.getLogger(__name__).error("lifecycle reconcile failed: %s", type(error).__name__)
                failed.append(tenant_id)
        return {"reconciled": reconciled, "failed": failed}

    def transition_steps(self) -> list[Step]:
        def write_apply(ctx: OperationContext) -> dict[str, Any]:
            try:
                result = self.store.transition(
                    ctx.params["tenantId"],
                    ctx.params["state"],
                    operation_id=ctx.operation_id,
                    actor=ctx.params["requestedBy"],
                    reason=ctx.params["reason"],
                    ticket=ctx.params.get("ticket"),
                    now=self.clock(),
                    expected_revision=ctx.params.get("expectedRevision"),
                    activation_receipt_id=ctx.params.get("paymentEntryId"),
                    seal=ctx.seal,
                )
            except LifecycleConflict as error:
                raise CommandProblem(str(error)) from None
            return {"revision": result["revision"], "state": result["state"],
                    "previousState": result.get("previousState")}

        def write_check(ctx: OperationContext) -> bool:
            return self.store.result_for(ctx.params["tenantId"], ctx.operation_id) is not None

        def project_apply(ctx: OperationContext) -> dict[str, Any]:
            result = self._operation_result(ctx)
            projection = self.store.projection(result)
            tenant_id = ctx.params["tenantId"]
            with retry_while_unreachable():
                service = TenantLifecycle(self._company_access(tenant_id))
                try:
                    service.project(projection)
                    service.enforce(projection["state"], projection["revision"], self.clock(),
                                    lapse_reason(result) if projection["state"] in LAPSED_STATES else None)
                except LifecycleConflict as error:
                    raise CommandProblem(str(error)) from None
            return {"revision": projection["revision"], "state": projection["state"]}

        def project_check(ctx: OperationContext) -> bool:
            result = self._operation_result(ctx)
            revision = result["revision"]
            try:
                with retry_while_unreachable():
                    current = TenantLifecycle(
                        self._company_access(ctx.params["tenantId"])
                    ).current()
            except LifecycleConflict:
                return False
            if current["revision"] > revision:
                return True
            if current["revision"] < revision:
                return False
            if result["state"] == "active" or result["state"] in LAPSED_STATES:
                return False
            return current["state"] == result["state"]

        def record_apply(ctx: OperationContext) -> dict[str, Any]:
            current = self._sync_record(ctx.params["tenantId"])
            return {"revision": current["revision"], "state": current["state"]}

        def record_check(ctx: OperationContext) -> bool:
            current = self.store.get(ctx.params["tenantId"])
            record = self.directory.get(ctx.params["tenantId"])
            return current is not None and record is not None and record["status"] in (
                _record_status(current["state"]), "deleted"
            )

        def notify_apply(ctx: OperationContext) -> dict[str, Any]:
            self._notify_status(ctx)
            return {}

        def notify_check(ctx: OperationContext) -> bool:
            result = self.store.result_for(ctx.params["tenantId"], ctx.operation_id) or {}
            if self.mail is None or self._status_notice(result) is None:
                return True
            return self.platform.collection(STATUS_NOTICES).document(
                f"{ctx.params['tenantId']}_{result['revision']}").get().exists

        return [
            Step("write_lifecycle", write_apply, write_check),
            Step("project_lifecycle", project_apply, project_check),
            Step("sync_record", record_apply, record_check),
            Step("notify_status", notify_apply, notify_check),
        ]

    @staticmethod
    def _status_notice(result: Mapping[str, Any]) -> tuple[str, str] | None:
        state, previous = result.get("state"), result.get("previousState")
        if state == "suspended":
            return "status_changed", "suspended"
        if state == "past_due":
            return "past_due", "past_due"
        if state in ("expired", "cancelled"):
            return "status_changed", "read_only"
        if state == "active" and previous in LAPSED_STATES:
            return "status_changed", "restored"
        return None

    def _notify_status(self, ctx: OperationContext) -> None:
        if self.mail is None:
            return
        try:
            result = self.store.result_for(ctx.params["tenantId"], ctx.operation_id) or {}
            notice = self._status_notice(result)
            if notice is None:
                return
            kind, status = notice
            tenant_id, revision = ctx.params["tenantId"], result["revision"]
            contact = company_contact(self.platform, tenant_id)
            if contact is None or contact[1] is None:
                outcome = {"status": "skipped", "jobId": None, "reason": "The company has no billing email."}
            else:
                payload = {"tenantId": tenant_id, "companyName": contact[0]}
                outcome = self.mail.enqueue_or_report(
                    tenant_id, f"status-{tenant_id}-{revision}", kind, contact[1],
                    payload if kind == "past_due" else {**payload, "status": status},
                    ctx.params["requestedBy"])
            reference = self.platform.collection(STATUS_NOTICES).document(f"{tenant_id}_{revision}")
            record = {"tenantId": tenant_id, "revision": revision, "status": outcome["status"],
                      "reason": outcome["reason"] if "reason" in outcome else None,
                      "jobId": outcome["jobId"], "notice": status}
            if (reference.get().to_dict() or {}) != record:
                reference.set(record)
        except Exception as error:
            logging.getLogger(__name__).error("lifecycle status mail failed: %s", type(error).__name__)

    def _operation_result(self, ctx: OperationContext) -> dict[str, Any]:
        result = self.store.result_for(ctx.params["tenantId"], ctx.operation_id)
        if result is None:
            raise CommandProblem("The lifecycle transition receipt is missing.")
        return result

    def _company_access(self, tenant_id: str) -> CompanyAccess:
        record = self.directory.get(tenant_id)
        if record is None:
            raise CommandProblem("Unknown company.")
        return self.access_for(record["location"])

    def _sync_record(self, tenant_id: str) -> dict[str, Any]:
        for _ in range(3):
            current = self.store.get(tenant_id)
            if current is None:
                raise CommandProblem("The lifecycle state is missing.")
            record = self.directory.get(tenant_id)
            if record is None:
                raise CommandProblem("Unknown company.")
            target = _record_status(current["state"])
            if record["status"] in (target, "deleted"):
                return current
            body = {key: value for key, value in record.items() if key not in _RECORD_META}
            body["status"] = target
            try:
                self.directory.put(body, expected_version=record["version"], now=self.clock())
            except DirectoryError as error:
                if "stale version" in str(error):
                    continue
                raise CommandProblem(str(error)) from None
        raise RetryLater("The company record changed while its status was updated.")


class TenantLifecycle:
    def __init__(self, access: CompanyAccess) -> None:
        self.access = access
        self.db = access.db
        self.reference = self.db.collection("config").document(LIFECYCLE)

    def current(self) -> dict[str, Any]:
        snapshot = self.reference.get()
        if not snapshot.exists:
            raise LifecycleConflict("The lifecycle projection is missing.")
        return clean_projection(projection_part(snapshot.to_dict() or {}))

    def access_stamped(self, state: str, revision: int) -> bool:
        snapshot = self.reference.get()
        if not snapshot.exists:
            return False
        data = snapshot.to_dict() or {}
        return data.get("access") == ACCESS_FOR_STATE.get(state) and data.get("accessRevision") == revision

    def project(self, value: Mapping[str, Any]) -> dict[str, Any]:
        projection = clean_projection(value)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = self.reference.get(transaction=transaction)
            if snapshot.exists:
                current = clean_projection(projection_part(snapshot.to_dict() or {}))
                if current["tenantId"] != projection["tenantId"]:
                    raise LifecycleConflict("The lifecycle projection belongs to another company.")
                if current["revision"] > projection["revision"]:
                    raise LifecycleConflict("A newer lifecycle revision is already projected.")
                if current["revision"] == projection["revision"]:
                    if current != projection:
                        raise LifecycleConflict("A lifecycle revision cannot be replaced.")
                    return current
            transaction.set(self.reference, projection, merge=True)
            return projection

        return write(self.db.transaction(max_attempts=10))

    def enforce(self, state: str, revision: int, now: datetime, reason: str | None = None) -> list[str]:
        affected: list[str] = []
        if state in SERVING_STATES:
            affected = self.recover(revision)
        elif state in LAPSED_STATES:
            affected = self.lapse(revision, reason or LAPSED_STATES[state])
            self.end_work_sessions(revision)
        self.stamp_access(revision, now)
        return affected

    def _projected(self, transaction: firestore.Transaction, revision: int) -> dict[str, Any] | None:
        return self._projected_in(self.reference.get(transaction=transaction), revision)

    @staticmethod
    def _projected_in(snapshot: Any, revision: int) -> dict[str, Any] | None:
        if not snapshot.exists:
            return None
        data = snapshot.to_dict() or {}
        projected = clean_projection(projection_part(data))
        return data if projected["revision"] == revision else None

    def _read_all(self, transaction: firestore.Transaction, references: list[Any]) -> dict[str, Any]:
        return {snapshot.reference.path: snapshot for snapshot in transaction.get_all(references)}

    @staticmethod
    def _chunks(rows: list[Any]) -> list[list[Any]]:
        return [rows[start:start + ROWS_PER_TRANSACTION] for start in range(0, len(rows), ROWS_PER_TRANSACTION)]

    def end_work_sessions(self, revision: int) -> list[str]:
        ended: list[str] = []
        rows = sorted(self.db.collection(LIVE_TRACKING).select(["activeSessionId"]).stream(), key=lambda row: row.id)
        for chunk in self._chunks(rows):
            outcomes = self._end_work_sessions(chunk, revision)
            if outcomes is None:
                break
            ended.extend(row.id for row, outcome in zip(chunk, outcomes) if outcome)
        return ended

    def _end_work_sessions(self, rows: list[Any], revision: int) -> list[bool | None] | None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> list[bool | None] | None:
            expected_held = [
                self.db.collection(HELD_SESSIONS).document(f"{row.id}_{streamed}")
                for row in rows
                for streamed in [(row.to_dict() or {}).get("activeSessionId")]
                if isinstance(streamed, str) and streamed
            ]
            snapshots = self._read_all(
                transaction, [self.reference, *[row.reference for row in rows], *expected_held])
            lifecycle = self._projected_in(snapshots[self.reference.path], revision)
            if lifecycle is None or lifecycle.get("state") not in LAPSED_STATES:
                return None
            changed_held = []
            for row in rows:
                live = snapshots[row.reference.path]
                current = (live.to_dict() or {}).get("activeSessionId") if live.exists else None
                if isinstance(current, str) and current:
                    held = self.db.collection(HELD_SESSIONS).document(f"{row.id}_{current}")
                    if held.path not in snapshots:
                        changed_held.append(held)
            if changed_held:
                snapshots.update(self._read_all(transaction, changed_held))
            outcomes: list[bool | None] = []
            for row in rows:
                reference = row.reference
                live = snapshots[reference.path]
                data = (live.to_dict() or {}) if live.exists else {}
                session_id = data.get("activeSessionId")
                started = data.get("workSessionStartedAt")
                if not isinstance(session_id, str) or not session_id:
                    outcomes.append(None)
                    continue
                held = self.db.collection(HELD_SESSIONS).document(f"{reference.id}_{session_id}")
                known = snapshots[held.path]
                if isinstance(started, datetime) and "serverStartedAt" not in (known.to_dict() or {}):
                    transaction.set(held, {
                        "uid": reference.id,
                        "workSessionId": session_id,
                        "workSessionGeneration": data.get("activeSessionGeneration"),
                        "serverStartedAt": started,
                    }, merge=True)
                if data.get("workSessionStatus") != "active":
                    outcomes.append(None)
                    continue
                transaction.update(reference, {
                    "workSessionStatus": "ended",
                    "status": "inactive",
                    "workSessionEndedAt": firestore.SERVER_TIMESTAMP,
                    "endedReason": COMPANY_PAUSED,
                })
                outcomes.append(True)
            return outcomes

        return write(self.db.transaction(max_attempts=10))

    def stamp_access(self, revision: int, now: datetime) -> dict[str, Any] | None:
        if not isinstance(now, datetime) or now.tzinfo is None:
            raise LifecycleConflict("now must be an aware timestamp.")

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any] | None:
            data = self._projected(transaction, revision)
            if data is None:
                return None
            access = ACCESS_FOR_STATE[data["state"]]
            previous = data.get("access")
            change: dict[str, Any] = {}
            if previous != access:
                change["access"] = access
            if data.get("accessRevision") != revision:
                change["accessRevision"] = revision
            leaving_open = previous == "open" or (
                previous is None and data.get("cutAt") is None and data["state"] in LAPSED_STATES
            )
            if access != "open" and leaving_open:
                change.update({"cutAt": now, "drainUntil": now + drain_length(),
                               "reactivatedAt": firestore.DELETE_FIELD})
            if access == "open" and previous in ("readonly", "closed") and isinstance(data.get("cutAt"), datetime):
                change["reactivatedAt"] = now
            if change:
                transaction.update(self.reference, change)
            return change

        return write(self.db.transaction(max_attempts=10))

    def lapse(
        self,
        revision: int,
        reason: str,
        *,
        after_reason: Callable[[], None] | None = None,
    ) -> list[str]:
        if type(revision) is not int or revision < 1 or reason not in LAPSE_REASONS:
            raise LifecycleConflict("The lapse request is invalid.")
        affected: list[str] = []
        rows = sorted(
            self.db.collection(ACCESS).select(_ACCESS_ROW_FIELDS).stream(),
            key=lambda row: ((row.to_dict() or {}).get("role") in _READ_ONLY_ROLES, row.id),
        )
        if not self._add_reasons(rows, revision, reason, affected, after_reason, by_role=True):
            return affected
        self._add_reasons(self._unlinked_profiles(rows), revision, reason, [], None, by_role=False)
        return affected

    @staticmethod
    def _reason_to_add(data: Mapping[str, Any], reason: str) -> str:
        role = str(data.get("role") or data.get("user_group") or "").lower()
        return READ_ONLY_REASON if role in (*_READ_ONLY_ROLES, "administrator") else reason

    def _add_reasons(
        self,
        rows: list[Any],
        revision: int,
        reason: str,
        affected: list[str],
        after_reason: Callable[[], None] | None,
        *,
        by_role: bool,
    ) -> bool:
        size = 1 if after_reason is not None else ROWS_PER_TRANSACTION
        pending: list[Any] = []
        group: bool | None = None

        def record(row: Any, added: bool | None) -> None:
            if added:
                if after_reason is not None:
                    after_reason()
                affected.append(row.id)

        def flush() -> bool:
            entries = list(pending)
            pending.clear()
            if not entries:
                return True
            outcomes = self._add_reason_batch(entries, revision, reason)
            if outcomes is None:
                return False
            for row, outcome in zip(entries, outcomes):
                record(row, outcome)
            return True

        for row in rows:
            data = row.to_dict() or {}
            row_group = data.get("role") in _READ_ONLY_ROLES if by_role else None
            if pending and row_group != group and not flush():
                return False
            group = row_group
            try:
                converting = row.reference.parent.id == ACCESS and data.get("accessVersion") is None
                _reasons(data.get("disabledReasons", []))
            except LifecycleConflict:
                converting = True
            if converting:
                if not flush():
                    return False
                added = self._add_reason(row.reference, revision, reason)
                if added is False:
                    return False
                record(row, added)
                continue
            pending.append(row)
            if len(pending) >= size and not flush():
                return False
        return flush()

    def _add_reason_batch(self, entries: list[Any], revision: int, reason: str
                          ) -> list[bool | None] | None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> list[bool | None] | None:
            snapshots = self._read_all(transaction, [self.reference, *[row.reference for row in entries]])
            lifecycle = snapshots[self.reference.path]
            if not lifecycle.exists:
                return None
            projected = clean_projection(projection_part(lifecycle.to_dict() or {}))
            if projected["revision"] != revision or projected["state"] not in LAPSED_STATES:
                return None
            outcomes: list[bool | None] = []
            for row in entries:
                account = snapshots[row.reference.path]
                if not account.exists:
                    outcomes.append(None)
                    continue
                data = account.to_dict() or {}
                added = self._reason_to_add(data, reason)
                reasons = _reasons(data.get("disabledReasons", []))
                if added not in reasons:
                    reasons = sorted([*reasons, added])
                    transaction.update(row.reference, {"disabledReasons": reasons})
                    profile_id = data.get("userDocId")
                    if isinstance(profile_id, str) and profile_id and profile_id != row.reference.id:
                        transaction.set(
                            self.db.collection(USERS).document(profile_id),
                            {"disabledReasons": reasons},
                            merge=True,
                        )
                outcomes.append(True)
            return outcomes

        return write(self.db.transaction(max_attempts=10))

    def recover(self, revision: int) -> list[str]:
        restored: list[str] = []
        rows = sorted(self.db.collection(ACCESS).select(_ACCESS_ROW_FIELDS).stream(), key=lambda row: row.id)
        for chunk in self._chunks([row for row in rows if self._holds_lapse_reason(row)]):
            removed = self._remove_lapse_reasons(chunk, revision)
            if removed is None:
                return restored
            changed = [row.id for row, did in zip(chunk, removed) if did]
            for uid, disabled in zip(changed, self._reconcile_auth_all(changed)):
                if not disabled:
                    restored.append(uid)
        profiles = [row for row in self._unlinked_profiles(rows) if self._holds_lapse_reason(row)]
        for chunk in self._chunks(profiles):
            if self._remove_lapse_reasons(chunk, revision) is None:
                break
        return restored

    @staticmethod
    def _holds_lapse_reason(row: Any) -> bool:
        try:
            reasons = _reasons((row.to_dict() or {}).get("disabledReasons", []))
        except LifecycleConflict:
            return True
        return any(reason in LAPSE_REASONS | {READ_ONLY_REASON} for reason in reasons)

    def _reconcile_auth_all(self, uids: list[str]) -> list[bool]:
        if len(uids) < 2:
            return [self.reconcile_auth(uid) for uid in uids]
        with ThreadPoolExecutor(max_workers=min(len(uids), AUTH_WORKERS)) as pool:
            return list(pool.map(self.reconcile_auth, uids))

    def _unlinked_profiles(self, rows: list[Any]) -> list[Any]:
        linked = {row.id for row in rows} | {(row.to_dict() or {}).get("userDocId") for row in rows}
        profiles = self.db.collection(USERS).select(_PROFILE_ROW_FIELDS).stream()
        return sorted((row for row in profiles if row.id not in linked), key=lambda row: row.id)

    def reconcile_auth(self, uid: str) -> bool:
        snapshot = self.db.collection(ACCESS).document(uid).get()
        if not snapshot.exists:
            raise LifecycleConflict("The account access record is missing.")
        data = snapshot.to_dict() or {}
        reasons = _reasons(data.get("disabledReasons", []))
        disabled = bool(
            set(reasons) - LAPSE_REASONS - {READ_ONLY_REASON}
            or data.get("invitationState") == "pending"
            or data.get("status") != "active"
            or data.get("isActive") is False
        )
        try:
            self.access.auth.update_user(uid, disabled=disabled)
            if disabled:
                self.access.auth.revoke_refresh_tokens(uid)
        except admin_auth.UserNotFoundError:
            pass
        return disabled

    def _add_reason(self, reference: Any, revision: int, reason: str) -> bool | None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool | None:
            lifecycle = self.reference.get(transaction=transaction)
            account = reference.get(transaction=transaction)
            if not lifecycle.exists:
                return False
            if not account.exists:
                return None
            projected = clean_projection(projection_part(lifecycle.to_dict() or {}))
            if projected["revision"] != revision or projected["state"] not in LAPSED_STATES:
                return False
            data = account.to_dict() or {}
            converted = None
            if reference.parent.id == ACCESS and data.get("accessVersion") is None:
                converted, _, _ = judge_access_row(
                    reference.id,
                    data,
                    lambda profile_id: self.db.collection(USERS).document(profile_id).get(transaction=transaction),
                )
            source = converted or data
            role = str(source.get("role") or source.get("user_group") or "").lower()
            added = READ_ONLY_REASON if role in (*_READ_ONLY_ROLES, "administrator") else reason
            reasons = _reasons(source.get("disabledReasons", []))
            changed = added not in reasons
            if changed:
                reasons = sorted([*reasons, added])
            if converted is not None:
                transaction.set(reference, {**converted, "disabledReasons": reasons}, merge=True)
            elif changed:
                transaction.update(reference, {"disabledReasons": reasons})
            if changed or converted is not None:
                profile_id = source.get("userDocId")
                if isinstance(profile_id, str) and profile_id and profile_id != reference.id:
                    transaction.set(
                        self.db.collection(USERS).document(profile_id),
                        {"disabledReasons": reasons},
                        merge=True,
                    )
            return True

        return write(self.db.transaction(max_attempts=10))

    def _remove_lapse_reasons(self, rows: list[Any], revision: int) -> list[bool] | None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> list[bool] | None:
            snapshots = self._read_all(transaction, [self.reference, *[row.reference for row in rows]])
            lifecycle = snapshots[self.reference.path]
            if not lifecycle.exists:
                return None
            projected = clean_projection(projection_part(lifecycle.to_dict() or {}))
            if projected["revision"] != revision or projected["state"] not in SERVING_STATES:
                return None
            outcomes: list[bool] = []
            for row in rows:
                account = snapshots[row.reference.path]
                if not account.exists:
                    outcomes.append(False)
                    continue
                data = account.to_dict() or {}
                reasons = _reasons(data.get("disabledReasons", []))
                remaining = [
                    reason for reason in reasons if reason not in LAPSE_REASONS | {READ_ONLY_REASON}
                ]
                if remaining == reasons:
                    outcomes.append(False)
                    continue
                transaction.update(row.reference, {"disabledReasons": remaining})
                profile_id = data.get("userDocId")
                if isinstance(profile_id, str) and profile_id and profile_id != row.reference.id:
                    transaction.set(
                        self.db.collection(USERS).document(profile_id),
                        {"disabledReasons": remaining},
                        merge=True,
                    )
                outcomes.append(True)
            return outcomes

        return write(self.db.transaction(max_attempts=10))

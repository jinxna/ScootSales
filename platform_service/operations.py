from __future__ import annotations

import hashlib
import json
import random
import re
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING, Any, Callable, Mapping, Sequence

from google.api_core.exceptions import Aborted, FailedPrecondition
from google.cloud import firestore

from . import config

if TYPE_CHECKING:
    from .audit import AuditLog

PENDING = "pending"
COMPLETED = "completed"
FAILED = "failed"

_STEP_NAME = re.compile(r"^[A-Za-z0-9_-]+$")
_MESSAGE_LIMIT = 200
MAX_RECOVERY_ATTEMPTS = 5


class OperationError(Exception):
    pass


class LeaseLost(OperationError):
    pass


class RetryLater(OperationError):
    pass


def is_busy(error: BaseException) -> bool:
    return isinstance(error, Aborted) or (isinstance(error, ValueError) and isinstance(error.__cause__, Aborted))


def commit_when_free(function: Any, database: Any, rounds: int = 5) -> Any:
    for attempt in range(rounds):
        try:
            return function(database.transaction(max_attempts=10))
        except (Aborted, ValueError) as error:
            if not is_busy(error) or attempt == rounds - 1:
                raise
            time.sleep(0.05 * (attempt + 1) + random.random() * 0.05)


@dataclass(frozen=True)
class OperationContext:
    operation_id: str
    tenant_id: str | None
    params: Mapping[str, Any]
    results: Mapping[str, Mapping[str, Any]]
    seal: Callable[[firestore.Transaction], None] = lambda transaction: None


@dataclass(frozen=True)
class Step:
    name: str
    apply: Callable[[OperationContext], Mapping[str, Any] | None]
    check: Callable[[OperationContext], bool]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _digest(value: Any) -> str:
    text = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _operation_id(action: str, idempotency_key: str) -> str:
    seed = f"{action}\n{idempotency_key}".encode("utf-8")
    return "op_" + hashlib.sha256(seed).hexdigest()[:32]


def operation_id(action: str, idempotency_key: str) -> str:
    return _operation_id(action, idempotency_key)


class OperationStore:
    def __init__(
        self,
        client: firestore.Client,
        *,
        collection: str = "operations",
        lease_seconds: int | None = None,
        owner: str | None = None,
        audit: AuditLog | None = None,
    ) -> None:
        self.audit = audit
        self._client = client
        self._collection = client.collection(collection)
        self._lease = timedelta(
            seconds=config.OPERATION_LEASE_SECONDS if lease_seconds is None else lease_seconds
        )
        self._owner = owner or f"worker-{uuid.uuid4().hex[:12]}"

    def get(self, operation_id: str) -> dict | None:
        snapshot = self._collection.document(operation_id).get()
        return snapshot.to_dict() if snapshot.exists else None

    def list_by_status(self, action: str, status: str, *, limit: int = 100) -> list[dict]:
        query = (
            self._collection.where(filter=firestore.FieldFilter("action", "==", action))
            .where(filter=firestore.FieldFilter("status", "==", status))
            .limit(limit)
        )
        return [snapshot.to_dict() or {} for snapshot in query.stream()]

    def annotate(self, operation_id: str, fields: Mapping[str, Any]) -> None:
        self._collection.document(operation_id).update(dict(fields))

    def reference(self, operation_id: str) -> Any:
        return self._collection.document(operation_id)

    def _new_record(
        self,
        *,
        idempotency_key: str,
        action: str,
        actor: str,
        tenant_id: str | None,
        reason: str,
        ticket: str | None,
        field_names: Sequence[str],
        params: Mapping[str, Any],
        step_names: Sequence[str],
        now: datetime,
        guard: Mapping[str, str] | None = None,
    ) -> tuple[str, str, dict]:
        if not idempotency_key or not action:
            raise OperationError("An idempotency key and an action are required.")
        names = list(step_names)
        if not names or len(set(names)) != len(names):
            raise OperationError("Step names must be present and unique.")
        for name in names:
            if not _STEP_NAME.match(name):
                raise OperationError(f"Invalid step name: {name!r}")

        operation_id = _operation_id(action, idempotency_key)
        fingerprint = _digest(
            {
                "action": action,
                "actor": actor,
                "tenantId": tenant_id,
                "params": params,
                "stepNames": names,
            }
        )
        record = {
            "operationId": operation_id,
            "action": action,
            "actor": actor,
            "tenantId": tenant_id,
            "reason": reason,
            "ticket": ticket,
            "fieldNames": list(field_names),
            "paramsHash": _digest(params),
            "fingerprint": fingerprint,
            "params": dict(params),
            "steps": {name: {"status": PENDING, "result": None, "finishedAt": None} for name in names},
            "status": PENDING,
            "outcome": None,
            "error": None,
            "createdAt": now,
            "updatedAt": now,
            "leaseOwner": None,
            "leaseUntil": None,
            "guard": dict(guard) if guard else None,
        }
        return operation_id, fingerprint, record

    def stage_begin(self, transaction: firestore.Transaction, staged: Any, existing: Mapping[str, Any] | None,
                    **fields: Any) -> str:
        operation_id, fingerprint, record = self._new_record(now=_utc_now(), **fields)
        if existing is not None:
            if existing.get("fingerprint") != fingerprint:
                raise OperationError("This idempotency key was already used for a different request.")
            return operation_id
        transaction.create(self._collection.document(operation_id), record)
        staged.add(actor=record["actor"], action="operation.begun", tenant_id=record["tenantId"],
                   key=f"begin:{operation_id}", summary=f"{record['actor']} started {record['action']}.",
                   refs={"operationId": operation_id, "operationAction": record["action"]})
        return operation_id

    def begin(
        self,
        *,
        idempotency_key: str,
        action: str,
        actor: str,
        tenant_id: str | None,
        reason: str,
        ticket: str | None,
        field_names: Sequence[str],
        params: Mapping[str, Any],
        step_names: Sequence[str],
        guard: Mapping[str, str] | None = None,
    ) -> str:
        now = _utc_now()
        operation_id, fingerprint, record = self._new_record(
            idempotency_key=idempotency_key, action=action, actor=actor, tenant_id=tenant_id, reason=reason,
            ticket=ticket, field_names=field_names, params=params, step_names=step_names, now=now, guard=guard)
        reference = self._collection.document(operation_id)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            snapshot = reference.get(transaction=transaction)
            if snapshot.exists:
                if (snapshot.to_dict() or {}).get("fingerprint") != fingerprint:
                    raise OperationError(
                        "This idempotency key was already used for a different request."
                    )
                return
            staged = self.audit.stage(transaction, now, tenant_id=tenant_id) if self.audit is not None else None
            transaction.create(reference, record)
            if staged is not None:
                staged.add(actor=actor, action="operation.begun", tenant_id=tenant_id, key=f"begin:{operation_id}",
                           summary=f"{actor} started {action}.",
                           refs={"operationId": operation_id, "operationAction": action})

        commit_when_free(write, self._client)
        return operation_id

    def reopen(self, operation_id: str, actor: str) -> dict:
        reference = self._collection.document(operation_id)
        moment = _utc_now()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                raise OperationError("Unknown operation.")
            record = snapshot.to_dict() or {}
            guard = record.get("guard")
            if guard:
                owner = self._client.collection(guard["collection"]).document(guard["id"]).get(transaction=transaction)
                if (owner.to_dict() or {}).get("status") != guard["status"]:
                    raise OperationError("This request is no longer waiting for its work, so it cannot run again.")
            if record["status"] != FAILED:
                return record
            staged = self.audit.stage(transaction, moment, tenant_id=record.get("tenantId")) if self.audit is not None else None
            fields = self._reopen_fields(record, moment)
            transaction.update(reference, fields)
            if staged is not None:
                self._reopen_event(staged, record, actor, fields)
            return {**record, **fields}

        return commit_when_free(write, self._client)

    @staticmethod
    def _reopen_fields(record: Mapping[str, Any], moment: datetime) -> dict[str, Any]:
        return {"status": PENDING, "outcome": None, "error": None, "leaseOwner": None, "leaseUntil": None,
                "updatedAt": moment, "reopened": int(record.get("reopened") or 0) + 1, "recoveryAttempts": 0}

    @staticmethod
    def _reopen_event(staged: Any, record: Mapping[str, Any], actor: str, fields: Mapping[str, Any]) -> None:
        staged.add(actor=actor, action="operation.reopened", tenant_id=record.get("tenantId"),
                   key=f"reopen:{record['operationId']}:{fields['reopened']}",
                   summary=f"{actor} tried {record.get('action')} again.",
                   refs={"operationId": record["operationId"], "operationAction": record.get("action")})

    def stage_close(self, transaction: firestore.Transaction, record: Mapping[str, Any], moment: datetime) -> None:
        transaction.update(self._collection.document(record["operationId"]), {
            "status": FAILED, "outcome": FAILED, "closed": True, "leaseOwner": None, "leaseUntil": None,
            "error": {"type": "Closed", "message": "Closed by staff before it finished."}, "updatedAt": moment})

    def run(
        self, operation_id: str, steps: Sequence[Step], *, now: datetime | None = None
    ) -> dict:
        reference = self._collection.document(operation_id)
        try:
            record, lease_time = self._take_lease(reference, steps, now or _utc_now())
        except (Aborted, ValueError) as error:
            if not is_busy(error):
                raise
            raise RetryLater("The database was busy. This will be tried again.") from error
        if record is None:
            return self.get(operation_id) or {}
        if record["status"] != PENDING:
            return record

        results: dict[str, Mapping[str, Any]] = {
            name: (state.get("result") or {})
            for name, state in record["steps"].items()
            if state.get("status") == "done"
        }
        try:
            for step in steps:
                if record["steps"][step.name]["status"] == "done":
                    continue
                context = OperationContext(
                    operation_id=operation_id,
                    tenant_id=record.get("tenantId"),
                    params=record.get("params") or {},
                    results=dict(results),
                    seal=self._sealer(reference, step.name, lease_time),
                )
                if step.check(context):
                    result: Mapping[str, Any] = {"alreadyApplied": True}
                else:
                    result = dict(step.apply(context) or {})
                results[step.name] = result
                self._mark_done(reference, step.name, result)
                record["steps"][step.name]["status"] = "done"
        except LeaseLost:
            raise
        except FailedPrecondition as error:
            raise LeaseLost("Another worker or a person changed this operation.") from error
        except RetryLater:
            self._release_lease(reference)
            raise
        except Exception as error:
            if is_busy(error):
                self._release_lease(reference)
                raise RetryLater("The database was busy. This will be tried again.") from error
            self._finish(
                reference,
                FAILED,
                error={
                    "type": type(error).__name__,
                    "message": str(error)[:_MESSAGE_LIMIT],
                },
            )
            raise
        self._finish(reference, COMPLETED)
        return self.get(operation_id) or {}

    def recover(
        self,
        actions: Mapping[str, Sequence[Step]],
        *,
        now: datetime | None = None,
        limit: int = 50,
    ) -> list[str]:
        moment = now or _utc_now()
        finished: list[str] = []
        attempted = 0
        pending = self._collection.where(
            filter=firestore.FieldFilter("status", "==", PENDING)
        )
        for snapshot in pending.stream():
            if attempted >= limit:
                break
            data = snapshot.to_dict() or {}
            steps = actions.get(data.get("action"))
            lease_until = data.get("leaseUntil")
            if steps is None or (lease_until is not None and lease_until >= moment):
                continue
            attempted += 1
            try:
                after = self.run(snapshot.id, steps, now=moment)
            except LeaseLost:
                continue
            except Exception as error:
                self._count_recovery_failure(snapshot.reference, error, moment)
                after = self.get(snapshot.id) or {}
            if after.get("status") in (COMPLETED, FAILED):
                finished.append(snapshot.id)
        return finished

    def _release_lease(self, reference: Any) -> None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            record = reference.get(transaction=transaction).to_dict() or {}
            if record.get("status") == PENDING and record.get("leaseOwner") == self._owner:
                transaction.update(reference, {"leaseOwner": None, "leaseUntil": None})

        commit_when_free(write, self._client)

    def _count_recovery_failure(self, reference: Any, error: Exception, moment: datetime) -> None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            record = reference.get(transaction=transaction).to_dict() or {}
            until = record.get("leaseUntil")
            if record.get("status") != PENDING or (until is not None and until >= moment
                                                   and record.get("leaseOwner") != self._owner):
                return
            attempts = int(record.get("recoveryAttempts") or 0) + 1
            fields: dict[str, Any] = {"recoveryAttempts": attempts, "updatedAt": _utc_now()}
            gave_up = attempts >= MAX_RECOVERY_ATTEMPTS
            staged = self.audit.stage(transaction, tenant_id=record.get("tenantId")) if gave_up and self.audit is not None else None
            failure = {"type": type(error).__name__, "message": str(error)[:_MESSAGE_LIMIT]}
            if gave_up:
                fields.update({"status": FAILED, "outcome": FAILED, "error": failure, "leaseOwner": None,
                               "leaseUntil": None})
            transaction.update(reference, fields)
            if staged is not None:
                staged.add(actor=record.get("actor") or "system", action="operation.failed",
                           tenant_id=record.get("tenantId"),
                           key=f"finish:{record['operationId']}" + (
                               f":{record['reopened']}" if record.get("reopened") else ""),
                           summary=f"{record.get('action')} failed after {attempts} recovery attempts.",
                           refs={"operationId": record["operationId"], "operationAction": record.get("action"),
                                 "errorType": failure["type"]})

        commit_when_free(write, self._client)

    def _take_lease(
        self, reference: Any, steps: Sequence[Step], now: datetime
    ) -> tuple[dict | None, Any]:
        @firestore.transactional
        def take(transaction: firestore.Transaction) -> dict | None:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                raise OperationError("Unknown operation.")
            record = snapshot.to_dict() or {}
            if record["status"] != PENDING:
                return record
            names = [step.name for step in steps]
            if len(names) != len(set(names)) or set(names) != set(record["steps"]):
                raise OperationError("The steps do not match the recorded operation.")
            holder = record.get("leaseOwner")
            until = record.get("leaseUntil")
            if holder and holder != self._owner and until is not None and until >= now:
                return None
            transaction.update(
                reference,
                {
                    "leaseOwner": self._owner,
                    "leaseUntil": now + self._lease,
                    "updatedAt": now,
                },
            )
            return record

        transaction = self._client.transaction(max_attempts=10)
        record = take(transaction)
        written = getattr(transaction, "write_results", None)
        return record, (written[0].update_time if written else None)

    def _fenced_update(self, reference: Any, fields: Mapping[str, Any], *, finished: str | None = None) -> None:
        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            record = reference.get(transaction=transaction).to_dict() or {}
            if record.get("status") != PENDING or record.get("leaseOwner") != self._owner:
                raise LeaseLost("Another worker took over this operation.")
            staged = self.audit.stage(transaction, tenant_id=record.get("tenantId")) if self.audit is not None and finished else None
            transaction.update(reference, dict(fields))
            if staged is not None:
                error = (fields.get("error") or {}).get("type")
                staged.add(actor=record.get("actor") or "system", action=f"operation.{finished}",
                           tenant_id=record.get("tenantId"),
                           key=f"finish:{record['operationId']}" + (f":{record['reopened']}" if record.get("reopened") else ""),
                           summary=f"{record.get('action')} {finished}.",
                           refs={"operationId": record["operationId"], "operationAction": record.get("action"),
                                 "errorType": error})

        commit_when_free(write, self._client)

    def _sealer(self, reference: Any, name: str, lease_time: Any) -> Callable[[firestore.Transaction], None]:
        option = self._client.write_option(last_update_time=lease_time) if lease_time is not None else None

        def seal(transaction: firestore.Transaction) -> None:
            now = _utc_now()
            transaction.update(reference, {f"steps.{name}.status": "done", f"steps.{name}.finishedAt": now,
                                           "updatedAt": now}, option=option)

        return seal

    def _mark_done(self, reference: Any, name: str, result: Mapping[str, Any]) -> None:
        now = _utc_now()
        self._fenced_update(
            reference,
            {
                f"steps.{name}.status": "done",
                f"steps.{name}.result": dict(result),
                f"steps.{name}.finishedAt": now,
                "leaseUntil": now + self._lease,
                "updatedAt": now,
            },
        )

    def _finish(
        self, reference: Any, status: str, *, error: Mapping[str, str] | None = None
    ) -> None:
        self._fenced_update(
            reference,
            {
                "status": status,
                "outcome": status,
                "error": dict(error) if error else None,
                "leaseOwner": None,
                "leaseUntil": None,
                "updatedAt": _utc_now(),
            },
            finished=status,
        )

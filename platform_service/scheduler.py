from __future__ import annotations

import asyncio
import contextlib
import hashlib
import logging
import os
import secrets
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Iterable, Sequence

from google.cloud import firestore

from . import config
from .account_deletion import AccountDeletions
from .account_security import watch_passwords
from .commands import CommandProblem
from .approvals import waiting_approvals
from .audit import AuditLog, canonical
from .company_access import CompanyAccess, company_access, platform_project_auth, project_auth, require_company_credentials
from .directory import COMPANIES, DirectoryStore, renew_directory_records
from .gps_purge import purge_old_positions
from .ids import KUALA_LUMPUR, last_day, local_date
from .invoices import (
    DRAFT, DUE_DAYS, ISSUED, InvoiceBook, bill_not_delivered, bill_waiting_for_delivery, invoice_delivery,
    open_ended_through, overdue_invoices)
from .lifecycle import ACTION_LIFECYCLE, LifecycleService
from .mail import (
    STAFF_MAIL_TENANT, MailQueue, MailTransport, build_transport, company_contact, deliver_mail, require_mail_ready,
)
from .onboarding import OnboardingDrafts
from .operations import COMPLETED, FAILED, OperationError, OperationStore, RetryLater, Step
from .order_price_check import check_orders
from .payments import PaymentLedger
from .signing import Keyring, Signer, format_timestamp, parse_timestamp
from .staff import active_accounts, solo_owner
from .usage_reconciler import UsageReconciler

LEASES = "scheduler_leases"
WORKERS = 4
_LOG = logging.getLogger("platform_service.scheduler")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


@dataclass(frozen=True)
class Job:
    name: str
    interval_seconds: int
    lease_seconds: int
    run: Callable[[], Any]
    max_run_seconds: int = 3600


class Scheduler:
    def __init__(self, db: firestore.Client, jobs: Sequence[Job], *, project_id: str | None = None,
                 owner: str | None = None, clock: Callable[[], datetime] = _utc_now,
                 poll_seconds: float | None = None, failure_retry_seconds: int = 300,
                 lease_collection: str = LEASES):
        expected = project_id if project_id is not None else config.PLATFORM_PROJECT_ID
        if db.project != expected:
            raise ValueError("The scheduler Firestore client is not bound to the platform project.")
        names = [job.name for job in jobs]
        if len(set(names)) != len(names):
            raise ValueError("Scheduler job names must be unique.")
        for job in jobs:
            if job.interval_seconds < 1 or job.lease_seconds < 1 or job.max_run_seconds < 1:
                raise ValueError("Scheduler intervals, leases and run limits must be positive.")
        self.db = db
        self.jobs = list(jobs)
        self.project_id = expected
        self.owner = owner or f"{socket.gethostname()}-{os.getpid()}-{secrets.token_hex(4)}"
        self.clock = clock
        self.poll_seconds = config.SCHEDULER_POLL_SECONDS if poll_seconds is None else poll_seconds
        self.failure_retry_seconds = failure_retry_seconds
        self.lease_collection = lease_collection
        self._task: asyncio.Task | None = None
        self._stop: asyncio.Event | None = None
        self._due: dict[str, str] = {}

    def job_names(self) -> list[str]:
        return [job.name for job in self.jobs]

    def run_due(self, only: Sequence[str] | None = None) -> dict[str, str]:
        selected = [job for job in self.jobs if only is None or job.name in only]
        stamp = _stamp(self.clock())
        ready = [job for job in selected if self._due.get(job.name, "") <= stamp]
        outcomes = {job.name: "not_due" for job in selected}
        for job in ready:
            outcomes[job.name] = self._run(job)
        return outcomes

    def _run(self, job: Job) -> str:
        try:
            token = self._claim(job)
        except Exception:
            _LOG.exception("Scheduler could not claim job %s.", job.name)
            return "error"
        if token is None:
            return "not_due"
        finished = threading.Event()
        beat = threading.Thread(target=self._keep_lease, args=(job, token, finished), daemon=True)
        beat.start()
        try:
            result = job.run()
        except Exception as error:
            _LOG.exception("Scheduler job %s failed.", job.name)
            self._stop_beat(finished, beat)
            self._release(job, token, False, f"{type(error).__name__}: {str(error)[:300]}")
            return "failed"
        self._stop_beat(finished, beat)
        self._release(job, token, True, str(result)[:1000])
        return "ran"

    @staticmethod
    def _stop_beat(finished: threading.Event, beat: threading.Thread) -> None:
        finished.set()
        beat.join()

    def _keep_lease(self, job: Job, token: str, finished: threading.Event) -> None:
        reference = self.db.collection(self.lease_collection).document(job.name)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool:
            state = reference.get(transaction=transaction).to_dict() or {}
            if state.get("leaseToken") != token:
                return False
            now = self.clock()
            transaction.update(reference, {"leaseExpiresAt": _stamp(now + timedelta(seconds=job.lease_seconds)),
                                           "heartbeatAt": _stamp(now)})
            return True

        deadline = time.monotonic() + job.max_run_seconds
        while not finished.wait(max(1.0, job.lease_seconds / 3)):
            if time.monotonic() >= deadline:
                _LOG.warning("Scheduler job %s ran longer than %s seconds, so its lease is no longer renewed.",
                             job.name, job.max_run_seconds)
                return
            try:
                if not write(self.db.transaction(max_attempts=3)):
                    return
            except Exception:
                _LOG.exception("Scheduler could not extend the lease of job %s.", job.name)

    def _claim(self, job: Job) -> str | None:
        reference = self.db.collection(self.lease_collection).document(job.name)
        token = secrets.token_urlsafe(18)
        now = self.clock()
        stamp = _stamp(now)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> tuple[bool, str]:
            snapshot = reference.get(transaction=transaction)
            state = snapshot.to_dict() if snapshot.exists else {}
            next_run = state.get("nextRunAt") or ""
            if (state.get("leaseExpiresAt") or "") > stamp or next_run > stamp:
                return False, next_run
            transaction.set(reference, {**state, "project": self.project_id, "leaseToken": token,
                                        "leaseOwner": self.owner, "lastStartedAt": stamp,
                                        "leaseExpiresAt": _stamp(now + timedelta(seconds=job.lease_seconds))})
            return True, ""

        claimed, next_run = write(self.db.transaction(max_attempts=10))
        if claimed:
            return token
        if next_run > stamp:
            self._due[job.name] = next_run
        return None

    def _release(self, job: Job, token: str, ok: bool, detail: str) -> None:
        reference = self.db.collection(self.lease_collection).document(job.name)
        now = self.clock()
        delay = job.interval_seconds if ok else min(job.interval_seconds, self.failure_retry_seconds)
        next_run = _stamp(now + timedelta(seconds=delay))

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool:
            snapshot = reference.get(transaction=transaction)
            state = snapshot.to_dict() if snapshot.exists else {}
            if state.get("leaseToken") != token:
                return False
            transaction.set(reference, {**state, "leaseToken": None, "leaseOwner": None,
                                        "leaseExpiresAt": None, "nextRunAt": next_run,
                                        "lastRunAt": _stamp(now), "lastRunOwner": self.owner,
                                        "lastStatus": "ran" if ok else "failed",
                                        "lastError": None if ok else detail,
                                        "lastResult": detail if ok else None})
            return True

        try:
            if write(self.db.transaction(max_attempts=10)):
                self._due[job.name] = next_run
        except Exception:
            _LOG.exception("Scheduler could not release job %s.", job.name)

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    async def start(self) -> None:
        if self.running:
            return
        self._stop = asyncio.Event()
        self._task = asyncio.create_task(self._loop())

    async def stop(self, timeout: float = 30.0) -> None:
        if self._task is None or self._stop is None:
            return
        self._stop.set()
        try:
            await asyncio.wait_for(self._task, timeout)
        except asyncio.TimeoutError:
            _LOG.warning("Scheduler did not stop within %s seconds.", timeout)
        self._task = None

    async def _loop(self) -> None:
        assert self._stop is not None
        while not self._stop.is_set():
            try:
                await asyncio.to_thread(self.run_due)
            except Exception:
                _LOG.exception("Scheduler pass failed.")
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._stop.wait(), self.poll_seconds)


def install(app: Any, build: Callable[[], Scheduler], *, enabled: bool | None = None) -> None:
    if not (config.SCHEDULER_ENABLED if enabled is None else enabled):
        return
    inner = app.router.lifespan_context

    @contextlib.asynccontextmanager
    async def lifespan(application: Any):
        scheduler = build()
        application.state.scheduler = scheduler
        await scheduler.start()
        try:
            async with inner(application) as state:
                yield state
        finally:
            await scheduler.stop()

    app.router.lifespan_context = lifespan


REMINDERS = "renewal_reminders"
REMINDER_DAYS = (14, 3)
_REMINDER_STATES = frozenset({"active", "past_due"})


def send_renewal_reminders(db: firestore.Client, queue: Any, *, now: datetime) -> dict[str, int]:
    ledger = PaymentLedger(db, clock=lambda: now, mail=MailQueue(db, enabled=False))
    counts = {"queued": 0, "skipped": 0, "errors": 0}
    for snapshot in db.collection("lifecycle").stream():
        tenant_id = snapshot.id
        try:
            if (snapshot.to_dict() or {}).get("state") not in _REMINDER_STATES:
                continue
            end = ledger.coverage(tenant_id, now).checked_end
            if end is None or end <= now:
                continue
            days_left = (end - now).total_seconds() / 86400
            threshold = next((day for day in sorted(REMINDER_DAYS) if days_left <= day), None)
            if threshold is None:
                continue
            date = last_day(end)
            reference = db.collection(REMINDERS).document(f"{tenant_id}_{date}_{threshold}")
            if (reference.get().to_dict() or {}).get("status") == "queued":
                continue
            contact = company_contact(db, tenant_id)
            if contact is None or contact[1] is None:
                outcome = {"status": "skipped", "jobId": None, "reason": "The company has no billing email."}
            else:
                outcome = queue.enqueue_or_report(
                    tenant_id, f"renewal-{tenant_id}-{date}-{threshold}", "renewal_reminder", contact[1],
                    {"tenantId": tenant_id, "companyName": contact[0], "expiresAt": date}, "scheduler")
            if outcome["status"] == "skipped":
                counts["skipped"] += 1
            elif outcome["status"] == "queued":
                counts["queued"] += 1
            else:
                counts["errors"] += 1
                continue
            reference.set({"tenantId": tenant_id, "expiresAt": date, "threshold": threshold,
                           "status": outcome["status"], "reason": outcome.get("reason"),
                           "jobId": outcome["jobId"], "createdAt": _stamp(now)})
        except Exception:
            _LOG.exception("Renewal reminder failed for %s.", tenant_id)
            counts["errors"] += 1
    return counts


RENEWAL_BLOCKS = "renewal_blocks"
INVOICE_EXISTS_FOR_PERIOD = "An invoice already exists for this period"
DRAFT_LEAD = timedelta(days=14)
_LIVE_STATES = frozenset({"active", "past_due"})


def draft_renewal_invoices(db: firestore.Client, book: InvoiceBook, *, now: datetime) -> dict[str, int]:
    ledger = PaymentLedger(db, clock=lambda: now, mail=MailQueue(db, enabled=False))
    counts = {"drafted": 0, "skipped": 0, "blocked": 0, "errors": 0}
    blocks = db.collection(RENEWAL_BLOCKS)
    stale = {snapshot.id for snapshot in blocks.stream()}
    for snapshot in db.collection("lifecycle").stream():
        tenant_id = snapshot.id
        try:
            if (snapshot.to_dict() or {}).get("state") not in _LIVE_STATES:
                continue
            paid_to = ledger.coverage(tenant_id, now).checked_end
            if paid_to is None or paid_to - now > DRAFT_LEAD:
                counts["skipped"] += 1
                continue

            def starts_that_day() -> bool:
                return any(row["status"] != "void"
                           and local_date(parse_timestamp(row["periodStart"])) == local_date(paid_to)
                           for row in book.list_invoices(tenant_id))

            if open_ended_through(db, tenant_id, paid_to) and starts_that_day():
                counts["skipped"] += 1
                continue
            try:
                period_start = format_timestamp(paid_to)
                voided = [row for row in book.list_invoices(tenant_id)
                          if row["status"] == "void" and row["periodStart"] == period_start]
                if any(not row.get("creditedMinor", 0) for row in voided):
                    counts["skipped"] += 1
                    continue
                closed = len(voided)
                book.create_draft(tenant_id, f"renewal-{paid_to:%Y%m%d}" + (f"-{closed}" if closed else ""),
                                  {"periodStart": period_start}, "scheduler")
            except CommandProblem as problem:
                if str(problem).startswith(INVOICE_EXISTS_FOR_PERIOD) and starts_that_day():
                    counts["skipped"] += 1
                    continue
                blocks.document(tenant_id).set({"tenantId": tenant_id, "reason": str(problem),
                                                "coverEndsAt": format_timestamp(paid_to), "since": _stamp(now)})
                stale.discard(tenant_id)
                counts["blocked"] += 1
                continue
            counts["drafted"] += 1
        except Exception:
            _LOG.exception("Renewal invoice draft failed for %s.", tenant_id)
            stale.discard(tenant_id)
            counts["errors"] += 1
    for tenant_id in stale:
        blocks.document(tenant_id).delete()
    return counts


RETENTION_SCAN_LIMIT = 2000
RETENTION_BATCH = 400
DELETABLE_MAIL_STATUSES = frozenset({"sent", "failed"})
INVOICE_MAIL_KIND = "invoice"


def _delete_old(db: firestore.Client, collection: str, field: str, cutoff: Any,
                keep: Callable[[dict[str, Any]], bool]) -> int:
    deleted = 0
    last = None
    while deleted < RETENTION_SCAN_LIMIT:
        query = db.collection(collection).where(filter=firestore.FieldFilter(field, "<", cutoff)).order_by(field)
        if last is not None:
            query = query.start_after(last)
        page = list(query.limit(RETENTION_BATCH).stream())
        if not page:
            break
        last = page[-1]
        batch = db.batch()
        for row in page:
            if not keep(row.to_dict() or {}):
                batch.delete(row.reference)
                deleted += 1
        batch.commit()
    return deleted


def purge_old_records(db: firestore.Client, *, now: datetime) -> dict[str, int]:
    cutoff = now - timedelta(days=config.MAIL_AND_LIMIT_RETENTION_DAYS)
    return {"mailJobs": _delete_old(db, "mail_jobs", "updatedAt", _stamp(cutoff),
                                    lambda job: job.get("status") not in DELETABLE_MAIL_STATUSES
                                    or job.get("kind") == INVOICE_MAIL_KIND),
            "rateLimits": _delete_old(db, "rate_limits", "expiresAt", cutoff, lambda _: False)}


UNDELIVERED_BILL = "The bill for the next period was not delivered. Send it again."


def _past_due_cause(db: firestore.Client, ledger: PaymentLedger, tenant_id: str,
                    now: datetime, *, wait_for_bill: bool = True) -> tuple[str, str] | None:
    overdue = overdue_invoices(db, tenant_id, now)
    if overdue:
        invoice = overdue[0]
        reason = f"Invoice {invoice['number']} is unpaid {DUE_DAYS} days after delivery."
        if any(row.get("invoiceId") == invoice["invoiceId"] for row in ledger.voided_payments(tenant_id)):
            reason += " Its payment was voided."
        return ("invoice-" + invoice["invoiceId"], reason)
    cover = ledger.coverage(tenant_id, now)
    paid_until = cover.paid_until
    if paid_until is not None and paid_until <= now:
        if wait_for_bill and bill_waiting_for_delivery(db, tenant_id, paid_until):
            return None
        if cover.held_end == paid_until:
            return (f"lapse-{tenant_id}-{_stamp(paid_until)}",
                    f"A payment has not been checked against the bank statement. Cover from unchecked payments ended on {last_day(paid_until)}.")
        lapse = f"Paid cover ended on {last_day(paid_until)}."
        if any(isinstance(row.get("periodEnd"), datetime) and row["periodEnd"] > now
               for row in ledger.voided_payments(tenant_id)):
            lapse += " A payment was voided."
        return (f"lapse-{tenant_id}-{_stamp(paid_until)}", lapse)
    if paid_until is None:
        voided = ledger.latest_void(tenant_id)
        if voided is not None:
            return (f"void-{voided['entryId']}",
                    "A payment was voided and the company has no other paid cover.")
    return None


def mark_past_due(db: firestore.Client, lifecycle: LifecycleService, *, now: datetime,
                  invoices: InvoiceBook | None = None) -> dict[str, int]:
    ledger = PaymentLedger(db, clock=lambda: now, mail=MailQueue(db, enabled=False))
    mail = invoices.mail if invoices is not None else MailQueue(db, enabled=False)
    counts = {"pastDue": 0, "restored": 0, "pending": 0, "skipped": 0, "errors": 0, "recovered": 0}
    if invoices is not None:
        try:
            invoices.settle_pending()
        except Exception:
            _LOG.exception("Invoice delivery check failed.")
            counts["errors"] += 1
    try:
        counts["recovered"] = len(lifecycle.runner.recover(lifecycle.recovery_actions(), now=now))
    except Exception:
        _LOG.exception("Lifecycle recovery failed.")
        counts["errors"] += 1
    for snapshot in db.collection("lifecycle").where(
            filter=firestore.FieldFilter("state", "in", ["active", "past_due"])).stream():
        tenant_id = snapshot.id
        try:
            data = snapshot.to_dict() or {}
            cause = _past_due_cause(db, ledger, tenant_id, now)
            if data.get("state") == "past_due":
                cover = ledger.coverage(tenant_id, now)
                covering = cover.checked_covering
                if cause is not None or not covering:
                    stored = str(data.get("reason") or "")
                    reason = cause[1] if cause is not None else None
                    ended = cover.paid_until
                    if (cause is None and ended is not None and ended <= now
                            and bill_not_delivered(db, mail, tenant_id, ended)):
                        reason = f"Paid cover ended on {last_day(ended)}. {UNDELIVERED_BILL}"
                    elif cause is None and stored.endswith(UNDELIVERED_BILL):
                        lapse = _past_due_cause(db, ledger, tenant_id, now, wait_for_bill=False)
                        reason = lapse[1] if lapse is not None else None
                    if (reason is not None and reason != stored
                            and (reason.endswith(UNDELIVERED_BILL) or stored.endswith(UNDELIVERED_BILL))):
                        lifecycle.store.restate_past_due(tenant_id, reason, expected_revision=data["revision"],
                                                         actor="scheduler", now=now)
                    continue
                cause = (f"back-to-active-{covering[0]}", "Nothing is overdue and a checked payment covers the company today.",
                         "active", covering[0])
            elif cause is None:
                continue
            else:
                cause = (*cause, "past_due", None)
            steps = lifecycle.transition_steps()
            revision = data["revision"]
            try:
                operation_id = lifecycle.runner.begin(
                    idempotency_key=f"{cause[2].replace('_', '-')}-{cause[0]}-r{revision}", action=ACTION_LIFECYCLE,
                    actor="scheduler", tenant_id=tenant_id, reason=cause[1], ticket=None,
                    field_names=["state", "expectedRevision", "paymentEntryId"],
                    params={"tenantId": tenant_id, "state": cause[2], "expectedRevision": revision,
                            "paymentEntryId": cause[3], "reason": cause[1], "ticket": None, "requestedBy": "scheduler"},
                    step_names=[step.name for step in steps])
            except OperationError:
                counts["skipped"] += 1
                continue
            outcome = lifecycle.runner.run(operation_id, steps)
            if outcome.get("status") == COMPLETED:
                counts["restored" if cause[2] == "active" else "pastDue"] += 1
            elif outcome.get("status") == FAILED:
                counts["errors"] += 1
            else:
                counts["pending"] += 1
        except RetryLater:
            counts["pending"] += 1
        except Exception:
            _LOG.exception("Past due check failed for %s.", tenant_id)
            counts["errors"] += 1
    return counts


STAFF_DIGESTS = "staff_digests"
DIGEST_HOUR = 9
DIGEST_ROLES = ("owner", "operator")


def companies_past_grace(db: firestore.Client, now: datetime) -> list[tuple[str, datetime]]:
    rows = []
    for snapshot in db.collection("lifecycle").where(filter=firestore.FieldFilter("state", "==", "past_due")).stream():
        ends = (snapshot.to_dict() or {}).get("graceEndsAt")
        if isinstance(ends, datetime) and ends <= now:
            rows.append((snapshot.id, ends))
    return sorted(rows, key=lambda row: (row[1], row[0]))


def _shared_counts(db: firestore.Client, now: datetime) -> dict[str, int]:
    def count(field: str, value: str, collection: str) -> int:
        return sum(1 for _ in db.collection(collection).where(filter=firestore.FieldFilter(field, "==", value)).stream())

    mail = MailQueue(db, enabled=False)
    issued = [snapshot.to_dict() or {} for snapshot in db.collection("invoices").where(
        filter=firestore.FieldFilter("status", "==", ISSUED)).stream()]
    return {"invoicesToIssue": count("status", DRAFT, "invoices"),
            "invoicesToSend": sum(
                1 for row in issued
                if row.get("sendRequestedAt") is None or (invoice_delivery(mail, row) or {}).get("state") == "not_delivered"),
            "companiesPastDue": count("state", "past_due", "lifecycle"),
            "companiesGraceOver": len(companies_past_grace(db, now))}


def staff_open_items(db: firestore.Client, ledger: PaymentLedger, now: datetime,
                     person: str | None) -> dict[str, int]:
    solo = person is not None and solo_owner(db, person)
    return {"paymentsToCheck": sum(1 for row in ledger.awaiting_check(person, None, solo) if row["canCheck"]),
            "approvalsWaiting": waiting_approvals(db, now, not_by=None if solo else person), **_shared_counts(db, now)}


def expire_support_grants(db: firestore.Client, *, now: datetime) -> dict[str, int]:
    expired = 0
    for snapshot in db.collection("support_grants").where(
            filter=firestore.FieldFilter("status", "==", "active")).stream():
        ends = (snapshot.to_dict() or {}).get("expiresAt")
        if not isinstance(ends, datetime) or ends > now:
            continue

        @firestore.transactional
        def write(transaction: firestore.Transaction, reference: Any = snapshot.reference) -> bool:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current.get("status") != "active":
                return False
            transaction.update(reference, {"status": "expired", "expiredAt": now,
                                           "revision": int(current.get("revision") or 1) + 1})
            return True

        expired += write(db.transaction(max_attempts=10))
    return {"expired": expired}


def send_audit_anchors(db: firestore.Client, queue: MailQueue, *, now: datetime) -> dict[str, Any]:
    if not config.FINANCE_EMAIL:
        return {"skipped": "No finance address is set."}
    sent = errors = 0
    by_day: dict[str, list[Any]] = {}
    for snapshot in db.collection("audit_digests").stream():
        data = snapshot.to_dict() or {}
        if data.get("anchoredAt") or not data.get("headHash"):
            continue
        by_day.setdefault(data.get("day") or snapshot.id, []).append((snapshot, data))
    for day, digests in sorted(by_day.items()):
        if [snapshot.id for snapshot, _ in digests] == [day]:
            key, head_hash = f"audit-anchor-{day}", digests[0][1]["headHash"]
        else:
            heads = {snapshot.id: data["headHash"] for snapshot, data in digests}
            head_hash = hashlib.sha256(canonical(heads).encode("utf-8")).hexdigest()
            key = f"audit-anchor-{day}-{head_hash[:16]}"
        outcome = queue.enqueue_or_report(
            STAFF_MAIL_TENANT, key, "audit_anchor", config.FINANCE_EMAIL,
            {"tenantId": STAFF_MAIL_TENANT, "day": day, "count": sum(data["count"] for _, data in digests),
             "headHash": head_hash}, "scheduler")
        if outcome["status"] == "queued":
            for snapshot, _ in digests:
                snapshot.reference.update({"anchoredAt": _stamp(now)})
            sent += 1
        else:
            errors += 1
    return {"sent": sent, "errors": errors}


def send_staff_digest(db: firestore.Client, queue: MailQueue, *, now: datetime) -> dict[str, Any]:
    local = now.astimezone(KUALA_LUMPUR)
    if local.hour < DIGEST_HOUR:
        return {"skipped": "The digest is sent from 9 am Kuala Lumpur time."}
    date = local.date().isoformat()
    marker = db.collection(STAFF_DIGESTS).document(date)
    state = marker.get().to_dict() or {}
    if state.get("complete"):
        return {"skipped": "The digest was already sent today."}
    ledger = PaymentLedger(db, clock=lambda: now, mail=MailQueue(db, enabled=False))
    recipients: list[tuple[str, dict[str, int]]] = []
    if config.FINANCE_EMAIL:
        recipients.append((config.FINANCE_EMAIL, staff_open_items(db, ledger, now, None)))
    for email, role in sorted(active_accounts(db).items()):
        if role in DIGEST_ROLES:
            counts = staff_open_items(db, ledger, now, email)
            if any(counts.values()):
                recipients.append((email, counts))
    done = set(state.get("done") or [])
    errors = 0
    for email, counts in recipients:
        tag = hashlib.sha256(email.encode("utf-8")).hexdigest()[:16]
        if tag in done:
            continue
        outcome = queue.enqueue_or_report(
            STAFF_MAIL_TENANT, f"staff-digest-{date}-{tag}", "staff_digest", email,
            {"tenantId": STAFF_MAIL_TENANT, "date": date, "counts": counts}, "scheduler")
        if outcome["status"] == "queued":
            done.add(tag)
        else:
            errors += 1
    marker.set({"date": date, "done": sorted(done), "complete": errors == 0, "updatedAt": _stamp(now)})
    return {"queued": len(done), "errors": errors}


def _counts(result: dict[str, Any]) -> dict[str, Any]:
    return {key: len(value) if isinstance(value, list) else value for key, value in result.items()}


def _mail_delivery(queue: MailQueue, worker_id: str, transport: Callable[[], MailTransport],
                   invoices: InvoiceBook | None = None) -> Callable[[], dict[str, Any]]:
    def deliver() -> dict[str, Any]:
        if not queue.enabled:
            return {"skipped": "Transactional mail delivery is disabled."}
        result = _counts(deliver_mail(queue, transport=transport(), worker_id=worker_id))
        if invoices is not None:
            result.update({f"invoice_{key}": value for key, value in invoices.settle_pending().items()})
        return result

    return deliver


def build_scheduler(db: firestore.Client, *, project_id: str | None = None,
                    tenant_clients: Callable[[], Iterable[tuple[str, Callable[[], firestore.Client]]]] | None = None,
                    access_for: Callable[[Any], CompanyAccess] = company_access,
                    lifecycle: LifecycleService | None = None, invoices: InvoiceBook | None = None,
                    audit: AuditLog | None = None, subscriptions: Any | None = None,
                    operations: OperationStore | None = None,
                    recovery: Callable[[], dict[str, list[Step]]] | None = None,
                    transport: Callable[[], MailTransport] = build_transport,
                    clock: Callable[[], datetime] = _utc_now, **options: Any) -> Scheduler:
    require_company_credentials()
    queue = MailQueue(db, clock=clock)
    if queue.enabled:
        require_mail_ready(transport())
    owner_label = f"scheduler-{os.getpid()}"

    def renew() -> dict[str, Any]:
        directory = DirectoryStore(db, keyring=Keyring.from_environment(), signer=Signer.from_environment())
        return _counts(renew_directory_records(directory, now=clock()))

    def company_snapshots() -> list[Any]:
        return list(db.collection(COMPANIES).stream())

    def across_companies(work: Callable[[Any], Any], snapshots: Sequence[Any]) -> list[Any]:
        if len(snapshots) < 2:
            return [work(snapshot) for snapshot in snapshots]
        with ThreadPoolExecutor(max_workers=min(len(snapshots), WORKERS)) as pool:
            return list(pool.map(work, snapshots))

    def reconcile() -> dict[str, Any]:
        directory = DirectoryStore(db, keyring=Keyring.from_environment())
        reconciler = UsageReconciler(db, directory, access_for=access_for, clock=clock)

        def reconcile_one(snapshot: Any) -> str | None:
            try:
                reconciler.reconcile(snapshot.id)
            except Exception:
                _LOG.exception("Usage reconcile failed for %s.", snapshot.id)
                return snapshot.id
            return None

        outcomes = across_companies(reconcile_one, company_snapshots())
        failed = [tenant_id for tenant_id in outcomes if tenant_id is not None]
        return {"reconciled": len(outcomes) - len(failed), "failed": failed}

    def directory_tenant_clients() -> Iterable[tuple[str, Callable[[], firestore.Client]]]:
        directory = DirectoryStore(db, keyring=Keyring.from_environment())
        for snapshot in company_snapshots():
            yield snapshot.id, lambda snapshot=snapshot: access_for(directory.from_snapshot(snapshot)["location"]).db

    def account_deletion() -> dict[str, Any]:
        directory = DirectoryStore(db, keyring=Keyring.from_environment())
        runner = operations or OperationStore(db, audit=audit)
        totals = {"accepted": 0, "cancelled": 0, "purged": 0, "failed": 0}
        failed: list[str] = []
        for snapshot in company_snapshots():
            tenant_id = snapshot.id
            try:
                record = directory.from_snapshot(snapshot)
                if record["status"] != "live":
                    continue
                deletions = AccountDeletions(
                    access_for(record["location"]), tenant_id, lambda name=record["legalName"]: name,
                    runner=runner, mail=queue, platform=db, clock=clock)
                outcome = deletions.run(apply=True)
            except Exception:
                _LOG.exception("Account deletion failed for %s.", tenant_id)
                failed.append(tenant_id)
                continue
            totals = _deletion_totals(totals, outcome)
        return {**totals, "companiesFailed": failed}

    def password_watch() -> dict[str, Any]:
        return watch_passwords(db, queue, directory=DirectoryStore(db, keyring=Keyring.from_environment()),
                               access_for=access_for,
                               staff_auth=(lambda: project_auth(project_id)) if project_id else platform_project_auth)

    def reminders() -> dict[str, Any]:
        if not queue.enabled:
            return {"skipped": "Transactional mail delivery is disabled."}
        return send_renewal_reminders(db, queue, now=clock())

    def for_each_company(action: Callable[[firestore.Client], int]) -> dict[str, Any]:
        def run_one(entry: tuple[str, Callable[[], firestore.Client]]) -> tuple[int, str | None]:
            tenant_id, open_client = entry
            try:
                return action(open_client()), None
            except Exception:
                _LOG.exception("Company job failed for %s.", tenant_id)
                return 0, tenant_id

        outcomes = across_companies(run_one, list((tenant_clients or directory_tenant_clients)()))
        return {"done": sum(done for done, _ in outcomes),
                "failed": [tenant_id for _, tenant_id in outcomes if tenant_id is not None]}

    jobs = [Job("mail", config.SCHEDULER_MAIL_SECONDS, 120, _mail_delivery(queue, owner_label, transport, invoices)),
            Job("renew", config.SCHEDULER_RENEW_SECONDS, 900, renew),
            Job("reconcile", config.SCHEDULER_RECONCILE_SECONDS, 900, reconcile),
            Job("reminders", config.SCHEDULER_REMINDER_SECONDS, 900, reminders),
            Job("price_check", config.SCHEDULER_PRICE_CHECK_SECONDS, 120,
                lambda: for_each_company(lambda company_db: check_orders(company_db, now=clock())["checked"])),
            Job("purge", config.SCHEDULER_PURGE_SECONDS, 900,
                lambda: for_each_company(lambda company_db: purge_old_positions(company_db, now=clock()))),
            Job("retention", config.SCHEDULER_PURGE_SECONDS, 900, lambda: purge_old_records(db, now=clock())),
            Job("account_deletion", config.SCHEDULER_ACCOUNT_DELETION_SECONDS, 600, account_deletion),
            Job("password_watch", config.SCHEDULER_PASSWORD_WATCH_SECONDS, 600, password_watch),
            Job("support_grant_expiry", config.SCHEDULER_SUPPORT_GRANT_EXPIRY_SECONDS, 900,
                lambda: expire_support_grants(db, now=clock()))]
    if recovery is not None:
        def recover_operations() -> dict[str, Any]:
            return {"finished": len((operations or OperationStore(db, audit=audit)).recover(recovery(), now=clock()))}

        jobs.append(Job("recover_operations", config.SCHEDULER_RECOVERY_SECONDS, 600, recover_operations))
    if audit is not None:
        def staff_digest() -> dict[str, Any]:
            if not queue.enabled:
                return {"skipped": "Transactional mail delivery is disabled."}
            return send_staff_digest(db, queue, now=clock())

        def audit_digest() -> dict[str, Any]:
            result = audit.run_digests()
            if queue.enabled:
                result["anchors"] = send_audit_anchors(db, queue, now=clock())
            return result

        def onboarding_expiry() -> dict[str, Any]:
            return {"ended": OnboardingDrafts(db, audit, clock=clock).expire_due(clock())}

        jobs.append(Job("onboarding_expiry", config.SCHEDULER_ONBOARDING_SECONDS, 900, onboarding_expiry))
        jobs.append(Job("audit_digest", config.SCHEDULER_AUDIT_DIGEST_SECONDS, 900, audit_digest))
        jobs.append(Job("staff_digest", config.SCHEDULER_STAFF_DIGEST_SECONDS, 900, staff_digest))
    if lifecycle is not None:
        jobs.append(Job("past_due", config.SCHEDULER_PAST_DUE_SECONDS, 900,
                        lambda: mark_past_due(db, lifecycle, now=clock(), invoices=invoices)))

        def reconcile_projections() -> dict[str, Any]:
            outcome = {f"lifecycle_{key}": value for key, value in lifecycle.reconcile_projections().items()}
            if subscriptions is not None:
                outcome.update({f"plan_{key}": value
                                for key, value in subscriptions.refresh_plans(clock(), actor="scheduler").items()})
            return _counts(outcome)

        jobs.append(Job("projection_reconcile", config.SCHEDULER_PROJECTION_SECONDS, 900, reconcile_projections))
    if invoices is not None:
        jobs.append(Job("invoice_drafts", config.SCHEDULER_INVOICE_DRAFT_SECONDS, 900,
                        lambda: draft_renewal_invoices(db, invoices, now=clock())))
    return Scheduler(db, jobs, project_id=project_id, clock=clock, **options)


def _deletion_totals(totals: dict[str, int], outcome: dict[str, Any]) -> dict[str, int]:
    done = outcome["done"]
    return {"accepted": totals["accepted"] + len(done["accept"]), "cancelled": totals["cancelled"] + len(done["cancel"]),
            "purged": totals["purged"] + len(done["purge"]), "failed": totals["failed"] + len(outcome["failed"])}

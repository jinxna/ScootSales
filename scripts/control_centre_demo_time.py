from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

LOOPBACK = ("127.0.0.1", "localhost", "[::1]", "::1")


def refuse_unless_local() -> None:
    hosts = [os.environ.get(name, "").strip() for name in ("FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST")]
    if not all(host and host.rsplit(":", 1)[0] in LOOPBACK for host in hosts):
        raise SystemExit("Refusing to run: the Firestore and Auth emulators must be on a loopback address.")
    if not os.environ.get("PLATFORM_PROJECT_ID", "").startswith("demo-"):
        raise SystemExit("Refusing to run: the platform project is not a demo project.")


refuse_unless_local()

from google.cloud import firestore  # noqa: E402

from platform_service import config  # noqa: E402
from platform_service.audit import CHAIN, DIGESTS, EVENTS, GENESIS, STARTS, AuditLog, chain_doc_id, event_hash  # noqa: E402
from platform_service.company_access import company_access  # noqa: E402
from platform_service.directory import DirectoryStore  # noqa: E402
from platform_service.ids import KUALA_LUMPUR, local_date  # noqa: E402
from platform_service.invoices import CREDIT_NOTES, INVOICES, InvoiceBook  # noqa: E402
from platform_service.lifecycle import LifecycleService, LifecycleStore  # noqa: E402
from platform_service.mail import DeliveryRejected, MailQueue, StubTransport, deliver_mail  # noqa: E402
from platform_service.operations import OperationStore  # noqa: E402
from platform_service.payments import CHECKS, ENTRIES  # noqa: E402
from platform_service.plans import PlanStore  # noqa: E402
from platform_service.scheduler import build_scheduler, send_staff_digest  # noqa: E402
from platform_service.signing import Keyring, Signer, format_timestamp, parse_timestamp  # noqa: E402

INVOICE_MOMENTS = ("createdAt", "updatedAt", "issuedAt", "sendRequestedAt", "deliveredAt", "dueAt", "paidAt",
                   "pendingAt", "editedAt", "voidedAt", "extendedAt")
INVOICE_PERIOD = ("periodStart", "periodEnd")
ENTRY_MOMENTS = ("createdAt", "graceEnd", "periodStart", "periodEnd")
LIFECYCLE_MOMENTS = ("stateSince", "updatedAt", "graceEndsAt", "windowEndsAt", "retentionEndsAt")
APPROVAL_MOMENTS = ("createdAt", "expiresAt", "decidedAt", "executedAt")
MAIL_STAMPS = ("createdAt", "updatedAt", "nextAttemptAt", "startedAt")
CUTOFFS = "demo_seed_audit_cutoffs"


def client() -> firestore.Client:
    return firestore.Client(project=config.PLATFORM_PROJECT_ID)


def move(data: dict, names: tuple[str, ...], delta: timedelta) -> dict:
    changes = {}
    for name in names:
        value = data.get(name)
        if isinstance(value, datetime):
            changes[name] = value - delta
        elif isinstance(value, str) and value.endswith("Z"):
            changes[name] = format_timestamp(parse_timestamp(value) - delta)
    return changes


def shift_all(db: firestore.Client, collection: str, tenant_id: str, names: tuple[str, ...], delta: timedelta,
              only: set[str] | None = None) -> int:
    count = 0
    query = db.collection(collection).where(filter=firestore.FieldFilter("tenantId", "==", tenant_id))
    for snapshot in query.stream():
        if only is not None and snapshot.id not in only:
            continue
        changes = move(snapshot.to_dict() or {}, names, delta)
        if changes:
            snapshot.reference.update(changes)
            count += 1
    return count


def age(args: dict) -> dict:
    db = client()
    tenant_id = args["tenantId"]
    delta = timedelta(days=args["days"])
    special = {invoice_id: timedelta(days=days) for invoice_id, days in (args.get("invoiceDays") or {}).items()}
    now = datetime.now(timezone.utc)
    db.collection(CUTOFFS).document(tenant_id).set({"tenantId": tenant_id, "at": format_timestamp(now)})
    queue = MailQueue(db)
    deliver_mail(queue, transport=StubTransport(), worker_id="demo-seed")
    InvoiceBook(db, PlanStore(db), mail=queue).settle_pending()
    invoices = 0
    for snapshot in db.collection(INVOICES).where(filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream():
        data = snapshot.to_dict() or {}
        own = special.get(snapshot.id, delta)
        changes = {**move(data, INVOICE_MOMENTS, own), **move(data, INVOICE_PERIOD, delta)}
        snapshot.reference.update(changes)
        invoices += 1
    shift_all(db, ENTRIES, tenant_id, ENTRY_MOMENTS + ("receivedAt",), delta)
    shift_all(db, CHECKS, tenant_id, ("checkedAt",), delta)
    shift_all(db, CREDIT_NOTES, tenant_id, ("issuedAt",), delta)
    shift_all(db, "approvals", tenant_id, APPROVAL_MOMENTS, delta)
    shift_all(db, "mail_jobs", tenant_id, MAIL_STAMPS, delta)
    for snapshot in db.collection("mail_jobs").where(filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream():
        job = snapshot.to_dict() or {}
        due = (job.get("payload") or {}).get("dueAt")
        if job.get("kind") == "invoice" and isinstance(due, str):
            snapshot.reference.update({"payload.dueAt": (datetime.fromisoformat(due) - delta).date().isoformat()})
    shift_all(db, "plan_requests", tenant_id, ("createdAt",), delta)
    lifecycle = db.collection("lifecycle").document(tenant_id)
    if lifecycle.get().exists:
        lifecycle.update(move(lifecycle.get().to_dict() or {}, LIFECYCLE_MOMENTS, delta))
    time.sleep(1.2)
    return {"tenantId": tenant_id, "invoices": invoices}


def build_services(db: firestore.Client, clock):
    signer = Signer.from_environment()
    store = DirectoryStore(db, keyring=Keyring.from_environment(), signer=signer)
    audit = AuditLog(db, clock=clock)
    operations = OperationStore(db, audit=audit)
    plans = PlanStore(db)
    mail = MailQueue(db, clock=clock)
    invoices = InvoiceBook(db, plans, clock=clock, mail=mail, audit=audit)
    lifecycle_store = LifecycleStore(db, audit=audit)
    lifecycle = LifecycleService(
        db, operations, store, lifecycle_store, access_for=company_access, clock=clock, mail=mail)
    return build_scheduler(db, lifecycle=lifecycle, invoices=invoices, audit=audit, clock=clock)


def jobs(args: dict) -> dict:
    db = client()
    scheduler = build_services(db, lambda: datetime.now(timezone.utc))
    return scheduler.run_due(only=args["jobs"])


class DemoTransport:
    def __init__(self, reject: dict) -> None:
        self.reject = {address.lower(): rule for address, rule in reject.items()}
        self.tries: dict[str, int] = {}

    def send(self, message, idempotency_key: str) -> str:
        address = str(message["to"]).lower()
        rule = self.reject.get(address)
        if rule is not None:
            raise DeliveryRejected("The mail provider rejected this address.", retryable=bool(rule.get("retryable")))
        return "demo-" + idempotency_key[:16]


def mail(args: dict) -> dict:
    db = client()
    clock_now = [datetime.now(timezone.utc)]
    queue = MailQueue(db, enabled=True, clock=lambda: clock_now[0])
    transport = DemoTransport(args.get("reject") or {})
    rounds = max([1] + [int(rule.get("rounds", 1)) for rule in (args.get("reject") or {}).values()])
    totals = {"sent": 0, "failed": 0, "queued": 0}
    for _ in range(rounds):
        outcome = deliver_mail(queue, now=clock_now[0], transport=transport, worker_id="demo-seed")
        for name in totals:
            totals[name] += len(outcome[name])
        clock_now[0] += timedelta(minutes=5)
    return totals


def enqueue(args: dict) -> dict:
    db = client()
    queue = MailQueue(db, enabled=True)
    job = queue.enqueue(args["tenantId"], args["key"], args["kind"], args["recipient"], args["payload"], args["actor"])
    return {"jobId": job["jobId"], "status": job["status"]}


def agemail(args: dict) -> dict:
    db = client()
    delta = timedelta(hours=args["hours"])
    moved = 0
    query = db.collection("mail_jobs").where(filter=firestore.FieldFilter("tenantId", "==", args["tenantId"]))
    for snapshot in query.stream():
        data = snapshot.to_dict() or {}
        if data.get("kind") == args["kind"]:
            snapshot.reference.update(move(data, MAIL_STAMPS, delta))
            moved += 1
    return {"moved": moved}


def audit(args: dict) -> dict:
    db = client()
    ages = {tenant: timedelta(days=days) for tenant, days in (args.get("ages") or {}).items()}
    default = timedelta(days=args.get("default", 0))
    cutoffs = {snapshot.id: (snapshot.to_dict() or {}).get("at") for snapshot in db.collection(CUTOFFS).stream()}
    events = [snapshot.to_dict() or {} for snapshot in db.collection(EVENTS).stream()]
    moved = []
    for event in events:
        tenant = event.get("tenantId")
        delta = ages.get(tenant, default)
        cutoff = cutoffs.get(tenant)
        if tenant in ages and cutoff is not None and event["at"] > cutoff:
            delta = timedelta(0)
        moved.append((parse_timestamp(event["at"]) - delta, event["day"], event["seq"], event))
    moved.sort(key=lambda item: (item[0], item[1], item[2]))
    for collection in (CHAIN, DIGESTS, STARTS):
        for snapshot in db.collection(collection).stream():
            snapshot.reference.delete()
    by_chain_day: dict[tuple[str, str | None], list] = {}
    for moment, _, _, event in moved:
        by_chain_day.setdefault((local_date(moment), event.get("chain")), []).append((moment, event))
    last_hash: dict[tuple[str, str | None], str] = {}
    rewritten = 0
    for day, chain in sorted(by_chain_day, key=lambda pair: (pair[0], pair[1] or "")):
        before = (datetime.fromisoformat(day) - timedelta(days=1)).date().isoformat()
        previous = last_hash.get((before, chain), GENESIS)
        seed = previous
        head = None
        for seq, (moment, event) in enumerate(by_chain_day[(day, chain)], start=1):
            updated = {**event, "seq": seq, "at": format_timestamp(moment), "day": day, "prevHash": previous}
            updated["hash"] = event_hash(updated)
            db.collection(EVENTS).document(event["eventId"]).set(updated)
            previous = updated["hash"]
            head = updated
            rewritten += 1
        last_hash[(day, chain)] = previous
        db.collection(CHAIN).document(chain_doc_id(day, chain)).set({
            "day": day, **({"chain": chain} if chain is not None else {}), "count": len(by_chain_day[(day, chain)]),
            "lastEventId": head["eventId"], "lastHash": previous, "seedHash": seed, "updatedAt": head["at"]})
    days = sorted({day for day, _ in by_chain_day})
    log = AuditLog(db)
    result = log.run_digests()
    broken = [day for day in days if not log.verify(day)["ok"]]
    return {"events": rewritten, "days": len(days), "digests": result["written"], "broken": broken}


def digest(args: dict) -> dict:
    db = client()
    ten = datetime.now(KUALA_LUMPUR).replace(hour=10, minute=0, second=0, microsecond=0)
    return send_staff_digest(db, MailQueue(db, enabled=True), now=ten.astimezone(timezone.utc))


COMMANDS = {"age": age, "jobs": jobs, "mail": mail, "enqueue": enqueue, "agemail": agemail, "audit": audit,
            "digest": digest}


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        raise SystemExit("Use one of: " + ", ".join(COMMANDS))
    raw = sys.stdin.read().strip()
    print(json.dumps(COMMANDS[sys.argv[1]](json.loads(raw) if raw else {}), default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import calendar
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from google.cloud import firestore

from .audit import AuditLog
from .commands import CommandProblem, PlanProblem
from .ids import (
    DUE_DAYS, KUALA_LUMPUR, amount_minor, bad, check_key, command_id, digest, identity, last_day, local_date, retry, safe,
    text, timestamp, utc_now)
from .invoice_pdf import invoice_attachment
from .mail import MailQueue, company_contact, delivery_outcome
from .plans import PlanStore
from .signing import format_timestamp, parse_timestamp

INVOICES = "invoices"
CREDIT_NOTES = "credit_notes"
COUNTERS = "document_counters"
PERIOD_CLAIMS = "invoice_period_claims"
PERIOD_LOCKS = "invoice_period_locks"
SAME_PERIOD_REFUSAL = "An invoice already exists for this period. Open that invoice."


def issued_period_refusal(number: str | None) -> str:
    return f"An invoice already exists for this period: {number}. Open that invoice."


SEND_ATTEMPTS = 20
UNCHECKED_COVER = timedelta(days=7)
MAX_PERIOD_START_AHEAD = timedelta(days=62)
EXTENSION_DAYS = 14
DRAFT, ISSUED, SENT, PAID, VOID = "draft", "issued", "sent", "paid", "void"
INVOICE_ID = re.compile(r"^inv_[0-9a-f]{64}$")
_INVOICE_FIELDS = frozenset({
    "invoiceId", "tenantId", "packageId", "packageName", "billingInterval", "periodStart", "periodEnd",
    "amountMinor", "currency", "status", "number", "issuedAt", "deliveredAt", "dueAt", "note", "source",
    "createdBy", "createdAt", "updatedAt", "paidMinor", "creditedMinor", "editedBy", "editedAt", "issuedBy",
    "sendRequestedAt", "sentBy", "voidedBy", "voidedAt", "extendedAt", "extendedDays", "extendedBy", "quoteId"})
_COMPANY_INVOICE_FIELDS = frozenset({
    "invoiceId", "packageName", "billingInterval", "periodStart", "periodEnd", "amountMinor", "currency", "status",
    "number", "issuedAt", "dueAt", "paidMinor", "creditedMinor"})
_CREDIT_FIELDS = frozenset({
    "creditNoteId", "number", "invoiceId", "invoiceNumber", "tenantId", "amountMinor", "currency", "reason",
    "issuedAt", "createdBy"})
QUOTES = "quotes"
_DRAFT_BODY = frozenset({"periodStart", "note"})
_EDIT_BODY = frozenset({"note", "periodStart"})
_INTERVAL_MONTHS = {"monthly": 1, "yearly": 12}


class NeedsManualDraft(CommandProblem):
    pass


def add_months(moment: datetime, months: int) -> datetime:
    local = moment.astimezone(KUALA_LUMPUR)
    index = local.month - 1 + months
    year, month = local.year + index // 12, index % 12 + 1
    shifted = local.replace(year=year, month=month, day=min(local.day, calendar.monthrange(year, month)[1]))
    return shifted.astimezone(moment.tzinfo)


def outstanding_minor(invoice: Mapping[str, Any]) -> int:
    return invoice["amountMinor"] - invoice.get("creditedMinor", 0) - invoice.get("paidMinor", 0)


def read_counter(client: firestore.Client, transaction: firestore.Transaction, prefix: str,
                 moment: datetime) -> tuple[Any, int]:
    reference = client.collection(COUNTERS).document(f"{prefix}-{moment.astimezone(KUALA_LUMPUR).year}")
    return reference, (reference.get(transaction=transaction).to_dict() or {}).get("last", 0)


def take_number(transaction: firestore.Transaction, reference: Any, prefix: str, moment: datetime,
                last: int) -> str:
    year = moment.astimezone(KUALA_LUMPUR).year
    transaction.set(reference, {"prefix": prefix, "year": year, "last": last + 1})
    return f"{prefix}-{year}-{last + 1:06d}"


def _rows(client: firestore.Client, tenant_id: str) -> list[dict[str, Any]]:
    return [snapshot.to_dict() or {} for snapshot in client.collection(INVOICES).where(
        filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream()]


def overdue_invoices(client: firestore.Client, tenant_id: str, moment: datetime) -> list[dict[str, Any]]:
    overdue = [row for row in _rows(client, tenant_id)
               if row.get("status") in (ISSUED, SENT) and row.get("deliveredAt") is not None
               and row.get("dueAt") is not None and row["dueAt"] < moment and outstanding_minor(row) > 0
               and not (row.get("pendingEntryId") and row["pendingAt"] + UNCHECKED_COVER > moment)]
    return sorted(overdue, key=lambda row: (row["dueAt"], row["number"]))


def bill_waiting_for_delivery(client: firestore.Client, tenant_id: str, moment: datetime) -> bool:
    return any(row.get("status") == ISSUED and row.get("sendRequestedAt") is not None
               and row.get("deliveredAt") is None and row["periodEnd"] > moment and outstanding_minor(row) > 0
               for row in _rows(client, tenant_id))


def bill_not_delivered(client: firestore.Client, mail: MailQueue, tenant_id: str, moment: datetime) -> bool:
    return any(row.get("status") == ISSUED and row.get("sendRequestedAt") is not None
               and row.get("deliveredAt") is None and row["periodEnd"] > moment and outstanding_minor(row) > 0
               and (invoice_delivery(mail, row) or {}).get("state") == "not_delivered"
               for row in _rows(client, tenant_id))


def open_ended_through(client: firestore.Client, tenant_id: str, moment: datetime) -> bool:
    return any(row.get("status") != VOID and row["periodEnd"] > moment for row in _rows(client, tenant_id))


def extension_problem(invoice: Mapping[str, Any]) -> str | None:
    if invoice.get("extendedAt") is not None:
        return "This invoice was already extended once."
    if (invoice.get("status") not in (ISSUED, SENT) or invoice.get("dueAt") is None
            or outstanding_minor(invoice) <= 0):
        return "Only a sent invoice with an open balance can be extended."
    return None


def company_workspace(client: firestore.Client, tenant_id: str) -> str:
    data = client.collection("companies").document(tenant_id).get().to_dict() or {}
    try:
        workspace = json.loads(data.get("payload") or "").get("workspace")
    except (ValueError, AttributeError):
        workspace = None
    return workspace if isinstance(workspace, str) else ""


def invoice_pdf(client: firestore.Client, invoice: Mapping[str, Any], contact: tuple[str, str | None]) -> dict[str, Any]:
    return invoice_attachment(invoice, company_name=contact[0], billing_email=contact[1],
                              workspace=company_workspace(client, invoice["tenantId"]))


def invoice_view(data: Mapping[str, Any], delivery: Mapping[str, Any] | None = None) -> dict[str, Any]:
    return {**safe(data, _INVOICE_FIELDS), "outstandingMinor": outstanding_minor(data), "delivery": delivery,
            "pendingEntryId": data.get("pendingEntryId"), "graceUsed": bool(data.get("graceUsed"))}


def first_mail_job_id(invoice: Mapping[str, Any]) -> str:
    return hashlib.sha256(f"{invoice['tenantId']}\x00invoice-{invoice['invoiceId']}".encode()).hexdigest()


def _chain_end(mail: MailQueue, tenant_id: str, job_id: str) -> dict[str, Any] | None:
    job = None
    seen: set[str] = set()
    while job_id not in seen:
        seen.add(job_id)
        try:
            job = mail.get(tenant_id, job_id)
        except LookupError:
            return job
        if not job.get("retriedAs"):
            return job
        job_id = job["retriedAs"]
    return job


def latest_mail_job(mail: MailQueue, invoice: Mapping[str, Any]) -> dict[str, Any] | None:
    tenant_id = invoice["tenantId"]
    latest = _chain_end(mail, tenant_id, first_mail_job_id(invoice))
    if latest is None:
        return None
    for attempt in range(1, SEND_ATTEMPTS):
        key = f"invoice-{invoice['invoiceId']}-{attempt}"
        later = _chain_end(mail, tenant_id, hashlib.sha256(f"{tenant_id}\x00{key}".encode()).hexdigest())
        if later is None:
            break
        latest = later
    return latest


def invoice_delivery(mail: MailQueue, invoice: Mapping[str, Any]) -> dict[str, Any] | None:
    if invoice.get("status") not in (ISSUED, SENT) or invoice.get("sendRequestedAt") is None:
        return None
    delivered = invoice.get("deliveredAt") is not None
    job = latest_mail_job(mail, invoice)
    if job is None:
        if delivered:
            return {"state": "delivered", "reason": None, "jobStatus": None, "needsConfirm": False}
        return {"state": "not_delivered", "reason": "The invoice email was never queued.",
                "jobStatus": None, "needsConfirm": False}
    state, reason = delivery_outcome(job)
    if state == "delivered" and not delivered:
        state = "sending"
    return {"state": state, "reason": reason, "jobStatus": job["status"],
            "needsConfirm": job["status"] == "uncertain" and state == "not_delivered"}


def company_invoices(client: firestore.Client, tenant_id: str) -> list[dict[str, Any]]:
    rows = [row for row in _rows(client, tenant_id) if row.get("status") in (ISSUED, SENT, PAID)]
    rows.sort(key=lambda row: row.get("issuedAt") or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    return [{**safe(row, _COMPANY_INVOICE_FIELDS), "outstandingMinor": outstanding_minor(row)} for row in rows]


def credit_note_view(data: Mapping[str, Any]) -> dict[str, Any]:
    return safe(data, _CREDIT_FIELDS)


def _note(value: Any) -> str:
    if not isinstance(value, str) or len(value.strip()) > 500:
        raise bad("note must be text of at most 500 characters.")
    return value.strip()


def _missing() -> HTTPException:
    return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invoice not found.")


def _invoice_id(value: Any) -> str:
    if not isinstance(value, str) or not INVOICE_ID.fullmatch(value):
        raise _missing()
    return value

def period_claim_id(tenant_id: str, start: datetime) -> str:
    return f"{tenant_id}_{local_date(start)}"


def check_period_start(start: datetime, moment: datetime) -> None:
    if start > moment + MAX_PERIOD_START_AHEAD:
        raise bad("The invoice period cannot start more than 62 days from today.")


class InvoiceBook:
    def __init__(self, client: firestore.Client, plans: PlanStore, *, clock: Callable[[], datetime] = utc_now,
                 mail: MailQueue | None = None, audit: AuditLog | None = None) -> None:
        self.client = client
        self.plans = plans
        self.clock = clock
        self.mail = mail if mail is not None else MailQueue(client)
        self.mail.refreshers["invoice"] = self._fresh_mail
        self.audit = audit if audit is not None else AuditLog(client, clock=clock)

    def _approved_quote(self, tenant_id: str, interval: str, plan_id: str) -> dict[str, Any]:
        rows = [snapshot.to_dict() or {} for snapshot in self.client.collection(QUOTES).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream()]
        subscription = self.plans.get_subscription(tenant_id) or {}
        changed_at = subscription.get("planSetAt") or subscription.get("updatedAt")
        rows = [row for row in rows if row.get("status") == "approved" and row.get("billingInterval") == interval
                and (row.get("planId") == plan_id or (
                    row.get("planId") is None and isinstance(changed_at, datetime) and changed_at <= row["createdAt"]))]
        if not rows:
            raise NeedsManualDraft("This package has no price yet. Set a price for this package on the Packages page first, "
                                   "then apply the package again on the company page. An approved quote for this "
                                   "package also works: ask for a new quote for this package.", fix="set_price")
        return max(rows, key=lambda row: (row["createdAt"], row["quoteId"]))

    def _package(self, tenant_id: str) -> dict[str, Any]:
        try:
            effective = self.plans.effective(tenant_id, self.clock())
        except PlanProblem as problem:
            raise CommandProblem(str(problem), fix=problem.fix) from None
        interval = effective.get("billingInterval")
        if interval not in _INTERVAL_MONTHS:
            raise NeedsManualDraft("Choose a billing period for this company's package first.", fix="choose_package")
        price = (effective.get("prices") or {}).get(interval)
        quote_id = None
        if price is None:
            approved = self._approved_quote(tenant_id, interval, effective["planId"])
            amount, quote_id = amount_minor(approved["amountMinor"], "amountMinor"), approved["quoteId"]
        else:
            amount = amount_minor(int((Decimal(str(price)) * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP)), "amountMinor")
        return {"packageId": effective["planId"], "packageName": effective["name"],
                "billingInterval": interval, "amountMinor": amount, **({"quoteId": quote_id} if quote_id else {})}

    def _claim_period(self, transaction: firestore.Transaction, tenant_id: str, invoice_id: str, start: datetime,
                      end: datetime, amount: int, moment: datetime, *, vacated_start: datetime | None = None
                      ) -> tuple[dict[str, Any] | None, dict[str, Any] | None, Callable[[], None]]:
        lock_ref = self.client.collection(PERIOD_LOCKS).document(tenant_id)
        claim_ref = self.client.collection(PERIOD_CLAIMS).document(period_claim_id(tenant_id, start))
        vacated_ref = None if vacated_start is None else self.client.collection(PERIOD_CLAIMS).document(
            period_claim_id(tenant_id, vacated_start))
        lock_ref.get(transaction=transaction)
        vacated = vacated_ref.get(transaction=transaction) if vacated_ref is not None else None
        day = local_date(start)
        rows = [snapshot.to_dict() or {} for snapshot in self.client.collection(INVOICES).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream(transaction=transaction)]
        match = next((row for row in rows if row.get("status") != VOID and row["invoiceId"] != invoice_id
                      and local_date(row["periodStart"]) == day and row["amountMinor"] == amount), None)
        overlap = next((row for row in rows if row.get("status") != VOID and row["invoiceId"] != invoice_id
                        and day < local_date(row["periodEnd"]) and local_date(row["periodStart"]) < local_date(end)),
                       None)

        def commit() -> None:
            if (vacated is not None and vacated_ref != claim_ref and vacated.exists
                    and (vacated.to_dict() or {}).get("invoiceId") == invoice_id):
                transaction.delete(vacated_ref)
            transaction.set(claim_ref, {"tenantId": tenant_id, "periodStart": start, "periodEnd": end,
                                        "invoiceId": invoice_id, "amountMinor": amount, "claimedAt": moment})
            transaction.set(lock_ref, {"tenantId": tenant_id, "updatedAt": moment})

        return match, overlap, commit

    def create_draft(self, tenant_id: str, key: str, body: Mapping[str, Any], actor: str) -> dict[str, Any]:
        identity(tenant_id, key)
        actor = text(actor, "actor", 254)
        if not isinstance(body, Mapping) or set(body) - _DRAFT_BODY:
            raise bad("Supply only periodStart and note. The amount comes from the package price or an approved quote.")
        moment = self.clock()
        start_text = timestamp(body["periodStart"], "periodStart") if body.get("periodStart") is not None \
            else format_timestamp(moment)
        start = parse_timestamp(start_text)
        check_period_start(start, moment)
        note = _note(body.get("note", ""))
        package = self._package(tenant_id)
        end = add_months(start, _INTERVAL_MONTHS[package["billingInterval"]])
        payload_hash = digest({"tenantId": tenant_id, "periodStart": body.get("periodStart"), "note": note})
        invoice_id = command_id("inv", tenant_id, key, "invoice.draft")
        reference = self.client.collection(INVOICES).document(invoice_id)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            prior = reference.get(transaction=transaction)
            if prior.exists:
                data = prior.to_dict() or {}
                retry(data, payload_hash)
                return data
            match, overlap, claimed = self._claim_period(
                transaction, tenant_id, invoice_id, start, end, package["amountMinor"], moment)
            if match is not None:
                if match["status"] != DRAFT:
                    raise CommandProblem(issued_period_refusal(match.get("number")))
                return {**match, "existing": True}
            if overlap is not None:
                raise CommandProblem(issued_period_refusal(overlap["number"]) if overlap.get("number")
                                     else SAME_PERIOD_REFUSAL)
            invoice = {"invoiceId": invoice_id, "tenantId": tenant_id, **package, "currency": "MYR",
                       "periodStart": start, "periodEnd": end, "status": DRAFT, "number": None,
                       "issuedAt": None, "deliveredAt": None, "dueAt": None, "note": note,
                       "source": "scheduler" if actor == "scheduler" else "staff", "createdBy": actor,
                       "createdAt": moment, "updatedAt": moment, "paidMinor": 0, "creditedMinor": 0,
                       "payloadHash": payload_hash}
            staged = self.audit.stage(transaction, moment, tenant_id=tenant_id)
            claimed()
            transaction.create(reference, invoice)
            staged.add(actor=actor, action="invoice.draft_created", tenant_id=tenant_id, key=f"draft:{invoice_id}",
                       summary="Invoice draft created.", refs={"invoiceId": invoice_id})
            return invoice

        stored = write(self.client.transaction(max_attempts=10))
        return {**invoice_view(stored), **({"existing": True} if stored.get("existing") else {})}

    def get(self, invoice_id: str) -> dict[str, Any]:
        _invoice_id(invoice_id)
        data = self.client.collection(INVOICES).document(invoice_id).get().to_dict()
        if data is None:
            raise _missing()
        data = self.settle_delivery(invoice_id)
        return {**invoice_view(data, self._delivery(data)), "creditNotes": self.credit_notes(invoice_id)}

    def list_invoices(self, tenant_id: str | None = None) -> list[dict[str, Any]]:
        collection = self.client.collection(INVOICES)
        if tenant_id is not None:
            identity(tenant_id)
            collection = collection.where(filter=firestore.FieldFilter("tenantId", "==", tenant_id))
        rows = [snapshot.to_dict() or {} for snapshot in collection.stream()]
        rows.sort(key=lambda row: row["createdAt"], reverse=True)
        rows = [self.settle_delivery(row["invoiceId"]) if row.get("status") in (ISSUED, SENT)
                and row.get("sendRequestedAt") is not None else row for row in rows]
        return [invoice_view(row, self._delivery(row)) for row in rows]

    def credit_notes(self, invoice_id: str) -> list[dict[str, Any]]:
        rows = [snapshot.to_dict() or {} for snapshot in self.client.collection(CREDIT_NOTES).where(
            filter=firestore.FieldFilter("invoiceId", "==", invoice_id)).stream()]
        rows.sort(key=lambda row: row["issuedAt"])
        return [credit_note_view(row) for row in rows]

    def _change_draft(self, invoice_id: str, change: Callable[[dict[str, Any]], dict[str, Any]], *,
                      claim: Callable[[firestore.Transaction, dict[str, Any], dict[str, Any]], Callable[[], None]] | None = None,
                      actor: str, action: str, summary: str) -> dict[str, Any]:
        _invoice_id(invoice_id)
        reference = self.client.collection(INVOICES).document(invoice_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                raise _missing()
            invoice = snapshot.to_dict() or {}
            if invoice["status"] != DRAFT:
                raise CommandProblem("Only a draft can be changed. Issued invoices are locked.")
            fields = change(invoice)
            commit = claim(transaction, invoice, fields) if claim is not None else None
            staged = self.audit.stage(transaction, moment, tenant_id=invoice["tenantId"])
            if commit is not None:
                commit()
            transaction.update(reference, fields)
            staged.add(actor=actor, action=action, tenant_id=invoice["tenantId"],
                       key=f"{action}:{invoice_id}:{moment.isoformat()}", summary=summary,
                       refs={"invoiceId": invoice_id})
            return {**invoice, **fields}

        return invoice_view(write(self.client.transaction(max_attempts=10)))

    def edit_draft(self, invoice_id: str, body: Mapping[str, Any], actor: str) -> dict[str, Any]:
        actor = text(actor, "actor", 254)
        if not isinstance(body, Mapping) or not body or set(body) - _EDIT_BODY:
            raise bad("A draft can change only note and periodStart.")
        moment = self.clock()

        def change(invoice: dict[str, Any]) -> dict[str, Any]:
            fields = {"editedBy": actor, "editedAt": moment, "updatedAt": moment}
            if "periodStart" in body:
                start = parse_timestamp(timestamp(body["periodStart"], "periodStart"))
                check_period_start(start, moment)
                fields["periodStart"] = start
                fields["periodEnd"] = add_months(start, _INTERVAL_MONTHS[invoice["billingInterval"]])
            if "note" in body:
                fields["note"] = _note(body["note"])
            return fields

        def claim(transaction: firestore.Transaction, invoice: dict[str, Any], fields: dict[str, Any]
                  ) -> Callable[[], None]:
            start = fields.get("periodStart", invoice["periodStart"])
            match, overlap, commit = self._claim_period(
                transaction, invoice["tenantId"], invoice_id, start,
                fields.get("periodEnd", invoice["periodEnd"]), invoice["amountMinor"], moment,
                vacated_start=invoice["periodStart"])
            if match is not None or (overlap is not None and start != invoice["periodStart"]):
                raise CommandProblem(SAME_PERIOD_REFUSAL)
            return commit

        return self._change_draft(invoice_id, change, claim=claim if "periodStart" in body else None,
                                  actor=actor, action="invoice.draft_edited",
                                  summary="Invoice draft edited.")

    def void_draft(self, invoice_id: str, actor: str) -> dict[str, Any]:
        actor = text(actor, "actor", 254)
        moment = self.clock()
        def release(transaction: firestore.Transaction, invoice: dict[str, Any], _: dict[str, Any]
                    ) -> Callable[[], None]:
            claim_ref = self.client.collection(PERIOD_CLAIMS).document(
                period_claim_id(invoice["tenantId"], invoice["periodStart"]))
            held = claim_ref.get(transaction=transaction)
            held_here = held.exists and (held.to_dict() or {}).get("invoiceId") == invoice_id

            def commit() -> None:
                if held_here:
                    transaction.delete(claim_ref)

            return commit

        return self._change_draft(
            invoice_id, lambda _: {"status": VOID, "voidedBy": actor, "voidedAt": moment, "updatedAt": moment},
            claim=release, actor=actor, action="invoice.voided", summary="Invoice draft voided.")

    def issue(self, invoice_id: str, actor: str) -> dict[str, Any]:
        _invoice_id(invoice_id)
        actor = text(actor, "actor", 254)
        reference = self.client.collection(INVOICES).document(invoice_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                raise _missing()
            invoice = snapshot.to_dict() or {}
            if invoice["status"] in (ISSUED, SENT, PAID):
                return invoice
            if invoice["status"] != DRAFT:
                raise CommandProblem("A voided draft cannot be issued.")
            counter, last = read_counter(self.client, transaction, "INV", moment)
            staged = self.audit.stage(transaction, moment, tenant_id=invoice["tenantId"])
            number = take_number(transaction, counter, "INV", moment, last)
            fields = {"status": ISSUED, "number": number, "issuedAt": moment, "issuedBy": actor, "updatedAt": moment}
            transaction.update(reference, fields)
            staged.add(actor=actor, action="invoice.issued", tenant_id=invoice["tenantId"], key=f"issue:{invoice_id}",
                       summary=f"Invoice {number} issued.", refs={"invoiceId": invoice_id, "invoiceNumber": number})
            return {**invoice, **fields}

        return invoice_view(write(self.client.transaction(max_attempts=10)))

    def _latest_mail_job(self, invoice: Mapping[str, Any]) -> dict[str, Any] | None:
        return latest_mail_job(self.mail, invoice)

    def _delivery(self, invoice: Mapping[str, Any]) -> dict[str, Any] | None:
        return invoice_delivery(self.mail, invoice)

    def _fresh_mail(self, job: Mapping[str, Any]) -> dict[str, Any]:
        tenant_id = job["tenantId"]
        number = (job.get("payload") or {}).get("invoiceNumber")
        invoice = next((row for row in _rows(self.client, tenant_id) if row.get("number") == number), None)
        if (invoice is None or invoice.get("status") not in (ISSUED, SENT) or invoice.get("sendRequestedAt") is None
                or invoice.get("deliveredAt") is not None):
            raise ValueError("This invoice email is not waiting to be delivered.")
        contact = company_contact(self.client, tenant_id)
        if contact is None or contact[1] is None:
            raise ValueError("The company has no billing email.")
        return {"recipient": contact[1], "payload": self._mail_payload(invoice, contact, self.clock()),
                "attached": invoice_pdf(self.client, invoice, contact)}

    @staticmethod
    def _mail_payload(invoice: Mapping[str, Any], contact: tuple[str, str | None], moment: datetime) -> dict[str, Any]:
        return {"tenantId": invoice["tenantId"], "companyName": contact[0], "invoiceNumber": invoice["number"],
                "amountMinor": invoice["amountMinor"], "currency": invoice["currency"],
                "periodStart": local_date(invoice["periodStart"]), "periodEnd": last_day(invoice["periodEnd"]),
                "dueAt": local_date(moment + timedelta(days=DUE_DAYS))}

    def settle_delivery(self, invoice_id: str) -> dict[str, Any]:
        _invoice_id(invoice_id)
        reference = self.client.collection(INVOICES).document(invoice_id)
        current = reference.get().to_dict()
        if current is None:
            raise _missing()
        if current.get("status") not in (ISSUED, SENT) or current.get("sendRequestedAt") is None:
            return current
        job = self._latest_mail_job(current)
        if job is None:
            return current
        state, failure = delivery_outcome(job)
        moment = self.clock()
        if current.get("deliveredAt") is not None:
            if state != "not_delivered" or current["status"] != SENT:
                return current

            @firestore.transactional
            def undeliver(transaction: firestore.Transaction) -> dict[str, Any]:
                latest = reference.get(transaction=transaction).to_dict() or {}
                if latest.get("deliveredAt") is None or latest.get("status") != SENT:
                    return latest
                fields = {"status": ISSUED, "deliveredAt": None, "dueAt": None, "updatedAt": moment}
                staged = self.audit.stage(transaction, moment, tenant_id=latest["tenantId"])
                transaction.update(reference, fields)
                staged.add(actor="scheduler", action="invoice.not_delivered", tenant_id=latest["tenantId"],
                           key=f"undelivered:{invoice_id}:{job['jobId']}:{job.get('deliveryStatusAt') or ''}",
                           summary=f"Invoice {latest['number']} was not delivered. {failure}",
                           refs={"invoiceId": invoice_id, "invoiceNumber": latest["number"]})
                return {**latest, **fields}

            return undeliver(self.client.transaction(max_attempts=10))
        if state != "delivered":
            return current
        delivered_at = parse_timestamp(job.get("startedAt") or job["updatedAt"])

        @firestore.transactional
        def deliver(transaction: firestore.Transaction) -> dict[str, Any]:
            latest = reference.get(transaction=transaction).to_dict() or {}
            if latest.get("deliveredAt") is not None or latest.get("status") not in (ISSUED, SENT):
                return latest
            fields = {"status": SENT, "deliveredAt": delivered_at, "dueAt": delivered_at + timedelta(days=DUE_DAYS),
                      "updatedAt": moment}
            staged = self.audit.stage(transaction, moment, tenant_id=latest["tenantId"])
            transaction.update(reference, fields)
            staged.add(actor=latest.get("sentBy") or "scheduler", action="invoice.sent",
                       tenant_id=latest["tenantId"], key=f"sent:{invoice_id}:{job['jobId']}:{job.get('deliveryStatusAt') or ''}",
                       summary=f"Invoice {latest['number']} delivered.",
                       refs={"invoiceId": invoice_id, "invoiceNumber": latest["number"]})
            return {**latest, **fields}

        return deliver(self.client.transaction(max_attempts=10))

    def settle_pending(self) -> dict[str, int]:
        counts = {"delivered": 0, "waiting": 0, "undelivered": 0}
        rows = self.client.collection(INVOICES).where(
            filter=firestore.FieldFilter("status", "in", [ISSUED, SENT])).stream()
        for snapshot in rows:
            row = snapshot.to_dict() or {}
            if row.get("sendRequestedAt") is None:
                continue
            settled = self.settle_delivery(row["invoiceId"])
            if row.get("deliveredAt") is None:
                counts["delivered" if settled.get("deliveredAt") else "waiting"] += 1
            elif settled.get("deliveredAt") is None:
                counts["undelivered"] += 1
        return counts

    def send(self, invoice_id: str, actor: str, *, confirm_duplicate_risk: bool = False) -> dict[str, Any]:
        _invoice_id(invoice_id)
        actor = text(actor, "actor", 254)
        reference = self.client.collection(INVOICES).document(invoice_id)
        moment = self.clock()
        current = reference.get().to_dict()
        if current is None:
            raise _missing()
        contact = company_contact(self.client, current["tenantId"])
        if contact is None or contact[1] is None:
            raise CommandProblem("The company has no billing email.")

        @firestore.transactional
        def request(transaction: firestore.Transaction) -> dict[str, Any]:
            invoice = reference.get(transaction=transaction).to_dict() or {}
            if invoice.get("status") not in (ISSUED, SENT):
                raise CommandProblem("Issue the invoice before you send it.")
            if invoice.get("sendRequestedAt") is not None:
                return invoice
            fields = {"sendRequestedAt": moment, "sentBy": actor, "updatedAt": moment}
            staged = self.audit.stage(transaction, moment, tenant_id=invoice["tenantId"])
            transaction.update(reference, fields)
            staged.add(actor=actor, action="invoice.send_requested", tenant_id=invoice["tenantId"],
                       key=f"send-request:{invoice_id}", summary=f"Invoice {invoice['number']} queued for sending.",
                       refs={"invoiceId": invoice_id, "invoiceNumber": invoice["number"]})
            return {**invoice, **fields}

        request(self.client.transaction(max_attempts=10))
        invoice = self.settle_delivery(invoice_id)
        outcome: dict[str, Any] = {"status": "queued", "reason": None, "jobId": None}
        if invoice.get("deliveredAt") is None:
            job = self._latest_mail_job(invoice)
            tenant_id = invoice["tenantId"]
            if job is None:
                outcome = self.mail.enqueue_or_report(
                    tenant_id, "invoice-" + invoice_id, "invoice", contact[1],
                    self._mail_payload(invoice, contact, moment), actor, attached=invoice_pdf(self.client, invoice, contact))
                if outcome["status"] != "queued":
                    raise CommandProblem(outcome.get("reason") or "The invoice email could not be queued.")
            elif delivery_outcome(job)[0] == "not_delivered":
                try:
                    retried, _ = self.mail.retry(tenant_id, job["jobId"], actor, confirm_duplicate_risk=confirm_duplicate_risk)
                except (LookupError, ValueError, RuntimeError) as error:
                    raise CommandProblem(str(error)) from None
                outcome = {"status": "queued", "reason": None, "jobId": retried["jobId"]}
            else:
                outcome = {"status": "queued", "reason": None, "jobId": job["jobId"]}
            invoice = self.settle_delivery(invoice_id)
        return {**invoice_view(invoice, self._delivery(invoice)), "mail": outcome}

    def extend_due(self, invoice_id: str, days: int, operation_id: str, actor: str,
                   seal: Callable[[firestore.Transaction], None] | None = None) -> dict[str, Any]:
        _invoice_id(invoice_id)
        actor = text(actor, "actor", 254)
        if type(days) is not int or not 1 <= days <= EXTENSION_DAYS:
            raise bad(f"An extension is 1 to {EXTENSION_DAYS} days.")
        reference = self.client.collection(INVOICES).document(invoice_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                raise _missing()
            invoice = snapshot.to_dict() or {}
            if invoice.get("extensionOperationId") == operation_id:
                return invoice
            problem = extension_problem(invoice)
            if problem is not None:
                raise CommandProblem(problem)
            fields = {"dueAt": invoice["dueAt"] + timedelta(days=days), "extendedAt": moment, "extendedDays": days,
                      "extendedBy": actor, "extensionOperationId": operation_id, "updatedAt": moment}
            staged = self.audit.stage(transaction, moment, tenant_id=invoice["tenantId"])
            transaction.update(reference, fields)
            staged.add(actor=actor, action="invoice.extended", tenant_id=invoice["tenantId"],
                       key=f"extend:{invoice_id}", summary=f"Invoice {invoice['number']} due date extended by {days} days.",
                       refs={"invoiceId": invoice_id, "invoiceNumber": invoice["number"], "days": days})
            if seal is not None:
                seal(transaction)
            return {**invoice, **fields}

        return invoice_view(write(self.client.transaction(max_attempts=10)))

    def credit_note(self, invoice_id: str, key: str, body: Mapping[str, Any], actor: str,
                    seal: Callable[[firestore.Transaction], None] | None = None) -> dict[str, Any]:
        _invoice_id(invoice_id)
        check_key(key)
        actor = text(actor, "actor", 254)
        if not isinstance(body, Mapping) or set(body) != {"amountMinor", "reason"}:
            raise bad("A credit note needs exactly amountMinor and reason.")
        amount = amount_minor(body["amountMinor"], "amountMinor")
        reason = text(body["reason"], "reason", 500)
        payload_hash = digest({"invoiceId": invoice_id, "amountMinor": amount, "reason": reason})
        note_id = command_id("cn", invoice_id, key, "invoice.credit")
        note_ref = self.client.collection(CREDIT_NOTES).document(note_id)
        invoice_ref = self.client.collection(INVOICES).document(invoice_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            prior = note_ref.get(transaction=transaction)
            if prior.exists:
                data = prior.to_dict() or {}
                retry(data, payload_hash)
                return data
            snapshot = invoice_ref.get(transaction=transaction)
            if not snapshot.exists:
                raise _missing()
            invoice = snapshot.to_dict() or {}
            if invoice["status"] not in (ISSUED, SENT, PAID):
                raise CommandProblem("A credit note needs an issued invoice.")
            if amount > outstanding_minor(invoice):
                raise CommandProblem("A credit note cannot be more than the outstanding amount of the invoice.")
            counter, last = read_counter(self.client, transaction, "CN", moment)
            staged = self.audit.stage(transaction, moment, tenant_id=invoice["tenantId"])
            note = {"creditNoteId": note_id, "number": take_number(transaction, counter, "CN", moment, last),
                    "invoiceId": invoice_id, "invoiceNumber": invoice["number"], "tenantId": invoice["tenantId"],
                    "amountMinor": amount, "currency": invoice["currency"], "reason": reason,
                    "issuedAt": moment, "createdBy": actor, "payloadHash": payload_hash}
            transaction.create(note_ref, note)
            closed = amount == outstanding_minor(invoice) and not invoice.get("pendingEntryId")
            transaction.update(invoice_ref, {"creditedMinor": invoice.get("creditedMinor", 0) + amount,
                                             "updatedAt": moment,
                                             **({"status": VOID, "voidedBy": actor, "voidedAt": moment} if closed else {})})
            staged.add(actor=actor, action="invoice.credit_noted", tenant_id=invoice["tenantId"],
                       key=f"credit:{note_id}",
                       summary=f"Credit note {note['number']} issued for invoice {invoice['number']}.",
                       refs={"invoiceId": invoice_id, "creditNoteId": note_id, "creditNoteNumber": note["number"]})
            if seal is not None:
                seal(transaction)
            return note

        return credit_note_view(write(self.client.transaction(max_attempts=10)))

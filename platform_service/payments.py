from __future__ import annotations

import hashlib
import logging
import random
import re
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from google.api_core.exceptions import Aborted
from google.cloud import firestore

from .audit import AuditLog
from .commands import CommandProblem
from .ids import amount_minor, bad, command_id, digest, identity, local_date, local_day, retry, safe, text, timestamp, utc_now
from .invoices import (
    INVOICE_ID, INVOICES, ISSUED, PAID, SENT, UNCHECKED_COVER, VOID, invoice_pdf, outstanding_minor, read_counter,
    take_number)
from .mail import MailQueue, company_contact
from .operations import is_busy
from .signing import format_timestamp, parse_timestamp


ENTRIES = "payment_entries"
REFERENCES = "payment_references"
ACCOUNTS = "payment_accounts"
CHECKS = "payment_checks"
BACK_DATE_LIMIT = timedelta(days=3)
BUSY = "Someone else is changing this payment at the same moment. Check it and try again."
log = logging.getLogger(__name__)


_ENTRY = re.compile(r"^(?:pay|void)_[0-9a-f]{64}$")
_PAYMENT_FIELDS = frozenset({"amountMinor", "currency", "externalReference", "invoiceId", "receivedAt", "reason"})
_STORED_FIELDS = _PAYMENT_FIELDS | {"invoiceReference", "periodStart", "periodEnd"}
_COMMON_FIELDS = frozenset({"entryId", "tenantId", "type", "createdBy", "createdAt", "revision"})
_CHECK_FIELDS = frozenset({"entryId", "tenantId", "invoiceId", "invoiceNumber", "receiptNumber", "checkedBy",
                           "checkedAt"})


def _payment(body: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(body, Mapping) or set(body) != _PAYMENT_FIELDS:
        raise bad("Supply exactly amountMinor, currency, externalReference, invoiceId, receivedAt and reason.")
    amount = amount_minor(body["amountMinor"], "amountMinor")
    if body["currency"] != "MYR":
        raise bad("currency must be MYR.")
    invoice_id = body["invoiceId"]
    if not isinstance(invoice_id, str) or not INVOICE_ID.fullmatch(invoice_id):
        raise bad("invoiceId must name an invoice.")
    return {"amountMinor": amount, "currency": "MYR",
            "externalReference": text(body["externalReference"], "externalReference", 100),
            "invoiceId": invoice_id, "receivedAt": timestamp(body["receivedAt"], "receivedAt"),
            "reason": text(body["reason"], "reason", 500)}


def _receipt(data: Mapping[str, Any]) -> dict[str, Any]:
    fields = _STORED_FIELDS if data.get("type") == "payment" else frozenset({"receiptId", "reason"})
    return safe(data, _COMMON_FIELDS | fields)


def _account(data: Mapping[str, Any] | None, tenant_id: str) -> dict[str, Any]:
    if data is None:
        return {"tenantId": tenant_id, "revision": 0}
    revision = data.get("revision")
    if data.get("tenantId") != tenant_id or type(revision) is not int or revision < 0:
        raise CommandProblem("The payment account revision is invalid.")
    return {"tenantId": tenant_id, "revision": revision}


def _voided_ids(rows: list[Mapping[str, Any]], tenant_id: str) -> set[Any]:
    return {row.get("receiptId") for row in rows
            if row.get("tenantId") == tenant_id and row.get("type") == "void"
            and isinstance(row.get("entryId"), str) and _ENTRY.fullmatch(row["entryId"])
            and isinstance(row.get("receiptId"), str) and _ENTRY.fullmatch(row["receiptId"])
            and type(row.get("revision")) is int and row["revision"] > 0}


@dataclass(frozen=True)
class Coverage:
    checked_end: datetime | None
    unchecked_end: datetime | None
    covering_entries: tuple[str, ...]
    oldest_unchecked: datetime | None = None
    held_end: datetime | None = None
    checked_covering: tuple[str, ...] = ()

    @property
    def check_by(self) -> datetime | None:
        return None if self.oldest_unchecked is None else self.oldest_unchecked + UNCHECKED_COVER

    @property
    def paid_until(self) -> datetime | None:
        return max((end for end in (self.checked_end, self.unchecked_end) if end is not None), default=None)


def is_waiting_for_check(row: Mapping[str, Any], checks: set[str], voided: set[Any]) -> bool:
    return (row.get("type") == "payment" and row.get("entryId") not in checks and row.get("entryId") not in voided
            and bool(row.get("invoiceId")))


def may_check(entry: Mapping[str, Any], actor: str | None, person: str | None, solo: bool) -> bool:
    own = entry.get("createdBy") == actor or bool(person and entry.get("createdByPerson") == person)
    return solo or not own


def coverage_of(rows: list[Mapping[str, Any]], checks: set[str], tenant_id: str, at: datetime) -> Coverage:
    voided = _voided_ids(rows, tenant_id)
    checked_end = unchecked_end = held_end = None
    covering: list[str] = []
    checked_covering: list[str] = []
    payments = [row for row in sorted(rows, key=lambda item: item.get("revision") or 0)
                if row.get("tenantId") == tenant_id and row.get("type") == "payment"
                and row.get("entryId") not in voided and isinstance(row.get("entryId"), str)
                and (row.get("entryId") in checks or is_waiting_for_check(row, checks, voided))
                and _ENTRY.fullmatch(row["entryId"]) and isinstance(row.get("periodStart"), datetime)
                and isinstance(row.get("periodEnd"), datetime) and isinstance(row.get("createdAt"), datetime)]
    oldest_unchecked = min((row["createdAt"] for row in payments if row["entryId"] not in checks), default=None)
    for row in payments:
        entry_id, start, end = row["entryId"], row["periodStart"], row["periodEnd"]
        checked = entry_id in checks
        grace_end = row.get("graceEnd")
        if not isinstance(grace_end, datetime):
            grace_end = row["createdAt"] + UNCHECKED_COVER
        if not checked:
            grace_end = min(grace_end, oldest_unchecked + UNCHECKED_COVER)
        effective_end = end if checked else min(end, grace_end)
        if effective_end <= start:
            continue
        if not checked and effective_end < end:
            held_end = effective_end if held_end is None else max(held_end, effective_end)
        if checked:
            checked_end = effective_end if checked_end is None else max(checked_end, effective_end)
        else:
            unchecked_end = effective_end if unchecked_end is None else max(unchecked_end, effective_end)
        if start <= at < effective_end:
            covering.append(entry_id)
            if checked:
                checked_covering.append(entry_id)
    return Coverage(checked_end, unchecked_end, tuple(covering), oldest_unchecked, held_end, tuple(checked_covering))


class PaymentLedger:
    def __init__(self, client: firestore.Client, *, clock: Callable[[], datetime] = utc_now,
                 mail: MailQueue | None = None, audit: AuditLog | None = None) -> None:
        self.client = client
        self.clock = clock
        self.mail = mail if mail is not None else MailQueue(client)
        self.audit = audit if audit is not None else AuditLog(client, clock=clock)

    def _commit(self, write: Callable[[firestore.Transaction], dict[str, Any]]) -> dict[str, Any]:
        try:
            return write(self.client.transaction(max_attempts=10))
        except (Aborted, ValueError) as error:
            if not is_busy(error):
                raise
        time.sleep(random.uniform(0.05, 0.25))
        try:
            return write(self.client.transaction(max_attempts=10))
        except (Aborted, ValueError) as error:
            if not is_busy(error):
                raise
            raise CommandProblem(BUSY) from error

    def _mail_receipt(self, tenant_id: str, receipt: Mapping[str, Any], receipt_number: str, actor: str) -> None:
        try:
            contact = company_contact(self.client, tenant_id)
            if contact is None or contact[1] is None:
                outcome = {"status": "skipped", "jobId": None, "reason": "The company has no billing email."}
            else:
                invoice = self.client.collection(INVOICES).document(receipt["invoiceId"]).get().to_dict()
                outcome = self.mail.enqueue_or_report(
                    tenant_id, "receipt-" + receipt["entryId"], "receipt", contact[1],
                    {"tenantId": tenant_id, "companyName": contact[0],
                     "invoiceReference": receipt["invoiceReference"], "receiptNumber": receipt_number,
                     "amountMinor": receipt["amountMinor"], "currency": receipt["currency"],
                     "paidAt": local_date(parse_timestamp(receipt["receivedAt"]))},
                    actor, attached=invoice_pdf(self.client, invoice, contact) if invoice else None)
            reference = self.client.collection(ENTRIES).document(receipt["entryId"])
            if (reference.get().to_dict() or {}).get("mail") != outcome:
                reference.update({"mail": outcome})
        except Exception as error:
            log.error("payment receipt mail failed: %s", type(error).__name__)

    def get_account(self, tenant_id: str) -> dict[str, Any]:
        identity(tenant_id)
        snapshot = self.client.collection(ACCOUNTS).document(tenant_id).get()
        return _account(snapshot.to_dict() if snapshot.exists else None, tenant_id)

    def list_entries(self, tenant_id: str) -> list[dict[str, Any]]:
        identity(tenant_id)
        rows = [_receipt(snapshot.to_dict() or {}) for snapshot in self.client.collection(ENTRIES).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream()]
        return sorted(rows, key=lambda row: row["revision"])

    def snapshot(self, tenant_id: str, actor: str | None = None, person: str | None = None,
                 solo: bool = False) -> dict[str, Any]:
        identity(tenant_id)
        query = self.client.collection(ENTRIES).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id))
        check_query = self.client.collection(CHECKS).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id))
        account_ref = self.client.collection(ACCOUNTS).document(tenant_id)

        @firestore.transactional
        def read(transaction: firestore.Transaction) -> dict[str, Any]:
            checks = {row.id: row.to_dict() or {} for row in check_query.stream(transaction=transaction)}
            raw = [row.to_dict() or {} for row in query.stream(transaction=transaction)]
            voided = _voided_ids(raw, tenant_id)
            rows = [{**_receipt(row),
                     "check": safe(checks[row["entryId"]], _CHECK_FIELDS) if row.get("entryId") in checks else None,
                     "canCheck": is_waiting_for_check(row, set(checks), voided)
                     and may_check(row, actor, person, solo)}
                    for row in raw]
            account = account_ref.get(transaction=transaction)
            cover = coverage_of(raw, set(checks), tenant_id, self.clock())
            return {"entries": sorted(rows, key=lambda row: row["revision"]),
                    "account": _account(account.to_dict() if account.exists else None, tenant_id),
                    "cover": {"coveringEntryIds": list(cover.covering_entries),
                              "checkedCoveringEntryIds": list(cover.checked_covering),
                              "checkBy": None if cover.check_by is None else format_timestamp(cover.check_by)}}

        return read(self.client.transaction(read_only=True))

    def coverage(self, tenant_id: str, at: datetime, transaction: firestore.Transaction | None = None) -> Coverage:
        identity(tenant_id)
        if not isinstance(at, datetime) or at.tzinfo is None or at.utcoffset() is None:
            raise bad("at must be a timezone-aware datetime.")
        moment = at.astimezone(timezone.utc)
        query = self.client.collection(ENTRIES).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id))
        check_query = self.client.collection(CHECKS).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id))

        def read(reader: firestore.Transaction) -> Coverage:
            rows = [row.to_dict() or {} for row in query.stream(transaction=reader)]
            checks = {row.id for row in check_query.stream(transaction=reader)}
            return coverage_of(rows, checks, tenant_id, moment)

        if transaction is not None:
            return read(transaction)
        return firestore.transactional(read)(self.client.transaction(read_only=True))

    def latest_void(self, tenant_id: str) -> dict[str, Any] | None:
        identity(tenant_id)
        rows = [row.to_dict() or {} for row in self.client.collection(ENTRIES).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)).where(
            filter=firestore.FieldFilter("type", "==", "void")).stream()]
        return max(rows, key=lambda row: row.get("revision") or 0, default=None)

    def voided_payments(self, tenant_id: str) -> list[dict[str, Any]]:
        identity(tenant_id)
        rows = [row.to_dict() or {} for row in self.client.collection(ENTRIES).where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream()]
        voided = _voided_ids(rows, tenant_id)
        return [row for row in rows if row.get("type") == "payment" and row.get("entryId") in voided]

    def awaiting_check(self, actor: str | None = None, person: str | None = None,
                       solo: bool = False) -> list[dict[str, Any]]:
        entries = self.client.collection(ENTRIES)
        checked = {row.id for row in self.client.collection(CHECKS).stream()}
        voided = {(row.to_dict() or {}).get("receiptId") for row in entries.where(
            filter=firestore.FieldFilter("type", "==", "void")).stream()}
        rows = [row.to_dict() or {} for row in entries.where(
            filter=firestore.FieldFilter("type", "==", "payment")).stream()]
        waiting = [row for row in rows if is_waiting_for_check(row, checked, voided)]
        return [{**_receipt(row), "canCheck": may_check(row, actor, person, solo)}
                for row in sorted(waiting, key=lambda row: row["createdAt"])]

    def record(self, tenant_id: str, key: str, body: Mapping[str, Any], actor: str, *,
               is_owner: bool = False, person: str | None = None) -> dict[str, Any]:
        identity(tenant_id, key)
        actor = text(actor, "actor", 254)
        fields = _payment(body)
        normalized_reference = fields["externalReference"].casefold()
        payload_hash = digest({**fields, "externalReference": normalized_reference})
        entry_id = command_id("pay", tenant_id, key, "payment.record")
        entry_ref = self.client.collection(ENTRIES).document(entry_id)
        claim_ref = self.client.collection(REFERENCES).document(
            "external_" + hashlib.sha256(f"{tenant_id}\n{normalized_reference}".encode("utf-8")).hexdigest())
        old_claim_ref = self.client.collection(REFERENCES).document(
            "external_" + hashlib.sha256(normalized_reference.encode("utf-8")).hexdigest())
        account_ref = self.client.collection(ACCOUNTS).document(tenant_id)
        invoice_ref = self.client.collection(INVOICES).document(fields["invoiceId"])
        moment = self.clock()
        format_timestamp(moment)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            prior = entry_ref.get(transaction=transaction)
            if prior.exists:
                data = prior.to_dict() or {}
                retry(data, payload_hash)
                return _receipt(data)
            claim = claim_ref.get(transaction=transaction)
            old_claim = old_claim_ref.get(transaction=transaction)
            if not claim.exists and old_claim.exists and (old_claim.to_dict() or {}).get("tenantId") == tenant_id:
                claim = old_claim
            account = account_ref.get(transaction=transaction)
            invoice = invoice_ref.get(transaction=transaction).to_dict() or {}
            held = (claim.to_dict() or {}) if claim.exists else {}
            claimed_entry = held.get("entryId")
            if claim.exists:
                void = self.client.collection(REFERENCES).document(
                    "void_" + hashlib.sha256(str(claimed_entry).encode("utf-8")).hexdigest()
                ).get(transaction=transaction)
                voided = (void.to_dict() or {}) if void.exists else {}
                if (not isinstance(held.get("tenantId"), str) or voided.get("tenantId") != held.get("tenantId")
                        or voided.get("receiptId") != claimed_entry):
                    raise CommandProblem("That external reference is already recorded.")
            if invoice.get("tenantId") != tenant_id or invoice.get("status") in (None, "draft", "void"):
                raise CommandProblem("The invoice was not found as an issued invoice for this company.")
            if invoice["status"] != PAID and invoice.get("creditedMinor", 0) > 0 and outstanding_minor(invoice) <= 0:
                raise CommandProblem("Credit notes already cover this invoice, so it needs no payment."
                                     + (" Void the payment waiting to be checked; the invoice then closes."
                                        if invoice.get("pendingEntryId") else ""))
            if invoice["status"] == PAID or outstanding_minor(invoice) <= 0:
                raise CommandProblem("That invoice is already paid.")
            if invoice.get("pendingEntryId"):
                raise CommandProblem("This invoice already has a payment waiting to be checked. "
                                     "Check it or void it first.")
            received_day = local_day(parse_timestamp(fields["receivedAt"]))
            if received_day > local_day(moment):
                raise CommandProblem("The bank date cannot be in the future.")
            if received_day < local_day(invoice["issuedAt"]):
                raise CommandProblem("The bank date cannot be before the invoice date.")
            if local_day(moment) - received_day > BACK_DATE_LIMIT and not is_owner:
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                                    detail="A bank date more than 3 days back needs the owner.")
            if fields["amountMinor"] != outstanding_minor(invoice):
                raise CommandProblem(
                    f"The amount must equal the invoice balance of MYR {outstanding_minor(invoice) / 100:.2f}.")
            current = _account(account.to_dict() if account.exists else None, tenant_id)
            revision = current["revision"] + 1
            staged = self.audit.stage(transaction, moment, tenant_id=tenant_id)
            entry = {"entryId": entry_id, "tenantId": tenant_id, "type": "payment", **fields,
                     "invoiceReference": invoice["number"], "periodStart": invoice["periodStart"],
                     "periodEnd": invoice["periodEnd"], "createdBy": actor, "createdAt": moment,
                     **({"createdByPerson": person} if person else {}),
                     "graceEnd": moment if invoice.get("graceUsed") else moment + UNCHECKED_COVER,
                     "revision": revision, "payloadHash": payload_hash}
            transaction.create(entry_ref, entry)
            transaction.update(invoice_ref, {"pendingEntryId": entry_id, "pendingAt": moment, "graceUsed": True,
                                             "updatedAt": moment})
            claim_body = {"type": "external", "tenantId": tenant_id, "entryId": entry_id}
            if claim.exists:
                transaction.set(claim_ref, {**claim_body, "replacesEntryId": claimed_entry,
                                            "replacesTenantId": held["tenantId"]})
            else:
                transaction.create(claim_ref, claim_body)
            transaction.set(account_ref, {"tenantId": tenant_id, "revision": revision, "updatedAt": moment}, merge=True)
            staged.add(actor=actor, action="payment.recorded", tenant_id=tenant_id, key=f"record:{entry_id}",
                       summary=f"Payment recorded for invoice {invoice['number']}.",
                       refs={"entryId": entry_id, "invoiceId": fields["invoiceId"], "invoiceNumber": invoice["number"]})
            return _receipt(entry)

        return self._commit(write)

    def check(self, tenant_id: str, entry_id: str, actor: str, *,
              solo: bool | Callable[[firestore.Transaction], bool] = False,
              person: str | None = None) -> dict[str, Any]:
        identity(tenant_id)
        actor = text(actor, "actor", 254)
        if not isinstance(entry_id, str) or not _ENTRY.fullmatch(entry_id) or not entry_id.startswith("pay_"):
            raise bad("Enter a valid receipt ID.")
        entry_ref = self.client.collection(ENTRIES).document(entry_id)
        check_ref = self.client.collection(CHECKS).document(entry_id)
        void_ref = self.client.collection(REFERENCES).document(
            "void_" + hashlib.sha256(entry_id.encode("utf-8")).hexdigest())
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            prior = check_ref.get(transaction=transaction)
            entry = entry_ref.get(transaction=transaction).to_dict() or {}
            voided = void_ref.get(transaction=transaction).exists
            if entry.get("tenantId") != tenant_id or entry.get("type") != "payment":
                raise CommandProblem("The payment was not found for this company.")
            if voided:
                raise CommandProblem("That payment was voided.")
            if prior.exists:
                return prior.to_dict() or {}
            if not entry.get("invoiceId"):
                raise CommandProblem("This payment has no invoice. Void it and record it again for an invoice.")
            own = not may_check(entry, actor, person, False)
            if own and not (solo(transaction) if callable(solo) else solo):
                raise CommandProblem("Another person must check this payment.")
            invoice_ref = self.client.collection(INVOICES).document(entry["invoiceId"])
            invoice = invoice_ref.get(transaction=transaction).to_dict() or {}
            if entry["amountMinor"] != outstanding_minor(invoice):
                if invoice.get("creditedMinor", 0) > 0 and outstanding_minor(invoice) == 0:
                    raise CommandProblem("Credit notes already cover this invoice. Void this payment; "
                                         "the invoice then closes.")
                raise CommandProblem("The invoice balance changed. Void this payment and record it again.")
            counter, last = read_counter(self.client, transaction, "RCT", moment)
            staged = self.audit.stage(transaction, moment, tenant_id=tenant_id)
            check = {"entryId": entry_id, "tenantId": tenant_id, "invoiceId": entry["invoiceId"],
                     "invoiceNumber": entry["invoiceReference"],
                     "receiptNumber": take_number(transaction, counter, "RCT", moment, last),
                     "checkedBy": actor, "checkedAt": moment, **({"soloApproval": True} if own else {})}
            transaction.create(check_ref, check)
            transaction.update(invoice_ref, {"paidMinor": invoice["paidMinor"] + entry["amountMinor"],
                                             "status": PAID, "paidAt": moment, "pendingEntryId": None,
                                             "pendingAt": None, "updatedAt": moment})
            summary = f"Payment for invoice {entry['invoiceReference']} checked against the bank statement."
            staged.add(actor=actor, action="payment.checked", tenant_id=tenant_id, key=f"check:{entry_id}",
                       summary=f"Solo approval: {summary}" if own else summary,
                       refs={"entryId": entry_id, "invoiceId": entry["invoiceId"],
                             "invoiceNumber": entry["invoiceReference"], "receiptNumber": check["receiptNumber"],
                             "soloApproval": "true" if own else None})
            return check

        check = self._commit(write)
        entry = self.client.collection(ENTRIES).document(entry_id).get().to_dict() or {}
        self._mail_receipt(tenant_id, _receipt(entry), check["receiptNumber"], actor)
        return safe(check, _CHECK_FIELDS)

    def correct(
        self, tenant_id: str, key: str, receipt_id: str, body: Mapping[str, Any], actor: str,
        *, solo: bool = False, person: str | None = None,
        seal: Callable[[firestore.Transaction], None] | None = None,
    ) -> dict[str, Any]:
        identity(tenant_id, key)
        actor = text(actor, "actor", 254)
        if not isinstance(receipt_id, str) or not _ENTRY.fullmatch(receipt_id):
            raise bad("Enter a valid receipt ID.")
        if not isinstance(body, Mapping) or set(body) != {"reason"}:
            raise bad("A correction requires only a reason.")
        reason = text(body["reason"], "reason", 500)
        payload_hash = digest({"receiptId": receipt_id, "reason": reason})
        entry_id = command_id("void", tenant_id, key, "payment.correct")
        entry_ref = self.client.collection(ENTRIES).document(entry_id)
        original_ref = self.client.collection(ENTRIES).document(receipt_id)
        claim_ref = self.client.collection(REFERENCES).document(
            "void_" + hashlib.sha256(receipt_id.encode("utf-8")).hexdigest())
        check_ref = self.client.collection(CHECKS).document(receipt_id)
        account_ref = self.client.collection(ACCOUNTS).document(tenant_id)
        moment = self.clock()
        format_timestamp(moment)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            prior = entry_ref.get(transaction=transaction)
            if prior.exists:
                data = prior.to_dict() or {}
                retry(data, payload_hash)
                return _receipt(data)
            original = original_ref.get(transaction=transaction).to_dict() or {}
            claim = claim_ref.get(transaction=transaction)
            account = account_ref.get(transaction=transaction)
            checked = check_ref.get(transaction=transaction).exists
            invoice_ref = self.client.collection(INVOICES).document(original.get("invoiceId") or "none")
            invoice = invoice_ref.get(transaction=transaction).to_dict() or {}
            if original.get("tenantId") != tenant_id or original.get("type") != "payment":
                raise CommandProblem("The original payment was not found for this company.")
            if claim.exists:
                raise CommandProblem("That payment was already voided.")
            if not may_check(original, actor, person, solo):
                raise CommandProblem("Another person must void this payment.")
            current = _account(account.to_dict() if account.exists else None, tenant_id)
            revision = current["revision"] + 1
            staged = self.audit.stage(transaction, moment, tenant_id=tenant_id)
            entry = {"entryId": entry_id, "tenantId": tenant_id, "type": "void", "receiptId": receipt_id,
                     "reason": reason, "createdBy": actor, "createdAt": moment, "revision": revision,
                     "payloadHash": payload_hash}
            transaction.create(entry_ref, entry)
            transaction.create(claim_ref, {"type": "void", "tenantId": tenant_id, "entryId": entry_id,
                                           "receiptId": receipt_id})
            transaction.set(account_ref, {"tenantId": tenant_id, "revision": revision, "updatedAt": moment}, merge=True)
            if checked:
                transaction.update(invoice_ref, {
                    "paidMinor": invoice["paidMinor"] - original["amountMinor"], "paidAt": None,
                    "status": SENT if invoice.get("deliveredAt") else ISSUED, "updatedAt": moment})
            elif invoice.get("pendingEntryId") == receipt_id:
                covered = invoice.get("creditedMinor", 0) > 0 and outstanding_minor(invoice) == 0
                transaction.update(invoice_ref, {
                    "pendingEntryId": None, "pendingAt": None, "updatedAt": moment,
                    **({"status": VOID, "voidedBy": actor, "voidedAt": moment} if covered else {})})
            staged.add(actor=actor, action="payment.voided", tenant_id=tenant_id, key=f"void:{entry_id}",
                       summary=f"Payment for invoice {original.get('invoiceReference')} voided.",
                       refs={"entryId": entry_id, "receiptId": receipt_id,
                             "invoiceNumber": original.get("invoiceReference")})
            if seal is not None:
                seal(transaction)
            return _receipt(entry)

        return self._commit(write)

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from google.api_core.exceptions import Aborted
from google.cloud import firestore

from . import config
from .audit import EVENTS, AuditLog, event_id
from .commands import CommandProblem, PlanProblem
from .directory import DirectoryStore, clean_billing_email
from .ids import bad, check_key, command_id, digest, identity, retry, safe, text, utc_now
from .invoices import (
    CREDIT_NOTES, EXTENSION_DAYS, INVOICE_ID, INVOICES, ISSUED, PAID, SENT, InvoiceBook, extension_problem,
    outstanding_minor)
from .lifecycle import ACTION_LIFECYCLE, ALLOWED_TRANSITIONS, LifecycleService, LifecycleStore
from .mail import MailQueue, company_contact
from .operations import (
    COMPLETED, FAILED, PENDING, OperationContext, OperationError, OperationStore, RetryLater, Step, commit_when_free, is_busy)
from .operations import operation_id as operation_id_for
from .payments import ENTRIES, REFERENCES, PaymentLedger, may_check
from .plans import PlanStore, check_plan_id, has_price, clean_override, clean_version, clean_visibility
from .records import RecordError
from .signing import format_timestamp
from .staff import STAFF, active_accounts
from .subscriptions import ACTION_PLAN_PUT, ACTION_SUBSCRIPTION, SubscriptionService

APPROVALS = "approvals"
QUOTES = "quotes"
REQUESTED, APPROVED, REJECTED, EXPIRED, EXECUTED = "requested", "approved", "rejected", "expired", "executed"
STATUSES = frozenset({REQUESTED, APPROVED, REJECTED, EXPIRED, EXECUTED})
REQUEST_ROLES = ("owner", "operator")
DECIDE_ROLES = ("owner", "operator")
SCOPES = frozenset({"all", "mine", "others"})
APPROVAL_ID = re.compile(r"^apr_[0-9a-f]{64}$")
_PAYMENT = re.compile(r"^pay_[0-9a-f]{64}$")
_VIEW_FIELDS = frozenset({
    "approvalId", "action", "tenantId", "companyName", "summary", "params", "reason", "status", "requestedBy",
    "createdAt", "expiresAt", "decidedBy", "decidedAt", "rejectionReason", "operationId", "executedAt",
    "executionError", "closedBy", "closedAt"})
_PROGRESS_FIELDS = ("appliedSteps", "canClose")
_STEP_DONE = {
    "set_billing_email": "the billing email was changed", "notify_old_address": "the old address was told",
    "write_lifecycle": "the new company status was saved",
    "project_lifecycle": "the status was sent to the company's own project",
    "sync_record": "the company record was updated", "notify_status": "the company was told",
    "write_subscription": "the new package was saved",
    "project_plan": "the package limits were sent to the company's own project",
    "resign_record": "the company record was signed again", "extend_due_date": "the due date was extended",
    "issue_credit_note": "the credit note was issued", "void_payment": "the payment was voided",
    "record_quote": "the quote was recorded", "write_version": "the new package version was saved"}

LIFECYCLE_SUSPEND = "lifecycle.suspend"
LIFECYCLE_CANCEL = "lifecycle.cancel"
LIFECYCLE_REACTIVATE = "lifecycle.reactivate"
LIFECYCLE_EXPIRE = "lifecycle.expire"
REACTIVATABLE = ("suspended", "cancelled", "expired")
BILLING_EMAIL = "billing_email.change"
INVOICE_EXTENSION = "invoice.extension"
PLAN_OVERRIDE = "plan.override"
CREDIT_NOTE = "invoice.credit_note"
PAYMENT_VOID = "payment.void"
QUOTE_PRICE = "quote.price"
PACKAGE_PRICE = "package.price"

ACTION_LABELS = {
    LIFECYCLE_SUSPEND: "suspending a company", LIFECYCLE_CANCEL: "cancelling a company",
    LIFECYCLE_REACTIVATE: "reactivating a company", LIFECYCLE_EXPIRE: "expiring a company",
    BILLING_EMAIL: "billing email changes", INVOICE_EXTENSION: "invoice extensions",
    PLAN_OVERRIDE: "package overrides", CREDIT_NOTE: "credit notes", PAYMENT_VOID: "payment voids",
    QUOTE_PRICE: "quoted prices", PACKAGE_PRICE: "package prices"}

MAX_LISTED = 1000
GENERIC_FAILURE = "The action did not finish. Try again, or close this request and send a new one."
NOT_STARTED = "The change was approved but its work never started. Try again to start it, or close this request."
BUSY = "Someone else is changing this request at the same moment. Check it and try again."
GAVE_UP = ("The action could not reach a service after several tries. Try again, or close this request and send "
           "a new one.")
_SAFE_FAILURES = frozenset({"CommandProblem", "PlanProblem", "PlanLimit", "PlanMissing", "UsageMissing",
                            "LifecycleConflict", "HTTPException", "DirectoryError", "RecordError", "OperationError"})
_STATUS_PREFIX = re.compile(r"^\d{3}: ")


@dataclass(frozen=True)
class Handler:
    operation: str
    prepare: Callable[[Mapping[str, Any], str | None], tuple[dict[str, Any], str | None]]
    verify: Callable[[Mapping[str, Any], str | None, Mapping[str, Any]], None]
    describe: Callable[[Mapping[str, Any], str | None], str]
    execution: Callable[[Mapping[str, Any]], tuple[dict[str, Any], list[str]]]
    steps: Callable[[], list[Step]]


def mask_email(email: str | None) -> str:
    if not email:
        return "removed"
    name, _, domain = email.partition("@")
    return f"{name[:1]}***@{domain}"


def price_changes(plans: PlanStore, plan_id: str, content: Mapping[str, Any]) -> bool:
    plan = plans.get_plan(plan_id)
    if plan is None:
        return has_price(content.get("prices"))
    current = plans.get_version(plan_id, plan["currentVersion"]) or {}
    return has_price(current.get("prices")) and current.get("prices") != content.get("prices")


_PRICE_ONLY_LABELS = {"name": "name", "edition": "edition", "limits": "limits", "features": "features",
                      "tagline": "tagline", "highlights": "highlights", "sortOrder": "sort order", "notes": "notes",
                      "quotaSchemaVersion": "quota schema", "visibility": "visibility"}


def price_only_problem(plans: PlanStore, plan_id: str, content: Mapping[str, Any], visibility: str | None,
                       based_on: int) -> str | None:
    plan = plans.get_plan(plan_id)
    if plan is None or not based_on:
        return None
    base = plans.get_version(plan_id, based_on) or {}
    try:
        base_content = clean_version(base)
    except HTTPException:
        base_content = {}
    for field in sorted((set(content) | set(base_content)) - {"prices", "quotaSchemaVersion"}):
        if content.get(field) != base_content.get(field):
            return (f"A price approval can change only prices, but the {_PRICE_ONLY_LABELS.get(field, field)} "
                    "is also different from the current version. Send a request with only the price change.")
    if content.get("quotaSchemaVersion", 1) != base.get("quotaSchemaVersion", 1):
        return ("A price approval can change only prices, but the quota schema is also different from the current "
                "version. Send a request with only the price change.")
    if visibility is not None and visibility != plan.get("visibility"):
        return ("A price approval can change only prices, but the visibility is also different from the current "
                "version. Send a request with only the price change.")
    return None


def _expired(data: Mapping[str, Any], now: datetime) -> bool:
    return data.get("status") == REQUESTED and data["expiresAt"] <= now


def waiting_approvals(client: firestore.Client, now: datetime, *, not_by: str | None = None) -> int:
    total = 0
    for snapshot in client.collection(APPROVALS).where(
            filter=firestore.FieldFilter("status", "==", REQUESTED)).stream():
        data = snapshot.to_dict() or {}
        if not _expired(data, now) and (not_by is None or data.get("requestedBy") != not_by):
            total += 1
    return total


def _failure_text(error_type: str | None, message: str | None) -> str:
    if error_type == "RetryLater":
        return GAVE_UP
    if error_type in _SAFE_FAILURES and message:
        return _STATUS_PREFIX.sub("", message)[:200]
    return GENERIC_FAILURE


def _applied_steps(operation: Mapping[str, Any] | None) -> list[str]:
    recorded = (operation or {}).get("steps") or {}
    return [_STEP_DONE.get(name, name.replace("_", " ")) for name, step in recorded.items()
            if step.get("status") == "done"]


def _closing_problem(operation: Mapping[str, Any] | None, now: datetime) -> str | None:
    if operation is None:
        return None
    applied = _applied_steps(operation)
    if applied:
        return ("Part of this change is already done: " + "; ".join(applied)
                + ". It cannot be closed. Try again to finish it.")
    if operation.get("status") == COMPLETED:
        return "The work already finished."
    until = operation.get("leaseUntil")
    if operation.get("status") == PENDING and until is not None and until >= now:
        return "The work is running now. Wait a few minutes, then try again or close it."
    return None


def _operation_key(handler: "Handler", data: Mapping[str, Any]) -> str:
    approval_id = data["approvalId"]
    if data.get("operationId") == operation_id_for(handler.operation, approval_id):
        return approval_id
    return f"approval:{approval_id}"


class ApprovalBook:
    def __init__(
        self,
        client: firestore.Client,
        runner: OperationStore,
        audit: AuditLog,
        *,
        directory: DirectoryStore,
        lifecycle_store: LifecycleStore,
        lifecycle_service: LifecycleService,
        ledger: PaymentLedger,
        invoices: InvoiceBook,
        plans: PlanStore,
        subscriptions: SubscriptionService,
        mail: MailQueue,
        clock: Callable[[], datetime] = utc_now,
        solo_owner: Callable[..., bool] = lambda *_: False,
    ) -> None:
        self.client = client
        self.runner = runner
        self.audit = audit
        self.directory = directory
        self.lifecycle_store = lifecycle_store
        self.lifecycle_service = lifecycle_service
        self.ledger = ledger
        self.invoices = invoices
        self.plans = plans
        self.subscriptions = subscriptions
        self.mail = mail
        self.clock = clock
        self.solo_owner = solo_owner
        self.handlers = {
            LIFECYCLE_SUSPEND: self._lifecycle_handler("suspended", "Suspend"),
            LIFECYCLE_CANCEL: self._lifecycle_handler("cancelled", "Cancel"),
            LIFECYCLE_REACTIVATE: self._lifecycle_handler("active", "Reactivate"),
            LIFECYCLE_EXPIRE: self._lifecycle_handler("expired", "Expire"),
            BILLING_EMAIL: self._billing_email_handler(),
            INVOICE_EXTENSION: self._extension_handler(),
            PLAN_OVERRIDE: self._override_handler(),
            CREDIT_NOTE: self._credit_note_handler(),
            PAYMENT_VOID: self._void_handler(),
            QUOTE_PRICE: self._quote_handler(),
            PACKAGE_PRICE: self._package_price_handler(),
        }

    def action_labels(self) -> list[str]:
        return [ACTION_LABELS[name] for name in self.handlers]

    def recovery_actions(self) -> dict[str, list[Step]]:
        owned = (BILLING_EMAIL, INVOICE_EXTENSION, CREDIT_NOTE, PAYMENT_VOID, QUOTE_PRICE)
        return {self.handlers[name].operation: self.handlers[name].steps() for name in owned}

    def _company(self, tenant_id: Any) -> tuple[str, str | None]:
        identity(tenant_id)
        try:
            contact = company_contact(self.client, tenant_id)
        except Exception:
            contact = None
        if contact is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown company.")
        return contact

    def _required_tenant(self, tenant_id: Any) -> str:
        if tenant_id is None:
            raise bad("This request needs a tenantId.")
        self._company(tenant_id)
        return tenant_id

    def _invoice(self, invoice_id: Any) -> dict[str, Any]:
        if not isinstance(invoice_id, str) or not INVOICE_ID.fullmatch(invoice_id):
            raise bad("invoiceId must name an invoice.")
        data = self.client.collection(INVOICES).document(invoice_id).get().to_dict()
        if data is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invoice not found.")
        return data

    def _invoice_tenant(self, invoice: Mapping[str, Any], tenant_id: str | None) -> str:
        if tenant_id is not None and tenant_id != invoice["tenantId"]:
            raise bad("That invoice belongs to another company.")
        return invoice["tenantId"]

    @staticmethod
    def _only(raw: Any, allowed: set[str], required: set[str]) -> None:
        if not isinstance(raw, Mapping) or set(raw) - allowed or not required <= set(raw):
            raise bad("Supply exactly: " + ", ".join(sorted(required)) + (
                ". Optional: " + ", ".join(sorted(allowed - required)) if allowed - required else "."))

    def _lifecycle_handler(self, target: str, label: str) -> Handler:
        allowed = {"expectedRevision", "ticket"} | ({"paymentEntryId"} if target == "active" else set())
        required = {"expectedRevision"} | ({"paymentEntryId"} if target == "active" else set())

        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, allowed, required)
            tenant = self._required_tenant(tenant_id)
            revision, entry, ticket = raw.get("expectedRevision"), raw.get("paymentEntryId"), raw.get("ticket")
            if type(revision) is not int or revision < 0:
                raise bad("expectedRevision must be a whole number of 0 or more.")
            if target == "active" and (not isinstance(entry, str) or not _PAYMENT.fullmatch(entry)):
                raise bad("Reactivation needs the paymentEntryId of a payment that covers today.")
            if ticket is not None and (not isinstance(ticket, str) or len(ticket) > 100):
                raise bad("A ticket is at most 100 characters.")
            return {"state": target, "expectedRevision": revision, "paymentEntryId": entry, "ticket": ticket}, tenant

        def verify(params: Mapping[str, Any], tenant_id: str | None, _: Mapping[str, Any]) -> None:
            current = self.lifecycle_store.get(tenant_id)
            if current is None:
                raise CommandProblem("This company has no status yet.")
            if current["revision"] != params["expectedRevision"]:
                raise CommandProblem("The company status changed since this was requested. Send a new request.")
            if target not in ALLOWED_TRANSITIONS.get(current["state"], frozenset()):
                raise CommandProblem("That status change is not allowed from the current status.")
            if target == "active":
                if current["state"] not in REACTIVATABLE:
                    raise CommandProblem("Reactivate applies only to a suspended, cancelled or expired company.")
                covering = self.ledger.coverage(tenant_id, self.clock()).covering_entries
                if params["paymentEntryId"] not in covering:
                    raise CommandProblem("Reactivation needs a payment that covers today.")

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            params = data["params"]
            return ({"tenantId": data["tenantId"], "state": target, "expectedRevision": params["expectedRevision"],
                     "paymentEntryId": params["paymentEntryId"], "reason": data["reason"],
                     "ticket": params["ticket"], "requestedBy": data["decidedBy"]},
                    ["state", "expectedRevision", "paymentEntryId"])

        return Handler(ACTION_LIFECYCLE, prepare, verify, lambda _, company: f"{label} {company}.", execution,
                       self.lifecycle_service.transition_steps)

    def _billing_email_handler(self) -> Handler:
        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, {"billingEmail"}, {"billingEmail"})
            tenant = self._required_tenant(tenant_id)
            try:
                new = clean_billing_email(raw["billingEmail"])
            except RecordError as error:
                raise bad(str(error)) from None
            return {"billingEmail": new, "previousBillingEmail": self._company(tenant)[1]}, tenant

        def verify(params: Mapping[str, Any], tenant_id: str | None, _: Mapping[str, Any]) -> None:
            current = self._company(tenant_id)[1]
            if current != params["previousBillingEmail"]:
                raise CommandProblem("The billing email changed since this was requested. Send a new request.")
            if params["billingEmail"] == current:
                raise CommandProblem("That is already the billing email.")

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            params = data["params"]
            return ({"tenantId": data["tenantId"], "billingEmail": params["billingEmail"],
                     "previousBillingEmail": params["previousBillingEmail"], "approvalId": data["approvalId"],
                     "actor": data["decidedBy"]}, ["billingEmail"])

        def steps() -> list[Step]:
            def set_apply(ctx: OperationContext) -> dict[str, Any]:
                self.directory.set_billing_email(
                    ctx.params["tenantId"], ctx.params["billingEmail"], audit=self.audit,
                    actor=ctx.params["actor"], key=f"billing-email:{ctx.operation_id}",
                    expected_previous=ctx.params["previousBillingEmail"], seal=ctx.seal)
                return {"changed": True}

            def set_check(ctx: OperationContext) -> bool:
                return self.audit.client.collection(EVENTS).document(
                    event_id("billing_email.changed", f"billing-email:{ctx.operation_id}")).get().exists

            def notify_apply(ctx: OperationContext) -> dict[str, Any]:
                previous = ctx.params["previousBillingEmail"]
                if not previous:
                    return {"status": "skipped", "jobId": None}
                tenant_id = ctx.params["tenantId"]
                outcome = self.mail.enqueue_or_report(
                    tenant_id, "billing-email-" + ctx.params["approvalId"], "billing_email_changed", previous,
                    {"tenantId": tenant_id, "companyName": self._company(tenant_id)[0],
                     "newEmailHint": mask_email(ctx.params["billingEmail"])}, ctx.params["actor"])
                return {"status": outcome["status"], "jobId": outcome["jobId"]}

            return [Step("set_billing_email", set_apply, set_check),
                    Step("notify_old_address", notify_apply, lambda _: False)]

        return Handler(BILLING_EMAIL, prepare, verify,
                       lambda _, company: f"Change the billing email for {company}.", execution, steps)

    def _extension_handler(self) -> Handler:
        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, {"invoiceId", "days"}, {"invoiceId"})
            invoice = self._invoice(raw["invoiceId"])
            days = raw.get("days", EXTENSION_DAYS)
            if type(days) is not int or not 1 <= days <= EXTENSION_DAYS:
                raise bad(f"An extension is 1 to {EXTENSION_DAYS} days.")
            tenant = self._invoice_tenant(invoice, tenant_id)
            return {"invoiceId": raw["invoiceId"], "invoiceNumber": invoice.get("number"), "days": days}, tenant

        def verify(params: Mapping[str, Any], tenant_id: str | None, _: Mapping[str, Any]) -> None:
            problem = extension_problem(self._invoice(params["invoiceId"]))
            if problem is not None:
                raise CommandProblem(problem)

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            params = data["params"]
            return ({"tenantId": data["tenantId"], "invoiceId": params["invoiceId"], "days": params["days"],
                     "actor": data["decidedBy"]}, ["dueAt"])

        def steps() -> list[Step]:
            def apply(ctx: OperationContext) -> dict[str, Any]:
                self.invoices.extend_due(ctx.params["invoiceId"], ctx.params["days"], ctx.operation_id,
                                         ctx.params["actor"], seal=ctx.seal)
                return {"extended": True}

            def check(ctx: OperationContext) -> bool:
                return self._invoice(ctx.params["invoiceId"]).get("extensionOperationId") == ctx.operation_id

            return [Step("extend_due_date", apply, check)]

        return Handler(INVOICE_EXTENSION, prepare, verify,
                       lambda params, _: f"Extend invoice {params['invoiceNumber']} by {params['days']} days.",
                       execution, steps)

    def _override_handler(self) -> Handler:
        def cleaned(params: Mapping[str, Any], reason: str, actor: str, now: datetime) -> dict[str, Any]:
            return clean_override({**params, "reason": reason}, now=now, actor=actor)

        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, {"limits", "features", "ticket", "expiresAt"}, {"expiresAt"})
            tenant = self._required_tenant(tenant_id)
            return {key: raw[key] for key in ("limits", "features", "ticket", "expiresAt") if key in raw}, tenant

        def verify(params: Mapping[str, Any], tenant_id: str | None, context: Mapping[str, Any]) -> None:
            cleaned(params, context["reason"], "check", self.clock())

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            change = cleaned(data["params"], data["reason"], data["requestedBy"], data["decidedAt"])
            return ({"tenantId": data["tenantId"], "change": change, "requestedBy": data["decidedBy"]},
                    sorted(change))

        return Handler(ACTION_SUBSCRIPTION, prepare, verify,
                       lambda _, company: f"Add a plan override for {company}.", execution,
                       self.subscriptions.subscription_steps)

    def _credit_note_handler(self) -> Handler:
        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, {"invoiceId", "amountMinor"}, {"invoiceId", "amountMinor"})
            invoice = self._invoice(raw["invoiceId"])
            amount = raw["amountMinor"]
            if type(amount) is not int or amount <= 0:
                raise bad("amountMinor must be a positive integer in MYR sen.")
            tenant = self._invoice_tenant(invoice, tenant_id)
            return {"invoiceId": raw["invoiceId"], "invoiceNumber": invoice.get("number"), "amountMinor": amount}, tenant

        def verify(params: Mapping[str, Any], tenant_id: str | None, _: Mapping[str, Any]) -> None:
            invoice = self._invoice(params["invoiceId"])
            if invoice["status"] not in (ISSUED, SENT, PAID):
                raise CommandProblem("A credit note needs an issued invoice.")
            if params["amountMinor"] > outstanding_minor(invoice):
                raise CommandProblem("A credit note cannot be more than the outstanding amount of the invoice.")

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            params = data["params"]
            return ({"tenantId": data["tenantId"], "invoiceId": params["invoiceId"],
                     "amountMinor": params["amountMinor"], "reason": data["reason"], "actor": data["decidedBy"]},
                    ["creditNote"])

        def steps() -> list[Step]:
            def apply(ctx: OperationContext) -> dict[str, Any]:
                note = self.invoices.credit_note(
                    ctx.params["invoiceId"], ctx.operation_id,
                    {"amountMinor": ctx.params["amountMinor"], "reason": ctx.params["reason"]}, ctx.params["actor"],
                    seal=ctx.seal)
                return {"creditNoteNumber": note["number"]}

            def check(ctx: OperationContext) -> bool:
                note_id = command_id("cn", ctx.params["invoiceId"], ctx.operation_id, "invoice.credit")
                return self.client.collection(CREDIT_NOTES).document(note_id).get().exists

            return [Step("issue_credit_note", apply, check)]

        return Handler(CREDIT_NOTE, prepare, verify,
                       lambda params, _: f"Issue a credit note on invoice {params['invoiceNumber']}.", execution, steps)

    def _void_handler(self) -> Handler:
        def entry_of(tenant_id: str, receipt_id: str) -> dict[str, Any]:
            entry = self.client.collection(ENTRIES).document(receipt_id).get().to_dict() or {}
            if entry.get("tenantId") != tenant_id or entry.get("type") != "payment":
                raise CommandProblem("The payment was not found for this company.")
            return entry

        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, {"receiptId"}, {"receiptId"})
            tenant = self._required_tenant(tenant_id)
            receipt_id = raw["receiptId"]
            if not isinstance(receipt_id, str) or not _PAYMENT.fullmatch(receipt_id):
                raise bad("Enter a valid receipt ID.")
            return {"receiptId": receipt_id, "invoiceNumber": entry_of(tenant, receipt_id).get("invoiceReference")}, tenant

        def verify(params: Mapping[str, Any], tenant_id: str | None, context: Mapping[str, Any]) -> None:
            entry = entry_of(tenant_id, params["receiptId"])
            if self.client.collection(REFERENCES).document(
                    "void_" + hashlib.sha256(params["receiptId"].encode("utf-8")).hexdigest()
            ).get().exists:
                raise CommandProblem("That payment was already voided.")
            if (context["approver"] is not None and not context.get("solo")
                    and not may_check(entry, context["approver"], context.get("person"), False)):
                raise CommandProblem("Another person must void this payment.")
            requester = context.get("requester")
            if (context["approver"] is None and requester is not None and not context.get("solo")
                    and requester != entry.get("createdBy")
                    and not self._other_approvers(entry, requester, context.get("person"))):
                raise CommandProblem("The person who recorded this payment cannot approve its void. "
                                     "Ask them to request it, so another approver can decide.")

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            return ({"tenantId": data["tenantId"], "receiptId": data["params"]["receiptId"],
                     "reason": data["reason"], "actor": data["decidedBy"],
                     "person": data.get("decidedByPerson"), "solo": bool(data.get("soloApproval"))}, ["void"])

        def steps() -> list[Step]:
            def apply(ctx: OperationContext) -> dict[str, Any]:
                void = self.ledger.correct(ctx.params["tenantId"], ctx.operation_id, ctx.params["receiptId"],
                                           {"reason": ctx.params["reason"]}, ctx.params["actor"],
                                           solo=ctx.params.get("solo", False), person=ctx.params.get("person"),
                                           seal=ctx.seal)
                return {"voidEntryId": void["entryId"]}

            def check(ctx: OperationContext) -> bool:
                entry_id = command_id("void", ctx.params["tenantId"], ctx.operation_id, "payment.correct")
                return self.client.collection(ENTRIES).document(entry_id).get().exists

            return [Step("void_payment", apply, check)]

        return Handler(PAYMENT_VOID, prepare, verify,
                       lambda params, company: f"Void the payment for invoice {params['invoiceNumber']} ({company}).",
                       execution, steps)

    def _quote_handler(self) -> Handler:
        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, {"amountMinor", "billingInterval"}, {"amountMinor", "billingInterval"})
            tenant = self._required_tenant(tenant_id)
            amount, interval = raw["amountMinor"], raw["billingInterval"]
            if type(amount) is not int or amount <= 0:
                raise bad("amountMinor must be a positive integer in MYR sen.")
            if interval not in ("monthly", "yearly"):
                raise bad("Choose a monthly or yearly billing period.")
            return {"amountMinor": amount, "billingInterval": interval, "planId": current_plan_id(tenant)}, tenant

        def current_plan_id(tenant_id: str) -> str:
            try:
                return self.plans.effective(tenant_id, self.clock())["planId"]
            except PlanProblem as problem:
                raise CommandProblem(str(problem)) from None

        def verify(params: Mapping[str, Any], tenant_id: str | None, _: Mapping[str, Any]) -> None:
            self._company(tenant_id)
            try:
                effective = self.plans.effective(tenant_id, self.clock())
            except PlanProblem as problem:
                raise CommandProblem(str(problem)) from None
            if (effective.get("prices") or {}).get(params["billingInterval"]) is not None:
                raise CommandProblem("This package has a fixed price. A quote applies to a package priced by quote.")
            if params.get("planId") not in (None, effective["planId"]):
                raise CommandProblem("The package changed since this was requested. Send a new request.")

        def subscription_ref(tenant_id: str) -> Any:
            return self.client.collection("subscriptions").document(tenant_id)

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            params = data["params"]
            return ({"tenantId": data["tenantId"], "amountMinor": params["amountMinor"],
                     "billingInterval": params["billingInterval"],
                     "planId": params.get("planId") or current_plan_id(data["tenantId"]),
                     "reason": data["reason"], "approvalId": data["approvalId"],
                     "requestedBy": data["requestedBy"], "actor": data["decidedBy"]},
                    ["amountMinor", "billingInterval"])

        def steps() -> list[Step]:
            def reference(ctx: OperationContext) -> Any:
                quote_id = command_id("quote", ctx.params["tenantId"], ctx.operation_id, "quote.price")
                return quote_id, self.client.collection(QUOTES).document(quote_id)

            def apply(ctx: OperationContext) -> dict[str, Any]:
                quote_id, document = reference(ctx)
                moment = self.clock()
                if not document.get().exists:
                    verify(ctx.params, ctx.params["tenantId"], {})
                seen = (subscription_ref(ctx.params["tenantId"]).get().to_dict() or {}).get("revision")

                @firestore.transactional
                def write(transaction: firestore.Transaction) -> None:
                    if document.get(transaction=transaction).exists:
                        return
                    latest = (subscription_ref(ctx.params["tenantId"]).get(transaction=transaction).to_dict() or {})
                    if latest.get("revision") != seen:
                        raise CommandProblem("The package changed since this was requested. Send a new request.")
                    staged = self.audit.stage(transaction, moment, tenant_id=ctx.params["tenantId"])
                    transaction.create(document, {
                        "quoteId": quote_id, "tenantId": ctx.params["tenantId"],
                        "amountMinor": ctx.params["amountMinor"], "currency": "MYR",
                        "billingInterval": ctx.params["billingInterval"], "planId": ctx.params["planId"],
                        "status": "approved",
                        "approvalId": ctx.params["approvalId"], "requestedBy": ctx.params["requestedBy"],
                        "approvedBy": ctx.params["actor"], "reason": ctx.params["reason"], "createdAt": moment})
                    staged.add(actor=ctx.params["actor"], action="quote.priced", tenant_id=ctx.params["tenantId"],
                               key=f"quote:{quote_id}", summary="A quoted price was approved.",
                               refs={"quoteId": quote_id, "approvalId": ctx.params["approvalId"]})
                    ctx.seal(transaction)

                write(self.client.transaction(max_attempts=10))
                return {"quoteId": quote_id}

            return [Step("record_quote", apply, lambda ctx: reference(ctx)[1].get().exists)]

        return Handler(QUOTE_PRICE, prepare, verify,
                       lambda _, company: f"Approve a quoted price for {company}.", execution, steps)

    def _package_price_handler(self) -> Handler:
        def prepare(raw: Mapping[str, Any], tenant_id: str | None) -> tuple[dict[str, Any], str | None]:
            self._only(raw, {"planId", "version", "visibility"}, {"planId", "version"})
            plan_id = check_plan_id(raw["planId"] if isinstance(raw["planId"], str) else "")
            if not isinstance(raw["version"], Mapping):
                raise bad("version must be the new plan version.")
            content = clean_version(raw["version"])
            visibility = None if raw.get("visibility") is None else clean_visibility(raw["visibility"])
            plan = self.plans.get_plan(plan_id)
            if not price_changes(self.plans, plan_id, content):
                raise bad("This version does not change the price.")
            based_on = plan["currentVersion"] if plan else 0
            problem = price_only_problem(self.plans, plan_id, content, visibility, based_on)
            if problem:
                raise bad(problem)
            return ({"planId": plan_id, "content": content, "visibility": visibility,
                     "basedOnVersion": based_on}, tenant_id)

        def verify(params: Mapping[str, Any], tenant_id: str | None, _: Mapping[str, Any]) -> None:
            plan = self.plans.get_plan(params["planId"])
            if (plan["currentVersion"] if plan else 0) != params["basedOnVersion"]:
                raise CommandProblem("The package changed since this was requested. Send a new request.")
            problem = price_only_problem(self.plans, params["planId"], params["content"], params["visibility"],
                                         params["basedOnVersion"])
            if problem:
                raise CommandProblem(problem)

        def execution(data: Mapping[str, Any]) -> tuple[dict[str, Any], list[str]]:
            params = data["params"]
            return ({"planId": params["planId"], "content": params["content"], "visibility": params["visibility"],
                     "basedOnVersion": params["basedOnVersion"], "createdBy": data["decidedBy"]},
                    sorted(params["content"]))

        return Handler(ACTION_PLAN_PUT, prepare, verify,
                       lambda params, _: f"Change the price of package {params['planId']}.", execution,
                       self.subscriptions.plan_put_steps)

    @staticmethod
    def _new_package_is_owner_only(action: str, params: Mapping[str, Any], role: str) -> None:
        if action == PACKAGE_PRICE and not params["basedOnVersion"] and role != "owner":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                                detail="Only the owner can create a new package through a price approval.")

    def _new_package_from_someone_else(self, data: Mapping[str, Any]) -> bool:
        if not (data["action"] == PACKAGE_PRICE and not (data.get("params") or {}).get("basedOnVersion")):
            return False
        role = data.get("requestedByRole") or active_accounts(self.client).get(data["requestedBy"])
        return role != "owner"

    def _other_approvers(self, entry: Mapping[str, Any], requester: str, person: str | None) -> list[str]:
        barred_people = {person, entry.get("createdByPerson")} - {None}
        snapshots = self.client.collection(STAFF).where(filter=firestore.FieldFilter("status", "==", "active")).stream()
        return [row["email"] for row in (snapshot.to_dict() or {} for snapshot in snapshots)
                if row.get("role") in ("owner", "operator")
                and row["email"] not in (requester, entry.get("createdBy"))
                and (row.get("uid") or row["email"]) not in barred_people]

    @staticmethod
    def _same_person(data: Mapping[str, Any], actor: str, person: str | None) -> bool:
        return data["requestedBy"] == actor or (
            person is not None and data.get("requestedByPerson") == person)

    def _recorder_barred(self, data: Mapping[str, Any], actor: str, person: str | None, solo: bool) -> bool:
        if data["action"] != PAYMENT_VOID:
            return False
        entry = self.client.collection(ENTRIES).document(data["params"]["receiptId"]).get().to_dict() or {}
        return not may_check(entry, actor, person, solo)

    def view(self, data: Mapping[str, Any], actor: str, role: str, now: datetime | None = None,
             person: str | None = None, solo: bool = False) -> dict[str, Any]:
        moment = now or self.clock()
        current = EXPIRED if _expired(data, moment) else data["status"]
        pending = current == REQUESTED
        return {**safe(data, _VIEW_FIELDS), **{name: data[name] for name in _PROGRESS_FIELDS if name in data},
                "status": current,
                "canDecide": pending and role in DECIDE_ROLES and (solo or not self._same_person(data, actor, person))
                and not self._new_package_from_someone_else(data)
                and not (pending and self._recorder_barred(data, actor, person, solo)),
                "canReject": pending and role in DECIDE_ROLES}

    def request(self, actor: str, role: str, key: str, body: Mapping[str, Any],
                person: str | None = None) -> dict[str, Any]:
        check_key(key)
        actor = text(actor, "actor", 254)
        person = person or actor
        if role not in REQUEST_ROLES:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner or an operator can ask.")
        allowed = {"action", "tenantId", "reason", "params"}
        if not isinstance(body, Mapping) or set(body) - allowed or not {"action", "reason"} <= set(body):
            raise bad("Supply action, reason and params. tenantId is optional.")
        handler = self.handlers.get(body["action"]) if isinstance(body["action"], str) else None
        if handler is None:
            raise bad("Unknown approval action.")
        reason = text(body["reason"], "reason", 500)
        if len(reason) < 3:
            raise bad("Give a reason of 3 to 500 characters.")
        raw = body.get("params", {})
        if not isinstance(raw, Mapping):
            raise bad("params must be an object.")
        tenant_id = body.get("tenantId")
        if tenant_id is not None:
            identity(tenant_id)
        params, tenant_id = handler.prepare(raw, tenant_id)
        self._new_package_is_owner_only(body["action"], params, role)
        handler.verify(params, tenant_id, {"reason": reason, "approver": None, "requester": actor,
                                           "person": person, "solo": self.solo_owner(actor)})
        company = self._company(tenant_id)[0] if tenant_id is not None else None
        approval_id = command_id("apr", actor, key, "approval.request")
        payload_hash = digest({"action": body["action"], "tenantId": tenant_id, "reason": reason, "params": params})
        moment = self.clock()
        reference = self.client.collection(APPROVALS).document(approval_id)
        record = {
            "approvalId": approval_id, "action": body["action"], "tenantId": tenant_id, "companyName": company,
            "summary": handler.describe(params, company), "params": params, "reason": reason,
            "status": REQUESTED, "requestedBy": actor, "requestedByPerson": person, "requestedByRole": role,
            "createdAt": moment,
            "expiresAt": moment + timedelta(days=config.APPROVAL_DAYS), "decidedBy": None, "decidedAt": None,
            "rejectionReason": None, "operationId": None, "executedAt": None, "executionError": None,
            "payloadHash": payload_hash}

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            prior = reference.get(transaction=transaction)
            if prior.exists:
                data = prior.to_dict() or {}
                retry(data, payload_hash)
                return data
            staged = self.audit.stage(transaction, moment, tenant_id=tenant_id)
            transaction.create(reference, record)
            staged.add(actor=actor, action="approval.requested", tenant_id=tenant_id, key=f"request:{approval_id}",
                       summary=record["summary"], refs={"approvalId": approval_id, "approvalAction": body["action"]})
            return record

        return self.view(write(self.client.transaction(max_attempts=10)), actor, role, person=person,
                         solo=self.solo_owner(actor))

    def _read(self, approval_id: str) -> dict[str, Any]:
        if not isinstance(approval_id, str) or not APPROVAL_ID.fullmatch(approval_id):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Approval not found.")
        data = self.client.collection(APPROVALS).document(approval_id).get().to_dict()
        if data is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Approval not found.")
        return data

    def _settle_executed(self, data: dict[str, Any]) -> dict[str, Any]:
        if data["status"] != APPROVED:
            return data
        operation = self.runner.get(data["operationId"]) if data.get("operationId") else None
        progress = {"appliedSteps": _applied_steps(operation),
                    "canClose": _closing_problem(operation, self.clock()) is None}
        if operation is None:
            return {**data, **progress, "executionError": NOT_STARTED}
        if operation.get("status") == FAILED:
            error = operation.get("error") or {}
            message = _failure_text(error.get("type"), error.get("message"))
            if data.get("executionError") != message:
                self.client.collection(APPROVALS).document(data["approvalId"]).update({"executionError": message})
            return {**data, **progress, "executionError": message}
        data = {**data, **progress}
        if operation.get("status") != COMPLETED:
            return data
        reference = self.client.collection(APPROVALS).document(data["approvalId"])
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current.get("status") != APPROVED:
                return current
            staged = self.audit.stage(transaction, moment, tenant_id=current.get("tenantId"))
            fields = {"status": EXECUTED, "executedAt": moment, "executionError": None}
            transaction.update(reference, fields)
            staged.add(actor=current["decidedBy"], action="approval.executed", tenant_id=current.get("tenantId"),
                       key=f"executed:{current['approvalId']}", summary=current["summary"],
                       refs={"approvalId": current["approvalId"], "operationId": current["operationId"]})
            return {**current, **fields}

        return write(self.client.transaction(max_attempts=10))

    def get(self, approval_id: str, actor: str, role: str, person: str | None = None) -> dict[str, Any]:
        return self.view(self._settle_executed(self._read(approval_id)), actor, role, person=person,
                         solo=self.solo_owner(actor))

    def list_approvals(self, actor: str, role: str, *, status_filter: str | None = None, scope: str = "all",
                       tenant_id: str | None = None, limit: int = 50, after: str | None = None,
                       person: str | None = None) -> dict[str, Any]:
        if status_filter is not None and status_filter not in STATUSES:
            raise bad("status must be requested, approved, rejected, expired or executed.")
        if scope not in SCOPES:
            raise bad("scope must be all, mine or others.")
        if tenant_id is not None:
            identity(tenant_id)
        if type(limit) is not int or not 1 <= limit <= 200:
            raise bad("limit must be between 1 and 200.")
        moment = self.clock()
        collection = self.client.collection(APPROVALS)
        if status_filter is None:
            snapshots = list(collection.order_by("createdAt", direction=firestore.Query.DESCENDING)
                             .limit(MAX_LISTED).stream())
        else:
            stored = {REQUESTED: (REQUESTED, EXPIRED), EXPIRED: (REQUESTED, EXPIRED),
                      EXECUTED: (APPROVED, EXECUTED)}.get(status_filter, (status_filter,))
            snapshots = [snapshot for name in stored for snapshot in collection.where(
                filter=firestore.FieldFilter("status", "==", name)).stream()]
        rows = [snapshot.to_dict() or {} for snapshot in snapshots]
        rows = [row for row in rows if tenant_id is None or row.get("tenantId") == tenant_id]
        rows = [self._settle_executed(row) if row.get("status") == APPROVED else row for row in rows]
        solo = self.solo_owner(actor)
        pairs = [(row, self.view(row, actor, role, moment, person, solo)) for row in rows]
        views = [view for row, view in pairs
                 if (status_filter is None or view["status"] == status_filter)
                 and (scope == "all" or (scope == "mine") == self._same_person(row, actor, person))
                 and (tenant_id is None or view["tenantId"] == tenant_id)]
        views.sort(key=lambda row: (row["createdAt"], row["approvalId"]), reverse=True)
        if after is not None:
            position = next((index for index, row in enumerate(views) if row["approvalId"] == after), None)
            if position is None:
                raise bad("after must be an approval ID from a previous page.")
            views = views[position + 1:]
        return {"approvals": views[:limit], "nextAfter": views[limit - 1]["approvalId"] if len(views) > limit else None}

    def reject(self, approval_id: str, actor: str, role: str, reason: Any = None,
               person: str | None = None) -> dict[str, Any]:
        if role not in DECIDE_ROLES:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner or an operator can decide.")
        note = None if reason is None else text(reason, "reason", 500)
        reference = self.client.collection(APPROVALS).document(self._read(approval_id)["approvalId"])
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            data = reference.get(transaction=transaction).to_dict() or {}
            if data["status"] == REJECTED:
                return data
            if data["status"] != REQUESTED:
                raise CommandProblem(f"This request is already {data['status']}.")
            staged = self.audit.stage(transaction, moment, tenant_id=data.get("tenantId"))
            if _expired(data, moment):
                self._mark_expired(transaction, staged, reference, data)
                return {**data, "status": EXPIRED}
            fields = {"status": REJECTED, "decidedBy": actor, "decidedAt": moment, "rejectionReason": note}
            transaction.update(reference, fields)
            staged.add(actor=actor, action="approval.rejected", tenant_id=data.get("tenantId"),
                       key=f"reject:{data['approvalId']}", summary=data["summary"],
                       refs={"approvalId": data["approvalId"], "approvalAction": data["action"]})
            return {**data, **fields}

        result = write(self.client.transaction(max_attempts=10))
        if result["status"] == EXPIRED:
            raise CommandProblem("This request has expired.")
        return self.view(result, actor, role, person=person)

    @staticmethod
    def _mark_expired(transaction: firestore.Transaction, staged: Any, reference: Any,
                      data: Mapping[str, Any]) -> None:
        transaction.update(reference, {"status": EXPIRED})
        staged.add(actor="system", action="approval.expired", tenant_id=data.get("tenantId"),
                   key=f"expired:{data['approvalId']}", summary=data["summary"],
                   refs={"approvalId": data["approvalId"], "approvalAction": data["action"]})

    def approve(self, approval_id: str, actor: str, role: str, person: str | None = None) -> dict[str, Any]:
        if role not in DECIDE_ROLES:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner or an operator can decide.")
        actor = text(actor, "actor", 254)
        person = person or actor
        data = self._read(approval_id)
        handler = self.handlers[data["action"]]
        moment = self.clock()
        solo = self.solo_owner(actor)
        if data["status"] == REQUESTED:
            if self._new_package_from_someone_else(data):
                raise CommandProblem("Only the owner can ask for a new package. Reject this request and ask the "
                                     "owner to send it again.")
            if self._same_person(data, actor, person) and not solo:
                raise CommandProblem("Another person must approve this.")
            if not _expired(data, moment):
                handler.verify(data["params"], data.get("tenantId"),
                               {"reason": data["reason"], "approver": actor, "person": person, "solo": solo})
        reference = self.client.collection(APPROVALS).document(data["approvalId"])
        operation_id = operation_id_for(handler.operation, _operation_key(handler, data))

        @firestore.transactional
        def decide(transaction: firestore.Transaction) -> tuple[str, dict[str, Any]]:
            current = reference.get(transaction=transaction).to_dict() or {}
            solo = self.solo_owner(actor, transaction)
            state = current["status"]
            if state in (APPROVED, EXECUTED):
                return "run", current
            if state != REQUESTED:
                raise CommandProblem(f"This request is {state}.")
            own = self._same_person(current, actor, person)
            if own and not solo:
                raise CommandProblem("Another person must approve this.")
            existing = self.runner.reference(operation_id).get(transaction=transaction)
            staged = self.audit.stage(transaction, moment, tenant_id=current.get("tenantId"))
            if _expired(current, moment):
                self._mark_expired(transaction, staged, reference, current)
                return "expired", current
            fields = {"status": APPROVED, "decidedBy": actor, "decidedByPerson": person, "decidedAt": moment,
                      "operationId": operation_id, **({"soloApproval": True} if solo else {})}
            transaction.update(reference, fields)
            self.runner.stage_begin(transaction, staged, existing.to_dict() if existing.exists else None,
                                    **self._operation_fields(handler, {**current, **fields}))
            staged.add(actor=actor, action="approval.approved", tenant_id=current.get("tenantId"),
                       key=f"approve:{current['approvalId']}",
                       summary=f"Solo approval: {current['summary']}" if solo else current["summary"],
                       refs={"approvalId": current["approvalId"], "approvalAction": current["action"],
                             "operationId": operation_id, "soloApproval": "true" if solo else None})
            return "run", {**current, **fields}

        outcome, decided = decide(self.client.transaction(max_attempts=10))
        if outcome == "expired":
            raise CommandProblem("This request has expired. Send a new request.")
        return self._execute(decided, handler, actor, role, person)

    def retry(self, approval_id: str, actor: str, role: str, person: str | None = None) -> dict[str, Any]:
        if role not in DECIDE_ROLES:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner or an operator can decide.")
        data = self._settle_executed(self._read(approval_id))
        if data["status"] == EXECUTED:
            return {"approval": self.view(data, actor, role, person=person), "operation": self._outcome(data["operationId"])}
        if data["status"] == REJECTED:
            raise CommandProblem("This request was closed, so it cannot be tried again.")
        if data["status"] != APPROVED:
            raise CommandProblem("Only an approved request whose work did not finish can be tried again.")
        if self.runner.get(data["operationId"]) is not None:
            try:
                self.runner.reopen(data["operationId"], actor)
            except OperationError as error:
                raise CommandProblem(str(error)) from error
            except (Aborted, ValueError) as error:
                if not is_busy(error):
                    raise
                raise CommandProblem(BUSY) from error
        try:
            return self._execute(data, self.handlers[data["action"]], actor, role, person)
        except (Aborted, ValueError) as error:
            if not is_busy(error):
                raise
            raise CommandProblem(BUSY) from error

    def close(self, approval_id: str, actor: str, role: str, reason: Any,
              person: str | None = None) -> dict[str, Any]:
        if role not in DECIDE_ROLES:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner or an operator can decide.")
        note = text(reason, "reason", 500)
        if len(note) < 3:
            raise bad("Give a reason of 3 to 500 characters.")
        data = self._settle_executed(self._read(approval_id))
        if data["status"] != APPROVED:
            raise CommandProblem(f"This request is already {data['status']}.")
        reference = self.client.collection(APPROVALS).document(data["approvalId"])
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current["status"] != APPROVED:
                raise CommandProblem(f"This request is already {current['status']}.")
            snapshot = (self.runner.reference(current["operationId"]).get(transaction=transaction)
                        if current.get("operationId") else None)
            operation = snapshot.to_dict() if snapshot is not None and snapshot.exists else None
            problem = _closing_problem(operation, moment)
            if problem is not None:
                raise CommandProblem(problem)
            staged = self.audit.stage(transaction, moment, tenant_id=current.get("tenantId"))
            fields = {"status": REJECTED, "rejectionReason": f"Closed without finishing: {note}",
                      "closedBy": actor, "closedAt": moment}
            transaction.update(reference, fields)
            if operation is not None:
                self.runner.stage_close(transaction, operation, moment)
            staged.add(actor=actor, action="approval.closed", tenant_id=current.get("tenantId"),
                       key=f"closed:{current['approvalId']}",
                       summary=f"Closed without finishing. Reason: {note}. Request: {current['summary']}",
                       refs={"approvalId": current["approvalId"], "operationId": current.get("operationId"),
                             "reason": note, "closedBy": actor})
            return {**current, **fields}

        try:
            closed = commit_when_free(write, self.client)
        except (Aborted, ValueError) as error:
            if not is_busy(error):
                raise
            raise CommandProblem(BUSY) from error
        return self.view(closed, actor, role, person=person)

    def _operation_fields(self, handler: Handler, data: Mapping[str, Any]) -> dict[str, Any]:
        params, field_names = handler.execution(data)
        return {"idempotency_key": _operation_key(handler, data), "action": handler.operation, "actor": data["decidedBy"],
                "tenant_id": data.get("tenantId"), "reason": data["reason"], "ticket": params.get("ticket"),
                "field_names": field_names, "params": params,
                "step_names": [step.name for step in handler.steps()],
                "guard": {"collection": APPROVALS, "id": data["approvalId"], "status": APPROVED}}

    def _start_operation(self, data: Mapping[str, Any], handler: Handler) -> None:
        reference = self.client.collection(APPROVALS).document(data["approvalId"])
        operation_id = operation_id_for(handler.operation, _operation_key(handler, data))
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current["status"] != APPROVED:
                raise CommandProblem(f"This request is {current['status']}, so its work cannot start.")
            existing = self.runner.reference(operation_id).get(transaction=transaction)
            staged = self.audit.stage(transaction, moment, tenant_id=current.get("tenantId"))
            self.runner.stage_begin(transaction, staged, existing.to_dict() if existing.exists else None,
                                    **self._operation_fields(handler, current))

        write(self.client.transaction(max_attempts=10))

    def _execute(self, data: dict[str, Any], handler: Handler, actor: str, role: str,
                 person: str | None = None) -> dict[str, Any]:
        if data["status"] == EXECUTED:
            return {"approval": self.view(data, actor, role, person=person), "operation": self._outcome(data["operationId"])}
        steps = handler.steps()
        operation_id = operation_id_for(handler.operation, _operation_key(handler, data))
        if self.runner.get(operation_id) is None:
            self._start_operation(data, handler)
        try:
            self.runner.run(operation_id, steps)
        except RetryLater:
            if (self.runner.get(operation_id) or {}).get("closed"):
                raise CommandProblem("This request was closed before its work started.") from None
            return {"approval": self.view(self._read(data["approvalId"]), actor, role, person=person),
                    "operation": self._outcome(operation_id)}
        except Exception:
            pass
        record = self.runner.get(operation_id) or {}
        if record.get("status") == COMPLETED:
            settled = self._settle_executed(self._read(data["approvalId"]))
            return {"approval": self.view(settled, actor, role, person=person), "operation": self._outcome(operation_id)}
        if record.get("closed"):
            raise CommandProblem("This request was closed before its work started.")
        if record.get("status") == FAILED:
            error = record.get("error") or {}
            message = _failure_text(error.get("type"), error.get("message"))
            self.client.collection(APPROVALS).document(data["approvalId"]).update({"executionError": message})
            raise CommandProblem(message)
        return {"approval": self.view(data, actor, role, person=person), "operation": self._outcome(operation_id)}

    def _outcome(self, operation_id: str | None) -> dict[str, Any] | None:
        if operation_id is None:
            return None
        record = self.runner.get(operation_id) or {}
        return {"operationId": operation_id, "status": record.get("status"),
                "steps": {name: {"status": step.get("status"), "result": step.get("result")}
                          for name, step in (record.get("steps") or {}).items()}}

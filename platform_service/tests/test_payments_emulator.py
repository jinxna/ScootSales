


















from __future__ import annotations

import importlib
import json
import os
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service.commands import CommandProblem
from platform_service.ids import command_id
from platform_service.directory import DirectoryError, DirectoryStore
from platform_service.records import RecordError
from platform_service.invoices import InvoiceBook, NeedsManualDraft
from platform_service.mail import MailQueue
from platform_service.plans import PlanStore
from platform_service.signing import Keyring, Signer
from platform_service.tests.support import CHECKER, CLERK, issued_invoice, seed_subscription


pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Needs the assigned shared Firestore emulator.")

TENANT = "t_paymentone"
OTHER = "t_paymenttwo"
THIRD = "t_paymentthree"
ACTOR = CLERK
VOIDER = "owner@example.com"
NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)
AMOUNT = 10000


@pytest.fixture
def world():
    project = f"demo-v4-payment-{uuid.uuid4().hex[:12]}"
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    state = SimpleNamespace(db=db, now=NOW, project=project, invoices={})
    for tenant in (TENANT, OTHER):
        state.book, state.invoices[tenant] = issued_invoice(db, tenant, NOW)

    def ledger(mail_enabled=True):


        cls = importlib.import_module("platform_service.payments").PaymentLedger
        mail = importlib.import_module("platform_service.mail").MailQueue(db, clock=lambda: state.now, enabled=mail_enabled)
        return cls(db, clock=lambda: state.now, mail=mail)

    state.ledger = ledger
    yield state
    db.close()


INVOICE = {TENANT: command_id("inv", TENANT, "invoice-key-0001", "invoice.draft"),
           OTHER: command_id("inv", OTHER, "invoice-key-0001", "invoice.draft")}


def payment(tenant=TENANT, **changes):
    return {"amountMinor": AMOUNT, "currency": "MYR", "externalReference": "BANK/TRANSFER-001",
            "invoiceId": INVOICE[tenant], "receivedAt": "2026-10-29T09:00:00Z",
            "reason": "Manual bank confirmation", **changes}


def seed_company(world, tenant=TENANT, *, billing_email="billing@example.test", payload_tenant=None):
    envelope = {"payload": json.dumps({"tenantId": payload_tenant or tenant, "legalName": "Northwind Foods Sdn Bhd"})}
    if billing_email:
        envelope["billingEmail"] = billing_email
    world.db.collection("companies").document(tenant).set(envelope)


def stored(world, collection):
    return {s.id: s.to_dict() for s in world.db.collection(collection).stream()}


def test_record_is_immutable_safe_and_has_no_inferred_coverage(world):
    ledger = world.ledger()
    receipt = ledger.record(TENANT, "record-key-001", payment(), ACTOR)
    assert receipt == {"entryId": receipt["entryId"], "tenantId": TENANT, "type": "payment",
                       **payment(), "invoiceReference": "INV-2026-000001",
                       "periodStart": "2026-10-29T12:00:00Z", "periodEnd": "2026-11-29T12:00:00Z",
                       "createdBy": ACTOR, "createdAt": "2026-10-29T12:00:00Z", "revision": 1}
    assert "/" not in receipt["entryId"]
    assert len(stored(world, "payment_entries")) == 1
    assert len(stored(world, "payment_references")) == 1
    assert ledger.get_account(TENANT) == {"tenantId": TENANT, "revision": 1}
    assert ledger.list_entries(OTHER) == []
    assert ledger.list_entries(TENANT) == [receipt]
    assert {"payment_entries", "payment_references", "payment_accounts"} <= {c.id for c in world.db.collections()}
    assert "payment_checks" not in {c.id for c in world.db.collections()}






@pytest.mark.parametrize("same_tenant", [True])
def test_simultaneous_normalized_reference_has_one_winner(world, same_tenant):
    ledger = world.ledger()
    barrier = threading.Barrier(2)

    def submit(index):
        barrier.wait(timeout=10)
        try:
            return ledger.record(TENANT if same_tenant or index == 0 else OTHER,
                                 f"reference-race-{index}",
                                 payment(TENANT if same_tenant or index == 0 else OTHER,
                                         externalReference=" Bank/Straße " if index == 0 else "BANK/STRASSE"), ACTOR)
        except CommandProblem:
            return None

    with ThreadPoolExecutor(max_workers=2) as executor:
        replies = list(executor.map(submit, range(2)))
    assert sum(reply is not None for reply in replies) == 1
    assert len(stored(world, "payment_entries")) == 1
    assert len(stored(world, "payment_references")) == 1
    assert sum(row["revision"] for row in stored(world, "payment_accounts").values()) == 1


def test_same_key_concurrent_retries_commit_once(world):
    ledger = world.ledger()
    barrier = threading.Barrier(2)

    def submit(_):
        barrier.wait(timeout=10)
        return ledger.record(TENANT, "same-key-race-001", payment(), ACTOR)

    with ThreadPoolExecutor(max_workers=2) as executor:
        replies = list(executor.map(submit, range(2)))
    assert replies[0] == replies[1]
    assert ledger.get_account(TENANT)["revision"] == 1
    assert len(stored(world, "payment_entries")) == 1




@pytest.mark.parametrize("tenant,key", [("other", "valid-key-001"), ("t_bad/path", "valid-key-001"),
                                       (TENANT, "short"), (TENANT, "invalid/key"), (TENANT, "x" * 129)])
def test_invalid_tenant_or_key_cannot_be_a_document_path(world, tenant, key):
    ledger = world.ledger()
    with pytest.raises(HTTPException) as problem:
        ledger.record(tenant, key, payment(), ACTOR)
    assert problem.value.status_code == 400
    assert stored(world, "payment_entries") == {}






def test_fix047_same_reference_is_refused_in_one_company_and_accepted_in_another(world):
    ledger = world.ledger()
    ledger.record(TENANT, "held-key-001", payment(), ACTOR)
    with pytest.raises(CommandProblem):
        ledger.record(TENANT, "held-key-002", payment(), ACTOR)
    ledger.record(OTHER, "held-other-001", payment(OTHER), ACTOR)
    assert len(ledger.list_entries(OTHER)) == 1
    assert len(ledger.list_entries(TENANT)) == 1


def test_fix047_a_reference_claimed_before_the_upgrade_blocks_only_its_own_company(world):
    import hashlib
    old_id = "external_" + hashlib.sha256("bank/transfer-001".encode("utf-8")).hexdigest()
    world.db.collection("payment_references").document(old_id).set(
        {"type": "external", "tenantId": TENANT, "entryId": "pay_oldentry"})
    ledger = world.ledger()
    with pytest.raises(CommandProblem):
        ledger.record(TENANT, "held-key-003", payment(), ACTOR)
    ledger.record(OTHER, "held-other-002", payment(OTHER), ACTOR)
    assert len(ledger.list_entries(OTHER)) == 1


def test_concurrent_voids_append_exactly_one_correction_per_company(world):
    ledger = world.ledger()
    receipts = {tenant: ledger.record(tenant, "void-race-original",
                                      payment(tenant, externalReference=f"BANK/VOID-RACE-{tenant}"), ACTOR)
                for tenant in (TENANT, OTHER)}
    barrier = threading.Barrier(4)

    def correct(job):
        tenant, i = job
        barrier.wait(timeout=10)
        try:
            return ledger.correct(tenant, f"void-race-{i}", receipts[tenant]["entryId"],
                                  {"reason": "Correct invoice"}, VOIDER)
        except CommandProblem:
            return None

    jobs = [(tenant, i) for tenant in (TENANT, OTHER) for i in range(2)]
    with ThreadPoolExecutor(max_workers=4) as executor:
        results = dict(zip(jobs, executor.map(correct, jobs)))
    for tenant in (TENANT, OTHER):
        assert sum(results[(tenant, i)] is not None for i in range(2)) == 1
        assert len(ledger.list_entries(tenant)) == 2
        assert ledger.get_account(tenant)["revision"] == 2


def test_wrong_company_missing_receipt_and_correction_target_are_refused(world):
    ledger = world.ledger()
    receipt = ledger.record(TENANT, "target-original-001", payment(), ACTOR)
    with pytest.raises(CommandProblem):
        ledger.correct(OTHER, "wrong-company-001", receipt["entryId"], {"reason": "Wrong company"}, VOIDER)
    with pytest.raises(CommandProblem):
        ledger.correct(TENANT, "missing-receipt-001", "pay_" + "0" * 64, {"reason": "Missing"}, VOIDER)
    correction = ledger.correct(TENANT, "valid-correction-001", receipt["entryId"], {"reason": "Void"}, VOIDER)
    with pytest.raises(CommandProblem):
        ledger.correct(TENANT, "void-a-void-001", correction["entryId"], {"reason": "Void again"}, VOIDER)
    with pytest.raises(HTTPException):
        ledger.correct(TENANT, "path-injection-001", "payment_entries/receipt", {"reason": "Invalid path"}, VOIDER)
    assert ledger.get_account(TENANT)["revision"] == 2






def test_receipt_is_queued_only_after_the_check_and_once_even_when_retried(world):
    seed_company(world)
    ledger = world.ledger()
    receipt = ledger.record(TENANT, "receipt-mail-001", payment(), ACTOR)
    ledger.record(TENANT, "receipt-mail-001", payment(), ACTOR)
    assert stored(world, "mail_jobs") == {}
    check = ledger.check(TENANT, receipt["entryId"], CHECKER)
    ledger.check(TENANT, receipt["entryId"], CHECKER)
    jobs = stored(world, "mail_jobs")
    assert len(jobs) == 1
    job = next(iter(jobs.values()))
    assert job["kind"] == "receipt" and job["tenantId"] == TENANT and job["recipient"] == "billing@example.test"
    assert job["payload"] == {"tenantId": TENANT, "companyName": "Northwind Foods Sdn Bhd",
                              "invoiceReference": "INV-2026-000001", "receiptNumber": "RCT-2026-000001",
                              "amountMinor": AMOUNT, "currency": "MYR", "paidAt": "2026-10-29"}
    assert check["receiptNumber"] == "RCT-2026-000001"
    assert stored(world, "payment_entries")[receipt["entryId"]]["mail"] == {
        "status": "queued", "reason": None, "jobId": job["jobId"]}
    assert "mail" not in receipt




def test_company_record_for_another_tenant_never_receives_the_receipt(world):
    seed_company(world, payload_tenant=OTHER)
    ledger = world.ledger()
    receipt = ledger.record(TENANT, "receipt-mail-004", payment(), ACTOR)
    ledger.check(TENANT, receipt["entryId"], CHECKER)
    assert stored(world, "mail_jobs") == {}
    assert stored(world, "payment_entries")[receipt["entryId"]]["mail"]["status"] == "skipped"


def signed_directory(world):
    signer = Signer.generate("billing-test-key")
    return DirectoryStore(world.db, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer)


def company_record(**changes):
    return {"tenantId": TENANT, "workspace": "northwindfoods", "legalName": "Northwind Foods Sdn Bhd",
            "companyCode": "northwindfoods", "location": {"projectId": "northwind-prod", "databaseId": "(default)",
                                                          "authTenantId": None},
            "locationKind": "byo",
            "clientConfig": {"apiKey": "AIza" + "A" * 35, "appId": "1:222222222222:web:cccccccccccccccc",
                             "messagingSenderId": "222222222222"},
            "status": "active", "planRef": "standard", "releaseRing": "general", "rulesVersion": "r1", **changes}










def test_unchecked_payment_covers_seven_days_and_a_check_by_another_person_covers_the_invoice_period(world):
    ledger = world.ledger()
    receipt = ledger.record(TENANT, "cover-key-0001", payment(), ACTOR)
    unchecked = ledger.coverage(TENANT, NOW)
    assert unchecked.checked_end is None
    assert unchecked.unchecked_end == NOW + timedelta(days=7)
    assert unchecked.covering_entries == (receipt["entryId"],)
    assert ledger.coverage(TENANT, NOW + timedelta(days=7)).covering_entries == ()
    with pytest.raises(CommandProblem) as own:
        ledger.check(TENANT, receipt["entryId"], ACTOR)
    assert str(own.value) == "Another person must check this payment."
    assert stored(world, "payment_checks") == {}
    checked = ledger.check(TENANT, receipt["entryId"], CHECKER)
    assert checked["checkedBy"] == CHECKER and checked["receiptNumber"] == "RCT-2026-000001"
    after = ledger.coverage(TENANT, NOW + timedelta(days=20))
    assert after.checked_end == datetime(2026, 11, 29, 12, 0, tzinfo=timezone.utc)
    assert after.covering_entries == (receipt["entryId"],)
    invoice = world.book.get(INVOICE[TENANT])
    assert invoice["status"] == "paid" and invoice["paidMinor"] == AMOUNT and invoice["outstandingMinor"] == 0
    assert ledger.check(TENANT, receipt["entryId"], "third@example.test") == checked
    assert len(stored(world, "payment_checks")) == 1
    assert stored(world, "document_counters")["RCT-2026"]["last"] == 1
    snapshot = ledger.snapshot(TENANT)
    assert snapshot["entries"][0]["check"]["checkedBy"] == CHECKER


def test_an_invoice_with_a_payment_waiting_for_a_check_refuses_a_second_payment(world):
    ledger = world.ledger()
    first = ledger.record(TENANT, "double-key-0001", payment(), ACTOR)
    with pytest.raises(CommandProblem) as waiting:
        ledger.record(TENANT, "double-key-0002", payment(externalReference="BANK/TWICE"), ACTOR)
    assert "waiting to be checked" in str(waiting.value)
    assert [row["entryId"] for row in ledger.awaiting_check()] == [first["entryId"]]
    ledger.check(TENANT, first["entryId"], CHECKER)
    with pytest.raises(CommandProblem):
        ledger.record(TENANT, "double-key-0003", payment(externalReference="BANK/THRICE"), ACTOR)
    assert ledger.awaiting_check() == []


def test_a_voided_and_recorded_again_payment_gets_no_second_unchecked_cover(world):
    ledger = world.ledger()
    first = ledger.record(TENANT, "grace-key-0001", payment(), ACTOR)
    assert ledger.coverage(TENANT, NOW).covering_entries == (first["entryId"],)
    ledger.correct(TENANT, "grace-key-0002", first["entryId"], {"reason": "Wrong reference"}, VOIDER)
    assert ledger.coverage(TENANT, NOW).paid_until is None
    world.now = NOW + timedelta(days=3)
    again = ledger.record(TENANT, "grace-key-0003", payment(externalReference="BANK/AGAIN"), ACTOR)
    assert ledger.coverage(TENANT, world.now).covering_entries == ()
    assert ledger.coverage(TENANT, world.now).paid_until <= world.now
    ledger.check(TENANT, again["entryId"], CHECKER)
    assert ledger.coverage(TENANT, world.now).covering_entries == (again["entryId"],)




def test_void_needs_another_person_and_removes_cover_and_reopens_the_invoice(world):
    ledger = world.ledger()
    receipt = ledger.record(TENANT, "void-cover-0001", payment(), ACTOR)
    ledger.check(TENANT, receipt["entryId"], CHECKER)
    with pytest.raises(CommandProblem) as own:
        ledger.correct(TENANT, "void-cover-0002", receipt["entryId"], {"reason": "Wrong"}, ACTOR)
    assert str(own.value) == "Another person must void this payment."
    ledger.correct(TENANT, "void-cover-0003", receipt["entryId"], {"reason": "Wrong"}, VOIDER)
    assert ledger.coverage(TENANT, NOW).paid_until is None
    invoice = world.book.get(INVOICE[TENANT])
    assert invoice["status"] == "issued" and invoice["paidMinor"] == 0
    with pytest.raises(CommandProblem):
        ledger.check(TENANT, receipt["entryId"], CHECKER)
    assert ledger.awaiting_check() == []


def test_payment_needs_an_open_invoice_of_the_same_company_and_the_exact_balance(world):
    ledger = world.ledger()
    draft = world.book.create_draft(TENANT, "draft-key-0002", {"periodStart": "2026-11-29T12:00:00Z"}, ACTOR)
    for changes in ({"invoiceId": draft["invoiceId"]}, {"invoiceId": INVOICE[OTHER]}, {"amountMinor": AMOUNT - 1},
                    {"amountMinor": AMOUNT + 1}, {"invoiceId": "inv_" + "0" * 64}):
        with pytest.raises(CommandProblem):
            ledger.record(TENANT, "invoice-rule-0001", payment(**changes), ACTOR)
    assert stored(world, "payment_entries") == {}






def test_numbers_have_no_gaps_and_each_type_and_year_has_its_own_counter(world):
    book = world.book
    draft = book.create_draft(TENANT, "numbers-key-0001", {"periodStart": "2026-11-29T12:00:00Z"}, ACTOR)
    discarded = book.void_draft(draft["invoiceId"], ACTOR)
    assert discarded["status"] == "void" and discarded["number"] is None
    first = book.issue(book.create_draft(TENANT, "numbers-key-0002", {"periodStart": "2026-11-29T12:00:00Z"}, ACTOR)["invoiceId"], ACTOR)
    assert first["number"] == "INV-2026-000003"
    assert book.issue(first["invoiceId"], ACTOR) == first
    with pytest.raises(CommandProblem):
        book.issue(draft["invoiceId"], ACTOR)
    credit = book.credit_note(first["invoiceId"], "credit-key-0001", {"amountMinor": 100, "reason": "Goodwill"}, VOIDER)
    assert credit["number"] == "CN-2026-000001"
    later = InvoiceBook(world.db, PlanStore(world.db), clock=lambda: datetime(2027, 1, 2, tzinfo=timezone.utc),
                        mail=MailQueue(world.db, enabled=False))
    next_year = later.issue(later.create_draft(OTHER, "numbers-key-0003", {}, ACTOR)["invoiceId"], ACTOR)
    assert next_year["number"] == "INV-2027-000001"
    at_midnight = InvoiceBook(world.db, PlanStore(world.db),
                              clock=lambda: datetime(2026, 12, 31, 16, 30, tzinfo=timezone.utc),
                              mail=MailQueue(world.db, enabled=False))
    local_new_year = at_midnight.issue(at_midnight.create_draft(OTHER, "numbers-key-0004", {"periodStart": "2027-02-10T00:00:00Z"}, ACTOR)["invoiceId"], ACTOR)
    assert local_new_year["number"] == "INV-2027-000002"
    assert {key: row["last"] for key, row in stored(world, "document_counters").items()} == {
        "INV-2026": 3, "INV-2027": 2, "CN-2026": 1}


def test_credit_note_is_bound_to_the_outstanding_amount_of_its_invoice(world):
    book = world.book
    invoice = world.invoices[TENANT]
    with pytest.raises(CommandProblem):
        book.credit_note(invoice["invoiceId"], "credit-key-0001", {"amountMinor": AMOUNT + 1, "reason": "Too much"}, VOIDER)
    first = book.credit_note(invoice["invoiceId"], "credit-key-0002", {"amountMinor": 4000, "reason": "Discount"}, VOIDER)
    assert book.credit_note(invoice["invoiceId"], "credit-key-0002", {"amountMinor": 4000, "reason": "Discount"}, VOIDER) == first
    with pytest.raises(CommandProblem):
        book.credit_note(invoice["invoiceId"], "credit-key-0002", {"amountMinor": 4001, "reason": "Discount"}, VOIDER)
    with pytest.raises(CommandProblem):
        book.credit_note(invoice["invoiceId"], "credit-key-0003", {"amountMinor": 6001, "reason": "Too much"}, VOIDER)
    shown = book.get(invoice["invoiceId"])
    assert shown["outstandingMinor"] == 6000 and shown["creditedMinor"] == 4000
    assert [note["number"] for note in shown["creditNotes"]] == ["CN-2026-000001"]
    ledger = world.ledger()
    with pytest.raises(CommandProblem):
        ledger.record(TENANT, "credit-pay-0001", payment(), ACTOR)
    receipt = ledger.record(TENANT, "credit-pay-0002", payment(amountMinor=6000), ACTOR)
    ledger.check(TENANT, receipt["entryId"], CHECKER)
    with pytest.raises(CommandProblem):
        book.credit_note(invoice["invoiceId"], "credit-key-0004", {"amountMinor": 1, "reason": "Paid already"}, VOIDER)


def test_draft_amount_comes_from_the_package_and_an_issued_invoice_is_locked(world):
    book = world.book
    seed_subscription(world.db, THIRD, "P1", billingInterval="monthly")
    draft = book.create_draft(THIRD, "draft-key-0003", {"periodStart": "2026-11-29T12:00:00Z", "note": "  First  "}, ACTOR)
    assert draft["amountMinor"] == 10000 and draft["packageId"] == "P1" and draft["note"] == "First"
    assert draft["status"] == "draft" and draft["number"] is None and draft["currency"] == "MYR"
    assert book.create_draft(THIRD, "draft-key-0003", {"periodStart": "2026-11-29T12:00:00Z", "note": "  First  "}, ACTOR) == draft
    with pytest.raises(HTTPException):
        book.create_draft(THIRD, "draft-key-0004", {"amountMinor": 5}, ACTOR)
    assert draft["createdBy"] == ACTOR and "editedBy" not in draft
    edited = book.edit_draft(draft["invoiceId"], {"note": "Changed", "periodStart": "2026-11-15T00:00:00Z"}, CHECKER)
    assert edited["note"] == "Changed" and edited["periodStart"] == "2026-11-15T00:00:00Z"
    assert edited["periodEnd"] == "2026-12-15T00:00:00Z"
    assert edited["editedBy"] == CHECKER and edited["editedAt"] == "2026-10-29T12:00:00Z"
    for body in ({"amountMinor": 1}, {"status": "paid"}, {"periodEnd": "2026-12-31T00:00:00Z"}, {}):
        with pytest.raises(HTTPException):
            book.edit_draft(draft["invoiceId"], body, ACTOR)
    issued = book.issue(draft["invoiceId"], VOIDER)
    assert issued["status"] == "issued" and issued["issuedAt"] == "2026-10-29T12:00:00Z"
    assert issued["issuedBy"] == VOIDER and issued["createdBy"] == ACTOR and issued["editedBy"] == CHECKER
    with pytest.raises(CommandProblem):
        book.edit_draft(draft["invoiceId"], {"note": "Too late"}, ACTOR)
    with pytest.raises(CommandProblem):
        book.void_draft(draft["invoiceId"], ACTOR)
    assert stored(world, "invoices")[draft["invoiceId"]]["note"] == "Changed"
    discarded = book.void_draft(book.create_draft(OTHER, "draft-key-0005", {"periodStart": "2026-11-29T12:00:00Z"}, ACTOR)["invoiceId"], VOIDER)
    assert discarded["status"] == "void" and discarded["voidedBy"] == VOIDER
    assert discarded["voidedAt"] == "2026-10-29T12:00:00Z"


def plant_quote(world, tenant_id, amount, moment, interval="yearly", status="approved"):
    quote_id = f"quote_{uuid.uuid4().hex}"
    world.db.collection("quotes").document(quote_id).set({
        "quoteId": quote_id, "tenantId": tenant_id, "amountMinor": amount, "currency": "MYR",
        "billingInterval": interval, "status": status, "planId": "INTERNAL", "createdAt": moment})
    return quote_id


def test_a_package_priced_by_quote_uses_only_the_newest_approved_quote(world):
    seed_subscription(world.db, "t_quotecompany", "INTERNAL", billingInterval="yearly")
    with pytest.raises(NeedsManualDraft, match="Set a price for this package on the Packages page first"):
        world.book.create_draft("t_quotecompany", "quote-key-0001", {}, ACTOR)
    with pytest.raises(HTTPException):
        world.book.create_draft("t_quotecompany", "quote-key-0003", {"amountMinor": 1}, ACTOR)
    plant_quote(world, "t_quotecompany", 300000, NOW - timedelta(days=2), status="proposed")
    plant_quote(world, "t_quotecompany", 100000, NOW - timedelta(days=2), interval="monthly")
    with pytest.raises(NeedsManualDraft):
        world.book.create_draft("t_quotecompany", "quote-key-0004", {}, ACTOR)
    plant_quote(world, "t_quotecompany", 200000, NOW - timedelta(days=2))
    newest = plant_quote(world, "t_quotecompany", 250000, NOW - timedelta(days=1))
    quote = world.book.create_draft("t_quotecompany", "quote-key-0002", {}, ACTOR)
    assert quote["amountMinor"] == 250000 and quote["periodEnd"] == "2027-10-29T12:00:00Z"
    assert quote["quoteId"] == newest

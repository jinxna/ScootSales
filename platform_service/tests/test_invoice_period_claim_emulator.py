from __future__ import annotations

import os
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service.commands import CommandProblem
from platform_service.invoices import (
    PERIOD_CLAIMS, SAME_PERIOD_REFUSAL, InvoiceBook, issued_period_refusal, period_claim_id)
from platform_service.mail import MailQueue
from platform_service.plans import PlanStore
from platform_service.scheduler import INVOICE_EXISTS_FOR_PERIOD
from platform_service.signing import format_timestamp, parse_timestamp
from platform_service.tests.support import CLERK, seed_subscription

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Needs the assigned shared Firestore emulator.")

NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)
ONE = "t_claimone"
TWO = "t_claimtwo"
FIRST_DAY = "2026-11-01T00:00:00Z"
OWNER = "owner@example.test"


@pytest.fixture
def world():
    db = firestore.Client(project=f"demo-v4-claim-{uuid.uuid4().hex[:12]}", credentials=AnonymousCredentials())
    for tenant in (ONE, TWO):
        seed_subscription(db, tenant, "P1", billingInterval="monthly")
    book = InvoiceBook(db, PlanStore(db), clock=lambda: NOW, mail=MailQueue(db, clock=lambda: NOW, enabled=False))
    yield book
    db.close()


def invoices_of(book, tenant, status=None):
    return [row for row in book.list_invoices(tenant) if status is None or row["status"] == status]


def claim_document(book, tenant, day):
    return book.client.collection(PERIOD_CLAIMS).document(period_claim_id(tenant, parse_timestamp(day))).get()


def test_two_staff_creating_one_period_at_once_make_one_invoice(world):
    def create(index):
        return world.create_draft(ONE, f"staff-key-{index:04d}", {"periodStart": FIRST_DAY}, CLERK)["invoiceId"]

    with ThreadPoolExecutor(max_workers=2) as pool:
        ids = list(pool.map(create, range(2)))
    assert len(set(ids)) == 1
    assert len(invoices_of(world, ONE)) == 1
    assert claim_document(world, ONE, FIRST_DAY).exists


def test_the_scheduler_call_and_a_manual_create_give_one_invoice(world):
    manual = world.create_draft(ONE, "manual-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    renewal = world.create_draft(ONE, "renewal-20261101", {"periodStart": FIRST_DAY}, "scheduler")
    assert renewal["invoiceId"] == manual["invoiceId"]
    assert len(invoices_of(world, ONE)) == 1
    scheduled = world.create_draft(TWO, "renewal-20261101", {"periodStart": FIRST_DAY}, "scheduler")
    later_manual = world.create_draft(TWO, "manual-key-0002", {"periodStart": FIRST_DAY}, CLERK)
    assert later_manual["invoiceId"] == scheduled["invoiceId"] and len(invoices_of(world, TWO)) == 1


def test_empty_starts_a_few_milliseconds_apart_on_one_day_give_one_invoice(world):
    ticks = iter(NOW + timedelta(seconds=7 * step) for step in range(100))
    world.clock = lambda: next(ticks)
    first = world.create_draft(ONE, "empty-key-0001", {}, CLERK)
    second = world.create_draft(ONE, "empty-key-0002", {}, CLERK)
    assert second["invoiceId"] == first["invoiceId"] and second["existing"] is True
    assert "existing" not in first
    assert len(invoices_of(world, ONE)) == 1


def test_a_period_with_an_issued_invoice_is_refused_with_its_number(world):
    first = world.create_draft(ONE, "issued-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    issued = world.issue(first["invoiceId"], CLERK)
    with pytest.raises(CommandProblem) as refusal:
        world.create_draft(ONE, "issued-key-0002", {"periodStart": "2026-11-01T09:00:00Z"}, CLERK)
    assert str(refusal.value) == issued_period_refusal(issued["number"])
    assert len(invoices_of(world, ONE)) == 1


def test_a_different_amount_for_the_same_day_is_refused_as_an_overlap(world):
    first = world.create_draft(ONE, "amount-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    world.client.collection("invoices").document(first["invoiceId"]).update({"amountMinor": first["amountMinor"] + 100})
    with pytest.raises(CommandProblem, match=INVOICE_EXISTS_FOR_PERIOD):
        world.create_draft(ONE, "amount-key-0002", {"periodStart": FIRST_DAY}, CLERK)
    assert len(invoices_of(world, ONE)) == 1


def test_the_kuching_calendar_date_decides_the_period(world):
    first = world.create_draft(ONE, "day-key-0001", {"periodStart": "2026-11-01T17:00:00Z"}, CLERK)
    same_kuching_day = world.create_draft(ONE, "day-key-0002", {"periodStart": "2026-11-01T17:30:00Z"}, CLERK)
    assert same_kuching_day["invoiceId"] == first["invoiceId"] and same_kuching_day["existing"] is True
    with pytest.raises(CommandProblem, match=INVOICE_EXISTS_FOR_PERIOD):
        world.create_draft(ONE, "day-key-0003", {"periodStart": "2026-11-01T15:59:00Z"}, CLERK)
    assert len(invoices_of(world, ONE)) == 1


def test_editing_a_draft_onto_a_claimed_day_is_refused_and_the_claim_moves(world):
    world.create_draft(ONE, "edit-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    second = world.create_draft(ONE, "edit-key-0002", {"periodStart": "2026-12-01T00:00:00Z"}, CLERK)
    with pytest.raises(CommandProblem, match=SAME_PERIOD_REFUSAL):
        world.edit_draft(second["invoiceId"], {"periodStart": FIRST_DAY}, CLERK)
    moved = world.edit_draft(second["invoiceId"], {"periodStart": "2026-12-20T00:00:00Z"}, CLERK)
    assert moved["periodStart"] == "2026-12-20T00:00:00Z"
    assert not claim_document(world, ONE, "2026-12-01T00:00:00Z").exists
    assert claim_document(world, ONE, "2026-12-20T00:00:00Z").to_dict()["invoiceId"] == second["invoiceId"]


def test_a_void_frees_the_claim_so_a_corrected_invoice_can_be_made(world):
    first = world.create_draft(ONE, "void-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    world.void_draft(first["invoiceId"], OWNER)
    assert not claim_document(world, ONE, FIRST_DAY).exists
    corrected = world.create_draft(ONE, "void-key-0002", {"periodStart": FIRST_DAY}, CLERK)
    assert corrected["invoiceId"] != first["invoiceId"]
    assert claim_document(world, ONE, FIRST_DAY).to_dict()["invoiceId"] == corrected["invoiceId"]
    again = world.create_draft(ONE, "void-key-0003", {"periodStart": FIRST_DAY}, CLERK)
    assert again["invoiceId"] == corrected["invoiceId"]
    assert len(invoices_of(world, ONE, "draft")) == 1


def test_another_company_with_the_same_period_is_not_affected(world):
    one = world.create_draft(ONE, "company-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    two = world.create_draft(TWO, "company-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    assert one["invoiceId"] != two["invoiceId"] and one["tenantId"] == ONE and two["tenantId"] == TWO
    assert len(invoices_of(world, ONE)) == 1 and len(invoices_of(world, TWO)) == 1


def quote_row(book, tenant, interval, plan_id=None):
    book.client.collection("quotes").document(f"q-{tenant}-{interval}").set({
        "quoteId": f"q-{tenant}-{interval}", "tenantId": tenant, "amountMinor": 500000, "currency": "MYR",
        "billingInterval": interval, "planId": plan_id, "status": "approved", "createdAt": NOW})


def test_a_quote_for_the_other_billing_period_does_not_price_the_invoice(world):
    seed_subscription(world.client, "t_quoted", "TRIAL", billingInterval="yearly")
    quote_row(world, "t_quoted", "monthly", "TRIAL")
    with pytest.raises(CommandProblem, match="no price yet"):
        world.create_draft("t_quoted", "quote-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    quote_row(world, "t_quoted", "yearly", "TRIAL")
    draft = world.create_draft("t_quoted", "quote-key-0002", {"periodStart": FIRST_DAY}, CLERK)
    assert invoices_of(world, "t_quoted")[0]["amountMinor"] == 500000
    assert draft["invoiceId"]


def test_t9a_a_start_inside_an_earlier_period_is_refused(world):
    world.create_draft(ONE, "t9a-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    with pytest.raises(CommandProblem, match=INVOICE_EXISTS_FOR_PERIOD):
        world.create_draft(ONE, "t9a-key-0002", {"periodStart": "2026-11-15T00:00:00Z"}, CLERK)
    assert len(invoices_of(world, ONE)) == 1


def test_t9d_a_period_that_starts_where_the_last_one_ends_is_allowed(world):
    first = world.create_draft(ONE, "t9d-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    second = world.create_draft(ONE, "t9d-key-0002", {"periodStart": first["periodEnd"]}, CLERK)
    assert second["invoiceId"] != first["invoiceId"] and len(invoices_of(world, ONE)) == 2


def test_t9d2_a_date_picker_start_on_the_end_day_of_a_default_start_invoice_is_allowed(world):
    first = world.create_draft(ONE, "t9d2-key-0001", {}, CLERK)
    end_day = parse_timestamp(first["periodEnd"]).astimezone(timezone(timedelta(hours=8))).date()
    picker = format_timestamp(datetime.fromisoformat(f"{end_day.isoformat()}T00:00:00+08:00"))
    second = world.create_draft(ONE, "t9d2-key-0002", {"periodStart": picker}, CLERK)
    assert second["invoiceId"] != first["invoiceId"] and len(invoices_of(world, ONE)) == 2


def test_t9f_a_voided_period_can_be_made_again(world):
    first = world.create_draft(ONE, "t9f-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    world.void_draft(first["invoiceId"], CLERK)
    again = world.create_draft(ONE, "t9f-key-0002", {"periodStart": "2026-11-10T00:00:00Z"}, CLERK)
    assert again["invoiceId"] != first["invoiceId"]


def test_t9g_moving_a_draft_into_a_taken_period_is_refused_and_an_unchanged_start_still_saves(world):
    world.create_draft(ONE, "t9g-key-0001", {"periodStart": FIRST_DAY}, CLERK)
    second = world.create_draft(ONE, "t9g-key-0002", {"periodStart": "2026-12-20T00:00:00Z"}, CLERK)
    with pytest.raises(CommandProblem, match=SAME_PERIOD_REFUSAL):
        world.edit_draft(second["invoiceId"], {"periodStart": "2026-11-20T00:00:00Z"}, CLERK)
    assert world.get(second["invoiceId"])["periodStart"] == "2026-12-20T00:00:00Z"
    assert claim_document(world, ONE, "2026-12-20T00:00:00Z").exists
    saved = world.edit_draft(second["invoiceId"], {"periodStart": "2026-12-20T00:00:00Z", "note": "kept"}, CLERK)
    assert saved["periodStart"] == "2026-12-20T00:00:00Z"

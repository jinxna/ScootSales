from __future__ import annotations

import os
import threading
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from firebase_admin import auth as admin_auth

from platform_service.company_access import CompanyUnreachable, company_access, require_active_admin
from platform_service.lifecycle import LifecycleConflict, LifecycleService, LifecycleStore, TenantLifecycle
from platform_service.operations import OperationContext, OperationStore, RetryLater
from platform_service.payments import PaymentLedger
from platform_service.tests import support


pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)


@pytest.fixture
def world():
    project = f"demo-v4-lifecycle-{uuid.uuid4().hex[:12]}"
    access = company_access(
        {"projectId": project, "databaseId": "(default)", "authTenantId": None}
    )
    for uid, role, reasons in (
        ("admin-1", "admin", []),
        ("sales-1", "salesman", []),
        ("sales-2", "salesman", ["admin_suspension"]),
    ):
        access.auth.create_user(
            uid=uid,
            email=f"{uid}@example.test",
            disabled=bool(reasons),
        )
        row = {
            "accessVersion": 2,
            "uid": uid,
            "userDocId": uid.upper(),
            "role": role,
            "status": "active",
            "isActive": True,
            "invitationState": "redeemed",
            "disabledReasons": reasons,
        }
        access.db.collection("user_access").document(uid).set(row)
        access.db.collection("users").document(uid.upper()).set(row)
    service = TenantLifecycle(access)
    service.project(
        {
            "tenantId": "t_lifecycleone",
            "state": "suspended",
            "revision": 1,
            "stateSince": datetime(2026, 10, 29, tzinfo=timezone.utc),
            "graceEndsAt": None,
            "windowEndsAt": datetime(2026, 11, 1, tzinfo=timezone.utc),
            "retentionEndsAt": datetime(2026, 11, 28, tzinfo=timezone.utc),
        }
    )
    return access, service


def reasons(access, uid):
    return (
        access.db.collection("user_access").document(uid).get().to_dict() or {}
    ).get("disabledReasons")


def covered_payment(access, now, key="lifecycle-payment-001", started_days_ago=1):
    return support.covered_payment(access.db, "t_lifecycleone", now, key, started_days_ago=started_days_ago)


def test_old_lapse_job_cannot_disable_after_newer_activation(world):
    access, service = world
    reason_added = threading.Event()
    release = threading.Event()
    failure = []

    def paused():
        reason_added.set()
        if not release.wait(timeout=10):
            raise RuntimeError("The lifecycle race was not released.")

    def old_job():
        try:
            service.lapse(1, "billing_lapse", after_reason=paused)
        except Exception as error:
            failure.append(error)

    thread = threading.Thread(target=old_job)
    thread.start()
    assert reason_added.wait(timeout=10)
    assert reasons(access, "sales-1") == ["billing_lapse"]

    service.project(
        {
            "tenantId": "t_lifecycleone",
            "state": "active",
            "revision": 2,
            "stateSince": datetime(2026, 10, 30, tzinfo=timezone.utc),
            "graceEndsAt": None,
            "windowEndsAt": None,
            "retentionEndsAt": None,
        }
    )
    assert service.recover(2) == ["sales-1"]
    assert reasons(access, "sales-1") == []
    assert access.auth.get_user("sales-1").disabled is False

    release.set()
    thread.join(timeout=10)
    assert not thread.is_alive()
    assert failure == []
    assert reasons(access, "sales-1") == []
    assert access.auth.get_user("sales-1").disabled is False
    assert reasons(access, "sales-2") == ["admin_suspension"]
    assert access.auth.get_user("sales-2").disabled is True


def covered_payment_for(access, tenant_id, now, key):
    return support.covered_payment(access.db, tenant_id, now, key)["entryId"]


def project_platform_state(access, tenant, tenant_id="t_lifecycleone"):
    snapshot = access.db.collection("lifecycle").document(tenant_id).get()
    return tenant.project(LifecycleStore.projection(snapshot.to_dict()))


def test_fix267_stale_reactivation_cannot_remove_reasons_after_a_newer_suspension(world):
    access, service = world
    service.lapse(1, "billing_lapse")
    service.project(
        {
            "tenantId": "t_lifecycleone",
            "state": "active",
            "revision": 2,
            "stateSince": datetime(2026, 10, 30, tzinfo=timezone.utc),
            "graceEndsAt": None,
            "windowEndsAt": None,
            "retentionEndsAt": None,
        }
    )
    service.project(
        {
            "tenantId": "t_lifecycleone",
            "state": "suspended",
            "revision": 3,
            "stateSince": datetime(2026, 10, 31, tzinfo=timezone.utc),
            "graceEndsAt": None,
            "windowEndsAt": datetime(2026, 11, 3, tzinfo=timezone.utc),
            "retentionEndsAt": datetime(2026, 11, 30, tzinfo=timezone.utc),
        }
    )
    assert service.recover(2) == []
    assert reasons(access, "sales-1") == ["billing_lapse"]
    assert reasons(access, "admin-1") == ["lifecycle_readonly"]


def test_fix270_past_due_removes_lapse_reasons_left_by_a_skipped_reactivation(world):
    access, service = world
    service.lapse(1, "billing_lapse")
    service.project(
        {
            "tenantId": "t_lifecycleone",
            "state": "past_due",
            "revision": 3,
            "stateSince": datetime(2026, 10, 31, tzinfo=timezone.utc),
            "graceEndsAt": datetime(2026, 11, 7, tzinfo=timezone.utc),
            "windowEndsAt": None,
            "retentionEndsAt": None,
        }
    )
    service.enforce("past_due", 3, datetime(2026, 10, 31, tzinfo=timezone.utc))
    assert reasons(access, "sales-1") == []
    assert access.auth.get_user("sales-1").disabled is False
    assert reasons(access, "sales-2") == ["admin_suspension"]


def test_fix271_reconcile_repairs_a_suspension_that_failed_after_an_older_stamp(world):
    access, _ = world
    other = company_access(
        {"projectId": f"demo-v4-lifecycle-{uuid.uuid4().hex[:12]}", "databaseId": "(default)", "authTenantId": None}
    )
    other.auth.create_user(uid="other-sales", email="other-sales@example.test")
    other.db.collection("user_access").document("other-sales").set(
        {"accessVersion": 2, "uid": "other-sales", "role": "salesman", "status": "active",
         "isActive": True, "invitationState": "redeemed", "disabledReasons": []})
    access.db.collection("config").document("lifecycle").delete()
    now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
    store = LifecycleStore(access.db)
    run = suspend_service(access, now)
    receipt = covered_payment(access, now, "fix271-pay-1")["entryId"]
    run("active", "fix271-open-one", 0, receipt)
    run("suspended", "fix271-suspend-one", 1)
    assert stamp(access)["access"] == "readonly"
    assert reasons(access, "sales-1") == ["billing_lapse"]

    tenant = TenantLifecycle(access)
    store.transition("t_lifecycleone", "active", operation_id="fix271-open-two", actor="owner@example.test",
                     reason="Paid", ticket=None, now=now, expected_revision=2,
                     activation_receipt_id=receipt)
    project_platform_state(access, tenant)
    tenant.recover(3)
    store.transition("t_lifecycleone", "suspended", operation_id="fix271-suspend-two", actor="owner@example.test",
                     reason="Lapsed", ticket=None, now=now, expected_revision=3)
    project_platform_state(access, tenant)
    assert tenant.stamp_access(3, now) is None
    assert stamp(access)["state"] == "suspended" and stamp(access)["access"] == "readonly"
    assert reasons(access, "sales-1") == []

    store.transition("t_lifecycletwo", "active", operation_id="fix271-other-open", actor="owner@example.test",
                     reason="Paid", ticket=None, now=now,
                     activation_receipt_id=covered_payment_for(access, "t_lifecycletwo", now, "fix271-pay-other"))
    other_tenant = TenantLifecycle(other)
    project_platform_state(access, other_tenant, "t_lifecycletwo")
    other_tenant.enforce("active", 1, now)
    other_before = other.db.collection("config").document("lifecycle").get().to_dict()

    accounts = {"t_lifecycleone": access, "t_lifecycletwo": other}
    reconciled = LifecycleService(
        access.db, OperationStore(access.db), SimpleNamespace(get=lambda tenant_id: {"location": {"tenant": tenant_id}}),
        store, access_for=lambda location: accounts[location["tenant"]],
        clock=lambda: now + timedelta(minutes=1),
    ).reconcile_projections()
    assert reconciled == {"reconciled": ["t_lifecycleone"], "failed": []}
    assert reasons(access, "sales-1") == ["billing_lapse"]
    assert other.db.collection("config").document("lifecycle").get().to_dict() == other_before
    assert (other.db.collection("user_access").document("other-sales").get().to_dict() or {}).get(
        "disabledReasons") == []


def test_stale_lapse_and_non_monotonic_projection_change_nothing(world):
    access, service = world
    service.project(
        {
            "tenantId": "t_lifecycleone",
            "state": "active",
            "revision": 2,
            "stateSince": datetime(2026, 10, 30, tzinfo=timezone.utc),
            "graceEndsAt": None,
            "windowEndsAt": None,
            "retentionEndsAt": None,
        }
    )
    assert service.lapse(1, "billing_lapse") == []
    assert reasons(access, "sales-1") == []
    assert access.auth.get_user("sales-1").disabled is False
    with pytest.raises(LifecycleConflict):
        service.project(
            {
                "tenantId": "t_lifecycleone",
                "state": "suspended",
                "revision": 1,
                "stateSince": datetime(2026, 10, 29, tzinfo=timezone.utc),
                "graceEndsAt": None,
                "windowEndsAt": None,
                "retentionEndsAt": None,
            }
        )






def test_fix034_an_ended_company_keeps_its_data_ninety_days_for_every_company(world):
    access, _ = world
    store = LifecycleStore(access.db)
    now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
    for tenant in ("t_lifecycleone", "t_lifecycletwo"):
        payment = support.covered_payment(access.db, tenant, now, f"retention-{tenant}")
        store.transition(tenant, "active", operation_id=f"retention-on-{tenant}", actor="owner@example.test",
                         reason="Paid", ticket=None, now=now, activation_receipt_id=payment["entryId"])
        ended = store.transition(tenant, "cancelled", operation_id=f"retention-off-{tenant}",
                                 actor="owner@example.test", reason="Contract ended", ticket=None, now=now)
        assert ended["retentionEndsAt"] == now + timedelta(days=90)


def test_stale_expected_lifecycle_revision_writes_nothing(world):
    access, _ = world
    store = LifecycleStore(access.db)
    now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
    payment = covered_payment(access, now, "lifecycle-payment-002")
    first = store.transition(
        "t_lifecycleone",
        "active",
        operation_id="lifecycle-first-001",
        actor="owner@example.test",
        reason="Initial activation",
        ticket=None,
        now=now,
        activation_receipt_id=payment["entryId"],
    )
    with pytest.raises(LifecycleConflict):
        store.transition(
            "t_lifecycleone",
            "past_due",
            operation_id="lifecycle-stale-001",
            actor="scheduler",
            reason="Stale scheduler",
            ticket=None,
            now=now + timedelta(days=1),
            expected_revision=0,
        )
    assert store.get("t_lifecycleone") == first


def test_active_lifecycle_requires_current_explicit_unvoided_coverage(world):
    access, _ = world
    now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
    store = LifecycleStore(access.db)
    ledger = PaymentLedger(access.db, clock=lambda: now)
    without_coverage = support.covered_payment(
        access.db, "t_lifecycleone", now - timedelta(days=40), "lifecycle-payment-none")
    voided = covered_payment(access, now, "lifecycle-payment-voided")
    ledger.correct(
        "t_lifecycleone",
        "lifecycle-void-command",
        voided["entryId"],
        {"reason": "Cancelled"},
        "second-person@example.test",
    )
    for receipt in (None, without_coverage["entryId"], voided["entryId"]):
        with pytest.raises(LifecycleConflict):
            store.transition(
                "t_lifecycleone",
                "active",
                operation_id="lifecycle-rejected-" + (receipt or "missing")[-8:],
                actor="owner@example.test",
                reason="Invalid activation",
                ticket=None,
                now=now,
                activation_receipt_id=receipt,
            )
    assert store.get("t_lifecycleone") is None










def seed_legacy(access):
    rows = access.db.collection("user_access")
    users = access.db.collection("users")
    rows.document("leg-linked").set({"uid": "leg-linked", "userDocId": "LEG1", "isActive": "true", "status": "Active"})
    users.document("LEG1").set({
        "uid": "leg-linked", "role": "Sales Representative", "status": "active", "isActive": True,
        "branch_id": "B1", "salesman_code": "LEG1"})
    rows.document("leg-plain").set({
        "uid": "leg-plain", "role": "Administrator", "status": "Active", "isActive": True,
        "branch_id": "B1", "staffId": "ADM1"})
    rows.document("leg-inactive").set({
        "uid": "leg-inactive", "role": "salesman", "status": "suspended", "isActive": False, "employeeCode": "IN1"})
    rows.document("leg-broken").set({
        "uid": "leg-broken", "userDocId": "MISSING", "role": "salesman", "status": "active"})
    rows.document("leg-mismatch").set({
        "uid": "someone-else", "role": "salesman", "status": "active", "employeeCode": "MM1"})
    rows.document("leg-future").set({
        "accessVersion": 3, "uid": "leg-future", "role": "salesman", "status": "active"})
    rows.document("leg-unknown").set({
        "uid": "leg-unknown", "role": "janitor", "status": "active", "employeeCode": "JJ1"})


def row(access, uid):
    return access.db.collection("user_access").document(uid).get().to_dict() or {}














def suspend_service(access, now):
    store = LifecycleStore(access.db)
    service = LifecycleService(
        access.db, OperationStore(access.db), SimpleNamespace(get=lambda _: {"location": {}}), store,
        access_for=lambda _: access, clock=lambda: now)
    project = service.transition_steps()[1]

    def run(state, operation_id, revision, receipt=None):
        store.transition("t_lifecycleone", state, operation_id=operation_id, actor="owner@example.test",
                         reason=f"Move to {state}", ticket=None, now=now, expected_revision=revision,
                         activation_receipt_id=receipt)
        project.apply(OperationContext(operation_id=operation_id, tenant_id="t_lifecycleone",
                                       params={"tenantId": "t_lifecycleone"}, results={}))

    return run


def stamp(access):
    return access.db.collection("config").document("lifecycle").get().to_dict() or {}


def seed_sessions(access, now):
    live = access.db.collection("live_tracking")
    live.document("sales-1").set({"uid": "sales-1", "activeSessionId": "a" * 32, "activeSessionGeneration": 4,
                                  "workSessionStatus": "active", "status": "active",
                                  "workSessionStartedAt": now - timedelta(hours=2)})
    live.document("sales-2").set({"uid": "sales-2", "activeSessionId": "b" * 32, "activeSessionGeneration": 1,
                                  "workSessionStatus": "ended", "status": "inactive",
                                  "workSessionStartedAt": now - timedelta(hours=5)})


def test_suspension_enforces_then_ends_sessions_then_stamps_the_cut_and_reactivation_reopens(world):
    access, _ = world
    access.db.collection("config").document("lifecycle").delete()
    now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
    run = suspend_service(access, now)
    payment = covered_payment(access, now, "lifecycle-cut-payment")
    run("active", "lifecycle-cut-start", 0, payment["entryId"])
    assert stamp(access)["access"] == "open"
    assert "cutAt" not in stamp(access)
    seed_sessions(access, now)

    run("suspended", "lifecycle-cut-suspend", 1)
    cut = stamp(access)
    assert (cut["state"], cut["access"]) == ("suspended", "readonly")
    assert cut["cutAt"] == now and cut["drainUntil"] == now + timedelta(hours=24)
    assert reasons(access, "sales-1") == ["billing_lapse"]
    assert access.auth.get_user("sales-1").disabled is False
    ended = access.db.collection("live_tracking").document("sales-1").get().to_dict()
    assert (ended["workSessionStatus"], ended["status"], ended["endedReason"]) == ("ended", "inactive", "company_paused")
    assert ended["activeSessionId"] == "a" * 32
    held = access.db.collection("held_work_sessions")
    assert held.document("sales-1_" + "a" * 32).get().to_dict()["serverStartedAt"] == now - timedelta(hours=2)
    assert held.document("sales-2_" + "b" * 32).get().to_dict()["serverStartedAt"] == now - timedelta(hours=5)
    assert TenantLifecycle(access).current()["state"] == "suspended"

    run("active", "lifecycle-cut-reopen", 2, payment["entryId"])
    reopened = stamp(access)
    assert reopened["access"] == "open" and reopened["reactivatedAt"] == now
    assert reopened["cutAt"] == now and reopened["drainUntil"] == now + timedelta(hours=24)
    assert reasons(access, "sales-1") == []


def test_unreachable_company_during_enforcement_stamps_nothing_until_a_retry_lands(world, monkeypatch):
    access, _ = world
    access.db.collection("config").document("lifecycle").delete()
    now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
    run = suspend_service(access, now)
    payment = covered_payment(access, now, "lifecycle-unreachable-payment")
    run("active", "lifecycle-unreachable-start", 0, payment["entryId"])
    seed_sessions(access, now)
    original = TenantLifecycle.end_work_sessions

    def unreachable(self, revision):
        raise CompanyUnreachable("down")

    monkeypatch.setattr(TenantLifecycle, "end_work_sessions", unreachable)
    with pytest.raises(RetryLater):
        run("suspended", "lifecycle-unreachable-suspend", 1)
    pending = stamp(access)
    assert pending["state"] == "suspended" and pending["access"] == "open" and "cutAt" not in pending
    assert reasons(access, "sales-1") == ["billing_lapse"]

    monkeypatch.setattr(TenantLifecycle, "end_work_sessions", original)
    monkeypatch.setenv("PLATFORM_HELD_WORK_DRAIN_SECONDS", "120")
    LifecycleService(
        access.db, OperationStore(access.db), SimpleNamespace(get=lambda _: {"location": {}}),
        LifecycleStore(access.db), access_for=lambda _: access, clock=lambda: now + timedelta(minutes=1),
    ).transition_steps()[1].apply(OperationContext(
        operation_id="lifecycle-unreachable-suspend", tenant_id="t_lifecycleone",
        params={"tenantId": "t_lifecycleone"}, results={}))
    landed = stamp(access)
    assert landed["access"] == "readonly"
    assert landed["cutAt"] == now + timedelta(minutes=1)
    assert landed["drainUntil"] == now + timedelta(minutes=3)
    assert access.db.collection("live_tracking").document("sales-1").get().to_dict()["workSessionStatus"] == "ended"


def test_reconcile_finishes_a_suspension_whose_status_was_saved_but_whose_enforcement_never_ran(world, monkeypatch):
    access, _ = world
    access.db.collection("config").document("lifecycle").delete()
    now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
    run = suspend_service(access, now)
    payment = covered_payment(access, now, "lifecycle-reconcile-payment")
    run("active", "lifecycle-reconcile-start", 0, payment["entryId"])
    seed_sessions(access, now)
    original = TenantLifecycle.enforce

    def unreachable(self, state, revision, moment, reason=None):
        raise CompanyUnreachable("down")

    monkeypatch.setattr(TenantLifecycle, "enforce", unreachable)
    with pytest.raises(RetryLater):
        run("suspended", "lifecycle-reconcile-suspend", 1)
    assert stamp(access)["state"] == "suspended" and stamp(access)["access"] == "open"
    assert reasons(access, "sales-1") == []

    monkeypatch.setattr(TenantLifecycle, "enforce", original)
    reconciled = LifecycleService(
        access.db, OperationStore(access.db), SimpleNamespace(get=lambda _: {"location": {}}),
        LifecycleStore(access.db), access_for=lambda _: access, clock=lambda: now + timedelta(minutes=1),
    ).reconcile_projections()
    assert reconciled == {"reconciled": ["t_lifecycleone"], "failed": []}
    assert stamp(access)["access"] == "readonly"
    assert reasons(access, "sales-1") == ["billing_lapse"]
    assert access.db.collection("live_tracking").document("sales-1").get().to_dict()["workSessionStatus"] == "ended"

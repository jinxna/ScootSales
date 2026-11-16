from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
import os
import uuid

from fastapi import HTTPException
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore
import pytest

from platform_service import migrate_seats, seats
from platform_service.commands import CommandProblem, PlanLimit, PlanMissing, UsageMissing
from platform_service.plans import (
    PlanStore, carried_add_ons, clean_override, clean_subscription, clean_version,
    effective_plan, load_catalogue,
)
from platform_service.signing import format_timestamp

NOW = datetime.now(timezone.utc)
V1 = {"salesmen": 5, "supervisors": 1, "managers": 2, "products": 100}
V2 = {"salesmen": 5, "supervisors": 1, "admins": 1, "branchManagers": 1, "products": 100}


def canonical(**changes):
    return {"usageSchemaVersion": 2, "seats": {"salesmen": 0, "supervisors": 0,
            "admins": 1, "branchManagers": 1}, "products": 0, "activeAdmins": 1, **changes}


def version(schema=2):
    return {"version": 1, "name": "Quota", "edition": "basic", "features": {},
            "limits": dict(V2 if schema == 2 else V1),
            **({"quotaSchemaVersion": 2} if schema == 2 else {})}


def subscription(**changes):
    return {"planId": "Q", "status": "active", "addOns": {}, "overrides": [], **changes}












@pytest.fixture
def db():
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        pytest.skip("Needs the shared Firestore emulator")
    client = firestore.Client(project=f"demo-v4-quota-{uuid.uuid4().hex[:12]}", credentials=AnonymousCredentials())
    yield client
    def clear(collection):
        for snap in collection.stream():
            for child in snap.reference.collections():
                clear(child)
            snap.reference.delete()
    for collection in client.collections():
        clear(collection)
    client.close()


def mutate(db, deltas, limits=V2, active=0):
    @firestore.transactional
    def change(tx):
        data = seats.read_usage(tx, db, required=True)
        seats.move_counts(tx, db, data, deltas, limits, active_admin_delta=active)
    change(db.transaction(max_attempts=10))






def test_real_final_admin_race_and_unmigrated_refusal(db):
    seats.usage_ref(db).set(canonical(seats={"salesmen":0,"supervisors":0,"admins":2,"branchManagers":0}, activeAdmins=2))
    def remove(_):
        try:
            mutate(db, {"admins": -1}, None, -1)
            return "ok"
        except CommandProblem:
            return "last"
    with ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(remove, range(2))) == ["last", "ok"]
    seats.usage_ref(db).set({"seats": {"salesmen":0,"supervisors":0,"managers":2}, "products":0})
    with pytest.raises(UsageMissing):
        mutate(db, {"admins":-1}, None, -1)
    with pytest.raises(UsageMissing):
        seats.usage_counts(db, quota_schema_version=2)




def member(db, uid, role="admin", **extra):
    data = {"role":role,"status":"active","accessVersion":2,"userDocId":uid,
            "uid":uid, **extra}
    db.collection("user_access").document(uid).set(data)
    db.collection("users").document(uid).set({"role":role,"uid":uid})


def test_real_migration_preserves_release_and_recounts_fresh(db):
    member(db, "admin")
    member(db, "released", "branch_manager", status="invited", invitationState="pending", seatHeld=False)
    stale = migrate_seats.plan_migration(db)
    member(db, "new", "salesman")
    migrate_seats.apply_migration(db, stale)
    data = seats.usage_ref(db).get().to_dict()
    assert data["usageSchemaVersion"] == 2 and data["activeAdmins"] == 1
    assert data["seats"] == {"salesmen":1,"supervisors":0,"admins":1,"branchManagers":0}
    assert not data.get("membershipMaintenance")






def advanced(**changes):
    return clean_version({"name": "Quota", "edition": "advanced", "features": {"forecasting": True},
                          "limits": dict(V2), "quotaSchemaVersion": 2, **changes})


def override(**body):
    return clean_override({**body, "reason": "Pilot", "expiresAt": format_timestamp(NOW + timedelta(days=5))},
                          now=NOW, actor="ops")


def test_real_subscription_writes_pin_the_version_and_never_follow_a_lower_one(db):
    store = PlanStore(db)
    store.write_version("Q", advanced(), created_by="test")
    store.apply_subscription_change("tenant", clean_subscription({"planId": "Q", "status": "active", "addOns": {}}),
                                    operation_id="put", now=NOW)
    assert store.get_subscription("tenant")["planVersion"] == 1
    store.write_version("Q", advanced(edition="basic", features={}, limits={**V2, "salesmen": 1}), created_by="test")
    assert store.effective("tenant")["planVersion"] == 1
    store.apply_subscription_change("tenant", {"kind": "refresh"}, operation_id="refresh", now=NOW)
    pinned = store.effective("tenant")
    assert (pinned["planVersion"], pinned["edition"], pinned["features"], pinned["limits"]["salesmen"]) == (
        1, "advanced", {"forecasting": True}, 5)
    before = store.get_subscription("tenant")
    for key, body, words in (("lower", {"limits": {"salesmen": 1}}, "Salespeople would drop from 5 to 1."),
                             ("feature", {"features": {"forecasting": False}}, "forecasting would be switched off")):
        with pytest.raises(CommandProblem, match=words):
            store.apply_subscription_change("tenant", override(**body), operation_id=key, now=NOW)
    with pytest.raises(CommandProblem, match="would"):
        store.apply_subscription_change("tenant", clean_subscription(
            {"planId": "Q", "planVersion": 2, "status": "active", "addOns": {}}), operation_id="explicit", now=NOW)
    assert store.get_subscription("tenant") == before
    store.apply_subscription_change("tenant", override(limits={"salesmen": 9}), operation_id="raise", now=NOW)
    assert store.get_subscription("tenant")["planVersion"] == 1
    assert store.effective("tenant")["limits"]["salesmen"] == 9










def test_real_barrier_blocks_writer_during_fresh_migration_scan(db, monkeypatch):
    member(db, "admin")
    original = migrate_seats.plan_migration
    observed = []
    def scan(client):
        data = seats.usage_ref(client).get().to_dict() or {}
        if data.get(seats.MAINTENANCE):
            with pytest.raises(UsageMissing):
                mutate(client, {"products": 1}, V1)
            observed.append(True)
        return original(client)
    monkeypatch.setattr(migrate_seats, "plan_migration", scan)
    migrate_seats.apply_migration(db, original(db))
    assert len(observed) >= 2
    assert seats.usage_counts(db)["managers"] == 1








def test_real_completed_downgrade_refuses_captured_stale_admission(db):
    from platform_service.commands import PlanMissing
    captured = effective_plan(version(), subscription(revision=1), NOW)
    projection = db.collection("config").document("plan")
    seats.usage_ref(db).set(canonical())
    def acquire(effective):
        @firestore.transactional
        def change(tx):
            seats.check_plan_projection(tx, db, effective, now=NOW)
            data = seats.read_usage(tx, db, required=True)
            seats.move_counts(tx, db, data, {"salesmen":1}, effective["limits"])
        change(db.transaction(max_attempts=10))
    with pytest.raises(PlanMissing):
        acquire(captured)
    projection.set(captured)
    acquire(captured)
    lower = {**captured, "revision":2, "limits":{**captured["limits"],"salesmen":1}}
    projection.set(lower)
    with pytest.raises(PlanMissing):
        acquire(captured)
    assert seats.usage_counts(db, quota_schema_version=2)["salesmen"] == 1
    with pytest.raises(PlanLimit):
        acquire(lower)
    expired = {**lower,"validUntil":NOW-timedelta(seconds=1)}
    projection.set(expired)
    with pytest.raises(PlanMissing):
        acquire(expired)




def test_real_older_projection_cannot_overwrite_completed_newer_plan(db):
    from platform_service.commands import PlanMissing
    from platform_service.subscriptions import SubscriptionService
    captured = effective_plan(version(), subscription(revision=1), NOW)
    seats.usage_ref(db).set(canonical())
    projection = db.collection("config").document("plan")
    newer = {**captured,"revision":2,"limits":{**V2,"salesmen":1}}
    projection.set(newer)
    plans = SimpleNamespace(effective=lambda tenant, now:captured)
    service = SubscriptionService(db, None, SimpleNamespace(get=lambda tenant:{"location":{}}), plans,
                                  access_for=lambda loc: SimpleNamespace(db=db))
    with pytest.raises((CommandProblem, PlanMissing)):
        service.subscription_steps()[1].apply(SimpleNamespace(params={"tenantId":"tenant"}))
    assert projection.get().to_dict() == newer

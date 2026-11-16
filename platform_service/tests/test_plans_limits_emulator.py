from __future__ import annotations

import base64
import json
import os
import threading
import time
import urllib.request
import uuid
from types import SimpleNamespace
from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

from fastapi.testclient import TestClient
from firebase_admin import auth as admin_auth

from platform_service import config, devtool, migrate_seats, staff_api
from fastapi import HTTPException

from platform_service.commands import CommandProblem, PlanProblem
from platform_service.operations import OperationStore, Step
from platform_service.plans import PlanStore, clean_override, clean_subscription, effective_plan
from platform_service.records import RecordError, validate_record
from platform_service.seats import usage_counts
from platform_service.staff import staff_id
from platform_service.subscriptions import ACTION_SUBSCRIPTION, SubscriptionService

from .support import in_days, make_plan, seed_catalogue, seed_subscription, seed_usage, staff_assertion, staff_domains
from .test_invitations_emulator import (  # noqa: F401  (fixtures and helpers shared with that suite)
    PROJECT_A,
    PROJECT_B,
    PASSWORD,
    app,
    bearer,
    clean_emulators,
    client,
    company,
    create_auth_user,
    id_token,
    invite,
    jwt_claims,
    make_record,
    redeem,
    signer,
    store,
    write_member,
)

PLAN_LIMIT_TEXT = "Your plan allows {n} {pool}. Remove or suspend one first, or ask to upgrade."


def set_limits(client, **limits):
    number, _ = make_plan(client, "T1", **limits)
    reference = client.collection("subscriptions").document("t_northwind")
    if reference.get().exists:
        reference.update({"planVersion": number})


@pytest.fixture
def grid(store, client):
    store.put(make_record("northwind", PROJECT_A), expected_version=0)
    store.put(make_record("southridge", PROJECT_B), expected_version=0)
    for tenant in ("t_northwind", "t_southridge"):
        client.collection("lifecycle").document(tenant).set({"state": "active", "revision": 1})
    set_limits(client, salesmen=2, supervisors=2, managers=2, products=2)
    seed_subscription(client, "t_northwind", "T1", billingInterval="monthly")
    seed_subscription(client, "t_southridge")
    for project, uid, role, code in (
        (PROJECT_A, "admin-a", "admin", "A001"),
        (PROJECT_A, "sales-a", "salesman", "S001"),
        (PROJECT_A, "sup-a", "supervisor", "SUP1"),
        (PROJECT_B, "admin-b", "admin", "B001"),
    ):
        create_auth_user(project, uid)
        write_member(project, uid, role, code=code, codes=[] if role == "supervisor" else None)
    return {
        "admin": id_token(PROJECT_A, "admin-a"),
        "sales": id_token(PROJECT_A, "sales-a"),
        "other_admin": id_token(PROJECT_B, "admin-b"),
        "db": company(PROJECT_A).db,
    }


def counts(grid):
    return usage_counts(grid["db"])


def post(app, token, path, body=None, key=None, workspace="northwind"):
    headers = {"Idempotency-Key": key or uuid.uuid4().hex, **bearer(token)}
    return app.post(f"/v1/w/{workspace}/{path}", headers=headers, json=body)


def doc(grid, collection, doc_id):
    return grid["db"].collection(collection).document(doc_id).get().to_dict()


def add_products(grid, **rows):
    for name, fields in rows.items():
        grid["db"].collection("products").document(name).set(
            {"productName": name, "isVisible": False, "status": "hidden", **fields}
        )
    seed_usage(grid["db"])


def stale_token(project, uid, age_seconds):
    now = int(time.time())
    claims = {
        "iss": f"https://securetoken.google.com/{project}", "aud": project, "sub": uid,
        "iat": now, "exp": now + 3000, "auth_time": now - age_seconds, "firebase": {},
    }

    def segment(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()

    return f"{segment({'alg': 'none', 'typ': 'JWT'})}.{segment(claims)}."


def run_race(app_factory, tokens_and_bodies):
    barrier = threading.Barrier(len(tokens_and_bodies))
    replies = [None] * len(tokens_and_bodies)

    def go(index, token, extra):
        client = app_factory()
        barrier.wait()
        replies[index] = invite(client, token, **extra)

    threads = [
        threading.Thread(target=go, args=(i, token, extra))
        for i, (token, extra) in enumerate(tokens_and_bodies)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return replies
















def test_role_change_moves_the_seat_and_checks_the_new_pool(app, client, grid):
    admin = grid["admin"]
    set_limits(client, salesmen=2, supervisors=1, managers=2, products=2)
    refused = post(app, admin, "accounts/sales-a/role", {"role": "supervisor", "branchId": "BR2"})
    assert refused.status_code == 409 and refused.json()["code"] == "plan_limit"
    assert doc(grid, "user_access", "sales-a")["role"] == "salesman"
    assert counts(grid) == {"salesmen": 1, "supervisors": 1, "managers": 1, "products": 0}

    set_limits(client, salesmen=2, supervisors=2, managers=2, products=2)
    done = post(app, admin, "accounts/sales-a/role", {"role": "supervisor", "branchId": "BR2"})
    assert done.status_code == 200, done.text
    assert counts(grid) == {"salesmen": 0, "supervisors": 2, "managers": 1, "products": 0}
    for collection, doc_id in (("user_access", "sales-a"), ("users", "S001")):
        row = doc(grid, collection, doc_id)
        assert (row["role"], row["user_group"], row["seatClass"], row["branchId"]) == (
            "supervisor", "supervisor", "supervisor", "BR2"
        )
    assert doc(grid, "user_access", "sales-a")["assignedSalesmanCodes"] == []

    assert post(app, admin, "accounts/sup-a/role", {"role": "branch_manager", "branchId": "BR1"}).status_code == 200
    assert counts(grid) == {"salesmen": 0, "supervisors": 1, "managers": 2, "products": 0}
    assert post(app, admin, "accounts/admin-a/role", {"role": "salesman", "branchId": "BR1"}).status_code == 409
    assert post(app, admin, "accounts/sup-a/role", {"role": "owner", "branchId": "BR1"}).status_code == 400






def test_remove_deletes_records_clears_lists_and_frees_the_seat(app, grid):
    admin = grid["admin"]
    made = invite(app, admin, supervisorUid="sup-a", phone="+60 12-345 6789").json()
    assert redeem(app, made["code"], "6789").status_code == 200
    assert counts(grid)["salesmen"] == 2
    done = post(app, admin, f"accounts/{made['uid']}/remove")
    assert done.status_code == 200, done.text
    assert counts(grid)["salesmen"] == 1
    assert not grid["db"].collection("user_access").document(made["uid"]).get().exists
    assert not grid["db"].collection("users").document("S100").get().exists
    assert doc(grid, "user_access", "sup-a")["assignedSalesmanCodes"] == []
    user = company(PROJECT_A).auth.get_user(made["uid"])
    assert user.disabled
    listed = app.get("/v1/w/northwind/accounts/reconcile", headers=bearer(admin)).json()
    assert [row["uid"] for row in listed["authOnly"]] == [made["uid"]]
    assert post(app, admin, "accounts/admin-a/remove").status_code == 409
    assert post(app, admin, "accounts/nobody-here/remove").status_code == 404














def test_a_revoked_company_token_is_refused_on_client_routes(app, grid):
    admin = grid["admin"]
    assert app.get("/v1/w/northwind/usage", headers=bearer(admin)).status_code == 200
    time.sleep(1.2)
    company(PROJECT_A).auth.revoke_refresh_tokens("admin-a")
    for path in ("usage", "me", "account"):
        assert app.get(f"/v1/w/northwind/{path}", headers=bearer(admin)).status_code == 401
    assert app.get("/v1/me", headers=bearer(admin)).status_code == 401
    assert app.get("/v1/w/northwind/usage", headers=bearer(id_token(PROJECT_A, "admin-a"))).status_code == 200




def stored_mail(client, request_id):
    return client.collection("plan_requests").document(request_id).get().to_dict()["mail"]




def test_effective_plan_adds_add_ons_and_applies_only_live_overrides():
    now = datetime(2026, 11, 1, tzinfo=timezone.utc)
    version = {
        "version": 3, "name": "N", "edition": "basic", "prices": None,
        "limits": {"salesmen": 2, "supervisors": None, "managers": 1, "products": 50},
        "features": {"a": True, "b": False},
    }
    subscription = {
        "planId": "X", "status": "active", "revision": 4,
        "addOns": {"salesmen": 3, "supervisors": 5, "managers": 0, "products": 10},
        "overrides": [
            {"limits": {"products": None}, "features": {"b": True}, "expiresAt": now + timedelta(days=5)},
            {"limits": {"managers": 9}, "features": {}, "expiresAt": now - timedelta(days=1)},
            {"limits": {"salesmen": 4}, "features": {}, "expiresAt": now + timedelta(days=2)},
        ],
    }
    plan = effective_plan(version, subscription, now)
    assert plan["limits"] == {"salesmen": 4, "supervisors": None, "managers": 1, "products": None}
    assert plan["features"] == {"a": True, "b": True}
    assert plan["validUntil"] == now + timedelta(days=2)
    assert (plan["planId"], plan["planVersion"], plan["revision"]) == ("X", 3, 4)
    later = effective_plan(version, subscription, now + timedelta(days=6))
    assert later["limits"] == {"salesmen": 5, "supervisors": None, "managers": 1, "products": 60}
    assert later["validUntil"] is None




@pytest.fixture
def staff(store, client, signer, grid, monkeypatch):
    roles = {"ops@example.com": "owner", "second@example.com": "operator"}
    monkeypatch.setattr(config, "STAFF_DOMAINS", staff_domains(roles))
    assertion = staff_assertion(roles)
    app = TestClient(staff_api.create_app(store=store, signer=signer, client=client),
                     headers=assertion("ops@example.com"))
    app.assertion = assertion
    app.subscribe_with = lambda tenant_id, body: subscribe_directly(store, client, tenant_id, body)
    return app


def subscribe_directly(store, client, tenant_id, body):
    if store.get(tenant_id) is None:
        return SimpleNamespace(status_code=404, text="Unknown company.", json=lambda: {})
    try:
        change = clean_subscription(body)
    except HTTPException as error:
        return SimpleNamespace(status_code=error.status_code, text=str(error.detail), json=lambda: {})
    runner = OperationStore(client)
    service = SubscriptionService(client, runner, store, PlanStore(client))
    steps = service.subscription_steps()
    operation_id = runner.begin(
        idempotency_key=uuid.uuid4().hex, action=ACTION_SUBSCRIPTION, actor="ops@example.com",
        tenant_id=tenant_id, reason="Subscription change", ticket=None, field_names=sorted(change),
        params={"tenantId": tenant_id, "change": change, "requestedBy": "ops@example.com"},
        step_names=[step.name for step in steps])
    try:
        record = runner.run(operation_id, steps)
    except (CommandProblem, PlanProblem) as error:
        payload = {"message": str(error), "status": (runner.get(operation_id) or {}).get("status")}
        return SimpleNamespace(status_code=409, text=str(payload), json=lambda: payload)
    payload = {"operationId": operation_id, "status": record.get("status"),
               "steps": {name: {"status": step.get("status"), "result": step.get("result")}
                         for name, step in (record.get("steps") or {}).items()}}
    return SimpleNamespace(status_code=200, text=str(payload), json=lambda: payload)


def subscribe(staff, tenant_id, body):
    return staff.subscribe_with(tenant_id, body)


def second_person_approves(staff, action, params, tenant_id, reason):
    asked = staff.post("/staff/v1/approvals", headers={**staff.assertion("second@example.com"),
                                                        "Idempotency-Key": uuid.uuid4().hex}, json={
        "action": action, "tenantId": tenant_id, "reason": reason, "params": params})
    if asked.status_code != 201:
        return asked
    return staff.post(f"/staff/v1/approvals/{asked.json()['approvalId']}/approve")


def put(staff, path, body, key=None):
    return staff.put(path, json=body, headers={"Idempotency-Key": key or uuid.uuid4().hex})


def post_staff(staff, path, body=None, key=None):
    return staff.post(path, json=body or {}, headers={"Idempotency-Key": key or uuid.uuid4().hex})


NO_PRICE = {"currency": "MYR", "monthly": None, "yearly": None}


def version_body(**changes):
    body = {
        "name": "P1", "edition": "basic", "limits": {"salesmen": 2, "supervisors": 1, "managers": 1, "products": 60},
        "features": {}, "prices": {"currency": "MYR", "monthly": 100, "yearly": 960},
        "tagline": "T", "highlights": ["x"], "sortOrder": 10, "notes": "",
    }
    body.update(changes)
    return body


def test_plan_versions_are_added_never_rewritten(staff, client):
    seed_catalogue(client)
    listing = staff.get("/staff/v1/plans")
    assert [p["planId"] for p in listing.json()["plans"]] == ["ENTERPRISE", "INTERNAL", "P1", "P2", "PROFESSIONAL", "STANDARD", "STARTER", "T1", "TRIAL"]
    key = uuid.uuid4().hex
    reply = put(staff, "/staff/v1/plans/P1", version_body(), key=key)
    assert reply.status_code == 200 and reply.json()["status"] == "completed"
    assert reply.json()["steps"]["write_version"]["result"] == {"version": 2}
    store = PlanStore(client)
    assert store.get_plan("P1")["currentVersion"] == 2
    assert store.get_version("P1", 1)["limits"]["products"] == 50
    assert store.get_version("P1", 2)["limits"]["products"] == 60
    assert put(staff, "/staff/v1/plans/P1", version_body(), key=key).json()["status"] == "completed"
    assert store.get_plan("P1")["currentVersion"] == 2
    assert put(staff, "/staff/v1/plans/P1", version_body(name="Other"), key=key).status_code == 409
    assert put(staff, "/staff/v1/plans/GOLD", version_body(name="Gold", visibility="private", prices=NO_PRICE)).status_code == 200
    assert store.get_plan("GOLD")["visibility"] == "private"
    bad_limits = version_body(limits={"salesmen": 1})
    assert put(staff, "/staff/v1/plans/P1", bad_limits).status_code == 400
    assert put(staff, "/staff/v1/plans/P1", version_body(edition="x")).status_code == 400

    retired = post_staff(staff, "/staff/v1/plans/GOLD/retire")
    assert retired.status_code == 200 and store.get_plan("GOLD")["status"] == "retired"
    body = {"planId": "GOLD", "status": "active"}
    refused = subscribe(staff, "t_northwind", body)
    assert refused.status_code == 409 and refused.json()["message"] == "That plan is retired."


def test_a_turned_off_staff_account_is_refused(staff, client):
    assert staff.get("/staff/v1/me").status_code == 200
    client.collection("staff").document(staff_id("ops@example.com")).update({"status": "disabled"})
    assert staff.get("/staff/v1/me").status_code == 403
    client.collection("staff").document(staff_id("ops@example.com")).update({"status": "active", "role": "support"})
    assert staff.get("/staff/v1/me").json()["role"] == "support"


@pytest.fixture
def mail_on(monkeypatch):
    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    monkeypatch.setenv("PLATFORM_MAIL_TRANSPORT", "stub")








def plant_lifecycle(client, state, tenant="t_northwind"):
    now = datetime.now(timezone.utc)
    client.collection("lifecycle").document(tenant).set({
        "tenantId": tenant, "state": state, "revision": 1, "stateSince": now,
        "graceEndsAt": None, "windowEndsAt": None, "retentionEndsAt": None,
        "reason": "test", "ticket": "T-1", "updatedBy": "ops", "updatedAt": now,
    })



def test_subscription_change_cannot_remove_an_enabled_feature(staff, client, grid):
    limits = {"salesmen": 10, "supervisors": 2, "managers": 2, "products": 100}
    for plan_id, enabled in (("FEATURE_HIGH", True), ("FEATURE_LOW", False)):
        created = put(staff, f"/staff/v1/plans/{plan_id}", version_body(
            name=plan_id, edition="advanced", limits=limits,
            features={"forecasting": enabled}, visibility="private", prices=NO_PRICE,
        ))
        assert created.status_code == 200 and created.json()["status"] == "completed"
    active = subscribe(staff, "t_northwind", {
        "planId": "FEATURE_HIGH", "status": "active",
    })
    assert active.status_code == 200 and active.json()["status"] == "completed"
    before = PlanStore(client).get_subscription("t_northwind")

    refused = subscribe(staff, "t_northwind", {
        "planId": "FEATURE_LOW", "status": "active",
        "expectedRevision": before["revision"],
    })

    assert refused.status_code == 409
    assert "forecasting would be switched off" in refused.json()["message"]
    assert PlanStore(client).get_subscription("t_northwind") == before
    assert doc(grid, "config", "plan")["features"]["forecasting"] is True




def test_a_crash_between_subscription_steps_is_finished_by_recovery(store, client, signer, grid, monkeypatch):
    seed_catalogue(client)
    runner = OperationStore(client)
    service = SubscriptionService(client, runner, store, PlanStore(client))
    original = service.subscription_steps()

    class Crash(BaseException):
        pass

    def crashing(ctx):
        raise Crash()

    steps = [original[0], Step("project_plan", crashing, original[1].check), original[2]]
    change = {"kind": "put", "planId": "P2", "planVersion": None, "addOns": {k: 0 for k in
              ("salesmen", "supervisors", "managers", "products")}, "status": "active",
              "billingInterval": None, "renewsAt": None, "trialEndsAt": None, "expectedRevision": None}
    op = runner.begin(
        idempotency_key="crash-sub-1", action="subscription.change", actor="ops", tenant_id="t_northwind",
        reason="t", ticket=None, field_names=["change"],
        params={"tenantId": "t_northwind", "change": change, "requestedBy": "ops"},
        step_names=[s.name for s in steps],
    )
    with pytest.raises(Crash):
        runner.run(op, steps)
    assert PlanStore(client).get_subscription("t_northwind")["planId"] == "P2"
    assert doc(grid, "config", "plan") is None
    actions = staff_api.build_actions(client, store, signer, subscriptions=service)
    later = datetime.now(timezone.utc) + timedelta(seconds=config.OPERATION_LEASE_SECONDS + 60)
    assert runner.recover(actions, now=later) == [op]
    assert doc(grid, "config", "plan")["edition"] == "advanced"
    assert store.get("t_northwind")["planRef"] == "P2"
    assert PlanStore(client).get_subscription("t_northwind")["revision"] == 2


def test_fix032_a_plan_request_stays_open_through_an_override_and_the_decision_is_mailed(staff, client, grid, mail_on):
    seed_catalogue(client)
    make_plan(client, "BIGGER", salesmen=5, supervisors=5, managers=5, products=50)
    plans = PlanStore(client)
    now = datetime.now(timezone.utc)
    for tenant in ("t_northwind", "t_southridge"):
        plans.create_plan_request(tenant_id=tenant, plan_id="BIGGER", interval="yearly", requested_by=f"admin-{tenant}",
                                  key=f"fix032-{tenant}", now=now, requester_email=f"{tenant[2:]}@example.test")
    override = clean_override({"limits": {"products": 9}, "reason": "Short trial", "expiresAt": in_days(1)},
                              now=now, actor="ops@example.com")
    plans.apply_subscription_change("t_northwind", override, operation_id=f"fix032-{uuid.uuid4().hex}", now=now)
    later = now + timedelta(days=2)
    plans.apply_subscription_change("t_northwind", {"kind": "refresh"}, operation_id=f"fix032-{uuid.uuid4().hex}",
                                    now=later)
    rows = {row["tenantId"]: row for row in staff.get("/staff/v1/plan-requests").json()["requests"]}
    assert rows["t_northwind"]["open"] is True and rows["t_southridge"]["open"] is True

    approved = subscribe(staff, "t_northwind", {"planId": "BIGGER", "billingInterval": "yearly"})
    assert approved.status_code == 200 and approved.json()["status"] == "completed"

    rows = {row["tenantId"]: row for row in staff.get("/staff/v1/plan-requests").json()["requests"]}
    assert rows["t_northwind"]["open"] is False and rows["t_northwind"]["status"] == "approved"
    assert rows["t_southridge"]["open"] is True and rows["t_southridge"]["status"] == "requested"
    mailed = [row.to_dict() for row in client.collection("mail_jobs").stream()]
    decisions = [row for row in mailed if row["kind"] == "plan_request_approved"]
    assert [(row["tenantId"], row["recipient"]) for row in decisions] == [
        ("t_northwind", "northwind@example.test")]

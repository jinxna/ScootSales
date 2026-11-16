from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from google.cloud import firestore

from platform_service import config
from platform_service.commands import CommandProblem, PlanProblem
from platform_service.company_access import company_access
from platform_service.invitations import InvitationService, InviteProblem
from platform_service.operations import OperationContext, OperationStore




@pytest.fixture
def membership(monkeypatch):
    project = os.environ.get("V4_MEMBERSHIP_EMULATOR_PROJECT", "")
    if not (os.environ.get("FIRESTORE_EMULATOR_HOST")
            and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST") and project):
        pytest.skip("Needs shared emulators and an explicitly assigned membership demo project.")
    assert project.startswith("demo-v4-membership-"), "Refuse any other emulator project"
    monkeypatch.setattr(config, "EMULATOR_EXTRA_PROJECTS", frozenset({project}))
    access = company_access({"projectId": project, "databaseId": "(default)", "authTenantId": None})
    db = access.db
    for collection in ("users", "user_access", "config", "operations", "invitations"):
        for snapshot in db.collection(collection).stream():
            snapshot.reference.delete()
    for user in access.auth.list_users().iterate_all():
        access.auth.delete_user(user.uid)
    limits = {"salesmen": 5, "supervisors": 2, "admins": 3, "branchManagers": 3, "products": 100}
    effective = {"quotaSchemaVersion": 2, "limits": limits, "planId": "MEMBERSHIP",
                 "planVersion": 1, "revision": 1, "validUntil": None}
    plans = SimpleNamespace(effective=lambda *args: effective)
    db.collection("config").document("plan").set(effective)
    service = InvitationService(db, OperationStore(db), None, secret=b"x" * 32,
                                access_for=lambda location: access, plans=plans)
    db.collection("config").document("usage").set({
        "usageSchemaVersion": 2,
        "seats": {"salesmen": 0, "supervisors": 0, "admins": 0, "branchManagers": 0},
        "products": 0, "activeAdmins": 0,
    })

    def member(uid, role, *, active=True, held=True, pending=False):
        data = {"accessVersion": 2, "uid": uid, "userDocId": uid.upper(),
                "employeeCode": uid.upper(), "role": role, "status": "active" if active else "suspended",
                "isActive": active, "seatHeld": held, "branchId": "BR1", "supervisorUid": ""}
        if pending:
            data.update(invitationState="pending", invitationOp=f"invite-{uid}")
        db.collection("user_access").document(uid).set(data)
        db.collection("users").document(uid.upper()).set(data)
        access.auth.create_user(uid=uid, email=f"{uid}@example.com", disabled=not active)
        usage = db.collection("config").document("usage")
        changes = {}
        pool = {"admin": "admins", "branch_manager": "branchManagers",
                "supervisor": "supervisors", "salesman": "salesmen"}.get(role)
        if pool and held:
            changes[f"seats.{pool}"] = firestore.Increment(1)
        if role == "admin" and active and not pending:
            changes["activeAdmins"] = firestore.Increment(1)
        if changes:
            usage.update(changes)

    member("dev", "developer", held=False)
    params = {"tenantId": "tenant", "projectId": project, "databaseId": "(default)",
              "authTenantId": None, "workspace": "membership", "requestedBy": "dev", "revokedBy": "dev"}
    return SimpleNamespace(service=service, db=db, access=access, member=member, params=params,
                           limits=limits, plans=plans)


def usage(world):
    return world.db.collection("config").document("usage").get().to_dict()


def index(world, uid):
    return world.db.collection("user_access").document(uid).get().to_dict()


def role_params(world, uid, role, **extra):
    return {**world.params, "uid": uid, "role": role, "branchId": "BR1", "supervisorUid": None, **extra}




def test_two_competing_admin_demotions_keep_one_active_admin(membership):
    w = membership
    w.member("one", "admin")
    w.member("two", "admin")

    def demote(uid):
        try:
            w.service._apply_role(role_params(w, uid, "branch_manager"))
            return "changed"
        except (PlanProblem, CommandProblem, InviteProblem):
            return "refused"

    with ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(demote, ("one", "two"))) == ["changed", "refused"]
    assert usage(w)["activeAdmins"] == 1
    assert usage(w)["seats"] == {"salesmen": 0, "supervisors": 0, "admins": 1, "branchManagers": 1}
    assert sorted(index(w, uid)["role"] for uid in ("one", "two")) == ["admin", "branch_manager"]




@pytest.mark.parametrize("action", ["role", "reactivate", "revoke", "remove", "invite", "move"])
def test_stale_caller_is_refused_in_membership_transaction(membership, action):
    w = membership
    w.member("caller", "admin")
    w.member("target", "salesman", active=action != "reactivate", held=action != "reactivate")
    w.member("sup", "supervisor")
    w.db.collection("user_access").document("caller").update({"status": "suspended", "isActive": False})
    before = usage(w)
    params = role_params(w, "target", "supervisor", requestedBy="caller", revokedBy="caller")
    with pytest.raises((PlanProblem, CommandProblem, InviteProblem)):
        if action == "role":
            w.service._apply_role(params)
        elif action == "reactivate":
            w.service._activate_account(params)
        elif action == "revoke":
            w.service._suspend_records(params)
        elif action == "remove":
            w.service._remove_records(params)
        elif action == "move":
            w.service._apply_move({**params, "supervisorUid": "sup"})
        else:
            invite = {**params, "createdBy": "caller", "employeeCode": "NEW", "displayName": "New",
                      "phone": "12345678", "email": None, "signInId": "new@example.com"}
            w.service._apply_profile(OperationContext("new-invite", "tenant", invite, {}))
    assert usage(w) == before
    assert index(w, "target")["role"] == "salesman"
    assert index(w, "target")["supervisorUid"] == ""














def test_redeeming_released_reservation_never_enables_auth(membership):
    w = membership
    w.member("pending", "admin", active=False, pending=True)
    reference = w.db.collection("invitations").document("released")
    assert w.service._release_seat(w.access, "pending", "invite-pending", reference)
    w.service.directory = SimpleNamespace(lifecycle_state=lambda tenant: "active", get=lambda tenant: {"tenantId": tenant,
        "status": "live", "workspace": "membership", "location": {"projectId": w.access.project_id}})
    reference.set({"status": "redeeming"})
    with pytest.raises(HTTPException):
        w.service._finish_redeem(reference, {"tenantId": "tenant", "uid": "pending",
                                           "operationId": "invite-pending", "signInId": "pending@example.com"},
                                 "test-password-123", "test")
    assert w.access.auth.get_user("pending").disabled

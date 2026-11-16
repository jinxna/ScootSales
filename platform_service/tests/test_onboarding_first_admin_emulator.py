from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from platform_service import config, migrate_seats, prepare_data
from platform_service.commands import CommandProblem
from platform_service.company_access import company_access
from platform_service.plans import PlanStore
from platform_service.signing import b64url_encode
from platform_service.tests import test_staff_operator_emulator as operator
from platform_service.tests.test_staff_operator_emulator import assertion, staff_settings, world

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)


@pytest.fixture(autouse=True)
def invite_secret(monkeypatch):
    monkeypatch.setenv(config.INVITE_SECRET_ENV, b64url_encode(os.urandom(32)))


def price_standard(world):
    plans = world.db.collection("plans").document("STANDARD")
    current = plans.collection("versions").document(str(plans.get().to_dict()["currentVersion"])).get().to_dict()
    if (current.get("prices") or {}).get("monthly") is not None:
        return
    content = {key: current[key] for key in ("name", "edition", "limits", "features", "tagline", "highlights",
                                             "sortOrder", "notes", "quotaSchemaVersion") if key in current}
    PlanStore(world.db).write_version(
        "STANDARD", {**content, "prices": {"currency": "MYR", "monthly": 100, "yearly": 960}},
        created_by="test", visibility="public")


@pytest.fixture
def paid_company(world, assertion):
    def make(admin_email):
        price_standard(world)
        key = uuid.uuid4().hex
        draft = operator.start_draft(world, assertion, f"draft-{key}", adminEmail=admin_email).json()
        made = operator.complete(world, assertion, draft["draftId"], f"complete-{key}", operator.OWNER)
        assert made.status_code == 200, made.text
        tenant = made.json()["tenantId"]
        chosen = world.app.post(
            f"/staff/v1/companies/{tenant}/package",
            json={"planId": "STANDARD", "billingInterval": "monthly", "expectedRevision": 0, "reason": "Chosen at sign-up"},
            headers=operator.headers(assertion, operator.OPERATOR, f"package-{key}"))
        assert chosen.status_code == 200, chosen.text
        invoice = world.app.post(f"/staff/v1/companies/{tenant}/invoices", json={},
                                 headers=operator.headers(assertion, operator.OPERATOR, f"invoice-{key}"))
        assert invoice.status_code == 201, invoice.text
        issued = world.app.post(f"/staff/v1/invoices/{invoice.json()['invoiceId']}/issue",
                                headers=operator.headers(assertion, operator.OPERATOR))
        assert issued.status_code == 200, issued.text
        return draft["draftId"], tenant
    return make


def company_of(world):
    return company_access({"projectId": world.new_project, "databaseId": "(default)", "authTenantId": None})


def give_access(world, assertion, draft_id, code="ADM001", who=operator.OPERATOR):
    return world.app.post(f"/staff/v1/onboarding-drafts/{draft_id}/first-admin", json={"employeeCode": code},
                          headers=operator.headers(assertion, who))


def first_admin_events(world, draft_id):
    return [row.to_dict() for row in world.db.collection("audit_events").stream()
            if row.to_dict()["action"] == "onboarding.first_admin"
            and (row.to_dict().get("refs") or {}).get("draftId") == draft_id]


def step_of(draft, key):
    return next(step for step in draft["steps"] if step["key"] == key)


def test_existing_sign_in_account_becomes_the_active_first_admin_once(world, assertion, paid_company):
    draft_id, tenant = paid_company("owner@newco.example")
    target = company_of(world)
    user = target.auth.create_user(email="owner@newco.example", password="same-pass-1")
    refused = give_access(world, assertion, draft_id)
    assert refused.status_code == 409 and "steps 1 to 5" in refused.json()["detail"]
    assert "Step 5 (First payment)" in refused.json()["detail"]
    assert target.db.collection("user_access").document(user.uid).get().exists is False
    operator.plant_checked_payment(world, tenant)
    assert give_access(world, assertion, draft_id, who=operator.SUPPORT).status_code == 403

    granted = give_access(world, assertion, draft_id)
    again = give_access(world, assertion, draft_id, code="ADM002")
    assert granted.status_code == again.status_code == 200, granted.text + again.text
    for reply in (granted.json(), again.json()):
        assert (reply["state"], reply["path"], reply["uid"]) == ("active", "account", user.uid)
    row = target.db.collection("user_access").document(user.uid).get().to_dict()
    assert (row["accessVersion"], row["role"], row["status"], row["isActive"], row["seatHeld"]) == (
        2, "admin", "active", True, True)
    assert row["invitationState"] == "redeemed" and row["employeeCode"] == "ADM001"
    assert target.db.collection("users").document("ADM001").get().to_dict()["uid"] == user.uid
    assert target.db.collection("users").document("ADM002").get().exists is False
    assert target.db.collection("employee_codes").document("ADM001").get().to_dict()["sources"] == [
        f"user_access/{user.uid}"]
    usage = target.db.collection("config").document("usage").get().to_dict()
    assert usage["seats"]["admins"] == 1 and usage["activeAdmins"] == 1
    signed_in = operator.auth_call("POST", "/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake",
                                   {"targetProjectId": world.new_project, "email": "owner@newco.example",
                                    "password": "same-pass-1", "returnSecureToken": True})
    assert signed_in["localId"] == user.uid

    draft = again.json()["draft"]
    assert step_of(draft, "admin")["state"] == "green" and step_of(draft, "package")["state"] == "green"
    listed = next(row for row in world.app.get("/staff/v1/onboarding-drafts",
                                               headers=operator.headers(assertion)).json()["drafts"]
                  if row["draftId"] == draft_id)
    single = world.app.get(f"/staff/v1/onboarding-drafts/{draft_id}", headers=operator.headers(assertion)).json()
    assert listed["total"] == single["total"] == 8
    assert listed["doneCount"] == single["doneCount"] == draft["doneCount"]
    assert [step["state"] for step in listed["steps"]] == [step["state"] for step in single["steps"]]
    assert len(first_admin_events(world, draft_id)) == 1


def test_no_sign_in_account_gets_one_invitation_and_the_task_waits(world, assertion, paid_company):
    draft_id, tenant = paid_company("new.owner@newco.example")
    operator.plant_checked_payment(world, tenant)
    first = give_access(world, assertion, draft_id)
    again = give_access(world, assertion, draft_id)
    assert first.status_code == again.status_code == 200, first.text + again.text
    made, repeat = first.json(), again.json()
    assert (made["state"], made["path"]) == ("invited", "invitation")
    assert repeat["invitation"]["code"] == made["invitation"]["code"] and repeat["uid"] == made["uid"]
    row = company_of(world).db.collection("user_access").document(made["uid"]).get().to_dict()
    assert row["role"] == "admin" and row["invitationState"] == "pending" and row["isActive"] is False
    invitations_made = [doc.to_dict() for doc in world.db.collection("invitations").stream()
                        if doc.to_dict()["tenantId"] == tenant]
    assert len(invitations_made) == 1 and invitations_made[0]["role"] == "admin"
    step = step_of(repeat["draft"], "admin")
    assert step["state"] == "red" and step["button"]["id"] == "resend_invitation"
    assert len(first_admin_events(world, draft_id)) == 1


def test_an_expired_first_admin_invitation_offers_resend_and_resend_sends_a_new_code(
    world, assertion, paid_company,
):
    draft_id, tenant = paid_company("late.owner@newco.example")
    operator.plant_checked_payment(world, tenant)
    made = give_access(world, assertion, draft_id).json()
    world.db.collection("invitations").document(made["invitation"]["invitationId"]).update(
        {"expiresAt": datetime.now(timezone.utc) - timedelta(minutes=1)})
    swept = world.app.post(f"/staff/v1/companies/{tenant}/seats/sweep", headers=operator.headers(assertion))
    assert swept.status_code == 200 and swept.json()["released"] == 1, swept.text
    row = company_of(world).db.collection("user_access").document(made["uid"]).get().to_dict()
    assert row["invitationState"] == "expired"
    draft = world.app.get(f"/staff/v1/onboarding-drafts/{draft_id}", headers=operator.headers(assertion)).json()
    step = step_of(draft, "admin")
    assert step["state"] == "red" and step["button"]["id"] == "resend_invitation", step
    resent = world.app.post(f"/staff/v1/onboarding-drafts/{draft_id}/first-admin/resend",
                            headers=operator.headers(assertion, operator.OWNER))
    assert resent.status_code == 200, resent.text
    body = resent.json()
    assert body["state"] == "invited" and body["invitation"]["code"] != made["invitation"]["code"]
    assert pending_invitations(world, tenant) == [body["invitation"]["invitationId"]]


@pytest.mark.parametrize("case", ["other_role", "disabled", "code_taken"])
def test_first_admin_refusals_say_why_and_change_nothing(world, assertion, paid_company, case):
    draft_id, tenant = paid_company("taken@newco.example")
    operator.plant_checked_payment(world, tenant)
    target = company_of(world)
    user = target.auth.create_user(email="taken@newco.example", password="same-pass-1", disabled=case == "disabled")
    if case == "other_role":
        target.db.collection("users").document("SAL001").set(
            {"uid": user.uid, "employeeCode": "SAL001", "role": "salesman", "status": "active", "isActive": True})
        target.db.collection("user_access").document(user.uid).set(
            {"accessVersion": 2, "uid": user.uid, "role": "salesman", "status": "active", "isActive": True,
             "userDocId": "SAL001"})
        prepared = world.app.post(f"/staff/v1/companies/{tenant}/prepare-data", json={"apply": True},
                                  headers=operator.headers(assertion, operator.OWNER))
        assert prepared.status_code == 200 and prepared.json()["prepared"] is True, prepared.text
    if case == "code_taken":
        target.db.collection("users").document("ADM001").set({"uid": "someone-else", "employeeCode": "ADM001"})
    before = target.db.collection("user_access").document(user.uid).get().to_dict()
    reply = give_access(world, assertion, draft_id)
    assert reply.status_code == 409, reply.text
    expected = {"other_role": "already has access", "disabled": "turned off", "code_taken": "employee code"}[case]
    assert expected in reply.json()["detail"]
    assert reply.json().get("fix") == ("promote_first_admin" if case == "other_role" else None)
    assert target.db.collection("user_access").document(user.uid).get().to_dict() == before
    assert target.db.collection("config").document("usage").get().to_dict()["seats"]["admins"] == 0
    assert first_admin_events(world, draft_id) == []


def entry_of(tenant):
    import hashlib
    return "pay_" + hashlib.sha256(tenant.encode()).hexdigest()


def open_company(world, assertion, tenant, key):
    return world.app.put(
        f"/staff/v1/companies/{tenant}/lifecycle",
        json={"state": "active", "expectedRevision": 1, "paymentEntryId": entry_of(tenant),
              "reason": "Coverage verified for activation", "ticket": "ONB-1"},
        headers=operator.headers(assertion, operator.OPERATOR, key))


def test_the_company_opens_only_when_the_first_seven_steps_are_green_and_then_all_eight_are(
        world, assertion, paid_company):
    draft_id, tenant = paid_company("opener@newco.example")
    target = company_of(world)
    target.auth.create_user(email="opener@newco.example", password="same-pass-1")
    operator.plant_checked_payment(world, tenant)
    refused = open_company(world, assertion, tenant, "open-early-0001")
    assert refused.status_code == 409, refused.text
    assert "steps 1 to 7" in refused.json()["detail"] and "Step 6 (First administrator)" in refused.json()["detail"]
    assert world.db.collection("lifecycle").document(tenant).get().to_dict()["state"] == "lead"

    assert give_access(world, assertion, draft_id).status_code == 200
    opened = open_company(world, assertion, tenant, "open-ready-0001")
    assert opened.status_code in (200, 202), opened.text
    view = world.app.get(f"/staff/v1/onboarding-drafts/{draft_id}", headers=operator.headers(assertion)).json()
    assert [step["state"] for step in view["steps"]] == ["green"] * 8, view["steps"]
    assert view["doneCount"] == view["total"] == 8 and view["phase"] == "working" and view["next"] is None
    again = open_company(world, assertion, tenant, "open-again-0001")
    assert again.status_code != 500


def test_a_half_done_prepare_shows_resume_and_resume_finishes_it_with_the_same_operation(
        world, assertion, paid_company):
    draft_id, tenant = paid_company("resume@newco.example")
    target = company_of(world)
    usage = target.db.collection("config").document("usage")
    usage.set({"membershipMaintenance": {"operationId": "held-operation-1", "writerVersion": 2}}, merge=True)
    view = world.app.get(f"/staff/v1/onboarding-drafts/{draft_id}", headers=operator.headers(assertion)).json()
    people = next(step for step in view["steps"] if step["key"] == "people")
    assert people["state"] == "red" and people["button"]["id"] == "resume_prepare"
    assert people["button"]["roles"] == ["owner"]
    path = f"/staff/v1/companies/{tenant}/prepare-data"
    denied = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OPERATOR))
    assert denied.status_code == 403
    resumed = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OWNER))
    assert resumed.status_code == 200 and resumed.json()["prepared"] is True, resumed.text
    assert "membershipMaintenance" not in usage.get().to_dict()
    nothing = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OWNER))
    assert nothing.status_code == 409 and "No preparation is waiting" in nothing.json()["detail"]


HELD_OPERATION = "held-operation-1"


def lease_of(owner, age_seconds=0):
    beat = datetime.now(timezone.utc) - timedelta(seconds=age_seconds)
    return {"owner": owner, "startedAt": beat, "heartbeatAt": beat}


def hold(usage, lease=None):
    marker = {"operationId": HELD_OPERATION, "writerVersion": 2, **({"lease": lease} if lease else {})}
    usage.set({"membershipMaintenance": marker}, merge=True)


def add_unprepared_admin(target):
    kept = target.auth.create_user(email="unprepared@newco.example", password="same-pass-1")
    target.db.collection("users").document("ADM009").set(
        {"uid": kept.uid, "employeeCode": "ADM009", "role": "admin", "status": "active", "isActive": True})
    target.db.collection("user_access").document(kept.uid).set(
        {"accessVersion": 2, "uid": kept.uid, "role": "admin", "status": "active", "isActive": True,
         "userDocId": "ADM009", "invitationState": "redeemed", "employeeCode": "ADM009"})
    return target.db.collection("user_access").document(kept.uid)


def watch_scans(monkeypatch, after_scan):
    scan = migrate_seats.plan_migration
    plans = []

    def watched(db, **options):
        plan = scan(db, **options)
        plans.append(plan)
        after_scan(len(plans), plan)
        return plan

    monkeypatch.setattr(migrate_seats, "plan_migration", watched)
    return plans


def test_a_prepare_with_a_fresh_lease_of_another_run_shows_running_and_cannot_be_resumed(
        world, assertion, paid_company):
    draft_id, tenant = paid_company("running@newco.example")
    target = company_of(world)
    usage = target.db.collection("config").document("usage")
    hold(usage, lease_of("other-host:1:run-1"))
    before = usage.get().to_dict()
    path = f"/staff/v1/companies/{tenant}/prepare-data"
    report = world.app.post(path, json={}, headers=operator.headers(assertion, operator.OWNER)).json()
    assert report["halfDone"] is False and report["running"] is True
    assert prepare_data.PREPARING in report["blockers"]
    view = world.app.get(f"/staff/v1/onboarding-drafts/{draft_id}", headers=operator.headers(assertion)).json()
    people = step_of(view, "people")
    assert people["state"] == "red" and people["button"] is None and "running" in people["fact"]
    resumed = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OWNER))
    assert resumed.status_code == 409 and "running" in resumed.json()["detail"], resumed.text
    with pytest.raises(CommandProblem, match="running"):
        migrate_seats.apply_migration(target.db, {}, resume_operation=HELD_OPERATION)
    assert usage.get().to_dict() == before


def test_a_prepare_with_an_old_lease_shows_stopped_and_resume_takes_the_lease_as_a_new_owner(
        world, assertion, paid_company, monkeypatch):
    draft_id, tenant = paid_company("stale@newco.example")
    target = company_of(world)
    usage = target.db.collection("config").document("usage")
    hold(usage, lease_of("other-host:1:run-1", config.OPERATION_LEASE_SECONDS + 60))
    path = f"/staff/v1/companies/{tenant}/prepare-data"
    report = world.app.post(path, json={}, headers=operator.headers(assertion, operator.OWNER)).json()
    assert report["halfDone"] is True and report["running"] is False
    view = world.app.get(f"/staff/v1/onboarding-drafts/{draft_id}", headers=operator.headers(assertion)).json()
    assert step_of(view, "people")["button"]["id"] == "resume_prepare"
    seen = []
    watch_scans(monkeypatch, lambda count, plan: seen.append(usage.get().to_dict().get("membershipMaintenance")))
    started = datetime.now(timezone.utc)
    resumed = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OWNER))
    assert resumed.status_code == 200 and resumed.json()["prepared"] is True, resumed.text
    during = seen[1]
    assert during["operationId"] == HELD_OPERATION and during["writerVersion"] == 2
    assert during["lease"]["owner"] not in ("", "other-host:1:run-1")
    assert during["lease"]["heartbeatAt"] >= started - timedelta(seconds=5)
    assert seen[2]["lease"]["owner"] == during["lease"]["owner"]
    assert "membershipMaintenance" not in usage.get().to_dict()


def test_a_run_that_lost_its_lease_writes_nothing_more_and_leaves_the_marker_to_the_new_owner(
        world, assertion, paid_company, monkeypatch):
    draft_id, tenant = paid_company("fenced@newco.example")
    target = company_of(world)
    usage = target.db.collection("config").document("usage")
    row = add_unprepared_admin(target)
    hold(usage)

    def take_over(count, plan):
        if count == 2:
            usage.update({"membershipMaintenance.lease.owner": "other-host:2:run-2"})

    plans = watch_scans(monkeypatch, take_over)
    path = f"/staff/v1/companies/{tenant}/prepare-data"
    resumed = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OWNER))
    assert len(plans) == 2 and plans[1]["accessChanges"]
    assert resumed.status_code == 409, resumed.text
    assert "seatClass" not in row.get().to_dict()
    assert "seatClass" not in target.db.collection("users").document("ADM009").get().to_dict()
    stored = usage.get().to_dict()
    assert stored["membershipMaintenance"]["operationId"] == HELD_OPERATION
    assert stored["membershipMaintenance"]["lease"]["owner"] == "other-host:2:run-2"
    assert "updatedAt" not in stored


def test_a_prepare_that_fails_after_it_starts_shows_stopped_and_can_be_resumed_at_once(
        world, assertion, paid_company, monkeypatch):
    draft_id, tenant = paid_company("failed@newco.example")
    target = company_of(world)
    usage = target.db.collection("config").document("usage")
    add_unprepared_admin(target)
    hold(usage)

    def fail_second_scan(count, plan):
        if count == 2:
            raise CommandProblem("The second scan failed.")

    watch_scans(monkeypatch, fail_second_scan)
    path = f"/staff/v1/companies/{tenant}/prepare-data"
    failed = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OWNER))
    assert failed.status_code == 409 and "second scan failed" in failed.json()["detail"], failed.text
    marker = usage.get().to_dict()["membershipMaintenance"]
    assert marker["operationId"] == HELD_OPERATION and marker["lease"]["heartbeatAt"] is None
    report = world.app.post(path, json={}, headers=operator.headers(assertion, operator.OWNER)).json()
    assert report["halfDone"] is True and report["running"] is False
    resumed = world.app.post(path, json={"resume": True}, headers=operator.headers(assertion, operator.OWNER))
    assert resumed.status_code == 200 and resumed.json()["prepared"] is True, resumed.text
    assert "membershipMaintenance" not in usage.get().to_dict()


def correct_admin_email(world, assertion, draft_id, email):
    return world.app.put(f"/staff/v1/onboarding-drafts/{draft_id}", json={"adminEmail": email},
                         headers=operator.headers(assertion, operator.OWNER))


def pending_invitations(world, tenant):
    return [doc.id for doc in world.db.collection("invitations").stream()
            if doc.to_dict()["tenantId"] == tenant and doc.to_dict()["status"] == "open"]


@pytest.mark.parametrize("route", ["give_access", "resend"])
def test_a_corrected_first_admin_email_gets_the_invitation_and_the_old_one_stops_working(
    world, assertion, paid_company, route,
):
    draft_id, tenant = paid_company("typo@newco.example")
    operator.plant_checked_payment(world, tenant)
    first = give_access(world, assertion, draft_id)
    assert first.status_code == 200, first.text
    old_uid = first.json()["uid"]
    corrected = correct_admin_email(world, assertion, draft_id, "right@newco.example")
    assert corrected.status_code == 200, corrected.text
    if route == "give_access":
        second = give_access(world, assertion, draft_id)
    else:
        second = world.app.post(f"/staff/v1/onboarding-drafts/{draft_id}/first-admin/resend",
                                headers=operator.headers(assertion, operator.OWNER))
    assert second.status_code == 200, second.text
    body = second.json()
    assert body["state"] == "invited" and body["uid"] != old_uid
    target = company_of(world)
    assert target.auth.get_user(body["uid"]).email == "right@newco.example"
    assert target.db.collection("user_access").document(body["uid"]).get().to_dict()["role"] == "admin"
    open_now = pending_invitations(world, tenant)
    assert open_now == [body["invitation"]["invitationId"]]
    with pytest.raises(Exception):
        target.auth.get_user(old_uid)
    assert target.db.collection("user_access").document(old_uid).get().exists is False
    again = give_access(world, assertion, draft_id)
    assert again.status_code == 200, again.text
    assert again.json()["uid"] == body["uid"]


@pytest.mark.parametrize("route", ["give_access", "resend"])
@pytest.mark.parametrize("row", ["no_row", "active_admin"])
def test_a_corrected_first_admin_email_that_already_has_an_account_keeps_that_account(
    world, assertion, paid_company, route, row,
):
    draft_id, tenant = paid_company("typo@newco.example")
    operator.plant_checked_payment(world, tenant)
    first = give_access(world, assertion, draft_id)
    assert first.status_code == 200, first.text
    old_uid = first.json()["uid"]
    target = company_of(world)
    kept = target.auth.create_user(email="existing@newco.example", password="same-pass-1")
    if row == "active_admin":
        target.db.collection("users").document("ADM009").set(
            {"uid": kept.uid, "employeeCode": "ADM009", "role": "admin", "status": "active", "isActive": True})
        target.db.collection("user_access").document(kept.uid).set(
            {"accessVersion": 2, "uid": kept.uid, "role": "admin", "status": "active", "isActive": True,
             "userDocId": "ADM009", "invitationState": "redeemed", "employeeCode": "ADM009"})
        prepared = world.app.post(f"/staff/v1/companies/{tenant}/prepare-data", json={"apply": True},
                                  headers=operator.headers(assertion, operator.OWNER))
        assert prepared.status_code == 200 and prepared.json()["prepared"] is True, prepared.text
    assert correct_admin_email(world, assertion, draft_id, "existing@newco.example").status_code == 200
    if route == "give_access":
        second = give_access(world, assertion, draft_id)
    else:
        second = world.app.post(f"/staff/v1/onboarding-drafts/{draft_id}/first-admin/resend",
                                headers=operator.headers(assertion, operator.OWNER))
    assert second.status_code == 200, second.text
    body = second.json()
    assert (body["state"], body["path"], body["uid"]) == ("active", "account", kept.uid)
    stored = target.db.collection("user_access").document(kept.uid).get().to_dict()
    assert stored["role"] == "admin" and stored["status"] == "active" and stored["isActive"] is True
    assert pending_invitations(world, tenant) == []
    with pytest.raises(Exception):
        target.auth.get_user(old_uid)
    assert target.db.collection("user_access").document(old_uid).get().exists is False
    again = give_access(world, assertion, draft_id)
    assert again.status_code == 200, again.text
    assert again.json()["uid"] == kept.uid
    assert step_of(again.json()["draft"], "admin")["state"] == "green"

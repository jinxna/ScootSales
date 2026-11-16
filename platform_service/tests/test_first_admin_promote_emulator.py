from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

from fastapi import HTTPException

from platform_service import invitations
from platform_service.invitations import InvitationService, first_admin_state
from platform_service.operations import OperationStore

from .test_invitations_emulator import (
    PASSWORD, PROJECT_A, access_doc, app, client, clean_emulators, company, create_auth_user, mail_jobs,
    mailbox, profile_doc, redeem_email, sign_in_password, signer, store, world, write_member,
)

OWNER_STAFF = "owner@staff.example"
ANA = {"draftId": "drf_ana", "adminName": "Ana Tan", "adminEmail": "ana@example.com"}


@pytest.fixture
def service(client, store, world):
    return InvitationService(client, OperationStore(client), store, secret=invitations.load_secret())


@pytest.fixture
def record(store, world):
    return store.get("t_northwind")


@pytest.fixture
def invite_url(monkeypatch):
    monkeypatch.setenv(invitations.INVITE_URL_ENV, "https://join.example.test/start")


def person(uid="ana", role="salesman", **changes):
    create_auth_user(PROJECT_A, uid)
    write_member(PROJECT_A, uid, role, code="A101")
    if changes:
        company(PROJECT_A).db.collection("user_access").document(uid).update(changes)
    return {**ANA, "adminEmail": f"{uid}@example.com"}


def promote(service, record, draft, expected=None, code="A101"):
    return service.promote_to_first_admin(record, draft, code, expected, actor=OWNER_STAFF)


def refused(call, text):
    with pytest.raises(HTTPException) as caught:
        call()
    assert caught.value.status_code == 409
    assert text in caught.value.detail, caught.value.detail


def seats():
    return company(PROJECT_A).db.collection("config").document("usage").get().to_dict()


def test_a_salesperson_is_shown_then_promoted_and_keeps_uid_and_password(service, record):
    draft = person()
    before = seats()
    preview = promote(service, record, draft)
    assert preview["state"] == "preview"
    assert (preview["from"], preview["to"], preview["employeeCode"]) == ("Salesperson", "Admin", "A101")
    assert access_doc("ana")["role"] == "salesman"
    done = promote(service, record, draft, preview["expectedRow"])
    assert done == {"state": "active", "path": "promote", "uid": "ana", "invitation": None}
    row = access_doc("ana")
    assert (row["role"], row["status"], row["employeeCode"], row["uid"]) == ("admin", "active", "A101", "ana")
    assert profile_doc("A101")["role"] == "admin"
    after = seats()
    assert after["seats"]["salesmen"] == before["seats"]["salesmen"] - 1
    assert after["seats"]["admins"] == before["seats"]["admins"] + 1
    assert after["activeAdmins"] == before["activeAdmins"] + 1
    assert sign_in_password(PROJECT_A, "ana@example.com", PASSWORD)["localId"] == "ana"
    assert first_admin_state(company(PROJECT_A), "ana@example.com")["state"] == "active"
    assert promote(service, record, draft, preview["expectedRow"])["state"] == "active"
    assert seats()["activeAdmins"] == before["activeAdmins"] + 1


def test_a_supervised_salesperson_leaves_the_supervisor_list_when_promoted(service, record):
    write_member(PROJECT_A, "boss", "supervisor", code="SUP1", codes=["A101"])
    create_auth_user(PROJECT_A, "boss")
    draft = person(supervisorUid="boss", supervisorId="SUP1")
    preview = promote(service, record, draft)
    promote(service, record, draft, preview["expectedRow"])
    assert not access_doc("boss").get("assignedSalesmanCodes")
    assert access_doc("ana")["supervisorUid"] == ""


def test_a_row_that_changed_after_the_preview_is_refused_and_left_alone(service, record):
    draft = person()
    preview = promote(service, record, draft)
    company(PROJECT_A).db.collection("user_access").document("ana").update({"branchId": "BR2"})
    refused(lambda: promote(service, record, draft, preview["expectedRow"]), "changed after you looked")
    assert access_doc("ana")["role"] == "salesman"


def test_a_row_that_changes_between_the_check_and_the_write_is_refused(service, record, monkeypatch):
    draft = person()
    preview = promote(service, record, draft)
    original = InvitationService._precheck_seat

    def change_then_check(self, *args, **kwargs):
        company(PROJECT_A).db.collection("user_access").document("ana").update({"branchId": "BR2"})
        return original(self, *args, **kwargs)

    monkeypatch.setattr(InvitationService, "_precheck_seat", change_then_check)
    refused(lambda: promote(service, record, draft, preview["expectedRow"]), "changed after you looked")
    row = access_doc("ana")
    assert (row["role"], row["branchId"]) == ("salesman", "BR2")


def test_a_switched_off_row_is_refused_with_a_clear_text(service, record):
    draft = person(status="suspended", isActive=False)
    refused(lambda: promote(service, record, draft), "Ana's access is switched off")
    assert access_doc("ana")["role"] == "salesman"


def test_a_turned_off_sign_in_account_is_refused(service, record):
    draft = person()
    company(PROJECT_A).auth.update_user("ana", disabled=True)
    refused(lambda: promote(service, record, draft), "turned off in the company's Firebase project")
    assert access_doc("ana")["role"] == "salesman"


def test_a_pending_invitation_row_is_refused(service, record):
    pending = person("ana", status="suspended", isActive=False, invitationState="pending", seatHeld=True)
    refused(lambda: promote(service, record, pending), "has not accepted the invitation yet")


def test_a_different_employee_code_is_refused(service, record):
    draft = person("ana")
    refused(lambda: promote(service, record, draft, None, "ZZ999"), "keeps employee code A101")


def test_resend_mails_the_same_code_while_open_and_refuses_after_the_person_accepts(
        app, client, mailbox, invite_url, service, record):
    first = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_ana", name="Ana Tan",
                                      email="ana@example.com", employee_code="ADM100")
    assert first["state"] == "invited"
    assert len(mail_jobs(client)) == 1
    again = service.resend_first_admin_invitation(record, ANA, actor=OWNER_STAFF)
    assert again["resent"] is True
    assert again["invitation"]["code"] == first["invitation"]["code"]
    assert len(mail_jobs(client)) == 2
    assert first_admin_state(company(PROJECT_A), "ana@example.com")["state"] == "invited"
    reply = redeem_email(app, mailbox, first["invitation"], "ana@example.com")
    assert reply.status_code == 200, reply.text
    jobs_before = len(mail_jobs(client))
    refused(lambda: service.resend_first_admin_invitation(record, ANA, actor=OWNER_STAFF),
            "Ana already accepted. Nothing to resend.")
    assert len(mail_jobs(client)) == jobs_before
    assert first_admin_state(company(PROJECT_A), "ana@example.com")["state"] == "active"


def test_resend_with_no_earlier_invitation_is_refused(service, record):
    refused(lambda: service.resend_first_admin_invitation(record, ANA, actor=OWNER_STAFF),
            "No invitation was sent yet")


def test_resend_of_an_expired_invitation_makes_a_new_code_and_later_grants_use_it(
        app, client, mailbox, invite_url, service, record):
    first = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_ana", name="Ana Tan",
                                      email="ana@example.com", employee_code="ADM100")
    client.collection("invitations").document(first["invitation"]["invitationId"]).update(
        {"expiresAt": datetime.now(timezone.utc) - timedelta(minutes=1)})
    renewed = service.resend_first_admin_invitation(record, ANA, actor=OWNER_STAFF)
    assert renewed["invitation"]["code"] != first["invitation"]["code"]
    old = client.collection("invitations").document(first["invitation"]["invitationId"]).get().to_dict()
    assert old["status"] == "revoked"
    new_id = renewed["invitation"]["invitationId"]
    assert client.collection("invitations").document(new_id).get().to_dict()["status"] == "open"
    same = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_ana", name="Ana Tan",
                                     email="ana@example.com", employee_code="ADM100")
    assert same["invitation"]["code"] == renewed["invitation"]["code"]
    reply = redeem_email(app, mailbox, renewed["invitation"], "ana@example.com")
    assert reply.status_code == 200, reply.text
    assert access_doc(renewed["uid"])["role"] == "admin"


def test_the_state_reader_reports_each_state(invite_url, service, record):
    access = company(PROJECT_A)
    assert first_admin_state(access, "ana@example.com")["state"] == "missing"
    create_auth_user(PROJECT_A, "ana")
    assert first_admin_state(access, "ana@example.com")["state"] == "missing"
    write_member(PROJECT_A, "ana", "salesman", code="A101")
    blocked = first_admin_state(access, "Ana@Example.com")
    assert blocked["state"] == "blocked" and blocked["uid"] == "ana"
    assert "Salesperson" in blocked["line"]
    access.db.collection("user_access").document("ana").update({"role": "admin"})
    assert first_admin_state(access, "ana@example.com")["state"] == "active"
    access.db.collection("user_access").document("ana").update({"status": "suspended", "isActive": False})
    assert first_admin_state(access, "ana@example.com")["state"] == "blocked"
    access.db.collection("user_access").document("ana").update({"status": "active", "isActive": True})
    access.auth.update_user("ana", disabled=True)
    assert first_admin_state(access, "ana@example.com")["state"] == "blocked"
    sent = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_bo", name="Bo Lim",
                                     email="bo@example.com", employee_code="ADM200")
    invited = first_admin_state(access, "bo@example.com")
    assert invited["state"] == "invited" and invited["uid"] == sent["uid"]


def test_promoting_a_corrected_admin_email_closes_the_earlier_invitation(
        app, client, mailbox, invite_url, service, record):
    first = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_ana", name="Ana Tan",
                                      email="ana@example.com", employee_code="ADM100")
    draft = {**person("bo"), "draftId": "drf_ana", "adminName": "Bo Lim"}
    preview = promote(service, record, draft)
    promote(service, record, draft, preview["expectedRow"])
    assert client.collection("invitations").document(first["invitation"]["invitationId"]).get().to_dict()["status"] == "revoked"
    reply = app.post("/v1/invitations/email-code", json={"code": first["invitation"]["code"], "check": "ana@example.com"})
    assert reply.status_code == 410, reply.text
    assert access_doc("bo")["role"] == "admin"


def test_giving_access_again_to_the_first_email_after_a_correction_makes_a_new_invitation(
        app, client, mailbox, invite_url, service, record):
    first = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_ana", name="Ana Tan",
                                      email="ana@example.com", employee_code="ADM100")
    create_auth_user(PROJECT_A, "bo")
    write_member(PROJECT_A, "bo", "admin", code="B200")
    corrected = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_ana", name="Bo Lim",
                                          email="bo@example.com", employee_code="B200")
    assert corrected["state"] == "active"
    back = service.grant_first_admin(record, actor=OWNER_STAFF, draft_id="drf_ana", name="Ana Tan",
                                     email="ana@example.com", employee_code="ADM100")
    assert back["state"] == "invited"
    stored = client.collection("invitations").document(back["invitation"]["invitationId"]).get().to_dict()
    assert stored["status"] == "open"
    assert back["invitation"]["invitationId"] != first["invitation"]["invitationId"]
    reply = redeem_email(app, mailbox, back["invitation"], "ana@example.com")
    assert reply.status_code == 200, reply.text
    assert access_doc(back["uid"])["role"] == "admin"

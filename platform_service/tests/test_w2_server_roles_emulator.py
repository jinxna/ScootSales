from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import account_links, config
from platform_service.account_security import watch_passwords
from platform_service.company_access import _project_auth as project_auth
from platform_service.commands import CommandProblem
from platform_service.directory import DirectoryError
from platform_service.mail import STAFF_MAIL_TENANT, SUPPRESSIONS, MailQueue, StubTransport, address_key
from platform_service.mail_events import DeliveryEvent, record_event
from platform_service.operations import OperationStore
from platform_service.payments import PaymentLedger
from platform_service.signing import format_timestamp
from platform_service.staff import SESSIONS, STAFF, digest, staff_id
from platform_service.support import SupportConsent, SupportProblem
from platform_service.tenant_binding import verified_binding
from platform_service.tests.support import CHECKER, CLERK
from platform_service.tests.test_boundary_regressions_emulator import (  # noqa: F401
    AMOUNT, ENGINEER, INVOICE, OPERATOR, OTHER, OWNER, RECEIVED, TENANT, assertion, headers, pytestmark,
    company_base, put_company, staff_settings, world)

BOTH = (TENANT, OTHER)


def test_fix219_only_the_owner_or_the_engineer_who_started_a_company_change_can_try_it_again(world, assertion):
    store = OperationStore(world.db)
    for tenant in BOTH:
        owner_op = store.begin(idempotency_key=f"owner-put-{tenant}", action="directory.put", actor=OWNER,
                               tenant_id=tenant, reason="Rename", ticket=None, field_names=["legalName"],
                               params={"tenantId": tenant, "expectedVersion": 1, "record": {}},
                               step_names=["store_record"])
        engineer_op = store.begin(idempotency_key=f"engineer-put-{tenant}", action="directory.put", actor=ENGINEER,
                                  tenant_id=tenant, reason="Ring", ticket=None, field_names=["releaseRing"],
                                  params={"tenantId": tenant, "expectedVersion": 1, "record": {}},
                                  step_names=["store_record"])
        for who in (OPERATOR, ENGINEER):
            refused = world.app.post(f"/staff/v1/operations/{owner_op}/retry", headers=headers(assertion, who))
            assert refused.status_code == 403, (tenant, who, refused.text)
        assert world.app.post(f"/staff/v1/operations/{owner_op}/retry",
                              headers=headers(assertion, OWNER)).status_code != 403
        assert world.app.post(f"/staff/v1/operations/{engineer_op}/retry",
                              headers=headers(assertion, OPERATOR)).status_code == 403
        assert world.app.post(f"/staff/v1/operations/{engineer_op}/retry",
                              headers=headers(assertion, OWNER)).status_code != 403
    record = world.store.get(TENANT)
    renamed = put_company(world, assertion, OWNER, record, record["version"], "owner-rename-0001", legalName="Renamed")
    assert renamed.status_code == 200, renamed.text
    replay = put_company(world, assertion, ENGINEER, record, record["version"], "owner-rename-0001",
                         legalName="Renamed")
    assert replay.status_code == 403 and "someone else" in replay.json()["detail"], replay.text


def held_staff_invite(world, secret, *, recipient="newperson@example.com", status="invited"):
    identifier = staff_id(recipient)
    now = datetime.now(timezone.utc)
    world.db.collection(STAFF).document(identifier).set(
        {"email": recipient, "name": "New", "role": "support", "status": status, "invitedBy": OWNER,
         "inviteHash": digest(secret), "inviteExpiresAt": format_timestamp(now + timedelta(hours=24)),
         "createdAt": format_timestamp(now), "updatedAt": format_timestamp(now)})
    queue = MailQueue(world.db)
    job = queue.enqueue(
        STAFF_MAIL_TENANT, f"invite-{identifier}-{secret[:8]}", "staff_invite", recipient,
        {"tenantId": STAFF_MAIL_TENANT, "inviteUrl": f"https://staff.example.test/#staffInvite={identifier}.{secret}",
         "expiresAt": format_timestamp(now + timedelta(hours=24)), "role": "support", "invitedBy": OWNER}, OWNER)
    world.db.collection("mail_jobs").document(job["jobId"]).update(
        {"status": "held", "heldReason": "provider_unavailable", "heldAt": format_timestamp(now)})
    return identifier, job["jobId"]


def test_fix221_a_held_staff_invitation_is_released_only_by_the_owner_and_only_while_it_is_open(world, assertion):
    identifier, job_id = held_staff_invite(world, "s" * 40)
    refused = world.app.post(f"/staff/v1/mail/held/{job_id}/retry", headers=headers(assertion, OPERATOR))
    assert refused.status_code == 403 and "owner" in refused.json()["detail"]
    assert world.db.collection("mail_jobs").document(job_id).get().to_dict()["status"] == "held"
    revoked_id, revoked_job = held_staff_invite(world, "r" * 40, recipient="revoked@example.com", status="disabled")
    gone = world.app.post(f"/staff/v1/mail/held/{revoked_job}/retry", headers=headers(assertion, OWNER))
    assert gone.status_code == 409 and "revoked or has expired" in gone.json()["detail"]
    assert world.db.collection("mail_jobs").document(revoked_job).get().to_dict()["status"] == "held"
    sent = world.app.post(f"/staff/v1/mail/held/{job_id}/retry", headers=headers(assertion, OWNER))
    assert sent.status_code == 200, sent.text
    assert world.db.collection("mail_jobs").document(job_id).get().to_dict()["status"] == "queued"


def test_fix218_one_person_with_two_emails_cannot_record_and_check_the_same_payment(world):
    now = datetime.now(timezone.utc)
    ledger = PaymentLedger(world.db, clock=lambda: now, mail=MailQueue(world.db, clock=lambda: now, enabled=False))
    for tenant in BOTH:
        body = {"amountMinor": AMOUNT, "currency": "MYR", "externalReference": f"BANK/{tenant}", "invoiceId": INVOICE[tenant],
                "receivedAt": RECEIVED, "reason": "Manual bank confirmation"}
        receipt = ledger.record(tenant, f"pay-{tenant}-0001", body, CLERK, person="uid-person-one")
        with pytest.raises(CommandProblem, match="Another person"):
            ledger.check(tenant, receipt["entryId"], "clerk.second@example.test", person="uid-person-one")
        assert ledger.check(tenant, receipt["entryId"], CHECKER, person="uid-person-two")


def test_fix045_an_invoice_period_far_in_the_future_is_refused(world, assertion):
    now = datetime.now(timezone.utc)
    for tenant in BOTH:
        far = world.app.post(f"/staff/v1/companies/{tenant}/invoices",
                             json={"periodStart": format_timestamp(now + timedelta(days=400))},
                             headers=headers(assertion, OPERATOR, f"far-{tenant}-0001"))
        assert far.status_code == 400 and "62 days" in far.json()["detail"], far.text
        near = world.app.post(f"/staff/v1/companies/{tenant}/invoices",
                              json={"periodStart": format_timestamp(now + timedelta(days=30))},
                              headers=headers(assertion, OPERATOR, f"near-{tenant}-0001"))
        assert near.status_code == 201, near.text


def _watched_owner(world, mail_enabled):
    import json
    import urllib.request
    toolkit = f"http://{os.environ['FIREBASE_AUTH_EMULATOR_HOST']}/identitytoolkit.googleapis.com/v1"
    uid = "staff-owner-" + uuid.uuid4().hex[:8]
    request = urllib.request.Request(
        f"{toolkit}/projects/{world.project}/accounts", method="POST",
        data=json.dumps({"localId": uid, "email": OWNER, "password": "first-password-1", "emailVerified": True}).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer owner"})
    urllib.request.urlopen(request).read()
    now = datetime.now(timezone.utc)
    world.db.collection(STAFF).document(staff_id(OWNER)).set(
        {"email": OWNER, "name": "owner", "role": "owner", "status": "active", "uid": uid,
         "createdAt": format_timestamp(now)})
    mail = MailQueue(world.db, enabled=mail_enabled)

    def session(created_at):
        handle = digest("fix053-" + uuid.uuid4().hex)
        world.db.collection(SESSIONS).document(handle).set(
            {"uid": uid, "email": OWNER, "authTime": format_timestamp(created_at), "createdAt": format_timestamp(created_at),
             "expiresAt": format_timestamp(created_at + timedelta(hours=12)), "status": "active", "userAgent": "test",
             "ip": "127.0.0.1", "deviceHash": None})
        return world.db.collection(SESSIONS).document(handle)

    def watch():
        return watch_passwords(world.db, mail, directory=world.store, access_for=lambda location: None,
                               staff_auth=lambda: project_auth(world.project))

    return uid, session, watch


def test_fix053_a_password_change_ends_only_the_sessions_that_existed_before_it(world):
    uid, session, watch = _watched_owner(world, True)
    before = session(datetime.now(timezone.utc) - timedelta(hours=1))
    watch()
    project_auth(world.project).update_user(uid, password="second-password-2")
    after = session(datetime.now(timezone.utc) + timedelta(minutes=1))
    watch()
    assert before.get().to_dict()["status"] == "ended"
    assert after.get().to_dict()["status"] == "active"


def test_fix053_sessions_end_after_a_password_change_even_when_mail_is_off(world):
    uid, session, watch = _watched_owner(world, False)
    before = session(datetime.now(timezone.utc) - timedelta(hours=1))
    watch()
    project_auth(world.project).update_user(uid, password="second-password-2")
    result = watch()
    assert "skipped" not in result and result["checked"] >= 1
    assert before.get().to_dict()["status"] == "ended"
    assert watch()["checked"] >= 1 and before.get().to_dict()["status"] == "ended"


def test_fix141_a_company_binding_is_checked_against_the_real_clock_and_the_version_floor(world):
    long_ago = datetime.now(timezone.utc) - timedelta(days=400)
    record = world.store.get(TENANT)
    world.store.put(company_base(record), expected_version=record["version"], now=long_ago)
    stale = world.db.collection("companies").document(TENANT).get().to_dict()
    envelope = {key: stale[key] for key in ("alg", "keyId", "payload", "signature")}
    with pytest.raises(DirectoryError) as expired:
        verified_binding(world.store.keyring, envelope)
    assert "expired on" in str(expired.value) and "binding file" in str(expired.value)
    current = world.db.collection("companies").document(OTHER).get().to_dict()
    fresh = {key: current[key] for key in ("alg", "keyId", "payload", "signature")}
    assert verified_binding(world.store.keyring, fresh)["tenantId"] == OTHER
    with pytest.raises(DirectoryError):
        verified_binding(world.store.keyring, fresh, floor=current["version"] + 1)


def test_fix140_the_account_link_limit_is_kept_per_company_and_per_action(world, monkeypatch):
    monkeypatch.setattr(account_links, "RESPONSE_FLOOR_SECONDS", 0)
    monkeypatch.setattr(config, "ACCOUNT_LINK_ADDRESS_LIMIT_PER_HOUR", 2)
    path = "/v1/w/{}/auth/{}"
    body = {"email": "victim@example.test"}
    codes = [world.app.post(path.format("northwind", "password-reset"), json=body).status_code for _ in range(3)]
    assert codes == [202, 202, 429]
    assert world.app.post(path.format("northwind", "email-verification"), json=body).status_code == 202
    assert world.app.post(path.format("southridge", "password-reset"), json=body).status_code == 202


def test_n29_one_company_at_its_network_link_limit_does_not_stop_another(world, monkeypatch):
    monkeypatch.setattr(account_links, "RESPONSE_FLOOR_SECONDS", 0)
    monkeypatch.setattr(config, "ACCOUNT_LINK_NETWORK_LIMIT_PER_HOUR", 2)
    path = "/v1/w/{}/auth/password-reset"
    codes = [world.app.post(path.format("northwind"), json={"email": f"p{n}@example.test"}).status_code
             for n in range(6)]
    assert codes == [202, 202, 429, 429, 429, 429]
    assert world.app.post(path.format("southridge"), json={"email": "q@example.test"}).status_code == 202
    assert world.app.post("/staff/v1/password-reset", json={"email": "owner@example.com"}).status_code == 202


def test_unknown_workspaces_share_one_link_bucket_at_the_base_limit(world, monkeypatch):
    monkeypatch.setattr(account_links, "RESPONSE_FLOOR_SECONDS", 0)
    monkeypatch.setattr(config, "ACCOUNT_LINK_NETWORK_LIMIT_PER_HOUR", 2)
    path = "/v1/w/{}/auth/password-reset"
    reads = []
    original = world.store.find_by_workspace
    monkeypatch.setattr(world.store, "find_by_workspace", lambda name: reads.append(name) or original(name))
    assert world.app.post(path.format("northwind"), json={"email": "k@example.test"}).status_code == 202
    assert reads == ["northwind"]
    invented = [world.app.post(path.format(f"nowhere{n}"), json={"email": f"r{n}@example.test"}).status_code
                for n in range(6)]
    assert invented == [202, 202, 429, 429, 429, 429]


def test_sv_one_address_gets_six_reset_mails_a_day_and_one_company_cannot_use_up_another(world, monkeypatch):
    monkeypatch.setattr(account_links, "RESPONSE_FLOOR_SECONDS", 0)
    moment = {"now": datetime(2031, 3, 10, 0, 30, tzinfo=timezone.utc)}
    first_hour = moment["now"]

    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return moment["now"]

    monkeypatch.setattr(account_links, "datetime", Clock)
    for tenant in BOTH:
        world.db.collection("lifecycle").document(tenant).set({"state": "active"})
        company_project = world.store.get(tenant)["location"]["projectId"]
        company_db = firestore.Client(project=company_project, credentials=AnonymousCredentials())
        for name in ("one", "two"):
            user = project_auth(company_project).create_user(
                uid=f"sv-{name}", email=f"{name}@example.test", email_verified=True)
            company_db.collection("user_access").document(user.uid).set(
                {"accessVersion": 2, "uid": user.uid, "status": "active", "role": "admin"})
    _watched_owner(world, True)

    def mails(tenant):
        return sum(1 for row in world.db.collection("mail_jobs").stream() if row.to_dict()["tenantId"] == tenant)

    def ask(path, email, hours):
        moment["now"] = first_hour + timedelta(hours=hours)
        return world.app.post(path, json={"email": email})

    for path, tenant, email in (("/v1/w/northwind/auth/password-reset", TENANT, "one@example.test"),
                                ("/staff/v1/password-reset", STAFF_MAIL_TENANT, OWNER)):
        before = mails(tenant)
        assert [ask(path, email, hour).status_code for hour in range(6)] == [202] * 6
        assert mails(tenant) == before + 6
        refused = ask(path, email, 6)
        assert refused.status_code == 429 and refused.json()["detail"] == "Too many requests. Try again later."
        assert mails(tenant) == before + 6
        assert ask(path, email, 24).status_code == 202
        assert mails(tenant) == before + 7
    other_before, same_before = mails(OTHER), mails(TENANT)
    assert ask("/v1/w/southridge/auth/password-reset", "one@example.test", 6).status_code == 202
    assert ask("/v1/w/northwind/auth/password-reset", "two@example.test", 6).status_code == 202
    assert (mails(OTHER), mails(TENANT)) == (other_before + 1, same_before + 1)


def test_fix217_a_staff_member_in_the_middle_of_accepting_cannot_be_turned_off(world, assertion):
    identifier = staff_id("joining@example.com")
    now = datetime.now(timezone.utc)
    world.db.collection(STAFF).document(identifier).set(
        {"email": "joining@example.com", "name": "Joining", "role": "support", "status": "accepting",
         "acceptingAt": format_timestamp(now), "acceptNonce": "n", "inviteHash": digest("x" * 40),
         "inviteExpiresAt": format_timestamp(now + timedelta(hours=1)), "createdAt": format_timestamp(now),
         "updatedAt": format_timestamp(now)})
    refused = world.app.post(f"/staff/v1/staff/{identifier}/disable", headers=headers(assertion, OWNER))
    assert refused.status_code == 409 and "accepting" in refused.json()["detail"]
    assert "up to 10 minutes" in refused.json()["detail"]
    assert world.db.collection(STAFF).document(identifier).get().to_dict()["status"] == "accepting"
    world.db.collection(STAFF).document(identifier).update(
        {"acceptingAt": format_timestamp(now - timedelta(minutes=30))})
    assert world.app.post(f"/staff/v1/staff/{identifier}/disable", headers=headers(assertion, OWNER)).status_code == 200


def test_fix143_a_support_grant_replayed_after_a_revoke_shows_revoked_and_an_old_grant_shows_expired(world):
    now = datetime.now(timezone.utc)
    clock = {"now": now}
    for tenant in BOTH:
        service = SupportConsent(world.db, tenant, clock=lambda: clock["now"])
        body = {"staffEmail": "support@example.com", "scope": "diagnostics", "reason": "Look at sync",
                "expiresAt": format_timestamp(now + timedelta(minutes=30))}
        created = service.create("admin-uid", "grant-key-0001", body)
        service.revoke("admin-uid", created["grantId"], "revoke-key-0001", "Done", 1)
        replay = service.create("admin-uid", "grant-key-0001", body)
        assert replay["status"] == "revoked"
        second = service.create("admin-uid", "grant-key-0002", body)
        clock["now"] = now + timedelta(minutes=45)
        assert service.create("admin-uid", "grant-key-0002", body)["status"] == "expired"
        clock["now"] = now
        assert second["status"] == "active"


def held_past_due(world, tenant, recipient, reason):
    queue = MailQueue(world.db)
    job = queue.enqueue(tenant, f"held-{tenant}-{address_key(recipient)[:12]}", "past_due", recipient,
                        {"tenantId": tenant, "companyName": "Northwind"}, "scheduler")
    world.db.collection("mail_jobs").document(job["jobId"]).update(
        {"status": "held", "heldReason": reason, "heldAt": format_timestamp(datetime.now(timezone.utc))})
    return job["jobId"]


def job_status(world, job_id):
    return world.db.collection("mail_jobs").document(job_id).get().to_dict()["status"]


def test_fix030_a_held_mail_marked_handled_is_not_sent_the_next_day(world, assertion):
    handled = held_past_due(world, TENANT, "billing1@northwind.test", "daily_cap")
    other = held_past_due(world, OTHER, "billing1@southridge.test", "daily_cap")
    marked = world.app.post(f"/staff/v1/mail/held/{handled}/handled", headers=headers(assertion, OPERATOR))
    assert marked.status_code == 200, marked.text
    MailQueue(world.db).release_held(datetime.now(timezone.utc) + timedelta(days=1))
    assert job_status(world, handled) == "held"
    assert job_status(world, other) == "queued"


def test_fix214_lifting_a_mail_block_releases_the_mail_it_held(world, assertion):
    blocked = "blocked@northwind.test"
    mine = held_past_due(world, TENANT, blocked, "recipient_suppressed")
    elsewhere = held_past_due(world, OTHER, "other@southridge.test", "recipient_suppressed")
    world.db.collection(SUPPRESSIONS).document(address_key(blocked)).set(
        {"suppressionId": address_key(blocked), "tenantId": TENANT, "status": "active", "reason": "hard_bounce",
         "recipientHint": "b***@northwind.test", "kind": "past_due", "since": RECEIVED, "lastEventAt": RECEIVED})
    lifted = world.app.post(f"/staff/v1/mail/suppressions/{address_key(blocked)}/lift",
                            json={"reason": "Address fixed"}, headers=headers(assertion, OPERATOR))
    assert lifted.status_code == 200, lifted.text
    assert job_status(world, mine) == "queued"
    assert job_status(world, elsewhere) == "held"


SHARED = "shared@northwind.test"


def queued_for(world, tenant, tag):
    job = MailQueue(world.db).enqueue(tenant, f"t8-{tenant}-{tag}", "past_due", SHARED,
                                      {"tenantId": tenant, "companyName": "Northwind"}, "scheduler")
    return job["jobId"]


def mail_event(world, tenant, job_id, key, status, at):
    return record_event(world.db, DeliveryEvent(key=key, status=status, at=format_timestamp(at), email=SHARED,
                                                message_id="", job_hint=job_id, reason=""))


def attempt(world, tenant, job_id):
    MailQueue(world.db).deliver(tenant, job_id, "t8", StubTransport(path=None, ids={"past_due": 1}))
    return job_status(world, job_id)


def lift(world, assertion, record_id):
    response = world.app.post(f"/staff/v1/mail/suppressions/{record_id}/lift", json={"reason": "Address fixed"},
                              headers=headers(assertion, OPERATOR))
    assert response.status_code == 200, response.text


def test_t8a_a_complaint_to_one_company_does_not_block_the_same_address_for_another(world):
    now = datetime.now(timezone.utc)
    first, second = queued_for(world, TENANT, "a1"), queued_for(world, OTHER, "a1")
    assert mail_event(world, TENANT, first, "t8a-spam", "spam", now) == "accepted"
    assert attempt(world, OTHER, second) != "held"
    assert attempt(world, TENANT, queued_for(world, TENANT, "a2")) == "held"


def test_t8b_a_lift_of_a_complaint_leaves_an_earlier_hard_bounce_in_force(world, assertion):
    now = datetime.now(timezone.utc)
    first, second = queued_for(world, TENANT, "b1"), queued_for(world, OTHER, "b1")
    mail_event(world, TENANT, first, "t8b-bounce", "hard_bounce", now)
    mail_event(world, TENANT, first, "t8b-spam", "spam", now + timedelta(seconds=1))
    assert attempt(world, TENANT, first) == "held" and attempt(world, OTHER, second) == "held"
    complaint = [row for row in world.db.collection(SUPPRESSIONS).stream() if row.to_dict()["reason"] == "spam"][0]
    lift(world, assertion, complaint.id)
    assert job_status(world, first) == "held" and job_status(world, second) == "held"
    assert world.db.collection("mail_jobs").document(first).get().to_dict()["attempts"] == 0


def test_t8c_a_lift_for_one_company_releases_only_that_companys_mail(world, assertion):
    now = datetime.now(timezone.utc)
    first, second = queued_for(world, TENANT, "c1"), queued_for(world, OTHER, "c1")
    mail_event(world, TENANT, first, "t8c-a", "spam", now)
    mail_event(world, OTHER, second, "t8c-b", "spam", now)
    assert attempt(world, TENANT, first) == "held" and attempt(world, OTHER, second) == "held"
    own = [row for row in world.db.collection(SUPPRESSIONS).stream() if row.to_dict()["tenantId"] == TENANT][0]
    lift(world, assertion, own.id)
    assert job_status(world, first) == "queued" and job_status(world, second) == "held"


def test_t8d_an_old_global_complaint_record_holds_every_company_until_lifted(world, assertion):
    world.db.collection(SUPPRESSIONS).document(address_key(SHARED)).set(
        {"suppressionId": address_key(SHARED), "tenantId": TENANT, "status": "active", "reason": "spam",
         "recipientHint": "s***@northwind.test", "kind": "past_due", "since": RECEIVED, "lastEventAt": RECEIVED})
    first, second = queued_for(world, TENANT, "d1"), queued_for(world, OTHER, "d1")
    assert attempt(world, TENANT, first) == "held" and attempt(world, OTHER, second) == "held"
    lift(world, assertion, address_key(SHARED))
    assert job_status(world, first) == "queued" and job_status(world, second) == "queued"


def test_t8e_a_complaint_older_than_the_lift_does_not_block_again(world, assertion):
    now = datetime.now(timezone.utc)
    first = queued_for(world, TENANT, "e1")
    mail_event(world, TENANT, first, "t8e-new", "spam", now)
    own = [row for row in world.db.collection(SUPPRESSIONS).stream()][0]
    lift(world, assertion, own.id)
    mail_event(world, TENANT, first, "t8e-old", "spam", now - timedelta(hours=1))
    assert world.db.collection(SUPPRESSIONS).document(own.id).get().to_dict()["status"] == "lifted"

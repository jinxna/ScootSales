from __future__ import annotations

import base64
import html
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

from fastapi.testclient import TestClient
from firebase_admin import auth as admin_auth
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import config, invitations, staff_api
from platform_service.company_access import company_access
from platform_service.directory import DirectoryStore
from platform_service.invitations import InvitationService
from platform_service.mail import MailQueue, StubTransport, deliver_mail
from platform_service.operations import OperationStore, Step, operation_id
from platform_service.signing import Keyring, Signer, b64url_encode

from .support import seed_subscription, seed_usage

PASSWORD = "secret-pass-1"
SECRET = b64url_encode(os.urandom(32))
PROJECT_A, PROJECT_B = "demo-company-a", "demo-company-b"
COMPANY_PROJECTS = (PROJECT_A, PROJECT_B)
WRONG_CODE = "ZZZZ-ZZZZ-ZZZZ"
OWNER = {"Authorization": "Bearer owner"}
NOT_VALID = "The invitation code or check is not valid."


class SimulatedCrash(BaseException):
    pass


def _call(method, url, body=None, headers=None):
    request = urllib.request.Request(
        url,
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={"Content-Type": "application/json", **(headers or {})},
    )
    return json.loads(urllib.request.urlopen(request).read().decode() or "{}")


def _auth_url(path):
    return f"http://{os.environ['FIREBASE_AUTH_EMULATOR_HOST']}{path}"


def _toolkit(path):
    return _auth_url(f"/identitytoolkit.googleapis.com/v1/{path}")


def sign_in_password(project, email, password):
    return _call(
        "POST",
        _toolkit("accounts:signInWithPassword?key=fake"),
        {"targetProjectId": project, "email": email, "password": password, "returnSecureToken": True},
        OWNER,
    )


def create_auth_user(project, uid, password=PASSWORD):
    email = f"{uid}@example.com"
    _call(
        "POST",
        _toolkit(f"projects/{project}/accounts"),
        {"localId": uid, "email": email, "password": password},
        OWNER,
    )
    return email


def id_token(project, uid):
    return sign_in_password(project, f"{uid}@example.com", PASSWORD)["idToken"]


def jwt_claims(token):
    segment = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def location(project):
    return {"projectId": project, "databaseId": "(default)", "authTenantId": None}


def company(project):
    return company_access(location(project))


@pytest.fixture(autouse=True)
def clean_emulators(monkeypatch):
    monkeypatch.setenv(config.INVITE_SECRET_ENV, SECRET)
    monkeypatch.setattr(config, "CLIENT_CORS_ORIGINS", ())
    monkeypatch.setattr(config, "CLIENT_IP_HEADER", "")
    firestore_host = os.environ["FIRESTORE_EMULATOR_HOST"]
    for project in (config.PLATFORM_PROJECT_ID, *COMPANY_PROJECTS):
        documents = (
            f"http://{firestore_host}/emulator/v1/projects/{project}/databases/(default)/documents"
        )
        urllib.request.urlopen(urllib.request.Request(documents, method="DELETE")).read()
    for project in COMPANY_PROJECTS:
        _call("DELETE", _auth_url(f"/emulator/v1/projects/{project}/accounts"))


@pytest.fixture
def client():
    return firestore.Client(project=config.PLATFORM_PROJECT_ID, credentials=AnonymousCredentials())


@pytest.fixture
def signer():
    return Signer.generate("invite-key-1")


@pytest.fixture
def store(client, signer):
    return DirectoryStore(
        client, keyring=Keyring({signer.key_id: signer.public_key()}), signer=signer
    )


@pytest.fixture
def app(store):
    return TestClient(staff_api.create_app(store=store))


def make_record(name, project):
    return {
        "tenantId": f"t_{name}",
        "workspace": name,
        "legalName": f"{name.title()} Foods Sdn Bhd",
        "companyCode": name,
        "location": location(project),
        "locationKind": "byo",
        "clientConfig": {
            "apiKey": {"android": "AIza" + "A" * 35, "web": "AIza" + "B" * 35},
            "appId": {
                "android": "1:222222222222:android:aaaaaaaaaaaaaaaa",
                "web": "1:222222222222:web:cccccccccccccccc",
            },
            "messagingSenderId": "222222222222",
        },
        "status": "live",
        "planRef": "standard",
        "releaseRing": "general",
        "rulesVersion": "r1",
    }


def write_member(project, uid, role, *, code, status="active", branch="BR1", codes=None):
    db = company(project).db
    db.collection("users").document(code).set(
        {"uid": uid, "employeeCode": code, "role": role, "status": status, "name": code}
    )
    access = {
        "accessVersion": 2, "uid": uid, "userDocId": code, "employeeCode": code,
        "role": role, "status": status, "isActive": status == "active",
        "branchId": "" if role == "admin" else branch, "email": f"{uid}@example.com",
    }
    if codes is not None:
        access["assignedSalesmanCodes"] = codes
    db.collection("user_access").document(uid).set(access)
    seed_usage(db)


@pytest.fixture
def world(store, client):
    store.put(make_record("northwind", PROJECT_A), expected_version=0)
    store.put(make_record("southridge", PROJECT_B), expected_version=0)
    for tenant in ("t_northwind", "t_southridge"):
        seed_subscription(client, tenant)
        client.collection("lifecycle").document(tenant).set({"state": "active", "revision": 1})
    for project, uid, role, code in (
        (PROJECT_A, "admin-a", "admin", "A001"),
        (PROJECT_A, "sales-a", "salesman", "S001"),
        (PROJECT_B, "admin-b", "admin", "B001"),
    ):
        create_auth_user(project, uid)
        write_member(project, uid, role, code=code)
    return {
        "admin": id_token(PROJECT_A, "admin-a"),
        "sales": id_token(PROJECT_A, "sales-a"),
        "other_admin": id_token(PROJECT_B, "admin-b"),
    }


def invite(app, token, *, workspace="northwind", key=None, **changes):
    body = {
        "displayName": "Aisha Rahman", "role": "salesman", "employeeCode": "s100",
        "branchId": "BR1", "email": None, "phone": "+60 12-345 6789", "supervisorUid": None,
    }
    body.update(changes)
    headers = {"Idempotency-Key": key or uuid.uuid4().hex}
    if token:
        headers.update(bearer(token))
    return app.post(f"/v1/w/{workspace}/invitations", headers=headers, json=body)


def redeem(app, code, check="6789", *, password="correct-horse-1", device="Samsung A15", **extra):
    return app.post(
        "/v1/invitations/redeem",
        json={"code": code, "check": check, "password": password, "device": device, **extra},
    )


@pytest.fixture
def mailbox(monkeypatch, tmp_path):
    path = tmp_path / "mail.jsonl"
    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    monkeypatch.setenv("PLATFORM_MAIL_TRANSPORT", "stub")
    monkeypatch.setenv("PLATFORM_MAIL_STUB_FILE", str(path))
    return path


def sent_mail(mailbox):
    if not mailbox.exists():
        return []
    return [json.loads(line) for line in mailbox.read_text(encoding="utf-8").splitlines()]


def ask_email_code(app, mailbox, made, check):
    reply = app.post("/v1/invitations/email-code", json={"code": made["code"], "check": check})
    assert reply.status_code == 200, reply.text
    typed = re.search(r"verification code is (\d{6})", sent_mail(mailbox)[-1]["rendered"]["text"])
    return typed.group(1)


def redeem_email(app, mailbox, made, check, **extra):
    return redeem(app, made["code"], check, emailCode=ask_email_code(app, mailbox, made, check), **extra)


def listing(app, token, workspace="northwind"):
    reply = app.get(f"/v1/w/{workspace}/invitations", headers=bearer(token))
    assert reply.status_code == 200, reply.text
    return reply.json()["invitations"]


def invitation_doc(client, invitation_id):
    return client.collection("invitations").document(invitation_id).get().to_dict()


def auth_user_exists(project, email):
    try:
        company(project).auth.get_user_by_email(email)
        return True
    except admin_auth.UserNotFoundError:
        return False






def mail_jobs(client):
    return {snapshot.id: snapshot.to_dict() for snapshot in client.collection("mail_jobs").stream()}


def test_email_invitation_queues_one_mail_even_when_retried(app, client, world, monkeypatch):
    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    monkeypatch.setenv(invitations.INVITE_URL_ENV, "https://join.example.test/start")
    first = invite(app, world["admin"], key="mail-key-0001", email="Aisha@Example.com", phone=None)
    again = invite(app, world["admin"], key="mail-key-0001", email="Aisha@Example.com", phone=None)
    assert first.status_code == again.status_code == 201
    made = first.json()
    jobs = mail_jobs(client)
    assert len(jobs) == 1
    job = next(iter(jobs.values()))
    assert job["kind"] == "invitation" and job["tenantId"] == "t_northwind"
    assert job["recipient"] == "aisha@example.com"
    assert job["payload"] == {
        "tenantId": "t_northwind", "companyName": "Northwind Foods Sdn Bhd",
        "inviteUrl": f"https://join.example.test/start#invite={made['qrPayload']}", "expiresAt": made["expiresAt"]}
    assert invitation_doc(client, made["invitationId"])["mail"] == {
        "status": "queued", "reason": None, "jobId": job["jobId"]}


























def test_redeem_in_progress_is_refused_and_a_dead_lease_may_retry(app, client, world):
    made = invite(app, world["admin"]).json()
    reference = client.collection("invitations").document(made["invitationId"])
    soon = datetime.now(timezone.utc) + timedelta(minutes=4)
    reference.update({"status": "redeeming", "redeemLeaseUntil": soon})
    live = redeem(app, made["code"])
    assert live.status_code == 410 and live.json()["detail"] == "This invitation was already used."

    reference.update({"redeemLeaseUntil": datetime.now(timezone.utc) - timedelta(minutes=1)})
    assert redeem(app, made["code"]).status_code == 200
    assert reference.get().to_dict()["status"] == "redeemed"


















def test_only_active_admins_of_the_company_may_manage(app, client, world):
    assert invite(app, world["sales"]).status_code == 403
    assert invite(app, world["other_admin"]).status_code == 403
    assert invite(app, world["admin"], workspace="southridge").status_code == 403
    assert invite(app, None).status_code == 401
    assert invite(app, "not-a-token").status_code == 401
    for method, path in (
        ("GET", "/v1/w/northwind/invitations"),
        ("GET", "/v1/w/northwind/accounts/reconcile"),
        ("POST", f"/v1/w/northwind/invitations/{'0' * 32}/revoke"),
        ("POST", "/v1/w/northwind/accounts/sales-a/revoke"),
    ):
        assert app.request(method, path, headers=bearer(world["sales"])).status_code == 403, path
        assert app.request(method, path).status_code == 401, path
        assert app.request(method, path, headers=bearer(world["other_admin"])).status_code == 403, path

    company(PROJECT_A).db.collection("user_access").document("admin-a").update({"status": "suspended"})
    assert invite(app, world["admin"]).status_code == 403
    assert client.collection("invitations").limit(1).get() == []
    assert not auth_user_exists(PROJECT_A, "s100@t-northwind.invalid")


def test_same_key_returns_the_same_invitation_and_code(app, client, world):
    first = invite(app, world["admin"], key="idem-key-0001")
    again = invite(app, world["admin"], key="idem-key-0001")
    assert first.status_code == again.status_code == 201
    assert first.json() == again.json()
    assert len(list(client.collection("invitations").stream())) == 1
    users = [u for u in company(PROJECT_A).auth.list_users().iterate_all() if u.uid.startswith("inv")]
    assert len(users) == 1

    different = invite(app, world["admin"], key="idem-key-0001", displayName="Someone Else")
    assert different.status_code == 409
    assert invite(app, world["admin"], key="idem-key-0002").status_code == 409
    assert invite(app, world["other_admin"], workspace="southridge", key="idem-key-0001").status_code == 201


def test_duplicate_email_or_employee_code_is_409_before_anything_is_created(app, client, world):
    assert invite(app, world["admin"], email="aisha@example.com", phone=None).status_code == 201
    before = len(list(company(PROJECT_A).auth.list_users().iterate_all()))
    assert invite(app, world["admin"], employeeCode="S200", email="AISHA@example.com", phone=None).status_code == 409
    assert invite(app, world["admin"], employeeCode="S100", email="other@example.com", phone=None).status_code == 409
    assert invite(app, world["admin"], employeeCode="s001").status_code == 409
    assert invite(app, world["admin"], employeeCode="S300", email="sales-a@example.com", phone=None).status_code == 409
    assert len(list(company(PROJECT_A).auth.list_users().iterate_all())) == before
    assert len(list(client.collection("invitations").stream())) == 1


def forget_claims(db):
    for snapshot in db.collection("employee_codes").stream():
        snapshot.reference.delete()
    db.collection("config").document("employee_code_claims").delete()












def test_other_company_is_refused_without_consuming_the_code(app, client, world):
    made = invite(app, world["admin"]).json()
    mismatch = redeem(app, made["code"], projectId=PROJECT_B)
    assert mismatch.status_code == 409
    assert mismatch.json() == {
        "detail": "This invitation is for another company. Change company first."
    }
    stored = invitation_doc(client, made["invitationId"])
    assert stored["status"] == "open" and stored["failures"] == 0
    assert company(PROJECT_A).auth.get_user(made["uid"]).disabled

    wrong = redeem(app, made["code"], "0000", projectId=PROJECT_B)
    assert wrong.status_code == 403 and wrong.json() == {"detail": NOT_VALID}
    assert invitation_doc(client, made["invitationId"])["failures"] == 1

    ok = redeem(app, made["code"], projectId=PROJECT_A)
    assert ok.status_code == 200, ok.text
    assert ok.json()["projectId"] == PROJECT_A






def move(app, token, uid, supervisor_uid, *, key=None):
    headers = {**bearer(token), "Idempotency-Key": key or uuid.uuid4().hex}
    return app.post(f"/v1/w/northwind/accounts/{uid}/supervisor", headers=headers,
                    json={"supervisorUid": supervisor_uid})


def link(project, uid, supervisor_uid, supervisor_code):
    company(project).db.collection("user_access").document(uid).update(
        {"supervisorUid": supervisor_uid, "supervisorId": supervisor_code}
    )


def access_doc(uid, project=PROJECT_A):
    return company(project).db.collection("user_access").document(uid).get().to_dict()


def roster(uid):
    return access_doc(uid).get("assignedSalesmanCodes")


def move_events(client, kind):
    return [row.to_dict() for row in client.collection("audit_events").stream()
            if row.to_dict()["action"] == kind and row.to_dict()["refs"].get("operationAction") == "account.move"]




def test_move_is_refused_for_a_full_supervisor_another_branch_or_a_non_salesperson(app, world):
    write_member(PROJECT_A, "sup-1", "supervisor", code="SUP1", codes=["S001"])
    write_member(PROJECT_A, "sup-full", "supervisor", code="SUP3", codes=["S2", "S3", "S4", "S5", "S6"])
    write_member(PROJECT_A, "sup-far", "supervisor", code="SUP4", branch="BR2", codes=[])
    write_member(PROJECT_A, "sup-off", "supervisor", code="SUP5", status="suspended", codes=[])
    link(PROJECT_A, "sales-a", "sup-1", "SUP1")

    refusals = {
        ("sales-a", "sup-full"): "already has 5 salespeople",
        ("sales-a", "sup-far"): "another branch",
        ("sales-a", "sup-off"): "not an active supervisor",
        ("sales-a", "nobody"): "not an active supervisor",
        ("sup-1", "sup-full"): "Only a salesperson",
    }
    for (uid, target), text in refusals.items():
        reply = move(app, world["admin"], uid, target)
        assert reply.status_code == 409 and text in reply.json()["detail"], (uid, target, reply.text)
    assert move(app, world["sales"], "sales-a", "sup-full").status_code == 403
    assert move(app, world["admin"], "admin-a", "sup-1").status_code == 409
    assert move(app, world["admin"], "ghost", "sup-1").status_code == 404
    assert move(app, world["admin"], "sales-a", "bad/uid").status_code in (400, 404)

    assert access_doc("sales-a")["supervisorUid"] == "sup-1"
    assert roster("sup-1") == ["S001"] and roster("sup-full") == ["S2", "S3", "S4", "S5", "S6"]
    assert roster("sup-far") == [] and roster("sup-off") == []




def test_two_moves_into_the_last_place_admit_one(app, world):
    write_member(PROJECT_A, "sup-4", "supervisor", code="SUP4", codes=["S2", "S3", "S4", "S5"])
    for uid, code in (("sales-x", "S010"), ("sales-y", "S011")):
        write_member(PROJECT_A, uid, "salesman", code=code)
    with ThreadPoolExecutor(max_workers=2) as pool:
        replies = list(pool.map(lambda uid: move(app, world["admin"], uid, "sup-4"), ["sales-x", "sales-y"]))
    assert sorted(reply.status_code for reply in replies) == [200, 409], [reply.text for reply in replies]
    assert len(roster("sup-4")) == 5


def change_code(app, token, uid, code, *, key=None):
    headers = {**bearer(token), "Idempotency-Key": key or uuid.uuid4().hex}
    return app.post(f"/v1/w/northwind/accounts/{uid}/employee-code", headers=headers, json={"employeeCode": code})


@pytest.mark.parametrize("sent", ["S0002", "s0002"])
def test_saving_the_same_code_in_another_letter_case_changes_nothing(app, world, sent):
    write_member(PROJECT_A, "sales-c", "salesman", code="s0002")
    db = company(PROJECT_A).db
    db.collection("orders").document("ORD-sales-c").set({"salesmanUid": "sales-c", "salesmanCode": "s0002"})
    index_before = db.collection("user_access").document("sales-c").get().to_dict()
    profile_before = db.collection("users").document("s0002").get().to_dict()
    reply = change_code(app, world["admin"], "sales-c", sent)
    assert reply.status_code == 200, reply.text
    assert reply.json()["employeeCode"] == "s0002"
    assert db.collection("user_access").document("sales-c").get().to_dict() == index_before
    assert db.collection("users").document("s0002").get().to_dict() == profile_before
    assert not db.collection("users").document("S0002").get().exists


def test_two_accounts_cannot_take_the_same_new_code_together(app, world):
    write_member(PROJECT_A, "sales-b", "salesman", code="S002")
    with ThreadPoolExecutor(max_workers=2) as pool:
        replies = list(pool.map(lambda uid: change_code(app, world["admin"], uid, "S555"), ["sales-a", "sales-b"]))
    assert sorted(reply.status_code for reply in replies) == [200, 409], [reply.text for reply in replies]


def _wrap_step(monkeypatch, step_name, replace):
    original = InvitationService.create_steps

    def create_steps(self):
        steps = original(self)
        for index, step in enumerate(steps):
            if step.name == step_name:
                steps[index] = Step(step.name, replace(step.apply), step.check)
        return steps

    monkeypatch.setattr(InvitationService, "create_steps", create_steps)


def _recovery(client, store, signer):
    runner = OperationStore(client)
    service = InvitationService(client, runner, store, secret=invitations.load_secret())
    return runner, service, staff_api.build_actions(client, store, signer, service)


def test_crash_after_the_auth_user_is_finished_by_recovery_with_the_same_code(
    app, client, store, signer, monkeypatch, world, mailbox
):
    crashed = {"done": False}

    def crash_once(apply):
        def run(ctx):
            if not crashed["done"]:
                crashed["done"] = True
                raise SimulatedCrash()
            return apply(ctx)

        return run

    _wrap_step(monkeypatch, "write_profile", crash_once)
    key = "idem-key-crash-1"
    with pytest.raises(SimulatedCrash):
        invite(app, world["admin"], key=key, email="aisha@example.com", phone=None)

    op_id = operation_id("invitation.create", f"northwind:{key}")
    access = company(PROJECT_A)
    uid = invitations.derive_uid(op_id)
    assert access.auth.get_user(uid).disabled
    assert not access.db.collection("user_access").document(uid).get().exists
    assert OperationStore(client).get(op_id)["status"] == "pending"

    assert invite(app, world["admin"], key=key, email="aisha@example.com", phone=None).status_code == 409

    runner, service, actions = _recovery(client, store, signer)
    later = datetime.now(timezone.utc) + timedelta(seconds=config.OPERATION_LEASE_SECONDS + 60)
    assert runner.recover(actions, now=later) == [op_id]
    assert runner.get(op_id)["status"] == "completed"

    retry = invite(app, world["admin"], key=key, email="aisha@example.com", phone=None)
    assert retry.status_code == 201, retry.text
    expected = invitations.format_code(invitations.derive_code(service._secret(), op_id))
    assert retry.json()["code"] == expected and retry.json()["uid"] == uid
    matching = [u for u in access.auth.list_users().iterate_all() if u.email == "aisha@example.com"]
    assert len(matching) == 1
    assert redeem_email(app, mailbox, {"code": expected}, "aisha@example.com").status_code == 200


def test_permanent_failure_after_the_auth_step_leaves_no_orphan(app, client, monkeypatch, world):
    write_member(PROJECT_A, "sup-1", "supervisor", code="SUP1", codes=[])

    def fail(apply):
        def run(ctx):
            raise ValueError("boom")

        return run

    with monkeypatch.context() as patch:
        _wrap_step(patch, "create_code", fail)
        key = "idem-key-fail-1"
        failed = invite(app, world["admin"], key=key, email="aisha@example.com", phone=None, supervisorUid="sup-1")
        assert failed.status_code == 502
        assert "boom" not in failed.text

    access = company(PROJECT_A)
    op_id = operation_id("invitation.create", f"northwind:{key}")
    record = OperationStore(client).get(op_id)
    assert record["status"] == "failed" and record["cleanedUp"] is True
    assert not auth_user_exists(PROJECT_A, "aisha@example.com")
    assert not access.db.collection("users").document("S100").get().exists
    assert not access.db.collection("user_access").document(invitations.derive_uid(op_id)).get().exists
    assert access.db.collection("user_access").document("sup-1").get().to_dict()["assignedSalesmanCodes"] == []
    assert list(client.collection("invitations").stream()) == []
    assert invite(app, world["admin"], key=key, email="aisha@example.com", phone=None, supervisorUid="sup-1").status_code == 502
    assert invite(app, world["admin"], email="aisha@example.com", phone=None).status_code == 201




def test_interrupted_account_revoke_is_finished_by_recovery(app, client, store, signer, monkeypatch, world):
    made = invite(app, world["admin"]).json()
    redeem(app, made["code"])
    crashed = {"done": False}
    original = InvitationService.revoke_account_steps

    def steps(self):
        built = original(self)
        for index, step in enumerate(built):
            if step.name == "suspend_records":
                apply = step.apply

                def run(ctx, apply=apply):
                    if not crashed["done"]:
                        crashed["done"] = True
                        raise SimulatedCrash()
                    return apply(ctx)

                built[index] = Step(step.name, run, step.check)
        return built

    monkeypatch.setattr(InvitationService, "revoke_account_steps", steps)
    with pytest.raises(SimulatedCrash):
        app.post(f"/v1/w/northwind/accounts/{made['uid']}/revoke", headers=bearer(world["admin"]))
    access = company(PROJECT_A)
    assert not access.auth.get_user(made["uid"]).disabled
    assert access.db.collection("user_access").document(made["uid"]).get().to_dict()["status"] == "active"

    runner, _, actions = _recovery(client, store, signer)
    later = datetime.now(timezone.utc) + timedelta(seconds=config.OPERATION_LEASE_SECONDS + 60)
    assert len(runner.recover(actions, now=later)) == 1
    assert access.db.collection("user_access").document(made["uid"]).get().to_dict()["status"] == "suspended"
    assert access.db.collection("users").document("S100").get().to_dict()["isActive"] is False
    assert access.auth.get_user(made["uid"]).disabled






def profile_doc(doc_id, project=PROJECT_A):
    return company(project).db.collection("users").document(doc_id).get().to_dict()










def test_a_salesperson_cannot_take_a_supervisor_of_another_branch_by_role_change(app, world):
    write_member(PROJECT_A, "sup-far", "supervisor", code="SUP4", branch="BR2", codes=[])
    reply = app.post("/v1/w/northwind/accounts/sales-a/role",
                     headers={**bearer(world["admin"]), "Idempotency-Key": uuid.uuid4().hex},
                     json={"role": "salesman", "branchId": "BR1", "supervisorUid": "sup-far"})
    assert reply.status_code >= 400 and "another branch" in reply.text
    assert roster("sup-far") == []
    invited = invite(app, world["admin"], employeeCode="s300", phone="+60 12-345 2222",
                     branchId="BR1", supervisorUid="sup-far")
    assert invited.status_code >= 400 and roster("sup-far") == []








def remove_account(app, token, uid, *, key=None):
    headers = {**bearer(token), "Idempotency-Key": key or uuid.uuid4().hex}
    return app.post(f"/v1/w/northwind/accounts/{uid}/remove", headers=headers)


def record_order(project, uid, code, number="ORD-1"):
    company(project).db.collection("orders").document(number).set(
        {"orderId": number, "salesmanUid": uid, "salesmanCode": code, "totalPrice": 10.0})


def test_a_retired_code_in_one_company_never_blocks_the_same_code_in_another(app, world):
    record_order(PROJECT_A, "sales-a", "S001")
    assert remove_account(app, world["admin"], "sales-a").status_code == 200
    assert invite(app, world["admin"], employeeCode="s001", phone="+60 12-345 6003").status_code == 409
    other = invite(app, world["other_admin"], workspace="southridge", employeeCode="s001", phone="+60 12-345 6004")
    assert other.status_code == 201, other.text


def test_fix263_a_person_with_only_tracking_data_keeps_their_code_retired(app, world):
    for project, uid, code in ((PROJECT_A, "sales-a", "S001"),):
        db = company(project).db
        db.collection("gps_tracking").document("fix-1").set(
            {"uid": uid, "salesmanUid": uid, "salesmanCode": code, "latitude": 1.5535, "longitude": 110.3593})
        db.collection("live_tracking").document(uid).set(
            {"uid": uid, "salesmanUid": uid, "salesmanCode": code, "latitude": 1.5535, "longitude": 110.3593})
    assert remove_account(app, world["admin"], "sales-a").status_code == 200
    claim = company(PROJECT_A).db.collection("employee_codes").document("S001").get().to_dict() or {}
    assert claim.get("retired") is True
    assert invite(app, world["admin"], employeeCode="s001", phone="+60 12-345 7001").status_code == 409
    other = invite(app, world["other_admin"], workspace="southridge", employeeCode="s001", phone="+60 12-345 7002")
    assert other.status_code == 201, other.text


def test_fix286_an_order_recorded_after_the_history_check_still_retires_the_code(app, world, monkeypatch):
    original = InvitationService._remove_records

    def order_arrives_first(self, params):
        record_order(PROJECT_A, "sales-a", "S001")
        return original(self, params)

    monkeypatch.setattr(InvitationService, "_remove_records", order_arrives_first)
    assert remove_account(app, world["admin"], "sales-a").status_code == 200
    claim = company(PROJECT_A).db.collection("employee_codes").document("S001").get().to_dict() or {}
    assert claim.get("retired") is True
    assert invite(app, world["admin"], employeeCode="s001", phone="+60 12-345 7003").status_code == 409


def derived_email(code):
    return f"{code}@t-northwind.invalid"


def redeemed_salesperson(app, world, code="s100"):
    made = invite(app, world["admin"], employeeCode=code).json()
    assert redeem(app, made["code"], "6789").status_code == 200
    return made


def test_removing_a_person_with_no_work_frees_the_email_for_a_new_user(app, world):
    made = redeemed_salesperson(app, world)
    assert remove_account(app, world["admin"], made["uid"]).status_code == 200
    assert not auth_user_exists(PROJECT_A, derived_email("s100"))
    again = invite(app, world["admin"], employeeCode="s100")
    assert again.status_code == 201, again.text
    assert again.json()["uid"] != made["uid"]


def test_removing_a_person_with_work_keeps_the_sign_in_disabled(app, world):
    made = redeemed_salesperson(app, world)
    record_order(PROJECT_A, made["uid"], "S100")
    assert remove_account(app, world["admin"], made["uid"]).status_code == 200
    assert company(PROJECT_A).auth.get_user(made["uid"]).disabled


def test_the_same_remove_request_sent_again_after_the_sign_in_was_deleted_still_succeeds(app, world):
    made = redeemed_salesperson(app, world)
    assert remove_account(app, world["admin"], made["uid"], key="same-key").status_code == 200
    assert remove_account(app, world["admin"], made["uid"], key="same-key").status_code == 200
    assert remove_account(app, world["admin"], made["uid"]).status_code == 404


@pytest.mark.parametrize("worked", [False, True])
def test_an_invitation_reuses_a_leftover_disabled_sign_in_and_its_history(app, world, worked):
    access = company(PROJECT_A)
    access.auth.create_user(uid="ghost", email=derived_email("s102"), disabled=True)
    if worked:
        record_order(PROJECT_A, "ghost", "G1")
    made = invite(app, world["admin"], employeeCode="s102", role="supervisor")
    assert made.status_code == 201, made.text
    assert made.json()["uid"] == "ghost"
    assert redeem(app, made.json()["code"], "6789").status_code == 200
    assert not access.auth.get_user("ghost").disabled
    row = access.db.collection("user_access").document("ghost").get().to_dict()
    assert (row["role"], row["employeeCode"], row["status"]) == ("supervisor", "S102", "active")
    assert sign_in_password(PROJECT_A, derived_email("s102"), "correct-horse-1")["localId"] == "ghost"
    if worked:
        assert access.db.collection("orders").document("ORD-1").get().to_dict()["salesmanUid"] == "ghost"


def test_a_removed_person_with_work_is_invited_again_on_the_same_sign_in(app, world, mailbox):
    first = invite(app, world["admin"], email="aisha@example.com", phone=None, employeeCode="s100").json()
    assert redeem_email(app, mailbox, first, "aisha@example.com").status_code == 200
    record_order(PROJECT_A, first["uid"], "S100")
    assert remove_account(app, world["admin"], first["uid"]).status_code == 200
    again = invite(app, world["admin"], email="aisha@example.com", phone=None, employeeCode="s105", role="supervisor")
    assert again.status_code == 201, again.text
    assert again.json()["uid"] == first["uid"]


def test_a_rehired_person_whose_work_is_filed_only_under_the_old_code_keeps_the_sign_in_on_a_second_removal(
        app, world, mailbox):
    first = invite(app, world["admin"], email="aisha@example.com", phone=None, employeeCode="s100").json()
    assert redeem_email(app, mailbox, first, "aisha@example.com").status_code == 200
    record_order(PROJECT_A, "", "S100")
    assert remove_account(app, world["admin"], first["uid"]).status_code == 200
    again = invite(app, world["admin"], email="aisha@example.com", phone=None, employeeCode="s106").json()
    assert again["uid"] == first["uid"]
    assert redeem_email(app, mailbox, again, "aisha@example.com", password="correct-horse-2").status_code == 200
    assert remove_account(app, world["admin"], first["uid"]).status_code == 200
    assert company(PROJECT_A).auth.get_user(first["uid"]).disabled


def test_an_order_recorded_after_the_history_check_keeps_the_sign_in(app, world, monkeypatch):
    made = redeemed_salesperson(app, world)
    original = InvitationService._remove_records

    def order_arrives_first(self, params):
        record_order(PROJECT_A, made["uid"], "S100")
        return original(self, params)

    monkeypatch.setattr(InvitationService, "_remove_records", order_arrives_first)
    assert remove_account(app, world["admin"], made["uid"]).status_code == 200
    assert company(PROJECT_A).auth.get_user(made["uid"]).disabled


def test_a_sign_in_with_no_account_record_is_kept_when_its_profile_code_has_orders(app, world):
    access = company(PROJECT_A)
    access.auth.create_user(uid="legacy-7", email="legacy7@example.com")
    access.db.collection("users").document("G7").set({"uid": "legacy-7", "employeeCode": "G7", "role": "salesman"})
    record_order(PROJECT_A, "", "G7")
    assert remove_account(app, world["admin"], "legacy-7").status_code == 200
    assert access.auth.get_user("legacy-7").disabled
    again = invite(app, world["admin"], employeeCode="g7", phone="+60 12-345 7009")
    assert again.status_code == 409 and "used before by someone else" in again.text, again.text


def test_a_sign_in_whose_profile_holds_its_code_in_an_older_field_is_kept_when_that_code_has_orders(app, world):
    access = company(PROJECT_A)
    access.auth.create_user(uid="legacy-8", email="legacy8@example.com")
    access.db.collection("users").document("legacy8@example.com").set({"uid": "legacy-8", "staffId": "G8", "role": "salesman"})
    record_order(PROJECT_A, "", "G8")
    assert remove_account(app, world["admin"], "legacy-8").status_code == 200
    assert access.auth.get_user("legacy-8").disabled


def test_an_open_invitation_keeps_its_disabled_sign_in_when_the_email_is_invited_again(app, world):
    first = invite(app, world["admin"], email="aisha@example.com", phone=None, employeeCode="s100").json()
    again = invite(app, world["admin"], email="aisha@example.com", phone=None, employeeCode="s101")
    assert again.status_code == 409 and "sign-in email is already in use" in again.text
    assert company(PROJECT_A).auth.get_user(first["uid"]).disabled
    assert company(PROJECT_A).db.collection("user_access").document(first["uid"]).get().exists


def test_a_suspended_person_keeps_the_email_when_it_is_invited_again(app, world):
    reply = app.post("/v1/w/northwind/accounts/sales-a/revoke", headers=bearer(world["admin"]))
    assert reply.status_code == 200, reply.text
    again = invite(app, world["admin"], email="sales-a@example.com", phone=None, employeeCode="s103")
    assert again.status_code == 409 and "sign-in email is already in use" in again.text
    assert company(PROJECT_A).auth.get_user("sales-a").disabled


def remove_profile(app, token, doc_id, *, key=None):
    headers = {**bearer(token), "Idempotency-Key": key or uuid.uuid4().hex}
    return app.post(f"/v1/w/northwind/profiles/{doc_id}/remove", headers=headers)


def seed_profile(doc_id, **fields):
    company(PROJECT_A).db.collection("users").document(doc_id).set(
        {"employeeCode": doc_id, "name": doc_id, "role": "salesman", "branchId": "BR1", **fields})


def test_removing_a_profile_with_no_sign_in_deletes_it_its_team_places_and_branch_link(app, world):
    db = company(PROJECT_A).db
    seed_profile("M100", role="branch_manager")
    write_member(PROJECT_A, "sup-a", "supervisor", code="SUP1", codes=["m100", "S009"])
    db.collection("users").document("SUP1").update({"assignedSalesmanCodes": ["M100", "S009"]})
    db.collection("branches").document("BR1").set({"name": "Kuching", "branchManagerId": "m100"})
    db.collection("branches").document("BR2").set({"name": "Miri", "branchManagerId": "S001"})
    reply = remove_profile(app, world["admin"], "M100")
    assert reply.status_code == 200, reply.text
    assert reply.json() == {"docId": "M100", "status": "removed"}
    assert not db.collection("users").document("M100").get().exists
    assert db.collection("user_access").document("sup-a").get().to_dict()["assignedSalesmanCodes"] == ["S009"]
    assert db.collection("users").document("SUP1").get().to_dict()["assignedSalesmanCodes"] == ["S009"]
    assert "branchManagerId" not in db.collection("branches").document("BR1").get().to_dict()
    assert db.collection("branches").document("BR2").get().to_dict()["branchManagerId"] == "S001"
    assert remove_profile(app, world["admin"], "M100").status_code == 404


def test_removing_a_profile_whose_code_has_work_keeps_the_code_retired(app, world):
    seed_profile("M101")
    record_order(PROJECT_A, "", "M101")
    assert remove_profile(app, world["admin"], "M101").status_code == 200
    claim = company(PROJECT_A).db.collection("employee_codes").document("M101").get().to_dict() or {}
    assert claim.get("retired") is True


def test_a_profile_that_has_a_sign_in_a_linked_access_record_or_salespeople_is_not_removed(app, world):
    db = company(PROJECT_A).db
    seed_profile("U1", uid="some-uid")
    seed_profile("U2")
    db.collection("user_access").document("linked").set({"uid": "linked", "userDocId": "U2", "employeeCode": "U2"})
    seed_profile("U3", role="supervisor", assignedSalesmanCodes=["S001"])
    seed_profile("U4", email="sales-a@example.com")
    for doc_id in ("U1", "U2", "U3", "U4"):
        reply = remove_profile(app, world["admin"], doc_id)
        assert reply.status_code == 409, (doc_id, reply.text)
        assert db.collection("users").document(doc_id).get().exists
    assert "Move them to another supervisor first." in remove_profile(app, world["admin"], "U3").text


def test_only_an_active_admin_may_remove_a_profile(app, world):
    seed_profile("U5")
    assert remove_profile(app, world["sales"], "U5").status_code == 403
    assert company(PROJECT_A).db.collection("users").document("U5").get().exists


def test_fix287_an_invitation_that_expires_during_the_redeem_hold_does_not_join(app, client, world, monkeypatch):
    made = invite(app, world["admin"]).json()
    original = InvitationService._finish_redeem

    def expires_first(self, reference, data, password, device):
        reference.update({"expiresAt": datetime.now(timezone.utc) - timedelta(minutes=1)})
        return original(self, reference, data, password, device)

    monkeypatch.setattr(InvitationService, "_finish_redeem", expires_first)
    late = redeem(app, made["code"])
    assert late.status_code == 410, late.text
    assert late.json()["detail"] == "This invitation has expired. Ask your administrator for a new one."
    assert invitation_doc(client, made["invitationId"])["status"] != "redeemed"
    assert company(PROJECT_A).auth.get_user(made["uid"]).disabled


def test_fix213_an_expired_invitation_gives_back_its_seat_and_is_marked_expired(app, client, world):
    made = invite(app, world["admin"]).json()
    client.collection("invitations").document(made["invitationId"]).update(
        {"expiresAt": datetime.now(timezone.utc) - timedelta(minutes=1)})
    again = invite(app, world["admin"], displayName="Bala Kumar", employeeCode="s101")
    assert again.status_code in (200, 201), again.text
    assert invitation_doc(client, made["invitationId"])["status"] == "expired"
    held = access_doc(made["uid"])
    assert held["invitationState"] == "expired" and held["seatHeld"] is False
    invite(app, world["admin"], displayName="Chen Wei", employeeCode="s102")
    assert access_doc(made["uid"])["invitationState"] == "expired"


def test_fix213_an_invitation_whose_seat_was_already_freed_is_marked_expired_without_freeing_it_again(
        app, client, world):
    made = invite(app, world["admin"]).json()
    client.collection("invitations").document(made["invitationId"]).update(
        {"expiresAt": datetime.now(timezone.utc) - timedelta(days=3)})
    db = company(PROJECT_A).db
    db.collection("user_access").document(made["uid"]).update({"seatHeld": False})
    seats_before = db.collection("config").document("usage").get().to_dict()["seats"]["salesmen"]
    again = invite(app, world["admin"], displayName="Bala Kumar", employeeCode="s101")
    assert again.status_code in (200, 201), again.text
    assert invitation_doc(client, made["invitationId"])["status"] == "expired"
    held = access_doc(made["uid"])
    assert held["invitationState"] == "expired" and held["seatHeld"] is False
    assert db.collection("config").document("usage").get().to_dict()["seats"]["salesmen"] == seats_before + 1


def test_n29_wrong_tries_and_lookups_for_one_company_do_not_stop_another_company(app, client, world, monkeypatch):
    monkeypatch.setattr(config, "REDEEM_LIMIT_PER_HOUR", 2)
    monkeypatch.setattr(config, "COMPANY_LOOKUP_LIMIT_PER_HOUR", 2)
    first = invite(app, world["admin"]).json()
    other = invite(app, world["other_admin"], workspace="southridge")
    assert other.status_code in (200, 201), other.text
    assert [redeem(app, first["code"], "0000").status_code for _ in range(3)] == [403, 403, 429]
    assert redeem(app, other.json()["code"], projectId=PROJECT_B).status_code == 200
    assert [redeem(app, "2222-3333-4444").status_code for _ in range(3)] == [403, 403, 429]
    assert [app.get("/v1/companies/northwind").status_code for _ in range(3)] == [200, 200, 429]
    assert app.get("/v1/companies/southridge").status_code == 200
    assert [app.get("/v1/companies/nosuchco").status_code for _ in range(3)] == [404, 404, 429]


def test_unknown_code_guesses_use_the_network_total_so_a_real_code_is_refused_too(app, client, world, monkeypatch):
    monkeypatch.setattr(config, "REDEEM_LIMIT_PER_HOUR", 2)
    monkeypatch.setattr(config, "COMPANY_LOOKUP_LIMIT_PER_HOUR", 2)
    first = invite(app, world["admin"]).json()
    guesses = [redeem(app, f"2222-3333-44{a}{b}").status_code for a in "23456789" for b in "2345"]
    assert len([code for code in guesses if code != 429]) <= 3 * config.REDEEM_LIMIT_PER_HOUR
    assert redeem(app, first["code"], "0000").status_code == 429
    assert redeem(app, first["code"]).status_code == 429
    lookups = [app.get(f"/v1/companies/nosuch{n}").status_code for n in range(20)]
    assert len([code for code in lookups if code != 429]) <= 3 * config.COMPANY_LOOKUP_LIMIT_PER_HOUR
    assert app.get("/v1/companies/northwind").status_code == 429
    assert app.get("/v1/companies/southridge").status_code == 429


def test_a_locked_invitation_stays_locked_after_the_sweep_and_still_answers_locked(app, client, world):
    made = invite(app, world["admin"]).json()
    for _ in range(5):
        redeem(app, made["code"], "0000")
    assert invitation_doc(client, made["invitationId"])["status"] == "locked"
    assert redeem(app, made["code"]).status_code == 423
    again = invite(app, world["admin"], displayName="Bala Kumar", employeeCode="s101")
    assert again.status_code in (200, 201), again.text
    assert invitation_doc(client, made["invitationId"])["status"] == "locked"
    assert access_doc(made["uid"])["seatHeld"] is False
    assert redeem(app, made["code"]).status_code == 423


def test_fix213_invite_again_after_the_sweep_expired_it_reuses_the_same_employee_code(app, client, world):
    made = invite(app, world["admin"]).json()
    client.collection("invitations").document(made["invitationId"]).update(
        {"expiresAt": datetime.now(timezone.utc) - timedelta(minutes=1)})
    sweep = invite(app, world["admin"], displayName="Bala Kumar", employeeCode="s101")
    assert sweep.status_code in (200, 201), sweep.text
    assert access_doc(made["uid"])["invitationState"] == "expired"
    revoked = app.post(f"/v1/w/northwind/invitations/{made['invitationId']}/revoke",
                       headers={"Idempotency-Key": uuid.uuid4().hex, **bearer(world["admin"])})
    assert revoked.status_code == 200, revoked.text
    again = invite(app, world["admin"])
    assert again.status_code in (200, 201), again.text
    assert access_doc(made["uid"]) is None


def test_first_admin_invitation_from_staff_redeems_and_then_reports_active(app, client, store, world, mailbox):
    service = InvitationService(client, OperationStore(client), store, secret=invitations.load_secret())
    record = store.get("t_northwind")

    def grant(code="ADM009"):
        return service.grant_first_admin(record, actor="owner@staff.example", draft_id="drf_first", name="Nadia Owner",
                                         email="Nadia@Example.com", employee_code=code)

    made = grant()
    assert (made["state"], made["path"]) == ("invited", "invitation")
    assert grant("ADM010")["invitation"]["code"] == made["invitation"]["code"]
    assert profile_doc("ADM010") is None
    reply = redeem_email(app, mailbox, made["invitation"], "nadia@example.com")
    assert reply.status_code == 200, reply.text
    row = access_doc(made["uid"])
    assert (row["role"], row["status"], row["invitationState"]) == ("admin", "active", "redeemed")
    assert grant() == {"state": "active", "path": "account", "uid": made["uid"], "invitation": None}
    signed_in = sign_in_password(PROJECT_A, "nadia@example.com", "correct-horse-1")
    assert signed_in["localId"] == made["uid"]


def test_first_admin_grant_resumes_after_a_crash_between_profile_and_activation(client, store, world, monkeypatch):
    create_auth_user(PROJECT_A, "byo-boss")
    service = InvitationService(client, OperationStore(client), store, secret=invitations.load_secret())
    record = store.get("t_northwind")
    usage = company(PROJECT_A).db.collection("config").document("usage")
    admins_before = usage.get().to_dict()["seats"]["admins"]

    def grant(code):
        return service.grant_first_admin(record, actor="owner@staff.example", draft_id="drf_boss", name="Byo Boss",
                                         email="byo-boss@example.com", employee_code=code)

    def crash(*args, **kwargs):
        raise SimulatedCrash()

    activate = InvitationService._activate_records
    monkeypatch.setattr(InvitationService, "_activate_records", crash)
    with pytest.raises(SimulatedCrash):
        grant("ADM020")
    monkeypatch.setattr(InvitationService, "_activate_records", activate)
    assert access_doc("byo-boss")["invitationState"] == "pending"
    assert grant("ADM021") == {"state": "active", "path": "account", "uid": "byo-boss", "invitation": None}
    row = access_doc("byo-boss")
    assert (row["status"], row["employeeCode"], row["invitationState"]) == ("active", "ADM020", "redeemed")
    assert profile_doc("ADM021") is None
    assert usage.get().to_dict()["seats"]["admins"] == admins_before + 1


def test_a_profile_linked_by_its_older_uid_field_is_not_removed_and_its_sign_in_is_not_reused(app, world):
    company(PROJECT_A).auth.create_user(uid="old-link", email=derived_email("s104"), disabled=True)
    seed_profile("L1", userUid="old-link")
    assert remove_profile(app, world["admin"], "L1").status_code == 409
    again = invite(app, world["admin"], employeeCode="s104")
    assert again.status_code == 409 and "sign-in email is already in use" in again.text


def test_a_supervisor_profile_with_an_older_role_spelling_and_salespeople_is_not_removed(app, world):
    seed_profile("SV9", role="Supervisor", assignedSalesmanCodes=["S001"])
    reply = remove_profile(app, world["admin"], "SV9")
    assert reply.status_code == 409 and "still has salespeople" in reply.text


def test_removing_a_sign_in_whose_profile_links_it_by_the_older_uid_field_deletes_the_profile(app, world):
    access = company(PROJECT_A)
    access.auth.create_user(uid="old-link-2", email="oldlink2@example.com")
    seed_profile("L2", userUid="old-link-2", uid=" ")
    assert remove_profile(app, world["admin"], "L2").status_code == 409
    assert remove_account(app, world["admin"], "old-link-2").status_code == 200
    assert not access.db.collection("users").document("L2").get().exists

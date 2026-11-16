from __future__ import annotations

import os
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

from firebase_admin import auth as admin_auth

from platform_service import config
from platform_service.account_deletion import DELETED_NAME, AccountDeletions
from platform_service.company_access import company_access
from platform_service.mail import MailQueue
from platform_service.operations import OperationStore

from .support import seed_usage
from .test_invitations_emulator import PASSWORD, _auth_url, _call, create_auth_user, location, sign_in_password

PROJECT = "demo-company-a"
TENANT = "t_northwind"
START = datetime.now(timezone.utc).replace(microsecond=0)


@pytest.fixture(autouse=True)
def clean_emulators():
    host = os.environ["FIRESTORE_EMULATOR_HOST"]
    for project in (config.PLATFORM_PROJECT_ID, PROJECT):
        urllib.request.urlopen(urllib.request.Request(
            f"http://{host}/emulator/v1/projects/{project}/databases/(default)/documents", method="DELETE")).read()
    _call("DELETE", _auth_url(f"/emulator/v1/projects/{PROJECT}/accounts"))


class World:
    def __init__(self):
        self.access = company_access(location(PROJECT))
        self.db = self.access.db
        self.now = START
        self.worker = AccountDeletions(
            self.access, TENANT, lambda: "Northwind Foods Sdn Bhd", runner=OperationStore(self.db),
            mail=MailQueue(self.db, enabled=True), clock=lambda: self.now)

    def member(self, uid, role, code, name, **extra):
        create_auth_user(PROJECT, uid)
        self.db.collection("users").document(code).set({
            "uid": uid, "employeeCode": code, "role": role, "status": "active", "name": name,
            "email": f"{uid}@example.com", "phone": "0123456789", "photoUrl": "data:image/png;base64,AAAA"})
        self.db.collection("user_access").document(uid).set({
            "accessVersion": 2, "uid": uid, "userDocId": code, "employeeCode": code, "role": role,
            "status": "active", "isActive": True, "seatHeld": True, "branchId": "" if role == "admin" else "BR1",
            "email": f"{uid}@example.com", **extra})

    def request(self, uid, status="submitted"):
        self.db.collection("privacy_deletion_requests").document(uid).set({
            "requestType": "account_deletion", "status": status, "createdAt": self.now})

    def set_status(self, uid, status):
        self.db.collection("privacy_deletion_requests").document(uid).update({"status": status})

    def access_doc(self, uid):
        return self.db.collection("user_access").document(uid).get().to_dict()

    def request_doc(self, uid):
        return self.db.collection("privacy_deletion_requests").document(uid).get().to_dict()

    def disabled(self, uid):
        return self.access.auth.get_user(uid).disabled

    def mail_jobs(self):
        return [row.to_dict() for row in self.db.collection("mail_jobs").stream()]

    def run(self, **options):
        return self.worker.run(apply=True, **options)

    def seats(self):
        return self.db.collection("config").document("usage").get().to_dict()["seats"]["salesmen"]


@pytest.fixture
def world():
    world = World()
    world.member("admin-a", "admin", "A001", "Alice Admin")
    world.member("sales-a", "salesman", "S001", "Aisha Rahman")
    world.member("sales-b", "salesman", "S002", "Bala Kumar")
    seed_usage(world.db)
    for uid, name in (("sales-a", "Aisha Rahman"), ("sales-b", "Bala Kumar")):
        world.db.collection("orders").document(f"ORD-{uid}").set({
            "orderId": f"ORD-{uid}", "salesmanUid": uid, "salesmanName": name, "submittedByName": name,
            "createdByName": name, "salesmanEmail": f"{uid}@example.com", "totalPrice": 10.0})
        world.db.collection("visits").document(f"V-{uid}").set({"ownerUid": uid, "salesmanName": name})
        world.db.collection("gps_tracking").document(f"G-{uid}").set({"salesmanUid": uid, "uid": uid, "latitude": 1.5})
        world.db.collection("live_tracking").document(uid).set({"uid": uid, "latitude": 1.5, "longitude": 110.3})
    return world


def sign_in_refused(uid):
    with pytest.raises(urllib.error.HTTPError) as refused:
        sign_in_password(PROJECT, f"{uid}@example.com", PASSWORD)
    return refused.value.code




def test_a_second_run_changes_nothing_and_sends_no_second_mail(world):
    world.request("sales-a")
    world.run()
    first = world.access_doc("sales-a")["deletionRequestedAt"]
    world.now += timedelta(hours=2)
    again = world.run()
    assert again["due"] == {"accept": [], "cancel": [], "shorten": [], "purge": []}
    assert world.access_doc("sales-a")["deletionRequestedAt"] == first
    assert len(world.mail_jobs()) == 1






def test_purge_before_thirty_days_does_nothing(world):
    world.request("sales-a")
    world.run()
    world.now += timedelta(days=29, hours=23)
    outcome = world.run()
    assert outcome["due"]["purge"] == []
    assert world.disabled("sales-a") is True
    assert world.access_doc("sales-a") is not None






def test_fix178_delete_now_hides_at_once_can_be_restored_for_seven_days_then_is_removed(world):
    world.request("sales-a")
    world.run()
    world.request("sales-b")
    world.set_status("sales-a", "completed")
    world.set_status("sales-b", "completed")
    world.run()
    for uid in ("sales-a", "sales-b"):
        assert world.disabled(uid) is True
        assert world.access_doc(uid) is not None
        assert world.request_doc(uid)["status"] == "reviewing"
        assert world.request_doc(uid)["purgeAfter"] <= world.now + timedelta(days=7)
    world.now += timedelta(days=6)
    world.run()
    assert world.access_doc("sales-a") is not None and world.access_doc("sales-b") is not None
    world.set_status("sales-b", "rejected")
    world.run()
    assert world.disabled("sales-b") is False
    world.now += timedelta(days=2)
    world.run()
    assert world.access_doc("sales-a") is None
    assert world.request_doc("sales-a")["purgedAt"]
    assert world.access_doc("sales-b") is not None and world.disabled("sales-b") is False


def test_a_request_changes_only_the_account_it_names_and_never_disables_an_administrator(world):
    world.request("admin-a")
    outcome = world.run()
    assert outcome["done"]["accept"] == []
    assert world.disabled("admin-a") is False and "disabledReasons" not in world.access_doc("admin-a")
    refused = world.request_doc("admin-a")
    assert refused["status"] == "rejected" and refused["serverNote"]
    assert world.mail_jobs() == []
    world.set_status("admin-a", "completed")
    world.run()
    assert world.access_doc("admin-a") is not None and world.disabled("admin-a") is False


def test_fix263_a_purged_person_with_only_tracking_data_keeps_their_code_retired(world):
    world.db.collection("orders").document("ORD-sales-a").delete()
    world.db.collection("visits").document("V-sales-a").delete()
    world.request("sales-a")
    world.run()
    world.now += timedelta(days=31)
    world.run()
    assert world.access_doc("sales-a") is None
    claim = world.db.collection("employee_codes").document("S001").get().to_dict() or {}
    assert claim.get("retired") is True
    assert list(world.db.collection("gps_tracking").where("salesmanUid", "==", "sales-a").stream()) == []


def test_n17_a_rejection_during_the_purge_stays_rejected(world, monkeypatch):
    world.request("sales-a")
    world.run()
    world.now += timedelta(days=31)
    original = AccountDeletions._remove_profile

    def reject_then_remove(self, uid):
        world.set_status(uid, "rejected")
        return original(self, uid)

    monkeypatch.setattr(AccountDeletions, "_remove_profile", reject_then_remove)
    world.run()
    assert world.request_doc("sales-a")["status"] == "rejected"
    assert not world.request_doc("sales-a").get("purgedAt")

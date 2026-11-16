from __future__ import annotations

import json
import os
import subprocess
import time
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service import client_api, config, staff_api
from platform_service.company_access import CompanyUnreachable
from platform_service.directory import COMPANIES, DirectoryStore
from platform_service.held_work import MAX_BODY_BYTES, receipt_id
from platform_service.operations import OperationStore
from platform_service.signing import Keyring, Signer
from platform_service.tests.support import staff_assertion, staff_domains

REPO_ROOT = Path(__file__).resolve().parents[2]
STAFF_EMAIL = "ops@example.com"
ENGINEER_EMAIL = "engineer@example.com"
PASSWORD = "secret-pass-1"
UID = "same-uid"
COMPANY_PROJECTS = ("demo-company-a", "demo-company-b", "demo-company-c", "demo-unknown")


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


def id_token(project, uid=UID):
    owner = {"Authorization": "Bearer owner"}
    email = f"{uid}@example.com"
    _call(
        "POST",
        _auth_url(f"/identitytoolkit.googleapis.com/v1/projects/{project}/accounts"),
        {"localId": uid, "email": email, "password": PASSWORD},
        owner,
    )
    reply = _call(
        "POST",
        _auth_url("/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake"),
        {"targetProjectId": project, "email": email, "password": PASSWORD, "returnSecureToken": True},
        owner,
    )
    return reply["idToken"]


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(autouse=True)
def clean_emulators():
    firestore_host = os.environ["FIRESTORE_EMULATOR_HOST"]
    documents = (
        f"http://{firestore_host}/emulator/v1/projects/{config.PLATFORM_PROJECT_ID}"
        "/databases/(default)/documents"
    )
    urllib.request.urlopen(urllib.request.Request(documents, method="DELETE")).read()
    for project in COMPANY_PROJECTS:
        _call("DELETE", _auth_url(f"/emulator/v1/projects/{project}/accounts"))


ROLES = {STAFF_EMAIL: "owner", ENGINEER_EMAIL: "engineer"}


@pytest.fixture(autouse=True)
def staff_settings(monkeypatch):
    monkeypatch.setattr(config, "STAFF_DOMAINS", staff_domains({*ROLES, "someone@example.com"}))
    monkeypatch.setattr(config, "CLIENT_CORS_ORIGINS", ())
    monkeypatch.setattr(client_api, "HEALTH_CACHE_SECONDS", 0)


@pytest.fixture
def assertion():
    return staff_assertion(ROLES)


@pytest.fixture
def staff_headers(assertion):
    return assertion(STAFF_EMAIL)


@pytest.fixture
def engineer_headers(assertion):
    return assertion(ENGINEER_EMAIL)


@pytest.fixture
def client():
    return firestore.Client(
        project=config.PLATFORM_PROJECT_ID, credentials=AnonymousCredentials()
    )


@pytest.fixture
def signer():
    return Signer.generate("api-key-1")


@pytest.fixture
def store(client, signer):
    keyring = Keyring({signer.key_id: signer.public_key()})
    return DirectoryStore(client, keyring=keyring, signer=signer)


@pytest.fixture
def operations(client):
    return OperationStore(client)


@pytest.fixture
def staff_app(store, operations, signer, client):
    return TestClient(
        staff_api.create_app(store=store, operations=operations, signer=signer, client=client),
    )


@pytest.fixture
def client_app(staff_app):
    return staff_app


def make_record(name, project, status="live", **overrides):
    record = {
        "tenantId": f"t_{name}",
        "workspace": name,
        "legalName": f"{name.title()} Foods Sdn Bhd",
        "companyCode": name,
        "location": {"projectId": project, "databaseId": "(default)", "authTenantId": None},
        "locationKind": "byo",
        "clientConfig": {
            "apiKey": {"android": "AIza" + "A" * 35, "web": "AIza" + "B" * 35},
            "appId": {
                "android": "1:222222222222:android:aaaaaaaaaaaaaaaa",
                "web": "1:222222222222:web:cccccccccccccccc",
            },
            "messagingSenderId": "222222222222",
            "storageBucket": f"{project}.firebasestorage.app",
        },
        "status": status,
        "planRef": "standard",
        "releaseRing": "general",
        "rulesVersion": "r1",
    }
    record.update(overrides)
    return record


def set_lifecycle(client, record, state="active"):
    client.collection("lifecycle").document(record["tenantId"]).set({"state": state, "revision": 1})
    return record


@pytest.fixture
def company_a(client):
    return set_lifecycle(client, make_record("northwind", "demo-company-a"))


@pytest.fixture
def company_b(client):
    return set_lifecycle(client, make_record("southridge", "demo-company-b"))


def put_body(record, expected_version=0, **extra):
    return {"record": record, "expectedVersion": expected_version, "reason": "Onboarding.", **extra}


def idem(key):
    return {"Idempotency-Key": key}


def test_tampered_record_is_refused_everywhere(store, client, client_app, company_a):
    store.put(company_a, expected_version=0)
    token = id_token("demo-company-a")
    assert client_app.get("/v1/companies/northwind").status_code == 200

    reference = client.collection(COMPANIES).document(company_a["tenantId"])
    payload = reference.get().to_dict()["payload"]
    reference.update({"payload": payload.replace("Northwind Foods", "Evil Foods")})

    assert client_app.get("/v1/companies/northwind").status_code == 503
    assert client_app.get("/v1/me", headers=bearer(token)).status_code == 503


def test_older_signed_record_put_back_is_refused(store, client, client_app, company_a):
    first = store.put(company_a, expected_version=0)
    store.put({**company_a, "legalName": "Northwind Renamed Sdn Bhd"}, expected_version=1)
    assert client_app.get("/v1/companies/northwind").status_code == 200

    client.collection(COMPANIES).document(company_a["tenantId"]).update(first)

    assert client_app.get("/v1/companies/northwind").status_code == 503


def test_same_uid_in_two_companies_never_crosses(store, client, client_app, company_a, company_b):
    suspended = set_lifecycle(client, make_record("eastbay", "demo-company-c"), state="suspended")
    for record in (company_a, company_b, suspended):
        store.put(record, expected_version=0)
    token_a, token_b = id_token("demo-company-a"), id_token("demo-company-b")

    own_a = client_app.get("/v1/w/northwind/me", headers=bearer(token_a))
    assert own_a.status_code == 200
    assert own_a.json() == {"tenantId": "t_northwind", "workspace": "northwind", "uid": UID,
                            "lifecycle": {"state": "active", "access": "open"}}
    assert client_app.get("/v1/w/southridge/me", headers=bearer(token_a)).status_code == 403
    own_b = client_app.get("/v1/w/southridge/me", headers=bearer(token_b))
    assert own_b.status_code == 200 and own_b.json()["tenantId"] == "t_southridge"
    assert client_app.get("/v1/me", headers=bearer(token_b)).json()["workspace"] == "southridge"

    assert client_app.get("/v1/me", headers=bearer(id_token("demo-unknown"))).status_code == 403
    suspended_token = id_token("demo-company-c")
    assert client_app.get("/v1/me", headers=bearer(suspended_token)).status_code == 403
    paused = client_app.get("/v1/w/eastbay/me", headers=bearer(suspended_token))
    assert paused.status_code == 200
    assert paused.json()["lifecycle"] == {"state": "suspended", "access": "readonly"}
    assert client_app.get("/v1/w/eastbay/usage", headers=bearer(suspended_token)).status_code == 403
    assert client_app.get("/v1/me").status_code == 401
    assert client_app.get("/v1/me", headers=bearer("not-a-token")).status_code == 401








def test_staff_api_refuses_client_tokens_and_unlisted_staff(staff_app, assertion):
    firebase_token = id_token("demo-company-a")

    assert staff_app.get("/staff/v1/companies", headers=bearer(firebase_token)).status_code == 401
    assert (
        staff_app.get("/staff/v1/companies", headers={"X-Staff-Session": firebase_token}).status_code
        == 401
    )
    assert staff_app.get("/staff/v1/companies").status_code == 401
    other = assertion("someone@example.com")
    assert staff_app.get("/staff/v1/companies", headers=other).status_code == 403
    allowed = staff_app.get("/staff/v1/companies", headers=assertion(STAFF_EMAIL))
    assert allowed.status_code == 200 and allowed.json() == {"companies": []}




def test_retried_put_stores_once_and_changed_body_conflicts(
    staff_app, staff_headers, store, company_a
):
    path = "/staff/v1/companies/t_northwind"
    store.put(company_a, expected_version=0)
    renamed = {**company_a, "legalName": "Northwind Renamed Sdn Bhd"}
    first = staff_app.put(
        path, headers={**staff_headers, **idem("key-aaaa-0001")}, json=put_body(renamed, 1)
    )
    assert first.status_code == 200, first.text
    body = first.json()
    assert body["status"] == "completed"
    assert body["steps"]["store_record"]["result"] == {"version": 2}

    again = staff_app.put(
        path, headers={**staff_headers, **idem("key-aaaa-0001")}, json=put_body(renamed, 1)
    )
    assert again.status_code == 200 and again.json()["operationId"] == body["operationId"]
    assert store.get("t_northwind")["version"] == 2

    changed = {**company_a, "legalName": "Northwind Other Sdn Bhd"}
    conflict = staff_app.put(
        path, headers={**staff_headers, **idem("key-aaaa-0001")}, json=put_body(changed, 1)
    )
    assert conflict.status_code == 409
    assert store.get("t_northwind")["version"] == 2


def test_only_the_engineer_changes_setup_fields_and_only_the_owner_the_rest(
    staff_app, staff_headers, engineer_headers, store, company_a
):
    path = "/staff/v1/companies/t_northwind"
    refused = staff_app.put(path, headers={**staff_headers, **idem("key-setup-0001")}, json=put_body(company_a))
    assert refused.status_code == 400 and store.get("t_northwind") is None
    store.put(company_a, expected_version=0)
    renamed = {**company_a, "legalName": "Northwind Renamed Sdn Bhd"}
    by_engineer = staff_app.put(path, headers={**engineer_headers, **idem("key-setup-0003")},
                                json=put_body(renamed, 1))
    assert by_engineer.status_code == 403 and store.get("t_northwind")["version"] == 1
    by_owner = staff_app.put(path, headers={**staff_headers, **idem("key-setup-0004")}, json=put_body(renamed, 1))
    assert by_owner.status_code == 200 and store.get("t_northwind")["version"] == 2


def test_the_record_route_never_changes_status_edition_or_package(
    staff_app, staff_headers, engineer_headers, store, company_a
):
    path = "/staff/v1/companies/t_northwind"
    store.put(company_a, expected_version=0)
    for index, change in enumerate(({"status": "lead"}, {"status": "deleted"}, {"planRef": "other"},
                                    {"edition": "advanced" if company_a.get("edition") != "advanced" else "basic"})):
        for who, headers in (("owner", staff_headers), ("engineer", engineer_headers)):
            refused = staff_app.put(path, headers={**headers, **idem(f"key-life-{who}-{index}")},
                                    json=put_body({**company_a, **change}, 1))
            assert refused.status_code == 409, (who, change, refused.text)
    assert store.get("t_northwind")["version"] == 1 and store.get("t_northwind")["status"] == company_a["status"]






def test_interrupted_put_is_finished_by_recovery_once(
    staff_app, staff_headers, store, operations, company_a
):
    operation_id = operations.begin(
        idempotency_key="key-aaaa-0004",
        action="directory.put",
        actor=STAFF_EMAIL,
        tenant_id="t_northwind",
        reason="Onboarding.",
        ticket=None,
        field_names=sorted(company_a),
        params={"tenantId": "t_northwind", "expectedVersion": 0, "record": company_a},
        step_names=["store_record"],
    )
    assert store.get("t_northwind") is None

    first = staff_app.post("/staff/v1/operations/recover", headers=staff_headers)
    assert first.status_code == 200 and first.json() == {"finished": [operation_id]}
    assert store.get("t_northwind")["version"] == 1
    assert operations.get(operation_id)["status"] == "completed"

    second = staff_app.post("/staff/v1/operations/recover", headers=staff_headers)
    assert second.json() == {"finished": []}
    assert store.get("t_northwind")["version"] == 1


def test_recovery_after_a_write_that_already_happened_does_not_write_again(
    staff_app, staff_headers, store, operations, company_a
):
    operation_id = operations.begin(
        idempotency_key="key-aaaa-0005",
        action="directory.put",
        actor=STAFF_EMAIL,
        tenant_id="t_northwind",
        reason="Onboarding.",
        ticket=None,
        field_names=sorted(company_a),
        params={"tenantId": "t_northwind", "expectedVersion": 0, "record": company_a},
        step_names=["store_record"],
    )
    store.put(company_a, expected_version=0)

    reply = staff_app.post("/staff/v1/operations/recover", headers=staff_headers)
    assert reply.json() == {"finished": [operation_id]}
    assert store.get("t_northwind")["version"] == 1
    step = operations.get(operation_id)["steps"]["store_record"]
    assert step["result"] == {"alreadyApplied": True}














SALES_UID = "held-sales"
SESSION = "c" * 32
LATE_SESSION = "d" * 32


def iso(moment):
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


class HeldCompany:
    def __init__(self, store, client, state="suspended", slug="heldco"):
        self.slug = slug
        self.project = f"demo-held-{os.urandom(5).hex()}"
        self.record = make_record(slug, self.project)
        store.put(self.record, expected_version=0)
        set_lifecycle(client, self.record, state=state)
        self.db = firestore.Client(project=self.project, credentials=AnonymousCredentials())
        self.now = datetime.now(timezone.utc)
        self.cut = self.now - timedelta(hours=1)
        self.token = id_token(self.project, SALES_UID)
        self.db.collection("user_access").document(SALES_UID).set({
            "accessVersion": 2, "uid": SALES_UID, "status": "active", "role": "salesman", "employeeCode": "S1",
            "branchId": "B1", "invitationState": "redeemed", "disabledReasons": ["billing_lapse"]})
        self.db.collection("route_plans").document("P1").set({
            "planId": "P1", "status": "published", "salesmanUid": SALES_UID, "salesmanCode": "S1", "branchId": "B1",
            "weekStart": self.now - timedelta(days=2), "stopIds": ["s1", "s2"],
            "stopRetailerIds": {"s1": "R1", "s2": "R2"},
            "days": [{"dayId": "d1", "stops": [{"stopId": "s1", "retailerId": "R1", "retailerName": "Kedai Satu"},
                                               {"stopId": "s2", "retailerId": "R2", "retailerName": "Kedai Dua"}]}]})
        self.db.collection("route_plan_progress").document(f"P1_{SALES_UID}").set({
            "progressId": f"P1_{SALES_UID}", "planId": "P1", "salesmanUid": SALES_UID, "salesmanCode": "S1",
            "branchId": "B1", "status": "in_progress", "routeSessionState": "active", "selectedStopId": "s1",
            "selectionRevision": 1, "handledStopIds": [], "stopProgress": {}})
        self.db.collection("live_tracking").document(SALES_UID).set({
            "uid": SALES_UID, "activeSessionId": SESSION, "activeSessionGeneration": 3, "workSessionStatus": "ended",
            "status": "inactive", "workSessionStartedAt": self.cut - timedelta(hours=2)})
        self.stamp(access="readonly", cutAt=self.cut, drainUntil=self.cut + timedelta(hours=24))

    def stamp(self, **fields):
        self.db.collection("config").document("lifecycle").set(fields)

    def doc(self, collection, doc_id):
        return self.db.collection(collection).document(doc_id).get().to_dict()

    def send(self, app, items, token=None):
        return app.post(f"/v1/w/{self.slug}/held-work", json={"items": items}, headers=bearer(token or self.token))


def stop_item(stop_id, status, sequence, device_at, session=SESSION, payload=None, plan_id="P1"):
    return {"kind": "stop_event", "id": f"{session}_{stop_id}_{status}", "workSessionId": session,
            "workSessionGeneration": 3, "deviceAt": iso(device_at), "planId": plan_id, "stopId": stop_id,
            "status": status, "sessionEventSequence": sequence, "payload": payload or {}}


MANUAL_ARRIVAL = {"arrivalMode": "manual_unverified", "coordinateReferenceMode": "unverified",
                  "retailerCoordinateRevision": "", "retailerCoordinateSource": "", "arrivalFailureCode": "unavailable",
                  "overrideReasonCode": "gps_unavailable", "overrideNote": "GPS was down"}


def order_item(order_id, device_at, session=SESSION):
    return {"kind": "order", "id": order_id, "workSessionId": session, "workSessionGeneration": 3,
            "deviceAt": iso(device_at), "payload": {
                "visitSource": "personal_planner", "retailerId": "R9", "retailerName": "Kedai Sembilan",
                "items": [{"productId": "p1", "orderQty": 2}], "commercialSchemaVersion": 1,
                "commercialLines": ["p1~Item_One~2~1500"], "totalProducts": 1, "totalBoxes": 2, "totalPrice": 30.0,
                "salesmanUid": "someone-else", "status": "approved"}}


def outcomes(response):
    assert response.status_code == 200, response.text
    return {row["id"]: (row["outcome"], row.get("reason")) for row in response.json()["results"]}


def test_held_work_accepts_pre_cut_work_in_the_drain_window_once(store, client, client_app):
    company = HeldCompany(store, client)
    before = company.cut - timedelta(minutes=30)
    order_id = "ORD-P1-" + "1" * 32
    late_order = "ORD-P1-" + "2" * 32
    items = [
        stop_item("s1", "arrived", 1, before, payload=MANUAL_ARRIVAL),
        stop_item("s1", "completed", 2, before + timedelta(minutes=5)),
        stop_item("s2", "skipped", 3, company.cut + timedelta(minutes=4), payload={"skipReason": "Shop closed"}),
        order_item(order_id, before),
        order_item(late_order, company.cut + timedelta(minutes=6)),
        stop_item("s9", "arrived", 4, before, payload=MANUAL_ARRIVAL),
        {"kind": "stop_event", "id": "broken"},
    ]
    reply = company.send(client_app, items)
    assert reply.json()["lifecycle"]["state"] == "suspended" and reply.json()["lifecycle"]["access"] == "readonly"
    assert outcomes(reply) == {
        f"{SESSION}_s1_arrived": ("accepted", None),
        f"{SESSION}_s1_completed": ("accepted", None),
        f"{SESSION}_s2_skipped": ("accepted", None),
        order_id: ("accepted", None),
        late_order: ("rejected", "after_cut"),
        f"{SESSION}_s9_arrived": ("rejected", "not_on_plan"),
        "broken": ("rejected", "invalid"),
    }
    stop = company.doc("route_stop_progress", f"P1_{SALES_UID}_s1")
    assert (stop["status"], stop["source"], stop["retailerName"], stop["retailerId"]) == (
        "completed", "held_work", "Kedai Satu", "R1")
    assert (stop["arrivalMode"], stop["arrivalEventId"], stop["salesmanCode"], stop["branchId"]) == (
        "manual_unverified", f"{SESSION}_s1_arrived", "S1", "B1")
    assert stop["deviceOccurredAt"] == before + timedelta(minutes=5)
    parent = company.doc("route_plan_progress", f"P1_{SALES_UID}")
    assert parent["handledStopIds"] == ["s1", "s2"]
    assert (parent["status"], parent["routeSessionState"], parent["selectionRevision"]) == (
        "completed", "completed", 2)
    assert "selectedStopId" not in parent and parent["lastStopWriteEventId"] == f"{SESSION}_s2_skipped"
    order = company.doc("orders", order_id)
    assert (order["salesmanUid"], order["uid"], order["salesmanCode"], order["branchId"]) == (
        SALES_UID, SALES_UID, "S1", "B1")
    assert (order["status"], order["source"], order["orderId"]) == ("submitted", "held_work", order_id)
    assert isinstance(order["submittedAt"], datetime) and "serverPriceCheck" not in order
    assert company.doc("orders", late_order) is None
    receipt = company.doc("held_work_receipts", receipt_id(SALES_UID, order_id))
    assert (receipt["uid"], receipt["outcome"], receipt["kind"]) == (SALES_UID, "accepted", "order")
    assert company.doc("held_work_receipts", receipt_id(SALES_UID, late_order))["reason"] == "after_cut"

    again = outcomes(company.send(client_app, items[:4]))
    assert set(again.values()) == {("duplicate", None)}
    assert company.doc("route_plan_progress", f"P1_{SALES_UID}")["handledStopIds"] == ["s1", "s2"]


def test_held_work_on_a_replaced_route_needs_a_started_run_and_the_24_hour_window(store, client, client_app):
    company = HeldCompany(store, client)
    before = company.cut - timedelta(minutes=30)
    route = company.db.collection("route_plans").document("P1")
    progress = company.db.collection("route_plan_progress").document(f"P1_{SALES_UID}")
    route.update({"status": "archived", "replacedAt": company.now - timedelta(hours=1)})
    inside = outcomes(company.send(client_app, [stop_item("s1", "arrived", 1, before, payload=MANUAL_ARRIVAL)]))
    assert inside == {f"{SESSION}_s1_arrived": ("accepted", None)}
    route.update({"replacedAt": company.now - timedelta(hours=25)})
    late = outcomes(company.send(client_app, [stop_item("s2", "arrived", 2, before, payload=MANUAL_ARRIVAL)]))
    assert late == {f"{SESSION}_s2_arrived": ("rejected", "not_on_plan")}
    route.update({"replacedAt": company.now - timedelta(hours=1)})
    progress.update({"status": "accepted"})
    unstarted = outcomes(company.send(client_app, [stop_item("s2", "arrived", 2, before, payload=MANUAL_ARRIVAL)]))
    assert unstarted == {f"{SESSION}_s2_arrived": ("rejected", "not_on_plan")}
    assert company.doc("route_stop_progress", f"P1_{SALES_UID}_s2") is None


def one_stop_accepted_route(company, session_state):
    company.db.collection("route_plans").document("P1").update({
        "stopIds": ["s1"], "stopRetailerIds": {"s1": "R1"},
        "days": [{"dayId": "d1", "stops": [{"stopId": "s1", "retailerId": "R1", "retailerName": "Kedai Satu"}]}]})
    progress = {"status": "accepted", "routeSessionState": firestore.DELETE_FIELD}
    if session_state != "untracked":
        progress["routeSessionState"] = session_state
    company.db.collection("route_plan_progress").document(f"P1_{SALES_UID}").update(progress)


@pytest.mark.parametrize("session_state, stored_session", [("untracked", None), ("active", "completed")])
def test_held_work_skip_of_the_only_stop_completes_a_route_left_accepted(
    store, client, client_app, session_state, stored_session
):
    company = HeldCompany(store, client)
    one_stop_accepted_route(company, session_state)
    skip = stop_item("s1", "skipped", 1, company.cut - timedelta(minutes=20), payload={"skipReason": "Shop closed"})
    assert outcomes(company.send(client_app, [skip])) == {skip["id"]: ("accepted", None)}
    parent = company.doc("route_plan_progress", f"P1_{SALES_UID}")
    assert (parent["status"], parent["handledStopIds"], parent.get("routeSessionState")) == (
        "completed", ["s1"], stored_session)
    assert isinstance(parent["startedAt"], datetime) and "selectedStopId" not in parent
    stop = company.doc("route_stop_progress", f"P1_{SALES_UID}_s1")
    assert (stop["status"], stop["skipReason"], stop["salesmanCode"]) == ("skipped", "Shop closed", "S1")


def test_held_work_skip_of_the_only_stop_on_an_accepted_route_with_a_paused_session_is_refused(
    store, client, client_app
):
    company = HeldCompany(store, client)
    one_stop_accepted_route(company, "paused")
    skip = stop_item("s1", "skipped", 1, company.cut - timedelta(minutes=20), payload={"skipReason": "Shop closed"})
    assert outcomes(company.send(client_app, [skip])) == {skip["id"]: ("rejected", "invalid")}
    parent = company.doc("route_plan_progress", f"P1_{SALES_UID}")
    assert (parent["status"], parent["handledStopIds"], parent["routeSessionState"]) == ("accepted", [], "paused")
    assert company.doc("route_stop_progress", f"P1_{SALES_UID}_s1") is None


def test_held_work_keeps_the_last_stop_order_sent_after_the_run_completed_on_a_replaced_route(store, client, client_app):
    company = HeldCompany(store, client)
    before = company.cut - timedelta(minutes=30)
    company.db.collection("route_plans").document("P1").update(
        {"status": "archived", "replacedAt": company.now - timedelta(hours=1)})
    outcomes(company.send(client_app, [stop_item("s1", "arrived", 1, before, payload=MANUAL_ARRIVAL),
                                       stop_item("s1", "completed", 2, before + timedelta(minutes=1))]))
    company.db.collection("route_plan_progress").document(f"P1_{SALES_UID}").update(
        {"selectedStopId": "s2", "selectionRevision": firestore.Increment(1)})
    order_id = f"ORD-V2-{SALES_UID}.P1.s2"
    order = {"kind": "order", "id": order_id, "workSessionId": SESSION, "workSessionGeneration": 3,
             "deviceAt": iso(before + timedelta(minutes=3)), "payload": {
                 "visitSource": "assigned_route", "routePlanId": "P1", "routeStopId": "s2", "retailerId": "R2",
                 "retailerName": "Kedai Dua", "salesmanCode": "S1", "items": [{"productId": "p1", "orderQty": 2}],
                 "commercialSchemaVersion": 1, "commercialLines": ["p1~Item_One~2~1500"], "totalProducts": 1,
                 "totalBoxes": 2, "totalPrice": 30.0}}
    got = outcomes(company.send(client_app, [
        stop_item("s2", "arrived", 3, before + timedelta(minutes=2), payload=MANUAL_ARRIVAL),
        stop_item("s2", "completed", 4, before + timedelta(minutes=4)), order]))
    assert company.doc("route_plan_progress", f"P1_{SALES_UID}")["status"] == "completed"
    assert got[order_id] == ("accepted", None)




def test_held_work_refuses_after_the_drain_and_when_never_paused(store, client, client_app):
    company = HeldCompany(store, client)
    item = order_item("ORD-P1-" + "4" * 32, company.cut - timedelta(minutes=10))
    company.stamp(access="readonly", cutAt=company.cut - timedelta(hours=24),
                  drainUntil=company.now - timedelta(minutes=1))
    assert outcomes(company.send(client_app, [item])) == {item["id"]: ("rejected", "drain_closed")}
    company.stamp(access="open")
    assert outcomes(company.send(client_app, [item])) == {item["id"]: ("rejected", "not_paused")}
    assert company.doc("orders", item["id"]) is None


def test_held_work_after_reactivation_takes_pre_cut_sessions_only(store, client, client_app):
    company = HeldCompany(store, client, state="active")
    reactivated = company.now - timedelta(minutes=10)
    company.stamp(access="open", cutAt=company.cut, drainUntil=company.cut + timedelta(minutes=30),
                  reactivatedAt=reactivated)
    company.db.collection("held_work_sessions").document(f"{SALES_UID}_{LATE_SESSION}").set({
        "uid": SALES_UID, "workSessionId": LATE_SESSION, "workSessionGeneration": 3,
        "serverStartedAt": reactivated + timedelta(minutes=1)})
    old = order_item("ORD-P1-" + "5" * 32, company.cut - timedelta(minutes=1))
    old_late = order_item("ORD-P1-" + "6" * 32, company.cut + timedelta(minutes=20))
    new = order_item("ORD-P1-" + "7" * 32, company.now, session=LATE_SESSION)
    assert outcomes(company.send(client_app, [old, old_late, new])) == {
        old["id"]: ("accepted", None),
        old_late["id"]: ("rejected", "after_cut"),
        new["id"]: ("rejected", "not_paused"),
    }




class LinkMail:
    def __init__(self):
        self.sent = []

    def send(self, message, idempotency_key):
        self.sent.append(dict(message))
        return f"link-{len(self.sent)}"


def company_user(project, role="admin", status="active", uid=UID):
    token = id_token(project, uid)
    company_db = firestore.Client(project=project, credentials=AnonymousCredentials())
    company_db.collection("user_access").document(uid).set(
        {"accessVersion": 2, "uid": uid, "status": status, "role": role})
    return token, company_db


@pytest.fixture
def mail_app(store, client, monkeypatch):
    from platform_service import account_links

    monkeypatch.setenv("PLATFORM_MAIL_ENABLED", "true")
    monkeypatch.setattr(account_links, "RESPONSE_FLOOR_SECONDS", 0.2)
    mail = LinkMail()
    app = TestClient(staff_api.create_app(store=store, client=client, mail_transport=lambda: mail))
    yield app, mail
    app.close()

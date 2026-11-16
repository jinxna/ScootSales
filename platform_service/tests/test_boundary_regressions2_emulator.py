
from __future__ import annotations

import asyncio
import base64
import json
import os
from datetime import datetime, timedelta, timezone

import pytest

from platform_service import config, held_work

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

from platform_service.tests.test_invitations_emulator import (  # noqa: E402,F401
    PROJECT_A, app, bearer, clean_emulators, client, company, create_auth_user, id_token, invitation_doc,
    invite, redeem, signer, store, world, write_member)
from platform_service import invitations  # noqa: E402
from platform_service.invitations import InvitationService  # noqa: E402

def evidence(label, **facts):
    print("EVIDENCE " + label + " | " + " ".join(f"{key}={value!r}" for key, value in facts.items()))



def second_admin_token():
    create_auth_user(PROJECT_A, "admin-a2")
    write_member(PROJECT_A, "admin-a2", "admin", code="A002")
    return id_token(PROJECT_A, "admin-a2")


def revoke_account(app, token, uid):
    return app.post(f"/v1/w/northwind/accounts/{uid}/revoke", headers=bearer(token))


def test_c3_invitations_made_by_a_removed_admin_are_closed_and_cannot_be_redeemed(app, client, world):
    second_admin = second_admin_token()
    admin_invite = invite(app, world["admin"], role="admin", employeeCode="A100", branchId="",
                          displayName="Returning Admin", key="c3-invite-001").json()
    sales_invite = invite(app, world["admin"], employeeCode="S777", key="c3-invite-003").json()
    kept = invite(app, second_admin, role="salesman", employeeCode="S900", key="c3-invite-002").json()
    assert revoke_account(app, second_admin, "admin-a").status_code == 200
    access = company(PROJECT_A)
    for made in (admin_invite, sales_invite):
        assert invitation_doc(client, made["invitationId"])["status"] == "revoked"
        refused = redeem(app, made["code"])
        assert refused.status_code == 410, refused.text
        assert not access.db.collection("user_access").document(made["uid"]).get().exists
    assert invitation_doc(client, kept["invitationId"])["status"] == "open"
    assert redeem(app, kept["code"]).status_code == 200
    control = invite(app, second_admin, role="salesman", employeeCode="S901", key="c3-invite-004").json()
    assert revoke_account(app, second_admin, control["uid"]).status_code == 200
    assert redeem(app, control["code"]).status_code == 410




def test_c3_demoting_an_admin_closes_the_invitations_that_admin_made(app, client, world):
    second_admin = second_admin_token()
    made = invite(app, world["admin"], role="admin", employeeCode="A100", branchId="",
                  displayName="Returning Admin", key="c3-demote-001").json()
    peer = invite(app, second_admin, role="salesman", employeeCode="S902", key="c3-demote-002").json()
    demoted = app.post("/v1/w/northwind/accounts/admin-a/role",
                       headers={**bearer(second_admin), "Idempotency-Key": "c3-role-0001"},
                       json={"role": "salesman", "branchId": "BR1"})
    assert demoted.status_code == 200, demoted.text
    assert invitation_doc(client, made["invitationId"])["status"] == "revoked"
    assert redeem(app, made["code"]).status_code == 410
    assert invitation_doc(client, peer["invitationId"])["status"] == "open"


def test_c3_an_invitation_made_by_the_platform_stays_valid_after_its_named_admin_is_removed(app, client, world):
    second_admin = second_admin_token()
    made = invite(app, world["admin"], role="admin", employeeCode="A100", branchId="",
                  displayName="Platform Admin", key="c3-platform-001").json()
    operation = client.collection("operations").document(invitation_doc(client, made["invitationId"])["operationId"])
    operation.update({"actor": "operator@example.com"})
    assert revoke_account(app, second_admin, "admin-a").status_code == 200
    assert invitation_doc(client, made["invitationId"])["status"] == "open"
    assert redeem(app, made["code"]).status_code == 200


from platform_service.tests.test_api_emulator import (  # noqa: E402,F401
    MANUAL_ARRIVAL, SALES_UID, SESSION, HeldCompany, assertion, client_app, clean_emulators as api_clean_emulators, iso,
    operations, order_item, outcomes, staff_app, staff_settings, stop_item)



def phone_order(order_id, device_at, *, assigned=False, located=False):
    payload = {
        "orderId": order_id, "visitId": "visit-1", "retailerId": "R1" if assigned else "R9",
        "retailerName": "Kedai Satu", "outlet": "Kedai Satu", "uid": SALES_UID, "userUid": SALES_UID,
        "salesmanUid": SALES_UID, "salesmanEmail": "held-sales@example.com", "salesmanId": "S1", "salesmanCode": "S1",
        "salesmanName": "Held Sales", "submittedByUid": SALES_UID, "createdByUid": SALES_UID, "branchId": "B1",
        "supervisorId": "SUP1", "totalProducts": 1, "totalBoxes": 2, "totalPrice": 30.0, "status": "submitted",
        "items": [{"name": "Item One", "productName": "Item One", "productId": "p1", "barcode": "9555000011112",
                   "packingSize": "24x500ml", "uom": "CTN", "maxOrderQty": 50, "price": 15.0, "priceSource": "sheet",
                   "qty": 2, "expiry": "2027-03-01", "department": "Dairy", "departmentName": "Dairy",
                   "shelfBatches": [{"qty": 2, "expiry": "2027-03-01"}], "remarks": ""}],
        "commercialSchemaVersion": 1, "commercialLines": ["p1~Item_One~2~1500"],
        "signatureTimestamps": {"Dairy": "07/11/2026  10:15:02"},
        "visitSource": "assigned_route" if assigned else "personal_planner",
    }
    if assigned:
        payload.update({"routePlanId": "P1", "routeStopId": "s1"})
    if located:
        fix = {"latitude": 1.5535, "longitude": 110.3593, "accuracyMeters": 8.0, "deviceCapturedAt": iso(device_at),
               "isMocked": False}
        payload.update({
            "latitude": 1.5535, "longitude": 110.3593, "gpsLatitude": 1.5535, "gpsLongitude": 110.3593,
            "location": {"latitude": 1.5535, "longitude": 110.3593}, "accuracy": 8.0, "accuracyMeters": 8.0,
            "deviceCapturedAt": iso(device_at), "isMocked": False, "locationVerification": "device_captured",
            "locationEvidence": {"mode": "device_captured", **fix}})
    else:
        payload["locationEvidence"] = {"mode": "not_verified", "failureCode": "unavailable"}
    return {"kind": "order", "id": order_id, "workSessionId": SESSION, "workSessionGeneration": 3,
            "deviceAt": iso(device_at), "payload": payload}


def stored_order(held, order_id):
    return held.doc("orders", order_id)


def second_salesperson(held):
    colleague = "held-colleague"
    create_auth_user(held.project, colleague)
    held.db.collection("user_access").document(colleague).set({
        "accessVersion": 2, "uid": colleague, "status": "active", "role": "salesman", "employeeCode": "S2",
        "branchId": "B1", "invitationState": "redeemed", "disabledReasons": ["billing_lapse"]})
    return colleague, id_token(held.project, colleague)


def test_c11_held_work_keeps_only_listed_order_fields(store, client, client_app):
    held = HeldCompany(store, client)
    before = held.cut - timedelta(minutes=30)
    extra = order_item("ORD-P1-" + "a" * 32, before)
    extra["payload"].update({"approvedByUid": "attacker", "approvalStatus": "approved",
                             "priceCheckStatus": "verified", "discountPercent": 99, "managerNote": "free goods"})
    remark = order_item("ORD-P1-" + "b" * 32, before)
    remark["payload"]["rejectionRemark"] = "Fake manager note"
    flagged = order_item("ORD-P1-" + "c" * 32, before)
    flagged["payload"]["isDemo"] = True
    huge_name = order_item("ORD-P1-" + "d" * 32, before)
    huge_name["payload"]["retailerName"] = "x" * (200 * 1024)
    split_names = order_item("ORD-P1-" + "e" * 32, before)
    split_names["payload"].update({"retailerName": "a" * 1000, "outlet": "b" * 1000, "salesmanName": "c"})
    wrong_type = order_item("ORD-P1-" + "f" * 32, before)
    wrong_type["payload"]["salesmanName"] = 5
    long_id = order_item("ORD-P1-" + "9" * 32, before)
    long_id["payload"]["salesmanId"] = "s" * 101
    bad_failure = order_item("ORD-P1-" + "8" * 32, before)
    bad_failure["payload"]["locationEvidence"] = {"mode": "not_verified", "failureCode": "X" * 5}
    bad_stamps = order_item("ORD-P1-" + "7" * 32, before)
    bad_stamps["payload"]["signatureTimestamps"] = {"Dairy": "<script>"}
    clean = order_item("ORD-P1-" + "6" * 32, before)
    items = [extra, remark, flagged, huge_name, split_names, wrong_type, long_id, bad_failure, bad_stamps, clean]
    reply = outcomes(held.send(client_app, items))
    stored = {item["id"]: stored_order(held, item["id"]) for item in items}
    evidence("C11 order fields outside the rules list, 1 h after the cut",
             outcomes={item["id"][-1]: reply[item["id"]] for item in items},
             stored=[item["id"][-1] for item in items if stored[item["id"]] is not None])
    for item in items[:-1]:
        assert reply[item["id"]] == ("rejected", "invalid"), item["id"]
        assert stored[item["id"]] is None
    assert reply[clean["id"]] == ("accepted", None)
    kept = stored[clean["id"]]
    assert kept["status"] == "submitted" and kept["salesmanUid"] == SALES_UID
    assert "approvedByUid" not in kept and "rejectionRemark" not in kept
    refused = [row for row in held.db.collection("held_work_receipts").stream() if row.to_dict()["outcome"] == "rejected"]
    assert len(refused) == len(items) - 1


def test_c11_held_work_accepts_what_phone_1_0_2_sends(store, client, client_app):
    held = HeldCompany(store, client)
    before = held.cut - timedelta(minutes=30)
    personal = phone_order("ORD-P1-" + "1" * 32, before)
    personal_located = phone_order("ORD-P1-" + "2" * 32, before, located=True)
    assigned = phone_order(f"ORD-V2-{SALES_UID}.P1.s1", before, assigned=True, located=True)
    reply = outcomes(held.send(client_app, [personal, personal_located, assigned]))
    evidence("C11 control: exact 1.0.2 order payloads", outcomes=reply)
    assert set(reply.values()) == {("accepted", None)}
    stored = stored_order(held, personal_located["id"])
    assert stored["location"].latitude == 1.5535 and stored["locationVerification"] == "device_captured"
    assert stored_order(held, assigned["id"])["routeStopId"] == "s1"
    assert stored_order(held, personal["id"])["signatureTimestamps"] == {"Dairy": "07/11/2026  10:15:02"}


def test_c11_held_work_refuses_device_time_over_a_day_before_its_own_session_and_keeps_honest_clocks(store, client, client_app):
    held = HeldCompany(store, client)
    started = held.cut - timedelta(hours=2)
    impossible = order_item("ORD-P1-" + "a" * 32, held.cut - timedelta(days=30))
    slow_clock = order_item("ORD-P1-" + "b" * 32, started - timedelta(minutes=4))
    far_clock = order_item("ORD-P1-" + "c" * 32, started - timedelta(hours=23))
    over_a_day = order_item("ORD-P1-" + "f" * 32, started - timedelta(hours=25))
    honest = order_item("ORD-P1-" + "d" * 32, held.cut - timedelta(minutes=30))
    after = order_item("ORD-P1-" + "e" * 32, held.cut + timedelta(minutes=10))
    reply = outcomes(held.send(client_app, [impossible, slow_clock, far_clock, honest, after, over_a_day]))
    evidence("C11 device time against a session the server stamped 2 h before the cut",
             impossible=reply[impossible["id"]], slow_clock_4m=reply[slow_clock["id"]],
             far_clock_11m=reply[far_clock["id"]], honest=reply[honest["id"]], after_cut=reply[after["id"]],
             stored_impossible=stored_order(held, impossible["id"]) is not None)
    assert reply[impossible["id"]] == ("rejected", "before_session")
    assert reply[over_a_day["id"]] == ("rejected", "before_session")
    assert reply[far_clock["id"]] == ("accepted", None)
    assert reply[slow_clock["id"]] == ("accepted", None)
    assert reply[honest["id"]] == ("accepted", None)
    assert reply[after["id"]] == ("rejected", "after_cut")
    assert stored_order(held, impossible["id"]) is None and stored_order(held, over_a_day["id"]) is None
    planted_start = {"kind": "session_start", "id": SESSION, "workSessionId": SESSION, "workSessionGeneration": 3,
                     "deviceAt": iso(held.cut - timedelta(days=30))}
    early_stop = stop_item("s1", "arrived", 1, held.cut - timedelta(days=29), payload=MANUAL_ARRIVAL)
    reply = outcomes(held.send(client_app, [planted_start, early_stop]))
    assert reply == {SESSION: ("rejected", "before_session"), early_stop["id"]: ("rejected", "before_session")}
    assert held.doc("held_work_sessions", f"{SALES_UID}_{SESSION}") is None
    assert held.doc("route_stop_progress", f"P1_{SALES_UID}_s1") is None


def late_stamp(held, minutes):
    held.db.collection("live_tracking").document(SALES_UID).set({
        "uid": SALES_UID, "activeSessionId": SESSION, "activeSessionGeneration": 3, "workSessionStatus": "ended",
        "workSessionStartedAt": held.cut + timedelta(minutes=minutes)})


def test_c11_fix137_server_start_after_the_cut_is_never_overridden_by_phone_time(store, client, client_app):
    held = HeldCompany(store, client)
    late_stamp(held, 50)
    start = {"kind": "session_start", "id": SESSION, "workSessionId": SESSION, "workSessionGeneration": 3,
             "deviceAt": iso(held.cut - timedelta(hours=3))}
    work = order_item("ORD-P1-" + "a" * 32, held.cut - timedelta(minutes=170))
    stop = stop_item("s1", "arrived", 1, held.cut - timedelta(minutes=170), payload=MANUAL_ARRIVAL)
    reply = outcomes(held.send(client_app, [start, work, stop]))
    evidence("FIX-137 server stamp 50 min after the cut, phone says it started 3 h before", reply=reply)
    assert reply == {SESSION: ("rejected", "session_after_cut"), work["id"]: ("rejected", "session_after_cut"),
                     stop["id"]: ("rejected", "session_after_cut")}
    assert stored_order(held, work["id"]) is None
    assert held.doc("held_work_sessions", f"{SALES_UID}_{SESSION}") is None
    assert held.doc("route_stop_progress", f"P1_{SALES_UID}_s1") is None




def test_c11_fix137_a_session_stamped_between_cut_and_reactivation_stays_refused(store, client, client_app):
    held = HeldCompany(store, client)
    late_stamp(held, 20)
    held.stamp(access="open", cutAt=held.cut, drainUntil=held.cut + timedelta(hours=24),
               reactivatedAt=held.cut + timedelta(minutes=40))
    work = order_item("ORD-P1-" + "a" * 32, held.cut - timedelta(minutes=170))
    assert outcomes(held.send(client_app, [work])) == {work["id"]: ("rejected", "session_after_cut")}


def test_c11_fix137_a_phone_clock_set_back_inside_a_day_keeps_its_work(store, client, client_app):
    held = HeldCompany(store, client)
    started = held.cut - timedelta(hours=2)
    set_back = order_item("ORD-P1-" + "a" * 32, started + timedelta(minutes=5) - timedelta(minutes=30))
    first = outcomes(held.send(client_app, [set_back]))
    again = outcomes(held.send(client_app, [set_back]))
    assert first == {set_back["id"]: ("accepted", None)}
    assert again == {set_back["id"]: ("duplicate", None)}




def test_p1_held_work_receipt_belongs_to_the_person_who_sent_the_item(store, client, client_app):
    held = HeldCompany(store, client)
    colleague, token_b = second_salesperson(held)
    item = order_item("ORD-P1-" + "a" * 32, held.cut - timedelta(minutes=30))
    planted = outcomes(held.send(client_app, [item], token=token_b))
    mine = outcomes(held.send(client_app, [item]))
    again = outcomes(held.send(client_app, [item]))
    owners = sorted(row.to_dict()["uid"] for row in held.db.collection("held_work_receipts").stream())
    evidence("FIX-240 colleague posts my item id first", colleague_outcome=planted[item["id"]], mine=mine[item["id"]],
             mine_again=again[item["id"]], receipts_by=owners)
    assert planted[item["id"]][0] == "rejected"
    assert mine[item["id"]] == ("accepted", None)
    assert again[item["id"]] == ("duplicate", None)
    assert held.doc("orders", item["id"])["salesmanUid"] == SALES_UID
    assert owners == sorted([colleague, SALES_UID])


def test_p1_held_work_receipts_written_before_the_key_change_still_count(store, client, client_app):
    held = HeldCompany(store, client)
    done = order_item("ORD-P1-" + "a" * 32, held.cut - timedelta(minutes=30))
    planted = order_item("ORD-P1-" + "b" * 32, held.cut - timedelta(minutes=30))
    old = {"kind": "order", "workSessionId": SESSION, "deviceAt": held.cut - timedelta(minutes=30), "reason": None}
    held.db.collection("held_work_receipts").document(done["id"]).set(
        {**old, "uid": SALES_UID, "outcome": "accepted", "attempts": 1})
    held.db.collection("held_work_receipts").document(planted["id"]).set(
        {**old, "uid": "someone-else", "outcome": "rejected", "reason": "session_after_cut", "attempts": 1})
    reply = outcomes(held.send(client_app, [done, planted]))
    evidence("FIX-240 receipts under the old key", outcomes=reply,
             order_for_accepted_receipt=held.doc("orders", done["id"]) is not None)
    assert reply[done["id"]] == ("duplicate", None)
    assert held.doc("orders", done["id"]) is None
    assert reply[planted["id"]] == ("accepted", None)


class ChunkedBody:
    def __init__(self, chunk_size, chunks):
        self.chunk = b"x" * chunk_size
        self.total = chunks
        self.pulled = 0

    async def receive(self):
        if self.pulled >= self.total:
            return {"type": "http.request", "body": b"", "more_body": False}
        self.pulled += 1
        return {"type": "http.request", "body": self.chunk, "more_body": self.pulled < self.total}


def post_chunked(app, path, token, body):
    sent = []

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST", "scheme": "http",
             "path": path, "raw_path": path.encode(), "query_string": b"", "root_path": "",
             "headers": [(b"authorization", f"Bearer {token}".encode()), (b"content-type", b"application/json"),
                         (b"host", b"testserver")],
             "client": ("127.0.0.1", 50000), "server": ("testserver", 80)}
    asyncio.run(app(scope, body.receive, send))
    return next(message["status"] for message in sent if message["type"] == "http.response.start")


def test_p1_held_work_stops_reading_a_chunked_body_at_the_limit(store, client, client_app):
    held = HeldCompany(store, client)
    body = ChunkedBody(chunk_size=64 * 1024, chunks=400)
    status = post_chunked(client_app.app, "/v1/w/heldco/held-work", held.token, body)
    evidence("FIX-138 chunked body of 25 MB with no length header", status=status, chunks_read=body.pulled,
             chunks_sent_by_client=body.total)
    assert status == 413
    assert body.pulled <= held_work.MAX_BODY_BYTES // (64 * 1024) + 2


def quota_count(client):
    return [row.to_dict()["count"] for row in client.collection("rate_limits").stream() if row.id.startswith("held_")]


def clear_quota(client):
    for row in list(client.collection("rate_limits").stream()):
        if row.id.startswith("held_"):
            row.reference.delete()


def test_p1_n09_held_work_limits_items_an_hour_and_a_resent_duplicate_is_not_counted(store, client, client_app,
                                                                                     monkeypatch):
    monkeypatch.setattr(config, "HELD_WORK_ITEMS_PER_HOUR", 6, raising=False)
    held = HeldCompany(store, client)
    colleague, token_b = second_salesperson(held)
    before = held.cut - timedelta(minutes=30)
    batches = [[order_item("ORD-P1-" + f"{batch}{number}".ljust(32, "0"), before) for number in range(4)]
               for batch in range(3)]
    first = held.send(client_app, batches[0])
    lost_response_retry = held.send(client_app, batches[0])
    second = held.send(client_app, batches[1])
    third = held.send(client_app, batches[2])
    other = held.send(client_app, [order_item("ORD-P1-" + "f" * 32, before)], token=token_b)
    evidence("FIX-138 limit 6 items an hour, three batches of 4", statuses=[first.status_code, lost_response_retry.status_code,
             second.status_code, third.status_code], retry_after=third.headers.get("retry-after"),
             colleague=other.status_code, count=quota_count(client))
    assert first.status_code == 200 and set(outcomes(first).values()) == {("accepted", None)}
    assert lost_response_retry.status_code == 200
    assert set(outcomes(lost_response_retry).values()) == {("duplicate", None)}
    assert second.status_code == 200 and set(outcomes(second).values()) == {("accepted", None)}
    assert third.status_code == 429
    assert 0 < int(third.headers["retry-after"]) <= 3600
    assert other.status_code == 200
    assert all(held.doc("orders", item["id"]) is None for item in batches[2])
    clear_quota(client)
    assert set(outcomes(held.send(client_app, batches[2])).values()) == {("accepted", None)}
    assert all(held.doc("orders", item["id"]) is not None for batch in batches for item in batch)




def test_p1_held_work_answers_429_without_charging_or_touching_stored_work(store, client, client_app, monkeypatch):
    monkeypatch.setattr(config, "HELD_WORK_ITEMS_PER_HOUR", 6, raising=False)
    held = HeldCompany(store, client)
    before = held.cut - timedelta(minutes=30)
    first = [order_item("ORD-P1-" + f"a{number}".ljust(32, "0"), before) for number in range(8)]
    later = [order_item("ORD-P1-" + f"b{number}".ljust(32, "0"), before) for number in range(3)]
    assert held.send(client_app, first).status_code == 200
    counted = quota_count(client)
    replies = [held.send(client_app, later) for _ in range(5)]
    assert [reply.status_code for reply in replies] == [429] * 5
    assert quota_count(client) == counted == [8]
    assert all(held.doc("orders", item["id"]) is None for item in later)
    assert all(held.doc("held_work_receipts", held_work.receipt_id(SALES_UID, item["id"])) is None for item in later)
    clear_quota(client)
    assert set(outcomes(held.send(client_app, later)).values()) == {("accepted", None)}




def test_p1_held_work_cap_fits_the_largest_chunk_the_phone_sends(store, client, client_app):
    held = HeldCompany(store, client)
    before = held.cut - timedelta(minutes=30)
    ordinary = [honest_order(number, before) for number in range(25)]
    size, reply = post_raw(client_app, held, ordinary)
    evidence("FIX-138 25 ordinary orders of 25 lines", body_bytes=size, cap=held_work.MAX_BODY_BYTES, status=reply.status_code)
    assert size > 256 * 1024 and reply.status_code == 200
    assert {row for key, row in outcomes(reply).items() if key != SESSION} == {("accepted", None)}
    again = post_raw(client_app, held, ordinary)[1]
    assert {row for key, row in outcomes(again).items() if key != SESSION} == {("duplicate", None)}
    largest = [honest_order(100 + number, before, name_length=600, batches=20, remark=200, product_length=200, barcode=50,
                            packing=50, department=50) for number in range(25)]
    size, reply = post_raw(client_app, held, largest)
    evidence("FIX-138 25 orders at every limit the phone and the rules set", body_bytes=size, cap=held_work.MAX_BODY_BYTES,
             status=reply.status_code)
    assert size > 2 * 1024 * 1024 and size < held_work.MAX_BODY_BYTES and reply.status_code == 200
    assert {row for key, row in outcomes(reply).items() if key != SESSION} == {("accepted", None)}
    assert all(held.doc("orders", item["id"]) is not None for item in largest)
    over = [honest_order(200 + number, before, name_length=600, batches=20, remark=200, product_length=200, barcode=50,
                         packing=50, department=50, filler=1500) for number in range(25)]
    size, reply = post_raw(client_app, held, over)
    assert size > held_work.MAX_BODY_BYTES and reply.status_code == 413




def encoded(name):
    return base64.urlsafe_b64encode(name.encode()).decode().rstrip("=")


def honest_order(number, device_at, lines=25, name_length=45, batches=2, remark="", product_length=20, barcode=13,
                 packing=9, department=16, filler=0):
    remark = "r" * remark if isinstance(remark, int) else remark
    items = []
    for line in range(lines):
        name = f"N{line:02d}".ljust(name_length, "x")
        items.append({
            "name": name, "productId": f"p{line:02d}".ljust(product_length, "0"), "barcode": "9" * barcode,
            "packingSize": "p" * packing, "uom": "CTN", "maxOrderQty": 50, "department": "d" * department, "qty": 2,
            "expiry": "12/12/2030", "price": 15.5, "priceSource": "sheet", "remarks": remark, "stock": 10,
            "shelfBatches": [{"qty": 2, "expiry": "12/12/2030"} for _ in range(batches)],
            "retailerId": "R" * 100, "retailerName": "K" * 100, "visitId": "v" * 40,
            **({"padding": "z" * filler} if filler else {})})
    order_id = "ORD-P1-" + f"{number:032x}"
    payload = {
        "orderId": order_id, "visitId": "v" * 40, "retailerId": "R" * 100, "retailerName": "K" * 400, "outlet": "K" * 400,
        "uid": SALES_UID, "userUid": SALES_UID, "salesmanUid": SALES_UID, "salesmanEmail": "e" * 50, "salesmanId": "S1",
        "salesmanCode": "S1", "salesmanName": "n" * 60, "submittedByUid": SALES_UID, "createdByUid": SALES_UID,
        "branchId": "B1", "supervisorId": "SUP1", "totalProducts": lines, "totalBoxes": 2 * lines, "totalPrice": 31.0 * lines,
        "status": "submitted", "items": items, "commercialSchemaVersion": 1,
        "commercialLines": [f"{item['productId']}~{encoded(item['name'])}~2~1550" for item in items],
        "signatureTimestamps": {"Dairy": "07/11/2026  10:15:02"}, "visitSource": "personal_planner",
        "locationEvidence": {"mode": "not_verified", "failureCode": "unavailable"}}
    return {"kind": "order", "id": order_id, "workSessionId": SESSION, "workSessionGeneration": 3,
            "deviceAt": iso(device_at), "payload": payload}


def post_raw(client_app, held, items):
    start = {"kind": "session_start", "id": SESSION, "workSessionId": SESSION, "workSessionGeneration": 3,
             "deviceAt": iso(held.cut - timedelta(hours=2))}
    body = json.dumps({"items": [start, *items]}, separators=(",", ":")).encode()
    response = client_app.post("/v1/w/heldco/held-work", content=body,
                               headers={**bearer(held.token), "Content-Type": "application/json"})
    return len(body), response


def planted_order(held, colleague, item_id, device_at):
    order = phone_order(item_id, device_at)
    order["workSessionId"] = "d" * 32
    order["workSessionGeneration"] = 1
    for key in ("uid", "userUid", "salesmanUid", "submittedByUid", "createdByUid"):
        order["payload"][key] = colleague
    order["payload"].update({"salesmanCode": "S2", "salesmanId": "S2", "salesmanEmail": "held-colleague@example.com"})
    start = {"kind": "session_start", "id": "d" * 32, "workSessionId": "d" * 32, "workSessionGeneration": 1,
             "deviceAt": iso(held.cut - timedelta(hours=2))}
    return [start, order]


def test_p1_fix240_fix265_a_colleague_can_not_take_an_assigned_route_order_id_and_other_ids_a_colleague_holds_do_not_block_the_person(store, client, client_app):
    held = HeldCompany(store, client)
    colleague, token_b = second_salesperson(held)
    before = held.cut - timedelta(minutes=30)
    victim_id = f"ORD-V2-{SALES_UID}.P1.s1"
    random_id = "ORD-P1-" + "4" * 32
    start, theirs = planted_order(held, colleague, victim_id, before)
    other = planted_order(held, colleague, random_id, before)[1]
    planted = outcomes(held.send(client_app, [start, theirs, other], token=token_b))
    assert planted[victim_id] == ("rejected", "invalid") and planted[random_id] == ("accepted", None)
    assert held.doc("orders", victim_id) is None
    mine = [phone_order(victim_id, before, assigned=True), phone_order(random_id, before)]
    first = outcomes(held.send(client_app, mine))
    again = outcomes(held.send(client_app, mine))
    held.stamp(access="open", cutAt=held.cut, drainUntil=held.cut + timedelta(hours=24),
               reactivatedAt=held.cut + timedelta(minutes=40))
    after = outcomes(held.send(client_app, mine))
    evidence("FIX-240 FIX-265 colleague holds one of the person's order ids and is refused the other", first=first,
             again=again, after=after)
    assert first == {victim_id: ("accepted", None), random_id: ("accepted", None)}
    assert again == {victim_id: ("duplicate", None), random_id: ("duplicate", None)}
    assert after == again
    canonical = held.doc("orders", victim_id)
    assert canonical["salesmanUid"] == SALES_UID and canonical["routeStopId"] == "s1" and canonical["orderId"] == victim_id
    assert held.doc("orders", held_work.own_order_id(SALES_UID, victim_id)) is None
    colleagues = held.doc("orders", random_id)
    assert colleagues["salesmanUid"] == colleague and colleagues["orderId"] == random_id
    own = held.doc("orders", held_work.own_order_id(SALES_UID, random_id))
    assert own["salesmanUid"] == SALES_UID and own["orderId"] == held_work.own_order_id(SALES_UID, random_id)
    receipt = held.doc("held_work_receipts", held_work.receipt_id(SALES_UID, random_id))
    assert receipt["outcome"] == "accepted" and receipt["storedAs"] == held_work.own_order_id(SALES_UID, random_id)
    assert held.doc("orders", held_work.own_order_id(colleague, victim_id)) is None


def test_p1_fix240_an_order_id_can_not_be_made_to_look_like_a_stored_own_id(store, client, client_app):
    held = HeldCompany(store, client)
    before = held.cut - timedelta(minutes=30)
    forged = phone_order(held_work.own_order_id(SALES_UID, "ORD-P1-" + "5" * 32), before)
    assert outcomes(held.send(client_app, [forged])) == {forged["id"]: ("rejected", "invalid")}
    assert stored_order(held, forged["id"]) is None


def test_p1_fix240_a_stop_event_with_a_colleagues_item_id_does_not_block_the_person(store, client, client_app):
    held = HeldCompany(store, client)
    colleague, token_b = second_salesperson(held)
    before = held.cut - timedelta(minutes=30)
    theirs = stop_item("s1", "arrived", 1, before, payload=MANUAL_ARRIVAL)
    first = outcomes(held.send(client_app, [theirs], token=token_b))
    mine = outcomes(held.send(client_app, [theirs]))
    again = outcomes(held.send(client_app, [theirs]))
    assert first[theirs["id"]][0] == "rejected"
    assert mine == {theirs["id"]: ("accepted", None)}
    assert again == {theirs["id"]: ("duplicate", None)}
    assert held.doc("route_stop_progress", f"P1_{SALES_UID}_s1")["salesmanUid"] == SALES_UID
    assert held.doc("route_stop_progress", f"P1_{colleague}_s1") is None










def test_a3_fix264_parallel_held_work_requests_share_one_hourly_count_and_an_unreadable_count_refuses(
        store, client, client_app, monkeypatch):
    import httpx
    monkeypatch.setattr(config, "HELD_WORK_ITEMS_PER_HOUR", 3, raising=False)
    held = HeldCompany(store, client)
    other = HeldCompany(store, client, slug="heldco2")
    before = held.cut - timedelta(minutes=30)

    def batch(tag, cut_before):
        return [order_item("ORD-A3-" + f"{tag}{number}".ljust(32, "0"), cut_before) for number in range(5)]

    parallel = [batch(f"p{index}", before) for index in range(6)]
    other_batch = batch("o", other.cut - timedelta(minutes=30))

    async def burst():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=client_app.app), base_url="http://testserver",
                                     timeout=120) as web:
            async def post(company, items):
                return await web.post(f"/v1/w/{company.slug}/held-work", json={"items": items},
                                      headers=bearer(company.token))
            replies = await asyncio.gather(*[post(held, items) for items in parallel], post(other, other_batch))
            return replies[:-1], replies[-1]

    replies, other_reply = asyncio.run(burst())
    codes = sorted(reply.status_code for reply in replies)
    stored = sum(1 for items in parallel for item in items if held.doc("orders", item["id"]) is not None)
    evidence("FIX-264 six parallel posts of 5 items, limit 3", codes=codes, stored=stored,
             counts=sorted(quota_count(client)), other_company=other_reply.status_code)
    counts = sorted(quota_count(client))
    assert set(codes) <= {200, 429, 503}
    assert codes.count(200) == 1
    assert stored == 5
    assert other_reply.status_code == 200
    assert counts == sorted([stored, 5])
    for reply in replies:
        if reply.status_code == 503:
            assert 0 < int(reply.headers["retry-after"]) <= 10
    if 429 in codes:
        assert 200 in codes and counts.count(5) == 2
    assert other_reply.status_code == 200 and set(outcomes(other_reply).values()) == {("accepted", None)}

    class Unreadable:
        def get(self, *args, **kwargs):
            raise RuntimeError("counter unavailable")

    clear_quota(client)
    monkeypatch.setattr(held_work.HeldWork, "_quota", lambda self, context: Unreadable())
    later = batch("z", before)
    refused = held.send(client_app, later)
    assert refused.status_code == 503 and int(refused.headers["retry-after"]) > 0
    assert all(held.doc("orders", item["id"]) is None for item in later)


def test_a3_fix266_a_session_the_server_first_sees_after_the_cut_is_held_for_an_admin_never_submitted(
        store, client, client_app):
    held = HeldCompany(store, client)
    other = HeldCompany(store, client, slug="heldco2")
    cut = held.cut

    def fresh(session, order_id, stated):
        start = {"kind": "session_start", "id": session, "workSessionId": session, "workSessionGeneration": 1,
                 "deviceAt": iso(stated - timedelta(hours=2))}
        order = order_item(order_id, stated, session=session)
        order["workSessionGeneration"] = 1
        return [start, order]

    unknown = outcomes(held.send(client_app, fresh("e" * 32, "ORD-A3-LATE-1", cut - timedelta(minutes=30))))
    registered = outcomes(held.send(client_app, [order_item("ORD-A3-REG-1", cut - timedelta(minutes=30))]))
    stated_late = outcomes(held.send(client_app, fresh("f" * 32, "ORD-A3-LATE-2", cut + timedelta(minutes=6))))
    other_registered = outcomes(other.send(client_app, [order_item("ORD-A3-REG-1", other.cut - timedelta(minutes=30))]))
    held_order = held.doc("orders", "ORD-A3-LATE-1")
    evidence("FIX-266 session unknown to the server before the cut", unknown=unknown, registered=registered,
             stated_late=stated_late, status=held_order and held_order.get("status"),
             other_registered=other_registered)
    assert unknown["ORD-A3-LATE-1"] == ("accepted", None)
    assert held_order["status"] == "held_for_review" and held_order["salesmanUid"] == SALES_UID
    assert held_order["reviewReason"] == "session_unknown_before_pause"
    assert "Approve it only if you know the work was done before the pause" in held_order["reviewNote"]
    assert held.doc("held_work_receipts", held_work.receipt_id(SALES_UID, "ORD-A3-LATE-1"))["outcome"] == "accepted"
    assert registered == {"ORD-A3-REG-1": ("accepted", None)}
    assert held.doc("orders", "ORD-A3-REG-1")["status"] == "submitted"
    assert stated_late["ORD-A3-LATE-2"][0] != "accepted" and held.doc("orders", "ORD-A3-LATE-2") is None
    assert other_registered == {"ORD-A3-REG-1": ("accepted", None)}
    assert other.doc("orders", "ORD-A3-REG-1")["status"] == "submitted" and other.doc("orders", "ORD-A3-LATE-1") is None
    again = outcomes(held.send(client_app, fresh("e" * 32, "ORD-A3-LATE-1", cut - timedelta(minutes=30))))
    assert again["ORD-A3-LATE-1"] == ("duplicate", None)


def test_p1_held_work_hourly_count_belongs_to_one_company_even_for_the_same_uid(store, client, client_app, monkeypatch):
    monkeypatch.setattr(config, "HELD_WORK_ITEMS_PER_HOUR", 4, raising=False)
    first = HeldCompany(store, client)
    second = HeldCompany(store, client, slug="heldco2")
    before = first.cut - timedelta(minutes=30)
    batch_a = [order_item("ORD-P1-" + f"e{n}".ljust(32, "0"), before) for n in range(4)]
    batch_b = [order_item("ORD-P1-" + f"f{n}".ljust(32, "0"), second.cut - timedelta(minutes=30)) for n in range(4)]
    assert set(outcomes(first.send(client_app, batch_a)).values()) == {("accepted", None)}
    refused_a = first.send(client_app, batch_a[:1])
    own_b = outcomes(second.send(client_app, batch_b))
    evidence("two companies, same uid, limit 4", first_again=refused_a.status_code, second=sorted(set(own_b.values())),
             counts=sorted(quota_count(client)))
    assert refused_a.status_code == 429
    assert set(own_b.values()) == {("accepted", None)}
    assert sorted(quota_count(client)) == [4, 4]
    assert second.send(client_app, batch_b[:1]).status_code == 429


def test_p1_held_work_one_person_sending_at_once_gets_a_retryable_answer_never_500_and_other_companies_are_served(store, client, client_app):
    import httpx
    held = HeldCompany(store, client)
    other = HeldCompany(store, client, slug="otherco")
    before = held.cut - timedelta(minutes=30)
    session_start = {"kind": "session_start", "id": SESSION, "workSessionId": SESSION, "workSessionGeneration": 3,
                     "deviceAt": iso(held.cut - timedelta(hours=2))}

    def batch(number):
        return [session_start, *[order_item("ORD-P1-" + f"{number}{index}".ljust(32, "0"), before) for index in range(8)]]

    async def burst():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=client_app.app), base_url="http://testserver", timeout=120) as web:
            async def post(company, items):
                return await web.post(f"/v1/w/{company.slug}/held-work", json={"items": items}, headers=bearer(company.token))
            colleague = post(other, [order_item("ORD-P1-" + "e" * 32, other.cut - timedelta(minutes=30))])
            replies = await asyncio.gather(*[post(held, batch(number)) for number in range(10)], colleague)
            return replies[:-1], replies[-1]

    replies, colleague = asyncio.run(burst())
    statuses = sorted(reply.status_code for reply in replies)
    evidence("FIX-138 10 parallel posts from one person", statuses=statuses, other_company=colleague.status_code)
    assert 500 not in statuses and set(statuses) <= {200, 409, 429}
    for reply in replies:
        if reply.status_code == 200:
            assert {row["outcome"] for row in reply.json()["results"]} <= {"accepted", "duplicate", "retry_later"}
    assert colleague.status_code == 200 and outcomes(colleague)["ORD-P1-" + "e" * 32] == ("accepted", None)
    for number in range(10):
        resent = held.send(client_app, batch(number))
        assert {row["outcome"] for row in resent.json()["results"]} <= {"accepted", "duplicate"}
    assert all(held.doc("orders", "ORD-P1-" + f"{number}{index}".ljust(32, "0")) for number in range(10) for index in range(8))

def fail_redeem_after(monkeypatch, then, error, expire_lease=True):
    original = InvitationService._finish_redeem

    def failing(self, reference, data, password, device):
        if expire_lease:
            reference.update({"redeemLeaseUntil": datetime.now(timezone.utc) - timedelta(minutes=1)})
        then()
        raise error

    monkeypatch.setattr(InvitationService, "_finish_redeem", failing)
    return lambda: monkeypatch.setattr(InvitationService, "_finish_redeem", original)


def test_c63_a_failed_redeem_does_not_reopen_a_code_the_admin_revoked_meanwhile(app, client, world, monkeypatch):
    made = invite(app, world["admin"], key="c63-release-001").json()

    def revoke():
        revoked = app.post(f"/v1/w/northwind/invitations/{made['invitationId']}/revoke", headers=bearer(world["admin"]))
        assert revoked.status_code == 200, revoked.text

    restore = fail_redeem_after(monkeypatch, revoke, RuntimeError("the redeem stalled and then failed"))
    failed = redeem(app, made["code"])
    assert failed.status_code == 503
    assert invitation_doc(client, made["invitationId"])["status"] == "revoked"
    restore()
    assert redeem(app, made["code"]).status_code == 410


def test_c63_a_failed_redeem_does_not_release_a_code_another_device_now_holds(app, client, world, monkeypatch):
    made = invite(app, world["admin"], key="c63-release-002").json()
    other_lease = datetime.now(timezone.utc) + timedelta(minutes=4)

    def other_device():
        client.collection("invitations").document(made["invitationId"]).update({"redeemLeaseUntil": other_lease})

    fail_redeem_after(monkeypatch, other_device, RuntimeError("the redeem stalled and then failed"))
    failed = redeem(app, made["code"])
    assert failed.status_code == 503
    stored = invitation_doc(client, made["invitationId"])
    assert stored["status"] == "redeeming" and stored["redeemLeaseUntil"] == other_lease


def test_c63_a_failed_redeem_still_gives_its_own_code_back(app, client, world, monkeypatch):
    made = invite(app, world["admin"], key="c63-release-003").json()
    restore = fail_redeem_after(monkeypatch, lambda: None, RuntimeError("the redeem failed"), expire_lease=False)
    failed = redeem(app, made["code"])
    assert failed.status_code == 503
    stored = invitation_doc(client, made["invitationId"])
    assert stored["status"] == "open" and stored["redeemLeaseUntil"] is None
    restore()
    assert redeem(app, made["code"]).status_code == 200




def test_c63_the_in_transaction_caller_check_reads_disabled_reasons(app, client, world, monkeypatch):
    second_admin = second_admin_token()
    access = company(PROJECT_A)
    monkeypatch.setattr(InvitationService, "require_admin", lambda self, access, uid: {"role": "admin"})
    access.db.collection("user_access").document("admin-a2").update({"disabledReasons": ["deletion_requested"]})
    refused = revoke_account(app, second_admin, "sales-a")
    assert refused.status_code in (403, 409), refused.text
    assert access.db.collection("user_access").document("sales-a").get().to_dict()["status"] == "active"
    access.db.collection("user_access").document("admin-a2").update({"disabledReasons": ["lifecycle_readonly"]})
    allowed = revoke_account(app, second_admin, "sales-a")
    assert allowed.status_code == 200, allowed.text




def test_p1_held_work_an_item_the_company_database_can_never_save_is_refused_for_good_and_does_not_block_the_next(store, client, client_app, monkeypatch):
    from google.api_core.exceptions import InvalidArgument, ServiceUnavailable
    held = HeldCompany(store, client)
    before = held.cut - timedelta(minutes=30)
    items = [order_item("ORD-SAVE-" + name.ljust(30, "0"), before) for name in ("bad", "good")]
    real = held_work.HeldWork._one

    def one(self, access, context, actor, item, item_id):
        if item_id == items[0]["id"]:
            raise InvalidArgument("The document is too big to save.")
        return real(self, access, context, actor, item, item_id)

    monkeypatch.setattr(held_work.HeldWork, "_one", one)
    rows = outcomes(held.send(client_app, items))
    evidence("FIX-027 one order the database cannot save, one honest order", outcomes=rows)
    assert rows[items[0]["id"]] == ("rejected", "save_failed")
    assert rows[items[1]["id"]] == ("accepted", None)

    def down(self, access, context, actor, item, item_id):
        raise ServiceUnavailable("The company database is down.")

    monkeypatch.setattr(held_work.HeldWork, "_one", down)
    again = outcomes(held.send(client_app, [order_item("ORD-SAVE-" + "later".ljust(30, "0"), before)]))
    assert set(again.values()) == {("retry_later", "company_unreachable")}


def test_n11_held_work_an_unexpected_fault_on_one_item_waits_for_that_item_only_and_nothing_is_lost_or_doubled(
        store, client, client_app, monkeypatch):
    held = HeldCompany(store, client)
    other = HeldCompany(store, client, slug="otherco")
    before = held.cut - timedelta(minutes=30)
    items = [order_item("ORD-N11-" + name.ljust(31, "0"), before) for name in ("bad", "good")]
    real = held_work.HeldWork._one

    def one(self, access, context, actor, item, item_id):
        if item_id == items[0]["id"]:
            raise RuntimeError("An unexpected fault in one item.")
        return real(self, access, context, actor, item, item_id)

    monkeypatch.setattr(held_work.HeldWork, "_one", one)
    first = held.send(client_app, items)
    assert first.status_code == 200, first.text
    rows = outcomes(first)
    evidence("N-11 one item hits an unexpected fault, one honest order", outcomes=rows)
    assert rows == {items[0]["id"]: ("retry_later", "server_error"), items[1]["id"]: ("accepted", None)}
    elsewhere = outcomes(other.send(client_app, [order_item("ORD-N11-" + "other".ljust(31, "0"),
                                                            other.cut - timedelta(minutes=30))]))
    assert set(elsewhere.values()) == {("accepted", None)}
    monkeypatch.setattr(held_work.HeldWork, "_one", real)
    again = outcomes(held.send(client_app, items))
    assert again == {items[0]["id"]: ("accepted", None), items[1]["id"]: ("duplicate", None)}
    assert len(list(held.db.collection("orders").stream())) == 2


def test_p2_company_lookup_limit_counts_all_addresses_of_one_ipv6_network_together(client_app, monkeypatch):
    monkeypatch.setattr(config, "CLIENT_IP_HEADER", "x-forwarded-for")
    monkeypatch.setattr(config, "COMPANY_LOOKUP_LIMIT_PER_HOUR", 2)

    def lookup(address):
        return client_app.get("/v1/companies/unknownco", headers={"x-forwarded-for": address}).status_code

    same_network = [lookup(f"2001:db8:1:2::{number}") for number in (1, 2, 3)]
    other_network = lookup("2001:db8:9:9::1")
    one_address = [lookup("203.0.113.7") for _ in range(3)]
    assert same_network == [404, 404, 429]
    assert other_network == 404
    assert one_address == [404, 404, 429]
    refused = client_app.get("/v1/companies/unknownco", headers={"x-forwarded-for": "203.0.113.7"})
    assert refused.status_code == 429 and 1 <= int(refused.headers["Retry-After"]) <= 3600
    assert "Try again in" in refused.json()["detail"]

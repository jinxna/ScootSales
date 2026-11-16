from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import os
import threading
import uuid

from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore
import pytest

from platform_service import devtool
from platform_service.plans import PlanStore, clean_subscription, load_catalogue

pytestmark = pytest.mark.skipif(not os.environ.get("FIRESTORE_EMULATOR_HOST"), reason="Shared Firestore emulator required")
NOW = datetime.now(timezone.utc)


@pytest.fixture
def db():
    client = firestore.Client(project=f"demo-v4-seed-{uuid.uuid4().hex[:12]}", credentials=AnonymousCredentials())
    yield client
    def clear(collection):
        for snap in collection.stream():
            for child in snap.reference.collections():
                clear(child)
            snap.reference.delete()
    for collection in client.collections():
        clear(collection)
    client.close()


def catalogue(plan_id):
    row = next(row for row in load_catalogue() if row["planId"] == plan_id)
    return {key:value for key,value in row.items() if key not in ("planId","visibility")}


def seed_cli(db):
    return devtool.main(["seed-plans","--apply","--project",db.project,"--confirm-project",db.project])


def versions(db, plan_id):
    return {snap.id:snap.to_dict() for snap in db.collection("plans").document(plan_id).collection("versions").stream()}


@pytest.mark.parametrize("plan_id", ["STANDARD","PROFESSIONAL"])
def test_production_seed_changes_only_visibility_for_customized_agreements(db, plan_id, capsys):
    store = PlanStore(db)
    original = catalogue(plan_id)
    store.write_version(plan_id, original, created_by="staff", visibility="private", operation_id="original")
    customized = {**original,"limits":{**original["limits"],"salesmen":37},
                  "prices":{"currency":"MYR","monthly":317,"yearly":3100},"notes":"Negotiated agreement"}
    store.write_version(plan_id, customized, created_by="staff", operation_id="negotiated")
    for tenant, pin in (("pinned",1),("follower",None)):
        store.apply_subscription_change(tenant, clean_subscription({"planId":plan_id,"planVersion":pin,
                                        "status":"active","addOns":{"salesmen":2}}),
                                        operation_id=tenant, now=NOW)
    store.retire(plan_id, operation_id="staff-retired")
    root = store.get_plan(plan_id)
    before_versions = versions(db, plan_id)
    subscriptions = {tenant:store.get_subscription(tenant) for tenant in ("pinned","follower")}
    effective = {tenant:store.effective(tenant, NOW) for tenant in subscriptions}
    assert seed_cli(db) == 0
    output = capsys.readouterr().out
    after = store.get_plan(plan_id)
    assert after["currentVersion"] == root["currentVersion"], "seed implicitly published catalogue content"
    assert versions(db, plan_id) == before_versions
    assert {key:value for key,value in after.items() if key not in ("visibility","updatedAt")} == {
        key:value for key,value in root.items() if key not in ("visibility","updatedAt")}
    assert after["visibility"] == "public" and after["status"] == "retired"
    for tenant in subscriptions:
        assert store.get_subscription(tenant) == subscriptions[tenant]
        assert store.effective(tenant, NOW) == effective[tenant]
    assert f"preserved {plan_id} v2" in output and "catalogue differs" in output
    assert "limits" in output and "prices" in output
    assert "Negotiated agreement" not in output and "317" not in output
    assert seed_cli(db) == 0
    assert store.get_plan(plan_id) == after
    assert versions(db, plan_id) == before_versions








def test_competing_first_seeds_create_only_one_version(db):
    gate = threading.Barrier(2)
    def seed():
        gate.wait(timeout=10)
        return seed_cli(db)
    with ThreadPoolExecutor(max_workers=2) as executor:
        pending = [executor.submit(seed) for _ in range(2)]
        assert [result.result(timeout=120) for result in pending] == [0,0]
    for row in load_catalogue():
        assert set(versions(db,row["planId"])) == {"1"}

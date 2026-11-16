from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest

if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
    pytest.skip("Needs the Firestore emulator.", allow_module_level=True)

from google.cloud import firestore

from platform_service.operations import (
    LeaseLost,
    OperationContext,
    OperationError,
    OperationStore,
    Step,
)

LEASE_SECONDS = 60


class SimulatedCrash(BaseException):
    pass


@pytest.fixture()
def client():
    return firestore.Client(project="demo-scoot-platform")


@pytest.fixture()
def collection():
    return f"operations_{uuid.uuid4().hex[:10]}"


def worker(client, collection, owner):
    return OperationStore(
        client, collection=collection, lease_seconds=LEASE_SECONDS, owner=owner
    )


@pytest.fixture()
def store(client, collection):
    return worker(client, collection, "worker-a")


def effect_count(client, op_id, step) -> int:
    snapshot = client.collection("effects").document(f"{op_id}-{step}").get()
    return (snapshot.to_dict() or {}).get("count", 0) if snapshot.exists else 0


def make_steps(client, names=("create", "grant"), *, crash_once_in=None, fail_in=None):
    crashed = {"done": False}

    def build(name):
        def apply(ctx: OperationContext):
            ref = client.collection("effects").document(f"{ctx.operation_id}-{name}")
            ref.set({"count": firestore.Increment(1)}, merge=True)
            if name == crash_once_in and not crashed["done"]:
                crashed["done"] = True
                raise SimulatedCrash()
            if name == fail_in:
                raise ValueError("boom")
            return {"step": name}

        def check(ctx: OperationContext) -> bool:
            ref = client.collection("effects").document(f"{ctx.operation_id}-{name}")
            return ref.get().exists

        return Step(name=name, apply=apply, check=check)

    return [build(name) for name in names]


def begin(store, key, *, params=None, field_names=("plan",), steps=("create", "grant"), action="grant"):
    return store.begin(
        idempotency_key=key,
        action=action,
        actor="staff@example.com",
        tenant_id="acme",
        reason="onboarding",
        ticket="T-1",
        field_names=list(field_names),
        params=params if params is not None else {"plan": "pro"},
        step_names=list(steps),
    )




def test_crash_between_effect_and_mark_is_finished_by_recovery(client, collection, store):
    op_id = begin(store, "k2")
    steps = make_steps(client, crash_once_in="create")

    with pytest.raises(SimulatedCrash):
        store.run(op_id, steps)

    stuck = store.get(op_id)
    assert stuck["status"] == "pending"
    assert stuck["steps"]["create"]["status"] == "pending"
    assert effect_count(client, op_id, "create") == 1

    other = worker(client, collection, "worker-b")
    assert other.recover({"grant": steps}) == []
    assert effect_count(client, op_id, "grant") == 0

    later = datetime.now(timezone.utc) + timedelta(seconds=LEASE_SECONDS + 5)
    assert other.recover({"grant": steps}, now=later) == [op_id]

    final = store.get(op_id)
    assert final["status"] == "completed"
    assert final["steps"]["create"]["result"] == {"alreadyApplied": True}
    assert effect_count(client, op_id, "create") == 1
    assert effect_count(client, op_id, "grant") == 1




def test_retried_request_maps_to_same_record_and_does_not_rerun(client, store):
    first = begin(store, "k3")
    assert begin(store, "k3") == first

    store.run(first, make_steps(client))
    again = store.run(first, make_steps(client))

    assert again["status"] == "completed"
    assert effect_count(client, first, "create") == 1
    assert effect_count(client, first, "grant") == 1






def test_live_lease_of_another_owner_blocks_run(client, collection, store):
    op_id = begin(store, "k6")
    with pytest.raises(SimulatedCrash):
        store.run(op_id, make_steps(client, crash_once_in="create"))

    blocked = worker(client, collection, "worker-b").run(op_id, make_steps(client))

    assert blocked["status"] == "pending"
    assert blocked["leaseOwner"] == "worker-a"
    assert effect_count(client, op_id, "grant") == 0




def test_worker_that_lost_its_lease_writes_nothing(client, collection, store):
    op_id = begin(store, "k-fence")
    reference = client.collection(collection).document(op_id)

    def taken_over(ctx: OperationContext):
        reference.update({"leaseOwner": "worker-b"})
        return {"step": "create"}

    steps = [Step("create", taken_over, lambda ctx: False), *make_steps(client, names=("grant",))]
    with pytest.raises(LeaseLost):
        store.run(op_id, steps)

    record = store.get(op_id)
    assert record["status"] == "pending"
    assert record["leaseOwner"] == "worker-b"
    assert record["steps"]["create"]["status"] == "pending"
    assert record["error"] is None
    assert effect_count(client, op_id, "grant") == 0

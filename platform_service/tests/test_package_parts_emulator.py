from __future__ import annotations

import os

import pytest

from platform_service.commands import CommandProblem, PlanProblem
from platform_service.operations import OperationStore
from platform_service.plans import PlanStore
from platform_service.subscriptions import ACTION_SUBSCRIPTION, SubscriptionService

from .support import seed_catalogue
from .test_plans_limits_emulator import grid
from .test_invitations_emulator import (
    clean_emulators,
    client,
    signer,
    store,
)

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)

TENANT = "t_northwind"
ADD_ONS = {key: 0 for key in ("salesmen", "supervisors", "managers", "products")}


def package_change(expected_revision=None):
    return {
        "kind": "put", "planId": "P2", "planVersion": None, "addOns": ADD_ONS, "status": "active",
        "billingInterval": None, "renewsAt": None, "trialEndsAt": None, "expectedRevision": expected_revision,
    }


def begin(runner, service, key, change):
    return runner.begin(
        idempotency_key=key, action=ACTION_SUBSCRIPTION, actor="ops@example.com", tenant_id=TENANT,
        reason="Package change", ticket=None, field_names=["change"],
        params={"tenantId": TENANT, "change": change, "requestedBy": "ops@example.com"},
        step_names=[step.name for step in service.subscription_steps()],
    )


def stores_agree(client, store, grid):
    subscription = PlanStore(client).get_subscription(TENANT)
    projected = grid["db"].collection("config").document("plan").get().to_dict()
    record = store.get(TENANT)
    return (
        subscription["planId"] == "P2"
        and projected["revision"] == subscription["revision"]
        and projected["planId"] == "P2"
        and record["planRef"] == "P2"
        and record["edition"] == projected["edition"]
    )


def test_a_failure_after_the_first_part_names_the_saved_parts_and_finish_makes_all_three_agree(
    store, client, signer, grid
):
    seed_catalogue(client)
    runner = OperationStore(client)
    service = SubscriptionService(client, runner, store, PlanStore(client))
    projection = grid["db"].collection("config").document("plan")
    projection.set({"revision": 99, "planId": "P2", "planVersion": 1})
    operation = begin(runner, service, "parts-1", package_change())

    with pytest.raises(PlanProblem):
        runner.run(operation, service.subscription_steps())

    failed = runner.get(operation)
    assert failed["status"] == "failed"
    assert service.package_failure(operation) == {
        "operationId": operation,
        "parts": {"subscription": "saved", "companyLimits": "pending", "companyRecord": "pending"},
    }
    assert not stores_agree(client, store, grid)

    projection.delete()
    finished = service.finish_package(operation, "ops@example.com")

    assert finished["status"] == "completed"
    assert service.package_parts(TENANT) == {
        "subscription": "saved", "companyLimits": "saved", "companyRecord": "saved",
    }
    assert stores_agree(client, store, grid)


def test_a_change_refused_before_any_write_reports_every_part_pending(store, client, signer, grid):
    seed_catalogue(client)
    runner = OperationStore(client)
    service = SubscriptionService(client, runner, store, PlanStore(client))
    operation = begin(runner, service, "parts-2", package_change(expected_revision=50))

    with pytest.raises(CommandProblem):
        runner.run(operation, service.subscription_steps())

    assert service.package_failure(operation)["parts"] == {
        "subscription": "pending", "companyLimits": "pending", "companyRecord": "pending",
    }
    assert PlanStore(client).get_subscription(TENANT)["planId"] == "T1"


def test_a_package_the_company_already_has_reports_all_parts_saved(store, client, signer, grid):
    seed_catalogue(client)
    runner = OperationStore(client)
    service = SubscriptionService(client, runner, store, PlanStore(client))
    operation = begin(runner, service, "parts-3", package_change())
    runner.run(operation, service.subscription_steps())
    revision = PlanStore(client).get_subscription(TENANT)["revision"]

    assert service.package_parts(TENANT, revision) == {
        "subscription": "saved", "companyLimits": "saved", "companyRecord": "saved",
    }
    assert service.package_parts(TENANT, revision + 1) == {
        "subscription": "pending", "companyLimits": "pending", "companyRecord": "pending",
    }

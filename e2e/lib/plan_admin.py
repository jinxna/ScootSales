import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from google.cloud import firestore  # noqa: E402

from platform_service.company_access import company_access  # noqa: E402
from platform_service.directory import DirectoryStore  # noqa: E402
from platform_service.operations import OperationStore  # noqa: E402
from platform_service.commands import CommandProblem  # noqa: E402
from platform_service.lifecycle import LIFECYCLES, LifecycleStore, TenantLifecycle  # noqa: E402
from platform_service.plans import UPGRADE_ONLY_MESSAGE, PlanStore, clean_subscription, clean_version  # noqa: E402
from platform_service.signing import Keyring, Signer  # noqa: E402
from platform_service.subscriptions import SubscriptionService  # noqa: E402
from platform_service.tests.support import seed_catalogue, seed_usage  # noqa: E402
from platform_service.usage_reconciler import UsageReconciler  # noqa: E402


def seed_active_lifecycle(client, access, tenant: str) -> None:
    reference = client.collection(LIFECYCLES).document(tenant)
    if not reference.get().exists:
        now = datetime.now(timezone.utc).replace(microsecond=0)
        reference.set({
            "tenantId": tenant, "state": "active", "previousState": None, "revision": 1, "stateSince": now,
            "graceEndsAt": None, "windowEndsAt": None, "retentionEndsAt": None, "reason": "E2E harness",
            "ticket": None, "updatedBy": "e2e", "updatedAt": now, "lastOperationId": "e2e", "activationReceiptId": None,
        })
    current = reference.get().to_dict()
    projection = TenantLifecycle(access)
    try:
        projection.current()
    except Exception:
        projection.project(LifecycleStore.projection(current))


def main() -> int:
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print("FIRESTORE_EMULATOR_HOST must be set.", file=sys.stderr)
        return 2
    request = json.load(sys.stdin)
    tenant = request["tenantId"]
    client = firestore.Client(project=request["platformProject"])
    seeds = dict(part.split("=", 1) for part in os.environ["PLATFORM_SIGNING_KEYS"].split(","))
    key_id = sorted(seeds)[0]
    store = DirectoryStore(client, keyring=Keyring.from_environment(), signer=Signer.from_seed(key_id, seeds[key_id]))
    runner = OperationStore(client)
    service = SubscriptionService(client, runner, store, PlanStore(client))

    def company_db():
        return company_access(store.get(tenant)["location"]).db

    results = []
    for step in request["steps"]:
        op = step["op"]
        if op == "catalogue":
            seed_catalogue(client)
            results.append({"op": op})
        elif op in ("private_plan", "public_plan"):
            content = clean_version({
                "name": step["planId"], "edition": step.get("edition", "basic"),
                "limits": step["limits"], "features": {},
                "prices": step.get("prices"),
                **({"quotaSchemaVersion": step["quotaSchemaVersion"]}
                   if "quotaSchemaVersion" in step else {}),
            })
            number, _ = PlanStore(client).write_version(
                step["planId"], content, created_by="test",
                visibility="public" if op == "public_plan" else "private",
            )
            results.append({"op": op, "planId": step["planId"], "version": number})
        elif op == "subscribe":
            change = clean_subscription({
                "planId": step["planId"],
                "planVersion": step.get("planVersion"),
                "billingInterval": step.get("billingInterval"),
                "addOns": step.get("addOns", {}),
            })
            steps = service.subscription_steps()
            operation_id = runner.begin(
                idempotency_key=f"e2e-{uuid.uuid4().hex}", action="subscription.change", actor="e2e",
                tenant_id=tenant, reason="E2E harness", ticket=None, field_names=sorted(change),
                params={"tenantId": tenant, "change": change, "requestedBy": "e2e"},
                step_names=[s.name for s in steps],
            )
            try:
                record = runner.run(operation_id, steps)
            except CommandProblem as problem:
                text = str(problem)
                if not step.get("reseed") or (UPGRADE_ONLY_MESSAGE not in text and " would " not in text
                                                      and "different limit scheme" not in text):
                    raise
                client.collection("subscriptions").document(tenant).delete()
                operation_id = runner.begin(
                    idempotency_key=f"e2e-{uuid.uuid4().hex}", action="subscription.change", actor="e2e",
                    tenant_id=tenant, reason="E2E harness reseed", ticket=None, field_names=sorted(change),
                    params={"tenantId": tenant, "change": change, "requestedBy": "e2e"},
                    step_names=[s.name for s in steps],
                )
                record = runner.run(operation_id, steps)
            if record.get("status") != "completed":
                raise SystemExit(f"subscription change did not complete: {record.get('status')}")
            seed_active_lifecycle(client, company_access(store.get(tenant)["location"]), tenant)
            results.append({"op": op, "planId": step["planId"], "status": record["status"]})
        elif op == "usage":
            plan = seed_usage(company_db())
            results.append({"op": op, "usage": plan["usage"]})
        elif op == "reconcile":
            report = UsageReconciler(client, store).reconcile(tenant)
            results.append({
                "op": op,
                "mismatch": report["mismatch"],
                "recorded": report["recorded"],
                "expected": report["expected"],
                "anomalies": report["anomalies"],
            })
        else:
            raise SystemExit(f"unknown step {op}")
    print(json.dumps(results))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

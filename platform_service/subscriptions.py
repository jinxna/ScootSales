from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any, Callable, Mapping

from google.cloud import firestore

from .commands import CommandProblem, PlanMissing, PlanProblem, UsageMissing
from .company_access import UNREACHABLE, CompanyAccess, company_access, retry_while_unreachable
from .directory import DirectoryError, DirectoryStore
from .operations import OperationContext, OperationStore, Step
from .mail import MailQueue
from .plans import PLAN_REQUESTS, PlanStore
from .seats import CONFIG, PLAN, counts_of, read_usage, usage_counts
from .signing import format_timestamp

log = logging.getLogger(__name__)

ACTION_PLAN_PUT = "plan.put"
ACTION_PLAN_RETIRE = "plan.retire"
ACTION_SUBSCRIPTION = "subscription.change"
ACTION_REFRESH = "subscription.refresh"

_RECORD_META = {"kind", "version", "issuedAt", "expiresAt"}

PART_SAVED = "saved"
PART_PENDING = "pending"
PART_UNKNOWN = "unknown"

PACKAGE_PARTS = {
    "subscription": "subscription",
    "companyLimits": "company limits",
    "companyRecord": "company record",
}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class SubscriptionService:
    def __init__(
        self,
        platform: firestore.Client,
        runner: OperationStore,
        directory: DirectoryStore,
        plans: PlanStore,
        *,
        access_for: Callable[[Mapping[str, Any]], CompanyAccess] = company_access,
        clock: Callable[[], datetime] = _utc_now,
    ) -> None:
        self.platform = platform
        self.runner = runner
        self.directory = directory
        self.plans = plans
        self.access_for = access_for
        self.clock = clock

    def recovery_actions(self) -> dict[str, list[Step]]:
        return {
            ACTION_PLAN_PUT: self.plan_put_steps(),
            ACTION_PLAN_RETIRE: self.plan_retire_steps(),
            ACTION_SUBSCRIPTION: self.subscription_steps(),
            ACTION_REFRESH: self.subscription_steps(),
        }

    def package_parts(self, tenant_id: str, revision: int | None = None) -> dict[str, str]:
        subscription = self.plans.get_subscription(tenant_id)
        if subscription is None or (revision is not None and subscription["revision"] < revision):
            return {name: PART_PENDING for name in PACKAGE_PARTS}
        parts = {"subscription": PART_SAVED}
        try:
            effective = self.plans.effective(tenant_id, self.clock())
        except PlanProblem:
            return {**parts, "companyLimits": PART_UNKNOWN, "companyRecord": PART_UNKNOWN}
        parts["companyLimits"] = self._limits_part(tenant_id, subscription, effective)
        parts["companyRecord"] = self._record_part(tenant_id, effective)
        return parts

    def _limits_part(self, tenant_id: str, subscription: Mapping[str, Any], effective: Mapping[str, Any]) -> str:
        try:
            projected = self._company_db(tenant_id).collection(CONFIG).document(PLAN).get().to_dict()
        except (*UNREACHABLE, DirectoryError, CommandProblem):
            return PART_UNKNOWN
        matches = bool(
            projected
            and projected.get("revision") == subscription["revision"]
            and projected.get("planId") == effective["planId"]
            and projected.get("quotaSchemaVersion") == effective["quotaSchemaVersion"]
            and projected.get("limits") == effective["limits"]
        )
        return PART_SAVED if matches else PART_PENDING

    def _record_part(self, tenant_id: str, effective: Mapping[str, Any]) -> str:
        try:
            payload = self.directory.get(tenant_id)
        except DirectoryError:
            return PART_UNKNOWN
        if payload is None:
            return PART_UNKNOWN
        return PART_SAVED if self._record_matches(payload, effective) else PART_PENDING

    def package_failure(self, operation_id: str) -> dict[str, Any]:
        record = self.runner.get(operation_id) or {}
        written = ((record.get("steps") or {}).get("write_subscription") or {})
        tenant_id = record.get("tenantId")
        if written.get("status") != "done" or not tenant_id:
            parts = {name: PART_PENDING for name in PACKAGE_PARTS}
        else:
            parts = self.package_parts(tenant_id, (written.get("result") or {}).get("revision"))
        return {"operationId": operation_id, "parts": parts}

    def reopen_package(self, operation_id: str, actor: str) -> list[Step]:
        record = self.runner.get(operation_id)
        if record is None or record.get("action") not in (ACTION_SUBSCRIPTION, ACTION_REFRESH):
            raise CommandProblem("Unknown package change.")
        if record.get("closed"):
            raise CommandProblem("Staff closed this package change. Start it again.")
        self.runner.reopen(operation_id, actor)
        return self.subscription_steps()

    def finish_package(self, operation_id: str, actor: str) -> dict[str, Any]:
        return self.runner.run(operation_id, self.reopen_package(operation_id, actor))

    def plan_put_steps(self) -> list[Step]:
        def apply(ctx: OperationContext) -> dict[str, int]:
            params = ctx.params
            number, _ = self.plans.write_version(
                params["planId"],
                params["content"],
                created_by=params["createdBy"],
                visibility=params.get("visibility"),
                based_on_version=params.get("basedOnVersion"),
                price_locked=params.get("priceLocked", False),
                operation_id=ctx.operation_id,
                now=self.clock(),
                seal=ctx.seal,
            )
            return {"version": number}

        def check(ctx: OperationContext) -> bool:
            return self.plans.version_written_by(ctx.params["planId"], ctx.operation_id)

        return [Step("write_version", apply, check)]

    def plan_retire_steps(self) -> list[Step]:
        def apply(ctx: OperationContext) -> dict[str, bool]:
            self.plans.retire(
                ctx.params["planId"], operation_id=ctx.operation_id, now=self.clock()
            )
            return {"retired": True}

        def check(ctx: OperationContext) -> bool:
            plan = self.plans.get_plan(ctx.params["planId"])
            return bool(plan and plan.get("status") == "retired")

        return [Step("retire", apply, check)]

    def subscription_steps(self) -> list[Step]:
        @retry_while_unreachable()
        def write_apply(ctx: OperationContext) -> dict[str, int]:
            change = ctx.params["change"]
            if change["kind"] == "put":
                target_id = change["planId"]
                target_number = change.get("planVersion")
            else:
                current = self.plans.get_subscription(ctx.params["tenantId"]) or {}
                target_id, target_number = current.get("planId"), current.get("planVersion")
            if target_id:
                target_plan = self.plans.get_plan(target_id)
                target_number = target_number or (target_plan or {}).get("currentVersion")
                target = self.plans.get_version(target_id, target_number) if target_number else None
                if target and target.get("quotaSchemaVersion", 1) == 2:
                    usage_counts(self._company_db(ctx.params["tenantId"]), quota_schema_version=2)
            revision = self.plans.apply_subscription_change(
                ctx.params["tenantId"],
                ctx.params["change"],
                operation_id=ctx.operation_id,
                now=self.clock(),
                seal=ctx.seal,
                decided_by=ctx.params.get("requestedBy"),
            )
            self._mail_approved_request(ctx.params["tenantId"], ctx.operation_id)
            return {"revision": revision}

        def write_check(ctx: OperationContext) -> bool:
            return self.plans.subscription_written_by(ctx.params["tenantId"], ctx.operation_id)

        @retry_while_unreachable()
        def project_apply(ctx: OperationContext) -> dict[str, int]:
            now = self.clock()
            effective = self.plans.effective(ctx.params["tenantId"], now)
            db = self._company_db(ctx.params["tenantId"])
            @firestore.transactional
            def project(transaction: firestore.Transaction) -> None:
                data = read_usage(transaction, db, required=effective["quotaSchemaVersion"] == 2)
                projected = db.collection(CONFIG).document(PLAN).get(transaction=transaction).to_dict() or {}
                if (projected.get("revision", 0) > effective["revision"]
                        or (projected.get("revision") == effective["revision"]
                            and projected.get("planId") == effective["planId"]
                            and projected.get("planVersion", 0) > effective["planVersion"])):
                    raise PlanMissing("A newer plan was projected. Reload and try again.")
                if effective["quotaSchemaVersion"] == 2:
                    if data is None or data.get("usageSchemaVersion") != 2:
                        raise UsageMissing("Canonical usage migration is required for this plan.")
                    counts_of(data)
                transaction.set(db.collection(CONFIG).document(PLAN), {**effective, "projectedAt": now})
            project(db.transaction())
            return {"revision": effective["revision"]}

        @retry_while_unreachable()
        def project_check(ctx: OperationContext) -> bool:
            subscription = self.plans.get_subscription(ctx.params["tenantId"])
            if subscription is None:
                return False
            db = self._company_db(ctx.params["tenantId"])
            effective = self.plans.effective(ctx.params["tenantId"], self.clock())
            if effective["quotaSchemaVersion"] == 2:
                usage_counts(db, quota_schema_version=2)
            projected = (
                db
                .collection(CONFIG)
                .document(PLAN)
                .get()
                .to_dict()
            )
            return bool(projected and projected.get("revision") == subscription["revision"]
                        and projected.get("planId") == effective["planId"]
                        and projected.get("quotaSchemaVersion") == effective["quotaSchemaVersion"]
                        and projected.get("limits") == effective["limits"])

        def resign_apply(ctx: OperationContext) -> dict[str, Any]:
            tenant_id = ctx.params["tenantId"]
            effective = self.plans.effective(tenant_id, self.clock())
            for _ in range(3):
                payload = self.directory.get(tenant_id)
                if payload is None:
                    raise CommandProblem("Unknown company.")
                if self._record_matches(payload, effective):
                    return {"planRef": effective["planId"], "edition": effective["edition"]}
                record = {k: v for k, v in payload.items() if k not in _RECORD_META}
                record["planRef"] = effective["planId"]
                record["edition"] = effective["edition"]
                try:
                    self.directory.put(record, expected_version=payload["version"])
                except DirectoryError as error:
                    if "stale version" not in str(error):
                        raise
                    continue
                return {"planRef": effective["planId"], "edition": effective["edition"]}
            raise CommandProblem("The company record changed while it was being updated.")

        def resign_check(ctx: OperationContext) -> bool:
            tenant_id = ctx.params["tenantId"]
            payload = self.directory.get(tenant_id)
            return payload is not None and self._record_matches(
                payload, self.plans.effective(tenant_id, self.clock())
            )

        return [
            Step("write_subscription", write_apply, write_check),
            Step("project_plan", project_apply, project_check),
            Step("resign_record", resign_apply, resign_check),
        ]

    def _mail_approved_request(self, tenant_id: str, operation_id: str) -> None:
        try:
            request = self.plans.approved_request(tenant_id, operation_id)
            if request is None:
                return
            company = self.directory.get(tenant_id) or {}
            result = self.plans.mail_plan_request_approved(
                MailQueue(self.platform), request=request, company_name=company.get("legalName") or tenant_id)
            self.plans.client.collection(PLAN_REQUESTS).document(tenant_id).update({"mail.decision": result})
        except Exception as error:
            logging.getLogger(__name__).error("plan request decision mail failed: %s", type(error).__name__)

    @staticmethod
    def _record_matches(payload: Mapping[str, Any], effective: Mapping[str, Any]) -> bool:
        return (
            payload.get("planRef") == effective["planId"]
            and payload.get("edition") == effective["edition"]
        )

    def _company_db(self, tenant_id: str) -> firestore.Client:
        payload = self.directory.get(tenant_id)
        if payload is None:
            raise CommandProblem("Unknown company.")
        return self.access_for(payload["location"]).db

    def _projection_is_stale(self, tenant_id: str, now: datetime) -> str | None:
        effective = self.plans.effective(tenant_id, now)
        projected = (
            self._company_db(tenant_id).collection(CONFIG).document(PLAN).get().to_dict() or {}
        )
        if projected.get("revision", 0) < effective["revision"]:
            return f"r{effective['revision']}"
        if (
            projected.get("planVersion") == effective["planVersion"]
            and projected.get("planId") == effective["planId"]
            and projected.get("quotaSchemaVersion") == effective["quotaSchemaVersion"]
            and projected.get("edition") == effective["edition"]
        ):
            return None
        return f"v{int(effective['planVersion'])}"

    def refresh_plans(self, now: datetime | None = None, *, actor: str = "refresh") -> dict[str, list[str]]:
        moment = now or self.clock()
        refreshed: list[str] = []
        failed: list[str] = []
        for subscription in self.plans.list_subscriptions():
            tenant_id = subscription["tenantId"]
            until = subscription.get("validUntil")
            expired = until is not None and until <= moment
            try:
                stale_reason = self._projection_is_stale(tenant_id, moment)
            except Exception as error:
                log.error("plan refresh check failed: %s", type(error).__name__)
                failed.append(tenant_id)
                continue
            if not expired and stale_reason is None:
                continue
            reason = format_timestamp(until) if expired else stale_reason
            params = {"tenantId": tenant_id, "change": {"kind": "refresh"}, "requestedBy": actor}
            steps = self.subscription_steps()
            try:
                operation_id = self.runner.begin(
                    idempotency_key=f"refresh:{tenant_id}:{reason}",
                    action=ACTION_REFRESH,
                    actor=actor,
                    tenant_id=tenant_id,
                    reason="Plan refresh",
                    ticket=None,
                    field_names=sorted(params),
                    params=params,
                    step_names=[step.name for step in steps],
                )
                self.runner.run(operation_id, steps)
                refreshed.append(tenant_id)
            except Exception as error:
                log.error("plan refresh failed: %s", type(error).__name__)
                failed.append(tenant_id)
        return {"refreshed": refreshed, "failed": failed}

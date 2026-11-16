from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any, Callable, Mapping, Sequence

from fastapi import HTTPException, status
from google.cloud import firestore

from .commands import CommandProblem, UsageMissing, run_command
from .company_access import CompanyAccess, company_access, require_module_grant
from .operations import OperationContext, OperationStore, Step
from .orderable import is_orderable
from .plans import PlanStore
from .seats import check_plan_projection, move_counts, read_usage, usage_counts
from .tenancy import TenantContext

PRODUCTS = "products"
AUDIT_LOGS = "system_audit_logs"
ACTION_AVAILABILITY = "products.availability"
ACTION_DELETE = "products.delete"
MAX_CHANGES = 400
MAX_DELETES = 100

_PRODUCT_ID = re.compile(r"^[^/\x00-\x1f\x7f]{1,200}$")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _bad(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=detail)


def _product_id(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not _PRODUCT_ID.fullmatch(value)
        or value in (".", "..")
        or value.startswith("__")
    ):
        raise _bad("Check the product list and try again.")
    return value


def clean_changes(items: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    if not 1 <= len(items) <= MAX_CHANGES:
        raise _bad(f"Change between 1 and {MAX_CHANGES} products at a time.")
    changes = []
    for item in items:
        if not isinstance(item.get("visible"), bool):
            raise _bad("Check the product list and try again.")
        changes.append({"productId": _product_id(item.get("productId")), "visible": item["visible"]})
    if len({change["productId"] for change in changes}) != len(changes):
        raise _bad("Each product can appear once.")
    return changes


def clean_ids(items: Sequence[Any]) -> list[str]:
    if not 1 <= len(items) <= MAX_DELETES:
        raise _bad(f"Delete between 1 and {MAX_DELETES} products at a time.")
    ids = [_product_id(item) for item in items]
    if len(set(ids)) != len(ids):
        raise _bad("Each product can appear once.")
    return ids


class ProductCommands:
    def __init__(
        self,
        platform: Any,
        runner: OperationStore,
        *,
        access_for: Callable[[Mapping[str, Any]], CompanyAccess] = company_access,
        clock: Callable[[], datetime] = _utc_now,
        plans: PlanStore | None = None,
    ) -> None:
        self.runner = runner
        self.access_for = access_for
        self.clock = clock
        self.plans = plans or PlanStore(platform)

    def _access(self, params: Mapping[str, Any]) -> CompanyAccess:
        return self.access_for(
            {
                "projectId": params["projectId"],
                "databaseId": params["databaseId"],
                "authTenantId": params["authTenantId"],
            }
        )

    @staticmethod
    def _params(ctx: TenantContext, **more: Any) -> dict[str, Any]:
        location = ctx.record["location"]
        return {
            "tenantId": ctx.tenant_id,
            "workspace": ctx.workspace,
            "projectId": location["projectId"],
            "databaseId": location["databaseId"],
            "authTenantId": location["authTenantId"],
            "requestedBy": ctx.uid,
            **more,
        }

    def recovery_actions(self) -> dict[str, list[Step]]:
        return {
            ACTION_AVAILABILITY: self.availability_steps(),
            ACTION_DELETE: self.delete_steps(),
        }

    def set_availability(
        self, ctx: TenantContext, idempotency_key: str, items: Sequence[Mapping[str, Any]]
    ) -> dict[str, Any]:
        changes = clean_changes(items)
        access = self.access_for(ctx.record["location"])
        require_module_grant(access, ctx.uid, "products", "edit")
        run_command(
            self.runner,
            key=f"{ctx.workspace}:{idempotency_key}",
            action=ACTION_AVAILABILITY,
            actor=ctx.uid,
            tenant_id=ctx.tenant_id,
            reason="Product availability",
            params=self._params(ctx, changes=changes),
            steps=self.availability_steps(),
            fallback="The products could not be changed. Try again.",
            what="This change",
        )
        try:
            usage: dict[str, int] | None = usage_counts(access.db)
        except UsageMissing:
            usage = None
        return {"changed": len(changes), "usage": usage}

    def availability_steps(self) -> list[Step]:
        def apply(ctx: OperationContext) -> dict[str, int]:
            self._apply_availability(ctx.params)
            return {"changed": len(ctx.params["changes"])}

        def check(ctx: OperationContext) -> bool:
            db = self._access(ctx.params).db
            for change in ctx.params["changes"]:
                data = db.collection(PRODUCTS).document(change["productId"]).get().to_dict()
                if data is None or data.get("isVisible") is not change["visible"]:
                    return False
                if data.get("status") != ("active" if change["visible"] else "hidden"):
                    return False
            return True

        return [Step("apply_availability", apply, check)]

    def _apply_availability(self, params: Mapping[str, Any]) -> None:
        db = self._access(params).db
        changes = params["changes"]
        refs = [db.collection(PRODUCTS).document(change["productId"]) for change in changes]
        effective = (
            self.plans.effective(params["tenantId"], self.clock())
            if any(change["visible"] for change in changes)
            else None
        )
        limits = effective["limits"] if effective is not None else None

        @firestore.transactional
        def apply(transaction: firestore.Transaction) -> None:
            found = {snapshot.id: snapshot for snapshot in transaction.get_all(refs)}
            usage = read_usage(transaction, db, required=limits is not None)
            delta = 0
            updates = []
            for change, reference in zip(changes, refs):
                snapshot = found.get(reference.id)
                if snapshot is None or not snapshot.exists:
                    raise CommandProblem("A product in this list no longer exists. Reload and try again.")
                data = snapshot.to_dict() or {}
                fields = {
                    "isVisible": change["visible"],
                    "status": "active" if change["visible"] else "hidden",
                }
                delta += int(is_orderable({**data, **fields}, reference.id)) - int(
                    is_orderable(data, reference.id)
                )
                updates.append((reference, fields))
            if delta > 0 and usage is None:
                raise UsageMissing("The usage counters are not set up for this company.")
            if delta > 0:
                check_plan_projection(transaction, db, effective, now=self.clock())
            move_counts(transaction, db, usage, {"products": delta}, limits if delta > 0 else None)
            for reference, fields in updates:
                transaction.update(reference, {**fields, "updatedAt": firestore.SERVER_TIMESTAMP})

        apply(db.transaction(max_attempts=10))

    def delete_products(
        self, ctx: TenantContext, idempotency_key: str, items: Sequence[Any]
    ) -> dict[str, int]:
        ids = clean_ids(items)
        access = self.access_for(ctx.record["location"])
        require_module_grant(access, ctx.uid, "products", "delete")
        record = run_command(
            self.runner,
            key=f"{ctx.workspace}:{idempotency_key}",
            action=ACTION_DELETE,
            actor=ctx.uid,
            tenant_id=ctx.tenant_id,
            reason="Products deleted",
            params=self._params(ctx, productIds=ids),
            steps=self.delete_steps(),
            fallback="The products could not be deleted. Try again.",
        )
        result = record["steps"]["delete_products"].get("result") or {}
        return {"deleted": int(result.get("deleted", 0))}

    def delete_steps(self) -> list[Step]:
        def apply(ctx: OperationContext) -> dict[str, int]:
            return {"deleted": self._delete(ctx.params)}

        def check(ctx: OperationContext) -> bool:
            db = self._access(ctx.params).db
            return not any(
                db.collection(PRODUCTS).document(product_id).get().exists
                for product_id in ctx.params["productIds"]
            )

        return [Step("delete_products", apply, check)]

    def _actor(self, db: firestore.Client, uid: str) -> dict[str, str]:
        index = db.collection("user_access").document(uid).get().to_dict() or {}
        profile_id = index.get("userDocId")
        profile = (
            db.collection("users").document(profile_id).get().to_dict() or {} if profile_id else {}
        )
        return {
            "actorEmail": str(index.get("email") or ""),
            "actorName": str(profile.get("name") or ""),
            "actorRole": str(index.get("role") or ""),
        }

    def _delete(self, params: Mapping[str, Any]) -> int:
        db = self._access(params).db
        refs = [db.collection(PRODUCTS).document(product_id) for product_id in params["productIds"]]
        actor = {"actorUid": params["requestedBy"], **self._actor(db, params["requestedBy"])}

        @firestore.transactional
        def delete(transaction: firestore.Transaction) -> int:
            found = {snapshot.id: snapshot for snapshot in transaction.get_all(refs)}
            usage = read_usage(transaction, db, required=False)
            deleted = 0
            delta = 0
            for reference in refs:
                snapshot = found.get(reference.id)
                if snapshot is None or not snapshot.exists:
                    continue
                transaction.delete(reference)
                transaction.set(
                    db.collection(AUDIT_LOGS).document(),
                    {
                        "action": "deleted",
                        "entityType": PRODUCTS,
                        "entityId": reference.id,
                        "summary": f"Deleted {PRODUCTS} record {reference.id}",
                        **{key: actor[key] for key in ("actorUid", "actorEmail", "actorName", "actorRole")},
                        "metadata": {},
                        "createdAt": firestore.SERVER_TIMESTAMP,
                    },
                )
                deleted += 1
                delta -= int(is_orderable(snapshot.to_dict() or {}, reference.id))
            move_counts(transaction, db, usage, {"products": delta}, None)
            return deleted

        return delete(db.transaction(max_attempts=10))

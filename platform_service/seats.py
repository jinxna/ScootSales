from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping
from google.cloud import firestore
from .commands import CommandProblem, PlanLimit, PlanMissing, UsageMissing

LEGACY_POOLS = ("salesmen", "supervisors", "managers")
POOLS = ("salesmen", "supervisors", "admins", "branchManagers")
LIMIT_KEYS = (*LEGACY_POOLS, "products")
POOL_BY_ROLE = {"salesman": "salesmen", "supervisor": "supervisors",
                "admin": "admins", "branch_manager": "branchManagers"}
SEAT_CLASS_BY_ROLE = {"salesman": "salesman", "supervisor": "supervisor",
                      "admin": "manager", "branch_manager": "manager", "developer": "none"}
CONFIG, USAGE, PLAN = "config", "usage", "plan"
MAINTENANCE = "membershipMaintenance"
_ONE = {"salesmen": "salesman", "supervisors": "supervisor", "managers": "manager",
        "admins": "admin", "branchManagers": "branch manager", "products": "product"}


POOL_LABELS = {"salesmen": "Salespeople", "supervisors": "Supervisors", "managers": "Managers",
               "admins": "Admins", "branchManagers": "Branch managers", "products": "Products"}


def usage_rows(counts: Mapping[str, int], limits: Mapping[str, Any]) -> list[dict[str, Any]]:
    return [{"key": key, "label": POOL_LABELS[key], "used": counts[key], "limit": limits[key]}
            for key in limits]


def limit_keys(schema_version: int) -> tuple[str, ...]:
    if type(schema_version) is not int or schema_version not in (1, 2):
        raise ValueError("Unsupported quota schema version.")
    return LIMIT_KEYS if schema_version == 1 else (*POOLS, "products")


def limit_text(key: str, limit: int) -> str:
    noun = _ONE[key] if limit == 1 else ("branch managers" if key == "branchManagers" else key)
    first = "Hide or remove one first" if key == "products" else "Remove or suspend one first"
    return f"Your plan allows {limit} {noun}. {first}, or ask to upgrade."


def pool_for_role(role: Any) -> str | None:
    return POOL_BY_ROLE.get(role) if isinstance(role, str) else None


def seat_class_for_role(role: Any) -> str | None:
    return SEAT_CLASS_BY_ROLE.get(role) if isinstance(role, str) else None


def active_admin(data: Mapping[str, Any]) -> bool:
    return (data.get("role") == "admin" and data.get("status") == "active"
            and data.get("invitationState") != "pending")


def usage_ref(db: firestore.Client) -> Any:
    return db.collection(CONFIG).document(USAGE)


def _available(data: Mapping[str, Any]) -> None:
    if data.get(MAINTENANCE):
        raise UsageMissing("Membership maintenance is in progress. Try again after it finishes.", retryable=True)


def read_usage(transaction: firestore.Transaction, db: firestore.Client, *, required: bool) -> dict[str, Any] | None:
    snapshot = usage_ref(db).get(transaction=transaction)
    if snapshot.exists:
        data = snapshot.to_dict() or {}
        _available(data)
        return data
    if required:
        raise UsageMissing("The usage counters are not set up for this company.")
    return None


def _integer(value: Any) -> bool:
    return type(value) is int and value >= 0


def check_plan_projection(transaction: firestore.Transaction, db: firestore.Client,
                          effective: Mapping[str, Any], *, now: datetime | None = None) -> None:
    schema = effective.get("quotaSchemaVersion", 1)
    try:
        keys = limit_keys(schema)
    except ValueError:
        raise PlanMissing("The quota schema is unsupported.") from None
    limits = effective.get("limits")
    if (not isinstance(limits, Mapping) or set(limits) != set(keys)
            or any(value is not None and not _integer(value) for value in limits.values())):
        raise PlanMissing("The plan limits are incomplete or invalid.")
    until = effective.get("validUntil")
    if until is not None and (not isinstance(until, datetime) or until <= (now or datetime.now(timezone.utc))):
        raise PlanMissing("The effective plan expired. Reload and try again.")
    snapshot = db.collection(CONFIG).document(PLAN).get(transaction=transaction)
    if not snapshot.exists:
        if schema == 1:
            return
        raise PlanMissing("The plan projection is not ready. Reload after the subscription change finishes.")
    projected = snapshot.to_dict() or {}
    projected_revision, revision = projected.get("revision", 0), effective.get("revision", 0)
    projected_version, version = projected.get("planVersion", 0), effective.get("planVersion", 0)
    if (projected.get("quotaSchemaVersion", 1) != schema
            or any(type(value) is not int or value < 0 for value in
                   (projected_revision, revision, projected_version, version))
            or projected_revision > revision
            or (projected_revision == revision and (
                projected.get("planId") != effective.get("planId") or projected_version > version))):
        raise PlanMissing("The plan changed. Reload and try again.")


def counts_of(data: Mapping[str, Any]) -> dict[str, int]:
    _available(data)
    schema = data.get("usageSchemaVersion", 1)
    try:
        keys = limit_keys(schema)
    except ValueError:
        raise UsageMissing("The usage schema is unsupported.") from None
    native = data.get("seats")
    if (not isinstance(native, Mapping) or set(native) != set(keys[:-1])
            or not all(_integer(native[key]) for key in keys[:-1])
            or not _integer(data.get("products"))):
        raise UsageMissing("The usage counters are incomplete or invalid. Run the reviewed migration.")
    if schema == 2 and (not _integer(data.get("activeAdmins")) or data["activeAdmins"] > native["admins"]):
        raise UsageMissing("The active admin count is unavailable or invalid.")
    return {**native, "products": data["products"]}


def project_counts(counts: Mapping[str, int], native_schema: int, target_schema: int) -> dict[str, int]:
    limit_keys(target_schema)
    if native_schema == target_schema:
        return dict(counts)
    if target_schema == 2:
        raise UsageMissing("Canonical usage migration is required for this plan.")
    return {"salesmen": counts["salesmen"], "supervisors": counts["supervisors"],
            "managers": counts["admins"] + counts["branchManagers"], "products": counts["products"]}


def move_counts(transaction: firestore.Transaction, db: firestore.Client,
                data: Mapping[str, Any] | None, deltas: Mapping[str, int],
                limits: Mapping[str, Any] | None, *, active_admin_delta: int = 0) -> None:
    if type(active_admin_delta) is not int:
        raise UsageMissing("Invalid active admin transition.")
    if set(deltas) - set((*POOLS, "products")) or any(type(v) is not int for v in deltas.values()):
        raise UsageMissing("Invalid quota transition.")
    if data is None:
        if active_admin_delta or any(delta > 0 for delta in deltas.values()):
            raise UsageMissing("The usage counters are not set up for this company.")
        return
    current = counts_of(data)
    native_schema = data.get("usageSchemaVersion", 1)
    quota_schema = native_schema
    if limits is not None:
        quota_schema = 1 if set(limits) == set(LIMIT_KEYS) else 2
        if (set(limits) != set(limit_keys(quota_schema))
                or any(v is not None and not _integer(v) for v in limits.values())):
            raise UsageMissing("The plan quota limits are incomplete or invalid.")
    if active_admin_delta < 0 and native_schema != 2:
        raise UsageMissing("Canonical usage migration is required for active admin reductions.")
    after_admins = data.get("activeAdmins", 0) + active_admin_delta
    if active_admin_delta < 0 and after_admins < 1:
        raise CommandProblem("The final active admin cannot be removed or suspended.")
    quota_delta = dict(deltas)
    if quota_schema == 1:
        quota_delta["managers"] = quota_delta.pop("admins", 0) + quota_delta.pop("branchManagers", 0)
    projected = project_counts(current, native_schema, quota_schema)
    for key, delta in quota_delta.items():
        limit = None if limits is None else limits[key]
        if delta > 0 and limit is not None and projected[key] + delta > limit:
            raise PlanLimit(limit_text(key, limit))
    native_delta = dict(deltas)
    if native_schema == 1:
        native_delta["managers"] = native_delta.pop("admins", 0) + native_delta.pop("branchManagers", 0)
    change: dict[str, Any] = {}
    for key, delta in native_delta.items():
        if delta:
            after = current[key] + delta
            if native_schema == 2 and after < 0:
                raise UsageMissing("The quota transition disagrees with recorded usage.")
            change["products" if key == "products" else f"seats.{key}"] = max(after, 0)
    if native_schema == 2:
        if after_admins > current["admins"] + native_delta.get("admins", 0):
            raise UsageMissing("The active admin transition disagrees with recorded usage.")
        if active_admin_delta:
            change["activeAdmins"] = after_admins
    if change:
        transaction.update(usage_ref(db), {**change, "updatedAt": firestore.SERVER_TIMESTAMP})


def usage_counts(db: firestore.Client, *, quota_schema_version: int = 1) -> dict[str, int]:
    snapshot = usage_ref(db).get()
    if not snapshot.exists:
        raise UsageMissing("The usage counters are not set up for this company.")
    data = snapshot.to_dict() or {}
    return project_counts(counts_of(data), data.get("usageSchemaVersion", 1), quota_schema_version)

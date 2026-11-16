from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any, Callable, Mapping

from google.cloud import firestore

from .commands import CommandProblem, UsageMissing
from .company_access import CompanyAccess, company_access
from .directory import DirectoryStore
from .orderable import is_orderable
from .seats import MAINTENANCE, POOLS, active_admin, counts_of, pool_for_role, seat_class_for_role, usage_ref

REPORTS = "usage_reports"
_OPEN_INVITATION = ("open", "redeeming")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class UsageReconciler:
    def __init__(
        self,
        platform: firestore.Client,
        directory: DirectoryStore,
        *,
        access_for: Callable[[Mapping[str, Any]], CompanyAccess] = company_access,
        clock: Callable[[], datetime] = _utc_now,
    ) -> None:
        self.platform = platform
        self.directory = directory
        self.access_for = access_for
        self.clock = clock

    def reconcile(self, tenant_id: str) -> dict[str, Any]:
        record = self.directory.get(tenant_id)
        if record is None:
            raise CommandProblem("Unknown company.")
        now = self.clock()
        db = self.access_for(record["location"]).db
        invitations = self._invitations(tenant_id)

        expected = {pool: 0 for pool in POOLS}
        active_admins = 0
        anomalies: list[str] = []
        for snapshot in db.collection("user_access").select(
            ["role", "seatHeld", "status", "invitationState", "seatClass"]).stream():
            data = snapshot.to_dict() or {}
            role = data.get("role")
            pool = pool_for_role(role)
            held = data.get("seatHeld") is True
            should_hold = role != "developer" and (data.get("status") == "active" or (
                data.get("invitationState") == "pending"
                and self._invitation_allows(invitations.get(snapshot.id), now)
            ))
            if (
                held != should_hold
                or data.get("seatClass") != seat_class_for_role(role)
                or seat_class_for_role(role) is None
            ):
                anomalies.append(snapshot.id)
            if held and pool:
                expected[pool] += 1
            if active_admin(data):
                active_admins += 1
        expected["products"] = sum(
            1
            for product in db.collection("products").select(["isVisible", "visible", "status", "productStatus"]).stream()
            if is_orderable(product.to_dict() or {}, product.id)
        )

        stored = usage_ref(db).get()
        data = stored.to_dict() or {} if stored.exists else {}
        try:
            recorded = counts_of(data) if stored.exists else None
        except UsageMissing:
            recorded = None
            anomalies.append("config/usage")
        schema = data.get("usageSchemaVersion", 1) if stored.exists else None
        if schema != 2 or data.get("activeAdmins") != active_admins:
            anomalies.append("config/usage:canonical-admin-state")
        if data.get(MAINTENANCE):
            anomalies.append("config/usage:maintenance")
        report = {
            "tenantId": tenant_id,
            "recorded": recorded,
            "expected": expected,
            "recordedUsageSchemaVersion": schema,
            "expectedUsageSchemaVersion": 2,
            "recordedActiveAdmins": data.get("activeAdmins"),
            "expectedActiveAdmins": active_admins,
            "mismatch": (recorded != expected or schema != 2 or data.get("activeAdmins") != active_admins),
            "anomalies": sorted(set(anomalies)),
            "createdAt": now,
        }
        self.platform.collection(REPORTS).document(f"{tenant_id}_{uuid.uuid4().hex[:16]}").set(report)
        return report

    def _invitations(self, tenant_id: str) -> dict[str, dict[str, Any]]:
        query = self.platform.collection("invitations").where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)
        )
        rows: dict[str, dict[str, Any]] = {}
        for snapshot in query.select(["uid", "status", "expiresAt"]).stream():
            row = snapshot.to_dict() or {}
            rows[row.get("uid")] = row
        return rows

    @staticmethod
    def _invitation_allows(row: Mapping[str, Any] | None, now: datetime) -> bool:
        if row is None:
            return True
        expires = row.get("expiresAt")
        return row.get("status") in _OPEN_INVITATION and (
            not isinstance(expires, datetime) or expires > now
        )

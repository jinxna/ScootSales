from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Callable, Mapping

from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.responses import JSONResponse
from google.cloud import firestore

from . import auth, config
from .directory import DirectoryError, DirectoryStore
from .signing import format_timestamp

GRANTS = "support_grants"
SUPPORT_GRANTS_READ = "support.grants.read"

_COMMERCIAL = ("commercial.read",)
_ACCOUNTS = ("accounts.manage", "companies.create")

ROLE_CAPABILITIES: Mapping[str, Mapping[str, Any]] = {
    "owner": {
        "capabilities": (
            "inbox", "companies", "onboarding", "invoices", "payments", "packages", "staff", "audit", "settings",
            *_COMMERCIAL, *_ACCOUNTS, "owner.tools", SUPPORT_GRANTS_READ, "setup.enter",
        ),
        "home": "inbox",
    },
    "operator": {
        "capabilities": (
            "inbox", "companies", "onboarding", "invoices", "payments", "packages", "audit",
            *_COMMERCIAL, *_ACCOUNTS,
        ),
        "home": "inbox",
    },
    "engineer": {
        "capabilities": ("companies", "onboarding", *_COMMERCIAL, "setup.enter"),
        "home": "companies",
    },
    "support": {
        "capabilities": ("supportHome", SUPPORT_GRANTS_READ),
        "home": "supportHome",
    },
}

if set(ROLE_CAPABILITIES) != set(config.STAFF_ROLE_NAMES):
    raise RuntimeError("Every staff role needs capabilities and a home section.")


def capabilities_of(role: str) -> list[str]:
    return list(ROLE_CAPABILITIES.get(role, {}).get("capabilities", ()))


def with_capabilities(profile: Mapping[str, Any]) -> dict[str, Any]:
    entry = ROLE_CAPABILITIES.get(profile.get("role", ""), {})
    return {**profile, "capabilities": list(entry.get("capabilities", ())), "home": entry.get("home", "account")}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def install_support_routes(
    app: FastAPI,
    *,
    database: firestore.Client,
    directory: DirectoryStore,
    verified_staff: Callable[..., auth.StaffIdentity],
    clock: Callable[[], datetime] = _utc_now,
) -> None:
    def company_of(tenant_id: str, names: dict[str, tuple[str | None, str | None]]) -> tuple[str | None, str | None]:
        if tenant_id not in names:
            try:
                record = directory.get(tenant_id)
            except DirectoryError:
                record = None
            names[tenant_id] = ((record or {}).get("legalName"), (record or {}).get("workspace"))
        return names[tenant_id]

    @app.get("/staff/v1/support/home")
    def support_home(who: auth.StaffIdentity = Depends(verified_staff)) -> JSONResponse:
        if SUPPORT_GRANTS_READ not in capabilities_of(who.role):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "Only support staff and the owner can open this.")
        query = database.collection(GRANTS).where(filter=firestore.FieldFilter("status", "==", "active"))
        if who.role != "owner":
            query = query.where(filter=firestore.FieldFilter("staffEmail", "==", who.email))
        now = clock()
        names: dict[str, tuple[str | None, str | None]] = {}
        live = []
        for snapshot in query.stream():
            data = snapshot.to_dict() or {}
            expires = data.get("expiresAt")
            if not isinstance(expires, datetime) or expires <= now:
                continue
            company, workspace = company_of(str(data.get("tenantId", "")), names)
            live.append({
                "grantId": snapshot.id, "tenantId": data.get("tenantId"), "companyName": company,
                "workspace": workspace, "staffEmail": data.get("staffEmail"), "scope": data.get("scope"),
                "task": data.get("reason"), "expiresAt": format_timestamp(expires),
                "createdAt": format_timestamp(data["createdAt"]) if isinstance(data.get("createdAt"), datetime) else None,
            })
        live.sort(key=lambda row: (row["expiresAt"], row["grantId"]))
        return JSONResponse({"grants": live}, headers={"Cache-Control": "no-store"})

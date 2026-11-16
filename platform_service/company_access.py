from __future__ import annotations

import json
import os
import threading
from contextlib import contextmanager
from pathlib import Path
from dataclasses import dataclass
from typing import Any, Mapping

import firebase_admin
from fastapi import HTTPException, status
from firebase_admin import auth as admin_auth
from firebase_admin import credentials
from google.api_core.exceptions import GoogleAPICallError
from google.auth.credentials import AnonymousCredentials
from google.auth.exceptions import TransportError
from google.cloud import firestore
from google.oauth2 import service_account

from . import auth as platform_auth
from . import config
from .operations import RetryLater
from .records import PLATFORM_PROJECT_REFUSAL


@dataclass(frozen=True)
class CompanyAccess:
    project_id: str
    database_id: str
    auth_tenant_id: str | None
    db: firestore.Client
    auth: admin_auth.Client


_LOCK = threading.Lock()
_APPS: dict[str, firebase_admin.App] = {}
_DATABASES: dict[tuple[str, str], firestore.Client] = {}
_AUTH_CLIENTS: dict[tuple[str, str | None], admin_auth.Client] = {}
_PLATFORM_AUTH: dict[str, admin_auth.Client] = {}


def _emulated() -> bool:
    return platform_auth.emulator_mode() or bool(
        os.environ.get("FIRESTORE_EMULATOR_HOST", "").strip()
    )


class CompanyUnreachable(RuntimeError):
    pass


UNREACHABLE = (CompanyUnreachable, GoogleAPICallError, TransportError)


@contextmanager
def retry_while_unreachable():
    try:
        yield
    except UNREACHABLE:
        raise RetryLater("The company project cannot be reached yet.") from None


def require_company_credentials() -> None:
    if _emulated():
        return
    if not config.COMPANY_CREDENTIALS_DIR or not Path(config.COMPANY_CREDENTIALS_DIR).is_dir():
        raise RuntimeError("PLATFORM_COMPANY_CREDENTIALS_DIR must name the directory of company key files.")


def _key_file(project_id: str) -> Path | None:
    if _emulated():
        return None
    require_company_credentials()
    path = Path(config.COMPANY_CREDENTIALS_DIR) / f"{project_id}.json"
    if Path(project_id).name != project_id:
        raise CompanyUnreachable("This company project name is not valid.")
    if not path.is_file():
        return None
    try:
        key_project = json.loads(path.read_text(encoding="utf-8")).get("project_id")
    except (OSError, ValueError, AttributeError):
        raise RuntimeError("The service account key of this company project cannot be read.") from None
    if key_project != project_id:
        raise RuntimeError("The service account key does not belong to this company project.")
    return path


def service_email() -> str | None:
    if _emulated():
        return None
    import google.auth
    from google.auth.exceptions import GoogleAuthError
    from google.auth.transport.requests import Request

    try:
        credentials_, _ = google.auth.default()
        email = getattr(credentials_, "service_account_email", None)
        if not email or email == "default":
            credentials_.refresh(Request())
            email = getattr(credentials_, "service_account_email", None)
    except GoogleAuthError:
        return None
    return email if email and email != "default" else None


def _app(project_id: str) -> firebase_admin.App:
    app = _APPS.get(project_id)
    if app is None:
        key_file = _key_file(project_id)
        app = firebase_admin.initialize_app(
            credentials.Certificate(str(key_file)) if key_file else credentials.ApplicationDefault(),
            options={"projectId": project_id},
            name=f"company:{project_id}",
        )
        _APPS[project_id] = app
    return app


def _database(project_id: str, database_id: str) -> firestore.Client:
    client = _DATABASES.get((project_id, database_id))
    if client is None:
        key_file = _key_file(project_id)
        client = firestore.Client(
            project=project_id,
            database=database_id,
            credentials=AnonymousCredentials()
            if os.environ.get("FIRESTORE_EMULATOR_HOST", "").strip()
            else service_account.Credentials.from_service_account_file(str(key_file)) if key_file else None,
        )
        _DATABASES[(project_id, database_id)] = client
    return client


def _refuse_platform_project(project_id: str) -> None:
    if str(project_id).strip().lower() == config.PLATFORM_PROJECT_ID.lower():
        raise CompanyUnreachable(PLATFORM_PROJECT_REFUSAL)


def company_access(location: Mapping[str, Any]) -> CompanyAccess:
    project_id = location["projectId"]
    database_id = location.get("databaseId") or "(default)"
    tenant_id = location.get("authTenantId")
    _refuse_platform_project(project_id)
    if _emulated() and not platform_auth.emulator_project_allowed(project_id):
        raise RuntimeError("Emulator mode is only allowed for demo projects.")
    with _LOCK:
        app = _app(project_id)
        db = _database(project_id, database_id)
        client = _AUTH_CLIENTS.get((project_id, tenant_id))
        if client is None:
            client = admin_auth.Client(app, tenant_id=tenant_id)
            _AUTH_CLIENTS[(project_id, tenant_id)] = client
    return CompanyAccess(project_id, database_id, tenant_id, db, client)


def platform_project_auth() -> admin_auth.Client:
    project_id = config.PLATFORM_PROJECT_ID
    if _emulated():
        return _project_auth(project_id)
    with _LOCK:
        client = _PLATFORM_AUTH.get(project_id)
        if client is None:
            name = f"platform:{project_id}"
            try:
                app = firebase_admin.get_app(name)
            except ValueError:
                app = firebase_admin.initialize_app(credentials.ApplicationDefault(), options={"projectId": project_id},
                                                    name=name)
            client = admin_auth.Client(app, tenant_id=None)
            _PLATFORM_AUTH[project_id] = client
    return client


def project_auth(project_id: str) -> admin_auth.Client:
    _refuse_platform_project(project_id)
    return _project_auth(project_id)


def _project_auth(project_id: str) -> admin_auth.Client:
    if _emulated() and not platform_auth.emulator_project_allowed(project_id):
        raise RuntimeError("Emulator mode is only allowed for demo projects.")
    with _LOCK:
        client = _AUTH_CLIENTS.get((project_id, None))
        if client is None:
            client = admin_auth.Client(_app(project_id), tenant_id=None)
            _AUTH_CLIENTS[(project_id, None)] = client
    return client


ADMIN_ROLES = ("admin", "developer")
ADMIN_READ_ONLY_REASONS = frozenset({"lifecycle_readonly"})
GRANTABLE_ROLES = ("branch_manager", "supervisor")


def active_admin_row(data: Mapping[str, Any], uid: str) -> bool:
    reasons = data.get("disabledReasons", [])
    return bool(
        data.get("accessVersion") == 2
        and data.get("uid") == uid
        and data.get("status") == "active"
        and data.get("role") in ADMIN_ROLES
        and isinstance(reasons, list)
        and all(isinstance(reason, str) for reason in reasons)
        and set(reasons) <= ADMIN_READ_ONLY_REASONS
    )


def require_active_admin(access: CompanyAccess, uid: str) -> dict[str, Any]:
    snapshot = access.db.collection("user_access").document(uid).get()
    data = snapshot.to_dict() or {}
    if not (snapshot.exists and active_admin_row(data, uid)):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only an active administrator of this company can do this.",
        )
    return data


def require_module_grant(access: CompanyAccess, uid: str, module: str, action: str) -> dict[str, Any]:
    data = access.db.collection("user_access").document(uid).get().to_dict() or {}
    role = data.get("role")
    if role not in GRANTABLE_ROLES:
        return require_active_admin(access, uid)
    active = (
        data.get("accessVersion") == 2
        and data.get("uid") == uid
        and data.get("status") == "active"
        and data.get("disabledReasons", []) == []
    )
    table = access.db.collection("system_access_config").document("permission_matrix").get().to_dict() or {}
    roles = table.get("roles")
    row = roles.get(role) if isinstance(roles, dict) else None
    if not (active and isinstance(row, list) and f"{module}:view" in row and f"{module}:{action}" in row):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Your role has not been given this permission. Ask an admin.",
        )
    return data

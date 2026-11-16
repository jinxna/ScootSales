from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from firebase_admin import auth as admin_auth
from firebase_admin import exceptions as admin_exceptions
from google.api_core.exceptions import GoogleAPICallError
from google.auth.exceptions import TransportError

from .auth import ClientIdentity, reject_revoked
from .directory import RETAINED_STATES, DirectoryError, DirectoryStore

SERVING_STATES = frozenset({"active", "past_due"})


def lifecycle_projection(db: Any) -> dict[str, Any] | None:
    return db.collection("config").document("lifecycle").get().to_dict()


def retention_open(db: Any, now: datetime | None = None) -> bool:
    projection = lifecycle_projection(db) or {}
    ends = projection.get("retentionEndsAt")
    return (
        projection.get("state") in RETAINED_STATES
        and isinstance(ends, datetime)
        and ends > (now or datetime.now(timezone.utc))
    )


def company_serves(
    store: DirectoryStore,
    record: Mapping[str, Any],
    retained: Callable[[Mapping[str, Any]], bool] | None = None,
) -> bool:
    if record["status"] != "live":
        return False
    state = store.lifecycle_state(record["tenantId"])
    if state in SERVING_STATES:
        return True
    return retained is not None and state in RETAINED_STATES and retained(record)


@dataclass(frozen=True)
class TenantContext:
    tenant_id: str
    workspace: str
    project_id: str
    auth_tenant_id: str | None
    uid: str
    record: Mapping[str, Any]


def _forbidden(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=detail)


def ensure_signed_in(identity: ClientIdentity, access: Any) -> None:
    try:
        user = access.auth.get_user(identity.uid)
    except admin_auth.UserNotFoundError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Sign-in was revoked.",
                            headers={"WWW-Authenticate": "Bearer"}) from None
    except (RuntimeError, GoogleAPICallError, TransportError, admin_exceptions.FirebaseError) as error:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Sign-in could not be checked.") from error
    reject_revoked(identity, user)


def resolve_tenant(
    identity: ClientIdentity,
    store: DirectoryStore,
    *,
    workspace: str | None = None,
    retained: Callable[[Mapping[str, Any]], bool] | None = None,
    any_state: bool = False,
    access_for: Callable[[Mapping[str, Any]], Any] | None,
) -> TenantContext:
    try:
        record = store.find_by_auth(identity.project_id, identity.auth_tenant_id)
    except DirectoryError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The company directory could not be verified.",
        ) from error
    if record is None:
        raise _forbidden("This sign-in does not belong to a known company.")
    location = record["location"]
    if (
        location["projectId"] != identity.project_id
        or location["authTenantId"] != identity.auth_tenant_id
    ):
        raise _forbidden("This sign-in does not belong to a known company.")
    if workspace is not None and record["workspace"] != workspace:
        raise _forbidden("This sign-in belongs to another company.")
    try:
        serves = record["status"] != "deleted" if any_state else company_serves(store, record, retained)
    except DirectoryError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The company directory could not be verified.",
        ) from error
    if not serves:
        raise _forbidden("This company is not active.")
    if access_for is not None:
        try:
            access = access_for(record["location"])
        except (RuntimeError, GoogleAPICallError, TransportError) as error:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Sign-in could not be checked.") from error
        ensure_signed_in(identity, access)
    return TenantContext(
        tenant_id=record["tenantId"],
        workspace=record["workspace"],
        project_id=identity.project_id,
        auth_tenant_id=identity.auth_tenant_id,
        uid=identity.uid,
        record=record,
    )

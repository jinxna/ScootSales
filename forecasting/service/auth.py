from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request as UrlRequest, urlopen

from fastapi import HTTPException, status

from platform_service import auth as platform_auth

from . import config


@dataclass(frozen=True)
class ForecastAdministrator:
    uid: str
    role: str
    token: str = field(default="", repr=False)


def _authentication_error(detail: str = "Administrator authentication required.") -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def _verify_firebase_token(token: str) -> dict[str, Any]:
    identity = platform_auth.verify_client_token(token)
    if identity.project_id != config.FIREBASE_PROJECT_ID:
        raise _authentication_error("Invalid administrator session.")
    return {"uid": identity.uid}


def _firestore_document_url(collection: str, uid: str) -> str:
    emulator = os.environ.get("FIRESTORE_EMULATOR_HOST", "").strip()
    if emulator:
        root = f"http://{emulator}/v1"
    else:
        root = "https://firestore.googleapis.com/v1"
    project = quote(config.FIREBASE_PROJECT_ID, safe="")
    document_uid = quote(uid, safe="")
    return (
        f"{root}/projects/{project}/databases/(default)/documents/"
        f"{collection}/{document_uid}"
    )


def _read_profile_document(
    collection: str,
    uid: str,
    token: str,
) -> dict[str, Any] | None:
    request = UrlRequest(
        _firestore_document_url(collection, uid),
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    try:
        with urlopen(request, timeout=5) as response:  # noqa: S310 - fixed HTTPS host
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        if error.code == 404:
            return None
        raise RuntimeError("Profile authorization lookup was denied.") from error
    except (OSError, URLError, ValueError) as error:
        raise RuntimeError("Profile authorization lookup failed.") from error
    if not isinstance(payload, dict):
        raise RuntimeError("Profile authorization response was invalid.")
    fields = payload.get("fields", {})
    if not isinstance(fields, dict):
        raise RuntimeError("Profile authorization response was invalid.")
    return fields


def _field_text(fields: dict[str, Any], *keys: str) -> str:
    for key in keys:
        if key not in fields:
            continue
        value = fields.get(key)
        if isinstance(value, dict) and isinstance(value.get("stringValue"), str):
            return value["stringValue"]
    return ""


def _strict_field_text(fields: dict[str, Any], key: str) -> str | None:
    value = fields.get(key)
    if not isinstance(value, dict):
        return None
    text = value.get("stringValue")
    return text if isinstance(text, str) else None


def _strict_field_integer(fields: dict[str, Any], key: str) -> int | None:
    value = fields.get(key)
    if not isinstance(value, dict):
        return None
    integer = value.get("integerValue")
    if not isinstance(integer, str) or not integer.isdecimal():
        return None
    return int(integer)


def _is_valid_v2_identity(uid: str, access: dict[str, Any]) -> bool:
    role = _strict_field_text(access, "role")
    return (
        _strict_field_integer(access, "accessVersion") == 2
        and _strict_field_text(access, "uid") == uid
        and role in {"admin", "developer", "branch_manager", "supervisor", "salesman"}
        and _strict_field_text(access, "status") == "active"
        and _strict_field_text(access, "branchId") is not None
        and _strict_field_text(access, "employeeCode") is not None
    )


def _load_authoritative_profile(uid: str, token: str) -> dict[str, Any] | None:
    access = _read_profile_document("user_access", uid, token)
    version_field = access.get("accessVersion") if access is not None else None
    has_version = "accessVersion" in access if access is not None else False
    explicit_null_version = (
        isinstance(version_field, dict) and "nullValue" in version_field
    )
    if access is not None and has_version and not explicit_null_version:
        return access if _is_valid_v2_identity(uid, access) else None

    canonical = _read_profile_document("users", uid, token)
    if canonical is not None and not _is_active_profile(canonical):
        return None
    if access is None:
        return canonical
    if not _is_active_profile(access):
        return None
    if "userDocId" in access or "user_doc_id" in access:
        document_id = _field_text(access, "userDocId", "user_doc_id")
        if not document_id:
            return None
        indexed = canonical if document_id == uid else _read_profile_document(
            "users", document_id, token
        )
        if indexed is None or not _is_active_profile(indexed):
            return None
        if _field_text(indexed, "role", "user_group") != _field_text(
            access, "role", "user_group"
        ):
            return None
        if ("uid" in indexed or "userUid" in indexed) and _field_text(
            indexed, "uid", "userUid"
        ) != uid:
            return None
    return access


_MISSING = object()


def _rest_value(field: Any) -> Any:
    if not isinstance(field, dict):
        return _MISSING
    if "nullValue" in field:
        return None
    if "booleanValue" in field:
        return field["booleanValue"]
    if "stringValue" in field:
        return field["stringValue"]
    if "integerValue" in field:
        try:
            return int(field["integerValue"])
        except (TypeError, ValueError):
            return _MISSING
    if "doubleValue" in field:
        return field["doubleValue"]
    return _MISSING


def _first_present(fields: dict[str, Any], keys: tuple[str, ...], default: Any) -> Any:
    for key in keys:
        if key in fields:
            return _rest_value(fields[key])
    return default


def _is_active_profile(fields: dict[str, Any]) -> bool:
    flag = _first_present(fields, ("isActive", "is_active", "active", "enabled"), True)
    flag_active = (
        (flag is True)
        or (not isinstance(flag, bool) and isinstance(flag, (int, float)) and flag == 1)
        or (isinstance(flag, str) and flag.lower() in {"true", "1", "yes"})
        or (flag is None and _rest_value(fields.get("active")) is True)
    )
    status_value = _first_present(
        fields, ("status", "accountStatus", "account_status"), "active"
    )
    return flag_active and status_value in {"active", "Active"}


def _disabled_reasons(fields: dict[str, Any]) -> list[str] | None:
    value = fields.get("disabledReasons")
    if value is None:
        return []
    array = value.get("arrayValue") if isinstance(value, dict) else None
    if not isinstance(array, dict):
        return None
    reasons: list[str] = []
    for item in array.get("values", []):
        text = item.get("stringValue") if isinstance(item, dict) else None
        if not isinstance(text, str):
            return None
        reasons.append(text)
    return reasons


def _company_paused(fields: dict[str, Any], method: str) -> bool:
    reasons = _disabled_reasons(fields)
    if reasons is None:
        return True
    if not reasons:
        return False
    return not (method in {"GET", "HEAD"} and set(reasons) <= {"lifecycle_readonly"})


def authorize_request_headers(
    *,
    origin: str,
    authorization: str | None,
    method: str = "POST",
) -> ForecastAdministrator:
    origin = origin.strip()
    if origin and origin not in config.CORS_ALLOWED_ORIGINS:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Request origin is not allowed.",
        )

    scheme, separator, token = (authorization or "").partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not token.strip():
        raise _authentication_error()
    token = token.strip()

    claims = _verify_firebase_token(token)
    uid = claims.get("uid")
    if not isinstance(uid, str) or not uid or uid != uid.strip():
        raise _authentication_error("Invalid administrator session.")

    try:
        fields = _load_authoritative_profile(uid, token)
    except RuntimeError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Administrator authorization could not be checked.",
        ) from error
    if fields is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="An active administrator profile is required.",
        )

    role = _field_text(fields, "role", "user_group")
    if role not in {"admin", "developer"} or not _is_active_profile(fields):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="An active administrator profile is required.",
        )
    if _company_paused(fields, method.upper()):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "This company account is paused, so forecasts cannot be run or "
                "changed. Ask the Scoot Sales team to reactivate it."
            ),
        )
    return ForecastAdministrator(uid=uid, role=role, token=token)

from __future__ import annotations

import base64
import json
import os
import re
import threading
import time
from dataclasses import dataclass
from typing import Any

import requests
from fastapi import HTTPException, status
from google.auth import exceptions as google_auth_exceptions
from google.auth import jwt as google_jwt
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import id_token as google_id_token

from . import config

STAFF_SIGN_IN_PROVIDERS = frozenset({"password", "google.com"})
_CLOCK_SKEW_SECONDS = 60
_CERTIFICATE_TIMEOUT_SECONDS = 4
_CERTIFICATE_DEFAULT_TTL_SECONDS = 300
_CERTIFICATE_MAX_TTL_SECONDS = 3600
_MAX_AGE = re.compile(r"max-age=(\d+)")


class _CertificateCache:
    def __init__(self, transport: Any) -> None:
        self._transport = transport
        self._lock = threading.Lock()
        self._cached: tuple[Any, float] | None = None

    def __call__(self, url: str, method: str = "GET", body: Any = None, headers: Any = None,
                 timeout: Any = None, **kwargs: Any) -> Any:
        cached = self._cached
        if cached is not None and cached[1] > time.monotonic():
            return cached[0]
        with self._lock:
            cached = self._cached
            if cached is not None and cached[1] > time.monotonic():
                return cached[0]
            response = self._transport(url, method=method, body=body, headers=headers,
                                       timeout=_CERTIFICATE_TIMEOUT_SECONDS, **kwargs)
            if response.status == 200:
                header = (getattr(response, "headers", None) or {}).get("cache-control", "")
                match = _MAX_AGE.search(header)
                ttl = min(int(match.group(1)), _CERTIFICATE_MAX_TTL_SECONDS) if match                     else _CERTIFICATE_DEFAULT_TTL_SECONDS
                self._cached = (response, time.monotonic() + ttl)
            return response


_REQUEST = _CertificateCache(GoogleAuthRequest(session=requests.Session()))


@dataclass(frozen=True)
class ClientIdentity:
    uid: str
    project_id: str
    auth_tenant_id: str | None
    auth_time: float = 0.0
    issued_at: float = 0.0


@dataclass(frozen=True)
class StaffIdentity:
    email: str
    subject: str
    role: str = ""
    name: str = ""
    session_id: str | None = None


@dataclass(frozen=True)
class StaffToken:
    uid: str
    email: str
    auth_time: float
    provider: str


def person_of(identity: StaffIdentity) -> str:
    return identity.subject


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def emulator_mode() -> bool:
    return bool(os.environ.get("FIREBASE_AUTH_EMULATOR_HOST", "").strip())


_LOOPBACK = {"127.0.0.1", "localhost", "[::1]", "::1"}


def emulator_project_allowed(project_id: str) -> bool:
    if project_id.startswith("demo-"):
        return True
    if project_id not in config.EMULATOR_EXTRA_PROJECTS:
        return False
    for name in ("FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST"):
        host = os.environ.get(name, "").strip().rsplit(":", 1)[0]
        if host not in _LOOPBACK:
            return False
    return True


def bearer_token(authorization: str | None) -> str:
    scheme, separator, token = (authorization or "").partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not token.strip():
        raise _unauthorized("Sign-in required.")
    return token.strip()


def _decode_segment(segment: str) -> dict[str, Any]:
    value = json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))
    if not isinstance(value, dict):
        raise ValueError("Token segment is not an object.")
    return value


def _emulator_claims(token: str) -> dict[str, Any]:
    parts = token.split(".")
    if len(parts) != 3 or parts[2]:
        raise ValueError("Not an emulator token.")
    if _decode_segment(parts[0]).get("alg") != "none":
        raise ValueError("Not an emulator token.")
    claims = _decode_segment(parts[1])
    audience = claims.get("aud")
    if not isinstance(audience, str) or not emulator_project_allowed(audience):
        raise ValueError("Emulator tokens are accepted only for demo projects.")
    now = time.time()
    expires, issued = claims.get("exp"), claims.get("iat")
    if not isinstance(expires, (int, float)) or isinstance(expires, bool) or expires <= now:
        raise ValueError("Token has expired.")
    if not isinstance(issued, (int, float)) or isinstance(issued, bool) or issued > now + _CLOCK_SKEW_SECONDS:
        raise ValueError("Token was issued in the future.")
    return claims


def _signed_claims(token: str, request: Any = _REQUEST) -> dict[str, Any]:
    header = google_jwt.decode_header(token)
    if header.get("alg") != "RS256" or not header.get("kid"):
        raise ValueError("Not a Firebase ID token.")
    return dict(google_id_token.verify_firebase_token(token, request, audience=None))


def _token_claims(token: str, certificate_request: Any) -> dict[str, Any]:
    try:
        claims = _emulator_claims(token) if emulator_mode() else _signed_claims(token, certificate_request)
    except google_auth_exceptions.TransportError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Sign-in could not be checked.",
        ) from error
    except (TypeError, ValueError) as error:
        raise _unauthorized("Invalid or expired sign-in.") from error
    return claims


def _checked_claims(claims: dict[str, Any]) -> tuple[str, str, float, str | None]:
    audience = claims.get("aud")
    subject = claims.get("sub")
    auth_time = claims.get("auth_time")
    firebase = claims.get("firebase")
    tenant = firebase.get("tenant") if isinstance(firebase, dict) else None
    if (
        not isinstance(audience, str)
        or not audience
        or claims.get("iss") != f"https://securetoken.google.com/{audience}"
        or not isinstance(subject, str)
        or not subject
        or len(subject) > 128
        or isinstance(auth_time, bool)
        or not isinstance(auth_time, (int, float))
        or auth_time > time.time() + _CLOCK_SKEW_SECONDS
        or (tenant is not None and (not isinstance(tenant, str) or not tenant))
    ):
        raise _unauthorized("Invalid sign-in.")
    return audience, subject, float(auth_time), tenant


def verify_client_token(token: str, *, certificate_request: Any = _REQUEST) -> ClientIdentity:
    claims = _token_claims(token, certificate_request)
    audience, subject, auth_time, tenant = _checked_claims(claims)
    issued = claims.get("iat")
    issued_at = float(issued) if isinstance(issued, (int, float)) and not isinstance(issued, bool) else 0.0
    return ClientIdentity(uid=subject, project_id=audience, auth_tenant_id=tenant, auth_time=auth_time,
                          issued_at=issued_at)


def reject_revoked(identity: ClientIdentity, user: Any) -> None:
    if user.disabled or identity.issued_at * 1000 < user.tokens_valid_after_timestamp:
        raise _unauthorized("Sign-in was revoked.")


def verify_staff_token(token: str, *, certificate_request: Any = _REQUEST) -> StaffToken:
    claims = _token_claims(token, certificate_request)
    audience, subject, auth_time, tenant = _checked_claims(claims)
    email = claims.get("email")
    firebase = claims.get("firebase")
    provider = firebase.get("sign_in_provider") if isinstance(firebase, dict) else None
    if (
        provider not in STAFF_SIGN_IN_PROVIDERS
        or audience != config.PLATFORM_PROJECT_ID
        or tenant is not None
        or claims.get("email_verified") is not True
        or not isinstance(email, str)
        or "@" not in email
    ):
        raise _unauthorized("Invalid staff sign-in.")
    return StaffToken(uid=subject, email=email.strip().lower(), auth_time=auth_time, provider=provider)

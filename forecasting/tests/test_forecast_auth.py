from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

import pytest
from fastapi import HTTPException
from google.auth import exceptions as google_auth_exceptions

from forecasting.service import auth, config
from platform_service import auth as platform_auth


def _verified_claims(**overrides: Any) -> dict[str, Any]:
    claims: dict[str, Any] = {
        "aud": config.FIREBASE_PROJECT_ID,
        "iss": f"https://securetoken.google.com/{config.FIREBASE_PROJECT_ID}",
        "sub": "admin-uid",
        "auth_time": int(time.time()) - 30,
    }
    claims.update(overrides)
    return claims


def _fields(role: Any = "admin", status: Any = "active") -> dict[str, Any]:
    result: dict[str, Any] = {"role": {"stringValue": role}}
    if status is not None:
        result["status"] = {"stringValue": status}
    return result


@pytest.mark.parametrize(
    "header,make_claims",
    [
        ({"alg": "HS256", "kid": "kid"}, lambda: _verified_claims()),
        ({"alg": "RS256"}, lambda: _verified_claims()),
        (
            {"alg": "RS256", "kid": "kid"},
            lambda: _verified_claims(aud="wrong-project"),
        ),
        (
            {"alg": "RS256", "kid": "kid"},
            lambda: _verified_claims(iss="https://securetoken.google.com/wrong-project"),
        ),
        ({"alg": "RS256", "kid": "kid"}, lambda: _verified_claims(sub="")),
        ({"alg": "RS256", "kid": "kid"}, lambda: _verified_claims(auth_time=None)),
        (
            {"alg": "RS256", "kid": "kid"},
            lambda: _verified_claims(auth_time=time.time() + 120),
        ),
    ],
)
def test_invalid_firebase_token_shape_is_denied(
    monkeypatch: pytest.MonkeyPatch,
    header: dict[str, str],
    make_claims: Callable[[], dict[str, Any]],
) -> None:
    claims = make_claims()
    monkeypatch.setattr(platform_auth.google_jwt, "decode_header", lambda _: header)
    monkeypatch.setattr(
        platform_auth.google_id_token,
        "verify_firebase_token",
        lambda *_args, **_kwargs: claims,
    )

    with pytest.raises(HTTPException) as raised:
        auth._verify_firebase_token("bad-token")

    assert raised.value.status_code == 401


def test_certificate_transport_failure_is_service_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("FIREBASE_AUTH_EMULATOR_HOST", raising=False)
    monkeypatch.setattr(
        platform_auth.google_jwt,
        "decode_header",
        lambda _: {"alg": "RS256", "kid": "kid"},
    )
    monkeypatch.setattr(
        platform_auth.google_id_token,
        "verify_firebase_token",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            google_auth_exceptions.TransportError("offline")
        ),
    )

    with pytest.raises(HTTPException) as raised:
        auth._verify_firebase_token("signed-token")

    assert raised.value.status_code == 503


def test_user_access_presence_shadows_legacy_user_profile(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []

    def fake_read(collection: str, _uid: str, _token: str) -> dict[str, Any] | None:
        calls.append(collection)
        return {} if collection == "user_access" else _fields()

    monkeypatch.setattr(auth, "_read_profile_document", fake_read)

    assert auth._load_authoritative_profile("uid", "token") == {}
    assert calls == ["user_access", "users"]


def test_v2_access_is_the_only_authority_and_needs_one_read(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []
    access = {
        "accessVersion": {"integerValue": "2"},
        "uid": {"stringValue": "uid"},
        "role": {"stringValue": "admin"},
        "status": {"stringValue": "active"},
        "branchId": {"stringValue": ""},
        "employeeCode": {"stringValue": "A001"},
    }

    def fake_read(collection: str, _uid: str, _token: str) -> dict[str, Any] | None:
        calls.append(collection)
        return access if collection == "user_access" else None

    monkeypatch.setattr(auth, "_read_profile_document", fake_read)

    assert auth._load_authoritative_profile("uid", "token") == access
    assert calls == ["user_access"]


@pytest.mark.parametrize(
    "overrides",
    [
        {"accessVersion": {"integerValue": "3"}},
        {"uid": {"stringValue": "different"}},
        {"role": {"stringValue": "Administrator"}},
        {"status": {"stringValue": "suspended"}},
        {"status": None},
        {"branchId": {"integerValue": "7"}},
        {"employeeCode": {"integerValue": "7"}},
    ],
)
def test_malformed_v2_access_fails_closed_without_profile_fallback(
    monkeypatch: pytest.MonkeyPatch,
    overrides: dict[str, Any],
) -> None:
    access: dict[str, Any] = {
        "accessVersion": {"integerValue": "2"},
        "uid": {"stringValue": "uid"},
        "role": {"stringValue": "admin"},
        "status": {"stringValue": "active"},
        "branchId": {"stringValue": ""},
        "employeeCode": {"stringValue": "A001"},
    }
    access.update(overrides)
    calls: list[str] = []

    def fake_read(collection: str, _uid: str, _token: str) -> dict[str, Any] | None:
        calls.append(collection)
        return access if collection == "user_access" else _fields()

    monkeypatch.setattr(auth, "_read_profile_document", fake_read)

    assert auth._load_authoritative_profile("uid", "token") is None
    assert calls == ["user_access"]


def test_missing_user_access_falls_back_to_uid_user_document(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        auth,
        "_read_profile_document",
        lambda collection, _uid, _token: None
        if collection == "user_access"
        else _fields(),
    )

    assert auth._load_authoritative_profile("uid", "token") == _fields()


@pytest.mark.parametrize("document_id,status", [
    ("uid", "suspended"), ("staff-1", "suspended"), ("staff-1", "missing"),
    ("", "active"),
])
def test_active_index_cannot_bypass_canonical_suspension_or_missing_link(
    monkeypatch: pytest.MonkeyPatch, document_id: str, status: str,
) -> None:
    access = {**_fields(), "userDocId": {"stringValue": document_id}}
    def read(collection: str, doc_id: str, _token: str) -> dict[str, Any] | None:
        if collection == "user_access":
            return access
        if doc_id == document_id:
            return None if status == "missing" else _fields(status=status)
        return None
    monkeypatch.setattr(auth, "_read_profile_document", read)
    assert auth._load_authoritative_profile("uid", "token") is None


def test_active_linked_canonical_profile_preserves_access_role(monkeypatch: pytest.MonkeyPatch) -> None:
    access = {**_fields(), "userDocId": {"stringValue": "staff-1"}}
    monkeypatch.setattr(auth, "_read_profile_document", lambda collection, doc_id, token:
        access if collection == "user_access" else _fields() if doc_id == "staff-1" else None)
    assert auth._load_authoritative_profile("uid", "token") == access


def test_linked_canonical_role_demotion_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    access = {**_fields(), "userDocId": {"stringValue": "staff-1"}}
    monkeypatch.setattr(
        auth,
        "_read_profile_document",
        lambda collection, doc_id, token: access
        if collection == "user_access"
        else _fields("supervisor")
        if doc_id == "staff-1"
        else None,
    )

    assert auth._load_authoritative_profile("uid", "token") is None


def test_linked_canonical_wrong_uid_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    access = {**_fields(), "userDocId": {"stringValue": "staff-1"}}
    canonical = {**_fields(), "uid": {"stringValue": "different-uid"}}
    monkeypatch.setattr(
        auth,
        "_read_profile_document",
        lambda collection, doc_id, token: access
        if collection == "user_access"
        else canonical
        if doc_id == "staff-1"
        else None,
    )

    assert auth._load_authoritative_profile("uid", "token") is None


@pytest.mark.parametrize(
    "profile,expected_status",
    [
        (_fields("admin", "active"), 200),
        (_fields("developer", "Active"), 200),
        (_fields("admin", None), 200),
        (_fields("supervisor", "active"), 403),
        (_fields(" admin ", "active"), 403),
        (_fields("admin", "ACTIVE"), 403),
        ({"role": {"stringValue": ""}, "user_group": {"stringValue": "admin"}}, 403),
    ],
)
def test_authorization_matches_firestore_role_and_status_semantics(
    monkeypatch: pytest.MonkeyPatch,
    profile: dict[str, Any],
    expected_status: int,
) -> None:
    monkeypatch.setattr(auth, "_verify_firebase_token", lambda _: {"uid": "admin-uid"})
    monkeypatch.setattr(
        auth,
        "_load_authoritative_profile",
        lambda _uid, _token: profile,
    )

    if expected_status == 200:
        administrator = auth.authorize_request_headers(
            origin="http://localhost:5000",
            authorization="Bearer signed-token",
        )
        assert administrator.uid == "admin-uid"
    else:
        with pytest.raises(HTTPException) as raised:
            auth.authorize_request_headers(
                origin="http://localhost:5000",
                authorization="Bearer signed-token",
            )
        assert raised.value.status_code == expected_status


@pytest.mark.parametrize(
    "extra,active",
    [
        ({"isActive": {"booleanValue": False}}, False),
        ({"is_active": {"booleanValue": False}}, False),
        ({"active": {"booleanValue": False}}, False),
        ({"enabled": {"booleanValue": False}}, False),
        ({"accountStatus": {"stringValue": "suspended"}}, False),
        ({"account_status": {"stringValue": "suspended"}}, False),
        ({"isActive": {"stringValue": "no"}}, False),
        ({"isActive": {"booleanValue": True}}, True),
        ({"isActive": {"integerValue": "1"}}, True),
        ({"isActive": {"stringValue": "Yes"}}, True),
        ({}, True),
    ],
)
def test_legacy_suspension_aliases_match_firestore_rules(
    extra: dict[str, Any], active: bool,
) -> None:
    assert auth._is_active_profile({**_fields(status=None), **extra}) is active


@pytest.mark.parametrize("authorization", [None, "", "Basic value", "Bearer "])
def test_missing_or_malformed_authorization_is_denied(
    authorization: str | None,
) -> None:
    with pytest.raises(HTTPException) as raised:
        auth.authorize_request_headers(origin="", authorization=authorization)
    assert raised.value.status_code == 401
    assert raised.value.headers == {"WWW-Authenticate": "Bearer"}


def _paused_fields(*reasons: str) -> dict[str, Any]:
    return {
        **_fields(),
        "disabledReasons": {
            "arrayValue": {"values": [{"stringValue": reason} for reason in reasons]}
        },
    }


@pytest.mark.parametrize(
    "profile,method,expected_status",
    [
        (_paused_fields("billing_lapse"), "POST", 403),
        (_paused_fields("billing_lapse"), "GET", 403),
        (_paused_fields("lifecycle_readonly"), "POST", 403),
        (_paused_fields("lifecycle_readonly"), "GET", 200),
        (_paused_fields(), "POST", 200),
        (_fields(), "POST", 200),
    ],
)
def test_fix_189_paused_company_cannot_run_forecasts(
    monkeypatch: pytest.MonkeyPatch,
    profile: dict[str, Any],
    method: str,
    expected_status: int,
) -> None:
    monkeypatch.setattr(auth, "_verify_firebase_token", lambda _: {"uid": "admin-uid"})
    monkeypatch.setattr(auth, "_load_authoritative_profile", lambda _uid, _token: profile)
    call = dict(origin="http://localhost:5000", authorization="Bearer t", method=method)
    if expected_status == 200:
        assert auth.authorize_request_headers(**call).uid == "admin-uid"
    else:
        with pytest.raises(HTTPException) as raised:
            auth.authorize_request_headers(**call)
        assert raised.value.status_code == expected_status

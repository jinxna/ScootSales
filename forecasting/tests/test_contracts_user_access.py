from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from fastapi import HTTPException

from forecasting.service import auth

FIXTURE_DIR = Path(__file__).resolve().parents[2] / "contracts" / "user_access"
FIXTURES = sorted(FIXTURE_DIR.glob("*.json"))
CONSUMER_FIXTURES = [
    path
    for path in FIXTURES
    if "pythonIdentity" in json.loads(path.read_text(encoding="utf-8"))["expect"]
]


def _is_sentinel(value: Any, kind: str) -> bool:
    return isinstance(value, dict) and value.get("$sentinel") == kind


def _resulting_access(fixture: dict[str, Any]) -> dict[str, Any]:
    result = dict(fixture.get("existingAccess") or {})
    for key, value in fixture["access"].items():
        if _is_sentinel(value, "delete"):
            result.pop(key, None)
        elif _is_sentinel(value, "serverTimestamp"):
            result[key] = {"$timestamp": "2026-10-05T00:00:00Z"}
        else:
            result[key] = value
    return result


def _to_rest(value: Any) -> dict[str, Any]:
    if isinstance(value, dict) and "$timestamp" in value:
        return {"timestampValue": value["$timestamp"]}
    if value is None:
        return {"nullValue": None}
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        return {"integerValue": str(value)}
    if isinstance(value, float):
        return {"doubleValue": value}
    if isinstance(value, str):
        return {"stringValue": value}
    if isinstance(value, list):
        return {"arrayValue": {"values": [_to_rest(item) for item in value]}}
    if isinstance(value, dict):
        return {"mapValue": {"fields": _to_fields(value)}}
    raise TypeError(f"unsupported fixture value: {value!r}")


def _to_fields(document: dict[str, Any]) -> dict[str, Any]:
    return {key: _to_rest(value) for key, value in document.items()}


def _serve(monkeypatch: pytest.MonkeyPatch, fixture: dict[str, Any]) -> dict[str, Any]:
    access = _resulting_access(fixture)
    documents = {
        ("user_access", fixture["uid"]): _to_fields(access),
    }
    profile_id = access.get("userDocId") or access.get("user_doc_id")
    if isinstance(profile_id, str) and profile_id:
        documents[("users", profile_id)] = _to_fields(fixture["userDoc"])

    def fake_read(collection: str, uid: str, token: str) -> dict[str, Any] | None:
        return documents.get((collection, uid))

    monkeypatch.setattr(auth, "_read_profile_document", fake_read)
    return access


def test_contract_fixtures_are_present() -> None:
    assert CONSUMER_FIXTURES


@pytest.mark.parametrize("path", CONSUMER_FIXTURES, ids=lambda p: p.name)
def test_resolver_matches_contract_identity(
    path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = json.loads(path.read_text(encoding="utf-8"))
    expected = fixture["expect"]["pythonIdentity"]
    _serve(monkeypatch, fixture)

    resolved = auth._load_authoritative_profile(fixture["uid"], "token")

    if expected == "active":
        assert resolved is not None, fixture["description"]
    elif expected == "rejected":
        assert resolved is None, fixture["description"]
    else:  # pragma: no cover - guards the fixture vocabulary
        pytest.fail(f"unknown pythonIdentity {expected!r}")


@pytest.mark.parametrize("path", CONSUMER_FIXTURES, ids=lambda p: p.name)
def test_admin_gate_matches_contract(
    path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = json.loads(path.read_text(encoding="utf-8"))
    expected = fixture["expect"].get("pythonAdminAccess")
    if expected is None:
        pytest.skip("fixture does not pin the admin gate")
    _serve(monkeypatch, fixture)
    monkeypatch.setattr(
        auth, "_verify_firebase_token", lambda token: {"uid": fixture["uid"]}
    )

    def authorize() -> auth.ForecastAdministrator:
        return auth.authorize_request_headers(
            origin="", authorization="Bearer signed-token"
        )

    if expected == "allow":
        assert authorize().uid == fixture["uid"]
    else:
        with pytest.raises(HTTPException) as denied:
            authorize()
        assert denied.value.status_code == 403

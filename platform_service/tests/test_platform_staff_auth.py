from __future__ import annotations

import json
import socket

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from platform_service import company_access, config
from platform_service.staff import StaffBook

PLATFORM = "demo-control-keycheck"
ROBOT = f"platform@{PLATFORM}.iam.gserviceaccount.com"


def offline(*args, **kwargs):
    raise AssertionError("This check must not use the network.")


def test_staff_sign_in_accounts_use_the_control_centre_credential_and_never_a_company_key(tmp_path, monkeypatch):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    central = tmp_path / "central-key.json"
    central.write_text(json.dumps({"type": "service_account", "project_id": PLATFORM, "private_key_id": "local",
                                   "private_key": pem, "client_email": ROBOT, "client_id": "1",
                                   "token_uri": "https://oauth2.googleapis.com/token"}), encoding="utf-8")
    company_keys = tmp_path / "company-keys"
    company_keys.mkdir()
    for name in ("FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("GOOGLE_APPLICATION_CREDENTIALS", str(central))
    monkeypatch.setattr(config, "PLATFORM_PROJECT_ID", PLATFORM)
    monkeypatch.setattr(config, "COMPANY_CREDENTIALS_DIR", str(company_keys))
    monkeypatch.setattr(socket.socket, "connect", offline)
    monkeypatch.setattr(socket, "create_connection", offline)
    monkeypatch.setattr(socket, "getaddrinfo", offline)

    client = StaffBook(None, None, None).auth_client()

    claims = jwt.decode(client.create_custom_token("staff-1"), key.public_key(), algorithms=["RS256"],
                        options={"verify_aud": False})
    assert claims["iss"] == ROBOT and claims["uid"] == "staff-1"
    assert company_access.platform_project_auth() is client
    with pytest.raises(company_access.CompanyUnreachable):
        company_access.project_auth(PLATFORM)

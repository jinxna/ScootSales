from __future__ import annotations

import base64
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

from . import config

ALGORITHM = "Ed25519"
RECORD_KIND = "scoot.directory.record.v1"
MAX_PAYLOAD_BYTES = 256 * 1024
CLOCK_SKEW = timedelta(minutes=5)

_KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_B64URL = re.compile(r"^[A-Za-z0-9_-]*$")
_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
_ENVELOPE_KEYS = frozenset({"alg", "keyId", "payload", "signature"})


class SignatureError(ValueError):
    pass


class ExpiredSignature(SignatureError):
    def __init__(self, expires_at: datetime) -> None:
        super().__init__(f"Signed payload expired on {format_timestamp(expires_at)}.")
        self.expires_at = expires_at


def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text: str) -> bytes:
    if not isinstance(text, str) or not _B64URL.fullmatch(text) or len(text) % 4 == 1:
        raise SignatureError("Invalid base64url text.")
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def format_timestamp(moment: datetime) -> str:
    if moment.tzinfo is None:
        raise ValueError("Timestamps must be timezone-aware.")
    return moment.astimezone(timezone.utc).replace(microsecond=0).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def parse_timestamp(text: Any) -> datetime:
    if not isinstance(text, str) or not _TIMESTAMP.fullmatch(text):
        raise SignatureError("Invalid timestamp.")
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def _reject_constant(value: str) -> Any:
    raise SignatureError(f"Non-finite number {value} is not allowed.")


def encode_payload(payload: Mapping[str, Any]) -> str:
    return json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )


@dataclass(frozen=True)
class Signer:
    key_id: str
    private_key: Ed25519PrivateKey

    def __post_init__(self) -> None:
        if not _KEY_ID.fullmatch(self.key_id):
            raise ValueError("Invalid signing key ID.")

    def __repr__(self) -> str:
        return f"Signer(key_id={self.key_id!r})"

    @classmethod
    def generate(cls, key_id: str) -> "Signer":
        return cls(key_id, Ed25519PrivateKey.generate())

    @classmethod
    def from_seed(cls, key_id: str, seed: str) -> "Signer":
        raw = b64url_decode(seed.strip())
        if len(raw) != 32:
            raise ValueError("An Ed25519 seed is 32 bytes.")
        return cls(key_id, Ed25519PrivateKey.from_private_bytes(raw))

    @classmethod
    def from_environment(cls) -> "Signer":
        seed = os.environ.get(config.SIGNING_KEY_ENV, "")
        if not config.SIGNING_KEY_ID or not seed.strip():
            raise RuntimeError(
                "Signing needs PLATFORM_SIGNING_KEY_ID and PLATFORM_SIGNING_KEY."
            )
        return cls.from_seed(config.SIGNING_KEY_ID, seed)

    def seed(self) -> str:
        return b64url_encode(
            self.private_key.private_bytes(
                serialization.Encoding.Raw,
                serialization.PrivateFormat.Raw,
                serialization.NoEncryption(),
            )
        )

    def public_key(self) -> str:
        return b64url_encode(
            self.private_key.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw
            )
        )

    def sign(self, payload: Mapping[str, Any]) -> dict[str, str]:
        for field in ("kind", "version", "issuedAt", "expiresAt"):
            if field not in payload:
                raise ValueError(f"A signed payload needs {field}.")
        text = encode_payload(payload)
        if len(text.encode("utf-8")) > MAX_PAYLOAD_BYTES:
            raise ValueError("Signed payload is too large.")
        signature = self.private_key.sign(text.encode("utf-8"))
        return {
            "alg": ALGORITHM,
            "keyId": self.key_id,
            "payload": text,
            "signature": b64url_encode(signature),
        }


class Keyring:
    def __init__(self, public_keys: Mapping[str, str]) -> None:
        if not public_keys:
            raise ValueError("A keyring needs at least one public key.")
        self._keys: dict[str, Ed25519PublicKey] = {}
        for key_id, encoded in public_keys.items():
            if not _KEY_ID.fullmatch(key_id):
                raise ValueError("Invalid public key ID.")
            raw = b64url_decode(encoded)
            if len(raw) != 32:
                raise ValueError("An Ed25519 public key is 32 bytes.")
            self._keys[key_id] = Ed25519PublicKey.from_public_bytes(raw)

    @classmethod
    def parse(cls, text: str) -> "Keyring":
        keys: dict[str, str] = {}
        for part in text.split(","):
            key_id, separator, encoded = part.strip().partition("=")
            if not separator or key_id in keys:
                raise ValueError("Invalid or repeated public key entry.")
            keys[key_id] = encoded
        return cls(keys)

    @classmethod
    def from_environment(cls) -> "Keyring":
        if not config.PUBLIC_KEYS_TEXT:
            raise RuntimeError("Verification needs PLATFORM_PUBLIC_KEYS.")
        return cls.parse(config.PUBLIC_KEYS_TEXT)

    def verify(
        self,
        envelope: Any,
        *,
        kind: str,
        min_version: int = 0,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        if not isinstance(envelope, Mapping) or set(envelope) != _ENVELOPE_KEYS:
            raise SignatureError("Not a signed envelope.")
        if not all(isinstance(envelope[key], str) for key in _ENVELOPE_KEYS):
            raise SignatureError("Not a signed envelope.")
        if envelope["alg"] != ALGORITHM:
            raise SignatureError("Unsupported signature algorithm.")
        public_key = self._keys.get(envelope["keyId"])
        if public_key is None:
            raise SignatureError("Unknown signing key.")
        payload_bytes = envelope["payload"].encode("utf-8")
        if len(payload_bytes) > MAX_PAYLOAD_BYTES:
            raise SignatureError("Signed payload is too large.")
        signature = b64url_decode(envelope["signature"])
        if len(signature) != 64:
            raise SignatureError("Invalid signature length.")
        try:
            public_key.verify(signature, payload_bytes)
        except InvalidSignature as error:
            raise SignatureError("Signature does not match.") from error

        try:
            payload = json.loads(envelope["payload"], parse_constant=_reject_constant)
        except ValueError as error:
            raise SignatureError("Signed payload is not JSON.") from error
        if not isinstance(payload, dict) or payload.get("kind") != kind:
            raise SignatureError("Signed payload has the wrong kind.")
        version = payload.get("version")
        if isinstance(version, bool) or not isinstance(version, int) or version < 1:
            raise SignatureError("Signed payload has an invalid version.")
        if version < min_version:
            raise SignatureError("Signed payload is older than the last version seen.")
        moment = now or datetime.now(timezone.utc)
        issued = parse_timestamp(payload.get("issuedAt"))
        expires = parse_timestamp(payload.get("expiresAt"))
        if issued > moment + CLOCK_SKEW or expires <= issued:
            raise SignatureError("Signed payload has invalid times.")
        if moment >= expires:
            raise ExpiredSignature(expires)
        return payload

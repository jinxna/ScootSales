from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from .directory import DirectoryError
from .records import normalized_status, validate_record
from .signing import RECORD_KIND, ExpiredSignature, Keyring, format_timestamp

BINDING_FILE_ENV = "TENANT_BINDING_FILE"
BINDING_FLOOR_ENV = "TENANT_BINDING_MIN_VERSION"
BINDING_META = frozenset({"kind", "version", "issuedAt", "expiresAt"})


def verified_binding(keyring: Keyring, envelope: Any, *, now: datetime | None = None,
                     floor: int = 0) -> dict[str, Any]:
    try:
        payload = keyring.verify(envelope, kind=RECORD_KIND, min_version=floor,
                                 now=now or datetime.now(timezone.utc))
        clean_binding(payload)
        return {**payload, "status": normalized_status(payload.get("status"))}
    except ExpiredSignature as error:
        raise DirectoryError(
            f"The runtime company binding expired on {format_timestamp(error.expires_at)}. "
            f"Ask the platform owner for a newly signed binding file and replace the one named by {BINDING_FILE_ENV}."
        ) from error
    except (ValueError, TypeError, LookupError) as error:
        raise DirectoryError("The runtime company binding could not be verified.") from error


def clean_binding(payload: Mapping[str, Any]) -> dict[str, Any]:
    return validate_record({k: v for k, v in payload.items() if k not in BINDING_META})


def binding_file_path() -> str:
    return os.environ.get(BINDING_FILE_ENV, "").strip()


def binding_floor() -> int:
    value = os.environ.get(BINDING_FLOOR_ENV, "").strip()
    return int(value) if value.isdigit() else 0


def read_binding_file(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def bound_company(path: str | None = None, keyring: Keyring | None = None) -> dict[str, Any]:
    path = path or binding_file_path()
    if not path:
        raise RuntimeError(f"{BINDING_FILE_ENV} must identify the approved signed company binding.")
    keyring = keyring or Keyring.from_environment()
    return clean_binding(verified_binding(keyring, read_binding_file(path), floor=binding_floor()))

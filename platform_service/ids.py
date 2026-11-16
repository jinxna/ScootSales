from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from fastapi import HTTPException, status

from .commands import CommandProblem
from .signing import encode_payload, format_timestamp, parse_timestamp

TENANT = re.compile(r"^t_[a-z0-9]{6,32}$")
KEY = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
NO_KEY = object()
KUALA_LUMPUR = timezone(timedelta(hours=8), "Asia/Kuala_Lumpur")
MAX_AMOUNT_MINOR = 2 ** 53 - 1
DUE_DAYS = 14


_SPREADSHEET_PADDING = "".join(chr(code) for code in range(0x21)) + "\x7f\ufeff"


def safe_cell(value: Any) -> str:
    if not isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return f"'{value}" if value.lstrip(_SPREADSHEET_PADDING)[:1] in ("=", "+", "-", "@") else value


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def bad(message: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=message)


def local_day(moment: datetime):
    return moment.astimezone(KUALA_LUMPUR).date()


def local_date(moment: datetime) -> str:
    return local_day(moment).isoformat()


def last_day(period_end: datetime) -> str:
    return local_date(period_end - timedelta(days=1))


def amount_minor(value: Any, name: str) -> int:
    if type(value) is not int or not 0 < value <= MAX_AMOUNT_MINOR:
        raise bad(f"{name} must be a positive integer in MYR sen within the safe browser range.")
    return value


def text(value: Any, name: str, maximum: int) -> str:
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= maximum:
        raise bad(f"{name} must be nonempty text of at most {maximum} characters.")
    return value.strip()


def check_key(key: Any) -> None:
    if not isinstance(key, str) or not KEY.fullmatch(key):
        raise bad("Idempotency-Key must be 8-128 characters of A-Z, a-z, 0-9, _ or -.")


def identity(tenant_id: str, key: Any = NO_KEY) -> None:
    if not isinstance(tenant_id, str) or not TENANT.fullmatch(tenant_id):
        raise bad("Enter a valid permanent tenant ID.")
    if key is not NO_KEY:
        check_key(key)


def timestamp(value: Any, name: str) -> str:
    try:
        moment = parse_timestamp(value)
        if format_timestamp(moment) != value:
            raise ValueError()
    except (ValueError, TypeError):
        raise bad(f"{name} must be a canonical UTC timestamp like 2026-12-31T00:00:00Z.") from None
    return value


def digest(payload: Mapping[str, Any]) -> str:
    return hashlib.sha256(encode_payload(payload).encode("utf-8")).hexdigest()


def command_id(prefix: str, tenant_id: str, key: str, action: str) -> str:
    return prefix + "_" + digest({"tenantId": tenant_id, "key": key, "action": action})


def retry(data: Mapping[str, Any], payload_hash: str) -> None:
    if data.get("payloadHash") != payload_hash:
        raise CommandProblem("This idempotency key was already used for a different request.")


def safe(data: Mapping[str, Any], keys: frozenset[str]) -> dict[str, Any]:
    return {key: format_timestamp(value) if isinstance(value, datetime) else value
            for key, value in data.items() if key in keys}

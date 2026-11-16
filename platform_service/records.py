from __future__ import annotations

import re
from datetime import datetime, timedelta
from typing import Any, Mapping
from urllib.parse import urlsplit

from . import config
from .signing import RECORD_KIND, format_timestamp

STATUSES = frozenset({"lead", "live", "deleted"})
LEGACY_LIVE_STATUSES = frozenset({"trial", "active", "past_due", "suspended", "expired", "cancelled"})
RELEASE_RINGS = frozenset({"pilot", "general"})
EDITIONS = frozenset({"basic", "advanced"})
LOCATION_KINDS = frozenset({"byo", "managed"})
PLATFORMS = ("android", "ios", "web")

RESERVED_WORKSPACES = frozenset(
    {
        "admin", "api", "app", "apps", "assets", "auth", "billing", "console",
        "help", "login", "platform", "scoot", "scootsales", "signin", "signup",
        "staff", "static", "status", "support", "w", "www",
    }
)

_TENANT_ID = re.compile(r"^t_[a-z0-9]{6,32}$")
_WORKSPACE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$")
_COMPANY_CODE = re.compile(r"^[a-z0-9-]{2,32}$")
_LEGAL_NAME = re.compile(r"^[^\x00-\x1f\x7f]{1,120}$")
PLATFORM_PROJECT_REFUSAL = (
    "This Firebase project belongs to the Control Centre. Choose the company's own Firebase project."
)
_PROJECT_ID = re.compile(r"^[a-z][a-z0-9-]{4,29}$")
_DATABASE_ID = re.compile(r"^\(default\)$")
_AUTH_TENANT_ID = re.compile(r"^[A-Za-z0-9-]{4,63}$")
_SHORT_TEXT = re.compile(r"^[A-Za-z0-9._-]{1,40}$")
_API_KEY = re.compile(r"^AIza[0-9A-Za-z_-]{35}$")
_SENDER_ID = re.compile(r"^\d{6,20}$")
_APP_ID = re.compile(r"^\d+:(\d+):(android|ios|web):[0-9a-f]+$")
_BUCKET = re.compile(r"^[a-z0-9][a-z0-9.-]{2,}$")
_BUNDLE_ID = re.compile(r"^[A-Za-z0-9.-]{3,155}$")
_SITE_KEY = re.compile(r"^[A-Za-z0-9_-]{40}$")
_SERVICE_URL = re.compile(
    r"^(https://[a-z0-9.-]+(:\d{1,5})?|http://(127\.0\.0\.1|localhost)(:\d{1,5})?)(/[A-Za-z0-9._~/-]*)?$"
)
_HOST_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
SERVICES = ("forecastingUrl", "copilotUrl")
SERVICE_HOST_SUFFIX = "scootsales.my"
SERVICE_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost"})
REMOVED_SERVICES = frozenset({"voiceUrl", "otpUrl", "tenantApiUrl"})
REMOVED_FIELDS = frozenset({"apiContractVersion"})
_SKELETON = str.maketrans({"0": "o", "1": "l", "i": "l", "5": "s", "3": "e", "-": None})


class RecordError(ValueError):
    pass


def normalized_status(status: Any) -> Any:
    return "live" if status in LEGACY_LIVE_STATUSES else status


def workspace_skeleton(workspace: str) -> str:
    return workspace.lower().translate(_SKELETON).replace("rn", "m").replace("vv", "w")


def _match(value: Any, pattern: re.Pattern[str], name: str) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise RecordError(f"Invalid {name}.")
    return value


def _per_platform(value: Any, pattern: re.Pattern[str], name: str) -> str | dict[str, str]:
    if isinstance(value, str):
        return _match(value, pattern, name)
    if not isinstance(value, Mapping) or not value or set(value) - set(PLATFORMS):
        raise RecordError(f"Invalid {name}.")
    return {platform: _match(value[platform], pattern, name) for platform in sorted(value)}


def _client_config(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise RecordError("Invalid clientConfig.")
    allowed = {"apiKey", "appId", "messagingSenderId", "storageBucket", "iosBundleId", "appCheckSiteKey"}
    if set(value) - allowed:
        raise RecordError("clientConfig has unknown fields.")
    sender = _match(value.get("messagingSenderId"), _SENDER_ID, "messagingSenderId")
    app_id = _per_platform(value.get("appId"), _APP_ID, "appId")
    app_ids = {"any": app_id} if isinstance(app_id, str) else app_id
    for platform, text in app_ids.items():
        number, kind = _APP_ID.fullmatch(text).groups()  # type: ignore[union-attr]
        if number != sender or (platform != "any" and kind != platform):
            raise RecordError("appId does not match messagingSenderId or platform.")
    config: dict[str, Any] = {
        "apiKey": _per_platform(value.get("apiKey"), _API_KEY, "apiKey"),
        "appId": app_id,
        "messagingSenderId": sender,
    }
    if value.get("storageBucket") is not None:
        config["storageBucket"] = _match(value["storageBucket"], _BUCKET, "storageBucket")
    if value.get("iosBundleId") is not None:
        config["iosBundleId"] = _match(value["iosBundleId"], _BUNDLE_ID, "iosBundleId")
    if value.get("appCheckSiteKey") is not None:
        config["appCheckSiteKey"] = _match(value["appCheckSiteKey"], _SITE_KEY, "appCheckSiteKey")
    return config


def _services(value: Any) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, Mapping) or set(value) - set(SERVICES) - REMOVED_SERVICES:
        raise RecordError("Invalid services.")
    return {
        name: _match(url, _SERVICE_URL, name).rstrip("/")
        for name, url in sorted(value.items())
        if url is not None and name in SERVICES
    }


def check_service_hosts(services: Mapping[str, str], current: Mapping[str, str] | None = None) -> None:
    for name, url in services.items():
        if current is not None and current.get(name) == url:
            continue
        parts = urlsplit(url)
        host = (parts.hostname or "").lower()
        known = host in SERVICE_LOOPBACK_HOSTS or host.endswith("." + SERVICE_HOST_SUFFIX)
        if parts.username is not None or parts.password is not None or not known:
            raise RecordError(
                f"The {name} host {host or url} is not allowed. Use a company address such as name.{SERVICE_HOST_SUFFIX}.")
        try:
            port = parts.port
        except ValueError:
            port = -1
        shaped = all(_HOST_LABEL.fullmatch(label) for label in host.split("."))
        if not shaped or port == -1 or port == 0 or any(part in (".", "..") for part in parts.path.split("/")):
            raise RecordError(f"The {name} address {url} is not a valid web address.")


def check_workspace(value: Any) -> str:
    workspace = _match(value, _WORKSPACE, "workspace")
    if workspace in RESERVED_WORKSPACES:
        raise RecordError("Workspace name is reserved.")
    return workspace


def check_legal_name(value: Any) -> str:
    return _match(value, _LEGAL_NAME, "legalName").strip()


def validate_record(data: Mapping[str, Any], *, new: bool = False) -> dict[str, Any]:
    if not isinstance(data, Mapping):
        raise RecordError("A record must be an object.")
    allowed = {
        "tenantId", "workspace", "legalName", "companyCode", "location",
        "locationKind", "clientConfig", "status", "planRef", "releaseRing",
        "rulesVersion", "services", "edition",
    }
    if set(data) - allowed - REMOVED_FIELDS:
        raise RecordError("Record has unknown fields.")
    services = _services(data.get("services"))
    workspace = check_workspace(data.get("workspace"))
    location = data.get("location")
    if not isinstance(location, Mapping) or set(location) != {
        "projectId", "databaseId", "authTenantId"
    }:
        raise RecordError("Invalid location.")
    auth_tenant = location["authTenantId"]
    status = normalized_status(data.get("status"))
    if status not in STATUSES:
        raise RecordError("Invalid status.")
    ring = data.get("releaseRing")
    if ring not in RELEASE_RINGS:
        raise RecordError("Invalid releaseRing.")
    kind = data.get("locationKind")
    if kind not in LOCATION_KINDS:
        raise RecordError("Invalid locationKind.")
    edition = data.get("edition")
    if edition is not None and edition not in EDITIONS:
        raise RecordError("Invalid edition.")
    if new and data.get("companyCode") != workspace:
        raise RecordError("The company code must equal the workspace for a new company.")
    if str(location["projectId"]).strip().lower() == config.PLATFORM_PROJECT_ID.lower():
        raise RecordError(PLATFORM_PROJECT_REFUSAL)
    normalized = {
        "tenantId": _match(data.get("tenantId"), _TENANT_ID, "tenantId"),
        "workspace": workspace,
        "legalName": _match(data.get("legalName"), _LEGAL_NAME, "legalName").strip(),
        "companyCode": _match(data.get("companyCode"), _COMPANY_CODE, "companyCode"),
        "location": {
            "projectId": _match(location["projectId"], _PROJECT_ID, "projectId"),
            "databaseId": _match(location["databaseId"], _DATABASE_ID, "databaseId"),
            "authTenantId": None
            if auth_tenant is None
            else _match(auth_tenant, _AUTH_TENANT_ID, "authTenantId"),
        },
        "locationKind": kind,
        "clientConfig": _client_config(data.get("clientConfig")),
        "status": status,
        "planRef": _match(data.get("planRef"), _SHORT_TEXT, "planRef"),
        "releaseRing": ring,
        "rulesVersion": _match(data.get("rulesVersion"), _SHORT_TEXT, "rulesVersion"),
        "services": services,
    }
    if edition is not None:
        normalized["edition"] = edition
    return normalized


def record_payload(
    record: Mapping[str, Any],
    *,
    version: int,
    issued_at: datetime,
    ttl: timedelta,
) -> dict[str, Any]:
    if isinstance(version, bool) or not isinstance(version, int) or version < 1:
        raise RecordError("Invalid version.")
    return {
        **validate_record(record),
        "kind": RECORD_KIND,
        "version": version,
        "issuedAt": format_timestamp(issued_at),
        "expiresAt": format_timestamp(issued_at + ttl),
    }

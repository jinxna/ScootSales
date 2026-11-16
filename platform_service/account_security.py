from __future__ import annotations

import hashlib
import logging
import time
from datetime import datetime, timezone
from typing import Any, Callable, Iterable, Mapping

from fastapi import Depends, FastAPI, Header
from fastapi.responses import JSONResponse
from firebase_admin import auth as admin_auth
from google.cloud import firestore
from pydantic import BaseModel, ConfigDict, Field

from . import auth
from .company_access import ADMIN_ROLES, CompanyAccess
from .directory import DirectoryStore
from .mail import STAFF_MAIL_TENANT, MailQueue
from .signing import format_timestamp
from .staff import end_staff_sessions
from .tenancy import resolve_tenant

SECURITY = "account_security"
MAX_DEVICES = 20
FRESH_SIGN_IN_SECONDS = 300
STAFF_ACCOUNT_NAME = "Scoot Sales Control Centre"
_BROWSERS = (("Edg/", "Edge"), ("OPR/", "Opera"), ("Firefox/", "Firefox"), ("Chrome/", "Chrome"),
             ("Safari/", "Safari"), ("Dart/", "Scoot Sales app"))
_SYSTEMS = (("Windows", "Windows"), ("Android", "Android"), ("iPhone", "iOS"), ("iPad", "iOS"), ("CrOS", "ChromeOS"),
            ("Mac OS X", "macOS"), ("Linux", "Linux"))
_LOG = logging.getLogger(__name__)


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def security_ref(db: firestore.Client, tenant_id: str, uid: str) -> Any:
    return db.collection(SECURITY).document(f"{tenant_id}_{_hash(uid)[:32]}")


def device_label(user_agent: str) -> str:
    browser = next((name for marker, name in _BROWSERS if marker in user_agent), "Unknown browser")
    system = next((name for marker, name in _SYSTEMS if marker in user_agent), "an unknown system")
    return f"{browser} on {system}"


def device_fingerprint(user_agent: str, device_id: str) -> str:
    return _hash(f"{device_label(user_agent)}\n{device_id}")[:24]


def remember_device(transaction: firestore.Transaction, reference: Any, current: Mapping[str, Any],
                    fingerprint: str, base: Mapping[str, Any], now: str) -> bool:
    devices = [item for item in current.get("devices", []) if item != fingerprint]
    transaction.set(reference, {**base, "devices": [*devices, fingerprint][-MAX_DEVICES:], "lastSignInAt": now},
                    merge=True)
    return fingerprint not in current.get("devices", [])


def queue_signin_alert(mail: MailQueue, tenant_id: str, uid: str, email: str, account_name: str, label: str,
                       at: str, fingerprint: str) -> dict[str, Any]:
    stamp = at.replace("-", "").replace(":", "")
    return mail.enqueue_or_report(
        tenant_id, f"signin-{_hash(uid)[:16]}-{fingerprint[:16]}-{stamp}", "signin_alert", email,
        {"tenantId": tenant_id, "accountName": account_name, "device": label, "at": at}, email)


class SignInReport(BaseModel):
    model_config = ConfigDict(extra="forbid")
    device: str = Field(default="", max_length=64, pattern=r"^[A-Za-z0-9_-]*$")


def _identity(authorization: str | None = Header(default=None)) -> auth.ClientIdentity:
    return auth.verify_client_token(auth.bearer_token(authorization))


def install_sign_in_route(app: FastAPI, *, directory: DirectoryStore, database: firestore.Client,
                          access_for: Callable[[Mapping[str, Any]], CompanyAccess], mail: MailQueue) -> None:
    @app.post("/v1/w/{workspace}/security/sign-in")
    def report_sign_in(workspace: str, body: SignInReport, user_agent: str = Header(default=""),
                       who: auth.ClientIdentity = Depends(_identity)) -> JSONResponse:
        context = resolve_tenant(who, directory, workspace=workspace, access_for=access_for)
        access = access_for(context.record["location"])
        profile = access.db.collection("user_access").document(context.uid).get().to_dict() or {}
        tracked = (profile.get("accessVersion") == 2 and profile.get("uid") == context.uid
                   and profile.get("status") == "active" and profile.get("role") in ADMIN_ROLES
                   and time.time() - who.auth_time <= FRESH_SIGN_IN_SECONDS)
        email = access.auth.get_user(context.uid).email if tracked else None
        if not email:
            return JSONResponse({"status": "not_tracked"}, headers={"Cache-Control": "no-store"})
        fingerprint = device_fingerprint(user_agent, body.device)
        reference = security_ref(database, context.tenant_id, context.uid)
        now = format_timestamp(datetime.now(timezone.utc))

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool:
            current = reference.get(transaction=transaction).to_dict() or {}
            return remember_device(transaction, reference, current, fingerprint,
                                   {"tenantId": context.tenant_id, "uid": context.uid}, now)

        new = write(database.transaction(max_attempts=10))
        if new:
            queue_signin_alert(mail, context.tenant_id, context.uid, email, context.record["legalName"],
                               device_label(user_agent), now, fingerprint)
        return JSONResponse({"status": "new_device" if new else "known_device"}, headers={"Cache-Control": "no-store"})


def _changed_at(user: Any) -> int | None:
    value = getattr(user, "_data", {}).get("passwordUpdatedAt")
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def note_password(db: firestore.Client, mail: MailQueue, tenant_id: str, user: Any, account_name: str,
                  on_change: Callable[[Any], None] | None = None) -> bool:
    changed_at = _changed_at(user)
    if changed_at is None:
        return False
    reference = security_ref(db, tenant_id, user.uid)
    seen = (reference.get().to_dict() or {}).get("passwordUpdatedAt")
    if seen == changed_at:
        return False
    changed = isinstance(seen, int) and changed_at > seen
    if on_change is not None and (changed or not isinstance(seen, int)):
        on_change(user)
    alert = changed and bool(user.email) and mail.enabled
    if alert:
        at = format_timestamp(datetime.fromtimestamp(changed_at / 1000, tz=timezone.utc))
        outcome = mail.enqueue_or_report(
            tenant_id, f"pwchanged-{_hash(user.uid)[:16]}-{changed_at}", "password_changed", user.email,
            {"tenantId": tenant_id, "accountName": account_name, "at": at}, "password-watch")
        if outcome["status"] not in ("queued", "rejected"):
            return False
    reference.set({"tenantId": tenant_id, "uid": user.uid, "passwordUpdatedAt": changed_at}, merge=True)
    return alert


def _users(client: admin_auth.Client, uids: list[str]) -> Iterable[Any]:
    for start in range(0, len(uids), 100):
        yield from client.get_users([admin_auth.UidIdentifier(uid) for uid in uids[start:start + 100]]).users


def watch_passwords(db: firestore.Client, mail: MailQueue, *, directory: DirectoryStore,
                    access_for: Callable[[Mapping[str, Any]], CompanyAccess],
                    staff_auth: Callable[[], admin_auth.Client]) -> dict[str, Any]:
    result: dict[str, Any] = {"checked": 0, "alerts": 0, "failed": []}
    groups: list[tuple[str, str, Callable[[], tuple[admin_auth.Client, list[str]]]]] = []

    def staff_group() -> tuple[admin_auth.Client, list[str]]:
        rows = [snapshot.to_dict() or {} for snapshot in db.collection("staff").where(
            filter=firestore.FieldFilter("status", "==", "active")).stream()]
        return staff_auth(), sorted(row["uid"] for row in rows if isinstance(row.get("uid"), str))

    groups.append((STAFF_MAIL_TENANT, STAFF_ACCOUNT_NAME, staff_group))
    for record in directory.list_records():
        if record["status"] != "live":
            continue

        def company_group(record: Mapping[str, Any] = record) -> tuple[admin_auth.Client, list[str]]:
            access = access_for(record["location"])
            rows = [snapshot.to_dict() or {} for snapshot in access.db.collection("user_access").where(
                filter=firestore.FieldFilter("status", "==", "active")).stream()]
            return access.auth, sorted(row["uid"] for row in rows
                                       if row.get("role") in ADMIN_ROLES and isinstance(row.get("uid"), str))

        groups.append((record["tenantId"], record["legalName"], company_group))

    def staff_sign_out(user: Any) -> None:
        changed_at = datetime.fromtimestamp(_changed_at(user) / 1000, tz=timezone.utc)
        end_staff_sessions(db, user.uid, datetime.now(timezone.utc), created_before=format_timestamp(changed_at))

    for tenant_id, account_name, open_group in groups:
        try:
            client, uids = open_group()
            for user in _users(client, uids):
                result["checked"] += 1
                result["alerts"] += note_password(db, mail, tenant_id, user, account_name,
                                                  staff_sign_out if tenant_id == STAFF_MAIL_TENANT else None)
        except Exception:
            _LOG.exception("Password watch failed for %s.", tenant_id)
            result["failed"].append(tenant_id)
    return result

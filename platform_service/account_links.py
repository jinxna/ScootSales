from __future__ import annotations

import hashlib
import logging
import re
import secrets
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Literal, Mapping

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse
from firebase_admin import auth as admin_auth
from google.cloud import firestore
from pydantic import BaseModel, ConfigDict, Field

from . import config, invitations
from .account_security import STAFF_ACCOUNT_NAME
from .company_access import CompanyAccess
from .directory import DirectoryStore
from .ids import local_date
from .mail import STAFF_MAIL_TENANT, MailQueue, MailTransport
from .staff import STAFF, allowed_domain, staff_id
from .tenancy import company_serves

RATE_LIMITS = "rate_limits"
RESPONSE_FLOOR_SECONDS = 1.5
ADDRESS_LIMIT_PER_DAY = 6
UNKNOWN_KIND = "-/"
_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]+$")
_WORKSPACE = re.compile(r"^[a-z0-9-]{2,32}$")
_ACCEPTED = {"status": "accepted"}
_NO_STORE = {"Cache-Control": "no-store"}
_LOG = logging.getLogger(__name__)


@dataclass(frozen=True)
class LinkAction:
    kind: str
    param: str
    generate: Callable[[admin_auth.Client, str, admin_auth.ActionCodeSettings | None], str]
    needed: Callable[[Any], bool]


ACTIONS = {
    "password-reset": LinkAction("password_reset", "resetUrl",
                                 lambda client, email, settings: client.generate_password_reset_link(email, settings),
                                 lambda user: True),
    "email-verification": LinkAction("email_verification", "verifyUrl",
                                     lambda client, email, settings: client.generate_email_verification_link(
                                         email, settings),
                                     lambda user: not user.email_verified),
}


class CompanyLinkBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str = Field(max_length=320)
    client: Literal["dashboard", "phone"] = "dashboard"


class StaffLinkBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str = Field(max_length=320)


def admit(db: firestore.Client, scope: str, value: str, limit: int, now: datetime, daily: bool = False) -> bool:
    digest = hashlib.sha256(f"{scope}\n{value}".encode("utf-8")).hexdigest()[:32]
    bucket = local_date(now) if daily else now.strftime("%Y%m%d%H")
    reference = db.collection(RATE_LIMITS).document(f"{scope}_{digest}_{bucket}")

    @firestore.transactional
    def count(transaction: firestore.Transaction) -> bool:
        used = int((reference.get(transaction=transaction).to_dict() or {}).get("count") or 0)
        if used >= limit:
            return False
        transaction.set(reference, {"count": used + 1, "expiresAt": now + timedelta(hours=26 if daily else 2)})
        return True

    return count(db.transaction(max_attempts=10))


def _https(value: str) -> str | None:
    base = value.strip().rstrip("/")
    return base if base.startswith("https://") else None


def _settings(url: str | None) -> admin_auth.ActionCodeSettings | None:
    return admin_auth.ActionCodeSettings(url) if url else None


def install_account_link_routes(app: FastAPI, *, database: firestore.Client, directory: DirectoryStore,
                                access_for: Callable[[Mapping[str, Any]], CompanyAccess], mail: MailQueue,
                                transport: Callable[[], MailTransport],
                                staff_auth: Callable[[], admin_auth.Client]) -> None:
    def admit_kind(kind: str | None, peer: str, now: datetime) -> bool:
        return kind is None or admit(database, "link_kind", f"{kind}|{peer}",
                                     config.ACCOUNT_LINK_NETWORK_LIMIT_PER_HOUR, now)

    def admit_net(peer: str, now: datetime) -> bool:
        return admit(database, "link_net", peer, 3 * config.ACCOUNT_LINK_NETWORK_LIMIT_PER_HOUR, now)

    def throttle(request: Request, email: str, where: str, owner: str, kind_of: Callable[[], str | None]) -> None:
        now = datetime.now(timezone.utc)
        peer = invitations.client_ip(request.headers, request.client.host if request.client else None)
        kind = kind_of()
        unknown = kind is not None and kind.startswith(UNKNOWN_KIND)
        if not ((admit_net(peer, now) if unknown else True)
                and admit_kind(kind, peer, now)
                and admit(database, "link_addr", f"{where}|{email}", config.ACCOUNT_LINK_ADDRESS_LIMIT_PER_HOUR, now)
                and admit(database, "link_addr_day", f"{owner}|{email}", ADDRESS_LIMIT_PER_DAY, now,
                          daily=True)
                and (True if unknown else admit_net(peer, now))):
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many requests. Try again later.",
                                headers={"Retry-After": str(3600 - now.minute * 60 - now.second), **_NO_STORE})

    def accepted(started: float, work: Callable[[], None]) -> JSONResponse:
        try:
            work()
        except Exception:
            _LOG.exception("Account link request failed.")
        remaining = RESPONSE_FLOOR_SECONDS - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining)
        return JSONResponse(_ACCEPTED, status_code=status.HTTP_202_ACCEPTED, headers=_NO_STORE)

    def address(value: str) -> str:
        email = value.strip().lower()
        if not _EMAIL.fullmatch(email):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Enter a valid email.", headers=_NO_STORE)
        return email

    def send(tenant_id: str, action: LinkAction, user: Any, account_name: str, link: str) -> None:
        mail.send_now(tenant_id, f"{action.kind}-{hashlib.sha256(user.uid.encode()).hexdigest()[:16]}-"
                                 f"{secrets.token_hex(8)}", action.kind, user.email,
                      {"tenantId": tenant_id, "accountName": account_name, action.param: link}, "account-link",
                      transport())

    def company_link(action: LinkAction, record: Mapping[str, Any] | None, workspace: str, email: str,
                     client: str) -> None:
        if record is None or not company_serves(directory, record):
            return
        access = access_for(record["location"])
        try:
            user = access.auth.get_user_by_email(email)
        except admin_auth.UserNotFoundError:
            return
        profile = access.db.collection("user_access").document(user.uid).get().to_dict() or {}
        if user.disabled or not user.email or profile.get("status") != "active" or not action.needed(user):
            return
        base = _https(config.DASHBOARD_URL)
        target = f"{base}/w/{workspace}" if base and client == "dashboard" else None
        send(record["tenantId"], action, user, record["legalName"],
             action.generate(access.auth, user.email, _settings(target)))

    def staff_link(email: str) -> None:
        person = database.collection(STAFF).document(staff_id(email)).get().to_dict() or {}
        if person.get("status") != "active" or not isinstance(person.get("uid"), str) or not allowed_domain(email):
            return
        client = staff_auth()
        user = client.get_user(person["uid"])
        if user.disabled or (user.email or "").lower() != email:
            return
        action = ACTIONS["password-reset"]
        send(STAFF_MAIL_TENANT, action, user, STAFF_ACCOUNT_NAME,
             action.generate(client, user.email, _settings(_https(config.STAFF_URL))))

    @app.post("/v1/w/{workspace}/auth/{action_name}", status_code=status.HTTP_202_ACCEPTED)
    def company_account_link(workspace: str, action_name: str, body: CompanyLinkBody,
                             request: Request) -> JSONResponse:
        action = ACTIONS.get(action_name)
        if action is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Not found.")
        started = time.monotonic()
        email = address(body.email)
        try:
            known = directory.find_by_workspace(workspace) if _WORKSPACE.fullmatch(workspace) else None
        except Exception:
            _LOG.exception("Account link company lookup failed.")
            known = None

        def kind_of() -> str | None:
            return f"{known['tenantId']}/{action_name}" if known else f"{UNKNOWN_KIND}{action_name}"

        throttle(request, email, f"{workspace}/{action_name}", f"w:{workspace}", kind_of)
        return accepted(started, lambda: company_link(action, known, workspace, email, body.client))

    @app.post("/staff/v1/password-reset", status_code=status.HTTP_202_ACCEPTED)
    def staff_password_reset(body: StaffLinkBody, request: Request) -> JSONResponse:
        started = time.monotonic()
        email = address(body.email)
        throttle(request, email, "staff/password-reset", "staff", lambda: "staff/password-reset")
        return accepted(started, lambda: staff_link(email))

from __future__ import annotations

import hashlib
import hmac
import ipaddress
import logging
import os
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from firebase_admin import auth as admin_auth
from firebase_admin import exceptions as firebase_exceptions
from google.api_core import exceptions as gcloud_exceptions
from google.cloud import firestore

from . import auth, config
from .account_deletion import person_has_history, retire_code
from .commands import (
    CommandProblem,
    PlanLimit,
    PlanProblem,
    http_error,
    plan_refusal,
    run_command,
)
from .company_access import CompanyAccess, active_admin_row, company_access, require_active_admin
from .directory import DirectoryError, DirectoryStore
from .mail import MailQueue, build_transport
from .staff import mask
from .operations import (
    commit_when_free,
    FAILED,
    LeaseLost,
    OperationContext,
    OperationError,
    OperationStore,
    Step,
    operation_id as make_operation_id,
)
from .plans import PlanStore
from .seats import (
    active_admin,
    check_plan_projection,
    limit_text,
    move_counts,
    pool_for_role,
    read_usage,
    seat_class_for_role,
    usage_counts,
)
from .signing import SignatureError, b64url_decode, format_timestamp
from .lifecycle import LifecycleConflict, TenantLifecycle
from .tenancy import TenantContext, company_serves

log = logging.getLogger(__name__)

INVITATIONS = "invitations"
RATE_LIMITS = "rate_limits"
USERS = "users"
ACCESS = "user_access"
CLAIMS = "employee_codes"
CODE_IN_USE = "That employee code is already in use."
CODE_RETIRED = "That employee code was used before by someone else. Choose a different code."

INVITE_URL_ENV = "PLATFORM_INVITE_URL"

ACTION_CREATE = "invitation.create"
ACTION_FIRST_ADMIN = "invitation.first_admin"
FIRST_ADMIN_CREATOR = "platform:first-admin"
ACTION_REVOKE_ACCOUNT = "account.revoke"
ACTION_REACTIVATE = "account.reactivate"
ACTION_ROLE = "account.role"
ACTION_REMOVE = "account.remove"
ACTION_MOVE = "account.move"
ACTION_CODE = "account.code"

CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
CODE_LENGTH = 12
INVITE_TTL = timedelta(hours=72)
MAX_FAILURES = 5
REDEEM_LEASE = timedelta(minutes=5)
SUPERVISOR_CAP = 5
ROLES = ("salesman", "supervisor", "branch_manager", "admin")
ROLE_LABELS = {"salesman": "Salesperson", "supervisor": "Supervisor", "branch_manager": "Branch manager",
               "admin": "Admin", "developer": "Developer"}
MAX_RESENDS = 5
CODE_FIELDS = ("employeeCode", "employee_code", "staffId", "staff_id")
IN_QUERY_LIMIT = 30
MAX_CASE_LETTERS = 6

MSG_INVALID = "The invitation code or check is not valid."
MSG_EXPIRED = "This invitation has expired. Ask your administrator for a new one."
MSG_USED = "This invitation was already used."
MSG_REVOKED = "This invitation was revoked."
MSG_CREATOR_GONE = (
    "This invitation is closed because the administrator who sent it no longer has access. "
    "Ask an administrator of your company for a new invitation."
)
MSG_LOCKED = (
    "This invitation is locked after too many tries. Ask your administrator for a new one."
)
MSG_OTHER_PROJECT = "This invitation is for another company. Change company first."
MSG_RATE = "Too many attempts from this network. Try again later."
MSG_EMAIL_CODE_NEEDED = "Enter the 6-digit code mailed to your email address."
MSG_EMAIL_CODE_WRONG = "The email code is not right."
MSG_EMAIL_CODE_EXPIRED = "The email code has expired. Ask for a new one."
MSG_EMAIL_CODE_LOCKED = "Too many wrong email codes. Ask for a new one."
MSG_EMAIL_CODE_SENDS = "Too many email codes were sent for this invitation."

EMAIL_CODE_MINUTES = 10
EMAIL_CODE_MAX_WRONG = 5
EMAIL_CODE_MAX_SENDS = 5

_EMPLOYEE_CODE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,189}$")
_PHONE = re.compile(r"^[0-9+()\-. ]{4,24}$")
_BRANCH = re.compile(r"^[^/\x00-\x1f\x7f]{0,64}$")
_UID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_NAME = re.compile(r"^[^\x00-\x1f\x7f]{1,80}$")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


class InviteConfigError(RuntimeError):
    pass


class InviteProblem(Exception):
    def __init__(self, message: str, status_code: int = status.HTTP_409_CONFLICT) -> None:
        super().__init__(message)
        self.status_code = status_code


def load_secret() -> bytes:
    text = os.environ.get(config.INVITE_SECRET_ENV, "").strip()
    if not text:
        raise InviteConfigError("Invitations need PLATFORM_INVITE_SECRET.")
    try:
        raw = b64url_decode(text)
    except SignatureError as error:
        raise InviteConfigError("PLATFORM_INVITE_SECRET is not base64url.") from error
    if len(raw) < 32:
        raise InviteConfigError("PLATFORM_INVITE_SECRET must be at least 32 bytes.")
    return raw


def normalize_code(text: str) -> str:
    cleaned = re.sub(r"[\s-]", "", text).upper()
    return cleaned.replace("O", "0").replace("I", "1").replace("L", "1")


def is_valid_code(normalized: str) -> bool:
    return len(normalized) == CODE_LENGTH and all(c in CODE_ALPHABET for c in normalized)


def format_code(normalized: str) -> str:
    return "-".join(normalized[i : i + 4] for i in range(0, CODE_LENGTH, 4))


def derive_code(secret: bytes, operation_id: str) -> str:
    mac = hmac.new(secret, b"scoot-invite-code\n" + operation_id.encode(), hashlib.sha256)
    number = int.from_bytes(mac.digest()[:8], "big") >> 4
    return "".join(
        CODE_ALPHABET[(number >> (5 * index)) & 31] for index in reversed(range(CODE_LENGTH))
    )


def invitation_id_for(normalized_code: str) -> str:
    return hashlib.sha256(normalized_code.encode()).hexdigest()[:32]


def derive_uid(operation_id: str) -> str:
    return "inv" + hashlib.sha256(operation_id.encode()).hexdigest()[:25]


def needs_email_code(data: Mapping[str, Any]) -> bool:
    return not str(data.get("signInId") or "").endswith(".invalid")


def email_code_hash(secret: bytes, invitation_id: str, digits: str) -> str:
    message = f"scoot-invite-email-code\n{invitation_id}\n{digits}".encode()
    return hmac.new(secret, message, hashlib.sha256).hexdigest()


def normalize_check(kind: str, text: str) -> str:
    if kind == "phone_last4":
        return re.sub(r"\D", "", text)[-4:]
    return text.strip().lower()


def check_hash(secret: bytes, invitation_id: str, check_value: str) -> str:
    message = f"scoot-invite-check\n{invitation_id}\n{check_value}".encode()
    return hmac.new(secret, message, hashlib.sha256).hexdigest()


def trusted_proxy_networks() -> list[ipaddress.IPv4Network | ipaddress.IPv6Network]:
    return [ipaddress.ip_network(part.strip(), strict=False)
            for part in config.CLIENT_IP_TRUSTED_PROXIES.split(",") if part.strip()]


def from_trusted_proxy(peer: str | None) -> bool:
    networks = trusted_proxy_networks()
    if not networks:
        return auth.emulator_mode()
    try:
        address = ipaddress.ip_address(peer or "")
    except ValueError:
        return False
    return any(address in network for network in networks)


def _network_of(address: str) -> str:
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError:
        return address
    if parsed.version == 6 and parsed.ipv4_mapped is None:
        return str(ipaddress.ip_network(f"{parsed}/64", strict=False))
    return address


def client_ip(headers: Mapping[str, str], peer: str | None) -> str:
    header = config.CLIENT_IP_HEADER
    if header and from_trusted_proxy(peer):
        parts = [part.strip() for part in headers.get(header, "").split(",") if part.strip()]
        hops = max(config.CLIENT_IP_TRUSTED_HOPS, 1)
        if len(parts) >= hops:
            return _network_of(parts[-hops])
    return _network_of(peer) if peer else "unknown"


def _bad(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=detail)


def clean_invite(body: Mapping[str, Any], tenant_id: str) -> dict[str, Any]:
    name = str(body.get("displayName") or "").strip()
    if not _NAME.fullmatch(name):
        raise _bad("Enter a name of 1 to 80 characters.")
    role = body.get("role")
    if role not in ROLES:
        raise _bad("Choose a valid role.")
    code = str(body.get("employeeCode") or "").strip()
    if not _EMPLOYEE_CODE.fullmatch(code):
        raise _bad("Enter an employee code of 1 to 32 letters, digits, dots, dashes or underscores.")
    code = code.upper()
    branch = str(body.get("branchId") or "").strip()
    if not _BRANCH.fullmatch(branch):
        raise _bad("Enter a valid branch.")
    if not branch and role != "admin":
        raise _bad("This role needs a branch.")
    email = str(body.get("email") or "").strip().lower() or None
    if email and (len(email) > 254 or not _EMAIL.fullmatch(email)):
        raise _bad("Enter a valid email address.")
    phone = str(body.get("phone") or "").strip() or None
    if phone:
        digits = re.sub(r"\D", "", phone)
        if not _PHONE.fullmatch(phone) or not 4 <= len(digits) <= 15:
            raise _bad("Enter a valid phone number.")
    if not email and not phone:
        raise _bad("Enter an email address or a phone number.")
    supervisor = str(body.get("supervisorUid") or "").strip() or None
    if supervisor and not _UID.fullmatch(supervisor):
        raise _bad("Choose a valid supervisor.")
    return {
        "displayName": name,
        "role": role,
        "employeeCode": code,
        "branchId": branch,
        "email": email,
        "phone": phone,
        "supervisorUid": supervisor if role == "salesman" else None,
        "signInId": email or f"{code.lower()}@{tenant_id.replace('_', '-')}.invalid",
        "checkKind": "phone_last4" if phone else "email",
    }


def _gone(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_410_GONE, detail=detail)


MSG_BUSY = "The service is busy. Try again."


def _run_transaction(function: Any, transaction: Any) -> Any:
    try:
        return function(transaction)
    except ValueError as error:
        if "Failed to commit transaction" not in str(error):
            raise
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=MSG_BUSY, headers={"Retry-After": "1"}
        ) from error


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _as_time(value: Any) -> datetime | None:
    return value if isinstance(value, datetime) else None


def _text_time(value: Any) -> str | None:
    moment = _as_time(value)
    return format_timestamp(moment) if moment else None


class InvitationService:
    def __init__(
        self,
        platform: firestore.Client,
        runner: OperationStore,
        directory: DirectoryStore,
        *,
        secret: bytes | None,
        access_for: Callable[[Mapping[str, Any]], CompanyAccess] = company_access,
        clock: Callable[[], datetime] = _utc_now,
        plans: PlanStore | None = None,
        mail: MailQueue | None = None,
    ) -> None:
        self.platform = platform
        self.runner = runner
        self.directory = directory
        self.secret = secret
        self.access_for = access_for
        self.clock = clock
        self.plans = plans or PlanStore(platform)
        self.mail = mail if mail is not None else MailQueue(platform)

    def _secret(self) -> bytes:
        if self.secret is None:
            raise InviteConfigError("Invitations need PLATFORM_INVITE_SECRET.")
        return self.secret

    def _access(self, params: Mapping[str, Any]) -> CompanyAccess:
        return self.access_for(
            {
                "projectId": params["projectId"],
                "databaseId": params["databaseId"],
                "authTenantId": params["authTenantId"],
            }
        )

    @staticmethod
    def _location_params(ctx: TenantContext) -> dict[str, Any]:
        location = ctx.record["location"]
        return {
            "tenantId": ctx.tenant_id,
            "workspace": ctx.workspace,
            "projectId": location["projectId"],
            "databaseId": location["databaseId"],
            "authTenantId": location["authTenantId"],
        }

    def require_admin(self, access: CompanyAccess, uid: str) -> dict[str, Any]:
        return require_active_admin(access, uid)

    @staticmethod
    def _known_pool(role: Any) -> str | None:
        if role not in (*ROLES, "developer"):
            raise CommandProblem("The stored account role is invalid. Review the account first.")
        return pool_for_role(role)

    @staticmethod
    def _transaction_caller(
        transaction: firestore.Transaction, db: firestore.Client,
        params: Mapping[str, Any], target: Mapping[str, Any] | None = None,
    ) -> None:
        if params.get("firstAdmin") is True and params.get("createdBy") == FIRST_ADMIN_CREATOR:
            return
        uid = params.get("requestedBy") or params.get("revokedBy") or params.get("createdBy")
        if not isinstance(uid, str) or not uid:
            raise CommandProblem("The requesting administrator could not be verified.")
        caller = db.collection(ACCESS).document(uid).get(transaction=transaction).to_dict() or {}
        if not (active_admin_row(caller, uid) and caller.get("isActive") is not False
                and caller.get("invitationState") != "pending"):
            raise CommandProblem("Only an active administrator of this company can do this.")
        if uid == params.get("uid"):
            raise CommandProblem("You cannot change your own account here.")
        if target and target.get("role") == "developer" and caller.get("role") != "developer":
            raise CommandProblem("Only a developer can change a developer account.")

    def create_invitation(
        self, ctx: TenantContext, idempotency_key: str, body: Mapping[str, Any]
    ) -> dict[str, Any]:
        self._secret()
        fields = clean_invite(body, ctx.tenant_id)
        access = self.access_for(ctx.record["location"])
        self.require_admin(access, ctx.uid)
        try:
            self.release_stale_seats(ctx.record)
        except Exception as error:
            log.error("seat sweep failed: %s", type(error).__name__)
        return self._start_invitation(ctx, access, fields, f"{ctx.workspace}:{idempotency_key}", ctx.uid, {})

    def _start_invitation(
        self, ctx: TenantContext, access: CompanyAccess, fields: Mapping[str, Any], key: str, actor: str,
        extra: Mapping[str, Any],
    ) -> dict[str, Any]:
        secret = self._secret()
        op_id = make_operation_id(ACTION_CREATE, key)
        if self.runner.get(op_id) is None:
            self._precheck(access, fields, ctx.tenant_id)
        code = derive_code(secret, op_id)
        invitation_id = invitation_id_for(code)
        check_value = normalize_check(
            fields["checkKind"], fields["phone"] or fields["email"] or ""
        )
        params = {
            **self._location_params(ctx),
            **fields,
            **extra,
            "uid": derive_uid(op_id),
            "createdBy": ctx.uid,
            "checkHash": check_hash(secret, invitation_id, check_value),
        }
        steps = self.create_steps()
        try:
            self.runner.begin(
                idempotency_key=key,
                action=ACTION_CREATE,
                actor=FIRST_ADMIN_CREATOR if extra.get("firstAdmin") else actor,
                tenant_id=ctx.tenant_id,
                reason="Invitation",
                ticket=None,
                field_names=sorted(params),
                params=params,
                step_names=[step.name for step in steps],
            )
        except OperationError as error:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This idempotency key was already used for a different request.",
            ) from error
        except ValueError as error:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Too many invitations were created at once. Try again.",
            ) from error

        if extra.get("firstAdmin"):
            self.runner.annotate(op_id, {"actor": actor})
        try:
            record = self.runner.run(op_id, steps)
        except LeaseLost as error:
            raise self._in_progress() from error
        except Exception as error:
            self._after_failure(op_id)
            raise self._failure(error) from error
        if record.get("status") == FAILED:
            self._after_failure(op_id)
            error_info = record.get("error") or {}
            raise self._failure_text(error_info.get("type"), error_info.get("message"))
        if record.get("status") != "completed":
            raise self._in_progress()
        created = self._created_response(record)
        self._mail_invitation(ctx, record["params"].get("email"), created, record.get("actor") or ctx.uid)
        return created

    def grant_first_admin(
        self, record: Mapping[str, Any], *, actor: str, draft_id: str, name: str, email: str, employee_code: str,
    ) -> dict[str, Any]:
        self._secret()
        tenant_id = record["tenantId"]
        location = record["location"]
        fields = clean_invite({"displayName": name, "role": "admin", "employeeCode": employee_code, "branchId": "",
                               "email": email, "phone": None, "supervisorUid": None}, tenant_id)
        access = self.access_for(location)
        ctx = TenantContext(tenant_id=tenant_id, workspace=record["workspace"], project_id=location["projectId"],
                            auth_tenant_id=location.get("authTenantId"), uid=FIRST_ADMIN_CREATOR, record=record)
        key = self._first_admin_key(record["workspace"], draft_id)
        try:
            user = access.auth.get_user_by_email(fields["signInId"])
        except admin_auth.UserNotFoundError:
            user = None
        row = (access.db.collection(ACCESS).document(user.uid).get().to_dict() or {}) if user else {}
        earlier = self.runner.get(make_operation_id(ACTION_CREATE, key))
        changed = earlier is not None and earlier["params"]["email"] != fields["email"]
        first_name = name.split()[0]
        retired = earlier is not None and not changed and self._invitation_status(key) == "revoked"
        if user and active_admin_row(row, user.uid) and row.get("isActive") is not False \
                and row.get("invitationState") != "pending":
            if changed:
                self._retire_first_admin_invitation(key, earlier, actor, first_name)
            return {"state": "active", "path": "account", "uid": user.uid, "invitation": None}
        if (changed or retired) and user is None:
            created = self._reissue_first_admin(ctx, access, key, earlier, fields, actor, first_name)
            return {"state": "invited", "path": "invitation", "uid": created["uid"], "invitation": created}
        if earlier is not None and not changed:
            fields = {name: earlier["params"][name] for name in fields}
        if (earlier is None or changed) and user is not None:
            op_id = make_operation_id(ACTION_FIRST_ADMIN, f"{key}:{user.uid}")
            resuming = bool(row) and row.get("invitationOp") == op_id
            if row and not resuming:
                role = row.get("role")
                if role not in ("admin", "developer"):
                    raise CommandProblem(
                        f"This email already has access in this company as {ROLE_LABELS.get(role, role)}. "
                        "Make this person the Admin, or use another email.", fix="promote_first_admin")
                raise HTTPException(status.HTTP_409_CONFLICT, (
                    "This email has an administrator account that is not active. "
                    "Sort it out in the company first, or use another email."))
            if user.disabled:
                raise HTTPException(status.HTTP_409_CONFLICT,
                                    "This sign-in account is turned off in the company's Firebase project. "
                                    "Turn it on there, or use another email.")
            if resuming:
                fields = {**fields, "employeeCode": row["employeeCode"]}
            if changed:
                self._retire_first_admin_invitation(key, earlier, actor, first_name)
            return self._grant_existing_account(ctx, access, fields, user, op_id, resuming)
        created = self._start_invitation(ctx, access, fields, key, actor, {"firstAdmin": True})
        return {"state": "invited", "path": "invitation", "uid": created["uid"], "invitation": created}

    def _invitation_status(self, key: str) -> str | None:
        op_id = make_operation_id(ACTION_CREATE, key)
        reference = self.platform.collection(INVITATIONS).document(
            invitation_id_for(derive_code(self._secret(), op_id)))
        return (reference.get().to_dict() or {}).get("status")

    def _retire_earlier_first_admin(
        self, tenant: Mapping[str, Any], draft: Mapping[str, Any], email: str, actor: str, first_name: str,
    ) -> None:
        key = self._first_admin_key(tenant["workspace"], draft["draftId"])
        earlier = self.runner.get(make_operation_id(ACTION_CREATE, key))
        if earlier is not None and earlier["params"]["email"] != email:
            self._retire_first_admin_invitation(key, earlier, actor, first_name)

    def _first_admin_key(self, workspace: str, draft_id: str) -> str:
        key = f"{workspace}:first-admin:{draft_id}"
        sent_again = 0
        while self.runner.get(make_operation_id(ACTION_CREATE, f"{key}:resend:{sent_again + 1}")) is not None:
            sent_again += 1
        return key if sent_again == 0 else f"{key}:resend:{sent_again}"

    @staticmethod
    def _row_fingerprint(row: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "role": row.get("role"),
            "status": row.get("status"),
            "isActive": row.get("isActive"),
            "invitationState": row.get("invitationState"),
            "employeeCode": row.get("employeeCode"),
            "branchId": row.get("branchId"),
            "supervisorUid": row.get("supervisorUid") or "",
            "updatedAt": _text_time(row.get("updatedAt")),
        }

    @staticmethod
    def _first_admin_context(tenant: Mapping[str, Any]) -> TenantContext:
        location = tenant["location"]
        return TenantContext(tenant_id=tenant["tenantId"], workspace=tenant["workspace"],
                             project_id=location["projectId"], auth_tenant_id=location.get("authTenantId"),
                             uid=FIRST_ADMIN_CREATOR, record=tenant)

    def promote_to_first_admin(
        self, tenant: Mapping[str, Any], draft: Mapping[str, Any], employee_code: str,
        expected_row: Mapping[str, Any] | None, *, actor: str,
    ) -> dict[str, Any]:
        self._secret()
        tenant_id = tenant["tenantId"]
        fields = clean_invite({"displayName": draft["adminName"], "role": "admin", "employeeCode": employee_code,
                               "branchId": "", "email": draft["adminEmail"], "phone": None,
                               "supervisorUid": None}, tenant_id)
        access = self.access_for(tenant["location"])
        try:
            user = access.auth.get_user_by_email(fields["signInId"])
        except admin_auth.UserNotFoundError:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "This email has no sign-in account. Give access to send an invitation.") from None
        row = access.db.collection(ACCESS).document(user.uid).get().to_dict() or {}
        first_name = str(draft["adminName"]).split()[0]
        if active_admin_row(row, user.uid) and row.get("isActive") is not False \
                and row.get("invitationState") != "pending":
            self._retire_earlier_first_admin(tenant, draft, fields["email"], actor, first_name)
            return {"state": "active", "path": "account", "uid": user.uid, "invitation": None}
        if not row:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "This email has a sign-in account but no access in this company. "
                                "Give access to link it.")
        role = row.get("role")
        if role not in ("salesman", "supervisor", "branch_manager"):
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "This access record cannot be made the Admin here. Sort it out in People first.")
        if row.get("accessVersion") != 2 or row.get("uid") != user.uid:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{first_name}'s access record needs repair. Fix it in People first.")
        if row.get("invitationState") == "pending":
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{first_name} has not accepted the invitation yet. Wait, or resend it.")
        if row.get("status") != "active" or row.get("isActive") is False:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{first_name}'s access is switched off. Switch it on in People first.")
        if user.disabled:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "This sign-in account is turned off in the company's Firebase project. "
                                "Turn it on there, or use another email.")
        kept_code = str(row.get("employeeCode") or "")
        if not kept_code:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{first_name} has no employee code. Set it in People first.")
        if canonical_code(employee_code) != canonical_code(kept_code):
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{first_name} keeps employee code {kept_code}. Enter {kept_code}.")
        fingerprint = self._row_fingerprint(row)
        if expected_row is None:
            return {
                "state": "preview", "uid": user.uid, "email": fields["signInId"], "name": draft["adminName"],
                "from": ROLE_LABELS[role], "to": ROLE_LABELS["admin"], "employeeCode": kept_code,
                "expectedRow": fingerprint,
                "line": (f"{draft['adminName']} is a {ROLE_LABELS[role]} now. This makes the person the Admin. "
                         f"Same sign-in and password. Employee code {kept_code} stays."),
            }
        if dict(expected_row) != fingerprint:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{first_name}'s access changed after you looked. Look again.")
        self._precheck_seat(access, tenant_id, "admin")
        self._retire_earlier_first_admin(tenant, draft, fields["email"], actor, first_name)
        digest = hashlib.sha256(repr(sorted(fingerprint.items())).encode()).hexdigest()[:16]
        run_command(
            self.runner,
            key=f"{tenant['workspace']}:first-admin-promote:{draft['draftId']}:{user.uid}:{digest}",
            action=ACTION_ROLE,
            actor=actor,
            tenant_id=tenant_id,
            reason="First administrator",
            params=self._command_params(self._first_admin_context(tenant), user.uid, role="admin", branchId="",
                                        supervisorUid=None, firstAdmin=True, createdBy=FIRST_ADMIN_CREATOR,
                                        expectedRow=fingerprint),
            steps=self.role_steps(),
            fallback="The person could not be made the Admin. Try again.",
        )
        return {"state": "active", "path": "promote", "uid": user.uid, "invitation": None}

    def resend_first_admin_invitation(
        self, tenant: Mapping[str, Any], draft: Mapping[str, Any], *, actor: str,
    ) -> dict[str, Any]:
        secret = self._secret()
        first_name = str(draft["adminName"]).split()[0]
        accepted = HTTPException(status.HTTP_409_CONFLICT, f"{first_name} already accepted. Nothing to resend.")
        access = self.access_for(tenant["location"])
        key = self._first_admin_key(tenant["workspace"], draft["draftId"])
        op_id = make_operation_id(ACTION_CREATE, key)
        earlier = self.runner.get(op_id)
        if earlier is not None and earlier["params"]["email"] != str(draft["adminEmail"]).strip().lower():
            granted = self.grant_first_admin(
                tenant, actor=actor, draft_id=draft["draftId"], name=draft["adminName"], email=draft["adminEmail"],
                employee_code=draft.get("adminEmployeeCode") or earlier["params"]["employeeCode"])
            if granted["state"] != "invited":
                return granted
            sent = self.platform.collection(INVITATIONS).document(granted["invitation"]["invitationId"]).get().to_dict() or {}
            return {**granted, "resent": True, "mail": sent.get("mail")}
        current = first_admin_state(access, draft["adminEmail"])
        if current["state"] == "active":
            raise accepted
        if current["state"] == "blocked":
            raise HTTPException(status.HTTP_409_CONFLICT, current["line"])
        if earlier is None:
            raise HTTPException(status.HTTP_409_CONFLICT, "No invitation was sent yet. Choose Give access first.")
        reference = self.platform.collection(INVITATIONS).document(invitation_id_for(derive_code(secret, op_id)))
        stored = reference.get().to_dict() or {}
        if stored.get("status") == "redeemed":
            raise accepted
        ctx = self._first_admin_context(tenant)
        now = self.clock()
        expires = _as_time(stored.get("expiresAt"))
        fields = clean_invite({"displayName": draft["adminName"], "role": "admin",
                               "employeeCode": draft.get("adminEmployeeCode") or earlier["params"]["employeeCode"],
                               "branchId": "", "email": draft["adminEmail"], "phone": None, "supervisorUid": None},
                              tenant["tenantId"])
        same_person = earlier["params"]["email"] == fields["email"]
        if same_person and stored.get("status") == "open" and expires and expires > now:
            count = int(stored.get("resendCount") or 0) + 1
            if count > MAX_RESENDS:
                raise HTTPException(status.HTTP_409_CONFLICT,
                                    f"This invitation was already sent again {MAX_RESENDS} times. "
                                    "Wait until it expires, then resend.")
            reference.update({"resendCount": count})
            created = self._created_response(earlier)
            self._mail_invitation(ctx, earlier["params"].get("email"), created, actor,
                                  mail_key=f"invite-{reference.id}-r{count}")
            return {"state": "invited", "path": "invitation", "uid": created["uid"], "invitation": created,
                    "resent": True, "mail": (reference.get().to_dict() or {}).get("mail")}
        if same_person:
            fields = {name: earlier["params"][name] for name in fields}
        created = self._reissue_first_admin(ctx, access, key, earlier, fields, actor, first_name)
        sent = self.platform.collection(INVITATIONS).document(created["invitationId"]).get().to_dict() or {}
        return {"state": "invited", "path": "invitation", "uid": created["uid"], "invitation": created,
                "resent": True, "mail": sent.get("mail")}

    def _retire_first_admin_invitation(
        self, key: str, earlier: Mapping[str, Any], actor: str, first_name: str,
    ) -> None:
        op_id = make_operation_id(ACTION_CREATE, key)
        reference = self.platform.collection(INVITATIONS).document(
            invitation_id_for(derive_code(self._secret(), op_id)))
        stored = reference.get().to_dict() or {}
        now = self.clock()
        if stored.get("status") == "redeeming" and (_as_time(stored.get("redeemLeaseUntil")) or now) > now:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{first_name} is accepting the invitation right now. Try again in a moment.")
        if stored:
            self._close_invitation(reference, actor)
        self.discard_provisional(op_id, earlier["params"])

    def _reissue_first_admin(
        self, ctx: TenantContext, access: CompanyAccess, key: str, earlier: Mapping[str, Any],
        fields: Mapping[str, Any], actor: str, first_name: str,
    ) -> dict[str, Any]:
        self._retire_first_admin_invitation(key, earlier, actor, first_name)
        base, _, turn = key.partition(":resend:")
        return self._start_invitation(ctx, access, fields, f"{base}:resend:{int(turn or 0) + 1}", actor,
                                      {"firstAdmin": True})

    def _grant_existing_account(
        self, ctx: TenantContext, access: CompanyAccess, fields: Mapping[str, Any], user: Any, op_id: str,
        resuming: bool,
    ) -> dict[str, Any]:
        refusal = None if resuming else self._code_refusal(access, fields["employeeCode"])
        if refusal:
            raise HTTPException(status.HTTP_409_CONFLICT, refusal)
        if not resuming:
            self._precheck_seat(access, ctx.tenant_id, "admin")
        params = {**self._location_params(ctx), **fields, "uid": user.uid, "signInId": user.email or fields["signInId"],
                  "createdBy": FIRST_ADMIN_CREATOR, "firstAdmin": True}
        try:
            self._apply_profile(OperationContext(op_id, ctx.tenant_id, params, {}))
            self._activate_records(access, user.uid, op_id)
        except (InviteProblem, CommandProblem) as error:
            raise self._failure(error) from error
        return {"state": "active", "path": "account", "uid": user.uid, "invitation": None}

    def _mail_invitation(
        self, ctx: TenantContext, email: str | None, created: Mapping[str, Any], actor: str,
        *, mail_key: str | None = None,
    ) -> None:
        if not email:
            return
        try:
            reference = self.platform.collection(INVITATIONS).document(created["invitationId"])
            stored = reference.get().to_dict() or {}
            if stored.get("status") != "open":
                return
            base = os.environ.get(INVITE_URL_ENV, "").strip()
            if not base.startswith("https://"):
                outcome = {"status": "skipped", "jobId": None,
                           "reason": f"{INVITE_URL_ENV} is not set to an https URL."}
            else:
                outcome = self.mail.enqueue_or_report(
                    ctx.tenant_id,
                    mail_key or f"invite-{created['invitationId']}",
                    "invitation",
                    email,
                    {"tenantId": ctx.tenant_id, "companyName": ctx.record["legalName"],
                     "inviteUrl": f"{base}#invite={created['qrPayload']}", "expiresAt": created["expiresAt"]},
                    actor,
                )
            if stored.get("mail") != outcome:
                reference.update({"mail": outcome})
        except Exception as error:
            log.error("invitation mail status failed: %s", type(error).__name__)

    @staticmethod
    def _in_progress() -> HTTPException:
        return HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This invitation is still being created. Try again in a moment.",
        )

    def _failure(self, error: Exception) -> HTTPException:
        return self._failure_text(type(error).__name__, str(error))

    @staticmethod
    def _failure_text(kind: Any, message: Any) -> HTTPException:
        return http_error(
            kind,
            message,
            "The invitation could not be created. Start again with a new Idempotency-Key.",
        )

    def _precheck(self, access: CompanyAccess, fields: Mapping[str, Any], tenant_id: str) -> None:
        self._precheck_seat(access, tenant_id, fields["role"])
        try:
            access.auth.get_user_by_email(fields["signInId"])
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="That sign-in email is already in use.",
            )
        except admin_auth.UserNotFoundError:
            pass
        code = fields["employeeCode"]
        refusal = self._code_refusal(access, code)
        if refusal:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=refusal)
        if fields["supervisorUid"]:
            try:
                snapshot = access.db.collection(ACCESS).document(fields["supervisorUid"]).get()
                _check_supervisor(snapshot, code)
            except InviteProblem as error:
                raise HTTPException(status_code=error.status_code, detail=str(error)) from error

    def _code_refusal(self, access: CompanyAccess, code: str) -> str | None:
        db = access.db
        reference = db.collection(CLAIMS).document(canonical_code(code))
        claim = reference.get()
        if claim.exists and self._claim_is_live(db, claim):
            return CODE_RETIRED if (claim.to_dict() or {}).get("retired") is True else CODE_IN_USE
        return CODE_IN_USE if self._code_on_record(db, code) else None

    @staticmethod
    def _code_on_record(db: firestore.Client, code: str) -> bool:
        wanted = canonical_code(code)
        variants = sorted({str(code or ""), str(code or "").strip(), wanted, wanted.lower(), *_case_spellings(wanted)})
        if any(db.collection(USERS).document(name).get().exists for name in variants if name and "/" not in name):
            return True
        for start in range(0, len(variants), IN_QUERY_LIMIT):
            batch = variants[start:start + IN_QUERY_LIMIT]
            for collection in (USERS, ACCESS):
                for field in CODE_FIELDS:
                    query = db.collection(collection).where(filter=firestore.FieldFilter(field, "in", batch)).limit(1)
                    if any(True for _ in query.stream()):
                        return True
        return False

    @staticmethod
    def _holds_code(snapshot: Any, wanted: str) -> bool:
        if not snapshot.exists:
            return False
        data = snapshot.to_dict() or {}
        stored = [data.get(field) for field in CODE_FIELDS]
        if snapshot.reference.parent.id == USERS:
            stored.append(snapshot.id)
        return wanted in {canonical_code(value) for value in stored}

    @staticmethod
    def _claim_is_live(db: firestore.Client, claim: Any, transaction: Any = None) -> bool:
        if (claim.to_dict() or {}).get("retired") is True:
            return True
        return any(
            InvitationService._holds_code(db.document(path).get(transaction=transaction), claim.id)
            for path in (claim.to_dict() or {}).get("sources") or []
        )

    def _precheck_seat(self, access: CompanyAccess, tenant_id: str, role: str) -> None:
        try:
            plan = self.plans.effective(tenant_id, self.clock())
            limits = plan["limits"]
            schema = plan.get("quotaSchemaVersion", 1)
            counts = usage_counts(access.db, quota_schema_version=schema)
            pool = self._known_pool(role)
            if schema == 1 and pool in ("admins", "branchManagers"):
                pool = "managers"
            limit = limits.get(pool)
            if pool and limit is not None and counts[pool] + 1 > limit:
                raise PlanLimit(limit_text(pool, limit))
        except PlanProblem as problem:
            raise plan_refusal(problem) from problem

    def _created_response(self, record: Mapping[str, Any]) -> dict[str, Any]:
        secret = self._secret()
        params = record["params"]
        code = derive_code(secret, record["operationId"])
        return {
            "invitationId": invitation_id_for(code),
            "uid": params["uid"],
            "signInId": params["signInId"],
            "code": format_code(code),
            "qrPayload": f"scoot-invite:1:{params['workspace']}:{code}",
            "expiresAt": format_timestamp(record["createdAt"] + INVITE_TTL),
            "checkKind": params["checkKind"],
        }

    def create_steps(self) -> list[Step]:
        return [
            Step("create_auth_user", self._apply_auth_user, self._check_auth_user),
            Step("write_profile", self._apply_profile, self._check_profile),
            Step("create_code", self._apply_code, self._check_code),
        ]

    def recovery_actions(self) -> dict[str, list[Step]]:
        actions = {
            ACTION_REVOKE_ACCOUNT: self.revoke_account_steps(),
            ACTION_REACTIVATE: self.reactivate_steps(),
            ACTION_ROLE: self.role_steps(),
            ACTION_REMOVE: self.remove_steps(),
            ACTION_MOVE: self.move_steps(),
            ACTION_CODE: self.code_steps(),
        }
        if self.secret is not None:
            actions[ACTION_CREATE] = self.create_steps()
        return actions

    def _apply_auth_user(self, ctx: OperationContext) -> dict[str, str]:
        params = ctx.params
        access = self._access(params)
        uid = params["uid"]
        try:
            access.auth.create_user(
                uid=uid,
                email=params["signInId"],
                display_name=params["displayName"],
                disabled=True,
            )
        except admin_auth.EmailAlreadyExistsError as error:
            raise InviteProblem("That sign-in email is already in use.") from error
        except admin_auth.UidAlreadyExistsError:
            if access.auth.get_user(uid).email != params["signInId"]:
                raise InviteProblem("That account ID is already in use.") from None
        access.auth.set_custom_user_claims(uid, {"inviteOp": ctx.operation_id})
        return {"uid": uid}

    def _check_auth_user(self, ctx: OperationContext) -> bool:
        try:
            user = self._access(ctx.params).auth.get_user(ctx.params["uid"])
        except admin_auth.UserNotFoundError:
            return False
        return (user.email or "").lower() == ctx.params["signInId"].lower()

    def _profile_documents(
        self, params: Mapping[str, Any], operation_id: str, supervisor: Mapping[str, Any] | None
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        role = params["role"]
        code = params["employeeCode"]
        email = params["signInId"]
        supervisor_code = supervisor["employeeCode"] if supervisor else ""
        supervisor_uid = supervisor["uid"] if supervisor else ""
        pending = {
            "status": "suspended",
            "isActive": False,
            "createdVia": "invitation",
            "invitationState": "pending",
            "invitationOp": operation_id,
            "seatClass": seat_class_for_role(role),
            "seatHeld": True,
        }
        profile = {
            "uid": params["uid"],
            "userId": code,
            "employeeCode": code,
            "name": params["displayName"],
            "email": email,
            "username": email.split("@")[0],
            "role": role,
            "user_group": role,
            "branchId": params["branchId"],
            "branch_id": params["branchId"],
            "supervisorId": supervisor_code,
            "supervisor_id": supervisor_code,
            "contactNumber": params["phone"] or "",
            "contact_number": params["phone"] or "",
            "createdAt": firestore.SERVER_TIMESTAMP,
            "updatedAt": firestore.SERVER_TIMESTAMP,
            **pending,
        }
        if supervisor_uid:
            profile["supervisorUid"] = supervisor_uid
            profile["supervisor_uid"] = supervisor_uid
        index = {
            "accessVersion": 2,
            "uid": params["uid"],
            "userDocId": code,
            "employeeCode": code,
            "userId": code,
            "email": email,
            "role": role,
            "user_group": role,
            "branchId": params["branchId"],
            "branch_id": params["branchId"],
            "supervisorId": supervisor_code,
            "supervisor_id": supervisor_code,
            "supervisorUid": supervisor_uid if role == "salesman" else "",
            "updatedAt": firestore.SERVER_TIMESTAMP,
            **pending,
        }
        if role == "supervisor":
            index["assignedSalesmanCodes"] = []
        return profile, index

    def _apply_profile(self, ctx: OperationContext) -> dict[str, str]:
        params = ctx.params
        db = self._access(params).db
        users = db.collection(USERS).document(params["employeeCode"])
        index_ref = db.collection(ACCESS).document(params["uid"])
        claim_ref = db.collection(CLAIMS).document(canonical_code(params["employeeCode"]))
        supervisor_uid = params.get("supervisorUid")
        supervisor_ref = db.collection(ACCESS).document(supervisor_uid) if supervisor_uid else None
        pool = self._known_pool(params["role"])
        effective = self.plans.effective(params["tenantId"], self.clock())
        limits = effective["limits"]

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            existing = users.get(transaction=transaction)
            if existing.exists and (existing.to_dict() or {}).get("invitationOp") != ctx.operation_id:
                raise InviteProblem("That employee code is already in use.")
            claim = claim_ref.get(transaction=transaction)
            if (
                claim.exists
                and f"{ACCESS}/{params['uid']}" not in ((claim.to_dict() or {}).get("sources") or [])
                and self._claim_is_live(db, claim, transaction)
            ):
                raise InviteProblem(CODE_RETIRED if (claim.to_dict() or {}).get("retired") is True else CODE_IN_USE)
            usage = read_usage(transaction, db, required=True)
            earlier = index_ref.get(transaction=transaction).to_dict() or {}
            self._transaction_caller(transaction, db, params, earlier)
            if earlier:
                self._known_pool(earlier.get("role"))
                if earlier.get("invitationOp") != ctx.operation_id:
                    raise InviteProblem("That account is already in use.")
                if existing.exists:
                    return
            supervisor = None
            snapshot = supervisor_ref.get(transaction=transaction) if supervisor_ref is not None else None
            if snapshot is not None:
                supervisor = _check_supervisor(snapshot, params["employeeCode"], branch=params["branchId"])
            held = earlier.get("invitationOp") == ctx.operation_id and earlier.get("seatHeld") is True
            if earlier and not held:
                raise InviteProblem("This invitation no longer holds a seat. Invite the person again.")
            if pool and not held:
                check_plan_projection(transaction, db, effective, now=self.clock())
            move_counts(transaction, db, usage, {pool: 1} if pool and not held else {}, limits)
            profile, index = self._profile_documents(params, ctx.operation_id, supervisor)
            transaction.set(users, profile)
            transaction.set(index_ref, index)
            transaction.set(claim_ref, {"sources": [f"{ACCESS}/{params['uid']}"], "claimedAt": firestore.SERVER_TIMESTAMP})
            if supervisor is not None:
                self._roster(transaction, db, supervisor_ref, snapshot, params["employeeCode"], add=True)

        commit_when_free(write, db)
        return {"employeeCode": params["employeeCode"]}

    def _check_profile(self, ctx: OperationContext) -> bool:
        params = ctx.params
        db = self._access(params).db
        profile = db.collection(USERS).document(params["employeeCode"]).get()
        index = db.collection(ACCESS).document(params["uid"]).get()
        if index.exists:
            self._known_pool((index.to_dict() or {}).get("role"))
        return (
            profile.exists
            and index.exists
            and (profile.to_dict() or {}).get("invitationOp") == ctx.operation_id
            and (index.to_dict() or {}).get("invitationOp") == ctx.operation_id
        )

    def _apply_code(self, ctx: OperationContext) -> dict[str, str]:
        secret = self._secret()
        params = ctx.params
        record = self.runner.get(ctx.operation_id) or {}
        created = record["createdAt"]
        code = derive_code(secret, ctx.operation_id)
        invitation_id = invitation_id_for(code)
        reference = self.platform.collection(INVITATIONS).document(invitation_id)
        document = {
            "invitationId": invitation_id,
            "operationId": ctx.operation_id,
            "tenantId": params["tenantId"],
            "workspace": params["workspace"],
            "projectId": params["projectId"],
            "databaseId": params["databaseId"],
            "authTenantId": params["authTenantId"],
            "uid": params["uid"],
            "displayName": params["displayName"],
            "signInId": params["signInId"],
            "role": params["role"],
            "checkKind": params["checkKind"],
            "checkHash": params["checkHash"],
            "failures": 0,
            "status": "open",
            "createdAt": created,
            "expiresAt": created + INVITE_TTL,
            "createdBy": params["createdBy"],
            "redeemedAt": None,
            "redeemedDevice": None,
            "redeemLeaseUntil": None,
        }
        try:
            reference.create(document)
        except gcloud_exceptions.AlreadyExists:
            if (reference.get().to_dict() or {}).get("operationId") != ctx.operation_id:
                raise InviteProblem("That invitation code is already in use.") from None
        return {"invitationId": invitation_id}

    def _check_code(self, ctx: OperationContext) -> bool:
        secret = self._secret()
        invitation_id = invitation_id_for(derive_code(secret, ctx.operation_id))
        snapshot = self.platform.collection(INVITATIONS).document(invitation_id).get()
        return snapshot.exists and (snapshot.to_dict() or {}).get("operationId") == ctx.operation_id

    def _after_failure(self, op_id: str) -> None:
        try:
            record = self.runner.get(op_id) or {}
            if record.get("status") == FAILED and record.get("action") == ACTION_CREATE:
                self.discard_provisional(op_id, record["params"])
                self.runner.annotate(op_id, {"cleanedUp": True})
        except Exception as error:
            log.error("invitation cleanup failed: %s", type(error).__name__)

    def sweep_failed(self) -> list[str]:
        cleaned: list[str] = []
        for record in self.runner.list_by_status(ACTION_CREATE, FAILED):
            if record.get("cleanedUp"):
                continue
            try:
                self.discard_provisional(record["operationId"], record["params"])
                self.runner.annotate(record["operationId"], {"cleanedUp": True})
                cleaned.append(record["operationId"])
            except Exception as error:
                log.error("invitation cleanup failed: %s", type(error).__name__)
        return cleaned

    def discard_provisional(self, op_id: str, params: Mapping[str, Any]) -> None:
        access = self._access(params)
        uid = params["uid"]
        if uid != derive_uid(op_id):
            return
        try:
            user = access.auth.get_user(uid)
        except admin_auth.UserNotFoundError:
            user = None
        if user is not None and user.disabled:
            claims = user.custom_claims or {}
            if claims.get("inviteOp") == op_id or not claims:
                access.auth.delete_user(uid)
        db = access.db
        users = db.collection(USERS).document(params["employeeCode"])
        index_ref = db.collection(ACCESS).document(uid)

        @firestore.transactional
        def remove(transaction: firestore.Transaction) -> None:
            profile = users.get(transaction=transaction)
            index = index_ref.get(transaction=transaction)
            indexed_supervisor = str((index.to_dict() or {}).get("supervisorUid") or "") if index.exists else ""
            supervisor_uid = indexed_supervisor or params.get("supervisorUid")
            supervisor_ref = db.collection(ACCESS).document(supervisor_uid) if supervisor_uid else None
            supervisor = supervisor_ref.get(transaction=transaction) if supervisor_ref else None
            supervisor_profile = self._profile_codes(transaction, db, supervisor)
            usage = read_usage(transaction, db, required=False)
            def is_mine(snapshot: Any) -> bool:
                data = snapshot.to_dict() or {}
                return (snapshot.exists and data.get("invitationOp") == op_id
                        and data.get("invitationState") in ("pending", "expired"))

            if not (is_mine(profile) or is_mine(index)):
                return
            if is_mine(index):
                data = index.to_dict() or {}
                pool = self._known_pool(data.get("role"))
                move_counts(transaction, db, usage,
                            {pool: -1} if pool and data.get("seatHeld") is True else {}, None)
            if is_mine(profile):
                transaction.delete(users)
            if is_mine(index):
                transaction.delete(index_ref)
            if supervisor is not None and supervisor.exists:
                self._roster(transaction, db, supervisor_ref, supervisor, params["employeeCode"], add=False,
                             profile_codes=supervisor_profile)

        commit_when_free(remove, db)

    def release_stale_seats(self, record: Mapping[str, Any]) -> int:
        now = self.clock()
        access = self.access_for(record["location"])
        query = (
            self.platform.collection(INVITATIONS)
            .where(filter=firestore.FieldFilter("tenantId", "==", record["tenantId"]))
            .where(filter=firestore.FieldFilter("status", "in", ["open", "redeeming", "locked"]))
        )
        released = 0
        for snapshot in query.stream():
            row = snapshot.to_dict() or {}
            expires = _as_time(row.get("expiresAt"))
            lease = _as_time(row.get("redeemLeaseUntil"))
            stale = row.get("status") == "locked" or (
                expires is not None
                and expires <= now
                and (
                    row.get("status") == "open"
                    or (row.get("status") == "redeeming" and (lease is None or lease <= now))
                )
            )
            if stale and self._release_seat(access, row["uid"], row["operationId"], snapshot.reference,
                                            expire_record=row.get("status") != "locked"):
                released += 1
        return released

    def _release_seat(self, access: CompanyAccess, uid: str, op_id: str, invitation_ref: Any,
                      expire_record: bool = True) -> bool:
        db = access.db
        index_ref = db.collection(ACCESS).document(uid)

        @firestore.transactional
        def release(transaction: firestore.Transaction) -> tuple[bool, bool]:
            index = index_ref.get(transaction=transaction)
            usage = read_usage(transaction, db, required=False)
            data = index.to_dict() or {}
            if not (
                index.exists
                and data.get("invitationState") == "pending"
                and data.get("invitationOp") == op_id
            ):
                return False, False
            seat_held = data.get("seatHeld") is True
            pool = self._known_pool(data.get("role"))
            if seat_held:
                move_counts(transaction, db, usage, {pool: -1} if pool else {}, None)
            change = {"seatHeld": False, "invitationState": "expired", "updatedAt": firestore.SERVER_TIMESTAMP}
            transaction.update(index_ref, change)
            if data.get("userDocId"):
                transaction.set(db.collection(USERS).document(data["userDocId"]), change, merge=True)
            return True, seat_held

        expired, released = commit_when_free(release, db)
        held = (index_ref.get().to_dict() or {}) if not expired else {}
        if expire_record and (expired or (held.get("invitationState") == "expired"
                                          and held.get("invitationOp") == op_id)):
            self._expire_invitation(invitation_ref)
        return released

    def _expire_invitation(self, reference: Any) -> None:
        @firestore.transactional
        def expire(transaction: firestore.Transaction) -> None:
            data = reference.get(transaction=transaction).to_dict() or {}
            if data.get("status") in ("open", "redeeming", "locked"):
                transaction.update(reference, {"status": "expired", "redeemLeaseUntil": None})

        _run_transaction(expire, self.platform.transaction())

    def list_invitations(self, ctx: TenantContext) -> dict[str, Any]:
        access = self.access_for(ctx.record["location"])
        self.require_admin(access, ctx.uid)
        now = self.clock()
        query = self.platform.collection(INVITATIONS).where(
            filter=firestore.FieldFilter("tenantId", "==", ctx.tenant_id)
        )
        rows = [snapshot.to_dict() or {} for snapshot in query.stream()]
        rows.sort(key=lambda row: row.get("createdAt") or now, reverse=True)
        items = []
        for row in rows[:200]:
            state = row.get("status")
            expires = _as_time(row.get("expiresAt"))
            if state in ("open", "redeeming"):
                state = "expired" if state == "open" and expires and expires <= now else "open"
            items.append(
                {
                    "invitationId": row["invitationId"],
                    "uid": row["uid"],
                    "displayName": row["displayName"],
                    "signInId": row["signInId"],
                    "role": row["role"],
                    "status": state,
                    "expiresAt": _text_time(row.get("expiresAt")),
                    "createdAt": _text_time(row.get("createdAt")),
                    "createdBy": row.get("createdBy"),
                    "redeemedAt": _text_time(row.get("redeemedAt")),
                    "redeemedDevice": row.get("redeemedDevice"),
                    "failures": int(row.get("failures") or 0),
                }
            )
        return {"invitations": items}

    def revoke_invitation(self, ctx: TenantContext, invitation_id: str) -> dict[str, str]:
        access = self.access_for(ctx.record["location"])
        self.require_admin(access, ctx.uid)
        if not re.fullmatch(r"[0-9a-f]{32}", invitation_id):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown invitation.")
        reference = self.platform.collection(INVITATIONS).document(invitation_id)
        now = self.clock()

        @firestore.transactional
        def revoke(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            data = snapshot.to_dict() or {}
            if not snapshot.exists or data.get("tenantId") != ctx.tenant_id:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown invitation.")
            state = data.get("status")
            if state == "redeemed":
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="This invitation was already used. Revoke the account instead.",
                )
            lease = _as_time(data.get("redeemLeaseUntil"))
            if state == "redeeming" and lease and lease > now:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="This invitation is being used right now. Try again in a moment.",
                )
            if state != "revoked":
                transaction.update(
                    reference, {"status": "revoked", "revokedAt": now, "revokedBy": ctx.uid}
                )
            return data

        data = revoke(self.platform.transaction())
        record = self.runner.get(data["operationId"])
        if record and record.get("action") == ACTION_CREATE:
            self.discard_provisional(data["operationId"], record["params"])
        return {"status": "revoked"}

    def redeem(
        self,
        *,
        code: str,
        check: str,
        password: str,
        device: str,
        client_address: str,
        project_id: str | None = None,
        email_code: str | None = None,
    ) -> dict[str, str]:
        secret = self._secret()
        normalized = normalize_code(code)
        self._rate_limit(client_address, "redeem", normalized)
        if not is_valid_code(normalized):
            raise _bad("Enter the 12-character invitation code.")
        invitation_id = invitation_id_for(normalized)
        reference = self.platform.collection(INVITATIONS).document(invitation_id)
        now = self.clock()
        lease_until = now + REDEEM_LEASE

        @firestore.transactional
        def claim(transaction: firestore.Transaction) -> tuple[str, dict[str, Any]]:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                return "unknown", {}
            data = snapshot.to_dict() or {}
            state = data.get("status")
            lease = _as_time(data.get("redeemLeaseUntil"))
            expires = _as_time(data.get("expiresAt"))
            if state == "revoked":
                return "revoked", data
            if state == "expired":
                return "expired", data
            if state == "redeemed" or (state == "redeeming" and lease and lease > now):
                return "used", data
            if state in ("open", "locked", "redeeming") and (expires is None or expires <= now):
                return "expired", data
            failures = int(data.get("failures") or 0)
            if state == "locked" or failures >= MAX_FAILURES:
                return "locked", data
            given = check_hash(
                secret, invitation_id, normalize_check(data["checkKind"], check)
            )
            if not hmac.compare_digest(given, str(data.get("checkHash"))):
                failures += 1
                update: dict[str, Any] = {"failures": failures}
                if failures >= MAX_FAILURES:
                    update["status"] = "locked"
                    update["lockedAt"] = now
                transaction.update(reference, update)
                return ("locked" if failures >= MAX_FAILURES else "wrong"), data
            if project_id and project_id != data.get("projectId"):
                return "other_project", data
            if needs_email_code(data):
                typed = re.sub(r"\s", "", str(email_code or ""))
                stored = data.get("emailCodeHash")
                if not typed or not stored:
                    return "email_code_needed", data
                wrong = int(data.get("emailCodeFailures") or 0)
                code_expires = _as_time(data.get("emailCodeExpiresAt"))
                if code_expires is None or code_expires <= now:
                    return "email_code_expired", data
                if wrong >= EMAIL_CODE_MAX_WRONG:
                    return "email_code_locked", data
                if not hmac.compare_digest(email_code_hash(secret, invitation_id, typed), str(stored)):
                    wrong += 1
                    email_update: dict[str, Any] = {"emailCodeFailures": wrong}
                    if wrong >= EMAIL_CODE_MAX_WRONG:
                        email_update["emailCodeHash"] = None
                    transaction.update(reference, email_update)
                    return ("email_code_locked" if wrong >= EMAIL_CODE_MAX_WRONG else "email_code_wrong"), data
            transaction.update(
                reference, {"status": "redeeming", "redeemLeaseUntil": lease_until}
            )
            return "ok", data

        outcome, data = _run_transaction(claim, self.platform.transaction())
        if outcome in ("unknown", "wrong"):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=MSG_INVALID)
        if outcome == "other_project":
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=MSG_OTHER_PROJECT)
        if outcome == "revoked":
            raise _gone(MSG_REVOKED)
        if outcome == "used":
            raise _gone(MSG_USED)
        if outcome == "expired":
            raise _gone(MSG_EXPIRED)
        if outcome == "locked":
            raise HTTPException(status_code=status.HTTP_423_LOCKED, detail=MSG_LOCKED)
        if outcome == "email_code_needed":
            raise _bad(MSG_EMAIL_CODE_NEEDED)
        if outcome == "email_code_wrong":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=MSG_EMAIL_CODE_WRONG)
        if outcome == "email_code_expired":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=MSG_EMAIL_CODE_EXPIRED)
        if outcome == "email_code_locked":
            raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=MSG_EMAIL_CODE_LOCKED)

        try:
            return self._finish_redeem(reference, data, password, device)
        except HTTPException:
            self._release(reference, lease_until)
            raise
        except (ValueError, firebase_exceptions.InvalidArgumentError) as error:
            self._release(reference, lease_until)
            raise _bad("That password is not accepted. Choose another.") from error
        except Exception as error:
            self._release(reference, lease_until)
            log.error("redeem failed: %s", type(error).__name__)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Sign-up could not be finished. Try again.",
            ) from error

    def request_email_code(self, *, code: str, check: str, client_address: str) -> dict[str, Any]:
        secret = self._secret()
        normalized = normalize_code(code)
        self._rate_limit(client_address, "emailcode", normalized)
        if not is_valid_code(normalized):
            raise _bad("Enter the 12-character invitation code.")
        invitation_id = invitation_id_for(normalized)
        reference = self.platform.collection(INVITATIONS).document(invitation_id)
        now = self.clock()
        digits = f"{secrets.randbelow(10 ** 6):06d}"

        @firestore.transactional
        def issue(transaction: firestore.Transaction) -> tuple[str, dict[str, Any]]:
            snapshot = reference.get(transaction=transaction)
            if not snapshot.exists:
                return "unknown", {}
            data = snapshot.to_dict() or {}
            state = data.get("status")
            expires = _as_time(data.get("expiresAt"))
            if state == "revoked":
                return "revoked", data
            if state == "expired":
                return "expired", data
            if state == "redeemed":
                return "used", data
            if expires is None or expires <= now:
                return "expired", data
            failures = int(data.get("failures") or 0)
            if state == "locked" or failures >= MAX_FAILURES:
                return "locked", data
            given = check_hash(secret, invitation_id, normalize_check(data["checkKind"], check))
            if not hmac.compare_digest(given, str(data.get("checkHash"))):
                failures += 1
                update: dict[str, Any] = {"failures": failures}
                if failures >= MAX_FAILURES:
                    update["status"] = "locked"
                    update["lockedAt"] = now
                transaction.update(reference, update)
                return ("locked" if failures >= MAX_FAILURES else "wrong"), data
            if not needs_email_code(data):
                return "not_needed", data
            sends = int(data.get("emailCodeSends") or 0)
            if sends >= EMAIL_CODE_MAX_SENDS:
                return "sends", data
            issued = email_code_hash(secret, invitation_id, digits)
            transaction.update(reference, {
                "emailCodeHash": issued,
                "emailCodeExpiresAt": now + timedelta(minutes=EMAIL_CODE_MINUTES),
                "emailCodeFailures": 0,
                "emailCodeSends": sends + 1,
            })
            return "ok", {**data, "issuedHash": issued}

        outcome, data = _run_transaction(issue, self.platform.transaction())
        if outcome in ("unknown", "wrong"):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=MSG_INVALID)
        if outcome == "revoked":
            raise _gone(MSG_REVOKED)
        if outcome == "used":
            raise _gone(MSG_USED)
        if outcome == "expired":
            raise _gone(MSG_EXPIRED)
        if outcome == "locked":
            raise HTTPException(status_code=status.HTTP_423_LOCKED, detail=MSG_LOCKED)
        if outcome == "sends":
            raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=MSG_EMAIL_CODE_SENDS)
        if outcome == "not_needed":
            return {"required": False}
        sent = self.mail.send_now(
            data["tenantId"], f"invite-email-code-{invitation_id[:24]}-{secrets.token_hex(6)}", "invitation_email_code",
            data["signInId"], {"tenantId": data["tenantId"], "code": digits, "minutes": EMAIL_CODE_MINUTES},
            "invitation-redeem", build_transport())
        if sent["status"] not in ("sent", "queued"):
            self._restore_email_code(reference, data)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The email code could not be sent. Try again later.")
        return {"required": True, "sentTo": mask(data["signInId"]), "expiresInSeconds": EMAIL_CODE_MINUTES * 60}

    def _restore_email_code(self, reference: Any, before: Mapping[str, Any]) -> None:
        @firestore.transactional
        def restore(transaction: firestore.Transaction) -> None:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current.get("emailCodeHash") != before["issuedHash"]:
                return
            transaction.update(reference, {
                "emailCodeHash": before.get("emailCodeHash"),
                "emailCodeExpiresAt": before.get("emailCodeExpiresAt"),
                "emailCodeFailures": int(before.get("emailCodeFailures") or 0),
                "emailCodeSends": int(before.get("emailCodeSends") or 0),
            })

        try:
            restore(self.platform.transaction())
        except Exception as error:
            log.error("email code restore failed: %s", type(error).__name__)

    def _release(self, reference: Any, lease_until: datetime) -> None:

        @firestore.transactional
        def release(transaction: firestore.Transaction) -> None:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current.get("status") == "redeeming" and _as_time(current.get("redeemLeaseUntil")) == lease_until:
                transaction.update(reference, {"status": "open", "redeemLeaseUntil": None})

        try:
            _run_transaction(release, self.platform.transaction())
        except Exception as error:
            log.error("redeem release failed: %s", type(error).__name__)

    def _code_company(self, normalized: str) -> str | None:
        if not is_valid_code(normalized):
            return None
        data = self.platform.collection(INVITATIONS).document(invitation_id_for(normalized)).get().to_dict() or {}
        tenant_id = data.get("tenantId")
        return tenant_id if isinstance(tenant_id, str) and tenant_id else None

    def _rate_limit(self, client_address: str, prefix: str, normalized_code: str) -> None:
        now = self.clock()
        limit = config.REDEEM_LIMIT_PER_HOUR
        company = self._code_company(normalized_code)
        if company is None:
            admitted = (self._admit(prefix, client_address, 3 * limit, now)
                        and self._admit(f"{prefix}co", f"-\n{client_address}", limit, now))
        else:
            admitted = (self._admit(f"{prefix}co", f"{company}\n{client_address}", limit, now)
                        and self._admit(prefix, client_address, 3 * limit, now))
        if not admitted:
            raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=MSG_RATE,
                                headers={"Retry-After": str(3600 - now.minute * 60 - now.second)})

    def _admit(self, prefix: str, key: str, limit: int, now: datetime) -> bool:
        digest = hashlib.sha256(key.encode()).hexdigest()[:32]
        reference = self.platform.collection(RATE_LIMITS).document(
            f"{prefix}_{digest}_{now.strftime('%Y%m%d%H')}"
        )

        @firestore.transactional
        def count(transaction: firestore.Transaction) -> bool:
            snapshot = reference.get(transaction=transaction)
            attempts = int((snapshot.to_dict() or {}).get("count") or 0)
            if attempts >= limit:
                return False
            transaction.set(
                reference,
                {"count": attempts + 1, "expiresAt": now + timedelta(hours=2)},
            )
            return True

        return bool(_run_transaction(count, self.platform.transaction()))

    def _finish_redeem(
        self, reference: Any, data: Mapping[str, Any], password: str, device: str
    ) -> dict[str, str]:
        try:
            record = self.directory.get(data["tenantId"])
        except DirectoryError as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The company directory could not be verified.",
            ) from error
        if record is None or not company_serves(self.directory, record):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=MSG_INVALID)
        access = self.access_for(record["location"])
        uid = data["uid"]
        self._require_unexpired(reference)
        self._require_creator(reference, data, access)
        self._activate_records(access, uid, data["operationId"], validate_only=True)
        access.auth.update_user(uid, password=password, email_verified=needs_email_code(data))
        try:
            access.auth.set_custom_user_claims(uid, None)
            self._activate_records(access, uid, data["operationId"])
            if TenantLifecycle(access).reconcile_auth(uid):
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="This company is not active. Ask your administrator.",
                )
        except Exception:
            access.auth.update_user(uid, disabled=True)
            raise
        token = access.auth.create_custom_token(uid)
        redeemed_device = _CONTROL.sub("", device).strip()[:80]

        @firestore.transactional
        def finish(transaction: firestore.Transaction) -> bool:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current.get("status") != "redeeming":
                return False
            expires = _as_time(current.get("expiresAt"))
            if expires is None or expires <= self.clock():
                return None
            transaction.update(
                reference,
                {
                    "status": "redeemed",
                    "redeemedAt": self.clock(),
                    "redeemedDevice": redeemed_device or None,
                    "redeemLeaseUntil": None,
                    "emailCodeHash": None,
                },
            )
            return True

        finished = _run_transaction(finish, self.platform.transaction())
        if not finished:
            access.auth.update_user(uid, disabled=True)
            raise _gone(MSG_REVOKED if finished is False else MSG_EXPIRED)
        return {
            "customToken": token.decode() if isinstance(token, bytes) else token,
            "workspace": record["workspace"],
            "projectId": record["location"]["projectId"],
            "signInId": data["signInId"],
        }

    def _require_unexpired(self, reference: Any) -> None:
        expires = _as_time((reference.get().to_dict() or {}).get("expiresAt"))
        if expires is None or expires <= self.clock():
            raise _gone(MSG_EXPIRED)

    def _platform_created(self, data: Mapping[str, Any]) -> bool:
        record = self.runner.get(data["operationId"]) if data.get("operationId") else None
        return record is not None and record.get("actor") != data.get("createdBy")

    def _require_creator(self, reference: Any, data: Mapping[str, Any], access: CompanyAccess) -> None:
        if self._platform_created(data):
            return
        creator = data.get("createdBy")
        if not creator:
            return
        row = access.db.collection(ACCESS).document(creator).get().to_dict() if isinstance(creator, str) and creator else None
        if (row and active_admin_row(row, creator) and row.get("isActive") is not False
                and row.get("invitationState") != "pending"):
            return
        self._close_invitation(reference, "creator-check")
        raise _gone(MSG_CREATOR_GONE)

    def _close_invitation(self, reference: Any, closed_by: str) -> None:
        now = self.clock()

        @firestore.transactional
        def close(transaction: firestore.Transaction) -> dict[str, Any] | None:
            data = reference.get(transaction=transaction).to_dict() or {}
            if data.get("status") not in ("open", "locked", "redeeming"):
                return None
            transaction.update(reference, {"status": "revoked", "revokedAt": now, "revokedBy": closed_by,
                                           "redeemLeaseUntil": None})
            return data

        data = _run_transaction(close, self.platform.transaction())
        record = self.runner.get(data["operationId"]) if data and data.get("operationId") else None
        if record and record.get("action") == ACTION_CREATE:
            self.discard_provisional(data["operationId"], record["params"])

    def _open_created_invitations(self, params: Mapping[str, Any]) -> list[Any]:
        query = self.platform.collection(INVITATIONS).where(
            filter=firestore.FieldFilter("createdBy", "==", params["uid"])
        )
        return [
            snapshot
            for snapshot in query.stream()
            if (snapshot.to_dict() or {}).get("tenantId") == params["tenantId"]
            and (snapshot.to_dict() or {}).get("status") in ("open", "locked", "redeeming")
            and not self._platform_created(snapshot.to_dict() or {})
        ]

    def _activate_records(
        self, access: CompanyAccess, uid: str, op_id: str, *, validate_only: bool = False,
    ) -> None:
        db = access.db
        index_ref = db.collection(ACCESS).document(uid)

        @firestore.transactional
        def activate(transaction: firestore.Transaction) -> None:
            index = index_ref.get(transaction=transaction)
            usage = read_usage(transaction, db, required=True)
            data = index.to_dict() or {}
            if (
                not index.exists
                or data.get("invitationOp") != op_id
                or data.get("invitationState") not in ("pending", "redeemed")
            ):
                raise _gone(MSG_REVOKED)
            self._known_pool(data.get("role"))
            if data.get("seatHeld") is not True or (
                data.get("invitationState") == "redeemed" and data.get("status") != "active"
            ):
                raise _gone(MSG_REVOKED)
            if validate_only:
                move_counts(transaction, db, usage, {}, None)
                return
            admin_delta = int(data.get("role") == "admin" and not active_admin(data))
            move_counts(transaction, db, usage, {}, None, active_admin_delta=admin_delta)
            change = {
                "status": "active",
                "isActive": True,
                "invitationState": "redeemed",
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
            transaction.update(index_ref, change)
            profile_id = data.get("userDocId")
            if profile_id:
                transaction.set(db.collection(USERS).document(profile_id), change, merge=True)

        activate(db.transaction())

    def revoke_account(
        self, ctx: TenantContext, uid: str, idempotency_key: str | None
    ) -> dict[str, str]:
        access = self.access_for(ctx.record["location"])
        caller = self.require_admin(access, ctx.uid)
        if not _UID.fullmatch(uid):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account.")
        if uid == ctx.uid:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="You cannot revoke your own account."
            )
        self._guard_developer(access, caller, uid)
        known = access.db.collection(ACCESS).document(uid).get().exists
        if not known:
            try:
                access.auth.get_user(uid)
            except admin_auth.UserNotFoundError:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account."
                ) from None
        key = f"{ctx.workspace}:{idempotency_key or uuid.uuid4().hex}"
        params = {**self._location_params(ctx), "uid": uid, "revokedBy": ctx.uid}
        steps = self.revoke_account_steps()
        try:
            op_id = self.runner.begin(
                idempotency_key=key,
                action=ACTION_REVOKE_ACCOUNT,
                actor=ctx.uid,
                tenant_id=ctx.tenant_id,
                reason="Account revoked",
                ticket=None,
                field_names=sorted(params),
                params=params,
                step_names=[step.name for step in steps],
            )
        except OperationError as error:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This idempotency key was already used for a different request.",
            ) from error
        try:
            record = self.runner.run(op_id, steps)
        except LeaseLost as error:
            raise self._in_progress() from error
        except Exception as error:
            log.error("account revoke failed: %s", type(error).__name__)
            raise http_error(type(error).__name__, str(error),
                             "The account could not be revoked. Try again.") from error
        if record.get("status") != "completed":
            error = record.get("error") or {}
            raise http_error(error.get("type"), error.get("message"),
                             "The account could not be revoked. Try again.")
        return {"uid": uid, "status": "suspended"}

    def revoke_account_steps(self) -> list[Step]:
        def suspend_apply(ctx: OperationContext) -> dict[str, bool]:
            self._suspend_records(ctx.params)
            return {"suspended": True}

        def suspend_check(ctx: OperationContext) -> bool:
            db = self._access(ctx.params).db
            snapshot = db.collection(ACCESS).document(ctx.params["uid"]).get()
            if not snapshot.exists:
                return True
            data = snapshot.to_dict() or {}
            self._known_pool(data.get("role"))
            if (
                data.get("status") != "suspended"
                or data.get("isActive") is not False
                or data.get("seatHeld") is True
            ):
                return False
            profile_id = data.get("userDocId")
            if not profile_id:
                return True
            profile = db.collection(USERS).document(profile_id).get().to_dict() or {}
            return profile.get("status") == "suspended" and profile.get("isActive") is False

        return [Step("suspend_records", suspend_apply, suspend_check), *self._lockdown_steps()]

    def _lockdown_steps(self) -> list[Step]:
        def block_apply(ctx: OperationContext) -> dict[str, int]:
            count = 0
            for snapshot in self._open_invitations(ctx.params):
                snapshot.reference.update(
                    {"status": "revoked", "revokedAt": self.clock(), "revokedBy": ctx.params["revokedBy"]}
                )
                count += 1
            for snapshot in self._open_created_invitations(ctx.params):
                self._close_invitation(snapshot.reference, ctx.params["revokedBy"])
                count += 1
            return {"revoked": count}

        def block_check(ctx: OperationContext) -> bool:
            return not self._open_invitations(ctx.params) and not self._open_created_invitations(ctx.params)

        def disable_apply(ctx: OperationContext) -> dict[str, bool]:
            try:
                self._access(ctx.params).auth.update_user(ctx.params["uid"], disabled=True)
            except admin_auth.UserNotFoundError:
                pass
            return {"disabled": True}

        def disable_check(ctx: OperationContext) -> bool:
            try:
                return self._access(ctx.params).auth.get_user(ctx.params["uid"]).disabled
            except admin_auth.UserNotFoundError:
                return True

        def tokens_apply(ctx: OperationContext) -> dict[str, bool]:
            try:
                self._access(ctx.params).auth.revoke_refresh_tokens(ctx.params["uid"])
            except admin_auth.UserNotFoundError:
                pass
            return {"revoked": True}

        return [
            Step("block_invitations", block_apply, block_check),
            Step("disable_auth", disable_apply, disable_check),
            Step("revoke_tokens", tokens_apply, lambda ctx: False),
        ]

    def _open_invitations(self, params: Mapping[str, Any]) -> list[Any]:
        query = self.platform.collection(INVITATIONS).where(
            filter=firestore.FieldFilter("uid", "==", params["uid"])
        )
        return [
            snapshot
            for snapshot in query.stream()
            if (snapshot.to_dict() or {}).get("tenantId") == params["tenantId"]
            and (snapshot.to_dict() or {}).get("status") in ("open", "locked", "redeeming")
        ]

    def _suspend_records(self, params: Mapping[str, Any]) -> None:
        db = self._access(params).db
        index_ref = db.collection(ACCESS).document(params["uid"])

        @firestore.transactional
        def suspend(transaction: firestore.Transaction) -> None:
            index = index_ref.get(transaction=transaction)
            data = index.to_dict() or {}
            usage = read_usage(transaction, db, required=False)
            self._transaction_caller(transaction, db, params, data)
            if not index.exists:
                return
            pool = self._known_pool(data.get("role"))
            move_counts(transaction, db, usage,
                        {pool: -1} if pool and data.get("seatHeld") is True else {}, None,
                        active_admin_delta=-int(active_admin(data)))
            change: dict[str, Any] = {
                "status": "suspended",
                "isActive": False,
                "seatHeld": False,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
            if data.get("invitationState") == "pending":
                change["invitationState"] = "revoked"
            transaction.update(index_ref, change)
            if data.get("userDocId"):
                transaction.set(db.collection(USERS).document(data["userDocId"]), change, merge=True)

        commit_when_free(suspend, db)

    def _target(self, ctx: TenantContext, uid: str, *, own: str) -> CompanyAccess:
        access = self.access_for(ctx.record["location"])
        caller = self.require_admin(access, ctx.uid)
        if not _UID.fullmatch(uid):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account.")
        if uid == ctx.uid:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=own)
        self._guard_developer(access, caller, uid)
        return access

    @staticmethod
    def _guard_developer(access: CompanyAccess, caller: Mapping[str, Any], uid: str) -> None:
        target = access.db.collection(ACCESS).document(uid).get().to_dict() or {}
        if target.get("role") == "developer" and caller.get("role") != "developer":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Only a developer can change a developer account.",
            )

    def _command_params(self, ctx: TenantContext, uid: str, **more: Any) -> dict[str, Any]:
        return {**self._location_params(ctx), "uid": uid, "requestedBy": ctx.uid, **more}

    def reactivate_account(
        self, ctx: TenantContext, uid: str, idempotency_key: str
    ) -> dict[str, str]:
        access = self._target(ctx, uid, own="You cannot change your own account here.")
        if not access.db.collection(ACCESS).document(uid).get().exists:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account.")
        run_command(
            self.runner,
            key=f"{ctx.workspace}:{idempotency_key}",
            action=ACTION_REACTIVATE,
            actor=ctx.uid,
            tenant_id=ctx.tenant_id,
            reason="Account reactivated",
            params=self._command_params(ctx, uid),
            steps=self.reactivate_steps(),
            fallback="The account could not be reactivated. Try again.",
        )
        return {"uid": uid, "status": "active"}

    def reactivate_steps(self) -> list[Step]:
        def activate_apply(ctx: OperationContext) -> dict[str, bool]:
            self._activate_account(ctx.params)
            return {"active": True}

        def activate_check(ctx: OperationContext) -> bool:
            db = self._access(ctx.params).db
            data = db.collection(ACCESS).document(ctx.params["uid"]).get().to_dict() or {}
            if data:
                self._known_pool(data.get("role"))
            return (
                data.get("status") == "active"
                and data.get("isActive") is True
                and data.get("seatHeld") is True
            )

        def enable_apply(ctx: OperationContext) -> dict[str, bool]:
            access = self._access(ctx.params)
            try:
                access.auth.get_user(ctx.params["uid"])
                disabled = TenantLifecycle(access).reconcile_auth(ctx.params["uid"])
            except admin_auth.UserNotFoundError:
                raise CommandProblem("The sign-in account no longer exists.") from None
            except LifecycleConflict as error:
                raise CommandProblem(str(error)) from None
            if disabled:
                raise CommandProblem(
                    "This account stays disabled while the company is suspended, expired or cancelled."
                )
            return {"enabled": True}

        def enable_check(ctx: OperationContext) -> bool:
            try:
                return not self._access(ctx.params).auth.get_user(ctx.params["uid"]).disabled
            except admin_auth.UserNotFoundError:
                return False

        return [
            Step("activate_records", activate_apply, activate_check),
            Step("enable_auth", enable_apply, enable_check),
        ]

    def _activate_account(self, params: Mapping[str, Any]) -> None:
        db = self._access(params).db
        index_ref = db.collection(ACCESS).document(params["uid"])
        effective = self.plans.effective(params["tenantId"], self.clock())
        limits = effective["limits"]

        @firestore.transactional
        def activate(transaction: firestore.Transaction) -> None:
            index = index_ref.get(transaction=transaction)
            usage = read_usage(transaction, db, required=True)
            if not index.exists:
                raise CommandProblem("Unknown account.")
            data = index.to_dict() or {}
            self._transaction_caller(transaction, db, params, data)
            pool = self._known_pool(data.get("role"))
            if data.get("invitationState") in ("pending", "revoked", "expired"):
                raise CommandProblem("This person never accepted an invitation. Invite them again.")
            if pool and data.get("seatHeld") is not True:
                check_plan_projection(transaction, db, effective, now=self.clock())
            move_counts(transaction, db, usage,
                        {pool: 1} if pool and data.get("seatHeld") is not True else {}, limits,
                        active_admin_delta=int(data.get("role") == "admin" and not active_admin(data)))
            change = {
                "status": "active",
                "isActive": True,
                "seatHeld": True,
                "seatClass": seat_class_for_role(data.get("role")) or data.get("seatClass"),
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
            transaction.update(index_ref, change)
            if data.get("userDocId"):
                transaction.set(db.collection(USERS).document(data["userDocId"]), change, merge=True)

        commit_when_free(activate, db)

    def change_role(
        self, ctx: TenantContext, uid: str, idempotency_key: str, body: Mapping[str, Any]
    ) -> dict[str, str]:
        access = self._target(ctx, uid, own="You cannot change your own role.")
        role = body.get("role")
        if role not in ROLES:
            raise _bad("Choose a valid role.")
        branch = str(body.get("branchId") or "").strip()
        if not _BRANCH.fullmatch(branch) or (not branch and role != "admin"):
            raise _bad("Enter a valid branch.")
        supervisor = str(body.get("supervisorUid") or "").strip() or None
        if supervisor and not _UID.fullmatch(supervisor):
            raise _bad("Choose a valid supervisor.")
        if not access.db.collection(ACCESS).document(uid).get().exists:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account.")
        run_command(
            self.runner,
            key=f"{ctx.workspace}:{idempotency_key}",
            action=ACTION_ROLE,
            actor=ctx.uid,
            tenant_id=ctx.tenant_id,
            reason="Role changed",
            params=self._command_params(
                ctx, uid, role=role, branchId=branch,
                supervisorUid=supervisor if role == "salesman" else None,
            ),
            steps=self.role_steps(),
            fallback="The role could not be changed. Try again.",
        )
        return {"uid": uid, "role": role}

    def role_steps(self) -> list[Step]:
        def keeps_invitations(params: Mapping[str, Any]) -> bool:
            return params["role"] in ("admin", "developer")

        def apply(ctx: OperationContext) -> dict[str, bool]:
            self._apply_role(ctx.params)
            if not keeps_invitations(ctx.params):
                for snapshot in self._open_created_invitations(ctx.params):
                    self._close_invitation(snapshot.reference, ctx.params["requestedBy"])
            return {"changed": True}

        def check(ctx: OperationContext) -> bool:
            params = ctx.params
            db = self._access(params).db
            data = db.collection(ACCESS).document(params["uid"]).get().to_dict() or {}
            return (
                data.get("role") == params["role"]
                and data.get("branchId") == params["branchId"]
                and (data.get("supervisorUid") or None) == params["supervisorUid"]
                and (keeps_invitations(params) or not self._open_created_invitations(params))
            )

        return [Step("apply_role", apply, check)]

    def _apply_role(self, params: Mapping[str, Any]) -> None:
        db = self._access(params).db
        index_ref = db.collection(ACCESS).document(params["uid"])
        role, branch = params["role"], params["branchId"]
        new_supervisor = params.get("supervisorUid") or ""
        new_pool = self._known_pool(role)
        effective = self.plans.effective(params["tenantId"], self.clock())
        limits = effective["limits"]

        @firestore.transactional
        def change(transaction: firestore.Transaction) -> None:
            index = index_ref.get(transaction=transaction)
            if not index.exists:
                raise CommandProblem("Unknown account.")
            data = index.to_dict() or {}
            self._transaction_caller(transaction, db, params, data)
            expected = params.get("expectedRow")
            if expected is not None and dict(expected) != self._row_fingerprint(data):
                raise CommandProblem("This person's access changed after you looked. Look again.")
            old_role = data.get("role")
            old_pool = self._known_pool(old_role)
            code = str(data.get("employeeCode") or "")
            if old_role == "developer":
                raise CommandProblem("This account's role cannot be changed here.")
            orphans: dict[str, Any] = {}
            if old_role == "supervisor" and role != "supervisor":
                accesses = db.collection(ACCESS)
                for query in (
                    accesses.where(filter=firestore.FieldFilter("supervisorUid", "==", params["uid"])),
                    accesses.where(filter=firestore.FieldFilter("supervisorId", "==", code)) if code else None,
                ):
                    if query is not None:
                        for snapshot in transaction.get(query):
                            orphans[snapshot.id] = snapshot
            moves = data.get("seatHeld") is True and old_pool != new_pool
            usage = read_usage(transaction, db, required=moves)
            old_supervisor = str(data.get("supervisorUid") or "")
            old_ref = db.collection(ACCESS).document(old_supervisor) if old_supervisor else None
            old_snapshot = old_ref.get(transaction=transaction) if old_ref else None
            old_profile = self._profile_codes(transaction, db, old_snapshot)
            new_ref = db.collection(ACCESS).document(new_supervisor) if new_supervisor else None
            new_snapshot = new_ref.get(transaction=transaction) if new_ref else None
            sup = _check_supervisor(new_snapshot, code, branch=branch) if new_snapshot is not None else None

            deltas = {}
            if moves:
                if new_pool:
                    deltas[new_pool] = 1
                if old_pool:
                    deltas[old_pool] = -1
            admin_delta = int(active_admin({**data, "role": role})) - int(active_admin(data))
            if any(delta > 0 for delta in deltas.values()):
                check_plan_projection(transaction, db, effective, now=self.clock())
            move_counts(transaction, db, usage, deltas, limits, active_admin_delta=admin_delta)
            common = {
                "role": role,
                "user_group": role,
                "seatClass": seat_class_for_role(role),
                "branchId": branch,
                "branch_id": branch,
                "supervisorId": sup["employeeCode"] if sup else "",
                "supervisor_id": sup["employeeCode"] if sup else "",
                "supervisorUid": new_supervisor,
                "supervisor_uid": new_supervisor,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
            if role == "supervisor" and old_role != "supervisor":
                common["assignedSalesmanCodes"] = []
            if old_role == "supervisor" and role != "supervisor":
                common["assignedSalesmanCodes"] = firestore.DELETE_FIELD
            transaction.update(index_ref, common)
            unlinked = {
                "supervisorId": "", "supervisor_id": "", "supervisorUid": "", "supervisor_uid": "",
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
            for snapshot in orphans.values():
                transaction.update(snapshot.reference, unlinked)
                profile_id = (snapshot.to_dict() or {}).get("userDocId")
                if profile_id:
                    transaction.set(db.collection(USERS).document(profile_id), unlinked, merge=True)
            if data.get("userDocId"):
                transaction.set(db.collection(USERS).document(data["userDocId"]), common, merge=True)
            if old_snapshot is not None and old_snapshot.exists and old_supervisor != new_supervisor:
                self._roster(transaction, db, old_ref, old_snapshot, code, add=False, profile_codes=old_profile)
            if sup is not None and old_supervisor != new_supervisor:
                self._roster(transaction, db, new_ref, new_snapshot, code, add=True)

        commit_when_free(change, db)

    @staticmethod
    def _profile_codes(transaction: firestore.Transaction, db: firestore.Client, snapshot: Any) -> list[str]:
        doc_id = (snapshot.to_dict() or {}).get("userDocId") if snapshot is not None and snapshot.exists else None
        if not doc_id:
            return []
        return _roster_codes(db.collection(USERS).document(doc_id).get(transaction=transaction).to_dict() or {})

    @staticmethod
    def _roster(
        transaction: firestore.Transaction,
        db: firestore.Client,
        reference: Any,
        snapshot: Any,
        code: str,
        *,
        add: bool,
        profile_codes: list[str] | None = None,
    ) -> None:
        data = snapshot.to_dict() or {}
        wanted = canonical_code(code)
        codes = [item for item in _roster_codes(data) if canonical_code(item) != wanted]
        if add and wanted:
            codes.append(code)
        transaction.update(
            reference, {"assignedSalesmanCodes": codes, "updatedAt": firestore.SERVER_TIMESTAMP}
        )
        if data.get("userDocId") and wanted:
            if add:
                change = firestore.ArrayUnion(codes)
            else:
                change = [item for item in profile_codes or [] if canonical_code(item) != wanted]
            transaction.set(
                db.collection(USERS).document(data["userDocId"]), {"assignedSalesmanCodes": change}, merge=True
            )

    def move_salesperson(
        self, ctx: TenantContext, uid: str, idempotency_key: str, body: Mapping[str, Any]
    ) -> dict[str, str]:
        access = self._target(ctx, uid, own="You cannot move your own account.")
        supervisor = str(body.get("supervisorUid") or "").strip()
        if not _UID.fullmatch(supervisor):
            raise _bad("Choose a valid supervisor.")
        if not access.db.collection(ACCESS).document(uid).get().exists:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account.")
        run_command(
            self.runner,
            key=f"{ctx.workspace}:{idempotency_key}",
            action=ACTION_MOVE,
            actor=ctx.uid,
            tenant_id=ctx.tenant_id,
            reason="Salesperson moved to another supervisor",
            params=self._command_params(ctx, uid, supervisorUid=supervisor),
            steps=self.move_steps(),
            fallback="The salesperson could not be moved. Try again.",
        )
        return {"uid": uid, "supervisorUid": supervisor}

    def move_steps(self) -> list[Step]:
        def apply(ctx: OperationContext) -> dict[str, Any]:
            return self._apply_move(ctx.params)

        def check(ctx: OperationContext) -> bool:
            db = self._access(ctx.params).db
            data = db.collection(ACCESS).document(ctx.params["uid"]).get().to_dict() or {}
            target = ctx.params["supervisorUid"]
            if data.get("supervisorUid") != target:
                return False
            roster = _roster_codes(db.collection(ACCESS).document(target).get().to_dict() or {})
            return canonical_code(data.get("employeeCode")) in {canonical_code(code) for code in roster}

        return [Step("move_salesperson", apply, check)]

    def _apply_move(self, params: Mapping[str, Any]) -> dict[str, Any]:
        db = self._access(params).db
        index_ref = db.collection(ACCESS).document(params["uid"])
        target = params["supervisorUid"]
        target_ref = db.collection(ACCESS).document(target)
        supervisors = db.collection(ACCESS).where(filter=firestore.FieldFilter("role", "==", "supervisor"))

        @firestore.transactional
        def move(transaction: firestore.Transaction) -> dict[str, Any]:
            index = index_ref.get(transaction=transaction)
            if not index.exists:
                raise CommandProblem("Unknown account.")
            data = index.to_dict() or {}
            self._transaction_caller(transaction, db, params, data)
            if data.get("role") != "salesman":
                raise CommandProblem("Only a salesperson can be moved to another supervisor.")
            if data.get("invitationState") == "pending":
                raise CommandProblem("Accept the invitation first.")
            code = str(data.get("employeeCode") or "")
            if not canonical_code(code):
                raise CommandProblem("This salesperson has no employee code. Fix the account first.")
            target_snapshot = target_ref.get(transaction=transaction)
            holders = [
                snapshot for snapshot in transaction.get(supervisors)
                if snapshot.id != target
                and canonical_code(code) in {canonical_code(item) for item in _roster_codes(snapshot.to_dict() or {})}
            ]
            salesperson_branch = str(data.get("branchId") or "")
            if not canonical_code(salesperson_branch):
                raise CommandProblem("This salesperson has no branch. Set the branch first.")
            holder_profiles = {snapshot.id: self._profile_codes(transaction, db, snapshot) for snapshot in holders}
            sup = _check_supervisor(target_snapshot, code, branch=salesperson_branch)
            link = {
                "supervisorId": sup["employeeCode"],
                "supervisor_id": sup["employeeCode"],
                "supervisorUid": target,
                "supervisor_uid": target,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
            transaction.update(index_ref, link)
            if data.get("userDocId"):
                transaction.set(db.collection(USERS).document(data["userDocId"]), link, merge=True)
            for snapshot in holders:
                self._roster(transaction, db, snapshot.reference, snapshot, code, add=False,
                             profile_codes=holder_profiles[snapshot.id])
            self._roster(transaction, db, target_ref, target_snapshot, code, add=True)
            return {
                "employeeCode": code,
                "fromSupervisorUids": sorted(snapshot.id for snapshot in holders),
                "toSupervisorUid": target,
            }

        return commit_when_free(move, db)

    def change_employee_code(
        self, ctx: TenantContext, uid: str, idempotency_key: str, body: Mapping[str, Any]
    ) -> dict[str, str]:
        access = self._target(ctx, uid, own="You cannot change your own employee code.")
        code = str(body.get("employeeCode") or "").strip()
        if not _EMPLOYEE_CODE.fullmatch(code):
            raise _bad("Enter an employee code of 1 to 32 letters, digits, dots, dashes or underscores.")
        code = code.upper()
        current = access.db.collection(ACCESS).document(uid).get()
        if not current.exists:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account.")
        old_code = str((current.to_dict() or {}).get("employeeCode") or "")
        if canonical_code(old_code) != code:
            if person_has_history(access.db, uid, old_code):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"The employee code {old_code} cannot change. This person's orders, visits and routes "
                           "are filed under it, and a new code would hide them from their supervisor. Keep the "
                           "code. To use another one, remove this person and invite them again.")
            refusal = self._code_refusal(access, code)
            if refusal:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=refusal)
        run_command(
            self.runner,
            key=f"{ctx.workspace}:{idempotency_key}",
            action=ACTION_CODE,
            actor=ctx.uid,
            tenant_id=ctx.tenant_id,
            reason="Employee code changed",
            params=self._command_params(ctx, uid, employeeCode=code),
            steps=self.code_steps(),
            fallback="The employee code could not be changed. Try again.",
        )
        return {"uid": uid, "employeeCode": code}

    def code_steps(self) -> list[Step]:
        def apply(ctx: OperationContext) -> dict[str, bool]:
            self._apply_code_change(ctx.params)
            return {"changed": True}

        def check(ctx: OperationContext) -> bool:
            db = self._access(ctx.params).db
            data = db.collection(ACCESS).document(ctx.params["uid"]).get().to_dict() or {}
            return data.get("employeeCode") == ctx.params["employeeCode"]

        return [Step("apply_employee_code", apply, check)]

    def _apply_code_change(self, params: Mapping[str, Any]) -> None:
        db = self._access(params).db
        index_ref = db.collection(ACCESS).document(params["uid"])
        new_code = params["employeeCode"]
        new_canonical = canonical_code(new_code)
        new_claim_ref = db.collection(CLAIMS).document(new_canonical)
        fields = {field: new_code for field in CODE_FIELDS}
        fields["userId"] = new_code

        @firestore.transactional
        def change(transaction: firestore.Transaction) -> None:
            index = index_ref.get(transaction=transaction)
            if not index.exists:
                raise CommandProblem("Unknown account.")
            data = index.to_dict() or {}
            self._transaction_caller(transaction, db, params, data)
            if data.get("invitationState") == "pending":
                raise CommandProblem("Accept the invitation first.")
            old_code = str(data.get("employeeCode") or "")
            old_canonical = canonical_code(old_code)
            if old_code == new_code:
                return
            moved = old_canonical != new_canonical
            profile_id = str(data.get("userDocId") or "")
            if moved:
                claim = new_claim_ref.get(transaction=transaction)
                if (
                    claim.exists
                    and f"{ACCESS}/{params['uid']}" not in ((claim.to_dict() or {}).get("sources") or [])
                    and self._claim_is_live(db, claim, transaction)
                ):
                    raise CommandProblem(
                        CODE_RETIRED if (claim.to_dict() or {}).get("retired") is True else CODE_IN_USE)
                if profile_id != new_code and db.collection(USERS).document(new_code).get(transaction=transaction).exists:
                    raise CommandProblem("That employee code is already in use.")
            old_claim_ref = db.collection(CLAIMS).document(old_canonical) if old_canonical else None
            old_claim = old_claim_ref.get(transaction=transaction) if old_claim_ref is not None and moved else None
            profile_ref = db.collection(USERS).document(profile_id) if profile_id else None
            profile = profile_ref.get(transaction=transaction) if profile_ref is not None else None
            renames = bool(profile is not None and profile.exists and moved and profile_id == old_code)
            supervisor_uid = str(data.get("supervisorUid") or "")
            supervisor_ref = db.collection(ACCESS).document(supervisor_uid) if supervisor_uid else None
            supervisor = supervisor_ref.get(transaction=transaction) if supervisor_ref is not None else None
            reports: dict[str, Any] = {}
            if data.get("role") == "supervisor":
                accesses = db.collection(ACCESS)
                for query in (
                    accesses.where(filter=firestore.FieldFilter("supervisorUid", "==", params["uid"])),
                    accesses.where(filter=firestore.FieldFilter("supervisorId", "==", old_code)),
                ):
                    for snapshot in transaction.get(query):
                        reports[snapshot.id] = snapshot
            stamp = {"updatedAt": firestore.SERVER_TIMESTAMP}
            index_change = {**fields, **stamp}
            if renames:
                index_change["userDocId"] = new_code
            transaction.update(index_ref, index_change)
            if renames:
                transaction.set(
                    db.collection(USERS).document(new_code), {**(profile.to_dict() or {}), **fields, **stamp})
                transaction.delete(profile_ref)
            elif profile is not None and profile.exists:
                transaction.set(profile_ref, {**fields, **stamp}, merge=True)
            if moved:
                transaction.set(
                    new_claim_ref,
                    {"sources": [f"{ACCESS}/{params['uid']}"], "claimedAt": firestore.SERVER_TIMESTAMP},
                )
                if old_claim is not None and old_claim.exists:
                    transaction.delete(old_claim_ref)
            if supervisor is not None and supervisor.exists:
                swapped = [
                    new_code if canonical_code(item) == old_canonical else item
                    for item in _roster_codes(supervisor.to_dict() or {})
                ]
                transaction.update(supervisor_ref, {"assignedSalesmanCodes": swapped, **stamp})
                if (supervisor.to_dict() or {}).get("userDocId"):
                    transaction.set(
                        db.collection(USERS).document(supervisor.to_dict()["userDocId"]),
                        {"assignedSalesmanCodes": swapped}, merge=True)
            relink = {"supervisorId": new_code, "supervisor_id": new_code, **stamp}
            for snapshot in reports.values():
                transaction.update(snapshot.reference, relink)
                report_profile = (snapshot.to_dict() or {}).get("userDocId")
                if report_profile:
                    transaction.set(db.collection(USERS).document(report_profile), relink, merge=True)

        commit_when_free(change, db)

    def remove_account(
        self, ctx: TenantContext, uid: str, idempotency_key: str
    ) -> dict[str, str]:
        access = self._target(ctx, uid, own="You cannot remove your own account.")
        snapshot = access.db.collection(ACCESS).document(uid).get()
        if not snapshot.exists:
            try:
                access.auth.get_user(uid)
            except admin_auth.UserNotFoundError:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND, detail="Unknown account."
                ) from None
        elif (snapshot.to_dict() or {}).get("assignedSalesmanCodes"):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This supervisor still has salespeople. Move them to another supervisor first.",
            )
        run_command(
            self.runner,
            key=f"{ctx.workspace}:{idempotency_key}",
            action=ACTION_REMOVE,
            actor=ctx.uid,
            tenant_id=ctx.tenant_id,
            reason="Account removed",
            params={**self._command_params(ctx, uid), "revokedBy": ctx.uid},
            steps=self.remove_steps(),
            fallback="The account could not be removed. Try again.",
        )
        return {"uid": uid, "status": "removed"}

    def remove_steps(self) -> list[Step]:
        def remove_apply(ctx: OperationContext) -> dict[str, bool]:
            self._remove_records(ctx.params)
            return {"removed": True}

        def remove_check(ctx: OperationContext) -> bool:
            db = self._access(ctx.params).db
            uid = ctx.params["uid"]
            return (not db.collection(ACCESS).document(uid).get().exists
                    and not list(db.collection(USERS).where(filter=firestore.FieldFilter("uid", "==", uid)).limit(1).stream()))

        return [Step("remove_records", remove_apply, remove_check), *self._lockdown_steps()]

    @staticmethod
    def _profile_references(
        transaction: firestore.Transaction, db: firestore.Client, uid: str, access_row: Mapping[str, Any]
    ) -> list[Any]:
        users = db.collection(USERS)
        found: dict[str, Any] = {}
        linked = access_row.get("userDocId")
        wanted = [users.document(name) for name in {linked, access_row.get("employeeCode")} if name]
        for snapshot in [*(reference.get(transaction=transaction) for reference in wanted),
                         *transaction.get(users.where(filter=firestore.FieldFilter("uid", "==", uid)))]:
            if snapshot.exists and ((snapshot.to_dict() or {}).get("uid") == uid or snapshot.id == linked):
                found[snapshot.id] = snapshot.reference
        return list(found.values())

    def _remove_records(self, params: Mapping[str, Any]) -> None:
        db = self._access(params).db
        index_ref = db.collection(ACCESS).document(params["uid"])

        @firestore.transactional
        def remove(transaction: firestore.Transaction) -> None:
            index = index_ref.get(transaction=transaction)
            usage = read_usage(transaction, db, required=False)
            data = index.to_dict() or {}
            self._transaction_caller(transaction, db, params, data)
            profiles = self._profile_references(transaction, db, params["uid"], data)
            if not index.exists:
                for reference in profiles:
                    transaction.delete(reference)
                return
            pool = self._known_pool(data.get("role"))
            if data.get("assignedSalesmanCodes"):
                raise CommandProblem(
                    "This supervisor still has salespeople. Move them to another supervisor first."
                )
            supervisor_uid = str(data.get("supervisorUid") or "")
            supervisor_ref = db.collection(ACCESS).document(supervisor_uid) if supervisor_uid else None
            supervisor = supervisor_ref.get(transaction=transaction) if supervisor_ref else None
            supervisor_profile = self._profile_codes(transaction, db, supervisor)
            retain = person_has_history(db, params["uid"], str(data.get("employeeCode") or ""), transaction)
            move_counts(transaction, db, usage,
                        {pool: -1} if pool and data.get("seatHeld") is True else {}, None,
                        active_admin_delta=-int(active_admin(data)))
            transaction.delete(index_ref)
            for reference in profiles:
                transaction.delete(reference)
            if retain and canonical_code(data.get("employeeCode")):
                retire_code(transaction, db, params["uid"], data.get("employeeCode"))
            if supervisor is not None and supervisor.exists:
                self._roster(
                    transaction, db, supervisor_ref, supervisor,
                    str(data.get("employeeCode") or ""), add=False, profile_codes=supervisor_profile,
                )

        commit_when_free(remove, db)

    def reconcile(self, ctx: TenantContext) -> dict[str, Any]:
        access = self.access_for(ctx.record["location"])
        self.require_admin(access, ctx.uid)
        indexed: dict[str, str] = {}
        for snapshot in access.db.collection(ACCESS).stream():
            indexed[snapshot.id] = str((snapshot.to_dict() or {}).get("email") or "")
        auth_only = []
        seen: set[str] = set()
        for user in access.auth.list_users().iterate_all():
            seen.add(user.uid)
            if user.uid in indexed:
                continue
            created = user.user_metadata.creation_timestamp
            auth_only.append(
                {
                    "uid": user.uid,
                    "email": user.email,
                    "disabled": bool(user.disabled),
                    "createdAt": format_timestamp(
                        datetime.fromtimestamp(created / 1000, tz=timezone.utc)
                    )
                    if created
                    else None,
                }
            )
        profile_only = [
            {"uid": uid, "email": email} for uid, email in indexed.items() if uid not in seen
        ]
        return {"authOnly": auth_only, "profileOnly": profile_only}


def canonical_code(value: Any) -> str:
    return str(value or "").strip().upper()


def _case_spellings(canonical: str) -> list[str]:
    positions = [index for index, character in enumerate(canonical) if character.isalpha()]
    if len(positions) > MAX_CASE_LETTERS:
        return []
    spellings = []
    for mask in range(1 << len(positions)):
        letters = list(canonical)
        for bit, index in enumerate(positions):
            if mask >> bit & 1:
                letters[index] = letters[index].lower()
        spellings.append("".join(letters))
    return spellings


def _roster_codes(data: Mapping[str, Any]) -> list[str]:
    codes = data.get("assignedSalesmanCodes")
    return [str(code) for code in codes] if isinstance(codes, list) else []


def _check_supervisor(
    snapshot: Any, employee_code: str, *, branch: str | None = None
) -> dict[str, Any]:
    data = snapshot.to_dict() or {}
    if not (
        snapshot.exists and data.get("role") == "supervisor" and data.get("status") == "active"
    ):
        raise InviteProblem("The chosen supervisor is not an active supervisor of this company.")
    if branch is not None and canonical_code(data.get("branchId")) != canonical_code(branch):
        raise InviteProblem("That supervisor is in another branch. Choose a supervisor in the same branch.")
    codes = {canonical_code(code) for code in _roster_codes(data)} - {""}
    if canonical_code(employee_code) not in codes and len(codes) >= SUPERVISOR_CAP:
        raise InviteProblem("That supervisor already has 5 salespeople.")
    return {
        "uid": snapshot.id,
        "employeeCode": str(data.get("employeeCode") or ""),
        "userDocId": str(data.get("userDocId") or ""),
    }


def first_admin_state(access: CompanyAccess, email: str) -> dict[str, Any]:
    address = str(email or "").strip().lower()
    try:
        user = access.auth.get_user_by_email(address)
    except admin_auth.UserNotFoundError:
        return {"state": "missing", "uid": None,
                "line": f"{address} has no sign-in account yet. Give access to send an invitation."}
    row = access.db.collection(ACCESS).document(user.uid).get().to_dict() or {}
    if not row:
        return {"state": "missing", "uid": user.uid,
                "line": f"{address} has a sign-in account but no access in this company. Give access to link it."}
    role = row.get("role")
    if row.get("invitationState") == "pending":
        return {"state": "invited", "uid": user.uid,
                "line": f"The invitation to {address} is sent. Waiting for the person to accept."}
    if row.get("invitationState") == "expired":
        return {"state": "expired", "uid": user.uid, "line": f"The invitation to {address} expired. Resend it."}
    if role not in ("admin", "developer"):
        return {"state": "blocked", "uid": user.uid,
                "line": f"{address} already has access in this company as {ROLE_LABELS.get(role, role)}. "
                        "Make this person the Admin, or use another email."}
    if not (active_admin_row(row, user.uid) and row.get("isActive") is not False):
        return {"state": "blocked", "uid": user.uid,
                "line": f"The administrator access of {address} is switched off. Switch it on in People."}
    if user.disabled:
        return {"state": "blocked", "uid": user.uid,
                "line": f"The sign-in account of {address} is turned off in the company's Firebase project. "
                        "Turn it on there."}
    return {"state": "active", "uid": user.uid, "line": f"{address} can sign in as an Admin."}

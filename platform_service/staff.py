from __future__ import annotations

import hashlib
import hmac
import logging
import re
import secrets
from datetime import datetime, timedelta
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from firebase_admin import auth as admin_auth
from google.cloud import firestore

from . import auth, config
from .audit import EVENTS, AuditLog
from .company_access import platform_project_auth
from .ids import utc_now
from .mail import STAFF_MAIL_TENANT, MailQueue
from .signing import format_timestamp

STAFF = "staff"
SESSIONS = "staff_sessions"
BOOTSTRAP_MARKER = "staff_bootstrap"
CODES = "staff_login_codes"
BACKUPS = "staff_backup_codes"
TRUSTED = "staff_trusted_devices"
INVITE_ENDS = "staff_invite_ends"
TRUSTED_DEVICE_DAYS = 30
ACCEPT_LEASE_MINUTES = 10
INVITE_HOURS = 48
SESSION_HOURS = 12
MIN_PASSWORD = 12
MAX_PASSWORD = 128
PASSWORD_PROVIDER = "password"
ROLES = config.STAFF_ROLE_NAMES
_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]+$")
_NAME = re.compile(r"^[^\x00-\x1f\x7f]{1,80}$")
_STAFF_ID = re.compile(r"^stf_[0-9a-f]{24}$")
_TOKEN = re.compile(r"^(stf_[0-9a-f]{24})\.([A-Za-z0-9_-]{20,100})$")


def staff_id(email: str) -> str:
    return "stf_" + hashlib.sha256(email.strip().lower().encode("utf-8")).hexdigest()[:24]


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def keyed_digest(value: str) -> str:
    secret = config.STAFF_HASH_SECRET or ("emulator-only-staff-hash" if auth.emulator_mode() else "")
    if not secret:
        raise RuntimeError("PLATFORM_STAFF_HASH_SECRET is required outside emulator runs.")
    return hmac.new(secret.encode("utf-8"), value.encode("utf-8"), hashlib.sha256).hexdigest()


def clean_email(value: Any) -> str:
    if not isinstance(value, str) or len(value) > 254 or not _EMAIL.fullmatch(value.strip()):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Enter a valid work email.")
    return value.strip().lower()


def allowed_domain(email: str) -> bool:
    return (email.rsplit("@", 1)[1] in config.STAFF_DOMAINS
            or email in config.STAFF_EMAILS
            or (email in config.STAFF_BOOTSTRAP_OWNERS and auth.emulator_mode()))


def mask(email: str) -> str:
    name, domain = email.split("@", 1)
    return f"{name[:1]}***@{domain}"


_LOG = logging.getLogger(__name__)
INVITE_NOT_VALID = "This invitation is not valid. Ask the owner for a new one."
INVITE_REASONS = {
    "expired": "This invitation has expired. Ask the owner to send a new one.",
    "replaced": "A newer invitation was sent to this email. Use the link in the newest email.",
    "cancelled": "This invitation was cancelled. Ask the owner if you still need access.",
}
ACCOUNT_NOT_CREATED = ("Your account could not be created right now, and nothing was saved. "
                       "Try again in a few minutes. If it keeps failing, tell the person who invited you.")


def record_revision(data: Mapping[str, Any], revision: int) -> str:
    generation = data.get("generation")
    return f"{generation}-{revision}" if generation else str(revision)


def conflict(message: str) -> HTTPException:
    return HTTPException(status.HTTP_409_CONFLICT, message)


def view(data: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "staffId": staff_id(data["email"]), "email": data["email"], "name": data.get("name"),
        "role": data["role"], "status": data["status"], "invitedBy": data.get("invitedBy"),
        "createdAt": data.get("createdAt"), "lastSignInAt": data.get("lastSignInAt"),
        "inviteExpiresAt": data.get("inviteExpiresAt"),
    }


def active_accounts(db: firestore.Client, transaction: firestore.Transaction | None = None) -> dict[str, str]:
    accounts = {}
    query = db.collection(STAFF).where(filter=firestore.FieldFilter("status", "==", "active"))
    for snapshot in query.stream(transaction=transaction):
        data = snapshot.to_dict() or {}
        accounts[data["email"]] = data["role"]
    return accounts


def approvers(db: firestore.Client, transaction: firestore.Transaction | None = None) -> list[str]:
    return sorted(email for email, role in active_accounts(db, transaction).items() if role in ("owner", "operator"))


def solo_owner(db: firestore.Client, email: str, transaction: firestore.Transaction | None = None) -> bool:
    if not config.SOLO_OWNER:
        return False
    accounts = active_accounts(db, transaction)
    return sorted(name for name, role in accounts.items() if role in ("owner", "operator")) == [email] and accounts.get(email) == "owner"


def end_staff_sessions(db: firestore.Client, uid: str, moment: datetime, *, handle: str | None = None,
                       created_before: str | None = None) -> int:
    batch = db.batch()
    ended = 0
    now = format_timestamp(moment)
    for snapshot in db.collection(SESSIONS).where(filter=firestore.FieldFilter("uid", "==", uid)).stream():
        data = snapshot.to_dict() or {}
        if ((handle is None or snapshot.id == handle) and data.get("status") == "active"
                and (created_before is None or data.get("createdAt", "") <= created_before
                     or data.get("authTime", "") <= created_before)):
            batch.update(snapshot.reference, {"status": "ended", "endedAt": now})
            ended += 1
    if ended:
        batch.commit()
    if handle is None:
        forget_trusted_devices(db, uid, created_before=created_before)
    return ended


def forget_trusted_devices(db: firestore.Client, uid: str, *, created_before: str | None = None) -> int:
    batch = db.batch()
    forgotten = 0
    for snapshot in db.collection(TRUSTED).where(filter=firestore.FieldFilter("uid", "==", uid)).stream():
        data = snapshot.to_dict() or {}
        if (created_before is None or data.get("createdAt", "") <= created_before
                or data.get("authTime", "") <= created_before):
            batch.delete(snapshot.reference)
            forgotten += 1
    if forgotten:
        batch.commit()
    return forgotten


class StaffBook:
    def __init__(self, db: firestore.Client, audit: AuditLog, mail: MailQueue, *,
                 auth_client: Callable[[], admin_auth.Client] | None = None,
                 clock: Callable[[], datetime] = utc_now) -> None:
        self.db = db
        self.audit = audit
        self.mail = mail
        self.auth_client = auth_client or platform_project_auth
        self.clock = clock

    def reference(self, identifier: str) -> Any:
        return self.db.collection(STAFF).document(identifier)

    def get(self, email: str) -> dict[str, Any] | None:
        snapshot = self.reference(staff_id(email)).get()
        return snapshot.to_dict() if snapshot.exists else None

    def list_people(self) -> list[dict[str, Any]]:
        rows = [view(snapshot.to_dict() or {}) for snapshot in self.db.collection(STAFF).stream()]
        return sorted(rows, key=lambda row: row["email"])

    def active_accounts(self) -> dict[str, str]:
        return active_accounts(self.db)

    def active_owners(self) -> list[str]:
        return sorted(email for email, role in self.active_accounts().items() if role == "owner")

    def resolve(self, token: auth.StaffToken) -> dict[str, Any]:
        email = token.email.strip().lower()
        by_password = token.provider == PASSWORD_PROVIDER
        data = self.get(email) or (self._bootstrap(email, token.uid) if by_password else None)
        same_person = data is not None and (data.get("uid") == token.uid or (not data.get("uid") and by_password))
        if not same_person or data.get("status") != "active" or not allowed_domain(email):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "This account is not platform staff.")
        if data.get("role") == "owner":
            self._record_marker(email)
        return data

    def _record_marker(self, email: str) -> None:
        marker = self.db.collection(BOOTSTRAP_MARKER).document("owner")
        now = format_timestamp(self.clock())

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            if not marker.get(transaction=transaction).exists:
                transaction.create(marker, {"email": email, "createdAt": now})

        write(self.db.transaction(max_attempts=10))

    def _bootstrap(self, email: str, uid: str) -> dict[str, Any] | None:
        if email not in config.STAFF_BOOTSTRAP_OWNERS or not allowed_domain(email):
            return None
        reference = self.reference(staff_id(email))
        marker = self.db.collection(BOOTSTRAP_MARKER).document("owner")
        now = format_timestamp(self.clock())

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> tuple[dict[str, Any] | None, bool]:
            existing = reference.get(transaction=transaction)
            if existing.exists:
                return existing.to_dict() or {}, False
            owners = list(self.db.collection(STAFF).where(filter=firestore.FieldFilter("role", "==", "owner")).where(
                filter=firestore.FieldFilter("status", "==", "active")).get(transaction=transaction))
            recorded = marker.get(transaction=transaction).exists or bool(list(
                self.db.collection(EVENTS).where(filter=firestore.FieldFilter("action", "==", "staff.bootstrapped"))
                .limit(1).get(transaction=transaction)))
            if owners or recorded or list(self.db.collection(STAFF).limit(1).get(transaction=transaction)):
                return None, False
            staged = self.audit.stage(transaction, self.clock())
            data = {"email": email, "uid": uid, "name": email.split("@", 1)[0], "role": "owner",
                    "status": "active", "invitedBy": "bootstrap", "generation": secrets.token_hex(8),
                    "createdAt": now, "updatedAt": now}
            transaction.create(reference, data)
            transaction.create(marker, {"email": email, "createdAt": now})
            staged.add(actor=email, action="staff.bootstrapped", tenant_id=None, key=f"staff-bootstrap:{reference.id}",
                       summary="The first owner was created from the bootstrap list.", refs={"staffId": reference.id})
            return data, True

        data, created = write(self.db.transaction(max_attempts=10))
        if created:
            self.notify("bootstrapped", email, "the bootstrap list", f"bootstrap-{reference.id}", extra=(email,))
        return data

    def end_sessions(self, uid: str, *, handle: str | None = None) -> int:
        return end_staff_sessions(self.db, uid, self.clock(), handle=handle)

    def notify(self, event: str, person: str, actor: str, key: str, *, extra: tuple[str, ...] = (),
               owners_only: bool = False, minutes: int | None = None) -> None:
        recipients = (set(self.active_owners()) if owners_only else set(self.active_accounts())) | set(extra)
        if config.FINANCE_EMAIL:
            recipients.add(config.FINANCE_EMAIL.lower())
        at = format_timestamp(self.clock())
        for recipient in sorted(recipients):
            tag = digest(recipient)[:12]
            self.mail.enqueue_or_report(
                STAFF_MAIL_TENANT, f"sn-{key}-{tag}", "staff_notice", recipient,
                {"tenantId": STAFF_MAIL_TENANT, "event": event, "person": person, "actor": actor, "at": at,
                 **({"minutes": minutes} if minutes is not None else {})}, actor)

    def invite(self, actor: str, email: Any, name: Any, role: Any) -> dict[str, Any]:
        email = clean_email(email)
        if not isinstance(name, str) or not _NAME.fullmatch(name.strip()):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Enter a name of 1 to 80 characters.")
        if role not in ROLES:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Choose owner, operator, engineer or support.")
        if not allowed_domain(email):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Use a work email from an allowed company domain.")
        base = config.STAFF_URL.rstrip("/")
        if not base.startswith("https://"):
            raise conflict("PLATFORM_STAFF_URL must be set to the https address of the Control Centre.")
        identifier = staff_id(email)
        reference = self.reference(identifier)
        secret = secrets.token_urlsafe(32)
        moment = self.clock()
        expires = format_timestamp(moment + timedelta(hours=INVITE_HOURS))
        now = format_timestamp(moment)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            existing = reference.get(transaction=transaction)
            current = existing.to_dict() or {}
            if current.get("status") == "active":
                raise conflict("This person is already active. Change their role instead.")
            staged = self.audit.stage(transaction, moment)
            if current.get("inviteHash"):
                self._end_invite(transaction, current["inviteHash"], "replaced", now)
            kept = {name: value for name, value in current.items() if name not in ("acceptNonce", "acceptingAt")}
            transaction.set(reference, {
                **kept, "email": email, "name": name.strip(), "role": role, "status": "invited",
                "invitedBy": actor, "inviteHash": digest(secret), "inviteExpiresAt": expires,
                "generation": current.get("generation") or secrets.token_hex(8),
                "createdAt": current.get("createdAt", now), "updatedAt": now})
            staged.add(actor=actor, action="staff.invited", tenant_id=None, key=f"staff-invite:{identifier}:{digest(secret)[:12]}",
                       summary=f"{email} was invited as {role}.", refs={"staffId": identifier, "role": role})

        write(self.db.transaction(max_attempts=10))
        tag = digest(secret)[:12]
        mailed = self.mail.enqueue_or_report(
            STAFF_MAIL_TENANT, f"staff-invite-{identifier}-{tag}", "staff_invite", email,
            {"tenantId": STAFF_MAIL_TENANT, "inviteUrl": f"{base}/#staffInvite={identifier}.{secret}",
             "expiresAt": expires, "role": role, "invitedBy": actor}, actor)
        self.notify("invited", email, actor, f"invited-{identifier}-{tag}")
        return {"staffId": identifier, "email": email, "role": role, "status": "invited",
                "inviteExpiresAt": expires, "mail": mailed["status"]}

    def _end_invite(self, transaction: firestore.Transaction, invite_hash: str, reason: str, now: str) -> None:
        transaction.set(self.db.collection(INVITE_ENDS).document(invite_hash), {"reason": reason, "at": now})

    def _why_invalid(self, data: Mapping[str, Any] | None, secret: str) -> str:
        wanted = digest(secret)
        if data and data.get("inviteHash") and hmac.compare_digest(data["inviteHash"], wanted):
            if data.get("inviteExpiresAt", "") <= format_timestamp(self.clock()):
                return INVITE_REASONS["expired"]
            return INVITE_NOT_VALID
        ended = self.db.collection(INVITE_ENDS).document(wanted).get().to_dict() or {}
        return INVITE_REASONS.get(ended.get("reason", ""), INVITE_NOT_VALID)

    def _invite_valid(self, data: Mapping[str, Any] | None, secret: str) -> bool:
        if not data or not data.get("inviteHash") or not hmac.compare_digest(data["inviteHash"], digest(secret)):
            return False
        moment = self.clock()
        if data.get("inviteExpiresAt", "") <= format_timestamp(moment):
            return False
        if data.get("status") == "invited":
            return True
        return (data.get("status") == "accepting" and data.get("acceptingAt", "")
                <= format_timestamp(moment - timedelta(minutes=ACCEPT_LEASE_MINUTES)))

    def _invite_data(self, token: Any) -> tuple[str, str, dict[str, Any]]:
        match = _TOKEN.fullmatch(token) if isinstance(token, str) else None
        if match is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, INVITE_NOT_VALID)
        identifier, secret = match.groups()
        snapshot = self.reference(identifier).get()
        data = snapshot.to_dict() if snapshot.exists else None
        if not self._invite_valid(data, secret):
            raise HTTPException(status.HTTP_404_NOT_FOUND, self._why_invalid(data, secret))
        return identifier, secret, data

    def check_invite(self, token: Any) -> dict[str, Any]:
        _, _, data = self._invite_data(token)
        return {"email": data["email"], "name": data.get("name"), "role": data["role"]}

    def _claim_invite(self, identifier: str, secret: str) -> tuple[dict[str, Any], str]:
        reference = self.reference(identifier)
        nonce = secrets.token_hex(12)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            current = reference.get(transaction=transaction).to_dict()
            if not self._invite_valid(current, secret):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "This invitation was already used.")
            transaction.update(reference, {"status": "accepting", "acceptNonce": nonce,
                                           "acceptingAt": format_timestamp(moment)})
            return current

        return write(self.db.transaction(max_attempts=10)), nonce

    def _release_invite(self, identifier: str, nonce: str) -> None:
        reference = self.reference(identifier)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current.get("status") == "accepting" and current.get("acceptNonce") == nonce:
                transaction.update(reference, {"status": "invited", "acceptNonce": firestore.DELETE_FIELD,
                                               "acceptingAt": firestore.DELETE_FIELD})

        write(self.db.transaction(max_attempts=10))

    def accept_invite(self, token: Any, password: Any, name: Any) -> dict[str, Any]:
        identifier, secret, data = self._invite_data(token)
        if not isinstance(password, str) or not MIN_PASSWORD <= len(password) <= MAX_PASSWORD:
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                f"Use a password of {MIN_PASSWORD} to {MAX_PASSWORD} characters.")
        data, nonce = self._claim_invite(identifier, secret)
        chosen = name.strip() if isinstance(name, str) and _NAME.fullmatch(name.strip()) else data.get("name") or ""
        expected_uid = data.get("uid") or identifier
        refused = conflict("Ask the owner to send a new invitation.")
        try:
            client = self.auth_client()
            try:
                user = client.get_user_by_email(data["email"])
            except admin_auth.UserNotFoundError:
                user = None
            if user is not None and user.uid != expected_uid:
                raise refused
            if user is None:
                user = client.create_user(uid=expected_uid, email=data["email"], password=password,
                                          email_verified=True, display_name=chosen, disabled=False)
            else:
                client.update_user(user.uid, password=password, email_verified=True, display_name=chosen,
                                   disabled=False)
            client.revoke_refresh_tokens(user.uid)
        except (admin_auth.EmailAlreadyExistsError, admin_auth.UidAlreadyExistsError):
            self._release_invite(identifier, nonce)
            raise refused from None
        except HTTPException:
            self._release_invite(identifier, nonce)
            raise
        except Exception:
            self._release_invite(identifier, nonce)
            _LOG.exception("Staff invitation %s could not create the sign-in account.", identifier)
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, ACCOUNT_NOT_CREATED) from None
        except BaseException:
            self._release_invite(identifier, nonce)
            raise
        reference = self.reference(identifier)
        moment = self.clock()
        now = format_timestamp(moment)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            current = reference.get(transaction=transaction).to_dict() or {}
            if current.get("status") != "accepting" or current.get("acceptNonce") != nonce:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "This invitation was already used.")
            staged = self.audit.stage(transaction, moment)
            transaction.update(reference, {
                "status": "active", "uid": user.uid, "name": chosen, "acceptedAt": now, "updatedAt": now,
                "inviteHash": firestore.DELETE_FIELD, "inviteExpiresAt": firestore.DELETE_FIELD,
                "acceptNonce": firestore.DELETE_FIELD, "acceptingAt": firestore.DELETE_FIELD})
            staged.add(actor=data["email"], action="staff.accepted", tenant_id=None, key=f"staff-accept:{identifier}:{digest(secret)[:12]}",
                       summary=f"{data['email']} accepted the invitation.", refs={"staffId": identifier})

        write(self.db.transaction(max_attempts=10))
        self.notify("accepted", data["email"], data["email"], f"accepted-{identifier}-{digest(secret)[:12]}")
        return {"email": data["email"], "role": data["role"]}

    def _last_owner_guard(self, transaction: firestore.Transaction, current: Mapping[str, Any]) -> None:
        if current.get("role") != "owner" or current.get("status") != "active":
            return
        owners = list(self.db.collection(STAFF).where(filter=firestore.FieldFilter("role", "==", "owner")).where(
            filter=firestore.FieldFilter("status", "==", "active")).get(transaction=transaction))
        if len(owners) <= 1:
            raise conflict("This is the last active owner. Make another person owner first.")

    def change_role(self, actor: str, identifier: str, role: Any) -> dict[str, Any]:
        if role not in ROLES:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Choose owner, operator, engineer or support.")
        reference = self.reference(self._staff_id(identifier))
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> tuple[dict[str, Any], bool]:
            current = reference.get(transaction=transaction).to_dict()
            if not current or current["status"] == "disabled":
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Staff account not found.")
            if current["role"] == role:
                return current, False
            if role != "owner":
                self._last_owner_guard(transaction, current)
            staged = self.audit.stage(transaction, moment)
            revision = current.get("revision", 0) + 1
            updated = {**current, "role": role, "revision": revision, "updatedAt": format_timestamp(moment)}
            transaction.set(reference, updated)
            staged.add(actor=actor, action="staff.role_changed", tenant_id=None,
                       key=f"staff-role:{reference.id}:{record_revision(current, revision)}",
                       summary=f"{current['email']} changed from {current['role']} to {role}.",
                       refs={"staffId": reference.id, "from": current["role"], "to": role})
            return updated, True

        updated, changed = write(self.db.transaction(max_attempts=10))
        if changed:
            if updated.get("uid"):
                self.end_sessions(updated["uid"])
            self.notify("role_changed", updated["email"], actor,
                        f"role-{reference.id}-{record_revision(updated, updated['revision'])}")
        return view(updated)

    def disable(self, actor: str, identifier: str) -> dict[str, Any]:
        reference = self.reference(self._staff_id(identifier))
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> tuple[dict[str, Any], bool, bool]:
            current = reference.get(transaction=transaction).to_dict()
            if not current:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Staff account not found.")
            if current["status"] == "disabled":
                return current, False, False
            if (current["status"] == "accepting" and current.get("acceptingAt", "")
                    > format_timestamp(moment - timedelta(minutes=ACCEPT_LEASE_MINUTES))):
                raise conflict("This person is accepting the invitation right now. Try again in up to 10 minutes.")
            self._last_owner_guard(transaction, current)
            staged = self.audit.stage(transaction, moment)
            revision = current.get("revision", 0) + 1
            updated = {**current, "status": "disabled", "revision": revision, "updatedAt": format_timestamp(moment)}
            updated.pop("inviteHash", None)
            updated.pop("inviteExpiresAt", None)
            if current.get("inviteHash"):
                self._end_invite(transaction, current["inviteHash"], "cancelled", format_timestamp(moment))
            transaction.set(reference, updated)
            staged.add(actor=actor, action="staff.disabled", tenant_id=None, key=f"staff-disable:{reference.id}:{record_revision(current, revision)}",
                       summary=f"{current['email']} was turned off.", refs={"staffId": reference.id})
            return updated, True, current["status"] == "active"

        updated, changed, was_active = write(self.db.transaction(max_attempts=10))
        if changed:
            self.db.collection(BACKUPS).document(reference.id).delete()
            if updated.get("uid"):
                self.db.collection(CODES).document(updated["uid"]).delete()
                self.end_sessions(updated["uid"])
                try:
                    client = self.auth_client()
                    client.update_user(updated["uid"], disabled=True)
                    client.revoke_refresh_tokens(updated["uid"])
                except admin_auth.UserNotFoundError:
                    pass
            self.notify("disabled", updated["email"], actor,
                        f"disabled-{reference.id}-{record_revision(updated, updated['revision'])}",
                        extra=(updated["email"],) if was_active else ())
        return view(updated)

    def remove(self, actor: str, identifier: str) -> dict[str, Any]:
        reference = self.reference(self._staff_id(identifier))
        moment = self.clock()

        def check(current: Mapping[str, Any] | None) -> None:
            if not current:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Staff account not found.")
            if current["email"] == actor:
                raise conflict("You cannot remove your own account.")
            if current["status"] != "disabled":
                raise conflict("Turn this person off first. Only people who are turned off can be removed.")

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            current = reference.get(transaction=transaction).to_dict()
            check(current)
            staged = self.audit.stage(transaction, moment)
            transaction.delete(reference)
            staged.add(actor=actor, action="staff.removed", tenant_id=None,
                       key=f"staff-remove:{reference.id}:{record_revision(current, current.get('revision', 0))}",
                       summary=f"{current['email']} ({current.get('name') or 'no name'}) was removed.",
                       refs={"staffId": reference.id, "email": current["email"], "name": current.get("name") or ""})
            return current

        before = reference.get().to_dict()
        check(before)
        self.db.collection(BACKUPS).document(reference.id).delete()
        uid = before.get("uid")
        if uid:
            self.db.collection(CODES).document(uid).delete()
            self.end_sessions(uid)
            try:
                self.auth_client().delete_user(uid)
            except admin_auth.UserNotFoundError:
                pass
            except Exception:
                _LOG.exception("Staff account %s could not be deleted from sign-in.", reference.id)
                raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                                    "The sign-in account could not be removed right now. Nothing was removed. Try again in a minute.") from None
        removed = write(self.db.transaction(max_attempts=10))
        return {"staffId": reference.id, "email": removed["email"], "removed": True}

    @staticmethod
    def _staff_id(identifier: str) -> str:
        if not _STAFF_ID.fullmatch(identifier):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Staff account not found.")
        return identifier

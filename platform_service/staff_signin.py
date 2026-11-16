from __future__ import annotations

import hmac
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from fastapi import HTTPException, status
from firebase_admin import auth as admin_auth
from firebase_admin import exceptions as firebase_exceptions
from google.cloud import firestore

from . import auth
from .account_security import (
    STAFF_ACCOUNT_NAME, device_fingerprint, device_label, queue_signin_alert, remember_device, security_ref,
)
from .mail import HELD_DAILY_CAP, HELD_RECIPIENT_SUPPRESSED, STAFF_MAIL_TENANT, MailTransport, build_transport
from .signing import format_timestamp, parse_timestamp
from .ids import KUALA_LUMPUR, local_date
from .staff import (
    BACKUPS, CODES, SESSION_HOURS, SESSIONS, TRUSTED, TRUSTED_DEVICE_DAYS, StaffBook, allowed_domain, digest,
    keyed_digest, mask, staff_id,
)

CODE_MINUTES = 10
MAX_WRONG = 5
LOCK_STEPS_MINUTES = (15, 60, 1440)
LOCK_NOTICE_GAP_HOURS = 1
LOCK_MEMORY_HOURS = 24
CODES_PER_DAY = 10
CODE_GAP_SECONDS = 30
CODES_PER_WINDOW = 5
WINDOW_MINUTES = 15
FRESH_SECONDS = 600
BACKUP_CODE_COUNT = 10
MAILED_FIELDS = {"failures": "failures", "lockedUntil": "lockedUntil", "lockLevel": "lockLevel"}
BACKUP_FIELDS = {"failures": "backupFailures", "lockedUntil": "backupLockedUntil", "lockLevel": "backupLockLevel"}
_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
_CODE = re.compile(r"^\d{6}$")
_BACKUP = re.compile(r"^[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}$")
_DEVICE_TOKEN = re.compile(r"^([0-9a-f]{32})\.([A-Za-z0-9_-]{40,50})$")


@dataclass(frozen=True)
class Caller:
    user_agent: str
    ip: str
    device: str


def _kuala_lumpur_time(moment: str) -> str:
    local = parse_timestamp(moment).astimezone(KUALA_LUMPUR)
    if local.second or local.microsecond:
        local = local.replace(second=0, microsecond=0) + timedelta(minutes=1)
    return f"{local:%H:%M} on {local.day} {local:%B %Y} (Kuala Lumpur time, UTC+8)"


def _too_many(message: str, until: str | None = None) -> HTTPException:
    return HTTPException(status.HTTP_429_TOO_MANY_REQUESTS,
                         f"{message} Try again after {_kuala_lumpur_time(until)}." if until else message,
                         headers={"Cache-Control": "no-store"})


def _span(minutes: int) -> str:
    return f"{minutes // 60} hours" if minutes >= 120 else f"{minutes} minutes"


def _unauthorized(message: str) -> HTTPException:
    return HTTPException(status.HTTP_401_UNAUTHORIZED, message, headers={"WWW-Authenticate": "Bearer"})


class StaffSignIn:
    def __init__(self, book: StaffBook, *, transport: Callable[[], MailTransport] = build_transport) -> None:
        self.book = book
        self.db = book.db
        self.transport = transport

    def _now(self) -> datetime:
        return self.book.clock()

    def _fresh(self, token: auth.StaffToken) -> Any:
        if self._now().timestamp() - token.auth_time > FRESH_SECONDS:
            raise _unauthorized("Enter your password again.")
        try:
            user = self.book.auth_client().get_user(token.uid)
        except admin_auth.UserNotFoundError as error:
            raise _unauthorized("Enter your password again.") from error
        except firebase_exceptions.FirebaseError as error:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                                "Sign-in is not available right now. Try again in a minute.") from error
        if user.disabled or token.auth_time * 1000 < user.tokens_valid_after_timestamp:
            if user.disabled:
                raise _unauthorized("This account is turned off. Ask the owner.")
            raise _unauthorized("Your password was changed. Enter your new password.")
        return user

    def _open_session(self, transaction: firestore.Transaction, staged: Any, token: auth.StaffToken, caller: Caller, *,
                      session_ref: Any, staff_ref: Any, security: Any, known: dict[str, Any], device: str,
                      now: str, expires: str, how: str) -> bool:
        new_device = remember_device(transaction, security, known, device,
                                     {"tenantId": STAFF_MAIL_TENANT, "uid": token.uid}, now)
        transaction.update(staff_ref, {"lastSignInAt": now})
        transaction.create(session_ref, {
            "uid": token.uid, "email": token.email, "authTime": format_timestamp(datetime.fromtimestamp(
                token.auth_time, tz=timezone.utc)), "createdAt": now, "expiresAt": expires, "status": "active",
            "userAgent": caller.user_agent[:200], "ip": caller.ip[:64], "deviceHash": device})
        staged.add(actor=token.email, action="staff.signed_in", tenant_id=None, key=f"staff-session:{session_ref.id[:32]}",
                   summary=f"{token.email} signed in{how}.",
                   refs={"staffId": staff_ref.id, "session": session_ref.id[:16]})
        return new_device

    def backups_left(self, email: str) -> int:
        snapshot = self.db.collection(BACKUPS).document(staff_id(email)).get()
        return len((snapshot.to_dict() or {}).get("hashes", [])) if snapshot.exists else 0

    def request_code(self, token: auth.StaffToken) -> dict[str, Any]:
        person = self.book.resolve(token)
        self._fresh(token)
        moment = self._now()
        now = format_timestamp(moment)
        today = local_date(moment)
        code = f"{secrets.randbelow(10 ** 6):06d}"
        salt = secrets.token_hex(8)
        reference = self.db.collection(CODES).document(token.uid)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> tuple[str, str | int | None]:
            state = reference.get(transaction=transaction).to_dict() or {}
            if state.get("lockedUntil", "") > now:
                return "locked", state["lockedUntil"]
            if state.get("requestedAt"):
                waited = (moment - parse_timestamp(state["requestedAt"])).total_seconds()
                if waited < CODE_GAP_SECONDS:
                    return "wait", int(CODE_GAP_SECONDS - waited) + 1
            day_count = state.get("dayCount", 0) if state.get("dayKey") == today else 0
            if day_count >= CODES_PER_DAY:
                return "day_limit", None
            started, count = state.get("windowStart"), state.get("windowCount", 0)
            if not started or moment - parse_timestamp(started) >= timedelta(minutes=WINDOW_MINUTES):
                started, count = now, 0
            if count >= CODES_PER_WINDOW:
                return "limit", format_timestamp(parse_timestamp(started) + timedelta(minutes=WINDOW_MINUTES))
            transaction.set(reference, {
                **state, "email": token.email, "codeHash": keyed_digest(salt + code), "salt": salt,
                "expiresAt": format_timestamp(moment + timedelta(minutes=CODE_MINUTES)), "requestedAt": now,
                "windowStart": started, "windowCount": count + 1, "failures": state.get("failures", 0),
                "dayKey": today, "dayCount": day_count + 1})
            return "ok", None

        outcome, detail = write(self.db.transaction(max_attempts=10))
        if outcome == "locked":
            raise _too_many("Too many wrong codes. Sign-in is locked.", detail)
        if outcome == "wait":
            raise _too_many(f"A code was sent a moment ago. Wait {detail} seconds before you ask for another one.")
        if outcome == "day_limit":
            raise _too_many(f"You asked for {CODES_PER_DAY} sign-in codes today. Try again tomorrow, or use a backup code.")
        if outcome == "limit":
            raise _too_many(f"You asked for {CODES_PER_WINDOW} codes in a short time.", detail)
        sent = self.book.mail.send_now(
            STAFF_MAIL_TENANT, f"staff-code-{token.uid[:40]}-{secrets.token_hex(6)}", "staff_signin_code", token.email,
            {"tenantId": STAFF_MAIL_TENANT, "code": code, "minutes": CODE_MINUTES}, token.email, self.transport())
        if sent["status"] == "held":
            why = {HELD_DAILY_CAP: "today because the daily mail limit is reached",
                   HELD_RECIPIENT_SUPPRESSED: "because mail to this address bounced and is blocked"}.get(
                sent.get("heldReason"), "because the mail service is not available")
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                                f"Sign-in codes cannot be sent {why}. Use a backup code, or ask an owner to help.")
        if sent["status"] not in ("sent", "queued"):
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                                "The sign-in code could not be sent. Use a backup code or try again.")
        return {"status": "sent" if sent["status"] == "sent" else "sending", "sentTo": mask(person["email"]),
                "expiresInSeconds": CODE_MINUTES * 60, "backupCodesLeft": self.backups_left(token.email)}

    def verify(self, token: auth.StaffToken, code: Any, backup_code: Any, caller: Caller,
               remember: bool = False) -> dict[str, Any]:
        person = self.book.resolve(token)
        self._fresh(token)
        if (code is None) == (backup_code is None):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Send either code or backupCode.")
        if code is not None:
            entered = str(code).strip()
            if not _CODE.fullmatch(entered):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "The code has 6 digits.")
        else:
            entered = str(backup_code).strip().lower()
            if not _BACKUP.fullmatch(entered):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "A backup code looks like abcd-2345-wxyz.")
        moment = self._now()
        now = format_timestamp(moment)
        identifier = staff_id(token.email)
        secret = secrets.token_urlsafe(32)
        handle = digest(secret)
        device = device_fingerprint(caller.user_agent, caller.device)
        codes_ref = self.db.collection(CODES).document(token.uid)
        backups_ref = self.db.collection(BACKUPS).document(identifier)
        staff_ref = self.book.reference(identifier)
        session_ref = self.db.collection(SESSIONS).document(handle)
        security = security_ref(self.db, STAFF_MAIL_TENANT, token.uid)
        expires = format_timestamp(moment + timedelta(hours=SESSION_HOURS))
        device_handle, device_secret = secrets.token_hex(16), secrets.token_urlsafe(32)
        trusted_until = format_timestamp(moment + timedelta(days=TRUSTED_DEVICE_DAYS))

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            state = codes_ref.get(transaction=transaction).to_dict() or {}
            backups = backups_ref.get(transaction=transaction).to_dict() or {}
            current = staff_ref.get(transaction=transaction).to_dict() or {}
            known = security.get(transaction=transaction).to_dict() or {}
            remembered_before = list(self.db.collection(TRUSTED).where(filter=firestore.FieldFilter(
                "uid", "==", token.uid)).stream(transaction=transaction)) if remember else []
            staged = self.book.audit.stage(transaction, moment)
            if backup_code is None and state.get("lockedUntil", "") > now:
                return {"outcome": "locked", "until": state["lockedUntil"]}
            if current.get("status") != "active":
                return {"outcome": "denied"}
            hashes = list(backups.get("hashes", []))
            used_backup = False
            if backup_code is not None:
                wanted = keyed_digest(f"{identifier}:{entered}")
                matched = [item for item in hashes if hmac.compare_digest(item, wanted)]
                valid = bool(matched)
                if valid:
                    hashes.remove(matched[0])
                    used_backup = True
                elif state.get("backupLockedUntil", "") > now:
                    return {"outcome": "locked", "until": state["backupLockedUntil"]}
            else:
                valid = (bool(state.get("codeHash")) and state.get("expiresAt", "") > now
                         and hmac.compare_digest(state["codeHash"], keyed_digest(state.get("salt", "") + entered)))
            if not valid:
                names = BACKUP_FIELDS if backup_code is not None else MAILED_FIELDS
                failures = state.get(names["failures"], 0) + 1
                if failures >= MAX_WRONG:
                    remembered = state.get(names["lockedUntil"], "") > format_timestamp(
                        moment - timedelta(hours=LOCK_MEMORY_HOURS))
                    level = state.get(names["lockLevel"], 0) if remembered else 0
                    minutes = LOCK_STEPS_MINUTES[min(level, len(LOCK_STEPS_MINUTES) - 1)]
                    until = format_timestamp(moment + timedelta(minutes=minutes))
                    tag = secrets.token_hex(6)
                    notify = level >= 1 or state.get("lastLockNoticeAt", "") <= format_timestamp(
                        moment - timedelta(hours=LOCK_NOTICE_GAP_HOURS))
                    changes = {"email": token.email, names["failures"]: 0, names["lockedUntil"]: until,
                               names["lockLevel"]: level + 1}
                    if backup_code is None:
                        changes.update({"lockedAt": now, "codeHash": firestore.DELETE_FIELD,
                                        "salt": firestore.DELETE_FIELD, "expiresAt": firestore.DELETE_FIELD})
                    if notify:
                        changes["lastLockNoticeAt"] = now
                    transaction.set(codes_ref, changes, merge=True)
                    staged.add(actor=token.email, action="staff.locked", tenant_id=None,
                               key=f"staff-lock:{identifier}:{tag}", summary=f"Sign-in for {token.email} was locked for {_span(minutes)}.",
                               refs={"staffId": identifier})
                    return {"outcome": "locked_now", "until": until, "minutes": minutes, "notify": notify, "tag": tag}
                transaction.set(codes_ref, {"email": token.email, names["failures"]: failures}, merge=True)
                return {"outcome": "wrong", "left": MAX_WRONG - failures}
            transaction.set(codes_ref, {"email": token.email, "failures": 0, "lockLevel": 0,
                                        "backupFailures": 0, "backupLockLevel": 0,
                                        "codeHash": firestore.DELETE_FIELD, "salt": firestore.DELETE_FIELD,
                                        "expiresAt": firestore.DELETE_FIELD, "lockedUntil": firestore.DELETE_FIELD,
                                        "backupLockedUntil": firestore.DELETE_FIELD,
                                        "trustedFailures": 0, "trustedLockedUntil": firestore.DELETE_FIELD},
                            merge=True)
            if used_backup:
                transaction.set(backups_ref, {**backups, "hashes": hashes})
            if remember:
                for old in remembered_before:
                    past = old.to_dict() or {}
                    if past.get("deviceHash") == device or past.get("expiresAt", "") <= now:
                        transaction.delete(old.reference)
                transaction.create(self.db.collection(TRUSTED).document(device_handle), {
                    "uid": token.uid, "email": token.email,
                    "tokenHash": keyed_digest(f"{device_handle}:{device_secret}"),
                    "authTime": format_timestamp(datetime.fromtimestamp(token.auth_time, tz=timezone.utc)),
                    "createdAt": now, "expiresAt": trusted_until, "deviceHash": device,
                    "label": device_label(caller.user_agent)})
            new_device = self._open_session(
                transaction, staged, token, caller, session_ref=session_ref, staff_ref=staff_ref, security=security,
                known=known, device=device, now=now, expires=expires,
                how=(" with a backup code" if used_backup else "")
                + (f" and this device is remembered for {TRUSTED_DEVICE_DAYS} days" if remember else ""))
            return {"outcome": "ok", "newDevice": new_device, "usedBackup": used_backup, "left": len(hashes)}

        result = write(self.db.transaction(max_attempts=10))
        outcome = result["outcome"]
        if outcome == "locked":
            raise _too_many("Too many wrong codes. Sign-in is locked for a while.", result["until"])
        if outcome == "denied":
            raise HTTPException(status.HTTP_403_FORBIDDEN, "This account is not platform staff.")
        if outcome == "locked_now":
            if result["notify"]:
                self.book.notify("locked", token.email, token.email,
                                 f"locked-{identifier}-{result['tag']}", owners_only=True,
                                 minutes=result["minutes"])
            raise _too_many(f"Too many wrong codes. Sign-in is locked for {_span(result['minutes'])}.", result["until"])
        if outcome == "wrong":
            raise _unauthorized(f"That code is not right. {result['left']} tries left.")
        if result["newDevice"]:
            queue_signin_alert(self.book.mail, STAFF_MAIL_TENANT, token.uid, token.email, STAFF_ACCOUNT_NAME,
                               device_label(caller.user_agent), now, device)
        if result["usedBackup"]:
            self.book.notify("backup_used", token.email, token.email, f"backup-{identifier}-{handle[:12]}")
        return {"sessionId": secret, "handle": handle, "expiresAt": expires, "email": token.email,
                "name": person.get("name"), "role": person["role"], "usedBackupCode": result["usedBackup"],
                "backupCodesLeft": result["left"],
                **({"deviceToken": f"{device_handle}.{device_secret}", "deviceTokenExpiresAt": trusted_until}
                   if remember else {})}

    def trusted(self, token: auth.StaffToken, device_token: Any, caller: Caller) -> dict[str, Any]:
        person = self.book.resolve(token)
        user = self._fresh(token)
        refused = _unauthorized("Enter the emailed code.")
        parts = _DEVICE_TOKEN.fullmatch(device_token) if isinstance(device_token, str) else None
        if parts is None:
            raise refused
        device_handle, device_secret = parts.groups()
        moment = self._now()
        now = format_timestamp(moment)
        password_set = format_timestamp(datetime.fromtimestamp(user.tokens_valid_after_timestamp / 1000,
                                                               tz=timezone.utc))
        secret = secrets.token_urlsafe(32)
        handle = digest(secret)
        device = device_fingerprint(caller.user_agent, caller.device)
        codes_ref = self.db.collection(CODES).document(token.uid)
        trusted_ref = self.db.collection(TRUSTED).document(device_handle)
        staff_ref = self.book.reference(staff_id(token.email))
        security = security_ref(self.db, STAFF_MAIL_TENANT, token.uid)
        expires = format_timestamp(moment + timedelta(hours=SESSION_HOURS))

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> bool:
            state = codes_ref.get(transaction=transaction).to_dict() or {}
            record = trusted_ref.get(transaction=transaction).to_dict() or {}
            current = staff_ref.get(transaction=transaction).to_dict() or {}
            known = security.get(transaction=transaction).to_dict() or {}
            staged = self.book.audit.stage(transaction, moment)
            if current.get("status") != "active" or state.get("trustedLockedUntil", "") > now:
                return False
            valid = (hmac.compare_digest(record.get("tokenHash", ""), keyed_digest(f"{device_handle}:{device_secret}"))
                     and record.get("uid") == token.uid and record.get("expiresAt", "") > now
                     and record.get("deviceHash") == device and record.get("authTime", "") >= password_set)
            if not valid:
                failures = state.get("trustedFailures", 0) + 1
                transaction.set(codes_ref, {"email": token.email, "trustedFailures": failures} if failures < MAX_WRONG else {
                    "email": token.email, "trustedFailures": 0, "trustedLockedUntil": format_timestamp(
                        moment + timedelta(minutes=LOCK_STEPS_MINUTES[0]))}, merge=True)
                return False
            transaction.set(codes_ref, {"email": token.email, "trustedFailures": 0}, merge=True)
            self._open_session(
                transaction, staged, token, caller, session_ref=self.db.collection(SESSIONS).document(handle),
                staff_ref=staff_ref, security=security, known=known, device=device, now=now, expires=expires,
                how=" on a remembered device")
            return True

        if not write(self.db.transaction(max_attempts=10)):
            raise refused
        return {"sessionId": secret, "handle": handle, "expiresAt": expires, "email": token.email,
                "name": person.get("name"), "role": person["role"], "usedBackupCode": False,
                "backupCodesLeft": self.backups_left(token.email)}

    def authenticate(self, token: auth.StaffToken, secret: str | None) -> auth.StaffIdentity:
        if not secret or not 20 <= len(secret) <= 100:
            raise _unauthorized("Staff sign-in required.")
        handle = digest(secret)
        session_ref = self.db.collection(SESSIONS).document(handle)
        staff_ref = self.book.reference(staff_id(token.email))
        snapshots = {snapshot.reference.path: snapshot for snapshot in self.db.get_all([session_ref, staff_ref])}
        data = snapshots[session_ref.path].to_dict() or {}
        if (data.get("status") != "active" or data.get("expiresAt", "") <= format_timestamp(self._now())
                or data.get("uid") != token.uid or data.get("email") != token.email):
            raise _unauthorized("Your staff session ended. Sign in again.")
        person = snapshots[staff_ref.path].to_dict()
        if (not person or person.get("status") != "active" or person.get("uid") != token.uid
                or not allowed_domain(token.email)):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "This account is not platform staff.")
        return auth.StaffIdentity(email=token.email, subject=token.uid, role=person["role"],
                                  name=person.get("name") or "", session_id=handle)

    def sessions(self, identity: auth.StaffIdentity) -> list[dict[str, Any]]:
        now = format_timestamp(self._now())
        rows = []
        for snapshot in self.db.collection(SESSIONS).where(
                filter=firestore.FieldFilter("uid", "==", identity.subject)).stream():
            data = snapshot.to_dict() or {}
            if data.get("status") == "active" and data.get("expiresAt", "") > now:
                rows.append({"sessionId": snapshot.id, "createdAt": data["createdAt"], "expiresAt": data["expiresAt"],
                             "userAgent": data.get("userAgent"), "ip": data.get("ip"),
                             "current": snapshot.id == identity.session_id})
        return sorted(rows, key=lambda row: row["createdAt"], reverse=True)

    def end_session(self, identity: auth.StaffIdentity, handle: str) -> int:
        target = identity.session_id if handle == "current" else handle
        if not target or self.book.end_sessions(identity.subject, handle=target) == 0:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Session not found.")
        return 1

    def end_all(self, identity: auth.StaffIdentity) -> int:
        return self.book.end_sessions(identity.subject)

    def create_backup_codes(self, identity: auth.StaffIdentity, token: auth.StaffToken) -> list[str]:
        self._fresh(token)
        identifier = staff_id(identity.email)
        codes = ["-".join("".join(secrets.choice(_ALPHABET) for _ in range(4)) for _ in range(3))
                 for _ in range(BACKUP_CODE_COUNT)]
        moment = self._now()
        reference = self.db.collection(BACKUPS).document(identifier)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            staged = self.book.audit.stage(transaction, moment)
            transaction.set(reference, {"email": identity.email, "hashes": [keyed_digest(f"{identifier}:{code}") for code in codes],
                                        "createdAt": format_timestamp(moment)})
            staged.add(actor=identity.email, action="staff.backup_codes_created", tenant_id=None,
                       key=f"staff-backup:{identifier}:{digest(''.join(codes))[:12]}",
                       summary=f"New backup codes were created for {identity.email}.", refs={"staffId": identifier})

        write(self.db.transaction(max_attempts=10))
        self.book.notify("backup_created", identity.email, identity.email,
                         f"backupnew-{identifier}-{digest(''.join(codes))[:12]}", extra=(identity.email,))
        return codes

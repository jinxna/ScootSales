from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from firebase_admin import auth as admin_auth
from google.cloud import firestore

from . import config
from .commands import CommandProblem, run_command
from .company_access import CompanyAccess
from .lifecycle import ACCESS, DELETION_REASON, USERS, TenantLifecycle
from .mail import MailQueue
from .operations import OperationContext, OperationStore, Step
from .seats import move_counts, pool_for_role, read_usage

REQUESTS = "privacy_deletion_requests"
DELETED_NAME = "Deleted user"
ACTION_ACCEPT = "account.deletion_accept"
ACTION_CANCEL = "account.deletion_cancel"
ACTION_PURGE = "account.deletion_purge"
ACTION_SHORTEN = "account.deletion_shorten"
KEPT_ROLES = ("admin", "developer")
OPEN_STATUSES = ("submitted", "reviewing")
NAME_FIELDS = ("salesmanName", "submittedByName", "createdByName", "salesPersonName", "salespersonName", "ownerName")
EMAIL_FIELDS = ("salesmanEmail", "submittedByEmail", "createdByEmail")
BUSINESS_RECORDS = (
    ("orders", "salesmanUid"),
    ("route_plans", "salesmanUid"),
    ("visits", "salesmanUid"),
    ("visits", "ownerUid"),
    ("conversation_outcomes", "salesmanUid"),
    ("route_plan_progress", "salesmanUid"),
    ("route_stop_progress", "salesmanUid"),
    ("special_requests", "createdByUid"),
    ("retailers", "assignedSalesmanUid"),
)
HISTORY_RECORDS = (
    ("orders", "salesmanUid"),
    ("route_plans", "salesmanUid"),
    ("visits", "salesmanUid"),
    ("visits", "ownerUid"),
    ("conversation_outcomes", "salesmanUid"),
    ("route_plan_progress", "salesmanUid"),
    ("route_stop_progress", "salesmanUid"),
    ("gps_tracking", "salesmanUid"),
    ("gps_tracking", "uid"),
    ("live_tracking", "salesmanUid"),
    ("live_tracking", "uid"),
)
CODE_HISTORY_RECORDS = (
    ("orders", "salesmanCode"),
    ("orders", "salesmanId"),
    ("gps_tracking", "salesmanCode"),
    ("live_tracking", "salesmanCode"),
)
CODE_CLAIMS = "employee_codes"
TRACKING_RECORDS = (("gps_tracking", "salesmanUid"), ("gps_tracking", "uid"))
TRACKING_DOCUMENTS = ("live_tracking", "tracking_controls")
BATCH = 400
MAIL_ADMINS = 5

_LOG = logging.getLogger("platform_service.account_deletion")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _day(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d")


def _reasons(data: Mapping[str, Any]) -> list[str]:
    value = data.get("disabledReasons")
    return [reason for reason in value if isinstance(reason, str)] if isinstance(value, list) else []


def person_has_history(db: firestore.Client, uid: str, code: str,
                       transaction: firestore.Transaction | None = None) -> bool:
    searches = [(collection, field, uid) for collection, field in HISTORY_RECORDS]
    if code.strip():
        searches += [(collection, field, code) for collection, field in CODE_HISTORY_RECORDS]
    for collection, field, value in searches:
        query = db.collection(collection).where(filter=firestore.FieldFilter(field, "==", value)).limit(1)
        if any(True for _ in query.stream(transaction=transaction)):
            return True
    return False


def retire_code(transaction: firestore.Transaction, db: firestore.Client, uid: str, code: Any) -> None:
    claim = db.collection(CODE_CLAIMS).document(str(code or "").strip().upper())
    transaction.set(claim, {"retired": True, "retiredUid": uid, "retiredAt": firestore.SERVER_TIMESTAMP}, merge=True)


class AccountDeletions:
    def __init__(self, access: CompanyAccess, tenant_id: str, company_name: Callable[[], str], *,
                 runner: OperationStore, mail: MailQueue, platform: firestore.Client | None = None,
                 retention_days: int | None = None, clock: Callable[[], datetime] = _utc_now):
        days = config.ACCOUNT_DELETION_DAYS if retention_days is None else retention_days
        if type(days) is not int or days < 1:
            raise ValueError("Deletion retention must be a whole number of days, at least 1.")
        self.access, self.db = access, access.db
        self.platform = platform or access.db
        self.tenant_id, self.company_name = tenant_id, company_name
        self.runner, self.mail, self.clock = runner, mail, clock
        self.retention = timedelta(days=days)
        self.delete_now_window = timedelta(days=config.DELETE_NOW_RESTORE_DAYS)

    def run(self, *, apply: bool = False) -> dict[str, Any]:
        now = self.clock()
        due: dict[str, list[str]] = {"accept": [], "cancel": [], "shorten": [], "purge": []}
        for snapshot in self.db.collection(REQUESTS).stream():
            action = self._next_action(snapshot.to_dict() or {}, now)
            if action:
                due[action].append(snapshot.id)
        result: dict[str, Any] = {"dryRun": not apply, "due": {name: sorted(ids) for name, ids in due.items()},
                                  "done": {"accept": [], "cancel": [], "shorten": [], "purge": []}, "refused": [], "failed": []}
        if not apply:
            return result
        for action in ("accept", "cancel", "shorten", "purge"):
            for uid in sorted(due[action]):
                try:
                    if getattr(self, action)(uid, now) is False:
                        result["refused"].append(uid)
                    else:
                        result["done"][action].append(uid)
                except Exception:
                    _LOG.exception("Account deletion %s failed for a request.", action)
                    result["failed"].append(uid)
        return result

    @staticmethod
    def _next_action(request: Mapping[str, Any], now: datetime) -> str | None:
        status, created = request.get("status"), request.get("createdAt")
        accepted = created is not None and request.get("acceptedFor") == created
        if status == "completed" and request.get("purgedAt"):
            return None
        if status == "rejected":
            return "cancel" if accepted and request.get("restoredFor") != created else None
        if status not in OPEN_STATUSES and status != "completed":
            return None
        if not accepted:
            return "accept"
        if status == "completed":
            return "shorten"
        purge_after = request.get("purgeAfter")
        return "purge" if isinstance(purge_after, datetime) and purge_after <= now else None

    def _request(self, uid: str) -> Any:
        return self.db.collection(REQUESTS).document(uid)

    def _key(self, kind: str, uid: str, now: datetime) -> str:
        created = (self._request(uid).get().to_dict() or {}).get("createdAt")
        stamp = created.isoformat() if isinstance(created, datetime) else ""
        text = "\n".join((kind, self.tenant_id, uid, stamp, str(int(now.timestamp()) // 60)))
        digest = hashlib.sha256(text.encode()).hexdigest()
        return f"{kind}-{digest[:48]}"

    def _run(self, kind: str, action: str, uid: str, now: datetime, steps: list[Step], fallback: str) -> None:
        run_command(self.runner, key=self._key(kind, uid, now), action=action, actor="account-deletion-worker",
                    tenant_id=self.tenant_id, reason=fallback, params={"uid": uid}, steps=steps, fallback=fallback)

    def _still_due(self, uid: str, now: datetime, action: str) -> bool:
        return self._next_action(self._request(uid).get().to_dict() or {}, now) == action

    def _refuse(self, uid: str, now: datetime, note: str) -> bool:
        request = self._request(uid).get().to_dict() or {}
        created = request.get("createdAt")
        accepted = created is not None and request.get("acceptedFor") == created
        change = {"status": "rejected", "serverNote": note, "updatedAt": now}
        if not accepted:
            change["restoredFor"] = created
        self._request(uid).update(change)
        if accepted:
            self.cancel(uid, now)
        return False

    def accept(self, uid: str, now: datetime) -> bool | None:
        if not self._still_due(uid, now, "accept"):
            return None
        data = self.db.collection(ACCESS).document(uid).get().to_dict() or {}
        if data.get("accessVersion") != 2 or data.get("uid") != uid:
            return self._refuse(uid, now, "This account cannot be deleted from here.")
        if data.get("role") in KEPT_ROLES:
            return self._refuse(uid, now, "Administrator accounts are not deleted from the app.")
        if data.get("assignedSalesmanCodes"):
            return self._refuse(uid, now, "Move this supervisor's salespeople to another supervisor first.")
        window = self.delete_now_window if (self._request(uid).get().to_dict() or {}).get("status") == "completed"             else self.retention
        self._run("accept", ACTION_ACCEPT, uid, now, self._accept_steps(uid, now, window), "Deletion request accepted")

    def shorten(self, uid: str, now: datetime) -> bool | None:
        if not self._still_due(uid, now, "shorten"):
            return None
        self._run("shorten", ACTION_SHORTEN, uid, now, self._shorten_steps(uid, now), "Deletion shortened")

    def cancel(self, uid: str, now: datetime) -> None:
        self._run("cancel", ACTION_CANCEL, uid, now, self._cancel_steps(uid, now), "Deletion request cancelled")

    def purge(self, uid: str, now: datetime) -> bool | None:
        if not self._still_due(uid, now, "purge"):
            return None
        data = self.db.collection(ACCESS).document(uid).get().to_dict() or {}
        if data.get("accessVersion") != 2 or data.get("uid") != uid:
            return self._refuse(uid, now, "This account cannot be deleted from here.")
        if data.get("role") in KEPT_ROLES:
            return self._refuse(uid, now, "Administrator accounts are not deleted from the app.")
        if data.get("assignedSalesmanCodes"):
            return self._refuse(uid, now, "Move this supervisor's salespeople to another supervisor first.")
        self._run("purge", ACTION_PURGE, uid, now, self._purge_steps(uid, now), "Account deleted")

    def _profile_ids(self, data: Mapping[str, Any], uid: str) -> list[str]:
        ids = [uid]
        linked = data.get("userDocId")
        if isinstance(linked, str) and linked and linked != uid:
            ids.append(linked)
        return ids

    def _accept_steps(self, uid: str, now: datetime, window: timedelta) -> list[Step]:
        def mark_apply(_: OperationContext) -> dict[str, bool]:
            reference = self.db.collection(ACCESS).document(uid)

            @firestore.transactional
            def write(transaction: firestore.Transaction) -> None:
                snapshot = reference.get(transaction=transaction)
                if not snapshot.exists:
                    raise CommandProblem("Unknown account.")
                data = snapshot.to_dict() or {}
                reasons = _reasons(data)
                if DELETION_REASON in reasons:
                    return
                change = {"disabledReasons": sorted([*reasons, DELETION_REASON]), "deletionRequestedAt": now,
                          "deletionPurgeAfter": now + window, "updatedAt": firestore.SERVER_TIMESTAMP}
                transaction.update(reference, change)
                if data.get("userDocId"):
                    transaction.set(self.db.collection(USERS).document(data["userDocId"]), change, merge=True)

            write(self.db.transaction(max_attempts=10))
            return {"marked": True}

        def mark_check(_: OperationContext) -> bool:
            return DELETION_REASON in _reasons(self.db.collection(ACCESS).document(uid).get().to_dict() or {})

        def disable_apply(_: OperationContext) -> dict[str, bool]:
            try:
                self.access.auth.update_user(uid, disabled=True)
                self.access.auth.revoke_refresh_tokens(uid)
            except admin_auth.UserNotFoundError:
                pass
            return {"disabled": True}

        def notify_apply(_: OperationContext) -> dict[str, Any]:
            data = self.db.collection(ACCESS).document(uid).get().to_dict() or {}
            requested = data.get("deletionRequestedAt") or now
            purge_after = data.get("deletionPurgeAfter") or now + window
            outcomes = []
            admins = [row for row in self.db.collection(ACCESS).where(
                filter=firestore.FieldFilter("role", "==", "admin")).stream()
                if (row.to_dict() or {}).get("status") == "active"
                and isinstance((row.to_dict() or {}).get("email"), str)]
            for row in sorted(admins, key=lambda item: item.id)[:MAIL_ADMINS]:
                digest = hashlib.sha256(f"{uid}\n{requested.isoformat()}\n{row.id}".encode()).hexdigest()
                outcomes.append(self.mail.enqueue_or_report(
                    self.tenant_id, f"acctdel-{digest[:48]}", "account_deletion_notice", row.to_dict()["email"],
                    {"tenantId": self.tenant_id, "companyName": self.company_name(),
                     "requestedAt": _day(requested), "deleteAfter": _day(purge_after)}, "account-deletion-worker")["status"])
            return {"mail": outcomes}

        def record_apply(_: OperationContext) -> dict[str, bool]:
            request = self._request(uid).get().to_dict() or {}
            data = self.db.collection(ACCESS).document(uid).get().to_dict() or {}
            change = {
                "acceptedFor": request.get("createdAt"), "acceptedAt": now,
                "purgeAfter": data.get("deletionPurgeAfter") or now + window,
                "restoredFor": firestore.DELETE_FIELD, "serverNote": firestore.DELETE_FIELD, "updatedAt": now}
            if request.get("status") in (*OPEN_STATUSES, "completed"):
                change["status"] = "reviewing"
            self._request(uid).update(change)
            return {"recorded": True}

        def record_check(_: OperationContext) -> bool:
            request = self._request(uid).get().to_dict() or {}
            return request.get("createdAt") is not None and request.get("acceptedFor") == request.get("createdAt")

        return [Step("mark_requested", mark_apply, mark_check), Step("disable_auth", disable_apply, lambda _: False),
                Step("notify_admins", notify_apply, lambda _: False), Step("record_acceptance", record_apply, record_check)]

    def _shorten_steps(self, uid: str, now: datetime) -> list[Step]:
        def shorten_apply(_: OperationContext) -> dict[str, bool]:
            request = self._request(uid).get().to_dict() or {}
            purge_after = min(request.get("purgeAfter") or now + self.delete_now_window, now + self.delete_now_window)
            access = self.db.collection(ACCESS).document(uid)
            data = access.get().to_dict() or {}
            change = {"deletionPurgeAfter": purge_after, "updatedAt": firestore.SERVER_TIMESTAMP}
            access.update(change)
            if data.get("userDocId"):
                self.db.collection(USERS).document(data["userDocId"]).set(change, merge=True)
            self._request(uid).update({"purgeAfter": purge_after, "status": "reviewing", "updatedAt": now})
            return {"shortened": True}

        def shorten_check(_: OperationContext) -> bool:
            return (self._request(uid).get().to_dict() or {}).get("status") != "completed"

        return [Step("shorten_window", shorten_apply, shorten_check)]

    def _cancel_steps(self, uid: str, now: datetime) -> list[Step]:
        def clear_apply(_: OperationContext) -> dict[str, bool]:
            reference = self.db.collection(ACCESS).document(uid)

            @firestore.transactional
            def write(transaction: firestore.Transaction) -> None:
                snapshot = reference.get(transaction=transaction)
                if not snapshot.exists:
                    return
                data = snapshot.to_dict() or {}
                change = {"disabledReasons": [reason for reason in _reasons(data) if reason != DELETION_REASON],
                          "deletionRequestedAt": firestore.DELETE_FIELD, "deletionPurgeAfter": firestore.DELETE_FIELD,
                          "updatedAt": firestore.SERVER_TIMESTAMP}
                transaction.update(reference, change)
                if data.get("userDocId"):
                    transaction.set(self.db.collection(USERS).document(data["userDocId"]), change, merge=True)

            write(self.db.transaction(max_attempts=10))
            return {"cleared": True}

        def clear_check(_: OperationContext) -> bool:
            data = self.db.collection(ACCESS).document(uid).get().to_dict() or {}
            return DELETION_REASON not in _reasons(data) and "deletionRequestedAt" not in data

        def restore_apply(_: OperationContext) -> dict[str, bool]:
            if self.db.collection(ACCESS).document(uid).get().exists:
                TenantLifecycle(self.access).reconcile_auth(uid)
            return {"restored": True}

        def record_apply(_: OperationContext) -> dict[str, bool]:
            created = (self._request(uid).get().to_dict() or {}).get("createdAt")
            self._request(uid).update({"restoredFor": created, "restoredAt": now, "updatedAt": now})
            return {"recorded": True}

        def record_check(_: OperationContext) -> bool:
            request = self._request(uid).get().to_dict() or {}
            return request.get("createdAt") is not None and request.get("restoredFor") == request.get("createdAt")

        return [Step("clear_request", clear_apply, clear_check), Step("restore_sign_in", restore_apply, lambda _: False),
                Step("record_restore", record_apply, record_check)]

    def _purge_steps(self, uid: str, now: datetime) -> list[Step]:
        def disable_apply(_: OperationContext) -> dict[str, bool]:
            try:
                self.access.auth.update_user(uid, disabled=True)
                self.access.auth.revoke_refresh_tokens(uid)
            except admin_auth.UserNotFoundError:
                pass
            return {"disabled": True}

        def scrub_apply(_: OperationContext) -> dict[str, int]:
            return {"changed": self._scrub_business_records(uid)}

        def tracking_apply(_: OperationContext) -> dict[str, int]:
            stored = self.db.collection(ACCESS).document(uid).get().to_dict() or {}
            code = str(stored.get("employeeCode") or "").strip()
            if code and person_has_history(self.db, uid, code):
                self.db.collection(CODE_CLAIMS).document(code.upper()).set(
                    {"retired": True, "retiredUid": uid, "retiredAt": firestore.SERVER_TIMESTAMP}, merge=True)
            return {"deleted": self._delete_tracking(uid)}

        def invitations_apply(_: OperationContext) -> dict[str, int]:
            rows = [row for row in self.platform.collection("invitations").where(
                filter=firestore.FieldFilter("uid", "==", uid)).stream()
                if (row.to_dict() or {}).get("tenantId") in (None, self.tenant_id)]
            for row in rows:
                row.reference.delete()
            return {"deleted": len(rows)}

        def auth_apply(_: OperationContext) -> dict[str, bool]:
            try:
                self.access.auth.delete_user(uid)
            except admin_auth.UserNotFoundError:
                pass
            return {"deleted": True}

        def auth_check(_: OperationContext) -> bool:
            try:
                self.access.auth.get_user(uid)
            except admin_auth.UserNotFoundError:
                return True
            return False

        def records_apply(_: OperationContext) -> dict[str, bool]:
            self._remove_profile(uid)
            return {"removed": True}

        def records_check(_: OperationContext) -> bool:
            return not self.db.collection(ACCESS).document(uid).get().exists

        def record_apply(_: OperationContext) -> dict[str, bool]:
            reference = self._request(uid)

            @firestore.transactional
            def complete(transaction: firestore.Transaction) -> bool:
                if (reference.get(transaction=transaction).to_dict() or {}).get("status") not in OPEN_STATUSES:
                    return False
                transaction.update(reference, {"status": "completed", "purgedAt": now, "updatedAt": now})
                return True

            return {"recorded": complete(self.db.transaction(max_attempts=10))}

        def record_check(_: OperationContext) -> bool:
            request = self._request(uid).get().to_dict() or {}
            return request.get("status") == "completed" and bool(request.get("purgedAt"))

        return [Step("disable_auth", disable_apply, lambda _: False),
                Step("scrub_business_records", scrub_apply, lambda _: False),
                Step("delete_tracking", tracking_apply, lambda _: False),
                Step("delete_invitations", invitations_apply, lambda _: False),
                Step("delete_auth", auth_apply, auth_check), Step("remove_profile", records_apply, records_check),
                Step("record_purge", record_apply, record_check)]

    def _scrub_business_records(self, uid: str) -> int:
        changed = 0
        batch, pending = self.db.batch(), 0
        for collection, field in BUSINESS_RECORDS:
            rows = list(self.db.collection(collection).where(filter=firestore.FieldFilter(field, "==", uid)).stream())
            for row in rows:
                data = row.to_dict() or {}
                change: dict[str, Any] = {name: DELETED_NAME for name in NAME_FIELDS
                                          if name in data and data[name] != DELETED_NAME}
                change.update({name: firestore.DELETE_FIELD for name in EMAIL_FIELDS if name in data})
                if not change:
                    continue
                batch.update(row.reference, change)
                pending += 1
                changed += 1
                if pending == BATCH:
                    batch.commit()
                    batch, pending = self.db.batch(), 0
        if pending:
            batch.commit()
        return changed

    def _delete_tracking(self, uid: str) -> int:
        deleted = 0
        for collection, field in TRACKING_RECORDS:
            while True:
                rows = list(self.db.collection(collection).where(
                    filter=firestore.FieldFilter(field, "==", uid)).limit(BATCH).stream())
                if not rows:
                    break
                batch = self.db.batch()
                for row in rows:
                    batch.delete(row.reference)
                batch.commit()
                deleted += len(rows)
        for collection in TRACKING_DOCUMENTS:
            reference = self.db.collection(collection).document(uid)
            if reference.get().exists:
                reference.delete()
                deleted += 1
        return deleted

    def _remove_profile(self, uid: str) -> None:
        reference = self.db.collection(ACCESS).document(uid)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            snapshot = reference.get(transaction=transaction)
            usage = read_usage(transaction, self.db, required=False)
            if not snapshot.exists:
                return
            data = snapshot.to_dict() or {}
            pool = pool_for_role(data.get("role"))
            supervisor_uid = str(data.get("supervisorUid") or "")
            supervisor_ref = self.db.collection(ACCESS).document(supervisor_uid) if supervisor_uid else None
            supervisor = supervisor_ref.get(transaction=transaction) if supervisor_ref else None
            retain = person_has_history(self.db, uid, str(data.get("employeeCode") or ""), transaction)
            move_counts(transaction, self.db, usage, {pool: -1} if pool and data.get("seatHeld") is True else {}, None)
            transaction.delete(reference)
            if retain and str(data.get("employeeCode") or "").strip():
                retire_code(transaction, self.db, uid, data.get("employeeCode"))
            for profile_id in self._profile_ids(data, uid):
                transaction.delete(self.db.collection(USERS).document(profile_id))
            if supervisor is not None and supervisor.exists:
                remove = firestore.ArrayRemove([str(data.get("employeeCode") or "")])
                transaction.update(supervisor_ref, {"assignedSalesmanCodes": remove})
                linked = (supervisor.to_dict() or {}).get("userDocId")
                if linked:
                    transaction.set(self.db.collection(USERS).document(linked), {"assignedSalesmanCodes": remove}, merge=True)

        write(self.db.transaction(max_attempts=10))

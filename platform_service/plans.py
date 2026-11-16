from __future__ import annotations

import hashlib
import json
import logging
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from google.api_core import exceptions as gcloud_exceptions
from google.cloud import firestore

from . import config
from .commands import CommandProblem, PlanMissing
from .seats import LIMIT_KEYS, limit_keys
from .signing import SignatureError, format_timestamp, parse_timestamp

PLANS = "plans"
VERSIONS = "versions"
SUBSCRIPTIONS = "subscriptions"
PLAN_REQUESTS = "plan_requests"
PLAN_REQUEST_HISTORY = "history"
CATALOGUE_FILE = Path(__file__).with_name("plan_catalogue.json")

EDITIONS = ("basic", "advanced")
EDITION_CAPABILITIES = (
    ("Orders, purchase orders and special requests", "basic"),
    ("Products, categories and retailers", "basic"),
    ("Weekly route planner and saved routes", "basic"),
    ("Salesman tracking and visit logs", "basic"),
    ("Retailer score sheets", "basic"),
    ("Reports", "basic"),
    ("Salesperson phone app with offline ordering", "basic"),
    ("Scout for orders and routes", "basic"),
    ("Demand forecast", "advanced"),
    ("Action centre", "advanced"),
    ("Weekly AI summary", "advanced"),
    ("Trust and Impact Lab", "advanced"),
    ("Route priorities and retailer segments", "advanced"),
    ("Retailer memory and replenishment", "advanced"),
    ("Visit briefs on the phone and in Scout", "advanced"),
)


def edition_features() -> dict[str, list[str]]:
    return {
        edition: [
            label
            for label, minimum in EDITION_CAPABILITIES
            if EDITIONS.index(minimum) <= EDITIONS.index(edition)
        ]
        for edition in EDITIONS
    }
VISIBILITIES = ("public", "private")
PLAN_STATUSES = ("active", "retired")
BILLING_INTERVALS = ("monthly", "yearly")
CURRENCY = "MYR"
MAX_OVERRIDE_DAYS = 180
MAX_OVERRIDES = 20
UPGRADE_ONLY_MESSAGE = "This release supports upgrades only."
OPEN_REQUEST_MESSAGE = "Your request is with Scoot Sales."
NOTICE_INTERVAL = timedelta(hours=24)

PLAN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")
_FEATURE_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,39}$")
_NAME = re.compile(r"^[^\x00-\x1f\x7f]{1,80}$")
_NOTES = re.compile(r"^[^\x00-\x08\x0b-\x1f\x7f]{0,500}$")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _bad(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=detail)


def _count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 10_000_000


def _schema(data: Mapping[str, Any]) -> int:
    schema = data.get("quotaSchemaVersion", 1)
    try:
        limit_keys(schema)
    except ValueError:
        raise _bad("Unsupported quota schema version.") from None
    return schema


def _limits(value: Any, *, partial: bool, schema: int | None = 1) -> dict[str, int | None]:
    keys = (*LIMIT_KEYS, "admins", "branchManagers") if schema is None else limit_keys(schema)
    if not isinstance(value, Mapping) or set(value) - set(keys):
        raise _bad("Limits must name only the selected quota schema's pools.")
    if not partial and set(value) != set(keys):
        raise _bad("Give every limit required by the quota schema (null for unlimited).")
    for number in value.values():
        if number is not None and not _count(number):
            raise _bad("A limit is a whole number of 0 or more, or null for no limit.")
    return {key: value[key] for key in keys if key in value}


def _add_ons(value: Any, keys: tuple[str, ...]) -> dict[str, int]:
    if not isinstance(value, Mapping) or set(value) - set(keys):
        raise _bad("Add-ons must name only the selected quota schema's pools.")
    if not all(_count(number) for number in value.values()):
        raise _bad("An add-on is a whole number of 0 or more.")
    return dict(value)


def _features(value: Any) -> dict[str, bool]:
    if not isinstance(value, Mapping) or len(value) > 50:
        raise _bad("Features must be a list of on/off switches.")
    for key, flag in value.items():
        if not isinstance(key, str) or not _FEATURE_KEY.fullmatch(key) or not isinstance(flag, bool):
            raise _bad("Features must be a list of on/off switches.")
    return dict(value)


def _prices(value: Any) -> dict[str, Any]:
    value = {} if value is None else value
    ok = isinstance(value, Mapping) and set(value) <= {"currency", "monthly", "yearly"}
    if ok:
        ok = value.get("currency", CURRENCY) == CURRENCY
        for key in ("monthly", "yearly"):
            amount = value.get(key)
            ok = ok and (
                amount is None
                or (
                    isinstance(amount, (int, float))
                    and not isinstance(amount, bool)
                    and 0 <= amount <= 10_000_000
                )
            )
    if not ok:
        raise _bad("Prices are in MYR; monthly and yearly are numbers or null.")
    return {"currency": CURRENCY, "monthly": value.get("monthly"), "yearly": value.get("yearly")}


def _display(body: Mapping[str, Any]) -> dict[str, Any]:
    tagline = body.get("tagline") or ""
    highlights = body.get("highlights") or []
    order = body.get("sortOrder", 0)
    if (
        not isinstance(tagline, str)
        or len(tagline) > 80
        or "\n" in tagline
        or not isinstance(highlights, list)
        or len(highlights) > 12
        or not all(isinstance(item, str) and 1 <= len(item) <= 120 for item in highlights)
        or isinstance(order, bool)
        or not isinstance(order, int)
        or not -1_000_000 <= order <= 1_000_000
    ):
        raise _bad("Check the tagline (80), highlights (12 lines of 120) and sort order.")
    return {"tagline": tagline, "highlights": list(highlights), "sortOrder": order}


def check_plan_id(plan_id: str) -> str:
    if not PLAN_ID.fullmatch(plan_id):
        raise _bad("A plan ID is 1 to 32 letters, digits, dashes or underscores.")
    return plan_id


def clean_visibility(value: Any) -> str:
    if value not in VISIBILITIES:
        raise _bad("Visibility is public or private.")
    return value


def clean_version(body: Mapping[str, Any]) -> dict[str, Any]:
    name = str(body.get("name") or "").strip()
    if not _NAME.fullmatch(name):
        raise _bad("A plan name is 1 to 80 characters.")
    if body.get("edition") not in EDITIONS:
        raise _bad("Edition is basic or advanced.")
    notes = body.get("notes") or ""
    if not isinstance(notes, str) or not _NOTES.fullmatch(notes):
        raise _bad("Notes are at most 500 characters.")
    schema = _schema(body)
    return {
        "name": name,
        "edition": body["edition"],
        "limits": _limits(body.get("limits"), partial=False, schema=schema),
        **({"quotaSchemaVersion": schema} if "quotaSchemaVersion" in body else {}),
        "features": _features(body.get("features") or {}),
        "prices": _prices(body.get("prices")),
        **_display(body),
        "notes": notes,
    }


def _time_text(value: Any, what: str) -> str | None:
    if value is None:
        return None
    try:
        return format_timestamp(parse_timestamp(value))
    except SignatureError:
        raise _bad(f"{what} must look like 2026-12-31T00:00:00Z.") from None


def clean_subscription(body: Mapping[str, Any]) -> dict[str, Any]:
    plan_id = check_plan_id(str(body.get("planId") or ""))
    version = body.get("planVersion")
    if version is not None and (
        isinstance(version, bool) or not isinstance(version, int) or version < 1
    ):
        raise _bad("A plan version is a whole number from 1, or null for the plan's current version.")
    add_ons = _add_ons(body["addOns"], (*LIMIT_KEYS, "admins", "branchManagers")) if "addOns" in body else None
    interval = body.get("billingInterval")
    if interval is not None and interval not in BILLING_INTERVALS:
        raise _bad("Billing interval is monthly, yearly or null.")
    expected = body.get("expectedRevision")
    if expected is not None and (
        isinstance(expected, bool) or not isinstance(expected, int) or expected < 0
    ):
        raise _bad("expectedRevision must be a whole number of 0 or more.")
    return {
        "kind": "put",
        "planId": plan_id,
        "planVersion": version,
        **({"addOns": add_ons} if add_ons is not None else {}),
        "billingInterval": interval,
        "renewsAt": _time_text(body.get("renewsAt"), "renewsAt"),
        "trialEndsAt": _time_text(body.get("trialEndsAt"), "trialEndsAt"),
        "expectedRevision": expected,
    }


def clean_override(body: Mapping[str, Any], *, now: datetime, actor: str) -> dict[str, Any]:
    limits = _limits(body.get("limits", {}), partial=True, schema=None)
    features = _features(body.get("features") or {})
    if not limits and not features:
        raise _bad("An override must change at least one limit or feature.")
    reason = str(body.get("reason") or "").strip()
    if not 1 <= len(reason) <= 200:
        raise _bad("Give a reason of 1 to 200 characters.")
    ticket = body.get("ticket")
    if ticket is not None and (not isinstance(ticket, str) or len(ticket) > 100):
        raise _bad("A ticket is at most 100 characters.")
    expires = _time_text(body.get("expiresAt"), "expiresAt")
    if expires is None:
        raise _bad("An override needs an expiry date.")
    moment = parse_timestamp(expires)
    if moment <= now or moment > now + timedelta(days=MAX_OVERRIDE_DAYS):
        raise _bad(f"An override must expire within the next {MAX_OVERRIDE_DAYS} days.")
    return {
        "kind": "override",
        "override": {
            "limits": limits,
            "features": features,
            "reason": reason,
            "ticket": ticket or None,
            "expiresAt": expires,
            "createdBy": actor,
            "createdAt": format_timestamp(now),
        },
    }


def effective_plan(
    version: Mapping[str, Any], subscription: Mapping[str, Any], now: datetime
) -> dict[str, Any]:
    schema = _schema(version)
    keys = limit_keys(schema)
    base = _limits(version.get("limits"), partial=False, schema=schema)
    add_ons = _add_ons(subscription.get("addOns", {}), keys)
    limits: dict[str, int | None] = {}
    for key in keys:
        number = base[key]
        limits[key] = None if number is None else number + add_ons.get(key, 0)
    features = dict(version.get("features") or {})
    valid_until: datetime | None = None
    for override in subscription.get("overrides") or []:
        expires = override["expiresAt"]
        if expires <= now:
            continue
        limits.update(_limits(override.get("limits", {}), partial=True, schema=schema))
        features.update(override.get("features") or {})
        valid_until = expires if valid_until is None else min(valid_until, expires)
    return {
        "planId": subscription["planId"],
        "planVersion": version["version"],
        "quotaSchemaVersion": schema,
        "name": version["name"],
        "edition": version["edition"],
        "limits": limits,
        "features": features,
        "prices": version.get("prices"),
        "billingInterval": subscription.get("billingInterval"),
        "renewsAt": subscription.get("renewsAt"),
        "trialEndsAt": subscription.get("trialEndsAt"),
        "revision": subscription.get("revision", 0),
        "validUntil": valid_until,
    }


LIMIT_WORDS = {
    "salesmen": "Salespeople", "supervisors": "Supervisors", "managers": "Managers", "admins": "Admins",
    "branchManagers": "Branch managers", "products": "Products",
}


def _amount(value: Any) -> str:
    return "no limit" if value is None else str(value)


def _limit_drop(key: str, current: Any, target: Any) -> list[str]:
    if _limit_not_lower(current, target):
        return []
    return [f"{LIMIT_WORDS.get(key, key)} would drop from {_amount(current)} to {_amount(target)}."]


def lower_entitlements(current: Mapping[str, Any], target: Mapping[str, Any]) -> list[str]:
    lower: list[str] = []
    if current.get("edition") == "advanced" and target.get("edition") != "advanced":
        lower.append("The edition would drop from advanced to basic.")
    current_features = current.get("features") or {}
    target_features = target.get("features") or {}
    for key, enabled in current_features.items():
        if enabled and not target_features.get(key, False):
            words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", key).replace("_", " ").lower()
            lower.append(f"The feature {words} would be switched off.")
    current_schema = current.get("quotaSchemaVersion", 1)
    target_schema = target.get("quotaSchemaVersion", 1)
    current_limits = current.get("limits") or {}
    target_limits = target.get("limits") or {}
    if current_schema == target_schema:
        for key in limit_keys(current_schema):
            lower += _limit_drop(key, current_limits.get(key), target_limits.get(key))
    elif current_schema == 1 and target_schema == 2:
        for key in ("salesmen", "supervisors", "products"):
            lower += _limit_drop(key, current_limits.get(key), target_limits.get(key))
        target_admins = target_limits.get("admins")
        target_branch_managers = target_limits.get("branchManagers")
        if target_admins is None or target_branch_managers is None:
            target_managers = None
        else:
            target_managers = target_admins + target_branch_managers
        lower += _limit_drop("managers", current_limits.get("managers"), target_managers)
    else:
        lower.append("This package uses a different limit scheme.")
    return lower


def carried_add_ons(add_ons: Mapping[str, Any] | None, from_schema: int, to_schema: int) -> dict[str, int]:
    add_ons = dict(add_ons or {})
    if from_schema == to_schema:
        return add_ons
    if (from_schema, to_schema) != (1, 2):
        return {}
    carried = {key: add_ons[key] for key in ("salesmen", "supervisors", "products") if key in add_ons}
    if "managers" in add_ons:
        carried["admins"] = add_ons["managers"]
    return carried


def _limit_not_lower(current: Any, target: Any) -> bool:
    if current is None:
        return target is None
    return target is None or target >= current


def jsonable(value: Any) -> Any:
    if isinstance(value, datetime):
        return format_timestamp(value)
    if isinstance(value, Mapping):
        return {key: jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    return value


def load_catalogue(path: Path = CATALOGUE_FILE) -> list[dict[str, Any]]:
    rows = json.loads(path.read_text(encoding="utf-8"))["plans"]
    return [
        {"planId": check_plan_id(row["planId"]), "visibility": clean_visibility(row["visibility"]),
         **clean_version(row)}
        for row in rows
    ]


def has_price(prices: Any) -> bool:
    return isinstance(prices, Mapping) and any(prices.get(name) is not None for name in ("monthly", "yearly"))


class PlanStore:
    def __init__(self, client: firestore.Client) -> None:
        self.client = client

    def _plan(self, plan_id: str) -> Any:
        return self.client.collection(PLANS).document(plan_id)

    def _subscription(self, tenant_id: str) -> Any:
        return self.client.collection(SUBSCRIPTIONS).document(tenant_id)

    def _operation_receipt(self, action: str, subject: str, operation_id: str) -> Any:
        digest = hashlib.sha256(f"{action}\n{subject}\n{operation_id}".encode()).hexdigest()
        return self.client.collection("plan_operation_receipts").document(digest)

    @staticmethod
    def _intent_hash(body: Mapping[str, Any]) -> str:
        return hashlib.sha256(json.dumps(jsonable(body), sort_keys=True, separators=(",", ":"),
                                         allow_nan=False).encode()).hexdigest()

    def get_plan(self, plan_id: str) -> dict[str, Any] | None:
        snapshot = self._plan(plan_id).get()
        return snapshot.to_dict() if snapshot.exists else None

    def get_plans(self, plan_ids: Any) -> dict[str, dict[str, Any] | None]:
        references = [self._plan(plan_id) for plan_id in dict.fromkeys(plan_ids)]
        if not references:
            return {}
        found = {snapshot.id: (snapshot.to_dict() if snapshot.exists else None)
                 for snapshot in self.client.get_all(references)}
        return {reference.id: found.get(reference.id) for reference in references}

    def get_version(self, plan_id: str, number: int) -> dict[str, Any] | None:
        snapshot = self._plan(plan_id).collection(VERSIONS).document(str(number)).get()
        return snapshot.to_dict() if snapshot.exists else None

    def get_versions(self, pairs: Any) -> dict[tuple[str, Any], dict[str, Any] | None]:
        wanted = list(dict.fromkeys(pairs))
        if not wanted:
            return {}
        references = {self._plan(plan_id).collection(VERSIONS).document(str(number)).path: (plan_id, number)
                      for plan_id, number in wanted}
        found = {references[snapshot.reference.path]: (snapshot.to_dict() if snapshot.exists else None)
                 for snapshot in self.client.get_all(
                     [self._plan(plan_id).collection(VERSIONS).document(str(number)) for plan_id, number in wanted])}
        return {key: found.get(key) for key in wanted}

    def list_plans(self) -> list[dict[str, Any]]:
        plans = [(snapshot.id, snapshot.to_dict() or {}) for snapshot in self.client.collection(PLANS).stream()]
        versions = self.get_versions((plan_id, plan["currentVersion"]) for plan_id, plan in plans)
        rows = [{**plan, "current": versions[(plan_id, plan["currentVersion"])]} for plan_id, plan in plans]
        return sorted(rows, key=lambda row: row["planId"])

    def public_plans(self) -> list[dict[str, Any]]:
        rows = []
        plans = [(snapshot.id, snapshot.to_dict() or {}) for snapshot in self.client.collection(PLANS).stream()]
        plans = [(plan_id, plan) for plan_id, plan in plans
                 if plan.get("status") == "active" and plan.get("visibility") == "public"]
        versions = self.get_versions((plan_id, plan["currentVersion"]) for plan_id, plan in plans)
        for plan_id, plan in plans:
            version = versions[(plan_id, plan["currentVersion"])]
            if version is not None:
                rows.append(
                    {
                        "planId": plan_id,
                        "quotaSchemaVersion": _schema(version),
                        "sortOrder": version.get("sortOrder") or 0,
                        **{key: version.get(key) for key in (
                            "name", "tagline", "edition", "limits", "prices", "highlights"
                        )},
                    }
                )
        rows.sort(key=lambda row: (row["sortOrder"], row["planId"]))
        return [{key: value for key, value in row.items() if key != "sortOrder"} for row in rows]

    def upgrade_refusal(
        self,
        tenant_id: str,
        plan_id: str,
        now: datetime | None = None,
        *,
        subscription: Mapping[str, Any] | None = None,
        effective: Mapping[str, Any] | None = None,
    ) -> str | None:
        current_subscription = subscription if subscription is not None else self.get_subscription(tenant_id)
        if current_subscription is None:
            return None
        target_plan = self.get_plan(plan_id)
        if target_plan is None:
            return UPGRADE_ONLY_MESSAGE
        target_version = self.get_version(plan_id, target_plan["currentVersion"])
        if target_version is None:
            return UPGRADE_ONLY_MESSAGE
        current = effective if effective is not None else self.effective_for(current_subscription, now)
        target_schema = _schema(target_version)
        current_schema = current.get("quotaSchemaVersion", 1)
        target_subscription = {
            **current_subscription,
            "planId": plan_id,
            "planVersion": target_plan["currentVersion"],
            "addOns": carried_add_ons(current_subscription.get("addOns"), current_schema, target_schema),
        }
        try:
            target = effective_plan(target_version, target_subscription, now or _utc_now())
        except HTTPException:
            return UPGRADE_ONLY_MESSAGE
        lower = lower_entitlements(current, target)
        return " ".join(lower) if lower else None

    @staticmethod
    def request_is_open(prior: Mapping[str, Any], current: Mapping[str, Any]) -> bool:
        if prior.get("status") != "requested":
            return False
        return not PlanStore.request_is_met(prior, current)

    @staticmethod
    def request_is_met(prior: Mapping[str, Any], current: Mapping[str, Any]) -> bool:
        return (current.get("planId") == prior.get("planId")
                and current.get("billingInterval") == prior.get("interval"))

    def create_plan_request(
        self,
        *,
        tenant_id: str,
        plan_id: str,
        interval: str,
        requested_by: str,
        key: str,
        now: datetime,
        requester_email: str | None = None,
    ) -> dict[str, Any]:
        digest = hashlib.sha256(f"{tenant_id}\n{key}".encode()).hexdigest()[:32]
        reference = self.client.collection(PLAN_REQUESTS).document(tenant_id)
        history = reference.collection(PLAN_REQUEST_HISTORY).document(digest)
        fields = {"tenantId": tenant_id, "planId": plan_id, "interval": interval}
        subscription = self._subscription(tenant_id)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            prior = snapshot.to_dict() if snapshot.exists else {}
            current = subscription.get(transaction=transaction).to_dict() or {}
            if self.request_is_open(prior, current):
                if prior.get("requestKey") == digest and all(prior.get(n) == v for n, v in fields.items()):
                    return {"requestId": tenant_id, "created": False, "notice": False, "key": digest}
                raise CommandProblem(OPEN_REQUEST_MESSAGE)
            last_notice = prior.get("lastNoticeAt")
            notice = not isinstance(last_notice, datetime) or now - last_notice >= NOTICE_INTERVAL
            row = {
                **fields, "status": "requested", "requestedBy": requested_by, "createdAt": now,
                "requestKey": digest, "lastNoticeAt": now if notice else last_notice,
                "subscriptionRevision": current.get("revision", 0), "requesterEmail": requester_email,
            }
            transaction.set(reference, row)
            transaction.set(history, {key_: value for key_, value in row.items() if key_ != "lastNoticeAt"})
            return {"requestId": tenant_id, "created": True, "notice": notice, "key": digest}

        return write(self.client.transaction(max_attempts=10))

    def decline_plan_request(self, tenant_id: str, *, reason: str, decided_by: str, now: datetime) -> dict[str, Any]:
        reference = self.client.collection(PLAN_REQUESTS).document(tenant_id)
        subscription = self._subscription(tenant_id)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            prior = snapshot.to_dict() if snapshot.exists else {}
            current = subscription.get(transaction=transaction).to_dict() or {}
            if not self.request_is_open(prior, current):
                raise CommandProblem("This company has no open plan request.")
            decision = {"status": "declined", "declineReason": reason, "decidedBy": decided_by, "decidedAt": now}
            transaction.update(reference, decision)
            transaction.update(reference.collection(PLAN_REQUEST_HISTORY).document(prior["requestKey"]), decision)
            return {**prior, **decision}

        return write(self.client.transaction(max_attempts=10))

    def mail_plan_request_declined(self, mail: Any, *, request: Mapping[str, Any], company_name: str) -> dict[str, Any]:
        email = request.get("requesterEmail")
        if not email:
            return {"status": "skipped", "jobId": None, "reason": "The requester has no email address."}
        plan = self.get_plan(request["planId"]) or {}
        version = self.get_version(request["planId"], plan.get("currentVersion")) if plan else None
        return mail.enqueue_or_report(
            request["tenantId"], f"planreq-declined-{request['requestKey']}", "plan_request_declined", email,
            {"tenantId": request["tenantId"], "companyName": company_name,
             "planName": (version or {}).get("name") or request["planId"], "reason": request["declineReason"]},
            request["decidedBy"])

    def approved_request(self, tenant_id: str, operation_id: str) -> dict[str, Any] | None:
        snapshot = self.client.collection(PLAN_REQUESTS).document(tenant_id).get()
        stored = snapshot.to_dict() if snapshot.exists else None
        if not stored or stored.get("status") != "approved" or stored.get("decidedOperation") != operation_id:
            return None
        return stored

    def mail_plan_request_approved(self, mail: Any, *, request: Mapping[str, Any], company_name: str) -> dict[str, Any]:
        email = request.get("requesterEmail")
        if not email:
            return {"status": "skipped", "jobId": None, "reason": "The requester has no email address."}
        plan = self.get_plan(request["planId"]) or {}
        version = self.get_version(request["planId"], plan.get("currentVersion")) if plan else None
        return mail.enqueue_or_report(
            request["tenantId"], f"planreq-approved-{request['requestKey']}", "plan_request_approved", email,
            {"tenantId": request["tenantId"], "companyName": company_name,
             "planName": (version or {}).get("name") or request["planId"], "interval": request["interval"]},
            request.get("decidedBy") or "staff")

    def mail_plan_request(
        self, mail: Any, *, request: Mapping[str, Any], company_name: str, requester_email: str | None
    ) -> None:
        if not request["created"]:
            return
        try:
            reference = self.client.collection(PLAN_REQUESTS).document(request["requestId"])
            stored = reference.get().to_dict() or {}
            plan = self.get_plan(stored["planId"]) or {}
            version = self.get_version(stored["planId"], plan.get("currentVersion")) if plan else None
            plan_name = (version or {}).get("name") or stored["planId"]
            tenant_id, interval = stored["tenantId"], stored["interval"]
            actor = stored.get("requestedBy") or "client"
            if requester_email:
                received = mail.enqueue_or_report(
                    tenant_id, f"planreq-received-{request['key']}", "plan_request_received", requester_email,
                    {"tenantId": tenant_id, "companyName": company_name, "planName": plan_name,
                     "interval": interval}, actor)
            else:
                received = {"status": "skipped", "jobId": None,
                            "reason": "The requester has no email address."}
            if not request["notice"]:
                notice = {"status": "skipped", "jobId": None,
                          "reason": "An ops notice was sent in the last 24 hours."}
            elif config.OPS_EMAIL:
                notice = mail.enqueue_or_report(
                    tenant_id, f"planreq-notice-{request['key']}", "plan_request_notice", config.OPS_EMAIL,
                    {"tenantId": tenant_id, "companyName": company_name,
                     "requesterEmail": requester_email or "not available", "planName": plan_name,
                     "interval": interval, "requestedAt": format_timestamp(stored["createdAt"])}, actor)
            else:
                notice = {"status": "skipped", "jobId": None, "reason": "PLATFORM_OPS_EMAIL is not set."}
            reference.update({"mail": {"received": received, "notice": notice}})
        except Exception as error:
            logging.getLogger(__name__).error("plan request mail failed: %s", type(error).__name__)

    def get_subscription(self, tenant_id: str) -> dict[str, Any] | None:
        snapshot = self._subscription(tenant_id).get()
        return snapshot.to_dict() if snapshot.exists else None

    def get_subscriptions(self, tenant_ids: Any) -> dict[str, dict[str, Any] | None]:
        references = [self._subscription(tenant_id) for tenant_id in dict.fromkeys(tenant_ids)]
        if not references:
            return {}
        found = {snapshot.id: (snapshot.to_dict() if snapshot.exists else None)
                 for snapshot in self.client.get_all(references)}
        return {reference.id: found.get(reference.id) for reference in references}

    def subscription_written_by(self, tenant_id: str, operation_id: str) -> bool:
        if self._operation_receipt("subscription.change", tenant_id, operation_id).get().exists:
            return True
        current = self.get_subscription(tenant_id)
        return bool(current and current.get("lastOperationId") == operation_id)

    def list_subscriptions(self) -> list[dict[str, Any]]:
        return [snapshot.to_dict() or {} for snapshot in self.client.collection(SUBSCRIPTIONS).stream()]

    def effective(self, tenant_id: str, now: datetime | None = None) -> dict[str, Any]:
        subscription = self.get_subscription(tenant_id)
        if subscription is None:
            raise PlanMissing("This company has no package yet. Choose a package for it on the company page first.")
        return self.effective_for(subscription, now)

    def effective_for(self, subscription: Mapping[str, Any], now: datetime | None = None) -> dict[str, Any]:
        number = self.version_in_effect(subscription)
        version = self.get_version(subscription["planId"], number) if number else None
        if version is None:
            raise PlanMissing("This company's plan could not be found. Ask support for help.")
        return effective_plan(version, subscription, now or _utc_now())

    def version_in_effect(self, subscription: Mapping[str, Any], transaction: Any = None) -> int | None:
        number = subscription.get("planVersion")
        if number is not None:
            return number
        written = subscription.get("updatedAt")
        if written is None:
            return None
        rows = self._plan(subscription["planId"]).collection(VERSIONS).get(transaction=transaction)
        published = [row.to_dict() or {} for row in rows]
        in_effect = max((row["version"] for row in published
                         if row.get("createdAt") is not None and row["createdAt"] <= written), default=None)
        if in_effect is None:
            return min((row["version"] for row in published if "version" in row), default=None)
        return in_effect

    def write_version(
        self,
        plan_id: str,
        content: Mapping[str, Any],
        *,
        created_by: str,
        visibility: str | None = None,
        operation_id: str | None = None,
        skip_if_same: bool = False,
        seed_preserve_existing: bool = False,
        based_on_version: int | None = None,
        price_locked: bool = False,
        now: datetime | None = None,
        seal: Callable[[firestore.Transaction], None] | None = None,
    ) -> tuple[int, bool]:
        moment = now or _utc_now()
        plan_ref = self._plan(plan_id)
        receipt = self._operation_receipt("plan.put", plan_id, operation_id) if operation_id else None
        intent_hash = self._intent_hash({"content": content, "visibility": visibility,
            "skipIfSame": skip_if_same, "seedPreserveExisting": seed_preserve_existing})
        if seed_preserve_existing:
            _limits(content.get("limits"), partial=False, schema=_schema(content))
            initial = self.client.batch()
            initial.create(plan_ref, {
                "planId": plan_id, "currentVersion": 1, "updatedAt": moment,
                "lastOperationId": operation_id, "status": "active",
                "visibility": visibility or "public",
            })
            initial.create(plan_ref.collection(VERSIONS).document("1"), {
                "version": 1, **content, "createdAt": moment, "createdBy": created_by,
            })
            if receipt is not None:
                initial.create(receipt, {"intentHash": intent_hash, "version": 1})
            try:
                initial.commit()
                return 1, True
            except gcloud_exceptions.AlreadyExists:
                pass

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> tuple[int, bool]:
            prior = receipt.get(transaction=transaction) if receipt is not None else None
            if prior is not None and prior.exists:
                stored_receipt = prior.to_dict() or {}
                if stored_receipt.get("intentHash") != intent_hash:
                    raise CommandProblem("The plan operation already has different content.")
                return stored_receipt["version"], False
            snapshot = plan_ref.get(transaction=transaction)
            plan = snapshot.to_dict() if snapshot.exists else None
            current = plan["currentVersion"] if plan else 0
            if plan and operation_id and plan.get("lastOperationId") == operation_id:
                transaction.create(receipt, {"intentHash": intent_hash, "version": current})
                return current, False
            if based_on_version is not None and current != based_on_version:
                raise CommandProblem("The package changed since this was requested. Send a new request.")
            _limits(content.get("limits"), partial=False, schema=_schema(content))
            if plan and seed_preserve_existing:
                if visibility and plan.get("visibility") != visibility:
                    transaction.update(plan_ref, {"visibility": visibility, "updatedAt": moment})
                if receipt is not None:
                    transaction.create(receipt, {"intentHash": intent_hash, "version": current})
                return current, False
            if plan:
                stored = (
                    plan_ref.collection(VERSIONS).document(str(current)).get(transaction=transaction)
                ).to_dict() or {}
                if _schema(stored) != _schema(content):
                    raise CommandProblem("A plan ID cannot change quota schema. Create a new plan ID.")
            if price_locked and plan and has_price(stored.get("prices")) and stored.get("prices") != content.get("prices"):
                raise CommandProblem("This package already has a price. Changing it needs approval. Reload the page.")
            if price_locked and not plan and has_price(content.get("prices")):
                raise CommandProblem("A new package with a price needs approval.")
            if plan and skip_if_same:
                if all(stored.get(key) == value for key, value in content.items()):
                    if visibility and plan.get("visibility") != visibility:
                        transaction.update(plan_ref, {"visibility": visibility, "updatedAt": moment})
                    if receipt is not None:
                        transaction.create(receipt, {"intentHash": intent_hash, "version": current})
                    return current, False
            number = current + 1
            transaction.create(
                plan_ref.collection(VERSIONS).document(str(number)),
                {"version": number, **content, "createdAt": moment, "createdBy": created_by},
            )
            fields: dict[str, Any] = {
                "planId": plan_id,
                "currentVersion": number,
                "updatedAt": moment,
                "lastOperationId": operation_id,
            }
            if plan is None:
                fields["status"] = "active"
                fields["visibility"] = visibility or "public"
            elif visibility:
                fields["visibility"] = visibility
            transaction.set(plan_ref, fields, merge=True)
            if receipt is not None:
                transaction.create(receipt, {"intentHash": intent_hash, "version": number})
            if seal is not None:
                seal(transaction)
            return number, True

        return write(self.client.transaction())

    def version_written_by(self, plan_id: str, operation_id: str) -> bool:
        if self._operation_receipt("plan.put", plan_id, operation_id).get().exists:
            return True
        plan = self.get_plan(plan_id)
        return bool(plan and plan.get("lastOperationId") == operation_id)

    def retire(self, plan_id: str, *, operation_id: str, now: datetime | None = None) -> None:
        plan_ref = self._plan(plan_id)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> None:
            snapshot = plan_ref.get(transaction=transaction)
            if not snapshot.exists:
                raise CommandProblem("Unknown plan.")
            transaction.update(
                plan_ref,
                {"status": "retired", "updatedAt": now or _utc_now(), "lastOperationId": operation_id},
            )

        write(self.client.transaction())

    def apply_subscription_change(
        self,
        tenant_id: str,
        change: Mapping[str, Any],
        *,
        operation_id: str,
        now: datetime,
        seal: Callable[[firestore.Transaction], None] | None = None,
        decided_by: str | None = None,
    ) -> int:
        reference = self._subscription(tenant_id)
        receipt = self._operation_receipt("subscription.change", tenant_id, operation_id)
        intent_hash = self._intent_hash(change)
        request_ref = self.client.collection(PLAN_REQUESTS).document(tenant_id)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> int:
            prior = receipt.get(transaction=transaction)
            if prior.exists:
                stored_receipt = prior.to_dict() or {}
                if stored_receipt.get("intentHash") != intent_hash:
                    raise CommandProblem("The subscription operation already has a different intent.")
                return stored_receipt["revision"]
            snapshot = reference.get(transaction=transaction)
            current = snapshot.to_dict() if snapshot.exists else None
            if current and current.get("lastOperationId") == operation_id:
                transaction.create(receipt, {"intentHash": intent_hash, "revision": int(current["revision"])})
                return int(current["revision"])
            revision = int(current["revision"]) if current else 0
            kind = change["kind"]
            request_snapshot = request_ref.get(transaction=transaction) if kind == "put" else None
            open_request = (request_snapshot.to_dict() or {}) if request_snapshot and request_snapshot.exists else {}
            current_effective = None
            current_version = None
            if current is not None:
                current_number = self.version_in_effect(current, transaction)
                if current_number is not None:
                    current_snapshot = self._plan(current["planId"]).collection(VERSIONS).document(
                        str(current_number)
                    ).get(transaction=transaction)
                    current_version = current_snapshot.to_dict() if current_snapshot.exists else None
                if current_version is None:
                    raise CommandProblem("This company's current plan could not be found.")
                try:
                    current_effective = effective_plan(current_version, current, now)
                except HTTPException as error:
                    raise CommandProblem(str(error.detail)) from None
            if kind == "put":
                if change.get("expectedRevision") not in (None, revision):
                    raise CommandProblem(
                        "This subscription changed since you loaded it. Reload and try again."
                    )
                plan = self._plan(change["planId"]).get(transaction=transaction)
                if not plan.exists:
                    raise CommandProblem("Unknown plan.")
                if (plan.to_dict() or {}).get("status") == "retired" and (
                    not current or current.get("planId") != change["planId"]
                ):
                    raise CommandProblem("That plan is retired.")
                resolved = change["planVersion"] if change["planVersion"] is not None else (plan.to_dict() or {})["currentVersion"]
                target = self._plan(change["planId"]).collection(VERSIONS).document(str(resolved)).get(transaction=transaction)
                if not target.exists:
                    raise CommandProblem("That plan version does not exist.")
                target_version = target.to_dict() or {}
                if current and "addOns" not in change:
                    if _schema(current_version or {}) != _schema(target_version):
                        raise CommandProblem("Changing quota schemas requires an explicit compatible add-on agreement.")
                document: dict[str, Any] = {
                    "tenantId": tenant_id,
                    "planId": change["planId"],
                    "planVersion": resolved,
                    "addOns": dict(change.get("addOns", (current or {}).get("addOns", {}))),
                    "billingInterval": change["billingInterval"],
                    "renewsAt": _parse(change["renewsAt"]),
                    "trialEndsAt": _parse(change["trialEndsAt"]),
                    "overrides": list((current or {}).get("overrides") or []),
                }
            else:
                if current is None:
                    raise CommandProblem("This company has no subscription yet.")
                document = dict(current)
                document["planVersion"] = current_number
                target_version = current_version
                if kind == "override":
                    override = dict(change["override"])
                    override["expiresAt"] = _parse(override["expiresAt"])
                    override["createdAt"] = _parse(override["createdAt"])
                    document["overrides"] = [*document.get("overrides", []), override]
            live = [item for item in document["overrides"] if item["expiresAt"] > now]
            if len(live) > MAX_OVERRIDES:
                raise CommandProblem("This company has too many active overrides.")
            document["overrides"] = live
            try:
                target_effective = effective_plan(target_version, document, now)
            except HTTPException as error:
                raise CommandProblem(str(error.detail)) from None
            lower = lower_entitlements(current_effective, target_effective) if current_effective is not None else []
            if lower:
                raise CommandProblem(" ".join(lower))
            document["validUntil"] = min((item["expiresAt"] for item in live), default=None)
            if current is None or current.get("planId") != document["planId"]:
                document["planSetAt"] = now
            else:
                document["planSetAt"] = current.get("planSetAt") or current.get("updatedAt")
            document["revision"] = revision + 1
            document["updatedAt"] = now
            document["lastOperationId"] = operation_id
            transaction.set(reference, document)
            transaction.create(receipt, {"intentHash": intent_hash, "revision": revision + 1})
            if open_request.get("status") == "requested" and self.request_is_met(open_request, document):
                decision = {"status": "approved", "decidedBy": decided_by or "staff", "decidedAt": now,
                            "decidedOperation": operation_id}
                transaction.update(request_ref, decision)
                if open_request.get("requestKey"):
                    transaction.set(request_ref.collection(PLAN_REQUEST_HISTORY).document(
                        open_request["requestKey"]), decision, merge=True)
            if seal is not None:
                seal(transaction)
            return revision + 1

        return write(self.client.transaction())


def _parse(text: str | None) -> datetime | None:
    return None if text is None else parse_timestamp(text)

from __future__ import annotations

import hashlib
import re
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Callable, Mapping

from fastapi import HTTPException, status
from google.api_core.exceptions import Aborted
from google.cloud import firestore

from .audit import AuditLog
from .directory import CLAIMS as DIRECTORY_CLAIMS
from .directory import COMPANIES, clean_billing_email
from .ids import utc_now
from .operations import is_busy
from .plans import BILLING_INTERVALS
from .records import RecordError, check_legal_name, check_workspace, workspace_skeleton
from .signing import format_timestamp, parse_timestamp

DRAFTS = "onboarding_drafts"
CLAIMS = "onboarding_claims"
DRAFT_DAYS = 30
EXTENSION_DAYS = 30
STEPS = (
    ("details", "Company details"),
    ("project", "Firebase project"),
    ("people", "People and data"),
    ("package", "Package"),
    ("payment", "First payment"),
    ("admin", "First administrator"),
    ("rules", "Scoot rules"),
    ("open", "Open the company"),
)
TOTAL = len(STEPS)
OPEN_STATES = ("active", "past_due")
STATE_WORDS = {"lead": "being set up", "active": "active", "past_due": "past due", "suspended": "suspended",
               "expired": "expired", "cancelled": "cancelled"}
DETAIL_FIELDS = (("legalName", "company name"), ("workspace", "company code"),
                 ("planId", "package"), ("billingInterval", "billing period"), ("billingEmail", "billing email"),
                 ("adminName", "administrator name"), ("adminEmail", "administrator email"),
                 ("adminEmployeeCode", "administrator employee code"))
ADMIN_FIELDS = frozenset({"tradingName", "billingEmail", "adminName", "adminEmail", "adminEmployeeCode"})
BUTTONS = {
    "edit_details": ("Edit details", ("owner", "operator")),
    "connect_project": ("Connect project", ("owner", "engineer")),
    "check_again": ("Check again", ("owner", "operator", "engineer")),
    "fix_people": ("Fix people", ("owner",)),
    "prepare": ("Prepare company data", ("owner",)),
    "resume_prepare": ("Resume preparation", ("owner",)),
    "apply_package": ("Apply package", ("owner", "operator")),
    "finish_package": ("Finish package", ("owner", "operator")),
    "create_invoice": ("Create first invoice", ("owner", "operator")),
    "issue_invoice": ("Issue invoice", ("owner", "operator")),
    "record_payment": ("Record payment", ("owner", "operator")),
    "check_payment": ("Check payment", ("owner", "operator")),
    "give_access": ("Give access", ("owner", "operator")),
    "resend_invitation": ("Resend invitation", ("owner", "operator")),
    "install_rules": ("Install Scoot rules", ("owner",)),
    "make_active": ("Make active", ("owner", "operator")),
}
_EMPLOYEE_CODE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
FIELDS = frozenset({"legalName", "tradingName", "workspace", "planId", "billingInterval", "billingEmail",
                    "adminName", "adminEmail", "adminEmployeeCode"})
SETUP_FIELDS = frozenset({"location", "locationKind", "clientConfig", "rulesVersion", "releaseRing", "services",
                          "setup"})
OPEN, CANCELLED, EXPIRED, COMPLETED, COMPLETING = "open", "cancelled", "expired", "completed", "completing"
STATES = (OPEN, CANCELLED, EXPIRED, COMPLETED)
ENDED_STATES = (CANCELLED, EXPIRED)
LIST_WORKERS = 8
_DRAFT_ID = re.compile(r"^drf_[0-9a-f]{20}$")
_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]+$")
_TEXT = re.compile(r"^[^\x00-\x1f\x7f]{1,120}$")
_TAKEN = "That workspace code is already in use or too close to another company's code."


def _bad(message: str) -> HTTPException:
    return HTTPException(status.HTTP_400_BAD_REQUEST, message)


def _conflict(message: str) -> HTTPException:
    return HTTPException(status.HTTP_409_CONFLICT, message)


def draft_id_for(key: str) -> str:
    return "drf_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:20]


@dataclass(frozen=True)
class Reads:
    record: Callable[[str], Mapping[str, Any] | None]
    lifecycle: Callable[[str], str | None]
    project: Callable[[Mapping[str, Any]], None]
    people: Callable[[str], Mapping[str, Any]]
    package: Callable[[str], Mapping[str, Any]]
    payment: Callable[[str], Mapping[str, Any]]
    admin: Callable[[str, str], Mapping[str, Any]]
    rules: Callable[[str], Mapping[str, Any]]


class RulesUnreadable(Exception):
    def __init__(self, line: str) -> None:
        super().__init__(line)
        self.detail = line


def _unknown_line(error: Exception) -> str:
    detail = getattr(error, "detail", None)
    message = detail if isinstance(detail, str) else (str(error) if type(error).__name__ == "CommandProblem" else "")
    if message:
        return f"Unknown. Scoot could not read this now: {message[:160]}"
    return f"Unknown. Scoot could not read this now ({type(error).__name__})."


class _Run:
    def __init__(self, data: Mapping[str, Any], reads: Reads | None, now: str) -> None:
        self.data = data
        self.reads = reads
        self.now = now
        self.tenant = data.get("tenantId") or data.get("completingTenant")
        self._memo: dict[tuple[Any, ...], tuple[bool, Any]] = {}

    def read(self, name: str, *args: Any) -> Any:
        key = (name, repr(args))
        if key not in self._memo:
            try:
                if self.reads is None:
                    raise RuntimeError("Company facts cannot be read here.")
                self._memo[key] = (True, getattr(self.reads, name)(*args))
            except Exception as error:
                self._memo[key] = (False, error)
        ok, value = self._memo[key]
        if not ok:
            raise value
        return value

    def record(self) -> Mapping[str, Any] | None:
        return self.read("record", self.tenant)

    def lifecycle(self) -> str | None:
        return self.read("lifecycle", self.tenant)


def _waiting(number: int) -> tuple[bool, str, None]:
    return False, f"Waiting for step {number}.", None


def _step_details(run: _Run) -> tuple[bool | None, str, str | None]:
    missing = [label for name, label in DETAIL_FIELDS if not run.data.get(name)]
    if missing:
        return False, "Missing: " + ", ".join(missing) + ".", "edit_details"
    return True, "All company details are filled in.", None


def _step_project(run: _Run) -> tuple[bool | None, str, str | None]:
    if not run.tenant:
        return False, "No company record yet. Connect the Firebase project.", "connect_project"
    record = run.record()
    if record is None:
        return False, "The company record is missing. Connect the Firebase project again.", "connect_project"
    state = run.lifecycle()
    if state is None:
        return False, "The company has no status yet. Connect the Firebase project again.", "connect_project"
    try:
        run.read("project", record)
    except Exception as error:
        return None, _unknown_line(error), "connect_project"
    project = (record.get("location") or {}).get("projectId")
    return True, f"Scoot reads the project {project} now. The company is {STATE_WORDS.get(state, state)}.", None


def _step_people(run: _Run) -> tuple[bool | None, str, str | None]:
    if not run.tenant:
        return _waiting(2)
    people = run.read("people", run.tenant)
    if people.get("running"):
        return False, "A preparation is running. Wait until it finishes, then check again.", None
    if people["halfDone"]:
        return False, "A preparation stopped half-way. Resume it to finish.", "resume_prepare"
    blockers = people["blockers"]
    if blockers:
        more = f" ({len(blockers) - 1} more problem{'s' if len(blockers) > 2 else ''})" if len(blockers) > 1 else ""
        return False, f"{blockers[0]}{more}", "fix_people"
    if not people["prepared"]:
        moves = people.get("moves", 0)
        note = f" Prepare moves {moves} record{'s' if moves != 1 else ''} to the sign-in id." if moves else ""
        return False, "Company data is not prepared." + note, "prepare"
    return True, "Company data is prepared. No people problems found.", None


PACKAGE_PARTS = (("subscription", "subscription"), ("projected", "company limits"), ("recorded", "company record"))


def _step_package(run: _Run) -> tuple[bool | None, str, str | None]:
    if not run.tenant:
        return _waiting(2)
    package = run.read("package", run.tenant)
    saved = [label for key, label in PACKAGE_PARTS if package[key]]
    pending = [label for key, label in PACKAGE_PARTS if not package[key]]
    if not pending:
        return True, f"Package {package.get('planId')} is in the subscription, the company limits and the company record.", None
    if not saved:
        return False, "No package is applied yet.", "apply_package"
    return False, f"Saved: {', '.join(saved)}. Not finished: {', '.join(pending)}.", "finish_package"


def _step_payment(run: _Run) -> tuple[bool | None, str, str | None]:
    if not run.tenant:
        return _waiting(2)
    payment = run.read("payment", run.tenant)
    if payment["checked"]:
        return True, "A checked payment covers today.", None
    if payment["awaitingCheck"]:
        return False, "A payment is recorded. A second person must check it.", "check_payment"
    if payment.get("coverStarts"):
        return False, (f"The payment is recorded and checked. Cover starts on {payment['coverStarts']}. "
                       "This step turns green on that day."), None
    if payment["issued"]:
        return False, "The first invoice is issued. Record the payment.", "record_payment"
    if payment["invoice"]:
        return False, "The first invoice is a draft. Issue it before you record the payment.", "issue_invoice"
    return False, "No invoice yet. Create the first invoice.", "create_invoice"


def _step_admin(run: _Run) -> tuple[bool | None, str, str | None]:
    if not run.tenant:
        return _waiting(2)
    email = run.data.get("adminEmail")
    if not email:
        return False, "The draft has no administrator email.", "edit_details"
    admin = run.read("admin", run.tenant, email)
    if admin["state"] == "active":
        return True, f"{email} is an active administrator.", None
    if admin["state"] == "invited":
        return False, f"An invitation was sent to {email}. The person has not accepted it yet.", "resend_invitation"
    return False, admin["line"], "give_access"


def _step_rules(run: _Run) -> tuple[bool | None, str, str | None]:
    if not run.tenant:
        return _waiting(2)
    rules = run.read("rules", run.tenant)
    if rules["state"] == "match":
        return True, "The deployed rules are the rules of this release.", None
    if rules["state"] == "unreadable":
        raise RulesUnreadable(rules["line"])
    return False, rules["line"], "install_rules"


def _step_open(run: _Run) -> tuple[bool | None, str, str | None]:
    if not run.tenant:
        return _waiting(2)
    state = run.lifecycle()
    if state in OPEN_STATES:
        return True, f"The company is {STATE_WORDS[state]}.", None
    if state == "lead":
        return False, "The company is not open yet.", "make_active"
    return False, f"The company is {STATE_WORDS.get(state, 'not open')}.", None


STEP_FUNCTIONS = (_step_details, _step_project, _step_people, _step_package, _step_payment, _step_admin,
                  _step_rules, _step_open)


def _button(identifier: str | None) -> dict[str, Any] | None:
    if identifier is None:
        return None
    label, roles = BUTTONS[identifier]
    return {"id": identifier, "label": label, "roles": list(roles)}


def _compute_step(number: int, run: _Run) -> dict[str, Any]:
    try:
        ok, fact, button = STEP_FUNCTIONS[number - 1](run)
    except Exception as error:
        ok, fact, button = None, _unknown_line(error), "check_again"
    item = _item(number, run, ok, fact, button)
    if button == "finish_package":
        item["operationId"] = run.read("package", run.tenant).get("operationId")
    return item


def _item(number: int, run: _Run, ok: bool | None, fact: str, button: str | None) -> dict[str, Any]:
    key, label = STEPS[number - 1]
    return {"n": number, "key": key, "label": label, "ok": ok, "fact": fact, "checkedAt": run.now,
            "button": _button(button)}


def _past_setup(run: _Run) -> bool:
    try:
        return run.lifecycle() not in (None, "lead")
    except Exception:
        return False


def _public_steps(computed: list[dict[str, Any]]) -> list[dict[str, Any]]:
    steps = []
    earlier_green = True
    for item in computed:
        green = item["ok"] is True
        state = "green" if green else ("red" if item["ok"] is False and earlier_green else "grey")
        steps.append({"n": item["n"], "key": item["key"], "label": item["label"], "state": state,
                      "unknown": item["ok"] is None, "fact": item["fact"], "checkedAt": item["checkedAt"],
                      "button": None if green else item["button"],
                      **({"operationId": item["operationId"]} if item.get("operationId") else {})})
        earlier_green = earlier_green and green
    return steps


def refusal_for(step: Mapping[str, Any], total_before: int) -> str:
    span = "step 1" if total_before == 1 else f"steps 1 to {total_before}"
    verb = "is" if total_before == 1 else "are"
    return (f"The company opens only when {span} {verb} green. Step {step['n']} ({step['label']}) is not: "
            f"{step['fact']}")


class OnboardingDrafts:
    def __init__(self, db: firestore.Client, audit: AuditLog, *,
                 package_check: Callable[[Any], Mapping[str, Any]] | None = None,
                 reads: Reads | None = None,
                 clock: Callable[[], datetime] = utc_now) -> None:
        self.db = db
        self.audit = audit
        self.package_check = package_check
        self.reads = reads
        self.clock = clock

    def _ref(self, draft_id: str) -> Any:
        if not _DRAFT_ID.fullmatch(draft_id):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Draft not found.")
        return self.db.collection(DRAFTS).document(draft_id)

    @staticmethod
    def _claim_names(workspace: str) -> list[str]:
        return [f"workspace:{workspace}", f"skeleton:{workspace_skeleton(workspace)}"]

    def _read_claims(self, transaction: firestore.Transaction, workspace: str) -> dict[str, Any]:
        names = self._claim_names(workspace)
        held = {name: self.db.collection(CLAIMS).document(name).get(transaction=transaction) for name in names}
        directory = [self.db.collection(DIRECTORY_CLAIMS).document(name).get(transaction=transaction)
                     for name in (*names, f"code:{workspace}")]
        return {"held": held, "directory": directory}

    def _check_free(self, claims: Mapping[str, Any], draft_id: str) -> None:
        if any(snapshot.exists for snapshot in claims["directory"]):
            raise _conflict(_TAKEN)
        for snapshot in claims["held"].values():
            if snapshot.exists and (snapshot.to_dict() or {}).get("draftId") != draft_id:
                raise _conflict(_TAKEN)

    def _claim(self, transaction: firestore.Transaction, workspace: str, draft_id: str) -> None:
        for name in self._claim_names(workspace):
            transaction.set(self.db.collection(CLAIMS).document(name), {"draftId": draft_id})

    def _release(self, transaction: firestore.Transaction, claims: Mapping[str, Any], draft_id: str) -> None:
        for name, snapshot in claims["held"].items():
            if snapshot.exists and (snapshot.to_dict() or {}).get("draftId") == draft_id:
                transaction.delete(self.db.collection(CLAIMS).document(name))

    def _clean(self, body: Mapping[str, Any], *, required: bool) -> dict[str, Any]:
        if set(body) & SETUP_FIELDS:
            raise _bad("Setup details are entered by the engineer when setup is completed.")
        if set(body) - FIELDS:
            raise _bad("Unknown draft field.")
        if required and not {"legalName", "workspace"} <= set(body):
            raise _bad("Supply legalName and workspace.")
        fields: dict[str, Any] = {}
        try:
            if "legalName" in body:
                fields["legalName"] = check_legal_name(body["legalName"])
            if "workspace" in body:
                fields["workspace"] = check_workspace(body["workspace"])
        except RecordError as error:
            raise _bad(str(error)) from error
        for name in ("tradingName", "adminName"):
            if name in body:
                value = body[name]
                if value is None:
                    fields[name] = None
                elif not isinstance(value, str) or not _TEXT.fullmatch(value.strip()):
                    raise _bad(f"{name} must be 1 to 120 characters.")
                else:
                    fields[name] = value.strip()
        if "adminEmployeeCode" in body:
            value = body["adminEmployeeCode"]
            if value is None:
                fields["adminEmployeeCode"] = None
            elif not isinstance(value, str) or not _EMPLOYEE_CODE.fullmatch(value.strip()):
                raise _bad("Enter an employee code of 1 to 32 letters, digits, dots, dashes or underscores.")
            else:
                fields["adminEmployeeCode"] = value.strip()
        if "adminEmail" in body:
            value = body["adminEmail"]
            if value is None:
                fields["adminEmail"] = None
            elif not isinstance(value, str) or len(value) > 254 or not _EMAIL.fullmatch(value.strip()):
                raise _bad("Enter a valid administrator email.")
            else:
                fields["adminEmail"] = value.strip()
        if "billingEmail" in body:
            try:
                fields["billingEmail"] = clean_billing_email(body["billingEmail"])
            except Exception as error:
                raise _bad("Enter a valid billing email.") from error
        if "planId" in body:
            if body["planId"] is None:
                fields["planId"] = None
            else:
                if self.package_check is None:
                    raise _bad("Packages cannot be checked here.")
                fields["planId"] = self.package_check(body["planId"])["planId"]
        if "billingInterval" in body:
            if body["billingInterval"] is not None and body["billingInterval"] not in BILLING_INTERVALS:
                raise _bad("Choose a monthly or yearly billing period.")
            fields["billingInterval"] = body["billingInterval"]
        return fields

    def create(self, actor: str, key: str, body: Mapping[str, Any]) -> dict[str, Any]:
        fields = self._clean(body, required=True)
        draft_id = draft_id_for(key)
        reference = self._ref(draft_id)
        moment = self.clock()
        now = format_timestamp(moment)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            existing = reference.get(transaction=transaction)
            if existing.exists:
                data = existing.to_dict() or {}
                if data.get("createdBy") != actor or any(data.get(name) != value for name, value in fields.items()):
                    raise _conflict("This idempotency key was already used for a different request.")
                return data
            claims = self._read_claims(transaction, fields["workspace"])
            self._check_free(claims, draft_id)
            staged = self.audit.stage(transaction, moment)
            data = {"draftId": draft_id, "status": OPEN, "tradingName": None, "planId": None,
                    "billingInterval": None, "billingEmail": None, "adminName": None, "adminEmail": None,
                    "adminEmployeeCode": None, **fields, "createdBy": actor, "createdAt": now, "updatedAt": now,
                    "endsAt": format_timestamp(moment + timedelta(days=DRAFT_DAYS)), "extensions": 0,
                    "tenantId": None}
            transaction.create(reference, data)
            self._claim(transaction, fields["workspace"], draft_id)
            staged.add(actor=actor, action="onboarding.created", tenant_id=None, key=f"onboarding-created:{draft_id}",
                       summary=f"Onboarding draft for {fields['legalName']} was started.",
                       refs={"draftId": draft_id, "workspace": fields["workspace"]})
            return data

        return self.view(write(self.db.transaction(max_attempts=10)))

    def update(self, actor: str, draft_id: str, body: Mapping[str, Any]) -> dict[str, Any]:
        fields = self._clean(body, required=False)
        reference = self._ref(draft_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            current = snapshot.to_dict() if snapshot.exists else None
            if not current:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Draft not found.")
            if current["status"] == COMPLETED and not set(fields) <= ADMIN_FIELDS:
                raise _conflict("The project is connected. Only the administrator and trading name can change now.")
            if current["status"] == COMPLETED and not self._still_setting_up(current):
                raise _conflict("This company is already open. Change its people on the company page.")
            if current["status"] not in (OPEN, COMPLETED) and not self._stalled(transaction, current):
                raise _conflict("This draft is closed.")
            old_claims = self._read_claims(transaction, current["workspace"])
            new_claims = None
            if fields.get("workspace") not in (None, current["workspace"]):
                new_claims = self._read_claims(transaction, fields["workspace"])
                self._check_free(new_claims, draft_id)
            company_to_update = None
            company_billing = None
            if current["status"] == COMPLETED and current.get("tenantId") and "billingEmail" in fields:
                company = self.db.collection(COMPANIES).document(current["tenantId"])
                company_snapshot = company.get(transaction=transaction)
                if company_snapshot.exists:
                    company_to_update = company
                    company_billing = (company_snapshot.to_dict() or {}).get("billingEmail")
            billing_behind = company_to_update is not None and fields["billingEmail"] != company_billing
            if not billing_behind and all(current.get(name) == value for name, value in fields.items()):
                return current
            staged = self.audit.stage(transaction, moment)
            updated = {**current, **fields, "updatedAt": format_timestamp(moment)}
            transaction.set(reference, updated)
            if new_claims is not None:
                self._release(transaction, old_claims, draft_id)
                self._claim(transaction, fields["workspace"], draft_id)
            if billing_behind:
                value = fields["billingEmail"]
                transaction.update(company_to_update,
                                   {"billingEmail": firestore.DELETE_FIELD if value is None else value})
                staged.add(actor=actor, action="billing_email.changed", tenant_id=current["tenantId"],
                           key=f"onboarding-billing-edit:{draft_id}:{format_timestamp(moment)}:{hashlib.sha256(str(value).encode()).hexdigest()[:12]}",
                           summary="Billing email changed while the company was being set up.",
                           refs={"cleared": "yes" if value is None else None})
            staged.add(actor=actor, action="onboarding.updated", tenant_id=None,
                       key=f"onboarding-updated:{draft_id}:{format_timestamp(moment)}:{'-'.join(sorted(fields))}:{hashlib.sha256(repr(sorted((k, str(v)) for k, v in fields.items())).encode()).hexdigest()[:12]}",
                       summary="An onboarding draft was changed.", refs={"draftId": draft_id})
            return updated

        return self.view(write(self.db.transaction(max_attempts=10)))

    def _stalled(self, transaction: firestore.Transaction, draft: Mapping[str, Any]) -> bool:
        tenant = draft.get("completingTenant")
        return (draft["status"] == COMPLETING and bool(tenant)
                and not self.db.collection(COMPANIES).document(tenant).get(transaction=transaction).exists)

    def _still_setting_up(self, draft: Mapping[str, Any]) -> bool:
        tenant = draft.get("tenantId")
        return bool(tenant) and self.reads is not None and self.reads.lifecycle(tenant) in (None, "lead")

    def _finish(self, actor: str, draft_id: str, state: str, action: str, summary: str,
                allowed: tuple[str, ...] = (OPEN,)) -> dict[str, Any]:
        reference = self._ref(draft_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            current = snapshot.to_dict() if snapshot.exists else None
            if not current:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Draft not found.")
            if current["status"] not in allowed and not self._stalled(transaction, current):
                raise _conflict("This draft is already closed.")
            claims = self._read_claims(transaction, current["workspace"])
            staged = self.audit.stage(transaction, moment)
            updated = {**current, "status": state, "closedAt": format_timestamp(moment), "updatedAt": format_timestamp(moment)}
            transaction.set(reference, updated)
            self._release(transaction, claims, draft_id)
            staged.add(actor=actor, action=action, tenant_id=None, key=f"{action}:{draft_id}", summary=summary,
                       refs={"draftId": draft_id})
            return updated

        return write(self.db.transaction(max_attempts=10))

    def cancel(self, actor: str, draft_id: str) -> dict[str, Any]:
        return self.view(self._finish(actor, draft_id, CANCELLED, "onboarding.cancelled",
                                      "An onboarding draft was cancelled."))

    def expire_due(self, now: datetime) -> int:
        stamp = format_timestamp(now)
        ended = 0
        for snapshot in self.db.collection(DRAFTS).where(
                filter=firestore.FieldFilter("status", "in", [OPEN, COMPLETING])).stream():
            data = snapshot.to_dict() or {}
            if data.get("endsAt", "") <= stamp:
                try:
                    self._finish("scheduler", snapshot.id, EXPIRED, "onboarding.expired",
                                 "An onboarding draft ended after its time ran out.")
                    ended += 1
                except HTTPException:
                    continue
        return ended

    def extend(self, actor: str, draft_id: str) -> dict[str, Any]:
        reference = self._ref(draft_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            current = snapshot.to_dict() if snapshot.exists else None
            if not current:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Draft not found.")
            if current["status"] != OPEN and not self._stalled(transaction, current):
                raise _conflict("This draft is closed.")
            if current.get("extensions", 0) >= 1:
                raise _conflict("This draft was already extended once.")
            staged = self.audit.stage(transaction, moment)
            ends = parse_timestamp(current["endsAt"]) + timedelta(days=EXTENSION_DAYS)
            updated = {**current, "endsAt": format_timestamp(ends), "extensions": 1,
                       "updatedAt": format_timestamp(moment)}
            transaction.set(reference, updated)
            staged.add(actor=actor, action="onboarding.extended", tenant_id=None, key=f"onboarding-extended:{draft_id}",
                       summary="An onboarding draft was extended by 30 days.", refs={"draftId": draft_id})
            return updated

        return self.view(write(self.db.transaction(max_attempts=10)))

    def first_admin_ready(self, draft_id: str, employee_code: Any = None) -> tuple[dict[str, Any], str]:
        data = self.data(draft_id)
        if data["status"] != COMPLETED or not data.get("tenantId"):
            raise _conflict("Connect the Firebase project first.")
        if not data.get("adminEmail") or not data.get("adminName"):
            raise _conflict("Add the first administrator's name and email first.")
        code = employee_code if employee_code is not None else data.get("adminEmployeeCode")
        if not isinstance(code, str) or not _EMPLOYEE_CODE.fullmatch(code.strip()):
            raise _bad("Enter an employee code of 1 to 32 letters, digits, dots, dashes or underscores.")
        return data, code.strip()

    def record_first_admin(self, actor: str, draft_id: str, granted: Mapping[str, Any]) -> None:
        summary = ("The first administrator was given access." if granted["state"] == "active"
                   else "The first administrator was sent an invitation.")
        self.audit.record(actor=actor, action="onboarding.first_admin", tenant_id=self.data(draft_id).get("tenantId"),
                          key=f"onboarding-first-admin:{draft_id}:{granted['state']}", summary=summary,
                          refs={"draftId": draft_id, "uid": granted["uid"], "path": granted["path"]})

    def data(self, draft_id: str) -> dict[str, Any]:
        snapshot = self._ref(draft_id).get()
        if not snapshot.exists:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Draft not found.")
        return snapshot.to_dict() or {}

    def get(self, draft_id: str) -> dict[str, Any]:
        return self.view(self.data(draft_id))

    def list_drafts(self, state: str | None) -> list[dict[str, Any]]:
        if state is not None and state not in STATES:
            raise _bad("status must be open, cancelled, expired or completed.")
        rows = [snapshot.to_dict() or {} for snapshot in self.db.collection(DRAFTS).stream()]
        rows = sorted((row for row in rows if state is None or (OPEN if row["status"] == COMPLETING else row["status"]) == state),
                      key=lambda row: row["createdAt"], reverse=True)
        if not rows:
            return []
        with ThreadPoolExecutor(max_workers=min(LIST_WORKERS, len(rows))) as pool:
            return list(pool.map(self.view, rows))

    @staticmethod
    def tenant_for(draft_id: str) -> str:
        return "t_" + hashlib.sha256(draft_id.encode("utf-8")).hexdigest()[:24]

    def ready_for_setup(self, draft_id: str, tenant_id: str, key: str | None = None) -> dict[str, Any]:
        reference = self._ref(draft_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            data = snapshot.to_dict() if snapshot.exists else None
            if not data:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Draft not found.")
            if data["status"] == COMPLETED and data.get("tenantId") == tenant_id:
                return data
            if data["status"] not in (OPEN, COMPLETING):
                raise _conflict("This draft is closed.")
            earlier = data.get("completingTenant")
            if (earlier and earlier != tenant_id
                    and self.db.collection(COMPANIES).document(earlier).get(transaction=transaction).exists):
                raise _conflict("A company was already created from this draft. Connect the project again with "
                                "the same details.")
            missing = [label for name, label in DETAIL_FIELDS if not data.get(name)]
            if missing:
                raise _conflict("Finish the draft first: add the " + ", ".join(missing) + ".")
            updated = {**data, "status": COMPLETING, "completingTenant": tenant_id,
                       "completingAt": format_timestamp(moment)}
            if key is not None:
                updated["completingKey"] = key
            transaction.set(reference, updated)
            return updated

        return write(self.db.transaction(max_attempts=10))

    def complete(self, actor: str, draft_id: str, tenant_id: str) -> dict[str, Any]:
        reference = self._ref(draft_id)
        company = self.db.collection(COMPANIES).document(tenant_id)
        moment = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            snapshot = reference.get(transaction=transaction)
            current = snapshot.to_dict() if snapshot.exists else None
            if not current:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Draft not found.")
            if current["status"] == COMPLETED:
                if current.get("tenantId") != tenant_id:
                    raise _conflict("This draft was completed for another company.")
                return current
            if current["status"] != COMPLETING or current.get("completingTenant") != tenant_id:
                raise _conflict("This draft is not being set up for this company.")
            if not company.get(transaction=transaction).exists:
                raise _conflict("The company record does not exist yet.")
            claims = self._read_claims(transaction, current["workspace"])
            staged = self.audit.stage(transaction, moment, tenant_id=tenant_id)
            stamp = format_timestamp(moment)
            updated = {**current, "status": COMPLETED, "tenantId": tenant_id, "completedAt": stamp,
                       "completedBy": actor, "updatedAt": stamp}
            updated.pop("completingTenant", None)
            updated.pop("completingAt", None)
            updated.pop("completingKey", None)
            transaction.set(reference, updated)
            transaction.update(company, {"onboardingDraftId": draft_id})
            self._release(transaction, claims, draft_id)
            staged.add(actor=actor, action="onboarding.completed", tenant_id=tenant_id,
                       key=f"onboarding-completed:{draft_id}", summary="Setup was completed from an onboarding draft.",
                       refs={"draftId": draft_id, "tenantId": tenant_id})
            return updated

        try:
            return write(self.db.transaction(max_attempts=10))
        except (Aborted, ValueError) as error:
            if not is_busy(error):
                raise
            settled = reference.get().to_dict() or {}
            if settled.get("status") == COMPLETED and settled.get("tenantId") == tenant_id:
                return settled
            raise _conflict("Another person is finishing this draft at the same time. "
                            "Refresh the page in a moment.") from error

    def steps_of(self, data: Mapping[str, Any], run: _Run | None = None) -> list[dict[str, Any]]:
        now = format_timestamp(self.clock())
        if data.get("status") in ENDED_STATES:
            return _public_steps([{"n": number, "key": key, "label": label, "ok": False,
                                   "fact": "This draft has ended.", "checkedAt": now, "button": None}
                                  for number, (key, label) in enumerate(STEPS, start=1)])
        run = run or _Run(data, self.reads, now)
        past_setup = run.tenant is not None and _past_setup(run)
        computed: list[dict[str, Any]] = []
        blocked_at = None
        for number in range(1, TOTAL + 1):
            if past_setup and number < TOTAL:
                item = _item(number, run, True, "The company is already past setup.", None)
            elif blocked_at is not None:
                item = _item(number, run, *_waiting(blocked_at))
            else:
                item = _compute_step(number, run)
                if item["ok"] is not True:
                    blocked_at = number
            computed.append(item)
        return _public_steps(computed)

    def first_unmet(self, data: Mapping[str, Any], step: int) -> str | None:
        run = _Run(data, self.reads, format_timestamp(self.clock()))
        for number in range(1, step):
            item = _compute_step(number, run)
            if item["ok"] is not True:
                return refusal_for(item, step - 1)
        return None

    def require_earlier_green(self, draft_id: str, step: int) -> None:
        refusal = self.first_unmet(self.data(draft_id), step)
        if refusal is not None:
            raise _conflict(refusal)

    def view(self, data: Mapping[str, Any]) -> dict[str, Any]:
        run = _Run(data, self.reads, format_timestamp(self.clock()))
        steps = self.steps_of(data, run)
        record = lifecycle = None
        if run.tenant and data.get("status") not in ENDED_STATES:
            try:
                record = run.record()
            except Exception:
                record = None
            try:
                lifecycle = run.lifecycle()
            except Exception:
                lifecycle = None
        kind = None if record is None else ("existing" if record.get("locationKind") == "byo" else "new")
        done = sum(1 for step in steps if step["state"] == "green")
        following = next((step for step in steps if step["state"] != "green"), None)
        if data["status"] in ENDED_STATES or lifecycle in ("cancelled", "expired"):
            phase = "ended"
        else:
            phase = "working" if done == TOTAL else "setup"
        shown = OPEN if data["status"] == COMPLETING else data["status"]
        return {
            "draftId": data["draftId"], "status": shown, "phase": phase, "legalName": data["legalName"],
            "tradingName": data.get("tradingName"), "workspace": data["workspace"], "kind": kind,
            "planId": data.get("planId"), "billingInterval": data.get("billingInterval"),
            "billingEmail": data.get("billingEmail"), "adminName": data.get("adminName"),
            "adminEmail": data.get("adminEmail"), "adminEmployeeCode": data.get("adminEmployeeCode"),
            "createdBy": data["createdBy"], "createdAt": data["createdAt"], "endsAt": data["endsAt"],
            "canExtend": shown == OPEN and data.get("extensions", 0) < 1,
            "tenantId": data.get("tenantId"), "completedAt": data.get("completedAt"),
            "lifecycleState": lifecycle, "steps": steps, "doneCount": done, "total": TOTAL,
            "next": None if following is None else {"n": following["n"], "key": following["key"],
                                                    "label": following["label"], "button": following["button"]},
        }

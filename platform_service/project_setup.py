from __future__ import annotations

import hashlib
import re
from dataclasses import replace
from typing import Any, Callable, Mapping

from fastapi import HTTPException
from firebase_admin.exceptions import FirebaseError
from google.auth.exceptions import GoogleAuthError

from . import config
from .commands import CommandProblem
from .company_access import UNREACHABLE, CompanyAccess, company_access, service_email
from .directory import DirectoryError, DirectoryStore
from .ids import utc_now
from .lifecycle import ACTION_LIFECYCLE, LifecycleService
from .onboarding import COMPLETED, OnboardingDrafts
from .operations import FAILED, OperationContext, LeaseLost, OperationError, OperationStore, RetryLater, Step, operation_id
from .records import PLATFORM_PROJECT_REFUSAL, RecordError, validate_record
from .tenant_readiness import DeployedRules, RulesReadFailed, _rules_credentials, deployed_rules_reader

ACTION_CONNECT = "project.connect"
CONNECT_ACTOR = "connect-project"
PROJECT_ID = re.compile(r"^[a-z][a-z0-9-]{4,29}$")
FIREBASE_API = "https://firebase.googleapis.com/v1beta1"
KIND_FOR_LOCATION = {"existing": "byo", "new": "managed"}
LIFECYCLE_STEPS = ("write_lifecycle", "project_lifecycle", "sync_record", "notify_status")
PARTS = (
    ("read_project", "Scoot can open the project", ("read_project",)),
    ("detect_kind", "Project kind and data", ("detect_kind",)),
    ("check_unused", "No other company uses the project", ("check_unused",)),
    ("read_web_config", "Web app settings", ("read_web_config",)),
    ("read_rules", "Deployed rules", ("read_rules",)),
    ("claim_draft", "Draft marked as connecting", ("claim_draft",)),
    ("store_record", "Company record", ("store_record",)),
    ("finish_draft", "Draft completed", ("finish_draft",)),
    ("lifecycle", "Company status Lead", LIFECYCLE_STEPS),
)
LIVE_PARTS = frozenset({"read_project", "detect_kind", "read_web_config", "read_rules", "lifecycle"})
FALLBACK = "If nobody can add the member, ask your engineer to install a key with scoot-deploy install-key."
PROJECT_IN_USE = ("Another company already uses this Firebase project. Each company needs its own Firebase "
                  "project. Create a new Firebase project for this company and enter its details.")
NO_WEB_APP = ("This project has no web app yet. Add a web app in the Firebase console "
              "(Project settings, Your apps), then press Check again.")


def as_presser(ctx: OperationContext, actor: str) -> OperationContext:
    return replace(ctx, params={**ctx.params, "requestedBy": actor})


class ConnectRefused(Exception):
    def __init__(self, message: str, *, fallback: str | None = None) -> None:
        super().__init__(message)
        self.fallback = fallback


class WebConfigUnreadable(Exception):
    pass


WebConfigReader = Callable[[str], "dict[str, Any] | None"]
RulesReader = Callable[[str, str], "DeployedRules | None"]


def firebase_web_config_reader(project_id: str, session: Any = None) -> dict[str, Any] | None:
    http = session
    if http is None:
        from google.auth.transport.requests import AuthorizedSession

        http = AuthorizedSession(_rules_credentials(project_id))
    listing = http.get(f"{FIREBASE_API}/projects/{project_id}/webApps")
    if listing.status_code in (403, 404):
        raise WebConfigUnreadable("The web apps of the project cannot be listed.")
    if listing.status_code != 200:
        raise WebConfigUnreadable(f"The web apps could not be listed (status {listing.status_code}).")
    apps = sorted(listing.json().get("apps") or [], key=lambda item: item.get("appId", ""))
    if not apps:
        return None
    settings = http.get(f"{FIREBASE_API}/projects/{project_id}/webApps/{apps[0]['appId']}/config")
    if settings.status_code != 200:
        raise WebConfigUnreadable(f"The web app settings could not be read (status {settings.status_code}).")
    body = settings.json()
    client: dict[str, Any] = {"apiKey": {"web": body["apiKey"]}, "appId": {"web": body["appId"]},
                              "messagingSenderId": body["messagingSenderId"]}
    if body.get("storageBucket"):
        client["storageBucket"] = body["storageBucket"]
    return client


def counted(db: Any, collection: str) -> int:
    return int(db.collection(collection).count().get()[0][0].value)


def kind_summary(people: int, orders: int) -> tuple[str, str]:
    if people or orders:
        return "existing", f"Existing project: {people} people, {orders} orders."
    return "new", "New project: no people and no orders."


class ProjectSetup:
    def __init__(
        self,
        *,
        runner: OperationStore,
        directory: DirectoryStore,
        drafts: OnboardingDrafts,
        lifecycle: LifecycleService,
        access_for: Callable[[Mapping[str, Any]], CompanyAccess] = company_access,
        web_config_reader: WebConfigReader = firebase_web_config_reader,
        rules_reader: RulesReader | None = None,
        email_reader: Callable[[], str | None] = service_email,
    ) -> None:
        self.runner = runner
        self.directory = directory
        self.drafts = drafts
        self.lifecycle = lifecycle
        self.access_for = access_for
        self.web_config_reader = web_config_reader
        self.rules_reader = rules_reader or (lambda project, database: deployed_rules_reader(project, database)())
        self.email_reader = email_reader

    def recovery_actions(self) -> dict[str, list[Step]]:
        return {ACTION_CONNECT: self.steps()}

    @staticmethod
    def tenant_id(draft_id: str, project_id: str) -> str:
        return "t_" + hashlib.sha256(f"connect:{draft_id}:{project_id}".encode("utf-8")).hexdigest()[:24]

    def company_for(self, draft_id: str, project_id: str) -> str:
        earlier = self.drafts.data(draft_id).get("tenantId")
        if earlier and PROJECT_ID.fullmatch(project_id) and self.directory.project_holder(project_id) == earlier:
            return earlier
        return self.tenant_id(draft_id, project_id)

    def idempotency_key(self, draft_id: str, project_id: str, tenant_id: str) -> str:
        if tenant_id == self.tenant_id(draft_id, project_id):
            return f"connect-{draft_id}-{project_id}"
        return f"connect-{draft_id}-{project_id}-{tenant_id}"

    def member_text(self) -> str:
        email = self.email_reader()
        return email if email else "the Scoot service account"

    def cannot_open(self) -> ConnectRefused:
        return ConnectRefused(
            f"Scoot cannot open this project yet. Check that {self.member_text()} is a member with the role "
            "Firebase Admin, then press Check again.", fallback=FALLBACK)

    def access(self, project_id: str) -> CompanyAccess:
        location = {"projectId": project_id, "databaseId": "(default)", "authTenantId": None}
        try:
            return self.access_for(location)
        except (*UNREACHABLE, FirebaseError, GoogleAuthError, RuntimeError):
            raise self.cannot_open() from None

    def steps(self, presser: str = CONNECT_ACTOR) -> list[Step]:
        def read_project(ctx: OperationContext) -> dict[str, Any]:
            project_id = ctx.params["projectId"]
            access = self.access(project_id)
            try:
                list(access.db.collection("user_access").limit(1).stream())
                access.auth.list_users(max_results=1)
            except (*UNREACHABLE, FirebaseError, GoogleAuthError):
                raise self.cannot_open() from None
            return {"projectId": project_id}

        def detect_kind(ctx: OperationContext) -> dict[str, Any]:
            access = self.access(ctx.params["projectId"])
            try:
                people, orders = counted(access.db, "user_access"), counted(access.db, "orders")
            except (*UNREACHABLE, FirebaseError, GoogleAuthError):
                raise self.cannot_open() from None
            kind, summary = kind_summary(people, orders)
            return {"kind": kind, "locationKind": KIND_FOR_LOCATION[kind], "people": people, "orders": orders,
                    "summary": summary}

        def check_unused(ctx: OperationContext) -> dict[str, Any]:
            holder = self.directory.project_holder(ctx.params["projectId"])
            if holder is not None and holder != ctx.params["tenantId"]:
                raise ConnectRefused(PROJECT_IN_USE)
            return {}

        def read_web_config(ctx: OperationContext) -> dict[str, Any]:
            try:
                client = self.web_config_reader(ctx.params["projectId"])
            except (WebConfigUnreadable, *UNREACHABLE, GoogleAuthError):
                raise ConnectRefused(
                    f"Scoot cannot read the web app of this project. Check that {self.member_text()} has the "
                    "role Firebase Admin, then press Check again.", fallback=FALLBACK) from None
            if client is None:
                raise ConnectRefused(NO_WEB_APP)
            return {"clientConfig": client}

        def read_rules(ctx: OperationContext) -> dict[str, Any]:
            try:
                deployed = self.rules_reader(ctx.params["projectId"], "(default)")
            except (RulesReadFailed, *UNREACHABLE, GoogleAuthError):
                raise ConnectRefused("The rules of this project could not be read. Press Check again.") from None
            if deployed is None:
                return {"rulesVersion": "none", "rulesSha256": None}
            return {"rulesVersion": "sha-" + deployed.sha256[:12], "rulesSha256": deployed.sha256}

        def claim_draft(ctx: OperationContext) -> dict[str, Any]:
            try:
                self.drafts.ready_for_setup(ctx.params["draftId"], ctx.params["tenantId"])
            except HTTPException as error:
                raise ConnectRefused(str(error.detail)) from None
            return {}

        def store_record_check(ctx: OperationContext) -> bool:
            return self.directory.get(ctx.params["tenantId"]) is not None

        def store_record(ctx: OperationContext) -> dict[str, Any]:
            draft = self.drafts.data(ctx.params["draftId"])
            package = self.drafts.package_check(draft["planId"])
            try:
                record = validate_record({
                    "tenantId": ctx.params["tenantId"], "workspace": draft["workspace"],
                    "legalName": draft["legalName"], "companyCode": draft["workspace"], "status": "lead",
                    "location": {"projectId": ctx.params["projectId"], "databaseId": "(default)",
                                 "authTenantId": None},
                    "locationKind": ctx.results["detect_kind"]["locationKind"],
                    "clientConfig": ctx.results["read_web_config"]["clientConfig"],
                    "planRef": package["planId"], "edition": package["edition"], "releaseRing": "general",
                    "rulesVersion": ctx.results["read_rules"]["rulesVersion"],
                })
                envelope = self.directory.put(record, expected_version=0, draft_id=ctx.params["draftId"])
            except RecordError as error:
                raise ConnectRefused(str(error)) from None
            except DirectoryError as error:
                text = str(error)
                raise ConnectRefused(PROJECT_IN_USE if "Already claimed" in text else text) from None
            return {"stored": bool(envelope)}

        def finish_check(ctx: OperationContext) -> bool:
            draft = self.drafts.data(ctx.params["draftId"])
            return draft["status"] == COMPLETED and draft.get("tenantId") == ctx.params["tenantId"]

        def finish_draft(ctx: OperationContext) -> dict[str, Any]:
            draft = self.drafts.data(ctx.params["draftId"])
            tenant_id = ctx.params["tenantId"]
            if draft.get("billingEmail") and self.directory.billing_email(tenant_id) is None:
                self.directory.set_billing_email(
                    tenant_id, draft["billingEmail"], audit=self.drafts.audit, actor=presser,
                    key=f"onboarding-billing:{ctx.params['draftId']}", expected_previous=None,
                    summary="First billing email set when the project was connected; later changes need approval.")
            try:
                self.drafts.complete(presser, ctx.params["draftId"], tenant_id)
            except HTTPException as error:
                raise ConnectRefused(str(error.detail)) from None
            return {}

        return [
            Step("read_project", read_project, lambda ctx: False),
            Step("detect_kind", detect_kind, lambda ctx: False),
            Step("check_unused", check_unused, lambda ctx: False),
            Step("read_web_config", read_web_config, lambda ctx: False),
            Step("read_rules", read_rules, lambda ctx: False),
            Step("claim_draft", claim_draft, lambda ctx: False),
            Step("store_record", store_record, store_record_check),
            Step("finish_draft", finish_draft, finish_check),
        ]

    def connect(self, actor: str, draft_id: str, project_id: Any, *, reason: str = "Connect project") -> dict[str, Any]:
        if not isinstance(project_id, str) or not PROJECT_ID.fullmatch(project_id.strip()):
            raise HTTPException(400, "Enter the Firebase project ID, for example acme-sales-1a2b3.")
        project_id = project_id.strip()
        if project_id.lower() == config.PLATFORM_PROJECT_ID.lower():
            raise HTTPException(400, PLATFORM_PROJECT_REFUSAL)
        tenant_id = self.company_for(draft_id, project_id)
        key = self.idempotency_key(draft_id, project_id, tenant_id)
        steps = self.steps(actor)
        params = {"draftId": draft_id, "projectId": project_id, "tenantId": tenant_id, "state": "lead",
                  "ticket": None, "expectedRevision": None}
        try:
            op = self.runner.begin(
                idempotency_key=key, action=ACTION_CONNECT, actor=CONNECT_ACTOR, tenant_id=tenant_id, reason=reason,
                ticket=None, field_names=["projectId"], params=params, step_names=[step.name for step in steps])
        except OperationError:
            raise HTTPException(409, "Another person already started connecting this project. "
                                     "Ask that person to press Connect again.") from None
        self.runner.annotate(op, {"actor": actor})
        earlier = self.runner.get(op) or {}
        if earlier.get("status") == FAILED:
            self.runner.reopen(op, actor)
        refusal: str | None = None
        fallback: str | None = None
        retry = False
        try:
            self.runner.run(op, steps)
        except ConnectRefused as error:
            refusal, fallback = str(error), error.fallback
        except CommandProblem as error:
            refusal = str(error)
        except (RetryLater, LeaseLost):
            retry = True
        if refusal is None and not retry:
            refusal, retry = self.run_lifecycle(actor, tenant_id, reason)
        return {**self.report(draft_id, project_id, tenant_id), "refusal": refusal, "fallback": fallback, "retryLater": retry}

    def lifecycle_operation(self, tenant_id: str) -> str:
        return operation_id(ACTION_LIFECYCLE, f"connect-lifecycle-{tenant_id}")

    def lead_from_another_operation(self, tenant_id: str) -> bool:
        stored = self.lifecycle.store.get(tenant_id)
        return (stored or {}).get("state") == "lead" and self.lifecycle.store.result_for(
            tenant_id, self.lifecycle_operation(tenant_id)) is None

    def run_lifecycle(self, actor: str, tenant_id: str, reason: str) -> tuple[str | None, bool]:
        if self.lead_from_another_operation(tenant_id):
            return None, False
        steps = [Step(step.name, lambda ctx, step=step: step.apply(as_presser(ctx, actor)),
                      lambda ctx, step=step: step.check(as_presser(ctx, actor)))
                 for step in self.lifecycle.transition_steps()]
        params = {"tenantId": tenant_id, "state": "lead", "expectedRevision": None, "paymentEntryId": None,
                  "reason": reason, "ticket": None, "requestedBy": CONNECT_ACTOR}
        try:
            op = self.runner.begin(
                idempotency_key=f"connect-lifecycle-{tenant_id}", action=ACTION_LIFECYCLE, actor=CONNECT_ACTOR,
                tenant_id=tenant_id, reason=reason, ticket=None, field_names=["state"], params=params,
                step_names=[step.name for step in steps])
        except OperationError:
            raise HTTPException(409, "Another person already started connecting this project. "
                                     "Ask that person to press Connect again.") from None
        self.runner.annotate(op, {"actor": actor})
        if (self.runner.get(op) or {}).get("status") == FAILED:
            self.runner.reopen(op, actor)
        try:
            self.runner.run(op, steps)
        except CommandProblem as error:
            return str(error), False
        except (RetryLater, LeaseLost):
            return None, True
        return None, False

    def report(self, draft_id: str, project_id: str, tenant_id: str) -> dict[str, Any]:
        record = self.runner.get(operation_id(ACTION_CONNECT, self.idempotency_key(draft_id, project_id, tenant_id))) or {}
        steps = {**(record.get("steps") or {}),
                 **((self.runner.get(self.lifecycle_operation(tenant_id)) or {}).get("steps") or {})}
        saved = {name for name, state in steps.items() if state.get("status") == "done"}
        if self.lead_from_another_operation(tenant_id):
            saved.update(LIFECYCLE_STEPS)
        reachable = True
        if saved:
            try:
                list(self.access(project_id).db.collection("user_access").limit(1).stream())
            except (ConnectRefused, *UNREACHABLE, FirebaseError, GoogleAuthError):
                reachable = False
        parts = []
        for key, label, names in PARTS:
            if all(name in saved for name in names):
                state = "saved" if reachable or key not in LIVE_PARTS else "unknown"
            else:
                state = "pending"
            parts.append({"key": key, "label": label, "state": state})
        detected = (steps.get("detect_kind") or {}).get("result") or {}
        return {"ok": all(part["state"] == "saved" for part in parts), "tenantId": tenant_id,
                "projectId": project_id, "kind": detected.get("kind"), "people": detected.get("people"),
                "orders": detected.get("orders"), "summary": detected.get("summary"), "parts": parts}

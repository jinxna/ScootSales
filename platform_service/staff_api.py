from __future__ import annotations

import contextlib
import csv
import io
import json
import logging
import re
import time
import uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any, Callable, Iterator, Mapping

from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from google.api_core.exceptions import GoogleAPICallError
from google.cloud import firestore
from pydantic import BaseModel, Field, StrictInt, StringConstraints

from . import auth, config
from .approvals import (
    BILLING_EMAIL,
    CREDIT_NOTE,
    LIFECYCLE_CANCEL,
    LIFECYCLE_EXPIRE,
    LIFECYCLE_REACTIVATE,
    LIFECYCLE_SUSPEND,
    PACKAGE_PRICE,
    PAYMENT_VOID,
    PLAN_OVERRIDE,
    REACTIVATABLE,
    REQUEST_ROLES,
    ApprovalBook,
    price_changes,
)
from .account_links import install_account_link_routes
from .account_security import install_sign_in_route
from .audit import EVENT_FIELDS, AuditLog, check_chain, check_day, default_range
from .client_api import build_firestore_client, check_startup_safety, install_client_routes
from .commands import CommandProblem, PlanProblem
from .company_access import company_access, require_company_credentials, service_email
from .directory import (
    COMPANIES, DirectoryError, DirectoryStore, renew_directory_records,
)
from .invitations import InvitationService, InviteConfigError, client_ip, first_admin_state, load_secret
from .lifecycle import (
    ACTION_LIFECYCLE,
    ALLOWED_TRANSITIONS as LIFECYCLE_TRANSITIONS,
    FIRST_STATES,
    STATES,
    LifecycleConflict,
    LifecycleService,
    LifecycleStore,
    TenantLifecycle,
)
from .operations import (
    OperationContext,
    OperationError,
    OperationStore,
    RetryLater,
    Step,
    operation_id as operation_id_for,
)
from .ids import TENANT, identity, local_date, local_day, safe_cell
from .invoices import ISSUED, PAID, SENT, VOID, InvoiceBook, extension_problem
from .mail import (
    STAFF_MAIL_TENANT, MailQueue, MailTransport, build_transport, company_contact, require_mail_ready,
)
from .mail_events import install_mail_event_routes
from .onboarding import OnboardingDrafts, Reads
from .payments import CHECKS, ENTRIES, PaymentLedger, coverage_of
from .plans import (
    BILLING_INTERVALS,
    PLAN_ID,
    PLAN_REQUESTS,
    UPGRADE_ONLY_MESSAGE,
    PlanStore,
    carried_add_ons,
    check_plan_id,
    clean_override,
    clean_subscription,
    clean_version,
    clean_visibility,
    jsonable,
)
from .product_commands import ProductCommands
from .records import RecordError, check_service_hosts, validate_record, workspace_skeleton
from . import staff_routes
from .seed_directory import REPO_ROOT, current_rules_version
from . import tenant_readiness
from .seats import usage_ref
from . import staff_capabilities
from .staff import STAFF, StaffBook, solo_owner, staff_id, mask as mask_email
from .staff import digest as staff_digest
from .staff_signin import StaffSignIn
from .scheduler import RENEWAL_BLOCKS, build_scheduler, companies_past_grace, install as install_scheduler
from .signing import Keyring, Signer, format_timestamp, parse_timestamp
from .support import install_support_routes
from .tenant_export import install_export_routes
from .subscriptions import (
    ACTION_PLAN_PUT,
    ACTION_PLAN_RETIRE,
    ACTION_REFRESH,
    ACTION_SUBSCRIPTION,
    PACKAGE_PARTS,
    PART_SAVED,
    PART_UNKNOWN,
    SubscriptionService,
)
from . import access_migration, access_repair, prepare_data
from .project_setup import ProjectSetup, RulesReader, WebConfigReader, firebase_web_config_reader
from .usage_reconciler import UsageReconciler

DIRECTORY_PUT = "directory.put"
_IDEMPOTENCY_KEY = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
_OPERATION_ID = re.compile(r"^op_[0-9a-f]{32}$")
_EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]+$")
_SETUP_FIELDS = frozenset({"location", "locationKind", "clientConfig", "rulesVersion", "releaseRing",
                           "services"})
_COMPANY_FIELD_LABELS = {"legalName": "company name", "workspace": "workspace", "companyCode": "company code",
                         "status": "status", "planRef": "package", "edition": "edition"}
_APPROVAL_STATES = {"suspended": LIFECYCLE_SUSPEND, "cancelled": LIFECYCLE_CANCEL, "expired": LIFECYCLE_EXPIRE}
_LIFECYCLE_FIELDS = ("status", "edition", "planRef")
_SAFE_ERRORS = frozenset({"CommandProblem", "PlanProblem", "PlanLimit", "PlanMissing", "UsageMissing",
                          "LifecycleConflict"})
ATTENTION_DAYS = 14
MAX_EXPORT_ROWS = 10000


def _version_of(envelope: Mapping[str, Any]) -> int:
    return int(json.loads(envelope["payload"])["version"])


def directory_put_steps(store: DirectoryStore) -> list[Step]:
    def apply(context: OperationContext) -> dict[str, int]:
        envelope = store.put(
            context.params["record"], expected_version=context.params["expectedVersion"],
            draft_id=context.params.get("draftId"), setup_key=context.params.get("setupKey"),
        )
        return {"version": _version_of(envelope)}

    def check(context: OperationContext) -> bool:
        expected = validate_record(context.params["record"])
        current = store.get(expected["tenantId"])
        return (
            current is not None
            and current["version"] > context.params["expectedVersion"]
            and all(current.get(key) == value for key, value in expected.items())
        )

    return [Step("store_record", apply, check)]


def build_actions(
    client: firestore.Client,
    store: DirectoryStore,
    signer: Signer,
    invitations: InvitationService | None = None,
    *,
    subscriptions: SubscriptionService | None = None,
    products: ProductCommands | None = None,
    lifecycle: LifecycleService | None = None,
    approvals: ApprovalBook | None = None,
    project_setup: ProjectSetup | None = None,
) -> dict[str, list[Step]]:
    actions = {DIRECTORY_PUT: directory_put_steps(store)}
    for service in (invitations, subscriptions, products, lifecycle, approvals, project_setup):
        if service is not None:
            actions.update(service.recovery_actions())
    return actions


class PutCompany(BaseModel):
    record: dict[str, Any]
    expectedVersion: StrictInt = Field(ge=0)
    reason: str = Field(min_length=3, max_length=500)
    ticket: str | None = Field(default=None, max_length=100)


class RefreshDirectory(BaseModel):
    withinDays: StrictInt = Field(default=7, ge=1, le=29)
    tenantIds: list[Annotated[str, StringConstraints(pattern=r"^t_[a-z0-9]{6,32}$")]] | None = Field(
        default=None, min_length=1, max_length=50)


def _reason(body: Mapping[str, Any], default: str) -> str:
    reason = body.get("reason")
    if reason is None:
        return default
    if not isinstance(reason, str) or not 3 <= len(reason.strip()) <= 500:
        raise _bad_request("Give a reason of 3 to 500 characters.")
    return reason.strip()


def _ticket(body: Mapping[str, Any]) -> str | None:
    ticket = body.get("ticket")
    if ticket is not None and (not isinstance(ticket, str) or len(ticket) > 100):
        raise _bad_request("A ticket is at most 100 characters.")
    return ticket


def _bad_request(detail: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=detail)


def _idempotency_key(value: str | None) -> str:
    if value is None or not _IDEMPOTENCY_KEY.fullmatch(value):
        raise _bad_request("Idempotency-Key must be 8-128 characters of A-Z, a-z, 0-9, _ or -.")
    return value


_REQUEST_LOG = logging.getLogger("platform_service.request")
_REQUEST_ID = re.compile(r"[A-Za-z0-9._-]{8,64}")


def install_request_log(app: FastAPI) -> None:
    if not _REQUEST_LOG.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("%(message)s"))
        _REQUEST_LOG.addHandler(handler)
        _REQUEST_LOG.setLevel(logging.INFO)

    app.add_middleware(RequestLogMiddleware)


class RequestLogMiddleware:
    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict, receive: Callable[..., Any], send: Callable[..., Any]) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        request = Request(scope)
        supplied = request.headers.get("x-request-id", "")
        request_id = supplied if _REQUEST_ID.fullmatch(supplied) else uuid.uuid4().hex
        request.state.request_id = request_id
        started = time.monotonic()
        code = 500

        async def send_with_id(message: dict) -> None:
            nonlocal code
            if message["type"] == "http.response.start":
                code = message["status"]
                message.setdefault("headers", []).append((b"x-request-id", request_id.encode("latin-1")))
            await send(message)

        try:
            await self.app(scope, receive, send_with_id)
        finally:
            params = scope.get("path_params") or {}
            route = scope.get("route")
            tenant = params.get("tenant_id") or getattr(request.state, "tenant_id", None)
            _REQUEST_LOG.info(json.dumps({
                "event": "request", "requestId": request_id,
                "tenantId": tenant if isinstance(tenant, str) and TENANT.fullmatch(tenant) else None,
                "method": request.method, "route": getattr(route, "path", None), "status": code,
                "durationMs": round((time.monotonic() - started) * 1000),
            }, separators=(",", ":")))


def create_app(
    *,
    store: DirectoryStore | None = None,
    operations: OperationStore | None = None,
    signer: Signer | None = None,
    client: firestore.Client | None = None,
    mail_transport: Callable[[], MailTransport] | None = None,
    rules_reader_for: Callable[[Mapping[str, Any]], Callable[[], Any] | None] | None = None,
    connect_web_config_reader: WebConfigReader | None = None,
    connect_rules_reader: RulesReader | None = None,
) -> FastAPI:
    check_startup_safety()
    require_company_credentials()
    if not config.STAFF_HASH_SECRET and not auth.emulator_mode():
        raise RuntimeError("PLATFORM_STAFF_HASH_SECRET is required outside emulator runs.")
    if store is None:
        client = client or build_firestore_client()
        signer = signer or Signer.from_environment()
        store = DirectoryStore(client, keyring=Keyring.from_environment(), signer=signer)
    else:
        client = client or store.client
        signer = signer or store.signer or Signer.from_environment()
    audit_log = AuditLog(client)
    operations = operations or OperationStore(client, audit=audit_log)
    if operations.audit is None:
        operations.audit = audit_log
    try:
        invite_secret = load_secret()
    except InviteConfigError:
        invite_secret = None
    plan_store = PlanStore(client)
    access_for = company_access
    payment_ledger = PaymentLedger(client, audit=audit_log)
    mail_queue = MailQueue(client)
    transport_factory = mail_transport or build_transport
    if mail_queue.enabled:
        require_mail_ready(transport_factory())
    invoice_book = InvoiceBook(client, plan_store, mail=mail_queue, audit=audit_log)
    lifecycle_store = LifecycleStore(client, audit=audit_log)
    invitation_service = InvitationService(
        client, operations, store, secret=invite_secret, plans=plan_store, access_for=access_for,
    )
    product_service = ProductCommands(client, operations, plans=plan_store, access_for=access_for)
    subscription_service = SubscriptionService(client, operations, store, plan_store, access_for=access_for)
    lifecycle_service = LifecycleService(
        client,
        operations,
        store,
        lifecycle_store,
        access_for=access_for,
        clock=lambda: datetime.now(timezone.utc),
        mail=mail_queue,
    )
    reconciler = UsageReconciler(client, store, access_for=access_for)
    staff_book = StaffBook(client, audit_log, mail_queue)
    sign_in = StaffSignIn(staff_book, transport=transport_factory)
    approval_book = ApprovalBook(
        client, operations, audit_log, directory=store, lifecycle_store=lifecycle_store,
        lifecycle_service=lifecycle_service, ledger=payment_ledger, invoices=invoice_book, plans=plan_store,
        subscriptions=subscription_service, mail=mail_queue,
        solo_owner=lambda email, transaction=None: solo_owner(client, email, transaction),
    )
    directory: DirectoryStore = store
    database: firestore.Client = client
    runner: OperationStore = operations
    signing: Signer = signer

    app = FastAPI(title="Scoot platform staff API", docs_url=None, redoc_url=None, openapi_url=None)
    install_request_log(app)
    install_scheduler(app, lambda: build_scheduler(database, lifecycle=lifecycle_service, invoices=invoice_book,
                                                   audit=audit_log, subscriptions=subscription_service,
                                                   operations=runner, transport=transport_factory,
                                                   recovery=lambda: build_actions(
                                                       database, directory, signing, invitation_service,
                                                       subscriptions=subscription_service, products=product_service,
                                                       lifecycle=lifecycle_service, approvals=approval_book,
                                                       project_setup=project_setup)))

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request: Request, error: RequestValidationError) -> JSONResponse:
        if not request.url.path.startswith("/staff/"):
            return JSONResponse({"detail": "Check the details and try again."}, status_code=400,
                                headers={"Cache-Control": "no-store"})
        problems = [
            {"loc": list(item.get("loc", ())), "msg": item.get("msg", "Invalid value.")}
            for item in error.errors()
        ]
        return JSONResponse({"detail": problems}, status_code=422)

    @app.exception_handler(CommandProblem)
    async def command_conflict(_: Request, error: CommandProblem) -> JSONResponse:
        return JSONResponse({"detail": str(error), **({"fix": error.fix} if error.fix else {})}, status_code=409,
                            headers={"Cache-Control": "no-store"})

    def verified_staff(request: Request) -> auth.StaffIdentity:
        token = staff_routes.staff_token(request)
        return sign_in.authenticate(token, request.headers.get("x-staff-session"))

    def require(roles: tuple[str, ...], message: str) -> Callable[..., auth.StaffIdentity]:
        def dependency(who: auth.StaffIdentity = Depends(verified_staff)) -> auth.StaffIdentity:
            if who.role not in roles:
                raise HTTPException(status_code=403, detail=message)
            return who

        return dependency

    staff = require(("owner",), "Only the owner can do this.")
    operator_roles = ("owner", "operator")
    operator_staff = require(operator_roles, "Only an accounts operator or owner can do this.")
    engineer_staff = require(("owner", "engineer"), "Only the owner or the engineer can enter or change setup details.")
    draft_staff = require(("owner", "operator"), "Only an accounts operator or owner can do this.")
    task_staff = require(("owner", "operator", "engineer"), "Only staff who manage companies can do this.")
    company_reader = require(("owner", "operator", "engineer"), "Only staff who manage companies can do this.")

    def needs_approval(action: str) -> JSONResponse:
        return JSONResponse(
            {"detail": "This change needs a second person. Send an approval request.", "approvalAction": action},
            status_code=status.HTTP_409_CONFLICT, headers={"Cache-Control": "no-store"})

    @app.get("/staff/v1/me")
    def staff_profile(who: auth.StaffIdentity = Depends(verified_staff)) -> JSONResponse:
        return JSONResponse(staff_capabilities.with_capabilities(
                                {"email": who.email, "role": who.role, "name": who.name or None,
                                 "sessionId": who.session_id}),
                            headers={"Cache-Control": "no-store"})

    def outcome(operation_id: str, record: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "operationId": operation_id,
            "status": record.get("status"),
            "steps": {
                name: {"status": step.get("status"), "result": step.get("result")}
                for name, step in (record.get("steps") or {}).items()
            },
        }

    def settle(operation_id: str, steps: list[Step]) -> tuple[int, dict[str, Any]]:
        try:
            record = runner.run(operation_id, steps)
        except RetryLater:
            record = runner.get(operation_id) or {}
            return status.HTTP_202_ACCEPTED, outcome(operation_id, record)
        except (DirectoryError, RecordError, OperationError, CommandProblem, PlanProblem) as error:
            body: dict[str, Any] = {
                "detail": "The operation did not finish.",
                "errorType": type(error).__name__,
                "operationId": operation_id,
                "status": (runner.get(operation_id) or {}).get("status", "failed"),
            }
            if isinstance(error, (CommandProblem, PlanProblem)):
                body["message"] = str(error)
                if error.fix:
                    body["fix"] = error.fix
            if (runner.get(operation_id) or {}).get("action") == ACTION_SUBSCRIPTION:
                body.update(subscription_service.package_failure(operation_id))
            return status.HTTP_409_CONFLICT, body
        return status.HTTP_200_OK, outcome(operation_id, record)

    def run_operation(operation_id: str, steps: list[Step]) -> JSONResponse:
        code, body = settle(operation_id, steps)
        return JSONResponse(body, status_code=code)

    def begin(**fields: Any) -> str:
        try:
            return runner.begin(**fields)
        except OperationError as error:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This idempotency key was already used for a different request.",
            ) from error

    @app.get("/staff/v1/companies")
    def list_companies(_: auth.StaffIdentity = Depends(company_reader)) -> dict[str, Any]:
        try:
            records = directory.list_records_with_billing()
            states = {
                snapshot.id: (snapshot.to_dict() or {}).get("state")
                for snapshot in database.collection("lifecycle").select(["state"]).stream()
            }
            return {
                "companies": [
                    {**record, "lifecycleState": states[record["tenantId"]]
                     if isinstance(states.get(record["tenantId"]), str) else None,
                     "currentRulesVersion": current_rules_version(record.get("workspace", ""))}
                    for record in records
                ]
            }
        except DirectoryError as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The company directory could not be verified.",
            ) from error

    @app.put("/staff/v1/companies/{tenant_id}")
    def put_company(
        tenant_id: str,
        body: PutCompany,
        who: auth.StaffIdentity = Depends(verified_staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        role = who.role
        if role not in ("owner", "engineer"):
            raise HTTPException(status_code=403, detail="Only the owner can do this.")
        if body.record.get("tenantId") != tenant_id:
            raise _bad_request("record.tenantId must equal the tenant in the path.")
        if body.expectedVersion == 0:
            raise _bad_request("A company is created by completing its onboarding draft, not here.")
        try:
            proposed = validate_record(body.record)
        except RecordError as error:
            raise _bad_request(str(error)) from error
        try:
            current = directory.get(tenant_id) or {}
        except DirectoryError:
            snapshot = database.collection(COMPANIES).document(tenant_id).get()
            try:
                current = directory._verify(snapshot.to_dict() or {}, tenant_id, allow_expired=True) if snapshot.exists else {}
            except DirectoryError:
                current = {}
        if current and any(proposed.get(name) != current.get(name) for name in _LIFECYCLE_FIELDS):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Status, edition and package change through the status and package flows, not here.")
        try:
            check_service_hosts(proposed["services"], current.get("services") or {})
        except RecordError as error:
            raise _bad_request(str(error)) from error
        changed = {name for name in proposed if proposed.get(name) != current.get(name)}
        setup_changed = bool(changed & _SETUP_FIELDS)
        earlier = runner.get(operation_id_for(DIRECTORY_PUT, key))
        if earlier is not None and not may_continue_directory_put(who, earlier):
            raise HTTPException(status_code=403, detail="This change was started by someone else. Ask the owner.")
        replay = earlier is not None
        if not replay and role != "owner" and current:
            owner_only = sorted(changed - _SETUP_FIELDS)
            if owner_only:
                names = ", ".join(_COMPANY_FIELD_LABELS.get(name, name) for name in owner_only)
                raise HTTPException(
                    status_code=403,
                    detail=f"The engineer can change setup details only. Ask the owner to change: {names}.")
            if not setup_changed:
                raise HTTPException(status_code=403, detail="Only the owner can do this.")
        operation_id = begin(
            idempotency_key=key,
            action=DIRECTORY_PUT,
            actor=who.email,
            tenant_id=tenant_id,
            reason=body.reason,
            ticket=body.ticket,
            field_names=sorted(body.record),
            params={
                "tenantId": tenant_id,
                "expectedVersion": body.expectedVersion,
                "record": body.record,
            },
            step_names=["store_record"],
        )
        return run_operation(operation_id, directory_put_steps(directory))

    @app.put("/staff/v1/companies/{tenant_id}/billing-email")
    def put_billing_email(tenant_id: str, _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        return needs_approval(BILLING_EMAIL)

    def company_record(tenant_id: str) -> dict[str, Any]:
        try:
            record = directory.get(tenant_id)
        except DirectoryError as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The company directory could not be verified.",
            ) from error
        if record is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown company.")
        return record

    mail_job_fields = ("jobId", "kind", "recipient", "status", "attempts", "maxAttempts", "createdAt",
                       "updatedAt", "nextAttemptAt", "lastFailure", "retryOf", "retriedAs", "handledAt",
                       "handledBy", "heldReason", "heldAt", "deliveryStatus", "deliveryStatusAt", "attachmentName")

    def mail_job_row(job: Mapping[str, Any]) -> dict[str, Any]:
        return {name: job.get(name) for name in mail_job_fields}

    def mail_job_id(job_id: str) -> str:
        if not re.fullmatch(r"[0-9a-f]{64}", job_id):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown mail job.")
        return job_id

    def mail_failure(error: Exception) -> HTTPException:
        if isinstance(error, LookupError):
            return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown mail job.")
        return HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error))

    def mail_company_name(tenant_id: str, names: dict[str, str]) -> str:
        if tenant_id not in names:
            contact = None if tenant_id == STAFF_MAIL_TENANT else company_contact(database, tenant_id)
            names[tenant_id] = "Control Centre" if tenant_id == STAFF_MAIL_TENANT else (
                contact[0] if contact else tenant_id)
        return names[tenant_id]

    def check_staff_invite_mail(who: auth.StaffIdentity, job_id: str) -> None:
        job = database.collection("mail_jobs").document(mail_job_id(job_id)).get().to_dict() or {}
        if job.get("kind") != "staff_invite":
            return
        if who.role != "owner":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                                detail="Only the owner can send a staff invitation again.")
        secret = str((job.get("payload") or {}).get("inviteUrl", "")).rpartition(".")[2]
        person = database.collection(STAFF).document(staff_id(job.get("recipient", ""))).get().to_dict() or {}
        if (person.get("status") != "invited" or not secret
                or person.get("inviteHash") != staff_digest(secret)
                or person.get("inviteExpiresAt", "") <= format_timestamp(datetime.now(timezone.utc))):
            raise HTTPException(status_code=status.HTTP_409_CONFLICT,
                                detail="This invitation was revoked or has expired. Send a new invitation.")

    def held_mail_row(job: Mapping[str, Any], names: dict[str, str]) -> dict[str, Any]:
        tenant_id = job["tenantId"]
        mail_company_name(tenant_id, names)
        return {"jobId": job["jobId"], "tenantId": tenant_id, "companyName": names[tenant_id], "kind": job["kind"],
                "recipient": mask_email(job["recipient"]), "reason": job["heldReason"], "heldAt": job["heldAt"],
                "attempts": job["attempts"], "maxAttempts": job["maxAttempts"], "lastFailure": job["lastFailure"]}

    @app.get("/staff/v1/mail/held")
    def list_held_mail(_: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        names: dict[str, str] = {}
        return JSONResponse({"jobs": [held_mail_row(job, names) for job in mail_queue.held_jobs()]},
                            headers={"Cache-Control": "no-store"})

    @app.get("/staff/v1/mail/attention")
    def list_attention_mail(_: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        names: dict[str, str] = {}
        known: dict[str, bool] = {}

        def is_company(tenant_id: str) -> bool:
            if tenant_id not in known:
                try:
                    known[tenant_id] = directory.get(tenant_id) is not None
                except DirectoryError:
                    known[tenant_id] = False
            return known[tenant_id]

        jobs = [job for job in mail_queue.attention_jobs(limit=None) if is_company(job["tenantId"])][:200]
        return JSONResponse(
            {"jobs": [{**mail_job_row(job), "recipient": mask_email(job["recipient"]), "tenantId": job["tenantId"],
                       "companyName": mail_company_name(job["tenantId"], names)}
                      for job in jobs]},
            headers={"Cache-Control": "no-store"})

    @app.post("/staff/v1/mail/held/{job_id}/retry")
    def retry_held_mail(job_id: str, who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        try:
            tenant_id = mail_queue.tenant_of(mail_job_id(job_id))
            check_staff_invite_mail(who, job_id)
            job, _ = mail_queue.retry(tenant_id, job_id, who.email)
        except (LookupError, ValueError, RuntimeError) as error:
            raise mail_failure(error) from error
        return JSONResponse({"job": mail_job_row(job)}, headers={"Cache-Control": "no-store"})

    @app.post("/staff/v1/mail/held/{job_id}/handled")
    def handle_held_mail(job_id: str, who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        try:
            tenant_id = mail_queue.tenant_of(mail_job_id(job_id))
            job = mail_queue.mark_handled(tenant_id, job_id, who.email)
        except (LookupError, ValueError) as error:
            raise mail_failure(error) from error
        return JSONResponse({"job": mail_job_row(job)}, headers={"Cache-Control": "no-store"})

    @app.get("/staff/v1/companies/{tenant_id}/mail-jobs")
    def list_mail_jobs(
        tenant_id: str, limit: int = 50, after: str | None = None,
        _: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        company_record(tenant_id)
        try:
            page = mail_queue.list_jobs(tenant_id, limit=limit, after=after)
        except ValueError as error:
            raise _bad_request(str(error)) from error
        return JSONResponse({"jobs": [mail_job_row(job) for job in page["jobs"]], "nextAfter": page["nextAfter"]},
                            headers={"Cache-Control": "no-store"})

    @app.post("/staff/v1/companies/{tenant_id}/mail-jobs/{job_id}/retry")
    def retry_mail_job(
        tenant_id: str, job_id: str, body: dict[str, Any] | None = Body(default=None),
        who: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        body = body or {}
        confirm = body.get("confirmDuplicateRisk", False)
        if set(body) - {"confirmDuplicateRisk"} or not isinstance(confirm, bool):
            raise _bad_request("Supply only confirmDuplicateRisk as true or false.")
        company_record(tenant_id)
        check_staff_invite_mail(who, job_id)
        try:
            job, created = mail_queue.retry(tenant_id, mail_job_id(job_id), who.email,
                                            confirm_duplicate_risk=confirm)
        except (LookupError, ValueError, RuntimeError) as error:
            raise mail_failure(error) from error
        return JSONResponse({"job": mail_job_row(job)}, status_code=201 if created else 200,
                            headers={"Cache-Control": "no-store"})

    @app.post("/staff/v1/companies/{tenant_id}/mail-jobs/{job_id}/handled")
    def handle_mail_job(
        tenant_id: str, job_id: str, who: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        company_record(tenant_id)
        try:
            job = mail_queue.mark_handled(tenant_id, mail_job_id(job_id), who.email)
        except (LookupError, ValueError) as error:
            raise mail_failure(error) from error
        return JSONResponse({"job": mail_job_row(job)}, headers={"Cache-Control": "no-store"})

    @app.get("/staff/v1/plans")
    def list_plans(_: auth.StaffIdentity = Depends(operator_staff)) -> dict[str, Any]:
        return jsonable({"plans": plan_store.list_plans()})

    @app.put("/staff/v1/plans/{plan_id}")
    def put_plan(
        plan_id: str,
        body: dict[str, Any] = Body(...),
        who: auth.StaffIdentity = Depends(staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        content = clean_version(body)
        visibility = None if body.get("visibility") is None else clean_visibility(body["visibility"])
        if price_changes(plan_store, check_plan_id(plan_id), content):
            return needs_approval(PACKAGE_PRICE)
        steps = subscription_service.plan_put_steps()
        operation_id = begin(
            idempotency_key=key,
            action=ACTION_PLAN_PUT,
            actor=who.email,
            tenant_id=None,
            reason=_reason(body, "Plan version"),
            ticket=_ticket(body),
            field_names=sorted(content),
            params={
                "planId": check_plan_id(plan_id),
                "content": content,
                "visibility": visibility,
                "createdBy": who.email,
                "priceLocked": True,
            },
            step_names=[step.name for step in steps],
        )
        return run_operation(operation_id, steps)

    @app.post("/staff/v1/plans/refresh")
    def refresh_plans(who: auth.StaffIdentity = Depends(staff)) -> dict[str, list[str]]:
        return subscription_service.refresh_plans(actor=who.email)

    @app.post("/staff/v1/plans/{plan_id}/retire")
    def retire_plan(
        plan_id: str,
        body: dict[str, Any] | None = Body(default=None),
        who: auth.StaffIdentity = Depends(staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        if plan_store.get_plan(check_plan_id(plan_id)) is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown plan.")
        steps = subscription_service.plan_retire_steps()
        operation_id = begin(
            idempotency_key=key,
            action=ACTION_PLAN_RETIRE,
            actor=who.email,
            tenant_id=None,
            reason=_reason(body or {}, "Plan retired"),
            ticket=_ticket(body or {}),
            field_names=[],
            params={"planId": plan_id},
            step_names=[step.name for step in steps],
        )
        return run_operation(operation_id, steps)

    def begin_subscription(
        who: auth.StaffIdentity,
        key: str,
        tenant_id: str,
        change: dict[str, Any],
        reason: str,
        ticket: str | None,
    ) -> tuple[str, list[Step]]:
        steps = subscription_service.subscription_steps()
        operation_id = begin(
            idempotency_key=key,
            action=ACTION_SUBSCRIPTION,
            actor=who.email,
            tenant_id=tenant_id,
            reason=reason,
            ticket=ticket,
            field_names=sorted(change),
            params={"tenantId": tenant_id, "change": change, "requestedBy": who.email},
            step_names=[step.name for step in steps],
        )
        return operation_id, steps

    @app.get("/staff/v1/companies/{tenant_id}/subscription")
    def get_subscription(
        tenant_id: str, _: auth.StaffIdentity = Depends(operator_staff)
    ) -> dict[str, Any]:
        company_record(tenant_id)
        subscription = plan_store.get_subscription(tenant_id)
        if subscription is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No subscription yet.")
        try:
            effective = plan_store.effective(tenant_id)
        except PlanProblem as problem:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(problem)) from problem
        return jsonable({"subscription": subscription, "effective": effective})

    @app.put("/staff/v1/companies/{tenant_id}/subscription")
    def put_subscription(tenant_id: str, _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        return JSONResponse(
            {"detail": "A subscription cannot be set directly. Change the package with the package route."},
            status_code=status.HTTP_409_CONFLICT, headers={"Cache-Control": "no-store"})

    @app.post("/staff/v1/companies/{tenant_id}/overrides")
    def add_override(tenant_id: str, _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        return needs_approval(PLAN_OVERRIDE)

    @app.post("/staff/v1/companies/{tenant_id}/seats/sweep")
    def sweep_seats(tenant_id: str, _: auth.StaffIdentity = Depends(staff)) -> dict[str, int]:
        return {"released": invitation_service.release_stale_seats(company_record(tenant_id))}

    @app.post("/staff/v1/companies/{tenant_id}/usage/reconcile")
    def reconcile_usage(tenant_id: str, _: auth.StaffIdentity = Depends(staff)) -> dict[str, Any]:
        company_record(tenant_id)
        return jsonable(reconciler.reconcile(tenant_id))

    @app.post("/staff/v1/companies/{tenant_id}/prepare-data")
    def prepare_company_data(
        tenant_id: str, body: dict[str, Any] = Body(default={}), who: auth.StaffIdentity = Depends(staff),
    ) -> JSONResponse:
        if set(body) - {"apply", "resume"}:
            raise _bad_request("Supply only apply or resume.")
        record = company_record(tenant_id)
        access = access_for(record["location"])
        packages = plan_store.public_plans()
        current = (plan_store.get_subscription(tenant_id) or {}).get("planId")
        if body.get("apply") is not True and body.get("resume") is not True:
            return no_store(prepare_data.report(access.db, packages, current, auth_client=access.auth))
        require_earlier_green(tenant_id, 3)
        if body.get("resume") is True:
            result = prepare_data.resume(access.db, packages, current, auth_client=access.auth)
            audit_log.record(actor=who.email, action="company.data_prepare_resumed", tenant_id=tenant_id,
                             summary="A half-done preparation of company data was resumed.",
                             key=f"prepare-resume:{tenant_id}:{uuid.uuid4().hex}")
            return no_store(result)
        result = prepare_data.prepare(access.db, packages, current, auth_client=access.auth)
        audit_log.record(actor=who.email, action="company.data_prepared", tenant_id=tenant_id,
                         summary="Company data was prepared for package limits.",
                         key=f"prepare:{tenant_id}:{uuid.uuid4().hex}")
        return no_store(result)

    @app.get("/staff/v1/companies/{tenant_id}/lifecycle")
    def get_lifecycle(
        tenant_id: str, _: auth.StaffIdentity = Depends(operator_staff)
    ) -> dict[str, Any]:
        company_record(tenant_id)
        current = lifecycle_store.get(tenant_id)
        if current is None:
            return JSONResponse({"detail": "No lifecycle state yet.", "allowedNext": sorted(FIRST_STATES)},
                                status_code=status.HTTP_404_NOT_FOUND)
        try:
            projection = TenantLifecycle(access_for(company_record(tenant_id)["location"])).current()
        except LifecycleConflict:
            projection = None
        return jsonable(
            {
                "lifecycle": {
                    **{name: value for name, value in current.items() if name != "previousState"},
                    "activationReceiptId": current.get("activationReceiptId"),
                },
                "projection": projection,
                "allowedNext": sorted(LIFECYCLE_TRANSITIONS.get(current["state"], ())),
            }
        )

    @app.put("/staff/v1/companies/{tenant_id}/lifecycle")
    def put_lifecycle(
        tenant_id: str,
        body: dict[str, Any] = Body(...),
        who: auth.StaffIdentity = Depends(operator_staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        company_record(tenant_id)
        required = {"state", "expectedRevision", "paymentEntryId", "reason", "ticket"}
        if set(body) != required:
            raise _bad_request("Supply exactly state, expectedRevision, paymentEntryId, reason and ticket.")
        state = body.get("state")
        expected = body.get("expectedRevision")
        payment_entry_id = body.get("paymentEntryId")
        if state not in STATES:
            raise _bad_request("Choose a valid lifecycle state.")
        if type(expected) is not int or expected < 0:
            raise _bad_request("expectedRevision must be a whole number of 0 or more.")
        if state == "active" and not isinstance(payment_entry_id, str):
            raise _bad_request("Active status requires a paymentEntryId with current coverage.")
        if state != "active" and payment_entry_id is not None:
            raise _bad_request("paymentEntryId is only valid for active status.")
        if state == "active":
            require_earlier_green(tenant_id, 8)
        if state in _APPROVAL_STATES:
            return needs_approval(_APPROVAL_STATES[state])
        if state == "active" and (lifecycle_store.get(tenant_id) or {}).get("state") in REACTIVATABLE:
            return needs_approval(LIFECYCLE_REACTIVATE)
        reason = _reason(body, "Lifecycle change")
        ticket = _ticket(body)
        steps = lifecycle_service.transition_steps()
        params = {
            "tenantId": tenant_id,
            "state": state,
            "expectedRevision": expected,
            "paymentEntryId": payment_entry_id,
            "reason": reason,
            "ticket": ticket,
            "requestedBy": who.email,
        }
        operation_id = begin(
            idempotency_key=key,
            action=ACTION_LIFECYCLE,
            actor=who.email,
            tenant_id=tenant_id,
            reason=reason,
            ticket=ticket,
            field_names=["state", "expectedRevision", "paymentEntryId"],
            params=params,
            step_names=[step.name for step in steps],
        )
        return run_operation(operation_id, steps)

    @app.post("/staff/v1/operations/recover")
    def recover(_: auth.StaffIdentity = Depends(staff)) -> dict[str, list[str]]:
        finished = runner.recover(
            build_actions(
                database,
                directory,
                signing,
                invitation_service,
                subscriptions=subscription_service,
                products=product_service,
                lifecycle=lifecycle_service,
                approvals=approval_book,
                project_setup=project_setup,
            )
        )
        invitation_service.sweep_failed()
        return {"finished": finished}

    @app.post("/staff/v1/directory/refresh")
    def refresh(
        body: RefreshDirectory | None = None, _: auth.StaffIdentity = Depends(staff)
    ) -> dict[str, list[str]]:
        request = body or RefreshDirectory()
        try:
            return renew_directory_records(directory, within=timedelta(days=request.withinDays),
                                           tenant_ids=request.tenantIds)
        except GoogleAPICallError as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The directory could not be refreshed.",
            ) from error

    @app.get("/staff/v1/companies/{tenant_id}/payments")
    def list_payments(tenant_id: str, who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        company_record(tenant_id)
        return JSONResponse(payment_ledger.snapshot(tenant_id, who.email, auth.person_of(who),
                                                    solo_owner(database, who.email)),
                            headers={"Cache-Control": "no-store"})

    @app.post("/staff/v1/companies/{tenant_id}/payments", status_code=201)
    def record_payment(
        tenant_id: str, body: dict[str, Any] = Body(...),
        who: auth.StaffIdentity = Depends(operator_staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        company_record(tenant_id)
        require_earlier_green(tenant_id, 5)
        return JSONResponse(payment_ledger.record(tenant_id, key, body, who.email,
                                                  is_owner=who.role == "owner", person=auth.person_of(who)),
                            status_code=201, headers={"Cache-Control": "no-store"})

    @app.post("/staff/v1/companies/{tenant_id}/payments/{receipt_id}/check")
    def check_payment(
        tenant_id: str, receipt_id: str, who: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        company_record(tenant_id)
        require_earlier_green(tenant_id, 5)
        return no_store(payment_ledger.check(tenant_id, receipt_id, who.email,
                                             solo=lambda transaction: solo_owner(database, who.email, transaction),
                                             person=auth.person_of(who)))

    @app.get("/staff/v1/payments/to-check")
    def payments_to_check(who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        names = {record["tenantId"]: record["legalName"] for record in directory_records()}
        return no_store({"payments": [
            {**row, "companyName": names.get(row["tenantId"])}
            for row in payment_ledger.awaiting_check(who.email, auth.person_of(who),
                                                     solo_owner(database, who.email))]})

    def invoice_for(who: auth.StaffIdentity, invoice: dict[str, Any]) -> dict[str, Any]:
        return {**invoice, "canExtend": who.role in REQUEST_ROLES and extension_problem(invoice) is None}

    @app.get("/staff/v1/invoices")
    def list_invoices(tenantId: str | None = None,
                      who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        if tenantId is not None:
            company_record(tenantId)
        return no_store({"invoices": [invoice_for(who, row) for row in invoice_book.list_invoices(tenantId)]})

    @app.get("/staff/v1/invoices/{invoice_id}")
    def get_invoice(invoice_id: str, who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        return no_store(invoice_for(who, invoice_book.get(invoice_id)))

    @app.post("/staff/v1/companies/{tenant_id}/invoices", status_code=201)
    def create_invoice_draft(
        tenant_id: str, body: dict[str, Any] = Body(...),
        who: auth.StaffIdentity = Depends(operator_staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        company_record(tenant_id)
        require_earlier_green(tenant_id, 5)
        return no_store(invoice_book.create_draft(tenant_id, key, body, who.email), status.HTTP_201_CREATED)

    @app.patch("/staff/v1/invoices/{invoice_id}")
    def edit_invoice_draft(
        invoice_id: str, body: dict[str, Any] = Body(...), who: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        return no_store(invoice_book.edit_draft(invoice_id, body, who.email))

    @app.post("/staff/v1/invoices/{invoice_id}/issue")
    def issue_invoice(invoice_id: str, who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        tenant_id = (database.collection("invoices").document(invoice_id).get().to_dict() or {}).get("tenantId")
        if tenant_id:
            require_earlier_green(tenant_id, 5)
        return no_store(invoice_book.issue(invoice_id, who.email))

    @app.post("/staff/v1/invoices/{invoice_id}/send")
    def send_invoice(
        invoice_id: str, body: dict[str, Any] | None = Body(default=None),
        who: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        body = body or {}
        confirm = body.get("confirmDuplicateRisk", False)
        if set(body) - {"confirmDuplicateRisk"} or not isinstance(confirm, bool):
            raise _bad_request("Supply only confirmDuplicateRisk as true or false.")
        return no_store(invoice_book.send(invoice_id, who.email, confirm_duplicate_risk=confirm))

    @app.post("/staff/v1/invoices/{invoice_id}/void")
    def void_invoice_draft(invoice_id: str, who: auth.StaffIdentity = Depends(staff)) -> JSONResponse:
        return no_store(invoice_book.void_draft(invoice_id, who.email))

    @app.post("/staff/v1/invoices/{invoice_id}/credit-notes", status_code=201)
    def create_credit_note(invoice_id: str, _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        return needs_approval(CREDIT_NOTE)

    @app.post("/staff/v1/companies/{tenant_id}/payments/{receipt_id}/void", status_code=201)
    def void_payment(tenant_id: str, receipt_id: str, _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        return needs_approval(PAYMENT_VOID)

    def may_continue_directory_put(who: auth.StaffIdentity, record: Mapping[str, Any]) -> bool:
        return who.role == "owner" or (who.role == "engineer" and record.get("actor") == who.email)

    operator_retry_actions = frozenset({DIRECTORY_PUT, ACTION_SUBSCRIPTION, ACTION_REFRESH, ACTION_LIFECYCLE})

    def no_store(body: Any, status_code: int = 200) -> JSONResponse:
        return JSONResponse(jsonable(body), status_code=status_code, headers={"Cache-Control": "no-store"})

    def directory_records() -> list[dict[str, Any]]:
        try:
            return directory.list_records()
        except DirectoryError as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The company directory could not be verified.",
            ) from error

    def public_package(plan_id: Any) -> dict[str, Any]:
        plan = plan_store.get_plan(check_plan_id(plan_id if isinstance(plan_id, str) else ""))
        version = None
        if plan and plan.get("status") == "active" and plan.get("visibility") == "public":
            version = plan_store.get_version(plan_id, plan["currentVersion"])
        if version is None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="That package is not available.")
        return {"planId": plan_id, "planVersion": plan["currentVersion"], "edition": version["edition"],
                "quotaSchemaVersion": version.get("quotaSchemaVersion", 1)}

    def begin_package_change(
        who: auth.StaffIdentity, key: str, tenant_id: str, body: Mapping[str, Any]
    ) -> tuple[str, list[Step]]:
        earlier = runner.get(operation_id_for(ACTION_SUBSCRIPTION, key))
        if earlier is not None:
            change = (earlier.get("params") or {}).get("change") or {}
            if (earlier.get("actor") != who.email or earlier.get("tenantId") != tenant_id
                    or [change.get(name) for name in ("planId", "billingInterval", "expectedRevision")]
                    != [body.get(name) for name in ("planId", "billingInterval", "expectedRevision")]):
                raise HTTPException(status_code=status.HTTP_409_CONFLICT,
                                    detail="This idempotency key was already used for a different request.")
            return earlier["operationId"], subscription_service.subscription_steps()
        target = public_package(body.get("planId"))
        interval = body.get("billingInterval")
        if interval not in BILLING_INTERVALS:
            raise _bad_request("Choose a monthly or yearly billing period.")
        expected = body.get("expectedRevision")
        if type(expected) is not int or expected < 0:
            raise _bad_request("expectedRevision must be a whole number of 0 or more.")
        current = plan_store.get_subscription(tenant_id)
        if (current and current.get("planId") == target["planId"] and current.get("billingInterval") == interval
                and (plan_store.version_in_effect(current) == target["planVersion"]
                     or ((plan_store.get_version(target["planId"], plan_store.version_in_effect(current))
                          or {}).get("prices") or {}).get(interval) is not None)):
            raise HTTPException(status_code=status.HTTP_409_CONFLICT,
                                detail="This company already has this package and billing period.")
        try:
            refusal = plan_store.upgrade_refusal(tenant_id, target["planId"])
            if refusal is not None:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=refusal)
            add_ons = carried_add_ons((current or {}).get("addOns"),
                                      plan_store.effective(tenant_id)["quotaSchemaVersion"],
                                      target["quotaSchemaVersion"]) if current else {}
        except PlanProblem as problem:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(problem)) from problem

        def moment(name: str) -> str | None:
            value = (current or {}).get(name)
            return None if value is None else format_timestamp(value)

        change = clean_subscription({
            "planId": target["planId"],
            "planVersion": target["planVersion"],
            "addOns": add_ons,
            "billingInterval": interval,
            "renewsAt": moment("renewsAt"),
            "trialEndsAt": moment("trialEndsAt"),
            "expectedRevision": expected,
        })
        return begin_subscription(who, key, tenant_id, change, _reason(body, "Package change"), None)

    @app.get("/staff/v1/packages")
    def list_packages(_: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        return no_store({"packages": plan_store.public_plans()})

    @app.get("/staff/v1/companies/{tenant_id}/packages")
    def company_packages(tenant_id: str, _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        company_record(tenant_id)
        current = plan_store.get_subscription(tenant_id)
        summary = None
        if current is not None:
            try:
                effective = plan_store.effective(tenant_id)
            except PlanProblem as problem:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(problem)) from problem
            summary = {
                "planId": effective["planId"], "planVersion": effective["planVersion"],
                "name": effective["name"], "edition": effective["edition"],
                "billingInterval": current.get("billingInterval"),
                "status": (lifecycle_store.get(tenant_id) or {}).get("state"),
                "revision": current.get("revision", 0), "limits": effective["limits"],
            }
        offers = []
        for offer in plan_store.public_plans():
            try:
                refusal = plan_store.upgrade_refusal(tenant_id, offer["planId"])
            except PlanProblem:
                refusal = UPGRADE_ONLY_MESSAGE
            offers.append({**offer, "canRequest": refusal is None, "requestReason": refusal})
        return no_store({"current": summary, "packages": offers})

    @app.post("/staff/v1/companies/{tenant_id}/package")
    def change_package(
        tenant_id: str,
        body: dict[str, Any] = Body(...),
        who: auth.StaffIdentity = Depends(operator_staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        company_record(tenant_id)
        if set(body) - {"planId", "billingInterval", "expectedRevision", "reason"}:
            raise _bad_request("Supply only planId, billingInterval, expectedRevision and reason.")
        require_earlier_green(tenant_id, 4)
        return run_operation(*begin_package_change(who, key, tenant_id, body))

    def require_earlier_green(tenant_id: str, step: int) -> None:
        draft_id = (database.collection(COMPANIES).document(tenant_id).get().to_dict() or {}).get("onboardingDraftId")
        if not draft_id:
            return
        if (lifecycle_store.get(tenant_id) or {}).get("state") not in (None, "lead"):
            return
        drafts.require_earlier_green(draft_id, step)

    def reading_access(tenant_id: str) -> Any:
        return access_for(company_record(tenant_id)["location"])

    def read_project(record: Mapping[str, Any]) -> None:
        usage_ref(access_for(record["location"]).db).get(retry=None, timeout=prepare_data.CHECK_TIMEOUT_SECONDS)

    def read_people(tenant_id: str) -> dict[str, Any]:
        access = reading_access(tenant_id)
        current = (plan_store.get_subscription(tenant_id) or {}).get("planId")
        found = prepare_data.report(access.db, plan_store.public_plans(), current, auth_client=access.auth)
        return {"prepared": found["prepared"], "halfDone": found["halfDone"], "running": found["running"],
                "moves": len(found["moves"]),
                "blockers": [text for text in found["blockers"] if text != prepare_data.PREPARING]}

    def read_package(tenant_id: str) -> dict[str, Any]:
        subscription = plan_store.get_subscription(tenant_id)
        if subscription is None:
            return {"planId": None, "subscription": False, "projected": False, "recorded": False}
        parts = subscription_service.package_parts(tenant_id)
        if PART_UNKNOWN in parts.values():
            raise RuntimeError("Scoot could not read every part of the package: "
                               + ", ".join(PACKAGE_PARTS[name] for name, state in parts.items() if state == PART_UNKNOWN))
        return {"planId": subscription["planId"], "subscription": parts["subscription"] == PART_SAVED,
                "projected": parts["companyLimits"] == PART_SAVED, "recorded": parts["companyRecord"] == PART_SAVED,
                "operationId": failed_package_operation(tenant_id)}

    def failed_package_operation(tenant_id: str) -> str | None:
        rows = [snapshot.to_dict() or {} for snapshot in database.collection("operations").where(
            filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream()]
        failed = [row for row in rows if row.get("status") == "failed" and not row.get("closed")
                  and row.get("action") == ACTION_SUBSCRIPTION]
        newest = max(failed, key=lambda row: row.get("createdAt") or datetime.min.replace(tzinfo=timezone.utc),
                     default=None)
        return None if newest is None else newest["operationId"]

    def read_payment(tenant_id: str) -> dict[str, Any]:
        now = datetime.now(timezone.utc)
        cover = payment_ledger.coverage(tenant_id, now)
        entries = payment_ledger.snapshot(tenant_id)["entries"]
        invoices = [row for row in invoice_book.list_invoices(tenant_id) if row.get("status") != VOID]
        paid_starts = [parse_timestamp(row["periodStart"]) for row in invoices if row.get("status") == PAID]
        later = sorted(start for start in paid_starts if start > now)
        return {"invoice": bool(invoices),
                "coverStarts": f"{local_day(later[0]).day} {local_day(later[0]):%B %Y}" if later else None,
                "issued": any(row.get("status") in (ISSUED, SENT, PAID) for row in invoices),
                "awaitingCheck": any(entry.get("canCheck") for entry in entries),
                "checked": bool(cover.checked_covering)}

    def read_admin(tenant_id: str, email: str) -> dict[str, Any]:
        found = first_admin_state(reading_access(tenant_id), email)
        return {"state": found["state"], "line": found["line"]}

    def default_rules_reader(location: Mapping[str, Any]) -> Callable[[], Any] | None:
        if auth.emulator_mode():
            return None
        return tenant_readiness.deployed_rules_reader(location["projectId"], location.get("databaseId") or "(default)")

    reader_for = rules_reader_for or default_rules_reader

    def read_rules(tenant_id: str) -> dict[str, Any]:
        reader = reader_for(company_record(tenant_id)["location"])
        if reader is None:
            return {"state": "unreadable", "line": "Scoot cannot read the deployed rules from here."}
        rules_file = REPO_ROOT / "admin_dashboard" / "firestore.rules"
        if not rules_file.exists():
            return {"state": "unreadable", "line": "This Scoot release has no rules file to compare with."}
        deployed = reader()
        if deployed is None:
            return {"state": "unreadable",
                    "line": "Scoot cannot read the deployed rules. Either the main Scoot rules are not installed in "
                            "this project, or the key lacks the Firebase Rules Viewer role."}
        expected = tenant_readiness.rules_sha256(rules_file.read_text(encoding="utf-8"))
        if deployed.sha256 == expected:
            return {"state": "match", "line": ""}
        return {"state": "differs", "line": "The deployed rules are not the rules of this Scoot release."}

    drafts = OnboardingDrafts(
        database, audit_log, package_check=public_package,
        reads=Reads(record=directory.get, lifecycle=lambda tenant: (lifecycle_store.get(tenant) or {}).get("state"),
                    project=read_project, people=read_people, package=read_package, payment=read_payment,
                    admin=read_admin, rules=read_rules))

    project_setup = ProjectSetup(runner=runner, directory=directory, drafts=drafts, lifecycle=lifecycle_service,
                                 access_for=access_for,
                                 web_config_reader=connect_web_config_reader or firebase_web_config_reader,
                                 rules_reader=connect_rules_reader)

    def draft_for(who: auth.StaffIdentity, draft: dict[str, Any]) -> dict[str, Any]:
        return {**draft, "canExtend": draft["canExtend"] and who.role == "owner"}

    @app.post("/staff/v1/onboarding-drafts", status_code=201)
    def create_draft(
        body: dict[str, Any] = Body(...),
        who: auth.StaffIdentity = Depends(draft_staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        return no_store(draft_for(who, drafts.create(who.email, _idempotency_key(idempotency_key), body)),
                        status.HTTP_201_CREATED)

    @app.get("/staff/v1/onboarding-drafts")
    def list_drafts(
        status_filter: str | None = Query(default=None, alias="status"),
        who: auth.StaffIdentity = Depends(task_staff),
    ) -> JSONResponse:
        return no_store({"drafts": [draft_for(who, row) for row in drafts.list_drafts(status_filter)]})

    @app.get("/staff/v1/onboarding-drafts/{draft_id}")
    def get_draft(draft_id: str, who: auth.StaffIdentity = Depends(task_staff)) -> JSONResponse:
        return no_store(draft_for(who, drafts.get(draft_id)))

    @app.put("/staff/v1/onboarding-drafts/{draft_id}")
    def update_draft(
        draft_id: str, body: dict[str, Any] = Body(...), who: auth.StaffIdentity = Depends(draft_staff)
    ) -> JSONResponse:
        return no_store(draft_for(who, drafts.update(who.email, draft_id, body)))

    @app.post("/staff/v1/onboarding-drafts/{draft_id}/cancel")
    def cancel_draft(draft_id: str, who: auth.StaffIdentity = Depends(draft_staff)) -> JSONResponse:
        return no_store(draft_for(who, drafts.cancel(who.email, draft_id)))

    @app.post("/staff/v1/onboarding-drafts/{draft_id}/extend")
    def extend_draft(draft_id: str, who: auth.StaffIdentity = Depends(staff)) -> JSONResponse:
        return no_store(drafts.extend(who.email, draft_id))

    @app.post("/staff/v1/onboarding-drafts/{draft_id}/first-admin")
    def give_first_admin_access(
        draft_id: str, body: dict[str, Any] = Body(default={}), who: auth.StaffIdentity = Depends(draft_staff)
    ) -> JSONResponse:
        if set(body) - {"employeeCode"}:
            raise _bad_request("Supply only employeeCode.")
        draft, employee_code = drafts.first_admin_ready(draft_id, body.get("employeeCode"))
        require_earlier_green(draft["tenantId"], 6)
        try:
            granted = invitation_service.grant_first_admin(
                company_record(draft["tenantId"]), actor=who.email, draft_id=draft_id, name=draft["adminName"],
                email=draft["adminEmail"], employee_code=employee_code)
        except InviteConfigError as error:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Invitations are not available.") from error
        drafts.record_first_admin(who.email, draft_id, granted)
        return no_store({**granted, "draft": draft_for(who, drafts.get(draft_id))})

    @app.post("/staff/v1/onboarding-drafts/{draft_id}/first-admin/promote")
    def promote_first_admin(
        draft_id: str, body: dict[str, Any] = Body(...), who: auth.StaffIdentity = Depends(staff)
    ) -> JSONResponse:
        if set(body) - {"employeeCode", "expectedRow"} or "employeeCode" not in body:
            raise _bad_request("Supply employeeCode and, to confirm, expectedRow.")
        draft, employee_code = drafts.first_admin_ready(draft_id, body["employeeCode"])
        require_earlier_green(draft["tenantId"], 6)
        try:
            result = invitation_service.promote_to_first_admin(
                company_record(draft["tenantId"]), draft, employee_code, body.get("expectedRow"), actor=who.email)
        except InviteConfigError as error:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Invitations are not available.") from error
        if result["state"] == "preview":
            return no_store(result)
        drafts.record_first_admin(who.email, draft_id, result)
        return no_store({**result, "draft": draft_for(who, drafts.get(draft_id))})

    @app.post("/staff/v1/onboarding-drafts/{draft_id}/first-admin/resend")
    def resend_first_admin(draft_id: str, who: auth.StaffIdentity = Depends(draft_staff)) -> JSONResponse:
        draft = drafts.data(draft_id)
        if draft["status"] != "completed" or not draft.get("tenantId") or not draft.get("adminEmail"):
            raise HTTPException(status.HTTP_409_CONFLICT, "Connect the project first.")
        require_earlier_green(draft["tenantId"], 6)
        try:
            result = invitation_service.resend_first_admin_invitation(
                company_record(draft["tenantId"]), draft, actor=who.email)
        except InviteConfigError as error:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Invitations are not available.") from error
        drafts.record_first_admin(who.email, draft_id, result)
        return no_store({**result, "draft": draft_for(who, drafts.get(draft_id))})

    @app.post("/staff/v1/onboarding-drafts/{draft_id}/connect")
    def connect_draft_project(
        draft_id: str, body: dict[str, Any] = Body(...), who: auth.StaffIdentity = Depends(engineer_staff),
    ) -> JSONResponse:
        if set(body) != {"projectId"}:
            raise _bad_request("Supply only projectId.")
        result = project_setup.connect(who.email, draft_id, body["projectId"])
        code = (status.HTTP_409_CONFLICT if result["refusal"]
                else status.HTTP_202_ACCEPTED if result["retryLater"] else status.HTTP_200_OK)
        return no_store(result, code)

    @app.get("/staff/v1/onboarding-drafts/{draft_id}/connect")
    def connect_report(
        draft_id: str, project_id: str = Query(alias="projectId"), _: auth.StaffIdentity = Depends(engineer_staff),
    ) -> JSONResponse:
        return no_store(project_setup.report(draft_id, project_id, project_setup.company_for(draft_id, project_id)))

    @app.get("/staff/v1/project-access")
    def project_access(_: auth.StaffIdentity = Depends(engineer_staff)) -> JSONResponse:
        return no_store({"serviceEmail": service_email()})

    @app.get("/staff/v1/companies/{tenant_id}/people-defects")
    def people_defects(tenant_id: str, _: auth.StaffIdentity = Depends(staff)) -> JSONResponse:
        access = access_for(company_record(tenant_id)["location"])
        return no_store({"items": access_repair.people_defects(access.db, access.auth),
                         "archived": access_migration.archived_rows(access.db)})

    @contextlib.contextmanager
    def people_refusals() -> Iterator[None]:
        try:
            yield
        except access_repair.PeopleInvalid as error:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, str(error)) from error
        except access_repair.PeopleNotFound as error:
            raise HTTPException(status.HTTP_404_NOT_FOUND, str(error)) from error

    @app.post("/staff/v1/companies/{tenant_id}/people-fixes")
    def apply_people_fix(
        tenant_id: str, body: dict[str, Any] = Body(default={}), who: auth.StaffIdentity = Depends(staff),
    ) -> JSONResponse:
        access = access_for(company_record(tenant_id)["location"])
        item_id, fix_id = body.get("itemId"), body.get("fixId")
        if not isinstance(item_id, str) or not isinstance(fix_id, str):
            raise CommandProblem("Choose a person and a fix.")
        if body.get("apply") is not True:
            with people_refusals():
                return no_store(access_repair.preview_fix(access.db, access.auth, item_id, fix_id))
        expected = body.get("expected")
        if not isinstance(expected, dict):
            raise CommandProblem("Open the preview before you apply.")
        with people_refusals():
            result = access_repair.apply_fix(access.db, access.auth, item_id, fix_id, expected, who.email)
        audit_log.record(actor=who.email, action="company.people_fixed", tenant_id=tenant_id,
                         summary="A person's record was fixed.", key=f"people-fix:{tenant_id}:{uuid.uuid4().hex}")
        return no_store(result)

    @app.post("/staff/v1/companies/{tenant_id}/people-restore")
    def restore_people_row(
        tenant_id: str, body: dict[str, Any] = Body(default={}), who: auth.StaffIdentity = Depends(staff),
    ) -> JSONResponse:
        access = access_for(company_record(tenant_id)["location"])
        archive_id = body.get("archiveId")
        if not isinstance(archive_id, str) or not archive_id:
            raise CommandProblem("Choose a record to restore.")
        result = access_migration.restore_archived(access.db, archive_id, who.email)
        audit_log.record(actor=who.email, action="company.people_restored", tenant_id=tenant_id,
                         summary="An archived record was restored.",
                         key=f"people-restore:{tenant_id}:{uuid.uuid4().hex}")
        return no_store(result)

    def operation_row(data: Mapping[str, Any]) -> dict[str, Any]:
        error = data.get("error") or {}
        return {
            "operationId": data.get("operationId"),
            "action": data.get("action"),
            "status": data.get("status"),
            "reason": data.get("reason"),
            "createdAt": data.get("createdAt"),
            "updatedAt": data.get("updatedAt"),
            "errorType": error.get("type"),
            "errorMessage": error.get("message") if error.get("type") in _SAFE_ERRORS else None,
            "canRetry": (data.get("status") == "pending" and data.get("action") in operator_retry_actions)
            or (data.get("status") == "failed" and not data.get("closed") and data.get("action") == ACTION_SUBSCRIPTION),
        }

    def needs_attention(data: Mapping[str, Any], since: datetime) -> bool:
        updated = data.get("updatedAt")
        return data.get("status") == "pending" or (
            data.get("status") == "failed" and not data.get("closed") and isinstance(updated, datetime) and updated >= since)

    @app.get("/staff/v1/companies/{tenant_id}/operations")
    def company_operations(tenant_id: str, _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        company_record(tenant_id)
        since = datetime.now(timezone.utc) - timedelta(days=ATTENTION_DAYS)
        rows = [
            snapshot.to_dict() or {}
            for snapshot in database.collection("operations")
            .where(filter=firestore.FieldFilter("tenantId", "==", tenant_id)).stream()
        ]
        rows = sorted((row for row in rows if needs_attention(row, since)),
                      key=lambda row: row.get("createdAt") or since, reverse=True)
        return no_store({"operations": [operation_row(row) for row in rows[:20]]})

    @app.post("/staff/v1/operations/{operation_id}/retry")
    def retry_operation(operation_id: str, who: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        if not _OPERATION_ID.fullmatch(operation_id):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown operation.")
        record = runner.get(operation_id)
        if record is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown operation.")
        if record.get("action") not in operator_retry_actions:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                                detail="This kind of operation cannot be tried again here.")
        if record.get("action") == DIRECTORY_PUT and not may_continue_directory_put(who, record):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                                detail="Only the owner can try this change again.")
        if record.get("status") == "failed" and record.get("action") == ACTION_SUBSCRIPTION:
            try:
                steps = subscription_service.reopen_package(operation_id, who.email)
            except CommandProblem as error:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
            return run_operation(operation_id, steps)
        if record.get("status") != "pending":
            return JSONResponse(outcome(operation_id, record))
        lease = record.get("leaseUntil")
        if isinstance(lease, datetime) and lease >= datetime.now(timezone.utc):
            raise HTTPException(status_code=status.HTTP_409_CONFLICT,
                                detail="This operation is still running. Try again in a few minutes.")
        actions = build_actions(
            database, directory, signing, invitation_service,
            subscriptions=subscription_service, products=product_service, lifecycle=lifecycle_service,
            approvals=approval_book, project_setup=project_setup,
        )
        return run_operation(operation_id, actions[record["action"]])

    def plan_request_rows(records: list[dict[str, Any]], snapshots: list[Any]) -> list[dict[str, Any]]:
        names = {record["tenantId"]: record["legalName"] for record in records}
        requests = []
        for snapshot in snapshots:
            data = snapshot.to_dict() or {}
            if isinstance(data.get("tenantId"), str) and isinstance(data.get("planId"), str):
                requests.append((snapshot, data))
        subscriptions = plan_store.get_subscriptions({data["tenantId"] for _, data in requests})
        plans = plan_store.get_plans({data["planId"] for _, data in requests if PLAN_ID.fullmatch(data["planId"])})
        versions = plan_store.get_versions(
            {(plan_id, plan["currentVersion"]) for plan_id, plan in plans.items() if plan})
        plan_names = {
            plan_id: (versions.get((plan_id, plan["currentVersion"])) or {}).get("name") if plan else None
            for plan_id, plan in plans.items()
        }
        rows = []
        for snapshot, data in requests:
            tenant_id, plan_id = data["tenantId"], data["planId"]
            current = subscriptions.get(tenant_id) or {}
            rows.append({
                "requestId": snapshot.id, "tenantId": tenant_id, "companyName": names.get(tenant_id),
                "planId": plan_id, "planName": plan_names.get(plan_id), "interval": data.get("interval"),
                "status": data.get("status"), "createdAt": data.get("createdAt"),
                "declineReason": data.get("declineReason"),
                "open": plan_store.request_is_open(data, current),
            })
        return rows

    def open_plan_request_count() -> int:
        requested = [snapshot.to_dict() or {} for snapshot in database.collection(PLAN_REQUESTS).where(
            filter=firestore.FieldFilter("status", "==", "requested")).stream()]
        requested = [data for data in requested
                     if isinstance(data.get("tenantId"), str) and isinstance(data.get("planId"), str)]
        subscriptions = plan_store.get_subscriptions({data["tenantId"] for data in requested})
        return sum(1 for data in requested
                   if plan_store.request_is_open(data, subscriptions.get(data["tenantId"]) or {}))

    @app.get("/staff/v1/plan-requests")
    def list_plan_requests(
        limit: int = 50, after: str | None = None, _: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        if type(limit) is not int or not 1 <= limit <= 200:
            raise _bad_request("limit must be between 1 and 200.")
        collection = database.collection(PLAN_REQUESTS)
        query = collection.order_by("createdAt", direction=firestore.Query.DESCENDING)
        if after is not None:
            last = collection.document(after).get() if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", after) else None
            if last is None or not last.exists:
                raise _bad_request("after must be a request ID from a previous page.")
            query = query.start_after(last)
        snapshots = list(query.limit(limit + 1).stream())
        return no_store({"requests": plan_request_rows(directory_records(), snapshots[:limit]),
                         "nextAfter": snapshots[limit - 1].id if len(snapshots) > limit else None})

    @app.post("/staff/v1/plan-requests/{tenant_id}/decline")
    def decline_plan_request(
        tenant_id: str, body: dict[str, Any] = Body(...), who: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        reason = " ".join(body.get("reason", "").split()) if isinstance(body.get("reason"), str) else ""
        if set(body) != {"reason"} or not 3 <= len(reason) <= 300:
            raise _bad_request("Give a reason of 3 to 300 characters.")
        record = company_record(tenant_id)
        request = plan_store.decline_plan_request(
            tenant_id, reason=reason, decided_by=who.email, now=datetime.now(timezone.utc))
        audit_log.record(
            actor=who.email, action="plan_request.declined", tenant_id=tenant_id, key=request["requestKey"],
            summary="A plan request was declined.",
            refs={"planId": request["planId"], "interval": request["interval"], "reason": reason})
        mail = plan_store.mail_plan_request_declined(mail_queue, request=request, company_name=record["legalName"])
        return no_store({"status": "declined", "mail": mail})

    approver_staff = require(("owner", "operator"), "Only the owner or an operator can do this.")

    @app.post("/staff/v1/approvals", status_code=201)
    def request_approval(
        body: dict[str, Any] = Body(...),
        who: auth.StaffIdentity = Depends(approver_staff),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency_key(idempotency_key)
        return no_store(approval_book.request(who.email, who.role, key, body, person=auth.person_of(who)), status.HTTP_201_CREATED)

    @app.get("/staff/v1/approval-actions")
    def approval_actions(_: auth.StaffIdentity = Depends(verified_staff)) -> JSONResponse:
        return no_store({"actions": approval_book.action_labels()})

    @app.get("/staff/v1/approvals")
    def list_approvals(
        status_filter: str | None = Query(default=None, alias="status"),
        scope: str = "all", tenantId: str | None = None, limit: int = 50, after: str | None = None,
        who: auth.StaffIdentity = Depends(approver_staff),
    ) -> JSONResponse:
        return no_store(approval_book.list_approvals(
            who.email, who.role, status_filter=status_filter, scope=scope, tenant_id=tenantId,
            limit=limit, after=after, person=auth.person_of(who)))

    @app.get("/staff/v1/approvals/{approval_id}")
    def get_approval(approval_id: str, who: auth.StaffIdentity = Depends(approver_staff)) -> JSONResponse:
        return no_store(approval_book.get(approval_id, who.email, who.role, person=auth.person_of(who)))

    @app.post("/staff/v1/approvals/{approval_id}/approve")
    def approve_approval(approval_id: str, who: auth.StaffIdentity = Depends(approver_staff)) -> JSONResponse:
        result = approval_book.approve(approval_id, who.email, who.role, person=auth.person_of(who))
        pending = (result["operation"] or {}).get("status") == "pending"
        return no_store(result, status.HTTP_202_ACCEPTED if pending else status.HTTP_200_OK)

    @app.post("/staff/v1/approvals/{approval_id}/retry")
    def retry_approval(approval_id: str, who: auth.StaffIdentity = Depends(approver_staff)) -> JSONResponse:
        result = approval_book.retry(approval_id, who.email, who.role, person=auth.person_of(who))
        pending = (result["operation"] or {}).get("status") == "pending"
        return no_store(result, status.HTTP_202_ACCEPTED if pending else status.HTTP_200_OK)

    @app.post("/staff/v1/approvals/{approval_id}/close")
    def close_approval(
        approval_id: str, body: dict[str, Any] = Body(...), who: auth.StaffIdentity = Depends(approver_staff),
    ) -> JSONResponse:
        if set(body) != {"reason"}:
            raise _bad_request("Supply only reason.")
        return no_store(approval_book.close(approval_id, who.email, who.role, body["reason"],
                                            person=auth.person_of(who)))

    @app.post("/staff/v1/approvals/{approval_id}/reject")
    def reject_approval(
        approval_id: str, body: dict[str, Any] | None = Body(default=None),
        who: auth.StaffIdentity = Depends(approver_staff),
    ) -> JSONResponse:
        body = body or {}
        if set(body) - {"reason"}:
            raise _bad_request("Supply only reason.")
        return no_store(approval_book.reject(approval_id, who.email, who.role, body.get("reason"),
                                                   person=auth.person_of(who)))

    def audit_rows(actor: str | None, group: str | None, tenant_id: str | None, since: str | None,
                   until: str | None) -> tuple[str, str, list[dict[str, Any]]]:
        if tenant_id is not None:
            identity(tenant_id)
        start, end = default_range(since, until, now=datetime.now(timezone.utc))
        rows = audit_log.query(since=start, until=end, actor=actor.lower() if actor else None,
                               group=group or None, tenant_id=tenant_id)
        return start, end, rows

    @app.get("/staff/v1/audit-events")
    def list_audit_events(
        actor: str | None = None, group: str | None = None, tenantId: str | None = None,
        date_from: str | None = Query(default=None, alias="from"),
        date_to: str | None = Query(default=None, alias="to"),
        limit: int = 50, after: str | None = None,
        who: auth.StaffIdentity = Depends(operator_staff),
    ) -> JSONResponse:
        if type(limit) is not int or not 1 <= limit <= 200:
            raise _bad_request("limit must be between 1 and 200.")
        start, end, rows = audit_rows(actor, group, tenantId, date_from, date_to)
        if after is None:
            try:
                audit_log.record(actor=who.email, action="audit.viewed", tenant_id=None,
                                 key=uuid.uuid4().hex, summary="Audit log viewed.",
                                 refs={"from": start, "to": end, "actorFilter": actor, "groupFilter": group,
                                       "tenantFilter": tenantId})
            except Exception:
                _REQUEST_LOG.warning("The audit view could not be recorded.", exc_info=True)
        else:
            position = next((index for index, row in enumerate(rows) if row["eventId"] == after), None)
            if position is None:
                raise _bad_request("after must be an event ID from a previous page.")
            rows = rows[position + 1:]
        return no_store({"events": [{name: row.get(name) for name in EVENT_FIELDS} for row in rows[:limit]],
                         "nextAfter": rows[limit - 1]["eventId"] if len(rows) > limit else None,
                         "from": start, "to": end})

    @app.post("/staff/v1/audit-events/export")
    def export_audit_events(body: dict[str, Any] = Body(...), who: auth.StaffIdentity = Depends(staff)) -> Response:
        if set(body) - {"format", "actor", "group", "tenantId", "from", "to"}:
            raise _bad_request("Supply only format, actor, group, tenantId, from and to.")
        file_format = body.get("format", "json")
        if file_format not in ("json", "csv"):
            raise _bad_request("format is json or csv.")
        for name in ("actor", "group", "tenantId"):
            if body.get(name) is not None and not isinstance(body[name], str):
                raise _bad_request(f"{name} must be text.")
        start, end, rows = audit_rows(body.get("actor"), body.get("group"), body.get("tenantId"),
                                      body.get("from"), body.get("to"))
        if len(rows) > MAX_EXPORT_ROWS:
            raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                                detail="That export is too large. Choose fewer days.")
        events = [{name: row.get(name) for name in EVENT_FIELDS} for row in rows]
        audit_log.record(actor=who.email, action="audit.exported", tenant_id=body.get("tenantId"),
                         key=uuid.uuid4().hex, summary=f"Audit log exported as {file_format}.",
                         refs={"format": file_format, "from": start, "to": end, "count": len(events),
                               "actorFilter": body.get("actor"), "groupFilter": body.get("group")})
        headers = {"Cache-Control": "no-store"}
        if file_format == "json":
            return JSONResponse({"format": "json", "from": start, "to": end, "count": len(events),
                                 "events": events}, headers=headers)
        text = io.StringIO(newline="")
        writer = csv.writer(text)
        writer.writerow(EVENT_FIELDS)
        for event in events:
            writer.writerow([safe_cell(event[name]) for name in EVENT_FIELDS])
        headers["Content-Disposition"] = f'attachment; filename="audit-{start}_{end}.csv"'
        return Response(text.getvalue().encode("utf-8-sig"), media_type="text/csv; charset=utf-8", headers=headers)

    @app.get("/staff/v1/audit-events/verify")
    def verify_audit_day(day: str | None = None, chain: str | None = None,
                         _: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        chosen = check_day(day) if day is not None else local_date(datetime.now(timezone.utc))
        return no_store(audit_log.verify(chosen, check_chain(chain)) if chain is not None
                        else audit_log.verify_day(chosen))

    @app.get("/staff/v1/today")
    def today(_: auth.StaffIdentity = Depends(operator_staff)) -> JSONResponse:
        now = datetime.now(timezone.utc)
        horizon = now + timedelta(days=ATTENTION_DAYS)
        records = directory_records()
        lifecycle_states = {
            snapshot.id: (snapshot.to_dict() or {}).get("state")
            for snapshot in database.collection("lifecycle").select(["state"]).stream()
        }
        entries_by_tenant: dict[Any, list[dict[str, Any]]] = defaultdict(list)
        for snapshot in database.collection(ENTRIES).select(
                ["tenantId", "type", "entryId", "invoiceId", "periodStart", "periodEnd", "createdAt", "graceEnd",
                 "revision", "receiptId"]).stream():
            row = snapshot.to_dict() or {}
            entries_by_tenant[row.get("tenantId")].append(row)
        checked_entries = {snapshot.id for snapshot in database.collection(CHECKS).select([]).stream()}
        by_state: dict[str, int] = {}
        overdue = expiring = 0
        records_expired = sum(1 for record in records if record["expired"])
        records_expiring = sum(1 for record in records if not record["expired"]
                               and parse_timestamp(record["expiresAt"]) <= horizon)
        for record in records:
            state = lifecycle_states.get(record["tenantId"]) or "not_started"
            by_state[state] = by_state.get(state, 0) + 1
            end = coverage_of(entries_by_tenant.get(record["tenantId"], []), checked_entries,
                              record["tenantId"], now).paid_until
            if state in ("active", "past_due") and (end is None or end <= now):
                overdue += 1
            elif end is not None and now < end <= horizon:
                expiring += 1
        since = now - timedelta(days=ATTENTION_DAYS)
        pending = failed = 0
        for state_name in ("pending", "failed"):
            for snapshot in database.collection("operations").where(
                    filter=firestore.FieldFilter("status", "==", state_name)).select(
                        ["status", "updatedAt"]).stream():
                if needs_attention(snapshot.to_dict() or {}, since):
                    pending += state_name == "pending"
                    failed += state_name == "failed"
        names = {record["tenantId"]: record["legalName"] for record in records}
        grace_over = [{"tenantId": tenant, "legalName": names.get(tenant), "graceEndedAt": format_timestamp(ends)}
                      for tenant, ends in companies_past_grace(database, now)]
        renewal_blocked = [
            {"tenantId": row.get("tenantId"), "legalName": names.get(row.get("tenantId")),
             "reason": row.get("reason"), "coverEndsAt": row.get("coverEndsAt")}
            for row in sorted((snapshot.to_dict() or {} for snapshot in database.collection(RENEWAL_BLOCKS).stream()),
                              key=lambda row: row.get("coverEndsAt") or "")]
        return no_store({
            "companies": {"total": len(records), "byState": by_state, "recordsExpired": records_expired,
                          "recordsExpiringWithin14Days": records_expiring, "graceOver": grace_over,
                          "renewalBlocked": renewal_blocked},
            "payments": {"overdue": overdue, "expiringSoon": expiring, "withinDays": ATTENTION_DAYS},
            "operations": {"pending": pending, "failed": failed, "failedWithinDays": ATTENTION_DAYS},
            "planRequests": {"open": open_plan_request_count()},
        })

    staff_routes.install(app, book=staff_book, sign_in=sign_in, verified_staff=verified_staff, owner_only=staff,
                         ip_of=client_ip)
    install_mail_event_routes(app, database=database, audit=audit_log, operator_staff=operator_staff)
    install_account_link_routes(app, database=database, directory=directory, access_for=access_for, mail=mail_queue,
                                transport=transport_factory, staff_auth=staff_book.auth_client)
    install_sign_in_route(app, directory=directory, database=database, access_for=access_for, mail=mail_queue)
    install_client_routes(app, directory=directory, database=database, access_for=access_for, plans=plan_store)
    install_support_routes(app, directory, database, access_for)
    staff_capabilities.install_support_routes(app, database=database, directory=directory, verified_staff=verified_staff)
    install_export_routes(app, directory, database, access_for)
    return app

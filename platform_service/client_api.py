from __future__ import annotations

import re
import time
import hashlib
import json

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Literal, Mapping

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from firebase_admin import auth as admin_auth
from firebase_admin import exceptions as admin_exceptions
from google.cloud import firestore
from pydantic import BaseModel, ConfigDict, Field, StrictBool

from . import auth, config, invitations
from .audit import AuditLog
from .commands import CodedError, CommandProblem, PlanProblem, UsageMissing, plan_refusal
from .company_access import UNREACHABLE, CompanyAccess, require_active_admin
from .directory import DirectoryError, DirectoryStore
from .invoices import company_invoices
from .held_work import install_held_work_route
from .lifecycle import LIFECYCLE, lifecycle_view
from .operations import OperationStore
from .mail import MailQueue
from .plans import PlanStore, edition_features, jsonable
from .product_commands import ProductCommands
from .scheduler import LEASES
from .seats import usage_counts, usage_rows
from .tenancy import TenantContext, lifecycle_projection, resolve_tenant, retention_open

_WORKSPACE = re.compile(r"^[a-z0-9-]{2,32}$")
_UNVERIFIED = "The company directory could not be verified."
_IDEMPOTENCY_KEY = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
_NO_STORE = {"Cache-Control": "no-store"}
_LIVE_RECORD = {"Cache-Control": "public, max-age=60"}
FRESH_SIGN_IN_SECONDS = 300
HEALTH_CACHE_SECONDS = 10
HEALTH_READ_TIMEOUT_SECONDS = 3
SCHEDULER_STALL_SECONDS = 900
_PARALLEL_READS = ThreadPoolExecutor(max_workers=8, thread_name_prefix="client-read")


class InviteBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    displayName: str = Field(max_length=200)
    role: str = Field(max_length=32)
    employeeCode: str = Field(max_length=64)
    branchId: str = Field(default="", max_length=200)
    email: str | None = Field(default=None, max_length=320)
    phone: str | None = Field(default=None, max_length=64)
    supervisorUid: str | None = Field(default=None, max_length=200)


class RoleBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role: str = Field(max_length=32)
    branchId: str = Field(default="", max_length=200)
    supervisorUid: str | None = Field(default=None, max_length=200)


class EmployeeCodeBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    employeeCode: str = Field(max_length=64)


class MoveBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    supervisorUid: str = Field(max_length=200)


class PlanRequestBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    planId: str = Field(max_length=40)
    interval: Literal["monthly", "yearly"]


class AvailabilityChange(BaseModel):
    model_config = ConfigDict(extra="forbid")

    productId: str = Field(max_length=200)
    visible: StrictBool


class AvailabilityBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    changes: list[AvailabilityChange] = Field(min_length=1, max_length=400)


class DeleteProductsBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    productIds: list[str] = Field(min_length=1, max_length=100)


class RedeemBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str = Field(max_length=64)
    check: str = Field(max_length=320)
    password: str = Field(min_length=8, max_length=128)
    device: str = Field(default="", max_length=80)
    projectId: str | None = Field(default=None, max_length=64)
    emailCode: str | None = Field(default=None, max_length=16)


class EmailCodeBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str = Field(max_length=64)
    check: str = Field(max_length=320)


def check_startup_safety() -> None:
    if auth.emulator_mode() and not config.PLATFORM_PROJECT_ID.startswith("demo-"):
        raise RuntimeError(
            "Emulator sign-in is on, but the platform project is not a demo project."
        )


def check_client_ip_header() -> None:
    if auth.emulator_mode():
        return
    if not config.CLIENT_IP_HEADER:
        raise RuntimeError(
            "PLATFORM_CLIENT_IP_HEADER must name the proxy header that carries the caller address."
        )
    try:
        networks = invitations.trusted_proxy_networks()
    except ValueError:
        networks = []
    if not networks:
        raise RuntimeError(
            "PLATFORM_CLIENT_IP_TRUSTED_PROXIES must list the proxy addresses allowed to set the caller address."
        )


def build_firestore_client() -> firestore.Client:
    return firestore.Client(project=config.PLATFORM_PROJECT_ID)


def _unavailable() -> HTTPException:
    return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=_UNVERIFIED)


def _idempotency(value: str | None, *, required: bool = True) -> str | None:
    if value is None and not required:
        return None
    if value is None or not _IDEMPOTENCY_KEY.fullmatch(value):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Idempotency-Key must be 8-128 characters of A-Z, a-z, 0-9, _ or -.",
        )
    return value


def install_client_routes(
    app: FastAPI,
    *,
    directory: DirectoryStore,
    database: firestore.Client,
    access_for: Callable[[Mapping[str, Any]], CompanyAccess],
    plans: PlanStore,
) -> None:
    check_client_ip_header()
    if config.CLIENT_CORS_ORIGINS:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(config.CLIENT_CORS_ORIGINS),
            allow_credentials=False,
            expose_headers=["Date"],
            allow_methods=["GET", "POST"],
            allow_headers=["Authorization", "Content-Type", "Idempotency-Key"],
        )

    @app.exception_handler(CodedError)
    async def coded_error(_: Request, error: CodedError) -> JSONResponse:
        return JSONResponse(
            {"detail": error.detail, "code": error.code},
            status_code=error.status_code,
            headers=_NO_STORE,
        )

    @app.exception_handler(PlanProblem)
    async def plan_conflict(_: Request, error: PlanProblem) -> JSONResponse:
        if isinstance(error, UsageMissing) and error.retryable:
            return JSONResponse({"detail": str(error), "code": "tenant_not_ready", "retryable": True},
                                status_code=503, headers=_NO_STORE)
        return JSONResponse({"detail": str(error)}, status_code=409, headers=_NO_STORE)

    def invitation_service(*, needs_secret: bool) -> invitations.InvitationService:
        try:
            secret = invitations.load_secret()
        except invitations.InviteConfigError as error:
            if needs_secret:
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="Invitations are not available.",
                ) from error
            secret = None
        return invitations.InvitationService(
            database,
            OperationStore(database, audit=AuditLog(database)),
            directory,
            secret=secret,
            access_for=access_for,
            plans=plans,
        )

    def product_commands() -> ProductCommands:
        return ProductCommands(
            database, OperationStore(database, audit=AuditLog(database)), access_for=access_for, plans=plans
        )

    def tenant_response(context: TenantContext) -> dict[str, str]:
        return {
            "tenantId": context.tenant_id,
            "workspace": context.workspace,
            "uid": context.uid,
        }

    def identity(authorization: str | None = Header(default=None)) -> auth.ClientIdentity:
        return auth.verify_client_token(auth.bearer_token(authorization))

    health_state: dict[str, Any] = {"until": 0.0, "body": None}

    def stamp_time(value: Any) -> datetime | None:
        try:
            moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except (AttributeError, TypeError, ValueError):
            return None
        return moment if moment.tzinfo else None

    def scheduler_state(now: datetime) -> tuple[dict[str, int | None], list[str]]:
        ages: dict[str, int | None] = {}
        degraded: list[str] = []
        for snapshot in database.collection(LEASES).stream(retry=None, timeout=HEALTH_READ_TIMEOUT_SECONDS):
            data = snapshot.to_dict() or {}
            last = stamp_time(data.get("lastRunAt"))
            ages[snapshot.id] = None if last is None else max(0, int((now - last).total_seconds()))
            due = stamp_time(data.get("nextRunAt"))
            leased = stamp_time(data.get("leaseExpiresAt"))
            overdue = (due is not None and (now - due).total_seconds() > SCHEDULER_STALL_SECONDS
                       and (leased is None or leased <= now))
            if data.get("lastStatus") == "failed" or overdue:
                degraded.append(snapshot.id)
        return dict(sorted(ages.items())), sorted(degraded)

    def refresh_health() -> None:
        try:
            ages, degraded = scheduler_state(datetime.now(timezone.utc))
            body = {"status": "ok", "checks": {"firestore": "ok"},
                    "scheduler": {"status": "degraded" if degraded else "ok", "degradedJobs": degraded},
                    "schedulerLastRunAgeSeconds": ages}
            code = status.HTTP_200_OK
        except Exception:
            body = {"status": "unavailable", "checks": {"firestore": "failed"}}
            code = status.HTTP_503_SERVICE_UNAVAILABLE
        health_state.update(until=time.monotonic() + HEALTH_CACHE_SECONDS, body=body, code=code)

    def local_request(request: Request) -> bool:
        proxied = "x-forwarded-for" in request.headers or "x-real-ip" in request.headers
        return not proxied and request.client is not None and request.client.host in ("127.0.0.1", "::1")

    @app.get("/health")
    def health(request: Request) -> JSONResponse:
        if health_state["until"] <= time.monotonic():
            refresh_health()
        body = health_state["body"]
        if not local_request(request):
            body = {key: value for key, value in body.items() if key != "schedulerLastRunAgeSeconds"}
            if "scheduler" in body:
                body["scheduler"] = {"status": body["scheduler"]["status"]}
        return JSONResponse(body, status_code=health_state["code"], headers=_NO_STORE)

    @app.get("/v1/companies/{company_code}")
    def company_lookup(company_code: str, request: Request) -> JSONResponse:
        code = company_code.strip().lower()
        if not _WORKSPACE.fullmatch(code):
            raise HTTPException(404, "Unknown company.")
        try:
            envelope = directory.get_envelope_by_code(code)
        except DirectoryError as error:
            raise _unavailable() from error
        now = datetime.now(timezone.utc)
        peer = invitations.client_ip(request.headers, request.client.host if request.client else None)
        hour = int(now.timestamp()) // 3600

        @firestore.transactional
        def admit(transaction, key: str, limit: int):
            reference = database.collection("company_lookup_rates").document(
                hashlib.sha256(key.encode()).hexdigest())
            prior = reference.get(transaction=transaction).to_dict() or {}
            count = prior.get("count", 0)
            if type(count) is not int or count < 0:
                raise HTTPException(503, "Company lookup is temporarily unavailable.")
            if count >= limit:
                wait = (hour + 1) * 3600 - int(now.timestamp())
                raise HTTPException(429, f"Too many company lookups from this network. Try again in "
                                         f"{max(1, (wait + 59) // 60)} minutes.",
                                    headers={"Retry-After": str(wait), **_NO_STORE})
            transaction.set(reference, {"count": count + 1, "expiresAt": now + timedelta(hours=2)})

        limit = config.COMPANY_LOOKUP_LIMIT_PER_HOUR
        if envelope is None:
            admit(database.transaction(), f"{hour}\n{peer}", 3 * limit)
            admit(database.transaction(), f"{hour}\n-\n{peer}", limit)
        else:
            admit(database.transaction(), f"{hour}\n{code}\n{peer}", limit)
            admit(database.transaction(), f"{hour}\n{peer}", 3 * limit)
        if envelope is None:
            raise HTTPException(404, "Unknown company.")
        live = json.loads(envelope["payload"]).get("status") == "live"
        return JSONResponse(envelope, headers=_LIVE_RECORD if live else _NO_STORE)

    def admin_context(workspace: str, who: auth.ClientIdentity) -> TenantContext:
        return resolve_tenant(who, directory, workspace=workspace, access_for=access_for)

    @app.get("/v1/me")
    def me(who: auth.ClientIdentity = Depends(identity)) -> dict[str, str]:
        return tenant_response(resolve_tenant(who, directory, access_for=access_for))

    @app.get("/v1/w/{workspace}/me")
    def workspace_me(
        workspace: str, who: auth.ClientIdentity = Depends(identity)
    ) -> JSONResponse:
        context = resolve_tenant(who, directory, workspace=workspace, any_state=True, access_for=access_for)

        def read_stamp() -> dict[str, Any] | None:
            try:
                return access_for(context.record["location"]).db.collection("config").document(LIFECYCLE).get().to_dict()
            except UNREACHABLE:
                return None

        pending_stamp = _PARALLEL_READS.submit(read_stamp)
        try:
            state = directory.lifecycle_state(context.tenant_id)
        except DirectoryError as error:
            raise _unavailable() from error
        stamp = pending_stamp.result()
        return JSONResponse(
            {**tenant_response(context), "lifecycle": lifecycle_view(state, stamp)}, headers=_NO_STORE
        )

    @app.post("/v1/w/{workspace}/invitations")
    def create_invitation(
        workspace: str,
        body: InviteBody,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        service = invitation_service(needs_secret=True)
        result = service.create_invitation(admin_context(workspace, who), key, body.model_dump())
        return JSONResponse(result, status_code=201, headers=_NO_STORE)

    @app.get("/v1/w/{workspace}/invitations")
    def list_invitations(
        workspace: str, who: auth.ClientIdentity = Depends(identity)
    ) -> JSONResponse:
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.list_invitations(admin_context(workspace, who)), headers=_NO_STORE
        )

    @app.post("/v1/w/{workspace}/invitations/{invitation_id}/revoke")
    def revoke_invitation(
        workspace: str, invitation_id: str, who: auth.ClientIdentity = Depends(identity)
    ) -> JSONResponse:
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.revoke_invitation(admin_context(workspace, who), invitation_id),
            headers=_NO_STORE,
        )

    @app.get("/v1/w/{workspace}/accounts/reconcile")
    def reconcile_accounts(
        workspace: str, who: auth.ClientIdentity = Depends(identity)
    ) -> JSONResponse:
        service = invitation_service(needs_secret=False)
        return JSONResponse(service.reconcile(admin_context(workspace, who)), headers=_NO_STORE)

    @app.post("/v1/w/{workspace}/accounts/{uid}/revoke")
    def revoke_account(
        workspace: str,
        uid: str,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key, required=False)
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.revoke_account(admin_context(workspace, who), uid, key),
            headers=_NO_STORE,
        )

    @app.post("/v1/w/{workspace}/accounts/{uid}/reactivate")
    def reactivate_account(
        workspace: str,
        uid: str,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.reactivate_account(admin_context(workspace, who), uid, key), headers=_NO_STORE
        )

    @app.post("/v1/w/{workspace}/accounts/{uid}/role")
    def change_role(
        workspace: str,
        uid: str,
        body: RoleBody,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.change_role(admin_context(workspace, who), uid, key, body.model_dump()),
            headers=_NO_STORE,
        )

    @app.post("/v1/w/{workspace}/accounts/{uid}/employee-code")
    def change_employee_code(
        workspace: str,
        uid: str,
        body: EmployeeCodeBody,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.change_employee_code(admin_context(workspace, who), uid, key, body.model_dump()),
            headers=_NO_STORE,
        )

    @app.post("/v1/w/{workspace}/accounts/{uid}/supervisor")
    def move_salesperson(
        workspace: str,
        uid: str,
        body: MoveBody,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.move_salesperson(admin_context(workspace, who), uid, key, body.model_dump()),
            headers=_NO_STORE,
        )

    @app.post("/v1/w/{workspace}/accounts/{uid}/remove")
    def remove_account(
        workspace: str,
        uid: str,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        service = invitation_service(needs_secret=False)
        return JSONResponse(
            service.remove_account(admin_context(workspace, who), uid, key), headers=_NO_STORE
        )

    def plan_and_usage(ctx: TenantContext, *, admin_checked: bool = False) -> tuple[dict[str, Any], dict[str, int]]:
        access = access_for(ctx.record["location"])
        if not admin_checked:
            require_active_admin(access, ctx.uid)
        try:
            effective = plans.effective(ctx.tenant_id)
            return effective, usage_counts(
                access.db, quota_schema_version=effective.get("quotaSchemaVersion", 1),
            )
        except PlanProblem as problem:
            raise plan_refusal(problem) from problem

    @app.get("/v1/w/{workspace}/usage")
    def get_usage(workspace: str, who: auth.ClientIdentity = Depends(identity)) -> JSONResponse:
        effective, counts = plan_and_usage(admin_context(workspace, who))
        return JSONResponse(
            {
                "limits": dict(effective["limits"]),
                "usage": counts,
                "quotaSchemaVersion": effective.get("quotaSchemaVersion", 1),
                "planName": effective["name"],
                "edition": effective["edition"],
            },
            headers=_NO_STORE,
        )

    @app.get("/v1/w/{workspace}/account")
    def get_account(workspace: str, who: auth.ClientIdentity = Depends(identity)) -> JSONResponse:
        context = resolve_tenant(
            who,
            directory,
            access_for=access_for,
            workspace=workspace,
            retained=lambda record: retention_open(access_for(record["location"]).db),
        )
        require_active_admin(access_for(context.record["location"]), context.uid)
        if time.time() - who.auth_time > FRESH_SIGN_IN_SECONDS:
            raise CodedError(
                status.HTTP_401_UNAUTHORIZED,
                "Enter your password again to view this page.",
                "reauth_required",
            )
        effective, counts = plan_and_usage(context, admin_checked=True)
        return JSONResponse(
            jsonable(
                {
                    "plan": {
                        "name": effective["name"],
                        "planId": effective["planId"],
                        "quotaSchemaVersion": effective.get("quotaSchemaVersion", 1),
                        "edition": effective["edition"],
                        "status": (lifecycle_projection(access_for(context.record["location"]).db) or {}).get("state"),
                        "renewsAt": effective["renewsAt"],
                        "trialEndsAt": effective["trialEndsAt"],
                        "price": effective["prices"],
                        "billingInterval": effective["billingInterval"],
                        "features": effective["features"],
                    },
                    "usage": usage_rows(counts, effective["limits"]),
                    "invoices": company_invoices(database, context.tenant_id),
                    "export": {"available": True},
                }
            ),
            headers=_NO_STORE,
        )

    @app.post("/v1/w/{workspace}/products/availability")
    def set_availability(
        workspace: str,
        body: AvailabilityBody,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        result = product_commands().set_availability(
            admin_context(workspace, who), key, [item.model_dump() for item in body.changes]
        )
        return JSONResponse(result, headers=_NO_STORE)

    @app.post("/v1/w/{workspace}/products/delete")
    def delete_products(
        workspace: str,
        body: DeleteProductsBody,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        result = product_commands().delete_products(
            admin_context(workspace, who), key, body.productIds
        )
        return JSONResponse(result, headers=_NO_STORE)

    @app.post("/v1/invitations/redeem")
    def redeem_invitation(body: RedeemBody, request: Request) -> JSONResponse:
        service = invitation_service(needs_secret=True)
        address = invitations.client_ip(
            request.headers, request.client.host if request.client else None
        )
        result = service.redeem(
            code=body.code,
            check=body.check,
            password=body.password,
            device=body.device,
            client_address=address,
            project_id=body.projectId,
            email_code=body.emailCode,
        )
        return JSONResponse(result, headers=_NO_STORE)

    @app.post("/v1/invitations/email-code")
    def request_email_code(body: EmailCodeBody, request: Request) -> JSONResponse:
        service = invitation_service(needs_secret=True)
        address = invitations.client_ip(
            request.headers, request.client.host if request.client else None
        )
        result = service.request_email_code(code=body.code, check=body.check, client_address=address)
        return JSONResponse(result, headers=_NO_STORE)


    @app.get("/v1/w/{workspace}/plans")
    def list_plans(workspace: str, who: auth.ClientIdentity = Depends(identity)) -> JSONResponse:
        context = admin_context(workspace, who)
        require_active_admin(access_for(context.record["location"]), context.uid)
        current = plans.get_subscription(context.tenant_id) or {}
        offers = []
        for offer in plans.public_plans():
            refusal = plans.upgrade_refusal(context.tenant_id, offer["planId"])
            can_request = refusal is None
            offers.append(
                {
                    **offer,
                    "canRequest": can_request,
                    "requestReason": refusal,
                }
            )
        return JSONResponse(
            jsonable(
                {
                    "currentPlanId": current.get("planId"),
                    "currentInterval": current.get("billingInterval"),
                    "plans": offers,
                    "editionFeatures": edition_features(),
                }
            ),
            headers=_NO_STORE,
        )

    def requester_email(context: TenantContext) -> str | None:
        try:
            return access_for(context.record["location"]).auth.get_user(context.uid).email
        except Exception:
            return None

    @app.post("/v1/w/{workspace}/plan-requests")
    def request_plan(
        workspace: str,
        body: PlanRequestBody,
        who: auth.ClientIdentity = Depends(identity),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        key = _idempotency(idempotency_key)
        context = admin_context(workspace, who)
        require_active_admin(access_for(context.record["location"]), context.uid)
        plan = plans.get_plan(body.planId)
        if not plan or plan.get("status") != "active" or plan.get("visibility") != "public":
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="That plan is not available."
            )
        current = plans.get_subscription(context.tenant_id) or {}
        if current.get("planId") == body.planId and current.get("billingInterval") == body.interval:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="You are already on this plan and billing interval.",
            )
        refusal = plans.upgrade_refusal(context.tenant_id, body.planId)
        if refusal is not None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=refusal)
        email = requester_email(context)
        try:
            request = plans.create_plan_request(
                tenant_id=context.tenant_id,
                plan_id=body.planId,
                interval=body.interval,
                requested_by=context.uid,
                key=key,
                now=datetime.now(timezone.utc),
                requester_email=email,
            )
        except CommandProblem as problem:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(problem)) from problem
        plans.mail_plan_request(
            MailQueue(database),
            request=request,
            company_name=context.record["legalName"],
            requester_email=email,
        )
        return JSONResponse(
            {"requestId": request["requestId"], "status": "requested"},
            status_code=201 if request["created"] else 200,
            headers=_NO_STORE,
        )

    install_held_work_route(app, directory=directory, access_for=access_for, identity=identity, database=database)

from __future__ import annotations

import hashlib
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from fastapi import FastAPI, Header, HTTPException, Request, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from google.cloud import firestore
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import auth
from .company_access import CompanyAccess, require_active_admin
from .directory import DirectoryStore
from .plans import jsonable
from .signing import SignatureError, encode_payload, format_timestamp, parse_timestamp
from .tenancy import resolve_tenant, retention_open

_NO_STORE = {"Cache-Control": "no-store"}
_KEY = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
_GRANT = re.compile(r"^grant_[0-9a-f]{64}$")
_EMAIL = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


class SupportProblem(Exception):
    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class GrantBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    staffEmail: str = Field(max_length=254)
    scope: str = Field(max_length=32)
    reason: str = Field(min_length=1, max_length=500)
    expiresAt: str = Field(max_length=32)


class RevokeBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reason: str = Field(min_length=1, max_length=500)
    expectedRevision: int = Field(ge=1)


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _text(value: Any, name: str, maximum: int) -> str:
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= maximum:
        raise SupportProblem(400, f"{name} is invalid.")
    return value.strip()


def _email(value: Any) -> str:
    email = _text(value, "staffEmail", 254).lower()
    if not _EMAIL.fullmatch(email):
        raise SupportProblem(400, "staffEmail is invalid.")
    return email


class SupportConsent:
    def __init__(self, db: firestore.Client, tenant_id: str, *, clock: Callable[[], datetime] = _utc_now) -> None:
        self.db = db
        self.tenant_id = tenant_id
        self.clock = clock

    def _key(self, value: Any) -> str:
        if not isinstance(value, str) or not _KEY.fullmatch(value):
            raise SupportProblem(400, "Idempotency-Key is invalid.")
        return value

    def _grant_result(self, data: Mapping[str, Any]) -> dict[str, Any]:
        ended = data.get("status") == "active" and data["expiresAt"] <= self.clock()
        return jsonable(
            {
                key: ("expired" if ended and key == "status" else data[key])
                for key in (
                    "grantId",
                    "tenantId",
                    "staffEmail",
                    "scope",
                    "reason",
                    "status",
                    "revision",
                    "expiresAt",
                    "createdAt",
                    "createdBy",
                    "revokedAt",
                    "revokedBy",
                    "revocationReason",
                )
                if key in data
            }
        )

    def create(self, uid: str, key: str, body: Mapping[str, Any]) -> dict[str, Any]:
        key = self._key(key)
        email = _email(body.get("staffEmail"))
        if body.get("scope") != "diagnostics":
            raise SupportProblem(400, "Only diagnostics support can be granted.")
        reason = _text(body.get("reason"), "reason", 500)
        try:
            expires_at = parse_timestamp(body.get("expiresAt"))
        except SignatureError:
            raise SupportProblem(400, "expiresAt is invalid.") from None
        now = self.clock()
        digest = hashlib.sha256(f"{self.tenant_id}\n{key}".encode()).hexdigest()
        grant_id = f"grant_{digest}"
        intent = {
            "tenantId": self.tenant_id,
            "createdBy": uid,
            "staffEmail": email,
            "scope": "diagnostics",
            "reason": reason,
            "expiresAt": format_timestamp(expires_at),
        }
        intent_hash = hashlib.sha256(encode_payload(intent).encode()).hexdigest()
        grant_ref = self.db.collection("support_grants").document(grant_id)
        receipt_ref = self.db.collection("support_grant_receipts").document(digest)

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            receipt = receipt_ref.get(transaction=transaction)
            if receipt.exists:
                prior = receipt.to_dict() or {}
                if prior.get("intentHash") != intent_hash:
                    raise SupportProblem(409, "This operation already has a different intent.")
                return grant_ref.get(transaction=transaction).to_dict() or prior["result"]
            if expires_at < now + timedelta(minutes=5) or expires_at > now + timedelta(minutes=60):
                raise SupportProblem(400, "Support access must expire in 5 to 60 minutes.")
            result = {
                "grantId": grant_id,
                "tenantId": self.tenant_id,
                "staffEmail": email,
                "scope": "diagnostics",
                "reason": reason,
                "status": "active",
                "revision": 1,
                "expiresAt": expires_at,
                "createdAt": now,
                "createdBy": uid,
            }
            transaction.create(grant_ref, result)
            transaction.create(receipt_ref, {"intentHash": intent_hash, "result": result})
            return result

        return self._grant_result(write(self.db.transaction(max_attempts=10)))

    def revoke(
        self,
        uid: str,
        grant_id: str,
        key: str,
        reason: str,
        expected_revision: int,
    ) -> dict[str, Any]:
        key = self._key(key)
        if not _GRANT.fullmatch(grant_id):
            raise SupportProblem(404, "Support grant not found.")
        reason = _text(reason, "reason", 500)
        if type(expected_revision) is not int or expected_revision < 1:
            raise SupportProblem(400, "expectedRevision is invalid.")
        receipt_id = hashlib.sha256(
            f"{self.tenant_id}\n{grant_id}\nrevoke\n{key}".encode()
        ).hexdigest()
        intent = {
            "tenantId": self.tenant_id,
            "grantId": grant_id,
            "revokedBy": uid,
            "reason": reason,
            "expectedRevision": expected_revision,
        }
        intent_hash = hashlib.sha256(encode_payload(intent).encode()).hexdigest()
        grant_ref = self.db.collection("support_grants").document(grant_id)
        receipt_ref = self.db.collection("support_grant_receipts").document(receipt_id)
        now = self.clock()

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            receipt = receipt_ref.get(transaction=transaction)
            grant_snapshot = grant_ref.get(transaction=transaction)
            if receipt.exists:
                prior = receipt.to_dict() or {}
                if prior.get("intentHash") != intent_hash:
                    raise SupportProblem(409, "This operation already has a different intent.")
                return prior["result"]
            if not grant_snapshot.exists:
                raise SupportProblem(404, "Support grant not found.")
            grant = grant_snapshot.to_dict() or {}
            if grant.get("tenantId") != self.tenant_id:
                raise SupportProblem(404, "Support grant not found.")
            if grant.get("status") != "active" or grant.get("revision") != expected_revision:
                raise SupportProblem(409, "The support grant changed. Reload and try again.")
            result = {
                **grant,
                "status": "revoked",
                "revision": expected_revision + 1,
                "revokedAt": now,
                "revokedBy": uid,
                "revocationReason": reason,
            }
            transaction.set(grant_ref, result)
            transaction.create(receipt_ref, {"intentHash": intent_hash, "result": result})
            return result

        return self._grant_result(write(self.db.transaction(max_attempts=10)))


async def _json_or_none(request: Request) -> Any:
    try:
        return await request.json()
    except ValueError:
        return None


def install_support_routes(
    app: FastAPI,
    directory: DirectoryStore,
    database: firestore.Client,
    access_for: Callable[[Mapping[str, Any]], CompanyAccess],
    *,
    clock: Callable[[], datetime] = _utc_now,
) -> None:
    def active_admin(workspace: str, authorization: str | None) -> tuple[str, SupportConsent]:
        identity = auth.verify_client_token(auth.bearer_token(authorization))
        context = resolve_tenant(
            identity,
            directory,
            workspace=workspace,
            access_for=access_for,
            retained=lambda record: retention_open(access_for(record["location"]).db),
        )
        row = require_active_admin(access_for(context.record["location"]), context.uid)
        age = time.time() - identity.auth_time
        if row.get("role") != "admin" or age < 0 or age > 300:
            raise HTTPException(403, "A recent administrator sign-in is required.")
        return context.uid, SupportConsent(database, context.tenant_id, clock=clock)

    def response(action: Callable[[], dict[str, Any]], status_code: int = 200) -> JSONResponse:
        try:
            return JSONResponse(action(), status_code=status_code, headers=_NO_STORE)
        except SupportProblem as error:
            raise HTTPException(error.status_code, error.detail) from None

    @app.post("/v1/w/{workspace}/support-grants", status_code=status.HTTP_201_CREATED)
    async def create_grant(
        workspace: str,
        request: Request,
        authorization: str | None = Header(default=None),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        raw = await _json_or_none(request)

        def work() -> JSONResponse:
            uid, service = active_admin(workspace, authorization)
            try:
                body = GrantBody.model_validate(raw)
            except (ValueError, ValidationError):
                raise HTTPException(400, "Check the support grant details and try again.") from None
            return response(
                lambda: service.create(uid, idempotency_key, body.model_dump()),
                status.HTTP_201_CREATED,
            )

        return await run_in_threadpool(work)

    @app.post("/v1/w/{workspace}/support-grants/{grant_id}/revoke")
    async def revoke_grant(
        workspace: str,
        grant_id: str,
        request: Request,
        authorization: str | None = Header(default=None),
        idempotency_key: str | None = Header(default=None),
    ) -> JSONResponse:
        raw = await _json_or_none(request)

        def work() -> JSONResponse:
            uid, service = active_admin(workspace, authorization)
            try:
                body = RevokeBody.model_validate(raw)
            except (ValueError, ValidationError):
                raise HTTPException(400, "Check the revocation details and try again.") from None
            return response(
                lambda: service.revoke(
                    uid,
                    grant_id,
                    idempotency_key,
                    body.reason,
                    body.expectedRevision,
                )
            )

        return await run_in_threadpool(work)

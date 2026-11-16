from __future__ import annotations

from typing import Any, Callable

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict

from . import auth, config
from .staff import StaffBook, approvers, solo_owner
from .staff_signin import Caller, StaffSignIn


class InviteCheck(BaseModel):
    model_config = ConfigDict(extra="forbid")
    token: str


class InviteAccept(BaseModel):
    model_config = ConfigDict(extra="forbid")
    token: str
    password: str
    name: str | None = None


class VerifyBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    code: str | None = None
    backupCode: str | None = None
    remember: bool = False


class TrustedBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    deviceToken: str


class InviteStaff(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str
    name: str
    role: str


class RoleBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    role: str


def no_store(body: Any, code: int = status.HTTP_200_OK) -> JSONResponse:
    return JSONResponse(body, status_code=code, headers={"Cache-Control": "no-store"})


def caller_of(request: Request, ip_of: Callable[[Any, str | None], str]) -> Caller:
    agent = request.headers.get("user-agent", "")
    device = request.headers.get("x-staff-device", "").strip()
    return Caller(user_agent=agent, ip=ip_of(request.headers, request.client.host if request.client else None),
                  device=device[:64])


def staff_token(request: Request) -> auth.StaffToken:
    return auth.verify_staff_token(auth.bearer_token(request.headers.get("authorization")))


def install(app: FastAPI, *, book: StaffBook, sign_in: StaffSignIn, verified_staff: Callable[..., auth.StaffIdentity],
            owner_only: Callable[..., auth.StaffIdentity], ip_of: Callable[[Any, str | None], str]) -> None:
    @app.post("/staff/v1/invite/check")
    def check_invite(body: InviteCheck) -> JSONResponse:
        return no_store(book.check_invite(body.token))

    @app.post("/staff/v1/invite/accept", status_code=201)
    def accept_invite(body: InviteAccept) -> JSONResponse:
        return no_store(book.accept_invite(body.token, body.password, body.name), status.HTTP_201_CREATED)

    @app.post("/staff/v1/session/code")
    def send_code(token: auth.StaffToken = Depends(staff_token)) -> JSONResponse:
        result = sign_in.request_code(token)
        return no_store(result, status.HTTP_202_ACCEPTED if result["status"] == "sending" else status.HTTP_200_OK)

    @app.post("/staff/v1/session/verify", status_code=201)
    def verify_code(request: Request, body: VerifyBody, token: auth.StaffToken = Depends(staff_token)) -> JSONResponse:
        return no_store(sign_in.verify(token, body.code, body.backupCode, caller_of(request, ip_of), body.remember),
                        status.HTTP_201_CREATED)

    @app.post("/staff/v1/session/trusted", status_code=201)
    def trusted_device(request: Request, body: TrustedBody,
                       token: auth.StaffToken = Depends(staff_token)) -> JSONResponse:
        return no_store(sign_in.trusted(token, body.deviceToken, caller_of(request, ip_of)), status.HTTP_201_CREATED)

    @app.get("/staff/v1/sessions")
    def list_sessions(who: auth.StaffIdentity = Depends(verified_staff)) -> JSONResponse:
        return no_store({"sessions": sign_in.sessions(who) if who.session_id else []})

    @app.delete("/staff/v1/sessions/{handle}")
    def end_session(handle: str, who: auth.StaffIdentity = Depends(verified_staff)) -> JSONResponse:
        return no_store({"ended": sign_in.end_session(who, handle)})

    @app.post("/staff/v1/sessions/sign-out-all")
    def end_all_sessions(who: auth.StaffIdentity = Depends(verified_staff)) -> JSONResponse:
        return no_store({"ended": sign_in.end_all(who)})

    @app.get("/staff/v1/backup-codes")
    def backup_codes_left(who: auth.StaffIdentity = Depends(verified_staff)) -> JSONResponse:
        return no_store({"remaining": sign_in.backups_left(who.email)})

    @app.post("/staff/v1/backup-codes", status_code=201)
    def create_backup_codes(who: auth.StaffIdentity = Depends(verified_staff),
                            token: auth.StaffToken = Depends(staff_token)) -> JSONResponse:
        if not who.session_id:
            raise HTTPException(status.HTTP_409_CONFLICT, "Backup codes belong to password sign-in.")
        return no_store({"codes": sign_in.create_backup_codes(who, token)}, status.HTTP_201_CREATED)

    @app.get("/staff/v1/staff")
    def list_staff(who: auth.StaffIdentity = Depends(owner_only)) -> JSONResponse:
        return no_store({"staff": book.list_people(), "domains": sorted(config.STAFF_DOMAINS),
                         "soloOwner": {"enabled": config.SOLO_OWNER, "approvers": len(approvers(book.db)),
                                       "active": solo_owner(book.db, who.email)}})

    @app.post("/staff/v1/staff", status_code=201)
    def invite_staff(body: InviteStaff, who: auth.StaffIdentity = Depends(owner_only)) -> JSONResponse:
        return no_store(book.invite(who.email, body.email, body.name, body.role), status.HTTP_201_CREATED)

    @app.put("/staff/v1/staff/{staff_id}/role")
    def change_role(staff_id: str, body: RoleBody, who: auth.StaffIdentity = Depends(owner_only)) -> JSONResponse:
        return no_store(book.change_role(who.email, staff_id, body.role))

    @app.post("/staff/v1/staff/{staff_id}/disable")
    def disable_staff(staff_id: str, who: auth.StaffIdentity = Depends(owner_only)) -> JSONResponse:
        return no_store(book.disable(who.email, staff_id))

    @app.post("/staff/v1/staff/{staff_id}/remove")
    def remove_staff(staff_id: str, who: auth.StaffIdentity = Depends(owner_only)) -> JSONResponse:
        return no_store(book.remove(who.email, staff_id))

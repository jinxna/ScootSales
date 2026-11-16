from __future__ import annotations

from typing import Any, Mapping, Sequence

from fastapi import HTTPException, status

from .operations import (
    COMPLETED,
    FAILED,
    LeaseLost,
    OperationError,
    OperationStore,
    RetryLater,
    Step,
    is_busy,
)


class CommandProblem(Exception):
    fix: str | None = None

    def __init__(self, message: str = "", *, fix: str | None = None):
        super().__init__(message)
        if fix:
            self.fix = fix


class PlanProblem(Exception):
    code = "plan_limit"
    fix: str | None = None


class PlanLimit(PlanProblem):
    code = "plan_limit"


class PlanMissing(PlanProblem):
    code = "plan_missing"
    fix = "choose_package"


class UsageMissing(PlanProblem):
    code = "usage_missing"
    fix = "prepare_data"

    def __init__(self, message: str, *, retryable: bool = False):
        super().__init__(message)
        self.retryable = retryable


PLAN_CODES = {cls.__name__: cls.code for cls in (PlanLimit, PlanMissing, UsageMissing)}


class CodedError(HTTPException):
    def __init__(self, status_code: int, detail: str, code: str) -> None:
        super().__init__(status_code=status_code, detail=detail)
        self.code = code


def plan_refusal(problem: PlanProblem) -> CodedError:
    return CodedError(status.HTTP_409_CONFLICT, str(problem), problem.code)


def http_error(kind: Any, message: Any, fallback: str) -> HTTPException:
    if kind in PLAN_CODES:
        return CodedError(status.HTTP_409_CONFLICT, str(message), PLAN_CODES[kind])
    if kind in ("CommandProblem", "InviteProblem"):
        return HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(message))
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=fallback)


def in_progress(what: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail=f"{what} is still being applied. Try again in a moment.",
    )


def run_command(
    runner: OperationStore,
    *,
    key: str,
    action: str,
    actor: str,
    tenant_id: str,
    reason: str,
    params: Mapping[str, Any],
    steps: Sequence[Step],
    fallback: str,
    what: str = "This change",
) -> Mapping[str, Any]:
    try:
        operation_id = runner.begin(
            idempotency_key=key,
            action=action,
            actor=actor,
            tenant_id=tenant_id,
            reason=reason,
            ticket=None,
            field_names=sorted(params),
            params=params,
            step_names=[step.name for step in steps],
        )
    except OperationError as error:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This idempotency key was already used for a different request.",
        ) from error
    except Exception as error:
        if not is_busy(error):
            raise
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The service is busy. Nothing was changed. Try again in a moment.",
            headers={"Retry-After": "2"},
        ) from error
    try:
        record = runner.run(operation_id, steps)
    except (LeaseLost, RetryLater) as error:
        raise in_progress(what) from error
    except Exception as error:
        raise http_error(type(error).__name__, str(error), fallback) from error
    if record.get("status") == FAILED:
        info = record.get("error") or {}
        raise http_error(info.get("type"), info.get("message"), fallback)
    if record.get("status") != COMPLETED:
        raise in_progress(what)
    return record

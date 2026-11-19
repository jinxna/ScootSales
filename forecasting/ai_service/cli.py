from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from typing import Any

from forecasting.ai_core import ASIA_KUCHING

from .demo_seed import build_demo_documents
from .generator import build_generation
from .normalization import normalize_firestore_inputs
from .outcome_feedback import normalize_outcomes
from .repository import (
    RUNNER_PROJECT_IDS,
    FirestoreAiRepository,
    WindowTooLargeError,
    create_firestore_client,
)
from .scorecard import (
    ScorecardError,
    build_scorecard,
    scorecard_blocks,
    scorecard_read_weeks,
)


class EmptyGenerationError(RuntimeError):
    pass


def _as_of(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD") from exc


def _run_id(now: datetime) -> str:
    return f"ai1_{now:%Y%m%dT%H%M%SZ}_{uuid.uuid4().hex[:8]}"


def _summary_payload(
    *,
    result: Any,
    dry_run: bool,
    seed_counts: dict[str, int] | None,
    input_counts: dict[str, int],
    write_counts: dict[str, int],
    duration_seconds: float,
) -> dict[str, Any]:
    return {
        "mode": "dry-run" if dry_run else "write",
        "runId": result.run["runId"],
        "asOf": result.run["asOf"].isoformat(),
        "patterns": len(result.patterns),
        "insights": len(result.insights),
        "visitBriefs": len(result.visit_briefs),
        "retailerSegments": len(result.retailer_segments),
        "weeklySummaries": len(result.weekly_summaries),
        "notifications": len(result.notifications),
        "retailerMemory": len(result.retailer_memory),
        "retailerPriorityRankings": len(_rankings_of(result)),
        "historyWeeks": result.run.get("historyWeeks"),
        "windowEvaluated": result.run.get("windowEvaluated"),
        "highPriority": result.run["highPriorityCount"],
        "valueAtRiskRm": result.run["valueAtRiskRm"],
        "dataQuality": result.run["dataQuality"],
        "seeded": seed_counts or {},
        "inputCounts": input_counts,
        "writeCounts": write_counts,
        "plan": _plan_payload(result),
        "durationSeconds": duration_seconds,
    }


def _rankings_of(result: Any) -> tuple[Any, ...]:
    return tuple(getattr(result, "priority_rankings", ()) or ())


def _plan_payload(result: Any) -> dict[str, Any]:
    import math

    statuses: dict[str, int] = {}
    for pattern in getattr(result, "patterns", ()) or ():
        status = str(pattern.get("forecastStatus") or "unknown")
        statuses[status] = statuses.get(status, 0) + 1

    scopes: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    duplicates: list[str] = []
    non_finite = 0
    negative = 0
    for ranking in _rankings_of(result):
        key = (str(ranking.get("scopeKey")), str(ranking.get("weekKey")))
        if key in seen:
            duplicates.append(key[0] + "@" + key[1])
        seen.add(key)
        rows = list(ranking.get("ranking") or ())
        values: list[float] = []
        for row in rows:
            value = row.get("expectedOrderValueRm")
            if not isinstance(value, (int, float)) or not math.isfinite(float(value)):
                non_finite += 1
                continue
            if float(value) < 0:
                negative += 1
            values.append(float(value))
        scopes.append(
            {
                "scopeKey": str(ranking.get("scopeKey")),
                "weekKey": str(ranking.get("weekKey")),
                "retailerCount": int(ranking.get("retailerCount") or 0),
                "chosenCount": int(ranking.get("chosenCount") or 0),
                "exploreCount": sum(
                    1
                    for row in rows
                    if str(row.get("exploitOrExplore") or "") == "explore"
                ),
                "isDemo": bool(ranking.get("isDemo")),
                "topExpectedOrderValueRm": round(max(values), 4) if values else 0.0,
                "minExpectedOrderValueRm": round(min(values), 4) if values else 0.0,
            }
        )
    return {
        "scopes": scopes,
        "scopeCount": len(scopes),
        "duplicateScopeWeeks": duplicates,
        "patternForecastStatusMix": statuses,
        "nonFiniteExpectedValues": non_finite,
        "negativeExpectedValues": negative,
    }


def _emit(event: str, *, stream: Any = None, **fields: Any) -> None:
    output = stream or sys.stdout
    print(
        json.dumps(
            {
                "event": event,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                **fields,
            },
            default=str,
            sort_keys=True,
        ),
        file=output,
        flush=True,
    )


def _runtime_metadata() -> dict[str, str]:
    names = {
        "CLOUD_RUN_JOB": "jobName",
        "CLOUD_RUN_EXECUTION": "executionName",
        "CLOUD_RUN_TASK_INDEX": "taskIndex",
        "CLOUD_RUN_TASK_ATTEMPT": "taskAttempt",
        "CLOUD_RUN_TASK_COUNT": "taskCount",
        "GIT_COMMIT_SHA": "commitSha",
        "APP_VERSION": "appVersion",
    }
    return {
        output_name: value
        for environment_name, output_name in names.items()
        if (value := os.getenv(environment_name, "").strip())
    }


def _run_scorecard(
    repository: FirestoreAiRepository,
    *,
    raw: dict[str, list[dict[str, Any]]],
    result: Any,
    as_of: date,
    window: Any,
    dry_run: bool,
) -> dict[str, int] | None:
    try:
        if not repository.read_scorecard_enabled():
            return None
        scorecard = build_scorecard(
            orders=repository.read_scorecard_orders(
                as_of=as_of, read_weeks=scorecard_read_weeks(window)
            ),
            products=raw["products"],
            retailers=raw["retailers"],
            users=raw["users"],
            outcomes=raw["conversation_outcomes"],
            as_of=as_of,
            window=window,
        )
        rows = scorecard_blocks(scorecard, result.weekly_summaries)
        if not dry_run:
            repository.write_scorecard(rows)
        return {"scorecardSummaries": len(rows)}
    except Exception as error:  # noqa: BLE001 - the job reports it by name.
        raise ScorecardError(error) from error


def _merge_demo_preview(
    raw: dict[str, list[dict[str, Any]]],
    demo_documents: dict[str, tuple[tuple[str, dict[str, Any]], ...]],
) -> None:
    for collection, rows in demo_documents.items():
        existing = {
            str(row.get("docId", "")): row
            for row in raw.get(collection, [])
            if row.get("docId")
        }
        for doc_id, payload in rows:
            existing[doc_id] = {"docId": doc_id, **payload}
        raw[collection] = list(existing.values())


def _write_confirmation(project_id: str) -> str:
    return f"APPLY-{project_id}"


def _bound_location() -> "dict[str, Any] | None":
    if not os.environ.get("TENANT_BINDING_FILE", "").strip():
        return None
    from platform_service.tenant_binding import bound_company

    return bound_company()["location"]


def _resolve_target(project: str | None) -> "tuple[str | None, dict[str, Any] | None]":
    location = _bound_location()
    if project and location:
        raise ValueError("--project cannot be combined with TENANT_BINDING_FILE")
    if project:
        return RUNNER_PROJECT_IDS[project], None
    if location:
        return location["projectId"], location
    return None, None


class _RunnerArgumentParser(argparse.ArgumentParser):
    def parse_args(
        self,
        args: list[str] | None = None,
        namespace: argparse.Namespace | None = None,
    ) -> argparse.Namespace:
        parsed = super().parse_args(args, namespace)
        if parsed.seed_demo and parsed.project != "demo":
            self.error("--seed-demo requires --project demo")
        try:
            parsed.target_project_id, parsed.bound_location = _resolve_target(
                parsed.project
            )
        except Exception as error:  # noqa: BLE001
            self.error(f"company binding: {error}")
        if parsed.history_weeks is not None and not parsed.dry_run:
            self.error(
                "--history-weeks is a preview and needs --dry-run; a live run "
                "uses the saved forecast window"
            )
        if parsed.dry_run:
            if parsed.confirm:
                self.error("--confirm is accepted only with --apply")
            return parsed
        if not parsed.target_project_id:
            self.error(
                f"--apply requires --project {' or '.join(RUNNER_PROJECT_IDS)}, "
                "or TENANT_BINDING_FILE"
            )
        expected = _write_confirmation(parsed.target_project_id)
        if parsed.confirm != expected:
            self.error(
                f"--apply for {parsed.target_project_id} requires --confirm {expected}"
            )
        return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = _RunnerArgumentParser(description="Run AI-1 sales intelligence")
    parser.add_argument(
        "--as-of",
        type=_as_of,
        default=datetime.now(ASIA_KUCHING).date(),
        help="business as-of date in YYYY-MM-DD",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        help="read and calculate without writing Firestore (default)",
    )
    mode.add_argument(
        "--apply",
        dest="dry_run",
        action="store_false",
        help="write generated documents to Firestore",
    )
    parser.set_defaults(dry_run=True)
    parser.add_argument(
        "--seed-demo",
        action="store_true",
        help=(
            "idempotently seed marked demo records in the local demo project; "
            "requires --project demo"
        ),
    )
    parser.add_argument(
        "--project",
        choices=tuple(RUNNER_PROJECT_IDS),
        help=(
            "explicit local Firebase target; a company runtime takes its "
            "project from TENANT_BINDING_FILE instead"
        ),
    )
    parser.add_argument(
        "--confirm",
        help=(
            "non-secret project-specific confirmation required for --apply "
            "(APPLY-<Firebase project ID>)"
        ),
    )
    parser.add_argument(
        "--history-weeks",
        type=int,
        help=(
            "preview the lookback window (dry run only; clamped to the allowed "
            "range); omitted, the saved system_settings/forecast_window is used"
        ),
    )
    parser.add_argument(
        "--service-account",
        help=(
            "optional local-development key path; production uses runtime ADC"
        ),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    target_project_id = args.target_project_id
    target_label = args.project or (
        "company-binding" if args.bound_location else None
    )
    started_at = datetime.now(timezone.utc)
    run_id = _run_id(started_at)
    runtime = _runtime_metadata()
    repository: FirestoreAiRepository | None = None
    writes_started = False
    data_saved = False
    _emit(
        "ai_runner_started",
        runId=run_id,
        asOf=args.as_of,
        mode="dry-run" if args.dry_run else "write",
        seedDemo=args.seed_demo,
        target=target_label or "ambient-read-only",
        firebaseProjectId=target_project_id or "",
        runtime=runtime,
    )
    try:
        repository = FirestoreAiRepository(
            create_firestore_client(
                args.service_account,
                target_project_id,
                **(
                    {"bound_location": args.bound_location}
                    if args.bound_location
                    else {}
                ),
            )
        )
        if not args.dry_run:
            repository.write_run_record(
                run_id,
                {
                    "type": "sales_intelligence",
                    "status": "started",
                    "asOf": args.as_of,
                    "startedAt": started_at,
                    "source": "ai1_runner",
                    "target": target_label,
                    "firebaseProjectId": target_project_id,
                    "runtime": runtime,
                },
            )
            writes_started = True
            repository.abandon_dead_runs(before=started_at - timedelta(hours=2))

        seed_counts: dict[str, int] | None = None
        demo_documents = None
        if args.seed_demo:
            demo_documents = build_demo_documents(as_of=args.as_of)
            if args.dry_run:
                seed_counts = {
                    collection: len(rows)
                    for collection, rows in demo_documents.items()
                }
            else:
                seed_counts = repository.write_seed_documents(demo_documents)

        window = repository.resolve_history_window(
            as_of=args.as_of, requested=args.history_weeks
        )
        raw = repository.read_inputs(
            as_of=args.as_of, history_weeks=window.weeks
        )
        if args.dry_run and demo_documents is not None:
            _merge_demo_preview(raw, demo_documents)
        input_counts = {
            collection: len(rows)
            for collection, rows in raw.items()
        }
        normalized = normalize_firestore_inputs(
            orders=raw["orders"],
            products=raw["products"],
            retailers=raw["retailers"],
            users=raw["users"],
            as_of=args.as_of,
            history_weeks=window.weeks,
        )
        result = build_generation(
            normalized,
            as_of=args.as_of,
            run_id=run_id,
            generated_at=started_at,
            outcomes=normalize_outcomes(raw["conversation_outcomes"]),
            orders=raw["orders"],
            window=window,
        )
        result.run["inputCounts"] = input_counts
        result.run["runtime"] = runtime
        write_counts: dict[str, int] = {}
        if not result.patterns:
            raise EmptyGenerationError(
                "no retailer item has demand in the history window; nothing written"
            )
        if not args.dry_run:
            write_counts = repository.write_generation(result)
            data_saved = True
            finished_at = datetime.now(timezone.utc)
            repository.write_run_record(
                run_id,
                {
                    "status": "completed",
                    "finishedAt": finished_at,
                    "durationSeconds": round(
                        (finished_at - started_at).total_seconds(),
                        3,
                    ),
                    "inputCounts": input_counts,
                    "writeCounts": write_counts,
                    "emptyOutput": (
                        len(result.patterns) == 0
                        and len(result.insights) == 0
                    ),
                    "runtime": runtime,
                },
            )
        scorecard_counts = _run_scorecard(
            repository,
            raw=raw,
            result=result,
            as_of=args.as_of,
            window=window,
            dry_run=args.dry_run,
        )
        if scorecard_counts is not None:
            write_counts = {**write_counts, **scorecard_counts}
        finished_at = datetime.now(timezone.utc)
        summary = _summary_payload(
            result=result,
            dry_run=args.dry_run,
            seed_counts=seed_counts,
            input_counts=input_counts,
            write_counts=write_counts,
            duration_seconds=round(
                (finished_at - started_at).total_seconds(),
                3,
            ),
        )
        _emit("ai_runner_completed", runtime=runtime, **summary)
        return 0
    except Exception as error:  # noqa: BLE001 - convert job failures to exit 1.
        finished_at = datetime.now(timezone.utc)
        failure = {
            "status": "completed" if data_saved else "failed",
            "finishedAt": finished_at,
            "durationSeconds": round(
                (finished_at - started_at).total_seconds(),
                3,
            ),
            "errorType": type(error).__name__,
            "error": str(error)[:500],
            "partialWritesPossible": writes_started and not data_saved,
        }
        if data_saved:
            failure["lateError"] = failure.pop("error")
        if isinstance(error, WindowTooLargeError):
            failure["reason"] = "window_too_large"
            failure["suggestedHistoryWeeks"] = error.suggested_weeks
        if repository is not None and not args.dry_run:
            try:
                repository.write_run_record(run_id, failure)
            except Exception as record_error:  # noqa: BLE001
                failure["runRecordError"] = (
                    f"{type(record_error).__name__}: {record_error}"
                )[:500]
        _emit(
            "ai_runner_failed",
            stream=sys.stderr,
            runId=run_id,
            asOf=args.as_of,
            mode="dry-run" if args.dry_run else "write",
            target=target_label or "ambient-read-only",
            firebaseProjectId=target_project_id or "",
            runtime=runtime,
            **failure,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

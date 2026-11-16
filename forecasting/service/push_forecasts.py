from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Any, Callable

from forecasting.ai_core import ASIA_KUCHING
from forecasting.ai_service.repository import (
    RUNNER_PROJECT_IDS,
    FirestoreAiRepository,
    create_firestore_client,
)

from . import firebase_writer, pipeline_runner


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the operational forecast and optionally mirror it to Firestore"
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", dest="dry_run", action="store_true",
                      help="read and calculate without writing Firestore (default)")
    mode.add_argument("--apply", dest="dry_run", action="store_false",
                      help="write demand_forecasts and forecast_training_runs")
    parser.set_defaults(dry_run=True)
    parser.add_argument("--project", required=True, choices=tuple(RUNNER_PROJECT_IDS),
                        help="explicit Firebase target (dev = cos40005, hardware = hardware-client-sales, demo = emulator only)")
    parser.add_argument("--confirm",
                        help="required with --apply: APPLY-<Firebase project ID>")
    return parser


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = build_parser()
    args = parser.parse_args(argv)
    expected = f"APPLY-{RUNNER_PROJECT_IDS[args.project]}"
    if args.dry_run:
        if args.confirm:
            parser.error("--confirm is accepted only with --apply")
    elif args.confirm != expected:
        parser.error(f"--apply for {args.project} requires --confirm {expected}")
    return args


def _emit(event: str, stream: Any = None, **fields: Any) -> None:
    print(
        json.dumps(
            {"event": event, "timestamp": datetime.now(timezone.utc).isoformat(), **fields},
            default=str,
            sort_keys=True,
        ),
        file=stream or sys.stdout,
        flush=True,
    )


def main(
    argv: list[str] | None = None,
    *,
    client_factory: Callable[[str | None, str | None], Any] = create_firestore_client,
) -> int:
    args = parse_args(argv)
    project_id = RUNNER_PROJECT_IDS[args.project]
    mode = "dry-run" if args.dry_run else "write"
    _emit("forecast_push_started", mode=mode, firebaseProjectId=project_id)
    try:
        client = client_factory(None, project_id)
        as_of = datetime.now(ASIA_KUCHING).date()
        repository = FirestoreAiRepository(client)
        window = repository.resolve_history_window(as_of=as_of)
        raw = repository.read_inputs(as_of=as_of, history_weeks=window.weeks)
        inputs = {name: raw[name] for name in pipeline_runner.INPUT_COLLECTIONS}
        forecast_rows: list[dict[str, Any]] = []
        run = pipeline_runner.run_forecast(
            "headless_push", inputs=inputs, window=window,
            save_local=False, rows_out=forecast_rows,
        )
        if run.get("status") != "completed":
            _emit("forecast_push_failed", stream=sys.stderr, mode=mode,
                  reason=run.get("reason", "unknown"), error=run.get("error", ""))
            return 1
        if int(run.get("forecastedProducts") or 0) <= 0:
            _emit("forecast_push_failed", stream=sys.stderr, mode=mode,
                  reason="no_recent_orders", dataCutoff=run.get("dataCutoff", ""),
                  historyWeeks=run.get("historyWeeks"),
                  error="no product has demand in the history window; nothing written")
            return 1
        rows = int(run.get("productCount") or 0)
        written = {"demand_forecasts": 0, "forecast_training_runs": 0}
        if not args.dry_run:
            firebase_writer.use_client(client)
            written["forecast_training_runs"] = 1 if firebase_writer.push_run(run) else 0
            written["demand_forecasts"] = firebase_writer.push_forecast_results(rows=forecast_rows)
        if not args.dry_run and written["forecast_training_runs"] == 0:
            _emit("forecast_push_failed", stream=sys.stderr, mode=mode,
                  reason="run_record_not_written", error="forecast_training_runs write failed")
            return 1
        if not args.dry_run and written["demand_forecasts"] < rows:
            _emit("forecast_push_failed", stream=sys.stderr, mode=mode,
                  reason="forecast_rows_not_written", writeCounts=written,
                  error="demand_forecasts mirror was incomplete")
            return 1
        _emit(
            "forecast_push_completed",
            mode=mode,
            firebaseProjectId=project_id,
            runId=run.get("runId", ""),
            periodStart=run.get("periodStart", ""),
            historyWeeks=run.get("historyWeeks"),
            windowEvaluated=run.get("windowEvaluated"),
            productCount=rows,
            forecastedProducts=run.get("forecastedProducts", 0),
            insufficientHistoryProducts=run.get("insufficientHistoryProducts", 0),
            inputCounts=run.get("inputCounts", {}),
            wouldWrite={
                "demand_forecasts": rows,
                "forecast_training_runs": 1,
            },
            writeCounts=written,
        )
        return 0
    except Exception as error:  # noqa: BLE001 - convert any failure to exit 1
        _emit("forecast_push_failed", stream=sys.stderr, mode=mode,
              errorType=type(error).__name__, error=str(error)[:500])
        return 1


if __name__ == "__main__":
    sys.exit(main())

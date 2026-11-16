from __future__ import annotations

import json
import os
import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from typing import Any

from ..ai_core.calendar import (
    DEFAULT_HISTORY_WEEKS,
    HistoryWindow,
    completed_weeks_since,
    live_history_window,
    resolve_history_window,
    week_start,
)
from ..ai_service.normalization import earliest_order_date
from ..ai_service.operational_forecast import (
    OPERATIONAL_SCOPE_PRODUCT,
    build_operational_forecasts,
)
from . import config, firestore_reader

INPUT_COLLECTIONS = ("products", "orders", "retailers", "users")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _kuching_date(moment: datetime) -> date:
    return moment.astimezone(timezone(timedelta(hours=8))).date()


_SETTING_UNREAD = object()


def _read_concurrently(reads: dict[str, Callable[[], Any]]) -> dict[str, Any]:
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = {name: pool.submit(read) for name, read in reads.items()}
        return {name: future.result() for name, future in futures.items()}


def _read_window_setting(token: str) -> dict[str, Any] | None:
    return firestore_reader.get_document(
        "system_settings", "forecast_window", token=token
    )


def _read_inputs(token: str) -> dict[str, list[dict[str, Any]]]:
    return _read_concurrently(
        {
            collection: lambda collection=collection: firestore_reader.list_documents(
                collection, token=token
            )
            for collection in INPUT_COLLECTIONS
        }
    )


def _read_inputs_and_setting(
    token: str,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any] | None]:
    with ThreadPoolExecutor(max_workers=1) as pool:
        setting = pool.submit(_read_window_setting, token)
        inputs = _read_inputs(token)
        return inputs, setting.result()


def read_live_window(
    inputs: dict[str, list[dict[str, Any]]],
    *,
    as_of: date,
    token: str,
    setting: Any = _SETTING_UNREAD,
) -> HistoryWindow:
    if setting is _SETTING_UNREAD:
        setting = _read_window_setting(token)
    return live_history_window(
        (setting or {}).get("historyWeeks"),
        available_weeks=completed_weeks_since(
            earliest_order_date(inputs["orders"]), as_of
        ),
    )


def compute_operational_forecast(
    inputs: dict[str, list[dict[str, Any]]],
    *,
    as_of: date,
    generated_at: str,
    window: HistoryWindow,
    include_sarima: bool = True,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    payload = build_operational_forecasts(
        orders=inputs["orders"],
        products=inputs["products"],
        retailers=inputs["retailers"],
        users=inputs["users"],
        as_of=as_of,
        generated_at=generated_at,
        scope=OPERATIONAL_SCOPE_PRODUCT,
        window=window,
    ).to_dict()
    if not include_sarima:
        return payload, None
    sarima = build_operational_forecasts(
        orders=inputs["orders"], products=inputs["products"],
        retailers=inputs["retailers"], users=inputs["users"],
        as_of=as_of, generated_at=generated_at,
        scope=OPERATIONAL_SCOPE_PRODUCT, method="sarima",
    ).to_dict()
    seasonal_rows = {row["productId"]: row for row in sarima["rows"]}
    for row in payload["rows"]:
        row["comparisonForecasts"] = {
            "adaptive": dict(row), "sarima": seasonal_rows[row["productId"]],
        }
    payload["availableMethods"] = ["adaptive", "sarima"]
    return payload, sarima


def _model_mix(rows: list[dict[str, Any]]) -> dict[str, int]:
    mix: dict[str, int] = {}
    for row in rows:
        if row.get("status") != "ok":
            continue
        model = str(row.get("model") or "aggregate")
        mix[model] = mix.get(model, 0) + 1
    return mix


def _write_json(path: Any, payload: Any) -> None:
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    os.replace(temp, path)


def _record_run(run: dict[str, Any]) -> None:
    runs: list[dict[str, Any]] = []
    if config.TRAINING_RUNS_JSON.exists():
        try:
            loaded = json.loads(config.TRAINING_RUNS_JSON.read_text(encoding="utf-8"))
            if isinstance(loaded, list):
                runs = [row for row in loaded if isinstance(row, dict)]
        except (ValueError, OSError):
            runs = []
    _write_json(config.TRAINING_RUNS_JSON, [run] + runs[:49])


def preview_forecast(requested: int, *, token: str) -> dict[str, Any]:
    started = _now()
    as_of = _kuching_date(started)
    inputs, setting = _read_inputs_and_setting(token)
    live = read_live_window(inputs, as_of=as_of, token=token, setting=setting)
    preview = resolve_history_window(
        requested,
        available_weeks=completed_weeks_since(
            earliest_order_date(inputs["orders"]), as_of
        ),
        source="preview",
    )
    generated_at = started.isoformat()

    def forecast(window: HistoryWindow) -> dict[str, Any]:
        payload, _ = compute_operational_forecast(
            inputs,
            as_of=as_of,
            generated_at=generated_at,
            window=window,
            include_sarima=False,
        )
        return {"window": window.to_dict(), "forecast": payload}

    return {
        "status": "ok",
        "preview": forecast(preview),
        "baseline": forecast(live),
    }


def run_forecast(
    triggered_by: str = "dashboard",
    *,
    token: str = "",
    inputs: dict[str, list[dict[str, Any]]] | None = None,
    window: HistoryWindow | None = None,
    rows_out: list[dict[str, Any]] | None = None,
    save_local: bool = True,
) -> dict[str, Any]:
    if save_local:
        config.ensure_dirs()
    started = _now()
    try:
        as_of = _kuching_date(started)
        if inputs is None:
            if window is None:
                inputs, setting = _read_inputs_and_setting(token)
                window = read_live_window(
                    inputs, as_of=as_of, token=token, setting=setting
                )
            else:
                inputs = _read_inputs(token)
        window = window or HistoryWindow(
            weeks=DEFAULT_HISTORY_WEEKS,
            requested=DEFAULT_HISTORY_WEEKS,
            source="default",
        )
        generated_at = started.isoformat()
        payload, sarima = compute_operational_forecast(
            inputs, as_of=as_of, generated_at=generated_at, window=window
        )
        if save_local:
            _write_json(config.OPERATIONAL_FORECASTS_JSON, payload)

        rows = payload["rows"]
        if rows_out is not None:
            rows_out.extend(rows)
        finished = _now()
        run = {
            **window.to_dict(),
            "runId": "run_" + finished.strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6],
            "status": "completed",
            "triggeredBy": triggered_by,
            "startedAt": started.isoformat(),
            "finishedAt": finished.isoformat(),
            "durationSeconds": round((finished - started).total_seconds(), 1),
            "periodStart": payload["periodStart"],
            "periodEnd": (week_start(as_of) + timedelta(days=6)).isoformat(),
            "dataCutoff": payload["dataCutoff"],
            "productCount": payload["rowCount"],
            "forecastedProducts": payload["rowCount"] - payload["insufficientHistoryCount"],
            "insufficientHistoryProducts": payload["insufficientHistoryCount"],
            "modelMix": _model_mix(rows),
            "methodSummaries": {
                "adaptive": {"forecastedProducts": payload["rowCount"] - payload["insufficientHistoryCount"],
                             "unavailableProducts": payload["insufficientHistoryCount"]},
                "sarima": {"forecastedProducts": sarima["rowCount"] - sarima["insufficientHistoryCount"],
                           "unavailableProducts": sarima["insufficientHistoryCount"],
                           "modelMix": _model_mix(sarima["rows"])},
            },
            "forecastModelsVersion": rows[0]["modelVersion"] if rows else "",
            "forecastContractVersion": rows[0]["contractVersion"] if rows else "",
            "inputCounts": {name: len(rows_) for name, rows_ in inputs.items()},
            "dataQuality": payload["dataQuality"],
        }
        if save_local:
            _record_run(run)
        return run
    except firestore_reader.FirestoreReadError as error:
        return _failure("input_unavailable", str(error), started, triggered_by)
    except Exception as error:  # noqa: BLE001 - surface any failure as data, never crash the API
        return _failure("unexpected_error", str(error), started, triggered_by)


def _failure(reason: str, detail: str, started: datetime, triggered_by: str) -> dict[str, Any]:
    return {
        "status": "failed",
        "reason": reason,
        "error": (detail or "").strip()[-1500:],
        "triggeredBy": triggered_by,
        "startedAt": started.isoformat(),
        "finishedAt": _now().isoformat(),
    }


__all__ = [
    "INPUT_COLLECTIONS",
    "compute_operational_forecast",
    "preview_forecast",
    "read_live_window",
    "run_forecast",
]

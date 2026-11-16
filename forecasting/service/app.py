from __future__ import annotations

import asyncio
import csv
import json
import re
import tempfile
import threading
import time
import zipfile
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Body, FastAPI, File, HTTPException, Request, UploadFile, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response

from ..ai_core.calendar import parse_history_weeks
from . import (
    auth,
    config,
    excel_importer,
    firebase_writer,
    firestore_reader,
    pipeline_runner,
)

_MUTATION_LOCK = threading.Lock()
_PREVIEW_LOCK = threading.Lock()
_PREVIEW_CACHE_SECONDS = 60.0
_PREVIEW_CACHE: dict[tuple[str, int, Any], tuple[float, dict[str, Any]]] = {}
_FORECAST_CACHE: dict[str, Any] = {}
_FORECAST_CACHE_LOCK = threading.Lock()
_MUTATING_PATHS = {"/import-excel", "/run-forecast"}
_ALLOWED_UPLOAD_SUFFIXES = {".csv", ".xlsx"}


@asynccontextmanager
async def _lifespan(_: FastAPI) -> AsyncIterator[None]:
    config.validate_service_security()
    yield


class _RequestBodyTooLarge(Exception):
    pass


class _RequestBodyLimitMiddleware:
    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http" or scope.get("path") != "/import-excel":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers", []))
        raw_length = headers.get(b"content-length", b"")
        try:
            content_length = int(raw_length) if raw_length else None
        except ValueError:
            content_length = None
        if content_length is not None and content_length > config.MAX_REQUEST_BYTES:
            await _too_large_response()(scope, receive, send)
            return

        received = 0

        async def bounded_receive() -> dict[str, Any]:
            nonlocal received
            message = await receive()
            if message.get("type") == "http.request":
                received += len(message.get("body", b""))
                if received > config.MAX_REQUEST_BYTES:
                    raise _RequestBodyTooLarge
            return message

        try:
            await self.app(scope, bounded_receive, send)
        except _RequestBodyTooLarge:
            await _too_large_response()(scope, receive, send)


class _MutationLockMiddleware:
    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        is_mutation = (
            scope.get("type") == "http"
            and scope.get("method") == "POST"
            and scope.get("path") in _MUTATING_PATHS
        )
        if not is_mutation:
            await self.app(scope, receive, send)
            return
        if not _MUTATION_LOCK.acquire(blocking=False):
            response = JSONResponse(
                {"detail": "Another forecast import or run is already in progress."},
                status_code=status.HTTP_409_CONFLICT,
            )
            await response(scope, receive, send)
            return
        try:
            await self.app(scope, receive, send)
        finally:
            _MUTATION_LOCK.release()


class _ForecastAuthorizationMiddleware:
    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if (
            scope.get("type") != "http"
            or scope.get("method") == "OPTIONS"
            or scope.get("path") == "/health"
        ):
            await self.app(scope, receive, send)
            return

        headers = {
            key.decode("latin-1").lower(): value.decode("latin-1")
            for key, value in scope.get("headers", [])
        }
        try:
            administrator = await asyncio.to_thread(
                auth.authorize_request_headers,
                origin=headers.get("origin", ""),
                authorization=headers.get("authorization"),
                method=str(scope.get("method", "POST")),
            )
        except HTTPException as error:
            response = JSONResponse(
                {"detail": error.detail},
                status_code=error.status_code,
                headers=error.headers,
            )
            await response(scope, receive, send)
            return

        scope.setdefault("state", {})["forecast_administrator"] = administrator
        await self.app(scope, receive, send)


def _too_large_response() -> JSONResponse:
    return JSONResponse(
        {"status": "error", "message": "Upload exceeds the 10 MiB limit."},
        status_code=status.HTTP_413_CONTENT_TOO_LARGE,
    )

app = FastAPI(
    title="FYP-A Forecasting Service",
    version="1.0.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=_lifespan,
)

app.add_middleware(_RequestBodyLimitMiddleware)
app.add_middleware(_MutationLockMiddleware)
app.add_middleware(_ForecastAuthorizationMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=list(config.CORS_ALLOWED_ORIGINS),
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization"],
)


def _safe_upload_name(raw_name: str | None) -> tuple[str, str]:
    basename = (raw_name or "upload.xlsx").replace("\\", "/").rsplit("/", 1)[-1]
    suffix = Path(basename).suffix.lower()
    if suffix not in _ALLOWED_UPLOAD_SUFFIXES:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="Choose a .csv or .xlsx file.",
        )
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(basename).stem).strip("._-")
    return f"{(stem or 'upload')[:80]}{suffix}", suffix


async def _store_bounded_upload(file: UploadFile, suffix: str) -> Path:
    config.ensure_dirs()
    path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix="_incoming_",
            suffix=suffix,
            dir=config.IMPORTS,
            delete=False,
        ) as handle:
            path = Path(handle.name)
            total = 0
            while chunk := await file.read(64 * 1024):
                total += len(chunk)
                if total > config.MAX_UPLOAD_BYTES:
                    raise HTTPException(
                        status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                        detail="Upload exceeds the 10 MiB limit.",
                    )
                handle.write(chunk)
        return path
    except Exception:
        if path is not None:
            path.unlink(missing_ok=True)
        raise
    finally:
        await file.close()


def _xlsx_member_contains_formula(archive: zipfile.ZipFile, name: str) -> bool:
    marker = re.compile(br"<f(?:\s|>)")
    tail = b""
    with archive.open(name) as member:
        while chunk := member.read(64 * 1024):
            candidate = tail + chunk
            if marker.search(candidate):
                return True
            tail = candidate[-16:]
    return False


def _validate_xlsx_upload(path: Path) -> None:
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > config.MAX_XLSX_ENTRIES:
                raise ValueError("The workbook contains too many embedded files.")
            expanded_size = sum(entry.file_size for entry in entries)
            if expanded_size > config.MAX_XLSX_EXPANDED_BYTES:
                raise ValueError("The expanded workbook is too large.")
            names = {entry.filename.lower() for entry in entries}
            if any(name.endswith("vbaproject.bin") for name in names):
                raise ValueError("Macro-enabled workbooks are not accepted.")
            for entry in entries:
                name = entry.filename
                normalized_name = name.lower()
                if normalized_name.startswith("xl/worksheets/") and normalized_name.endswith(".xml"):
                    if _xlsx_member_contains_formula(archive, name):
                        raise ValueError("Workbook formulas are not accepted.")
    except (OSError, zipfile.BadZipFile, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=str(error) or "The workbook is not a valid .xlsx file.",
        ) from error


def _read_json_list(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (ValueError, OSError):
        return []


def _read_json_object(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (ValueError, OSError):
        return {}


def _empty_operational_set() -> dict[str, Any]:
    return {
        "scope": "product",
        "asOf": "",
        "periodStart": "",
        "dataCutoff": "",
        "generatedAt": "",
        "rowCount": 0,
        "insufficientHistoryCount": 0,
        "dataQuality": {},
        "rows": [],
    }


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "service": "FYP-A Forecasting Service",
        "endpoints": [
            "/health", "/latest-forecast", "/forecast-runs",
            "/forecast-errors", "/forecast-imports",
            "/import-excel (POST)", "/run-forecast (POST)",
            "/preview-forecast (POST)",
        ],
    }


def _forecast_snapshot() -> dict[str, Any]:
    path = config.OPERATIONAL_FORECASTS_JSON
    try:
        stat = path.stat()
        key: tuple[Any, ...] = (str(path), stat.st_mtime_ns, stat.st_size)
    except OSError:
        key = (str(path), None, None)
    with _FORECAST_CACHE_LOCK:
        cached = _FORECAST_CACHE.get("snapshot")
        if cached is not None and cached["key"] == key:
            return cached
    forecasts = _read_json_object(path)
    snapshot = {
        "key": key,
        "payload": forecasts or _empty_operational_set(),
        "hasForecast": bool(forecasts.get("rows")),
        "body": None,
    }
    if forecasts or key[1] is None:
        with _FORECAST_CACHE_LOCK:
            _FORECAST_CACHE["snapshot"] = snapshot
    return snapshot


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "hasForecast": _forecast_snapshot()["hasForecast"]}


@app.get("/latest-forecast")
def latest_forecast() -> Response:
    snapshot = _forecast_snapshot()
    if snapshot["body"] is None:
        snapshot["body"] = JSONResponse(snapshot["payload"]).body
    return Response(content=snapshot["body"], media_type="application/json")


@app.get("/forecast-runs")
def forecast_runs() -> JSONResponse:
    return JSONResponse(_read_json_list(config.TRAINING_RUNS_JSON))


@app.get("/forecast-imports")
def forecast_imports() -> JSONResponse:
    return JSONResponse(_read_json_list(config.IMPORT_HISTORY_JSON))


@app.get("/forecast-errors")
def forecast_errors() -> JSONResponse:
    path = config.IMPORT_ERRORS_CSV
    if not path.exists():
        return JSONResponse([])
    rows: list[dict[str, str]] = []
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except OSError:
        rows = []
    return JSONResponse(rows)


@app.post("/import-excel")
async def import_excel(file: UploadFile = File(...)) -> JSONResponse:
    original_name, suffix = _safe_upload_name(file.filename)
    temp_path: Path | None = None
    try:
        temp_path = await _store_bounded_upload(file, suffix)
    except HTTPException:
        raise
    except Exception:  # noqa: BLE001
        return JSONResponse(
            {"status": "error", "message": "Could not safely read the upload."},
            status_code=400,
        )

    try:
        assert temp_path is not None
        if suffix == ".xlsx":
            await asyncio.to_thread(_validate_xlsx_upload, temp_path)
        summary = await asyncio.to_thread(
            excel_importer.import_table, temp_path, original_name=original_name
        )
    except HTTPException:
        raise
    except excel_importer.ImportTooLarge as error:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE, detail=str(error)
        ) from error
    except Exception:  # noqa: BLE001 - unreadable file, not bad rows
        return JSONResponse(
            {
                "status": "error",
                "message": "File could not be parsed as a supported CSV/XLSX workbook.",
            },
            status_code=422,
        )
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)

    firebase_writer.push_import(summary)
    if summary["validRows"] == 0:
        firebase_writer.push_notification(
            title="Excel import had no usable rows",
            message=f"{summary['sourceFile']}: {summary['errorRows']} rows rejected, none imported.",
            notification_type="import_failed",
            related_id=summary.get("importId", ""),
        )
    else:
        firebase_writer.push_notification(
            title="Excel import completed",
            message=(f"{summary['sourceFile']}: {summary['validRows']} rows imported, "
                     f"{summary['errorRows']} rejected, {summary['warningRows']} warnings."),
            notification_type="import_completed" if summary["errorRows"] == 0 else "import_completed_with_errors",
            related_id=summary.get("importId", ""),
        )

    result: dict[str, Any] = {"status": "ok", "import": summary}
    result["note"] = (
        "The export is staged for the research pipeline (scripts/02-03). An "
        "operational forecast reads the live order history, so a run is not "
        "triggered by an import."
    )
    return JSONResponse(result)


@app.post("/run-forecast")
def run_forecast(request: Request) -> JSONResponse:
    administrator = request.state.forecast_administrator
    return JSONResponse(_run_and_mirror("dashboard", administrator.token))


@app.post("/preview-forecast")
def preview_forecast(
    request: Request, body: dict[str, Any] = Body(...)
) -> JSONResponse:
    administrator = request.state.forecast_administrator
    try:
        requested = parse_history_weeks(body.get("historyWeeks"))
    except ValueError as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(error)
        ) from error
    if not _PREVIEW_LOCK.acquire(blocking=False):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Another forecast preview is already in progress.",
        )
    try:
        live_setting = pipeline_runner._read_window_setting(administrator.token)
        cache_key = (
            administrator.uid,
            requested,
            (live_setting or {}).get("historyWeeks"),
        )
        cached = _PREVIEW_CACHE.get(cache_key)
        if cached is not None and time.monotonic() - cached[0] < _PREVIEW_CACHE_SECONDS:
            return JSONResponse(cached[1])
        result = pipeline_runner.preview_forecast(requested, token=administrator.token)
        now = time.monotonic()
        for key in [
            key for key, (stored_at, _) in _PREVIEW_CACHE.items()
            if now - stored_at >= _PREVIEW_CACHE_SECONDS
        ]:
            del _PREVIEW_CACHE[key]
        _PREVIEW_CACHE[cache_key] = (now, result)
        return JSONResponse(result)
    except firestore_reader.FirestoreReadError as error:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY, detail=str(error)
        ) from error
    finally:
        _PREVIEW_LOCK.release()


def _run_and_mirror(triggered_by: str, token: str) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    run = pipeline_runner.run_forecast(
        triggered_by=triggered_by, token=token, rows_out=rows
    )
    if run.get("status") == "completed":
        run_saved = firebase_writer.push_run(run)
        mirrored = firebase_writer.push_forecast_results(rows=rows)
        run["firestoreResultsMirrored"] = mirrored
        if firebase_writer.mirror_enabled() and (
            not run_saved or mirrored < len(rows)
        ):
            message = (
                f"Run {run.get('runId', '')}: the forecast was calculated but "
                f"only {mirrored} of {len(rows)} results reached the company "
                "database. Run it again."
            )
            firebase_writer.push_notification(
                title="Forecast run failed",
                message=message,
                notification_type="forecast_failed",
                related_id=run.get("runId", ""),
            )
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY, detail=message
            )
        firebase_writer.push_notification(
            title="Forecast run completed",
            message=(f"Run {run.get('runId', '')}: {run.get('forecastedProducts', '?')} of "
                     f"{run.get('productCount', '?')} catalogue products forecast, "
                     f"{run.get('insufficientHistoryProducts', '?')} without enough history."),
            notification_type="forecast_completed",
            related_id=run.get("runId", ""),
        )
    else:
        firebase_writer.push_notification(
            title="Forecast run failed",
            message=f"{run.get('reason', 'unknown')}: {run.get('error', '')[:200]}",
            notification_type="forecast_failed",
            related_id="",
        )
    return run


def main() -> None:
    import uvicorn

    config.validate_service_security()
    config.ensure_dirs()
    print("=" * 60)
    print(" FYP-A Forecasting Service")
    print(f"  http://{config.HOST}:{config.PORT}")
    print(f"  health: http://{config.HOST}:{config.PORT}/health")
    print("  (model runs only on /run-forecast - never on startup)")
    print("=" * 60)
    uvicorn.run(app, host=config.HOST, port=config.PORT, log_level="info")


if __name__ == "__main__":
    main()

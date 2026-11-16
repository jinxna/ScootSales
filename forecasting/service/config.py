from __future__ import annotations

import ipaddress
import os
from pathlib import Path


def _env_flag(name: str, *, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes"}


def _optional_path(name: str) -> Path | None:
    value = os.environ.get(name, "").strip()
    return Path(value).expanduser() if value else None


def _bound_project_id() -> str | None:
    from platform_service.tenant_binding import binding_file_path, bound_company

    path = binding_file_path()
    return bound_company(path)["location"]["projectId"] if path else None


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent

SCRIPTS = ROOT / "scripts"
DATA = ROOT / "data"
RAW = DATA / "raw"
PROCESSED = DATA / "processed"
OUTPUTS = ROOT / "outputs"
LOGS = ROOT / "logs"
IMPORTS = ROOT / "imports"

RAW_ORDERS_CSV = RAW / "dummy_orders.csv"

OPERATIONAL_FORECASTS_JSON = OUTPUTS / "operational_forecasts.json"
TRAINING_RUNS_JSON = OUTPUTS / "forecast_training_runs.json"

IMPORT_ERRORS_CSV = PROCESSED / "import_errors.csv"
IMPORT_HISTORY_JSON = OUTPUTS / "forecast_imports.json"

SERVICE_ACCOUNT_KEY = _optional_path("FIREBASE_SERVICE_ACCOUNT")

HOST = os.environ.get("FORECAST_HOST", "127.0.0.1")
PORT = int(os.environ.get("FORECAST_PORT", "8000"))
FIREBASE_PROJECT_ID = _bound_project_id() or os.environ.get(
    "FORECAST_FIREBASE_PROJECT_ID",
    "cos40005",
).strip()

MAX_UPLOAD_BYTES = 10 * 1024 * 1024
MAX_REQUEST_BYTES = MAX_UPLOAD_BYTES + 1024 * 1024
MAX_XLSX_EXPANDED_BYTES = 100 * 1024 * 1024
MAX_XLSX_ENTRIES = 2048
MAX_IMPORT_ROWS = 100_000
MAX_IMPORT_COLUMNS = 100
MAX_KEPT_IMPORTS = 20

DEFAULT_CORS_ALLOWED_ORIGINS = (
    "http://localhost:3000",
    "http://localhost:5000",
    "http://localhost:8080",
    "http://127.0.0.1:3000",
    "http://127.0.0.1:5000",
    "http://127.0.0.1:8080",
)
CORS_ALLOWED_ORIGINS = tuple(
    origin.strip()
    for origin in os.environ.get(
        "CORS_ALLOWED_ORIGINS",
        ",".join(DEFAULT_CORS_ALLOWED_ORIGINS),
    ).split(",")
    if origin.strip()
)

PUSH_FIRESTORE = _env_flag("FORECAST_PUSH_FIRESTORE")


def validate_service_security() -> None:
    host = HOST.strip().lower()
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = host == "localhost"
    if not loopback:
        raise RuntimeError(
            "The forecasting HTTP service is local-only; FORECAST_HOST must be "
            "localhost or a loopback address."
        )
    if not FIREBASE_PROJECT_ID:
        raise RuntimeError("The forecasting Firebase project must not be empty.")


def ensure_dirs() -> None:
    for folder in (RAW, PROCESSED, OUTPUTS, LOGS, IMPORTS):
        folder.mkdir(parents=True, exist_ok=True)

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

from . import config

_client: Any = None
_initialised = False
_available = False


def _firestore() -> Any:
    global _client, _initialised, _available
    if _initialised:
        return _client if _available else None
    _initialised = True

    if not config.PUSH_FIRESTORE:
        print("[firebase] FORECAST_PUSH_FIRESTORE disabled - staying local only.")
        return None
    try:
        emulator = os.environ.get("FIRESTORE_EMULATOR_HOST", "").strip()
        if emulator and config.SERVICE_ACCOUNT_KEY is None:
            from google.auth.credentials import AnonymousCredentials
            from google.cloud import firestore as google_firestore

            _client = google_firestore.Client(
                project=config.FIREBASE_PROJECT_ID,
                credentials=AnonymousCredentials(),
            )
            _available = True
            print("[firebase] Firestore mirror enabled against the emulator.")
            return _client
        import firebase_admin
        from firebase_admin import credentials, firestore

        if not firebase_admin._apps:  # type: ignore[attr-defined]
            if config.SERVICE_ACCOUNT_KEY is None:
                firebase_admin.initialize_app()
            elif config.SERVICE_ACCOUNT_KEY.is_file():
                cred = credentials.Certificate(str(config.SERVICE_ACCOUNT_KEY))
                firebase_admin.initialize_app(cred)
            else:
                print(
                    "[firebase] Configured development credential file was "
                    "not found - skipping Firestore mirror."
                )
                return None
        candidate = firestore.client()
        database = getattr(candidate, "_database", "(default)")
        if candidate.project != config.FIREBASE_PROJECT_ID or database != "(default)":
            print(
                f"[firebase] Credential targets project {candidate.project!r} "
                f"database {database!r}, not the bound project "
                f"{config.FIREBASE_PROJECT_ID!r} - skipping Firestore mirror."
            )
            return None
        _client = candidate
        _available = True
        print("[firebase] Firestore mirror enabled with explicit opt-in.")
        return _client
    except ImportError:
        print("[firebase] firebase-admin not installed - skipping Firestore mirror "
              "(pip install firebase-admin to enable).")
        return None
    except Exception as error:  # noqa: BLE001
        print(f"[firebase] Could not initialise Firestore ({error}) - skipping mirror.")
        return None


def mirror_enabled() -> bool:
    return _firestore() is not None


def use_client(client: Any) -> None:
    global _client, _initialised, _available
    _client = client
    _initialised = True
    _available = client is not None


def push_notification(
    *,
    title: str,
    message: str,
    notification_type: str,
    role_target: str = "admin",
    related_id: str = "",
) -> None:
    client = _firestore()
    if client is None:
        return
    try:
        client.collection("dashboard_notifications").add({
            "title": title,
            "message": message,
            "type": notification_type,
            "createdAt": datetime.now(timezone.utc),
            "read": False,
            "roleTarget": role_target,
            "relatedId": related_id,
            "source": "forecasting_service",
        })
    except Exception as error:  # noqa: BLE001
        print(f"[firebase] notification write failed: {error}")


def _no_nested_arrays(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _no_nested_arrays(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [
            " / ".join(str(part) for part in item)
            if isinstance(item, (list, tuple))
            else _no_nested_arrays(item)
            for item in value
        ]
    return value


def push_run(run: dict[str, Any]) -> bool:
    client = _firestore()
    if client is None:
        return False
    try:
        run_id = run.get("runId") or f"run_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}"
        payload: dict[str, Any] = _no_nested_arrays(
            {**run, "mirroredAt": datetime.now(timezone.utc)}
        )
        if not payload.get("createdAt"):
            payload["createdAt"] = (
                run.get("finishedAt")
                or run.get("startedAt")
                or datetime.now(timezone.utc).isoformat()
            )
        client.collection("forecast_training_runs").document(run_id).set(payload)
        return True
    except Exception as error:  # noqa: BLE001
        print(f"[firebase] run write failed: {error}")
        return False


def push_import(summary: dict[str, Any]) -> None:
    client = _firestore()
    if client is None:
        return
    try:
        slim = {
            k: v for k, v in summary.items() if k not in {"issues", "errorReport"}
        }
        client.collection("forecast_imports").document(summary.get("importId", "")).set(
            {**slim, "mirroredAt": datetime.now(timezone.utc)}
        )
    except Exception as error:  # noqa: BLE001
        print(f"[firebase] import write failed: {error}")


def _mirror_aliases(row: dict[str, Any]) -> dict[str, Any]:
    aliases: dict[str, Any] = {"mirroredAt": datetime.now(timezone.utc)}
    period_start = str(row.get("periodStart") or "")
    if len(period_start) >= 7:
        aliases["forecastMonth"] = period_start[:7]
    point = row.get("point")
    if isinstance(point, (int, float)):
        aliases["predictedQuantity"] = point
    aliases["modelUsed"] = row.get("model") or "aggregate"
    aliases["reason"] = _describe_row(row)
    return aliases


def _describe_row(row: dict[str, Any]) -> str:
    status = str(row.get("status") or "")
    if status == "model_error":
        return "SARIMA fitting failed. No forecast is available for this product."
    if status != "ok":
        return (
            "Not enough order history to forecast this product in the current "
            "window; the figure shown is what was observed."
        )
    demand_class = str(row.get("demandClass") or "mixed")
    count = row.get("modelledComponentCount") or row.get("componentCount") or 0
    period = str(row.get("periodStart") or "")
    model = row.get("model") or "the selected models"
    return (
        f"{demand_class} demand, forecast with {model} from {count} outlet "
        f"series for the week starting {period}."
    )


def push_forecast_results(
    limit: int | None = None, rows: list[dict[str, Any]] | None = None
) -> int:
    client = _firestore()
    if client is None:
        return 0
    if rows is None:
        if not config.OPERATIONAL_FORECASTS_JSON.exists():
            return 0
        try:
            payload = json.loads(
                config.OPERATIONAL_FORECASTS_JSON.read_text(encoding="utf-8")
            )
        except (ValueError, OSError):
            return 0
        rows = payload.get("rows") if isinstance(payload, dict) else None
        if not isinstance(rows, list):
            return 0
    selected = rows if limit is None else rows[:limit]

    written = 0
    pending = 0
    batch = client.batch()
    collection = client.collection("demand_forecasts")
    try:
        for row in selected:
            if not isinstance(row, dict):
                continue
            period_start = str(row.get("periodStart") or "")
            doc_id = f"{row.get('productId', '')}_{period_start}".replace("/", "-")
            batch.set(collection.document(doc_id), {**row, **_mirror_aliases(row)})
            pending += 1
            if pending == 400:
                batch.commit()
                written += pending
                pending = 0
                batch = client.batch()
        if pending:
            batch.commit()
            written += pending
    except Exception as error:  # noqa: BLE001
        print(f"[firebase] forecast_results commit failed: {error}")
    return written

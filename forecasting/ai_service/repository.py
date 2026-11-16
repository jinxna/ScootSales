from __future__ import annotations

import ipaddress
import os
import uuid
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from types import MappingProxyType
from typing import Any, Iterable, Mapping
from urllib.parse import urlsplit

from forecasting.ai_core import ASIA_KUCHING, HUMAN_FIELDS, merge_insight, week_start
from forecasting.ai_core.calendar import (
    DEFAULT_HISTORY_WEEKS,
    HISTORY_WINDOW_VERSION,
    MIN_HISTORY_WEEKS,
    HistoryWindow,
    completed_weeks_since,
    live_history_window,
    resolve_history_window,
)

from .generator import GenerationResult
from .visit_briefs import build_visit_briefs


REPO_ROOT = Path(__file__).resolve().parents[2]
MAX_ORDERS = 5000
MAX_PRODUCTS = 2000
MAX_RETAILERS = 2000
MAX_USERS = 1000
MAX_OUTCOMES = 1000
MAX_VISIT_BRIEFS = 2000
MAX_RETAILER_SEGMENTS = 2000
MAX_NOTIFICATIONS = 500
MAX_RETAILER_MEMORY = 2000
MAX_PRIORITY_RANKINGS = 500
BATCH_SIZE = 400
FORECAST_ACCURACY_VERSION = "forecast-accuracy/2.0.0"

RUNNER_PROJECT_IDS: Mapping[str, str] = MappingProxyType(
    {
        "dev": "cos40005",
        "demo": "demo-fyp-a",
        "hardware": "hardware-client-sales",
    }
)

AI_RUNNER_WRITE_COLLECTIONS = frozenset(
    {
        "ai_runs",
        "retailer_item_patterns",
        "ai_insights",
        "weekly_ai_summaries",
        "retailer_segments",
        "retailer_memory",
        "visit_briefs",
        "dashboard_notifications",
        "retailer_priority_rankings",
    }
)
DEMO_SEED_WRITE_COLLECTIONS = frozenset(
    {
        "orders",
        "products",
        "retailers",
        "users",
    }
)
ALLOWED_WRITE_COLLECTIONS = (
    AI_RUNNER_WRITE_COLLECTIONS | DEMO_SEED_WRITE_COLLECTIONS
)


def _local_keys_disabled() -> bool:
    return os.getenv("AI_RUNNER_DISABLE_LOCAL_KEYS", "").strip().lower() in {
        "1",
        "true",
        "yes",
    }


def _service_account_path(explicit: str | None = None) -> Path | None:
    if _local_keys_disabled():
        if explicit or os.getenv("GOOGLE_APPLICATION_CREDENTIALS"):
            raise RuntimeError(
                "File-based credentials are disabled for this runner."
            )
        return None

    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            raise FileNotFoundError("The explicit service-account file was not found.")
        return path.resolve()

    if os.getenv("GOOGLE_APPLICATION_CREDENTIALS"):
        return None

    for candidate in (
        REPO_ROOT / "serviceAccountKey.json",
        REPO_ROOT / "admin_dashboard" / "serviceAccountKey.json",
    ):
        if candidate.is_file():
            return candidate.resolve()
    return None


def _emulator_is_loopback(value: str) -> bool:
    raw = value.strip()
    if "://" in raw or "/" in raw:
        return False
    try:
        parsed = urlsplit(f"//{raw}")
        host = (parsed.hostname or "").lower()
        port = parsed.port
    except ValueError:
        return False
    if (
        not host
        or port is None
        or not 1 <= port <= 65535
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        return False
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _credential_project_id(credential: Any) -> str:
    try:
        project_id = credential.project_id
    except Exception as error:  # noqa: BLE001 - fail closed on ADC discovery.
        raise RuntimeError(
            "Firebase credential project could not be verified."
        ) from error
    if not isinstance(project_id, str) or not project_id.strip():
        raise RuntimeError("Firebase credential project could not be verified.")
    return project_id.strip()


def create_firestore_client(
    service_account: str | None = None,
    expected_project_id: str | None = None,
    bound_location: Mapping[str, Any] | None = None,
) -> Any:
    import firebase_admin
    from firebase_admin import credentials, firestore

    if bound_location is not None:
        if expected_project_id != bound_location["projectId"]:
            raise RuntimeError("Firebase project does not match the company binding.")
    elif (
        expected_project_id
        and expected_project_id not in RUNNER_PROJECT_IDS.values()
    ):
        raise RuntimeError("Unsupported Firebase project target.")
    database_id = (bound_location or {}).get("databaseId") or "(default)"
    named_database = None if database_id == "(default)" else database_id

    if expected_project_id == RUNNER_PROJECT_IDS["demo"] or (
        bound_location is not None and expected_project_id.startswith("demo-")
    ):
        emulator = os.getenv("FIRESTORE_EMULATOR_HOST", "").strip()
        if service_account:
            raise RuntimeError(
                "The demo target does not accept a service-account file."
            )
        if not emulator or not _emulator_is_loopback(emulator):
            raise RuntimeError(
                "The demo target requires a loopback FIRESTORE_EMULATOR_HOST."
            )
        from google.auth.credentials import AnonymousCredentials
        from google.cloud import firestore as google_firestore

        client = google_firestore.Client(
            project=expected_project_id,
            credentials=AnonymousCredentials(),
            **({} if named_database is None else {"database": named_database}),
        )
        if client.project != expected_project_id:
            raise RuntimeError("Firestore client project does not match --project.")
        return client

    if expected_project_id and os.getenv("FIRESTORE_EMULATOR_HOST", "").strip():
        raise RuntimeError(
            "The dev target refuses FIRESTORE_EMULATOR_HOST; select demo instead."
        )

    if expected_project_id:
        path = _service_account_path(service_account)
        credential = (
            credentials.ApplicationDefault()
            if path is None
            else credentials.Certificate(str(path))
        )
        if _credential_project_id(credential) != expected_project_id:
            raise RuntimeError(
                "Firebase credential project does not match --project."
            )
        app = firebase_admin.initialize_app(
            credential,
            {"projectId": expected_project_id},
            name=f"ai-runner-{uuid.uuid4().hex}",
        )
        try:
            client = firestore.client(
                app=app,
                **({} if named_database is None else {"database_id": named_database}),
            )
            if client.project != expected_project_id:
                raise RuntimeError(
                    "Firestore client project does not match --project."
                )
            return client
        except Exception:
            firebase_admin.delete_app(app)
            raise

    try:
        firebase_admin.get_app()
    except ValueError:
        path = _service_account_path(service_account)
        if path is None:
            firebase_admin.initialize_app()
        else:
            firebase_admin.initialize_app(credentials.Certificate(str(path)))
    return firestore.client()


def _rows(snapshot: Any) -> list[dict[str, Any]]:
    return [{"docId": doc.id, **doc.to_dict()} for doc in snapshot]


def _capped(
    rows: list[dict[str, Any]], collection: str, cap: int
) -> list[dict[str, Any]]:
    if len(rows) > cap:
        raise InputOverflowError(
            f"{collection} holds more than {cap} rows; refusing to generate "
            "from a silently truncated read"
        )
    return rows


def _firestore_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return value
    if isinstance(value, date):
        return datetime.combine(value, time.min, tzinfo=ASIA_KUCHING)
    if isinstance(value, Mapping):
        return {key: _firestore_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_firestore_value(item) for item in value]
    return value


def _priority_ranking_rows(
    *,
    current: Iterable[Mapping[str, Any]],
    existing: Iterable[Mapping[str, Any]],
    run_id: str,
    generated_at: datetime,
) -> list[tuple[str, dict[str, Any]]]:
    current_by_id = {
        str(row["rankingId"]): dict(row)
        for row in current
        if row.get("rankingId")
    }
    rows = list(current_by_id.items())
    for previous in existing:
        ranking_id = str(previous.get("rankingId") or previous.get("docId") or "")
        if not ranking_id or ranking_id in current_by_id:
            continue
        previous_payload = dict(previous)
        previous_payload.pop("docId", None)
        rows.append(
            (
                ranking_id,
                {
                    **previous_payload,
                    "rankingId": ranking_id,
                    "status": "inactive",
                    "sourceRunId": run_id,
                    "updatedAt": generated_at,
                },
            )
        )
    return rows


def _visit_brief_rows(
    *,
    current: Iterable[Mapping[str, Any]],
    existing: Iterable[Mapping[str, Any]],
    run_id: str,
    generated_at: datetime,
) -> list[tuple[str, dict[str, Any]]]:
    current_by_id = {
        str(row["briefId"]): dict(row)
        for row in current
        if row.get("briefId")
    }
    rows = list(current_by_id.items())
    for previous in existing:
        brief_id = str(previous.get("briefId") or previous.get("docId") or "")
        if not brief_id or brief_id in current_by_id:
            continue
        previous_payload = dict(previous)
        previous_payload.pop("docId", None)
        rows.append(
            (
                brief_id,
                {
                    **previous_payload,
                    "briefId": brief_id,
                    "status": "inactive",
                    "sourceRunId": run_id,
                    "insightCount": 0,
                    "highPriorityCount": 0,
                    "totalValueAtRiskRm": 0.0,
                    "topInsights": [],
                    "replenishment": [],
                    "updatedAt": generated_at,
                },
            )
        )
    return rows


def _retailer_segment_rows(
    *,
    current: Iterable[Mapping[str, Any]],
    existing: Iterable[Mapping[str, Any]],
    run_id: str,
    generated_at: datetime,
) -> list[tuple[str, dict[str, Any]]]:
    current_by_id = {
        str(row["segmentId"]): dict(row)
        for row in current
        if row.get("segmentId")
    }
    rows = list(current_by_id.items())
    for previous in existing:
        segment_id = str(
            previous.get("segmentId") or previous.get("docId") or ""
        )
        if not segment_id or segment_id in current_by_id:
            continue
        previous_payload = dict(previous)
        previous_payload.pop("docId", None)
        rows.append(
            (
                segment_id,
                {
                    **previous_payload,
                    "segmentId": segment_id,
                    "status": "inactive",
                    "attentionScore": 0,
                    "activeInsightCount": 0,
                    "highPriorityCount": 0,
                    "valueAtRiskRm": 0.0,
                    "topIssueTypes": [],
                    "sourceRunId": run_id,
                    "updatedAt": generated_at,
                },
            )
        )
    return rows


def _retailer_memory_rows(
    *,
    current: Iterable[Mapping[str, Any]],
    existing: Iterable[Mapping[str, Any]],
    run_id: str,
    generated_at: datetime,
) -> list[tuple[str, dict[str, Any]]]:
    current_by_id = {
        str(row["memoryId"]): dict(row)
        for row in current
        if row.get("memoryId")
    }
    rows = list(current_by_id.items())
    for previous in existing:
        memory_id = str(previous.get("memoryId") or previous.get("docId") or "")
        if not memory_id or memory_id in current_by_id:
            continue
        previous_payload = dict(previous)
        previous_payload.pop("docId", None)
        rows.append(
            (
                memory_id,
                {
                    **previous_payload,
                    "memoryId": memory_id,
                    "status": "inactive",
                    "isStale": True,
                    "staleReason": "outside_bounded_outcome_window",
                    "outcomeCount": 0,
                    "commonReasonCodes": [],
                    "priceSensitivityScore": 0.0,
                    "seasonalityScore": 0.0,
                    "replacementProducts": [],
                    "lastConfirmedIssues": [],
                    "confidence": 0.0,
                    "confidenceLabel": "low",
                    "sourceRunId": run_id,
                    "updatedAt": generated_at,
                },
            )
        )
    return rows


def _notification_rows(
    *,
    current: Iterable[Mapping[str, Any]],
    existing: Mapping[str, Mapping[str, Any]],
    generated_at: datetime,
) -> list[tuple[str, dict[str, Any]]]:
    rows: list[tuple[str, dict[str, Any]]] = []
    for row in current:
        notification_id = str(row.get("notificationId") or "")
        if not notification_id:
            continue
        previous = dict(existing.get(notification_id) or {})
        previous.pop("docId", None)
        payload = {
            **previous,
            **dict(row),
            "notificationId": notification_id,
            "createdAt": previous.get("createdAt") or generated_at,
            "updatedAt": generated_at,
            "read": previous.get("read", False),
        }
        if previous.get("readAt") is not None:
            payload["readAt"] = previous["readAt"]
        rows.append((notification_id, payload))
    return rows


class InputOverflowError(RuntimeError):
    pass


class WindowTooLargeError(InputOverflowError):
    def __init__(self, history_weeks: int, suggested_weeks: int | None) -> None:
        hint = (
            f"; a window of {suggested_weeks} weeks fits"
            if suggested_weeks is not None
            else ""
        )
        super().__init__(
            f"orders holds more than {MAX_ORDERS} rows in a {history_weeks}-week "
            f"window; refusing to generate from a silently truncated read{hint}"
        )
        self.history_weeks = history_weeks
        self.suggested_weeks = suggested_weeks


def _week_date(value: Any) -> date | None:
    if isinstance(value, datetime):
        if value.tzinfo is not None:
            value = value.astimezone(ASIA_KUCHING)
        return value.date()
    if isinstance(value, date):
        return value
    if value is None:
        return None
    to_datetime = getattr(value, "to_datetime", None)
    if callable(to_datetime):
        return _week_date(to_datetime())
    try:
        return _week_date(
            datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
        )
    except ValueError:
        return None


def _target_actual(
    previous: Mapping[str, Any],
    previous_week: date,
    row: Mapping[str, Any],
    quantities: list[Any],
) -> float | None:
    target = _week_date(previous.get("forecastPeriodStart")) or (
        previous_week + timedelta(days=7)
    )
    starts = row.get("weekStarts")
    if not isinstance(starts, (list, tuple)):
        return None
    indexes = [
        index for index, value in enumerate(starts) if _week_date(value) == target
    ]
    if len(indexes) != 1 or indexes[0] >= len(quantities):
        return None
    return float(quantities[indexes[0]] or 0)


def _forecast_evaluations(
    current: Iterable[Mapping[str, Any]],
    existing: Mapping[str, Mapping[str, Any]],
) -> list[dict[str, Any]]:
    evaluations: list[dict[str, Any]] = []
    for row in current:
        pattern_id = str(row.get("patternId") or "")
        previous = existing.get(pattern_id)
        quantities = row.get("weeklyQuantities")
        if not previous or not isinstance(quantities, list) or not quantities:
            continue
        status = previous.get("forecastStatus")
        if status is not None and str(status).strip().lower() != "ok":
            continue
        previous_week = _week_date(previous.get("lastObservedWeekStart"))
        current_week = _week_date(row.get("lastObservedWeekStart"))
        if previous_week is None or current_week is None:
            continue
        if previous_week >= current_week:
            continue
        actual = _target_actual(previous, previous_week, row, quantities)
        if actual is None:
            continue
        forecast = float(previous.get("forecastNextWeek") or 0)
        absolute_error = abs(forecast - actual)
        percentage_error = absolute_error / actual * 100 if actual > 0 else None
        evaluations.append(
            {
                "patternId": pattern_id,
                "branchId": str(row.get("branchId") or ""),
                "salesmanCode": str(row.get("salesmanCode") or ""),
                "historyWeeks": int(
                    previous.get("historyWeeks") or DEFAULT_HISTORY_WEEKS
                ),
                "absoluteError": round(absolute_error, 2),
                "percentageError": (
                    round(percentage_error, 2)
                    if percentage_error is not None
                    else None
                ),
            }
        )
    return evaluations


def _accuracy_metrics(rows: Iterable[Mapping[str, Any]]) -> dict[str, Any]:
    values = list(rows)
    percentage_errors = [
        float(row["percentageError"])
        for row in values
        if row.get("percentageError") is not None
    ]
    return {
        "evaluatedForecastCount": len(values),
        "meanAbsoluteError": (
            round(
                sum(float(row["absoluteError"]) for row in values) / len(values),
                2,
            )
            if values
            else 0.0
        ),
        "meanAbsolutePercentageError": (
            round(sum(percentage_errors) / len(percentage_errors), 2)
            if percentage_errors
            else None
        ),
        "percentageErrorCount": len(percentage_errors),
        "methodologyVersion": FORECAST_ACCURACY_VERSION,
        "historyWindowVersion": HISTORY_WINDOW_VERSION,
        "historyWeeks": sorted(
            {
                int(row["historyWeeks"])
                for row in values
                if row.get("historyWeeks") is not None
            }
        ),
    }


def _summary_with_accuracy(
    summary: Mapping[str, Any],
    evaluations: Iterable[Mapping[str, Any]],
) -> dict[str, Any]:
    scope_type = str(summary.get("scopeType") or "organization")
    scope_key = str(summary.get("scopeKey") or "all")
    scoped = [
        row
        for row in evaluations
        if scope_type == "organization"
        or (
            scope_type == "branch"
            and str(row.get("branchId") or "") == scope_key
        )
        or (
            scope_type == "salesman"
            and str(row.get("salesmanCode") or "") == scope_key
        )
    ]
    if not scoped:
        return dict(summary)
    return {**summary, "forecastAccuracy": _accuracy_metrics(scoped)}


class FirestoreAiRepository:
    def __init__(self, client: Any) -> None:
        self.client = client

    def earliest_order_date(self) -> date | None:
        from google.cloud.firestore_v1.base_query import FieldFilter

        for snapshot in (
            self.client.collection("orders")
            .where(
                filter=FieldFilter(
                    "submittedAt",
                    ">",
                    datetime.fromtimestamp(0, tz=timezone.utc),
                )
            )
            .order_by("submittedAt")
            .limit(1)
            .stream()
        ):
            return _week_date((snapshot.to_dict() or {}).get("submittedAt"))
        return None

    def read_forecast_window_setting(self) -> Any:
        snapshot = (
            self.client.collection("system_settings")
            .document("forecast_window")
            .get()
        )
        if not snapshot.exists:
            return None
        return (snapshot.to_dict() or {}).get("historyWeeks")

    def resolve_history_window(
        self, *, as_of: date, requested: int | None = None
    ) -> HistoryWindow:
        available = completed_weeks_since(self.earliest_order_date(), as_of)
        if requested is not None:
            return resolve_history_window(
                requested, available_weeks=available, source="preview"
            )
        return live_history_window(
            self.read_forecast_window_setting(), available_weeks=available
        )

    def read_inputs(
        self, *, as_of: date, history_weeks: int = DEFAULT_HISTORY_WEEKS
    ) -> dict[str, list[dict[str, Any]]]:
        from google.cloud.firestore_v1.base_query import FieldFilter

        current_week = week_start(as_of)
        read_weeks = max(history_weeks, DEFAULT_HISTORY_WEEKS)
        oldest_week = current_week.fromordinal(current_week.toordinal() - read_weeks * 7)
        start_local = datetime.combine(oldest_week, time.min, tzinfo=ASIA_KUCHING)
        end_local = datetime.combine(
            as_of + timedelta(days=1), time.min, tzinfo=ASIA_KUCHING
        )
        orders_query = (
            self.client.collection("orders")
            .where(
                filter=FieldFilter(
                    "submittedAt",
                    ">=",
                    start_local.astimezone(timezone.utc),
                )
            )
            .where(
                filter=FieldFilter(
                    "submittedAt",
                    "<",
                    end_local.astimezone(timezone.utc),
                )
            )
            .order_by("submittedAt", direction="DESCENDING")
            .limit(MAX_ORDERS + 1)
        )
        orders = _rows(orders_query.stream())
        if len(orders) > MAX_ORDERS:
            oldest_kept = _week_date(orders[MAX_ORDERS - 1].get("submittedAt"))
            fits = (
                completed_weeks_since(
                    oldest_kept + timedelta(days=7), as_of
                )
                if oldest_kept is not None
                else 0
            )
            raise WindowTooLargeError(
                read_weeks, fits if fits >= MIN_HISTORY_WEEKS else None
            )
        products = _capped(
            _rows(
                self.client.collection("products").limit(MAX_PRODUCTS + 1).stream()
            ),
            "products",
            MAX_PRODUCTS,
        )
        retailers = _capped(
            _rows(
                self.client.collection("retailers")
                .limit(MAX_RETAILERS + 1)
                .stream()
            ),
            "retailers",
            MAX_RETAILERS,
        )
        users = _capped(
            _rows(self.client.collection("users").limit(MAX_USERS + 1).stream()),
            "users",
            MAX_USERS,
        )
        return {
            "orders": orders,
            "products": products,
            "retailers": retailers,
            "users": users,
            "conversation_outcomes": _rows(
                self.client.collection("conversation_outcomes")
                .order_by("submittedAt", direction="DESCENDING")
                .limit(MAX_OUTCOMES)
                .stream()
            ),
        }

    def write_generation(self, result: GenerationResult) -> dict[str, int]:
        pattern_refs = [
            self.client.collection("retailer_item_patterns").document(
                row["patternId"]
            )
            for row in result.patterns
        ]
        existing_patterns = (
            {
                snapshot.id: snapshot.to_dict()
                for snapshot in self.client.get_all(pattern_refs)
                if snapshot.exists
            }
            if pattern_refs
            else {}
        )
        evaluations = _forecast_evaluations(result.patterns, existing_patterns)
        self._set_many(
            "retailer_item_patterns",
            ((row["patternId"], row) for row in result.patterns),
            merge=True,
        )

        now = datetime.now(timezone.utc)
        merged_insights: list[tuple[str, dict[str, Any]]] = []
        for row in result.insights:
            issue_id_value = row["issueId"]
            merged = self._refresh_insight(row, now)
            merged_insights.append((issue_id_value, merged))
        existing_segments = _rows(
            self.client.collection("retailer_segments")
            .limit(MAX_RETAILER_SEGMENTS)
            .stream()
        )
        retailer_segment_rows = _retailer_segment_rows(
            current=result.retailer_segments,
            existing=existing_segments,
            run_id=result.run["runId"],
            generated_at=now,
        )
        self._set_many(
            "retailer_segments",
            retailer_segment_rows,
            merge=False,
        )

        persisted_briefs = build_visit_briefs(
            (row for _, row in merged_insights),
            as_of=result.run["asOf"],
            run_id=result.run["runId"],
            generated_at=now,
            retailer_memory=result.retailer_memory,
            retailer_segments=result.retailer_segments,
            replenishment=result.replenishment,
            coverage_retailers=result.coverage_retailers,
        )
        existing_briefs = _rows(
            self.client.collection("visit_briefs")
            .limit(MAX_VISIT_BRIEFS)
            .stream()
        )
        visit_brief_rows = _visit_brief_rows(
            current=persisted_briefs,
            existing=existing_briefs,
            run_id=result.run["runId"],
            generated_at=now,
        )

        self._set_many(
            "weekly_ai_summaries",
            (
                (row["summaryId"], _summary_with_accuracy(row, evaluations))
                for row in result.weekly_summaries
            ),
            merge=True,
        )
        self._set_many(
            "visit_briefs",
            visit_brief_rows,
            merge=False,
        )
        from google.cloud.firestore_v1.base_query import FieldFilter

        existing_rankings = _rows(
            self.client.collection("retailer_priority_rankings")
            .where(filter=FieldFilter("status", "==", "active"))
            .limit(MAX_PRIORITY_RANKINGS)
            .stream()
        )
        ranking_rows = _priority_ranking_rows(
            current=result.priority_rankings,
            existing=existing_rankings,
            run_id=result.run["runId"],
            generated_at=now,
        )
        self._set_many(
            "retailer_priority_rankings",
            ranking_rows,
            merge=False,
        )
        notification_refs = [
            self.client.collection("dashboard_notifications").document(
                row["notificationId"]
            )
            for row in result.notifications[:MAX_NOTIFICATIONS]
        ]
        existing_notifications = (
            {
                snapshot.id: snapshot.to_dict()
                for snapshot in self.client.get_all(notification_refs)
                if snapshot.exists
            }
            if notification_refs
            else {}
        )
        notification_rows = _notification_rows(
            current=result.notifications[:MAX_NOTIFICATIONS],
            existing=existing_notifications,
            generated_at=now,
        )
        self._set_many(
            "dashboard_notifications",
            notification_rows,
            merge=False,
        )
        existing_memory = _rows(
            self.client.collection("retailer_memory")
            .limit(MAX_RETAILER_MEMORY)
            .stream()
        )
        retailer_memory_rows = _retailer_memory_rows(
            current=result.retailer_memory[:MAX_RETAILER_MEMORY],
            existing=existing_memory,
            run_id=result.run["runId"],
            generated_at=now,
        )
        self._set_many(
            "retailer_memory",
            retailer_memory_rows,
            merge=False,
        )
        self._set_many(
            "ai_runs",
            ((result.run["runId"], {**result.run, "status": "writing"}),),
            merge=False,
        )
        return {
            "patterns": len(result.patterns),
            "insights": len(result.insights),
            "retailerSegments": len(result.retailer_segments),
            "inactiveRetailerSegments": sum(
                row.get("status") == "inactive"
                for _, row in retailer_segment_rows
            ),
            "weeklySummaries": len(result.weekly_summaries),
            "visitBriefs": len(persisted_briefs),
            "inactiveVisitBriefs": sum(
                row.get("status") == "inactive"
                for _, row in visit_brief_rows
            ),
            "notifications": len(notification_rows),
            "retailerMemory": len(result.retailer_memory[:MAX_RETAILER_MEMORY]),
            "inactiveRetailerMemory": sum(
                row.get("status") == "inactive"
                for _, row in retailer_memory_rows
            ),
            "retailerPriorityRankings": len(ranking_rows),
            "inactiveRetailerPriorityRankings": sum(
                row.get("status") == "inactive" for _, row in ranking_rows
            ),
            "runs": 1,
        }

    def abandon_dead_runs(self, *, before: datetime) -> int:
        from google.cloud.firestore_v1.base_query import FieldFilter

        abandoned = 0
        for snapshot in (
            self.client.collection("ai_runs")
            .where(filter=FieldFilter("status", "in", ["started", "writing"]))
            .limit(50)
            .stream()
        ):
            started = (snapshot.to_dict() or {}).get("startedAt")
            if isinstance(started, datetime) and started < before:
                self.write_run_record(
                    snapshot.id,
                    {"status": "abandoned", "abandonedAt": datetime.now(timezone.utc)},
                )
                abandoned += 1
        return abandoned

    def write_run_record(
        self,
        run_id: str,
        payload: Mapping[str, Any],
        *,
        merge: bool = True,
    ) -> None:
        self._set_many(
            "ai_runs",
            ((run_id, {"runId": run_id, **dict(payload)}),),
            merge=merge,
        )

    def write_seed_documents(
        self,
        documents: Mapping[str, Iterable[tuple[str, Mapping[str, Any]]]],
    ) -> dict[str, int]:
        unexpected = set(documents).difference(DEMO_SEED_WRITE_COLLECTIONS)
        if unexpected:
            raise ValueError(
                "Demo seed attempted unsupported collection(s): "
                + ", ".join(sorted(unexpected))
            )
        counts: dict[str, int] = {}
        for collection, rows in documents.items():
            materialized = [(doc_id, dict(payload)) for doc_id, payload in rows]
            self._set_many(collection, materialized, merge=True)
            counts[collection] = len(materialized)
        return counts

    def _refresh_insight(
        self, computed: Mapping[str, Any], now: datetime
    ) -> dict[str, Any]:
        from google.api_core.exceptions import (
            AlreadyExists,
            FailedPrecondition,
            NotFound,
        )

        ref = self.client.collection("ai_insights").document(computed["issueId"])
        generated = {
            key: value
            for key, value in computed.items()
            if key not in HUMAN_FIELDS and key != "createdAt"
        }
        for attempt in range(5):
            snapshot = ref.get()
            previous = snapshot.to_dict() if snapshot.exists else None
            merged = merge_insight(previous, generated)
            merged.setdefault("createdAt", now)
            merged["updatedAt"] = now
            try:
                if not snapshot.exists:
                    ref.create(_firestore_value(merged))
                else:
                    updates = {key: merged[key] for key in generated}
                    updates["occurrenceCount"] = merged["occurrenceCount"]
                    updates["updatedAt"] = now
                    ref.update(
                        _firestore_value(updates),
                        option=self.client.write_option(
                            last_update_time=snapshot.update_time
                        ),
                    )
                return merged
            except (AlreadyExists, FailedPrecondition, NotFound):
                if attempt == 4:
                    raise
        raise RuntimeError("Insight refresh retry limit reached")

    def _set_many(
        self,
        collection: str,
        rows: Iterable[tuple[str, Mapping[str, Any]]],
        *,
        merge: bool,
    ) -> None:
        if collection not in ALLOWED_WRITE_COLLECTIONS:
            raise ValueError(
                f"AI runner attempted unsupported write collection: {collection}"
            )
        batch = self.client.batch()
        pending = 0
        for doc_id, payload in rows:
            ref = self.client.collection(collection).document(str(doc_id))
            batch.set(ref, _firestore_value(dict(payload)), merge=merge)
            pending += 1
            if pending == BATCH_SIZE:
                batch.commit()
                batch = self.client.batch()
                pending = 0
        if pending:
            batch.commit()

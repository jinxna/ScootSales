from __future__ import annotations

import hashlib
import json
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from forecasting.ai_core.calendar import (
    HISTORY_WINDOW_VERSION,
    HistoryWindow,
    completed_week_starts,
)
from forecasting.ai_core.forecast_contract import FORECAST_CONTRACT_VERSION
from forecasting.ai_service import cli
from forecasting.ai_service.generator import build_generation
from forecasting.ai_service.normalization import normalize_firestore_inputs
from forecasting.ai_service.repository import FirestoreAiRepository
from forecasting.service import app as service_app
from forecasting.service import auth, config, firebase_writer, firestore_reader, pipeline_runner

MOMENT = datetime(2026, 9, 18, 4, 0, tzinfo=timezone.utc)
AS_OF = date(2026, 9, 18)
WEEKS_OF_HISTORY = 30
ARTIFACT = Path(config.REPO_ROOT) / "eval_reports" / "forecast_window_e2e" / "result.json"

PRODUCTS = [
    {"productId": f"P{i}", "productName": f"Product {i}", "unitPrice": 2.0 + i}
    for i in (1, 2, 3)
]
RETAILERS = [
    {
        "retailerId": f"R{i}",
        "retailerName": f"Outlet {i}",
        "assignedSalesmanId": "S1",
        "branchId": "B1",
        "latitude": 1.55 + i / 100,
        "longitude": 110.35 + i / 100,
    }
    for i in (1, 2, 3, 4)
]
USERS = [{"uid": "u-s1", "employeeCode": "S1", "role": "salesman", "branchId": "B1"}]


def _quantity(retailer: int, product: int, week: int) -> float:
    if retailer == 1 and product == 1:
        return 30.0 if 18 <= week < 22 else (6.0 if week >= 22 else 12.0)
    return float((week * 7 + retailer * 3 + product * 5) % 5 + 1) if week % 2 == 0 else 0.0


def _orders() -> list[dict[str, Any]]:
    starts = completed_week_starts(AS_OF, weeks=WEEKS_OF_HISTORY)
    orders = []
    for week, start in enumerate(starts):
        for retailer in (1, 2, 3, 4):
            items = [
                {"productId": f"P{product}", "qty": qty, "price": 2.0 + product}
                for product in (1, 2, 3)
                if (qty := _quantity(retailer, product, week)) > 0
            ]
            if items:
                orders.append(
                    {
                        "orderId": f"O-{retailer}-{week}",
                        "submittedAt": (start + timedelta(days=2)).isoformat() + "T02:00:00+00:00",
                        "retailerId": f"R{retailer}",
                        "status": "confirmed",
                        "items": items,
                    }
                )
    return orders


def _profile(uid: str, role: str) -> dict[str, Any]:
    return {
        "accessVersion": {"integerValue": "2"},
        "uid": {"stringValue": uid},
        "role": {"stringValue": role},
        "status": {"stringValue": "active"},
        "branchId": {"stringValue": ""},
        "employeeCode": {"stringValue": ""},
    }


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _points(payload: dict[str, Any]) -> dict[str, float | None]:
    return {row["productId"]: row["point"] for row in payload["rows"]}


class _World:
    def __init__(self) -> None:
        self.documents = {
            "orders": _orders(),
            "products": PRODUCTS,
            "retailers": RETAILERS,
            "users": USERS,
        }
        self.setting: dict[str, Any] | None = None
        self.reads = 0
        self.writes: list[str] = []


@pytest.fixture()
def world(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> _World:
    state = _World()
    monkeypatch.setattr(config, "OPERATIONAL_FORECASTS_JSON", tmp_path / "operational_forecasts.json")
    monkeypatch.setattr(config, "TRAINING_RUNS_JSON", tmp_path / "forecast_training_runs.json")
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)
    monkeypatch.setattr(pipeline_runner, "_now", lambda: MOMENT)

    def list_documents(collection: str, **_: Any) -> list[dict[str, Any]]:
        state.reads += 1
        return [dict(row) for row in state.documents[collection]]

    def get_document(collection: str, doc_id: str, **_: Any) -> dict[str, Any] | None:
        assert (collection, doc_id) == ("system_settings", "forecast_window")
        state.reads += 1
        return None if state.setting is None else dict(state.setting)

    monkeypatch.setattr(firestore_reader, "list_documents", list_documents)
    monkeypatch.setattr(firestore_reader, "get_document", get_document)

    def recorder(name: str, result: Any):
        def record(*_: Any, **__: Any) -> Any:
            state.writes.append(name)
            return result

        return record

    monkeypatch.setattr(firebase_writer, "push_notification", recorder("push_notification", None))
    monkeypatch.setattr(firebase_writer, "push_import", recorder("push_import", None))
    monkeypatch.setattr(firebase_writer, "push_run", recorder("push_run", True))
    monkeypatch.setattr(firebase_writer, "push_forecast_results", recorder("push_forecast_results", 0))

    roles = {"admin-token": ("admin-uid", "admin"), "supervisor-token": ("sup-uid", "supervisor")}
    monkeypatch.setattr(
        auth, "_verify_firebase_token", lambda token: {"uid": roles[token][0]}
    )
    monkeypatch.setattr(
        auth,
        "_read_profile_document",
        lambda collection, uid, token: _profile(uid, roles[token][1])
        if collection == "user_access"
        else None,
    )
    return state


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_forecast_window_end_to_end(world: _World) -> None:
    result: dict[str, Any] = {
        "windowVersion": HISTORY_WINDOW_VERSION,
        "contractVersion": FORECAST_CONTRACT_VERSION,
        "asOf": AS_OF.isoformat(),
        "weeksOfHistory": WEEKS_OF_HISTORY,
        "steps": {},
    }
    steps = result["steps"]
    forecasts_file = config.OPERATIONAL_FORECASTS_JSON
    runs_file = config.TRAINING_RUNS_JSON

    with TestClient(service_app.app) as client:
        live8 = client.post("/run-forecast", headers=_headers("admin-token"))
        assert live8.status_code == 200
        run8 = live8.json()
        assert run8["status"] == "completed", run8
        assert (run8["historyWeeks"], run8["historyWindowSource"]) == (8, "default")
        assert run8["historyWindowVersion"] == HISTORY_WINDOW_VERSION
        file8 = json.loads(forecasts_file.read_text(encoding="utf-8"))
        assert file8["historyWeeks"] == 8
        assert {row["historyWeeks"] for row in file8["rows"]} == {8}
        assert json.loads(runs_file.read_text(encoding="utf-8"))[0]["historyWeeks"] == 8
        points8 = _points(file8)
        steps["liveDefault"] = {"historyWeeks": 8, "points": points8}

        before = (_sha(forecasts_file), _sha(runs_file))
        writes_before = list(world.writes)
        preview = client.post(
            "/preview-forecast", json={"historyWeeks": 12}, headers=_headers("admin-token")
        )
        assert preview.status_code == 200, preview.text
        body = preview.json()
        assert body["preview"]["window"]["historyWeeks"] == 12
        assert body["preview"]["window"]["windowEvaluated"] is True
        assert body["baseline"]["window"]["historyWeeks"] == 8
        assert {row["historyWeeks"] for row in body["preview"]["forecast"]["rows"]} == {12}
        assert {row["historyWeeks"] for row in body["baseline"]["forecast"]["rows"]} == {8}
        assert all(
            "comparisonForecasts" not in row for row in body["preview"]["forecast"]["rows"]
        )
        points12 = _points(body["preview"]["forecast"])
        assert _points(body["baseline"]["forecast"]) == points8
        assert points12 != points8, "N=12 must change at least one forecast"
        assert (_sha(forecasts_file), _sha(runs_file)) == before
        assert world.writes == writes_before
        steps["previewTwelve"] = {
            "jsonHashesUnchanged": True,
            "writerCalls": len(world.writes) - len(writes_before),
            "productsChanged": sorted(p for p in points12 if points12[p] != points8[p]),
        }

        clamped = client.post(
            "/preview-forecast", json={"historyWeeks": 2}, headers=_headers("admin-token")
        ).json()["preview"]["window"]
        assert (clamped["historyWeeks"], clamped["requestedHistoryWeeks"]) == (4, 2)
        assert clamped["historyWindowClamped"] is True
        refused = {}
        for label, value in (("string", "12"), ("float", 12.5), ("bool", True), ("null", None)):
            response = client.post(
                "/preview-forecast", json={"historyWeeks": value}, headers=_headers("admin-token")
            )
            assert response.status_code == 422, label
            refused[label] = response.status_code
        assert (_sha(forecasts_file), _sha(runs_file)) == before
        steps["bounds"] = {"2": clamped["historyWeeks"], "refused": refused}

        reads_before = world.reads
        denied = client.post(
            "/preview-forecast", json={"historyWeeks": 12}, headers=_headers("supervisor-token")
        )
        assert denied.status_code == 403
        assert world.reads == reads_before
        steps["supervisorPreview"] = {"status": denied.status_code}

        assert service_app._PREVIEW_LOCK.acquire(blocking=False)
        try:
            busy = client.post(
                "/preview-forecast", json={"historyWeeks": 12}, headers=_headers("admin-token")
            )
        finally:
            service_app._PREVIEW_LOCK.release()
        assert busy.status_code == 409
        steps["busyPreview"] = {"status": busy.status_code}

        world.setting = {"historyWeeks": 12}
        live12 = client.post("/run-forecast", headers=_headers("admin-token")).json()
        assert live12["status"] == "completed", live12
        assert (live12["historyWeeks"], live12["historyWindowSource"]) == (12, "setting")
        assert live12["windowEvaluated"] is True
        file12 = json.loads(forecasts_file.read_text(encoding="utf-8"))
        assert {row["historyWeeks"] for row in file12["rows"]} == {12}
        assert {
            row["comparisonForecasts"]["adaptive"]["historyWeeks"] for row in file12["rows"]
        } == {12}
        assert json.loads(runs_file.read_text(encoding="utf-8"))[0]["historyWeeks"] == 12
        assert _points(file12) == points12, "a live run equals the preview at the same window"
        assert _points(file12) != points8
        steps["liveTwelve"] = {"historyWeeks": 12, "points": _points(file12)}

        world.setting = {"historyWeeks": 7}
        live7 = client.post("/run-forecast", headers=_headers("admin-token")).json()
        assert (live7["historyWeeks"], live7["windowEvaluated"]) == (7, False)
        world.setting = {"historyWeeks": "12"}
        ignored = client.post("/run-forecast", headers=_headers("admin-token")).json()
        assert (ignored["historyWeeks"], ignored["historyWindowSource"]) == (8, "default")
        steps["otherSettings"] = {
            "seven": {"historyWeeks": 7, "windowEvaluated": False},
            "stringTwelve": {"historyWeeks": 8, "source": "default"},
        }

    generated = {}
    for weeks in (8, 12):
        window = HistoryWindow(weeks=weeks, requested=weeks, source="setting")
        normalized = normalize_firestore_inputs(
            orders=world.documents["orders"],
            products=PRODUCTS,
            retailers=RETAILERS,
            users=USERS,
            as_of=AS_OF,
            history_weeks=weeks,
        )
        output = build_generation(
            normalized,
            as_of=AS_OF,
            run_id=f"e2e-{weeks}",
            generated_at=MOMENT,
            orders=world.documents["orders"],
            window=window,
        )
        collections = {
            "retailer_item_patterns": output.patterns,
            "weekly_ai_summaries": output.weekly_summaries,
            "retailer_priority_rankings": output.priority_rankings,
            "ai_runs": (output.run,),
        }
        for name, rows in collections.items():
            assert rows, name
            assert {row["historyWeeks"] for row in rows} == {weeks}, name
            assert {row["historyWindowVersion"] for row in rows} == {HISTORY_WINDOW_VERSION}, name
        assert all(len(row["weeklyQuantities"]) == weeks for row in output.patterns)
        for insight in output.insights:
            expected = 8 if insight["type"] == "overdue_reorder" else weeks
            assert insight["historyWeeks"] == expected, insight["type"]
        generated[weeks] = {
            "patterns": len(output.patterns),
            "insights": len(output.insights),
            "rankings": len(output.priority_rankings),
            "forecastNextWeek": sum(row["forecastNextWeek"] for row in output.patterns),
        }
    assert generated[8]["forecastNextWeek"] != generated[12]["forecastNextWeek"]
    steps["intelligenceRun"] = generated

    result["passed"] = True
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")


class _Snapshot:
    def __init__(self, data: dict[str, Any] | None) -> None:
        self._data = data
        self.exists = data is not None

    def to_dict(self) -> dict[str, Any] | None:
        return self._data


class _Query:
    def __init__(self, client: "_Client", name: str) -> None:
        self.client, self.name = client, name

    def where(self, *_: Any, **__: Any) -> "_Query":
        return self

    def order_by(self, *_: Any, **__: Any) -> "_Query":
        return self

    def limit(self, _: int) -> "_Query":
        return self

    def stream(self) -> list[_Snapshot]:
        first = min(self.client.orders, key=lambda row: row["submittedAt"])
        return [_Snapshot({"submittedAt": first["submittedAt"]})]

    def document(self, _: str) -> "_Query":
        return self

    def get(self) -> _Snapshot:
        return _Snapshot(self.client.setting)


class _Client:
    def __init__(self, orders: list[dict[str, Any]], setting: dict[str, Any] | None) -> None:
        self.orders, self.setting = orders, setting

    def collection(self, name: str) -> _Query:
        return _Query(self, name)


def test_cli_reads_the_saved_window_and_previews_without_writing(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    orders = _orders()
    seen: list[int] = []

    class Repository(FirestoreAiRepository):
        def read_inputs(self, *, as_of: date, history_weeks: int = 8) -> dict[str, Any]:
            seen.append(history_weeks)
            return {
                "orders": orders,
                "products": PRODUCTS,
                "retailers": RETAILERS,
                "users": USERS,
                "conversation_outcomes": [],
            }

        def write_generation(self, result: Any) -> dict[str, int]:
            raise AssertionError("a dry run must not write")

    setting: dict[str, Any] = {"historyWeeks": 12}
    monkeypatch.setattr(cli, "FirestoreAiRepository", Repository)
    monkeypatch.setattr(
        cli,
        "create_firestore_client",
        lambda _account, _project: _Client(
            [{"submittedAt": o["submittedAt"]} for o in orders], setting
        ),
    )

    def completed() -> dict[str, Any]:
        lines = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.strip()]
        return next(line for line in lines if line["event"] == "ai_runner_completed")

    assert cli.main(["--as-of", AS_OF.isoformat(), "--project", "dev"]) == 0
    assert completed()["historyWeeks"] == 12
    assert cli.main(["--as-of", AS_OF.isoformat(), "--project", "dev", "--history-weeks", "26"]) == 0
    assert completed()["historyWeeks"] == 26
    assert seen == [12, 26]
    with pytest.raises(SystemExit):
        cli.main(
            ["--apply", "--project", "dev", "--confirm", "APPLY-cos40005", "--history-weeks", "12"]
        )

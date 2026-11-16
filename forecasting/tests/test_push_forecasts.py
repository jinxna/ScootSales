from __future__ import annotations

import pytest

from forecasting.ai_core.calendar import HistoryWindow
from forecasting.service import firebase_writer, pipeline_runner, push_forecasts

_INPUTS = {"orders": [], "products": [], "retailers": [], "users": [], "conversation_outcomes": []}


class _Repo:
    def __init__(self, client):
        pass

    def resolve_history_window(self, *, as_of, requested=None):
        return HistoryWindow(weeks=8, requested=8, source="default")

    def read_inputs(self, *, as_of, history_weeks=8):
        return dict(_INPUTS)


@pytest.fixture()
def wired(monkeypatch):
    calls = {"run": [], "push_run": [], "push_rows": 0, "use_client": []}
    monkeypatch.setattr(push_forecasts, "FirestoreAiRepository", _Repo)

    def fake_run(*args, **kwargs):
        calls["run"].append(kwargs)
        return {
            "status": "completed", "runId": "run_x", "productCount": 3,
            "periodStart": "2026-10-05", "forecastedProducts": 2,
            "insufficientHistoryProducts": 1, "inputCounts": {},
        }

    def fake_push_rows(rows=None):
        calls["push_rows"] = 3
        return 3

    monkeypatch.setattr(pipeline_runner, "run_forecast", fake_run)
    monkeypatch.setattr(firebase_writer, "use_client", lambda c: calls["use_client"].append(c))
    monkeypatch.setattr(firebase_writer, "push_run", lambda r: calls["push_run"].append(r) or True)
    monkeypatch.setattr(firebase_writer, "push_forecast_results", fake_push_rows)
    return calls


def _main(argv):
    return push_forecasts.main(argv, client_factory=lambda sa, project: object())


def test_project_is_required():
    with pytest.raises(SystemExit):
        push_forecasts.parse_args([])


@pytest.mark.parametrize(
    "argv",
    [
        ["--project", "dev", "--apply"],
        ["--project", "dev", "--apply", "--confirm", "APPLY-demo-fyp-a"],
        ["--project", "demo", "--apply", "--confirm", "APPLY-cos40005"],
        ["--project", "dev", "--confirm", "APPLY-cos40005"],
    ],
)
def test_bad_confirmation_is_rejected(argv):
    with pytest.raises(SystemExit):
        push_forecasts.parse_args(argv)


def test_dry_run_computes_but_writes_nothing(wired, capsys):
    assert _main(["--project", "dev"]) == 0
    assert wired["run"][0]["inputs"].keys() == {"orders", "products", "retailers", "users"}
    assert wired["push_run"] == [] and wired["use_client"] == [] and wired["push_rows"] == 0
    assert '"wouldWrite"' in capsys.readouterr().out


def test_apply_pushes_run_and_rows(wired, capsys):
    assert _main(["--project", "dev", "--apply", "--confirm", "APPLY-cos40005"]) == 0
    assert len(wired["use_client"]) == 1 and len(wired["push_run"]) == 1 and wired["push_rows"] == 3
    assert '"demand_forecasts": 3' in capsys.readouterr().out


def test_failed_run_exits_1(monkeypatch, wired):
    monkeypatch.setattr(
        pipeline_runner, "run_forecast",
        lambda *a, **k: {"status": "failed", "reason": "unexpected_error", "error": "x"},
    )
    assert _main(["--project", "dev", "--apply", "--confirm", "APPLY-cos40005"]) == 1
    assert wired["push_run"] == []


def test_no_recent_orders_exits_1_before_any_write(monkeypatch, wired):
    monkeypatch.setattr(
        pipeline_runner, "run_forecast",
        lambda *a, **k: {"status": "completed", "productCount": 5, "forecastedProducts": 0},
    )
    assert _main(["--project", "dev", "--apply", "--confirm", "APPLY-cos40005"]) == 1
    assert wired["push_run"] == [] and wired["use_client"] == [] and wired["push_rows"] == 0


def test_client_creation_failure_exits_1(wired):
    def boom(sa, project):
        raise RuntimeError("no credentials")

    assert push_forecasts.main(["--project", "dev"], client_factory=boom) == 1


def test_run_forecast_accepts_prefetched_inputs_without_token():
    inputs = {"orders": [], "products": [], "retailers": [], "users": []}
    run = pipeline_runner.run_forecast("test", inputs=inputs)
    assert run["status"] == "completed" and run["productCount"] == 0


def test_push_run_flattens_nested_arrays_and_reports_success():
    written = {}

    class _Doc:
        def set(self, payload):
            written.update(payload)

    class _Coll:
        def document(self, _id):
            return _Doc()

    class _Client:
        def collection(self, _name):
            return _Coll()

    firebase_writer.use_client(_Client())
    try:
        ok = firebase_writer.push_run(
            {"runId": "r", "dataQuality": {"missingPricePairs": [["R1", "P1"]], "n": 1}}
        )
    finally:
        firebase_writer._client = None
        firebase_writer._initialised = False
        firebase_writer._available = False
    assert ok is True
    assert written["dataQuality"]["missingPricePairs"] == ["R1 / P1"]


def test_full_forecast_mirror_writes_601_rows_in_two_batches(monkeypatch, tmp_path):
    import json
    from unittest.mock import MagicMock

    source = tmp_path / "forecasts.json"
    source.write_text(json.dumps({"rows": [
        {"productId": f"p{i}", "periodStart": "2026-10-05", "point": 1, "status": "ok"}
        for i in range(601)
    ]}), encoding="utf-8")
    client = MagicMock()
    monkeypatch.setattr(firebase_writer, "_firestore", lambda: client)
    monkeypatch.setattr(firebase_writer.config, "OPERATIONAL_FORECASTS_JSON", source)
    assert firebase_writer.push_forecast_results() == 601
    assert client.batch.call_count == 2
    assert client.batch.return_value.commit.call_count == 2


def test_push_fails_when_fewer_rows_than_run_reports(wired, monkeypatch, capsys):
    monkeypatch.setattr(
        pipeline_runner, "run_forecast",
        lambda *a, **k: {"status": "completed", "runId": "run_x", "productCount": 601, "forecastedProducts": 600},
    )
    monkeypatch.setattr(firebase_writer, "push_forecast_results", lambda rows=None: 600)
    assert _main(["--project", "dev", "--apply", "--confirm", "APPLY-cos40005"]) == 1
    assert "forecast_rows_not_written" in capsys.readouterr().err


def test_writer_counts_only_acknowledged_commits(monkeypatch, tmp_path):
    import json
    from unittest.mock import MagicMock

    source = tmp_path / "forecasts.json"
    source.write_text(json.dumps({"rows": [
        {"productId": "p1", "periodStart": "2026-10-05", "point": 7, "status": "ok"},
    ]}), encoding="utf-8")
    client = MagicMock()
    client.batch.return_value.commit.side_effect = RuntimeError("commit failed")
    monkeypatch.setattr(firebase_writer, "_firestore", lambda: client)
    monkeypatch.setattr(firebase_writer.config, "OPERATIONAL_FORECASTS_JSON", source)
    assert firebase_writer.push_forecast_results() == 0

    client.batch.return_value.commit.side_effect = None
    assert firebase_writer.push_forecast_results() == 1


def test_fix_198_writer_refuses_a_credential_for_another_project(monkeypatch):
    from types import SimpleNamespace

    import firebase_admin
    from firebase_admin import firestore

    from forecasting.service import config

    monkeypatch.delenv("FIRESTORE_EMULATOR_HOST", raising=False)
    monkeypatch.setattr(config, "PUSH_FIRESTORE", True)
    monkeypatch.setattr(config, "SERVICE_ACCOUNT_KEY", None)
    monkeypatch.setattr(config, "FIREBASE_PROJECT_ID", "company-a")
    monkeypatch.setattr(firebase_admin, "_apps", {"default": object()})
    monkeypatch.setattr(firebase_writer, "_initialised", False)
    monkeypatch.setattr(firebase_writer, "_available", False)
    monkeypatch.setattr(firebase_writer, "_client", None)
    monkeypatch.setattr(
        firestore, "client", lambda: SimpleNamespace(project="company-b")
    )

    assert firebase_writer.mirror_enabled() is False
    assert firebase_writer.push_forecast_results(rows=[{"productId": "P"}]) == 0

    monkeypatch.setattr(firebase_writer, "_initialised", False)
    monkeypatch.setattr(
        firestore, "client", lambda: SimpleNamespace(project="company-a")
    )
    assert firebase_writer.mirror_enabled() is True


def test_fix_237_dry_run_leaves_local_forecast_files_untouched(monkeypatch, tmp_path):
    for name in ("OPERATIONAL_FORECASTS_JSON", "TRAINING_RUNS_JSON"):
        monkeypatch.setattr(
            pipeline_runner.config, name, tmp_path / f"{name}.json"
        )
    inputs = {"orders": [], "products": [], "retailers": [], "users": []}

    dry = pipeline_runner.run_forecast("test", inputs=inputs, save_local=False)
    assert dry["status"] == "completed"
    assert list(tmp_path.iterdir()) == []

    saved = pipeline_runner.run_forecast("test", inputs=inputs)
    assert saved["status"] == "completed"
    assert len(list(tmp_path.iterdir())) == 2


def test_headless_run_never_writes_local_files(wired):
    assert _main(["--project", "dev"]) == 0
    assert wired["run"][-1]["save_local"] is False
    assert _main(["--project", "dev", "--apply", "--confirm", "APPLY-cos40005"]) == 0
    assert wired["run"][-1]["save_local"] is False
    assert wired["run"][-1]["rows_out"] == []

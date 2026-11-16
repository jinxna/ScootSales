from __future__ import annotations

from pathlib import Path
from typing import Any, Iterator
import zipfile

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from forecasting.service import app as service_app
from forecasting.service import auth, config


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(service_app.app) as test_client:
        yield test_client


def _allow_admin(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        auth,
        "authorize_request_headers",
        lambda **_: auth.ForecastAdministrator(
            uid="admin-uid", role="admin", token="test-token"
        ),
    )


def test_health_is_public_but_every_data_endpoint_requires_authentication(
    client: TestClient,
) -> None:
    health = client.get("/health")
    assert health.status_code == 200
    assert set(health.json()) == {"status", "hasForecast"}

    for path in (
        "/",
        "/latest-forecast",
        "/forecast-runs",
        "/forecast-errors",
        "/forecast-imports",
        "/docs",
        "/redoc",
        "/openapi.json",
    ):
        response = client.get(path)
        assert response.status_code == 401, path
        assert response.headers["www-authenticate"] == "Bearer"


def test_unauthenticated_run_never_reaches_pipeline(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = 0

    def fake_run(_: str) -> dict[str, Any]:
        nonlocal calls
        calls += 1
        return {"status": "completed"}

    monkeypatch.setattr(service_app.pipeline_runner, "run_forecast", fake_run)

    service_app._MUTATION_LOCK.acquire()
    try:
        response = client.post("/run-forecast")
        upload_response = client.post(
            "/import-excel",
            files={"file": ("orders.csv", b"a,b\n1,2", "text/csv")},
        )
    finally:
        service_app._MUTATION_LOCK.release()

    assert response.status_code == 401
    assert upload_response.status_code == 401
    assert calls == 0


def test_approved_preflight_for_protected_route_does_not_require_token(
    client: TestClient,
) -> None:
    response = client.options(
        "/run-forecast",
        headers={
            "Origin": "http://localhost:5000",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "Authorization",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://localhost:5000"


def test_disallowed_browser_origin_is_rejected_before_token_verification(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    verified = False

    def fake_verify(_: str) -> dict[str, Any]:
        nonlocal verified
        verified = True
        return {"uid": "admin-uid"}

    monkeypatch.setattr(auth, "_verify_firebase_token", fake_verify)

    response = client.post(
        "/run-forecast",
        headers={
            "Authorization": "Bearer valid",
            "Origin": "https://attacker.example",
        },
    )

    assert response.status_code == 403
    assert verified is False


def test_verified_non_admin_is_denied(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        auth,
        "_verify_firebase_token",
        lambda _: {"uid": "supervisor-uid"},
    )
    monkeypatch.setattr(
        auth,
        "_load_authoritative_profile",
        lambda _uid, _token: {
            "role": {"stringValue": "supervisor"},
            "status": {"stringValue": "active"},
        },
    )

    response = client.post(
        "/run-forecast",
        headers={"Authorization": "Bearer valid"},
    )

    assert response.status_code == 403


def test_active_admin_can_run_and_parallel_mutation_is_rejected(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _allow_admin(monkeypatch)
    calls = 0
    forwarded: list[str] = []

    def fake_run(triggered_by: str, token: str = "") -> dict[str, Any]:
        nonlocal calls
        calls += 1
        forwarded.append(token)
        return {"status": "completed", "runId": "run-1"}

    monkeypatch.setattr(service_app, "_run_and_mirror", fake_run)

    response = client.post("/run-forecast")
    assert response.status_code == 200
    assert response.json()["runId"] == "run-1"
    assert calls == 1
    assert forwarded == ["test-token"]

    service_app._MUTATION_LOCK.acquire()
    try:
        blocked = client.post("/run-forecast")
    finally:
        service_app._MUTATION_LOCK.release()
    assert blocked.status_code == 409
    assert calls == 1


def test_preview_is_cached_per_user_for_sixty_seconds(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    current = {"uid": "admin-a"}
    monkeypatch.setattr(
        auth,
        "authorize_request_headers",
        lambda **_: auth.ForecastAdministrator(
            uid=current["uid"], role="admin", token="token-" + current["uid"]
        ),
    )
    runs: list[tuple[int, str]] = []

    def fake_preview(requested: int, *, token: str) -> dict[str, Any]:
        runs.append((requested, token))
        return {"status": "ok", "run": len(runs)}

    clock = {"now": 1000.0}
    monkeypatch.setattr(service_app.pipeline_runner, "preview_forecast", fake_preview)
    monkeypatch.setattr(
        service_app.pipeline_runner, "_read_window_setting", lambda token: None
    )
    monkeypatch.setattr(service_app.time, "monotonic", lambda: clock["now"])
    service_app._PREVIEW_CACHE.clear()

    first = client.post("/preview-forecast", json={"historyWeeks": 12})
    clock["now"] += 30
    second = client.post("/preview-forecast", json={"historyWeeks": 12})
    assert first.json() == second.json() == {"status": "ok", "run": 1}
    assert len(runs) == 1

    client.post("/preview-forecast", json={"historyWeeks": 16})
    assert [weeks for weeks, _ in runs] == [12, 16]

    current["uid"] = "admin-b"
    other = client.post("/preview-forecast", json={"historyWeeks": 12})
    assert other.json() == {"status": "ok", "run": 3}
    assert runs[-1] == (12, "token-admin-b")

    current["uid"] = "admin-a"
    clock["now"] += 31
    expired = client.post("/preview-forecast", json={"historyWeeks": 12})
    assert expired.json() == {"status": "ok", "run": 4}


def test_a_changed_live_window_setting_is_not_masked_by_the_preview_cache(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _allow_admin(monkeypatch)
    setting: dict[str, Any] = {"historyWeeks": 8}
    monkeypatch.setattr(
        service_app.pipeline_runner,
        "_read_window_setting",
        lambda token: dict(setting),
    )
    monkeypatch.setattr(
        service_app.pipeline_runner,
        "preview_forecast",
        lambda requested, *, token: {"preview": requested, "baseline": setting["historyWeeks"]},
    )
    service_app._PREVIEW_CACHE.clear()

    first = client.post("/preview-forecast", json={"historyWeeks": 12})
    assert first.json() == {"preview": 12, "baseline": 8}
    setting["historyWeeks"] = 16
    second = client.post("/preview-forecast", json={"historyWeeks": 12})
    assert second.json() == {"preview": 12, "baseline": 16}


def test_a_failed_preview_is_not_cached(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _allow_admin(monkeypatch)
    outcomes = [service_app.firestore_reader.FirestoreReadError("down"), {"status": "ok"}]

    def fake_preview(requested: int, *, token: str) -> dict[str, Any]:
        outcome = outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    monkeypatch.setattr(service_app.pipeline_runner, "preview_forecast", fake_preview)
    monkeypatch.setattr(
        service_app.pipeline_runner, "_read_window_setting", lambda token: None
    )
    service_app._PREVIEW_CACHE.clear()

    assert client.post("/preview-forecast", json={"historyWeeks": 8}).status_code == 502
    assert client.post("/preview-forecast", json={"historyWeeks": 8}).json() == {"status": "ok"}


def test_upload_is_bounded_and_hostile_filename_never_controls_path(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _allow_admin(monkeypatch)
    monkeypatch.setattr(config, "IMPORTS", tmp_path)
    monkeypatch.setattr(config, "ensure_dirs", lambda: tmp_path.mkdir(exist_ok=True))
    monkeypatch.setattr(config, "MAX_UPLOAD_BYTES", 8)
    monkeypatch.setattr(config, "MAX_REQUEST_BYTES", 1024 * 1024)

    called = False

    def fake_import(path: Path, original_name: str) -> dict[str, Any]:
        nonlocal called
        called = True
        resolved = Path(path).resolve()
        assert resolved.parent == tmp_path.resolve()
        assert resolved.name.startswith("_incoming_")
        assert original_name == "evil.csv"
        return {
            "importId": "imp-1",
            "sourceFile": original_name,
            "validRows": 1,
            "errorRows": 0,
            "warningRows": 0,
        }

    monkeypatch.setattr(service_app.excel_importer, "import_table", fake_import)
    monkeypatch.setattr(service_app.firebase_writer, "push_import", lambda _: None)
    monkeypatch.setattr(
        service_app.firebase_writer,
        "push_notification",
        lambda **_: None,
    )

    too_large = client.post(
        "/import-excel",
        files={"file": ("orders.csv", b"123456789", "text/csv")},
    )
    assert too_large.status_code == 413
    assert called is False
    assert list(tmp_path.iterdir()) == []

    accepted = client.post(
        "/import-excel",
        files={"file": ("../../evil.csv", b"a,b\n1,2", "text/csv")},
    )
    assert accepted.status_code == 200
    assert called is True
    assert list(tmp_path.iterdir()) == []


def test_unsafe_non_loopback_service_host_is_refused(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config, "HOST", "0.0.0.0")
    with pytest.raises(RuntimeError, match="local-only"):
        config.validate_service_security()

    monkeypatch.setattr(config, "HOST", "127.0.0.1")
    config.validate_service_security()


@pytest.mark.parametrize(
    "member_name,content,expected",
    [
        (
            "xl/worksheets/sheet1.xml",
            b"<worksheet><sheetData/><f>SUM(A1:A2)</f></worksheet>",
            "formulas",
        ),
        ("xl/vbaProject.bin", b"macro", "Macro-enabled"),
    ],
)
def test_xlsx_formulas_and_macros_are_rejected(
    tmp_path: Path,
    member_name: str,
    content: bytes,
    expected: str,
) -> None:
    workbook = tmp_path / "unsafe.xlsx"
    with zipfile.ZipFile(workbook, "w") as archive:
        archive.writestr(member_name, content)

    with pytest.raises(HTTPException, match=expected):
        service_app._validate_xlsx_upload(workbook)


def test_fix_190_run_fails_when_results_do_not_reach_the_company_database(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _allow_admin(monkeypatch)
    rows = [{"productId": f"P{n}", "periodStart": "2026-11-09"} for n in range(5)]

    def fake_run(*_args: Any, rows_out: list[dict[str, Any]], **_kwargs: Any) -> dict[str, Any]:
        rows_out.extend(rows)
        return {"status": "completed", "runId": "run-1"}

    notices: list[str] = []
    monkeypatch.setattr(service_app.pipeline_runner, "run_forecast", fake_run)
    monkeypatch.setattr(service_app.firebase_writer, "mirror_enabled", lambda: True)
    monkeypatch.setattr(service_app.firebase_writer, "push_run", lambda _run: True)
    monkeypatch.setattr(
        service_app.firebase_writer, "push_forecast_results", lambda rows: 3
    )
    monkeypatch.setattr(
        service_app.firebase_writer,
        "push_notification",
        lambda **kwargs: notices.append(kwargs["title"]),
    )

    response = client.post("/run-forecast", headers={"Authorization": "Bearer t"})

    assert response.status_code == 502
    assert "3 of 5" in response.json()["detail"]
    assert notices == ["Forecast run failed"]

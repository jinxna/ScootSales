import json
from types import SimpleNamespace

import pytest

from forecasting.ai_core.calendar import HistoryWindow
from forecasting.ai_service import cli


_DEV_APPLY_ARGS = [
    "--apply",
    "--project",
    "dev",
    "--confirm",
    "APPLY-cos40005",
]


class _FailingRepository:
    instances = []

    def __init__(self, client):
        self.records = []
        self.__class__.instances.append(self)

    def write_run_record(self, run_id, payload, *, merge=True):
        self.records.append((run_id, dict(payload), merge))

    def abandon_dead_runs(self, *, before):
        return 0

    def resolve_history_window(self, *, as_of, requested=None):
        return HistoryWindow(weeks=8, requested=8, source="default")

    def read_inputs(self, *, as_of, history_weeks=8):
        raise RuntimeError("simulated read failure")


class _SuccessfulRepository:
    instances = []

    def __init__(self, client):
        self.records = []
        self.__class__.instances.append(self)

    def write_run_record(self, run_id, payload, *, merge=True):
        self.records.append((run_id, dict(payload), merge))

    def abandon_dead_runs(self, *, before):
        return 0

    def resolve_history_window(self, *, as_of, requested=None):
        return HistoryWindow(weeks=8, requested=8, source="default")

    def read_inputs(self, *, as_of, history_weeks=8):
        return {
            "orders": [],
            "products": [],
            "retailers": [],
            "users": [],
            "conversation_outcomes": [],
        }

    def write_generation(self, result):
        return {"patterns": 0, "insights": 0, "runs": 1}

    def read_scorecard_enabled(self):
        return False


def test_cli_returns_nonzero_and_records_structured_failure(
    monkeypatch,
    capsys,
) -> None:
    _FailingRepository.instances.clear()
    monkeypatch.setattr(
        cli,
        "create_firestore_client",
        lambda _service_account, _project_id: object(),
    )
    monkeypatch.setattr(cli, "FirestoreAiRepository", _FailingRepository)

    result = cli.main([*_DEV_APPLY_ARGS, "--as-of", "2026-06-15"])

    assert result == 1
    repository = _FailingRepository.instances[0]
    assert repository.records[0][1]["status"] == "started"
    assert repository.records[-1][1]["status"] == "failed"
    assert repository.records[-1][1]["partialWritesPossible"] is True
    captured = capsys.readouterr()
    events = [
        json.loads(line)
        for line in (captured.out + captured.err).splitlines()
        if line.strip()
    ]
    assert events[0]["event"] == "ai_runner_started"
    assert events[-1]["event"] == "ai_runner_failed"
    assert events[-1]["errorType"] == "RuntimeError"


def test_cli_success_records_counts_and_emits_completion(
    monkeypatch,
    capsys,
) -> None:
    _SuccessfulRepository.instances.clear()
    monkeypatch.setattr(
        cli,
        "create_firestore_client",
        lambda _service_account, _project_id: object(),
    )
    monkeypatch.setattr(cli, "FirestoreAiRepository", _SuccessfulRepository)
    monkeypatch.setattr(cli, "normalize_firestore_inputs", lambda **_: object())
    monkeypatch.setattr(
        cli,
        "build_generation",
        lambda *args, **kwargs: SimpleNamespace(
            run={
                "runId": kwargs["run_id"],
                "asOf": kwargs["as_of"],
                "highPriorityCount": 0,
                "valueAtRiskRm": 0.0,
                "dataQuality": {},
            },
            patterns=({"patternId": "p1"},),
            insights=(),
            visit_briefs=(),
            retailer_segments=(),
            weekly_summaries=(),
            notifications=(),
            retailer_memory=(),
        ),
    )

    result = cli.main([*_DEV_APPLY_ARGS, "--as-of", "2026-06-15"])

    assert result == 0
    repository = _SuccessfulRepository.instances[0]
    assert repository.records[0][1]["status"] == "started"
    assert repository.records[-1][1]["status"] == "completed"
    assert repository.records[-1][1]["emptyOutput"] is False
    assert repository.records[-1][1]["writeCounts"]["runs"] == 1
    events = [
        json.loads(line)
        for line in capsys.readouterr().out.splitlines()
        if line.strip()
    ]
    assert events[-1]["event"] == "ai_runner_completed"
    assert events[-1]["inputCounts"]["orders"] == 0


def test_plan_payload_summarises_scopes_and_flags_bad_values() -> None:
    result = SimpleNamespace(
        patterns=(
            {"forecastStatus": "ok"},
            {"forecastStatus": "insufficient_history"},
        ),
        priority_rankings=(
            {
                "scopeKey": "S1",
                "weekKey": "2026-W38",
                "retailerCount": 2,
                "chosenCount": 1,
                "isDemo": False,
                "ranking": (
                    {"expectedOrderValueRm": 10.0, "exploitOrExplore": "exploit"},
                    {"expectedOrderValueRm": 0.0, "exploitOrExplore": "explore"},
                ),
            },
            {
                "scopeKey": "S1",
                "weekKey": "2026-W38",
                "retailerCount": 1,
                "chosenCount": 1,
                "isDemo": False,
                "ranking": (
                    {
                        "expectedOrderValueRm": float("nan"),
                        "exploitOrExplore": "exploit",
                    },
                ),
            },
        ),
    )

    plan = cli._plan_payload(result)

    assert plan["scopeCount"] == 2
    assert plan["duplicateScopeWeeks"] == ["S1@2026-W38"]
    assert plan["patternForecastStatusMix"] == {
        "ok": 1,
        "insufficient_history": 1,
    }
    assert plan["nonFiniteExpectedValues"] == 1
    assert plan["negativeExpectedValues"] == 0
    assert plan["scopes"][0]["exploreCount"] == 1
    assert plan["scopes"][0]["topExpectedOrderValueRm"] == 10.0
    assert plan["scopes"][0]["minExpectedOrderValueRm"] == 0.0


def test_cli_defaults_to_dry_run_and_requires_apply_for_writes() -> None:
    parser = cli.build_parser()

    assert parser.parse_args([]).dry_run is True
    assert parser.parse_args(["--dry-run"]).dry_run is True
    parsed = parser.parse_args(_DEV_APPLY_ARGS)
    assert parsed.dry_run is False
    assert parsed.project == "dev"


@pytest.mark.parametrize(
    "arguments",
    [
        ["--apply"],
        ["--apply", "--project", "dev"],
        ["--apply", "--project", "dev", "--confirm", "wrong"],
        ["--dry-run", "--confirm", "APPLY-cos40005"],
        ["--seed-demo"],
        ["--seed-demo", "--project", "dev"],
        [
            "--apply",
            "--seed-demo",
            "--project",
            "dev",
            "--confirm",
            "APPLY-cos40005",
        ],
    ],
)
def test_cli_rejects_incomplete_or_mistargeted_write_gates(
    arguments: list[str],
) -> None:
    with pytest.raises(SystemExit) as raised:
        cli.build_parser().parse_args(arguments)
    assert raised.value.code == 2


def test_cli_accepts_exact_demo_write_gate() -> None:
    parsed = cli.build_parser().parse_args(
        [
            "--apply",
            "--seed-demo",
            "--project",
            "demo",
            "--confirm",
            "APPLY-demo-fyp-a",
        ]
    )
    assert parsed.dry_run is False
    assert parsed.seed_demo is True


def test_rejected_write_gate_creates_no_firestore_client(monkeypatch) -> None:
    called = False

    def fail_if_called(*_args, **_kwargs):
        nonlocal called
        called = True
        raise AssertionError("Firestore client must not be created")

    monkeypatch.setattr(cli, "create_firestore_client", fail_if_called)

    with pytest.raises(SystemExit):
        cli.main(["--apply"])

    assert called is False


def test_fix_191_error_after_data_saved_does_not_record_failed(monkeypatch) -> None:
    _SuccessfulRepository.instances.clear()
    monkeypatch.setattr(
        cli, "create_firestore_client", lambda _service_account, _project_id: object()
    )
    monkeypatch.setattr(cli, "FirestoreAiRepository", _SuccessfulRepository)
    monkeypatch.setattr(cli, "normalize_firestore_inputs", lambda **_: object())
    monkeypatch.setattr(
        cli,
        "build_generation",
        lambda *args, **kwargs: SimpleNamespace(
            run={"runId": kwargs["run_id"]},
            patterns=({"patternId": "p1"},),
            insights=(),
        ),
    )

    def late_failure(**_kwargs):
        raise RuntimeError("summary could not be built")

    monkeypatch.setattr(cli, "_summary_payload", late_failure)

    result = cli.main([*_DEV_APPLY_ARGS, "--as-of", "2026-06-15"])

    assert result == 1
    last = _SuccessfulRepository.instances[0].records[-1][1]
    assert last["status"] == "completed"
    assert last["lateError"] == "summary could not be built"
    assert last["partialWritesPossible"] is False


def test_apply_with_empty_generation_writes_nothing_and_fails(monkeypatch) -> None:
    _SuccessfulRepository.instances.clear()
    written = []
    monkeypatch.setattr(
        cli, "create_firestore_client", lambda _service_account, _project_id: object()
    )
    monkeypatch.setattr(cli, "FirestoreAiRepository", _SuccessfulRepository)
    monkeypatch.setattr(
        _SuccessfulRepository,
        "write_generation",
        lambda self, result: written.append(result),
    )
    monkeypatch.setattr(cli, "normalize_firestore_inputs", lambda **_: object())
    monkeypatch.setattr(
        cli,
        "build_generation",
        lambda *args, **kwargs: SimpleNamespace(
            run={"runId": kwargs["run_id"]}, patterns=(), insights=()
        ),
    )

    result = cli.main([*_DEV_APPLY_ARGS, "--as-of", "2026-06-15"])

    assert result == 1
    assert written == []
    last = _SuccessfulRepository.instances[0].records[-1][1]
    assert last["status"] == "failed"
    assert last["errorType"] == "EmptyGenerationError"


def test_apply_with_insights_but_no_patterns_writes_nothing_and_fails(monkeypatch) -> None:
    _SuccessfulRepository.instances.clear()
    written = []
    monkeypatch.setattr(
        cli, "create_firestore_client", lambda _service_account, _project_id: object()
    )
    monkeypatch.setattr(cli, "FirestoreAiRepository", _SuccessfulRepository)
    monkeypatch.setattr(
        _SuccessfulRepository,
        "write_generation",
        lambda self, result: written.append(result),
    )
    monkeypatch.setattr(cli, "normalize_firestore_inputs", lambda **_: object())
    monkeypatch.setattr(
        cli,
        "build_generation",
        lambda *args, **kwargs: SimpleNamespace(
            run={"runId": kwargs["run_id"]}, patterns=(), insights=(object(),)
        ),
    )

    result = cli.main([*_DEV_APPLY_ARGS, "--as-of", "2026-06-15"])

    assert result == 1
    assert written == []
    last = _SuccessfulRepository.instances[0].records[-1][1]
    assert last["status"] == "failed"
    assert last["errorType"] == "EmptyGenerationError"

from __future__ import annotations

from datetime import date
from types import SimpleNamespace

import pytest

from forecasting.ai_service.repository import FirestoreAiRepository


class _RecordingBatch:
    def __init__(self, written: dict[str, dict[str, object]]) -> None:
        self._written = written

    def set(self, ref: object, payload: object, merge: bool = False) -> None:
        self._written[ref.path] = {"payload": payload, "merge": merge}

    def commit(self) -> None:
        return None


class _RecordingCollection:
    def __init__(self, name: str, written: dict[str, dict[str, object]]) -> None:
        self._name = name
        self._written = written

    def document(self, doc_id: str) -> object:
        class _Ref:
            def __init__(self, path: str) -> None:
                self.path = path

        return _Ref(self._name + "/" + doc_id)

    def where(self, **_kwargs: object) -> "_RecordingCollection":
        return self

    def limit(self, _count: int) -> "_RecordingCollection":
        return self

    def stream(self) -> tuple[object, ...]:
        return ()


class _RecordingClient:
    def __init__(self) -> None:
        self.written: dict[str, dict[str, object]] = {}

    def collection(self, name: str) -> _RecordingCollection:
        return _RecordingCollection(name, self.written)

    def get_all(self, _refs: object) -> tuple[object, ...]:
        return ()

    def batch(self) -> _RecordingBatch:
        return _RecordingBatch(self.written)


def test_write_generation_persists_the_coverage_briefs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from forecasting.ai_service import repository as repository_module

    captured: dict[str, object] = {}
    real_builder = repository_module.build_visit_briefs

    def record(insights: object, **kwargs: object) -> object:
        captured.update(kwargs)
        return real_builder(insights, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(repository_module, "build_visit_briefs", record)

    client = _RecordingClient()
    repository = FirestoreAiRepository(client=client)  # type: ignore[arg-type]
    coverage = (
        {
            "retailerId": "R1",
            "retailerName": "First Shop",
            "salesmanUid": "uid-1",
            "salesmanCode": "S0001",
            "branchId": "B1",
            "isDemo": False,
            "sourceRunId": "run-1",
        },
    )
    result = SimpleNamespace(
        run={"runId": "run-1", "asOf": date(2026, 9, 19)},
        patterns=(),
        insights=(),
        retailer_segments=(),
        visit_briefs=(),
        weekly_summaries=(),
        notifications=(),
        retailer_memory=(),
        priority_rankings=(),
        replenishment=(),
        coverage_retailers=coverage,
    )

    written = repository.write_generation(result)  # type: ignore[arg-type]

    assert captured["coverage_retailers"] == coverage
    assert written["visitBriefs"] == 1
    assert "visit_briefs/" in "".join(client.written)


def test_fix_238_stale_rankings_are_retired_even_past_the_read_limit() -> None:
    from forecasting.ai_service.repository import MAX_PRIORITY_RANKINGS

    stored = [
        (f"old-{n}", {"rankingId": f"old-{n}", "status": "inactive"})
        for n in range(MAX_PRIORITY_RANKINGS + 100)
    ] + [
        (f"live-{n}", {"rankingId": f"live-{n}", "status": "active"})
        for n in range(20)
    ]

    class _Doc:
        def __init__(self, doc_id: str, data: dict[str, object]) -> None:
            self.id, self._data = doc_id, data

        def to_dict(self) -> dict[str, object]:
            return dict(self._data)

    class _Rankings(_RecordingCollection):
        def __init__(self, written: dict[str, dict[str, object]]) -> None:
            super().__init__("retailer_priority_rankings", written)
            self._active_only = False

        def where(self, *, filter: object) -> "_Rankings":
            self._active_only = filter.value == "active"  # type: ignore[attr-defined]
            return self

        def stream(self) -> list[_Doc]:
            rows = [
                row for row in stored
                if not self._active_only or row[1]["status"] == "active"
            ]
            return [_Doc(doc_id, data) for doc_id, data in rows][
                :MAX_PRIORITY_RANKINGS
            ]

    class _Client(_RecordingClient):
        def collection(self, name: str) -> _RecordingCollection:
            if name == "retailer_priority_rankings":
                return _Rankings(self.written)
            return super().collection(name)

    client = _Client()
    result = SimpleNamespace(
        run={"runId": "run-2", "asOf": date(2026, 9, 26)},
        patterns=(), insights=(), retailer_segments=(), visit_briefs=(),
        weekly_summaries=(), notifications=(), retailer_memory=(),
        priority_rankings=(), replenishment=(), coverage_retailers=(),
    )

    FirestoreAiRepository(client=client).write_generation(result)  # type: ignore[arg-type]

    retired = [
        path for path, row in client.written.items()
        if path.startswith("retailer_priority_rankings/live-")
        and row["payload"]["status"] == "inactive"  # type: ignore[index]
    ]
    assert len(retired) == 20


def test_fix_235_run_is_completed_only_at_the_end_and_dead_runs_are_marked() -> None:
    from datetime import datetime, timezone

    client = _RecordingClient()
    result = SimpleNamespace(
        run={"runId": "run-3", "asOf": date(2026, 9, 26), "status": "completed"},
        patterns=(), insights=(), retailer_segments=(), visit_briefs=(),
        weekly_summaries=(), notifications=(), retailer_memory=(),
        priority_rankings=(), replenishment=(), coverage_retailers=(),
    )
    FirestoreAiRepository(client=client).write_generation(result)  # type: ignore[arg-type]
    assert client.written["ai_runs/run-3"]["payload"]["status"] == "writing"  # type: ignore[index]

    old = datetime(2026, 9, 1, tzinfo=timezone.utc)
    docs = {"dead": {"startedAt": old}, "fresh": {"startedAt": datetime.now(timezone.utc)}}

    class _Snap:
        def __init__(self, doc_id: str) -> None:
            self.id = doc_id

        def to_dict(self) -> dict[str, object]:
            return docs[self.id]

    class _Runs(_RecordingCollection):
        def where(self, **_kwargs: object) -> "_Runs":
            return self

        def stream(self) -> list[_Snap]:
            return [_Snap(doc_id) for doc_id in docs]

    class _Client(_RecordingClient):
        def collection(self, name: str) -> _RecordingCollection:
            return _Runs(name, self.written) if name == "ai_runs" else super().collection(name)

    swept = _Client()
    abandoned = FirestoreAiRepository(client=swept).abandon_dead_runs(  # type: ignore[arg-type]
        before=datetime(2026, 11, 1, tzinfo=timezone.utc)
    )
    assert abandoned == 1
    assert swept.written["ai_runs/dead"]["payload"]["status"] == "abandoned"  # type: ignore[index]
    assert "ai_runs/fresh" not in swept.written

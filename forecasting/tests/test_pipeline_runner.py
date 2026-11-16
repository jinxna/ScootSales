from __future__ import annotations

import importlib.util
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from datetime import datetime, timezone
from pathlib import Path

import pytest

from forecasting.service import config, pipeline_runner
from forecasting.service import firestore_reader


def _order(order_id: str, day: str, quantity: float) -> dict[str, object]:
    return {
        "orderId": order_id,
        "submittedAt": day + "T02:00:00+00:00",
        "retailerId": "R1",
        "status": "confirmed",
        "items": [{"productId": "P1", "qty": quantity, "price": 2.0}],
    }


def test_dummy_generator_targets_evaluation_path_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.syspath_prepend(str(config.SCRIPTS))
    script_path = config.SCRIPTS / "01_generate_dummy_data.py"
    spec = importlib.util.spec_from_file_location("dummy_generator", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert module.OUTPUT == config.ROOT / "data" / "evaluation" / "dummy_orders.csv"
    assert module.OUTPUT != config.RAW_ORDERS_CSV


def test_a_refused_read_fails_the_run_and_writes_nothing(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    output = tmp_path / "operational_forecasts.json"
    runs = tmp_path / "forecast_training_runs.json"
    monkeypatch.setattr(config, "OPERATIONAL_FORECASTS_JSON", output)
    monkeypatch.setattr(config, "TRAINING_RUNS_JSON", runs)
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)

    def refused(collection: str, **_: object) -> list[dict[str, object]]:
        raise firestore_reader.FirestoreReadError(
            "Firestore refused the read of " + collection + " (HTTP 403)."
        )

    monkeypatch.setattr(pipeline_runner.firestore_reader, "list_documents", refused)

    result = pipeline_runner.run_forecast(triggered_by="test", token="t")

    assert result["status"] == "failed"
    assert result["reason"] == "input_unavailable"
    assert "refused" in result["error"]
    assert not output.exists()
    assert not runs.exists()


def test_a_run_writes_the_operational_rows_and_a_run_record(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    output = tmp_path / "operational_forecasts.json"
    runs = tmp_path / "forecast_training_runs.json"
    monkeypatch.setattr(config, "OPERATIONAL_FORECASTS_JSON", output)
    monkeypatch.setattr(config, "TRAINING_RUNS_JSON", runs)
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)
    moment = datetime(2026, 9, 18, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(pipeline_runner, "_now", lambda: moment)

    orders = [
        _order("O1", "2026-09-08", 9),
        _order("O2", "2026-09-01", 7),
        _order("O3", "2026-08-25", 5),
    ]
    documents: dict[str, list[dict[str, object]]] = {
        "products": [{"productId": "P1", "productName": "Alpha", "unitPrice": 2.0}],
        "orders": orders,
        "retailers": [{"retailerId": "R1", "retailerName": "Shop"}],
        "users": [],
    }
    monkeypatch.setattr(
        pipeline_runner.firestore_reader,
        "list_documents",
        lambda collection, **_: documents[collection],
    )
    monkeypatch.setattr(
        pipeline_runner.firestore_reader, "get_document", lambda *a, **k: None
    )

    result = pipeline_runner.run_forecast(triggered_by="test", token="t")

    assert result["status"] == "completed"
    assert result["productCount"] == 1
    assert result["forecastedProducts"] == 1
    assert result["insufficientHistoryProducts"] == 0
    assert result["periodStart"] == "2026-09-14"
    assert result["dataCutoff"] == "2026-09-13"
    assert result["forecastContractVersion"].startswith("operational-forecast/")
    assert result["inputCounts"] == {
        "products": 1,
        "orders": 3,
        "retailers": 1,
        "users": 0,
    }

    written = json.loads(output.read_text(encoding="utf-8"))
    assert written["rowCount"] == 1
    assert written["rows"][0]["productId"] == "P1"
    assert written["rows"][0]["status"] == "ok"
    assert written["rows"][0]["point"] is not None

    history = json.loads(runs.read_text(encoding="utf-8"))
    assert history[0]["runId"] == result["runId"]


def test_evaluation_processed_data_defaults_to_isolated_forecast_outputs(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.syspath_prepend(str(config.SCRIPTS))
    script_path = config.SCRIPTS / "03_train_forecast_model.py"
    spec = importlib.util.spec_from_file_location("train_forecast_model", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    production_processed = tmp_path / "production-processed"
    production_outputs = tmp_path / "production-outputs"
    evaluation_processed = tmp_path / "evaluation-processed"
    evaluation_outputs = tmp_path / "evaluation-outputs"
    module.PROCESSED = production_processed
    module.OUTPUTS = production_outputs
    module.EVALUATION_OUTPUTS = evaluation_outputs

    resolved_processed, resolved_outputs = module._pipeline_paths(
        evaluation_processed,
        None,
    )
    assert resolved_processed == evaluation_processed
    assert resolved_outputs == evaluation_outputs

    with pytest.raises(ValueError, match="separate --output-dir"):
        module._pipeline_paths(evaluation_processed, production_outputs)

    resolved_processed, resolved_outputs = module._pipeline_paths(
        production_processed,
        None,
    )
    assert resolved_processed == production_processed
    assert resolved_outputs == production_outputs


class _FakeFirestore(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, documents: list[dict], page_size: int) -> None:
        super().__init__(("127.0.0.1", 0), _FakeFirestoreHandler)
        self.documents = documents
        self.page_size = page_size
        self.connections = 0
        self.requests: list[dict] = []
        self.bytes_served = 0
        self.forced_status = 0
        self.drop_after_first_page = False

    def get_request(self):
        accepted = super().get_request()
        self.connections += 1
        return accepted


class _FakeFirestoreHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args: object) -> None:
        return

    def do_GET(self) -> None:
        server: _FakeFirestore = self.server
        query = parse_qs(urlsplit(self.path).query)
        server.requests.append(query)
        if server.forced_status:
            body = b"{}"
            self.send_response(server.forced_status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        start = int((query.get("pageToken") or ["0"])[0])
        mask = query.get("mask.fieldPaths")
        page = server.documents[start : start + server.page_size]
        documents = [
            {
                "name": "projects/p/databases/(default)/documents/orders/" + d["id"],
                "fields": {
                    k: v for k, v in d["fields"].items() if mask is None or k in mask
                },
            }
            for d in page
        ]
        payload: dict = {"documents": documents}
        if start + server.page_size < len(server.documents):
            payload["nextPageToken"] = str(start + server.page_size)
        body = json.dumps(payload).encode()
        server.bytes_served += len(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        if server.drop_after_first_page and len(server.requests) == 1:
            self.close_connection = True


def _fake_documents(count: int) -> list[dict]:
    return [
        {
            "id": "o" + str(n),
            "fields": {
                "status": {"stringValue": "confirmed"},
                "note": {"stringValue": "x" * 400},
            },
        }
        for n in range(count)
    ]


@pytest.fixture
def firestore_server(monkeypatch: pytest.MonkeyPatch):
    servers: list[_FakeFirestore] = []

    def start(documents: list[dict], page_size: int) -> _FakeFirestore:
        server = _FakeFirestore(documents, page_size)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        monkeypatch.setenv(
            "FIRESTORE_EMULATOR_HOST", "127.0.0.1:" + str(server.server_address[1])
        )
        servers.append(server)
        return server

    yield start
    for server in servers:
        server.shutdown()
        server.server_close()


def test_a_paged_read_reuses_one_connection(firestore_server) -> None:
    server = firestore_server(_fake_documents(5), page_size=2)
    rows = firestore_reader.list_documents("orders", token="t")
    assert [row["docId"] for row in rows] == ["o0", "o1", "o2", "o3", "o4"]
    assert len(server.requests) == 3
    assert server.connections == 1


def test_a_redirect_is_refused_not_read_as_an_empty_collection(firestore_server) -> None:
    server = firestore_server(_fake_documents(2), page_size=2)
    server.forced_status = 302
    with pytest.raises(firestore_reader.FirestoreReadError, match="HTTP 302"):
        firestore_reader.list_documents("orders", token="t")


def test_a_keep_alive_socket_closed_between_pages_is_reopened_once(firestore_server) -> None:
    server = firestore_server(_fake_documents(5), page_size=2)
    server.drop_after_first_page = True
    rows = firestore_reader.list_documents("orders", token="t")
    assert [row["docId"] for row in rows] == ["o0", "o1", "o2", "o3", "o4"]
    assert server.connections == 2


def test_a_capped_read_with_more_pages_is_refused_not_truncated(firestore_server) -> None:
    firestore_server(_fake_documents(4), page_size=2)
    with pytest.raises(firestore_reader.FirestoreReadError, match="incomplete"):
        firestore_reader.list_documents("orders", token="t", max_documents=2)


def test_a_read_exactly_at_the_cap_with_no_more_pages_succeeds(firestore_server) -> None:
    firestore_server(_fake_documents(2), page_size=2)
    rows = firestore_reader.list_documents("orders", token="t", max_documents=2)
    assert [row["docId"] for row in rows] == ["o0", "o1"]


def test_input_collections_are_read_with_a_field_mask(firestore_server) -> None:
    server = firestore_server(_fake_documents(3), page_size=3)
    rows = firestore_reader.list_documents("orders", token="t")
    assert server.requests[0]["mask.fieldPaths"] == sorted(
        firestore_reader.INPUT_FIELD_MASKS["orders"]
    )
    assert all("note" not in row for row in rows)
    assert all(row["status"] == "confirmed" for row in rows)


def test_a_collection_without_a_mask_is_read_whole(firestore_server) -> None:
    server = firestore_server(_fake_documents(1), page_size=1)
    rows = firestore_reader.list_documents("system_settings", token="t")
    assert "mask.fieldPaths" not in server.requests[0]
    assert rows[0]["note"] == "x" * 400


def test_the_field_mask_covers_every_field_the_forecast_reads(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import builtins
    from datetime import date

    from forecasting.ai_service import normalization

    class Recorder(dict):
        def __init__(self, seen: set, data: dict) -> None:
            super().__init__(data)
            self.seen = seen

        def get(self, key, default=None):
            self.seen.add(key)
            return super().get(key, default)

        def __getitem__(self, key):
            self.seen.add(key)
            return super().__getitem__(key)

    def recording_dict(row=()):
        if isinstance(row, Recorder):
            return Recorder(row.seen, row)
        return builtins.dict(row)

    monkeypatch.setattr(normalization, "dict", recording_dict, raising=False)
    seen: dict[str, set] = {name: set() for name in firestore_reader.INPUT_FIELD_MASKS}

    def rows(collection: str, *documents: dict) -> list[Recorder]:
        return [Recorder(seen[collection], document) for document in documents]

    normalization.normalize_firestore_inputs(
        orders=rows(
            "orders",
            {
                "docId": "o1",
                "outlet": "x",
                "submittedAt": "2026-10-01T02:00:00+00:00",
                "commercialSchemaVersion": 1,
                "commercialLines": ["p1~name~1~100"],
            },
            {
                "docId": "o2",
                "retailerId": "unlisted",
                "submittedAt": "2026-10-01T02:00:00+00:00",
                "items": [{"productId": "p1", "qty": 1}],
            },
        ),
        products=rows("products", {"docId": "p1"}),
        retailers=rows(
            "retailers",
            {"docId": "r1", "name": "x"},
            {"docId": "r2", "salesmanUid": "u1"},
        ),
        users=rows("users", {"docId": "u1"}),
        as_of=date(2026, 10, 20),
    )
    for collection, fields in firestore_reader.INPUT_FIELD_MASKS.items():
        assert seen[collection] - {"docId"} <= set(fields), (
            collection,
            seen[collection] - {"docId"} - set(fields),
        )

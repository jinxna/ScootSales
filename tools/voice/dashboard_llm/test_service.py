import json
import threading
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

from tools.voice.dashboard_llm import service

PAGES = [
    {"key": "all_orders", "label": "All Orders", "aliases": ["orders"]},
    {"key": "reports", "label": "Reports", "aliases": []},
]


def out(value: str) -> str:
    return f"{service.PREFILL}{value}<escape>}}"


def test_model_value_maps_only_to_requested_pages():
    assert service.parse_page(out("reports"), PAGES) == "reports"
    assert service.parse_page(out("Orders"), PAGES) == "all_orders"
    assert service.parse_page(out("system_health"), PAGES) is None
    assert service.parse_page(out("no_match"), PAGES) is None
    assert service.parse_page("sure, opening it", PAGES) is None
    assert service.parse_page(out("reports") + out("all_orders"), PAGES) is None


def test_ambiguous_alias_is_rejected():
    pages = PAGES + [{"key": "x", "label": "X", "aliases": ["orders"]}]
    assert service.parse_page(out("orders"), pages) is None


def test_threshold_and_validation():
    body = {"text": "show orders", "pages": PAGES}
    assert service.propose(lambda t, p: (out("reports"), 0.9995), body, 0.999)["pageKey"] == "reports"
    low = service.propose(lambda t, p: (out("reports"), 0.9), body, 0.999)
    assert low["pageKey"] is None and low["confidence"] == 0.0
    for bad in (
        {"text": "x" * 201, "pages": PAGES},
        {"text": "hi", "pages": []},
        {"text": "hi", "pages": [{"key": "Bad Key", "label": "l"}]},
        {"text": "hi", "pages": [{"key": "a", "label": "<escape>"}]},
        {"text": "  ", "pages": PAGES},
    ):
        with pytest.raises(service.RequestError):
            service.propose(lambda t, p: ("", 1.0), bad, 0.5)


def test_origin_rules():
    assert service.origin_allowed("http://localhost:5000")
    assert service.origin_allowed("http://127.0.0.1")
    for origin in ("https://evil.example", "http://localhost.evil.example", "http://localhost:5000@evil.example", None):
        assert not service.origin_allowed(origin)


def test_http_cors_and_binding():
    handler = service.make_handler(lambda t, p: (out("reports"), 1.0), 0.5)
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"

    def post(origin):
        req = urllib.request.Request(
            base + "/propose",
            json.dumps({"text": "reports", "pages": PAGES}).encode(),
            {"Content-Type": "application/json", "Origin": origin},
        )
        try:
            return urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:
            return error

    ok = post("http://localhost:1234")
    assert ok.status == 200 and ok.headers["Access-Control-Allow-Origin"] == "http://localhost:1234"
    assert json.load(ok)["pageKey"] == "reports"
    assert post("https://evil.example").status == 403
    server.shutdown()


def test_adapter_absent_falls_back_to_base(tmp_path):
    assert service.resolve_adapter_dir(str(tmp_path / "missing")) is None
    assert service.resolve_adapter_dir(str(tmp_path)) is None
    (tmp_path / "adapter_config.json").write_text("{}")
    assert service.resolve_adapter_dir(str(tmp_path)) == str(tmp_path)
    assert service.GemmaGenerator("x").adapter_dir is None


def test_threshold_depends_on_the_adapter_unless_overridden(monkeypatch):
    monkeypatch.delenv("DASHBOARD_VOICE_THRESHOLD", raising=False)
    assert service.default_threshold(True) == 0.98
    assert service.default_threshold(False) == 0.999
    assert service.default_threshold(False, "0.9") == 0.9
    monkeypatch.setenv("DASHBOARD_VOICE_THRESHOLD", "0.95")
    assert service.default_threshold(True) == 0.95


def test_health_reports_adapter_and_default_threshold():
    for adapter in (False, True):
        server = ThreadingHTTPServer(("127.0.0.1", 0), service.make_handler(lambda t, p: ("", 0.0), service.THRESHOLD, adapter))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        health = json.load(urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}/health"))
        server.shutdown()
        assert health == {"status": "ok", "threshold": service.THRESHOLD, "adapter": adapter}


def test_fresh_eval_targets_exist_in_their_catalogue():
    data = json.loads(
        Path(__file__)
        .with_name("fresh_phrases.json")
        .read_text(encoding="utf-8")
    )
    for case in data["cases"]:
        target = case.get("expect")
        if target in (None, "no_match"):
            continue
        keys = {page["key"] for page in data["catalogues"][case["catalogue"]]}
        assert target in keys, f"{case['catalogue']} does not offer expected page {target!r}"

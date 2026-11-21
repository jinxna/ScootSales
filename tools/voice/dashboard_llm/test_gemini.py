import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from tools.voice.dashboard_llm import copilot_model, evaluate_gemini as eg, gemini_client as gc

REQUEST = {"text": "park number two for later", "pages": [], "actions": ["daily_briefing", "set_item_status"]}


@pytest.fixture
def fake(monkeypatch):
    monkeypatch.setattr(gc.time, "sleep", lambda s: None)
    seen = {"requests": [], "replies": []}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            seen["requests"].append(
                {"path": self.path, "key": self.headers.get("x-goog-api-key"),
                 "body": json.loads(self.rfile.read(int(self.headers["Content-Length"])))}
            )
            status, payload = seen["replies"].pop(0)
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            return

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield seen, f"http://127.0.0.1:{httpd.server_port}"
    httpd.shutdown()


def reply(name, args):
    return (200, {"candidates": [{"content": {"parts": [{"functionCall": {"name": name, "args": args}}]}}]})


def generator(url):
    return gc.GeminiGenerator("secret-key", base_url=url, seconds_between_calls=0)


def test_request_is_forced_and_carries_enums_and_the_key_only_in_a_header(fake):
    seen, url = fake
    seen["replies"] = [reply("set_item_status", {"position": 2.0, "status": "in_review"})]
    result = copilot_model.interpret(generator(url), REQUEST, 0.0)
    assert result["call"] == {"name": "set_item_status", "args": {"position": 2, "status": "in_review"}}
    request = seen["requests"][0]
    assert request["body"]["generationConfig"]["maxOutputTokens"] == gc.MAX_OUTPUT_TOKENS
    assert request["body"]["generationConfig"]["thinkingConfig"] == {"thinkingLevel": "minimal"}
    assert request["key"] == "secret-key" and "secret-key" not in request["path"]
    assert request["body"]["toolConfig"]["functionCallingConfig"]["mode"] == "ANY"
    declarations = request["body"]["tools"][0]["functionDeclarations"]
    status = next(d for d in declarations if d["name"] == "set_item_status")
    assert status["parameters"]["properties"]["status"]["enum"] == ["in_review", "resolved", "ignored"]
    assert "parameters" not in next(d for d in declarations if d["name"] == "no_match")


def test_rate_limit_is_retried_and_a_text_only_reply_is_a_decline(fake):
    seen, url = fake
    seen["replies"] = [(429, {}), (200, {"candidates": [{"content": {"parts": [{"text": "sorry"}]}}]})]
    assert copilot_model.interpret(generator(url), REQUEST, 0.0)["call"] is None
    assert len(seen["requests"]) == 2


def test_a_reply_with_two_function_calls_is_no_call_not_the_first_one(fake):
    seen, url = fake
    parts = [{"functionCall": {"name": "set_item_status", "args": {"position": 2, "status": "resolved"}}},
             {"functionCall": {"name": "daily_briefing", "args": {}}}]
    seen["replies"] = [(200, {"candidates": [{"content": {"parts": parts}}]})]
    assert copilot_model.interpret(generator(url), REQUEST, 0.0)["call"] is None


@pytest.mark.parametrize("with_call", [False, True])
def test_max_tokens_finish_logs_an_error_without_changing_call_semantics(fake, caplog, with_call):
    seen, url = fake
    payload = reply("daily_briefing", {})[1] if with_call else {"candidates": [{"content": {"parts": []}}]}
    payload["candidates"][0]["finishReason"] = "MAX_TOKENS"
    payload["candidates"][0]["finishMessage"] = "private response detail"
    seen["replies"] = [(200, payload)]
    result = copilot_model.interpret(generator(url), REQUEST, 0.0)
    assert result["call"] == ({"name": "daily_briefing", "args": {}} if with_call else None)
    errors = [record for record in caplog.records if record.levelname == "ERROR"]
    assert len(errors) == 1
    assert "MAX_TOKENS" in errors[0].getMessage()
    assert all(value not in caplog.text for value in ("secret-key", REQUEST["text"], "private response detail"))


@pytest.mark.parametrize("name,args", [
    ("drop_database", {}), ("set_item_status", {"status": "deleted"}), ("set_item_status", {"status": "ignored", "extra": 1}),
    ("search_orders", {"retailer": "x"}),
])
def test_unknown_names_bad_values_and_unoffered_actions_are_rejected(fake, name, args):
    seen, url = fake
    seen["replies"] = [reply(name, args)]
    assert copilot_model.interpret(generator(url), REQUEST, 0.0)["call"] is None


def test_missing_key_stops_with_a_clear_message(monkeypatch, tmp_path):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setattr(eg, "REPO_ROOT", tmp_path)
    with pytest.raises(SystemExit, match="GEMINI_API_KEY"):
        eg.read_api_key()

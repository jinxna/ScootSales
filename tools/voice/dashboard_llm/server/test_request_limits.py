import concurrent.futures
import http.client
import json
import socket
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from tools.voice.dashboard_llm.server import app
from tools.voice.dashboard_llm.server.test_server import BODY, GOOD


@contextmanager
def hosted(generate=lambda *_: (GOOD, 1.0), *, ready=True, **limits):
    state = app.State(lambda _: {"sub": "test-user"}, generate, 0.98, set(), **limits)
    if ready:
        state.ready.set()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), app.make_handler(state))
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield state, httpd.server_port
    finally:
        httpd.shutdown()
        httpd.server_close()
        if hasattr(state, "close"):
            state.close()


def request(port, method="POST", path="/v1/interpret", *, token="test-token"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request(method, path, body=json.dumps(BODY) if method == "POST" else None,
                           headers={"Authorization": f"Bearer {token}"} if token else {})
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


def test_unready_health_is_503_and_recovers():
    with hosted(ready=False) as (state, port):
        assert request(port, "GET", "/health") == (503, {"ready": False})
        state.ready.set()
        assert request(port, "GET", "/health") == (200, {"ready": True})


@pytest.mark.parametrize('failure', ['project', 'blank_project', 'threshold', 'invalid_threshold',
                                     'threshold_range', 'invalid_limits', 'no_provider'])
def test_invalid_startup_configuration_serves_only_unready_responses(monkeypatch, failure):
    monkeypatch.setenv('FIREBASE_PROJECT_ID', 'demo-unready')
    monkeypatch.setenv('COPILOT_THRESHOLD', '0.98')
    monkeypatch.delenv('GEMINI_API_KEY', raising=False)
    if failure == 'project':
        monkeypatch.delenv('FIREBASE_PROJECT_ID')
    elif failure == 'blank_project':
        monkeypatch.setenv('FIREBASE_PROJECT_ID', ' ')
    elif failure == 'threshold':
        monkeypatch.delenv('COPILOT_THRESHOLD')
    elif failure == 'invalid_threshold':
        monkeypatch.setenv('COPILOT_THRESHOLD', 'invalid')
    elif failure == 'threshold_range':
        monkeypatch.setenv('COPILOT_THRESHOLD', 'NaN')
    elif failure == 'invalid_limits':
        monkeypatch.setenv('COPILOT_BODY_TIMEOUT', '0')
    else:
        monkeypatch.setenv('COPILOT_MODEL_ENABLED', '0')

    def unexpected(*_, **kwargs):
        raise AssertionError('Unavailable configuration must not initialize dependencies')

    monkeypatch.setattr(app, 'firebase_verifier', unexpected)
    monkeypatch.setattr(app.model, 'CopilotGenerator', unexpected)
    checked = []

    class Server:
        def __init__(self, address, handler):
            self.handler = handler

        def serve_forever(self):
            with ThreadingHTTPServer(('127.0.0.1', 0), self.handler) as server:
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    assert request(server.server_port, 'GET', '/health') == (503, {'ready': False})
                    assert request(server.server_port)[0] == 503
                    checked.append(True)
                finally:
                    server.shutdown()

    monkeypatch.setattr(app, 'Server', Server)
    app.main()
    assert checked


@pytest.mark.parametrize("trickle", [False, True])
def test_body_deadline_is_absolute_even_when_bytes_keep_arriving(trickle):
    with hosted(body_timeout=0.15, request_timeout=1) as (_, port):
        with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
            client.sendall(b"POST /v1/interpret HTTP/1.0\r\nContent-Length: 100\r\n\r\n{")
            finished = threading.Event()
            def drip():
                while not finished.wait(0.04):
                    try:
                        client.sendall(b" ")
                    except OSError:
                        return
            writer = threading.Thread(target=drip, daemon=True)
            started = time.monotonic()
            if trickle:
                writer.start()
            try:
                reply = client.recv(4096)
            finally:
                finished.set()
                if trickle:
                    writer.join()
            assert b" 408 " in reply
            assert time.monotonic() - started < 0.8


@pytest.mark.parametrize("stage", ["authentication", "access"])
def test_total_deadline_covers_authentication_and_access(stage):
    release = threading.Event()

    class Upstream(BaseHTTPRequestHandler):
        def do_GET(self):
            release.wait(1)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Upstream) as upstream:
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        transport = app.CertificateRequest()
        url = f"http://127.0.0.1:{upstream.server_port}/certificates"

        def slow_check(*_):
            transport(url)
            return {"sub": "test-user"} if stage == "authentication" else True

        try:
            with hosted(request_timeout=0.15) as (state, port):
                if stage == "authentication":
                    state.verify = slow_check
                else:
                    state.access = slow_check
                started = time.monotonic()
                assert request(port) == (504, {"error": "request deadline exceeded"})
                assert time.monotonic() - started < 0.8
                assert state.pending_count == 0
                assert not state._worker_started
        finally:
            release.set()
            upstream.shutdown()


def test_unauthenticated_flood_does_not_starve_an_authorized_http_request():
    release = threading.Event()
    denied = []
    model_calls = []

    def verify(token):
        if token == "test-token":
            return {"sub": "test-user"}
        denied.append(token)
        release.wait(2)
        raise ValueError("invalid token")

    with hosted(lambda *_: (model_calls.append(True) or GOOD, 1.0), max_pending=2) as (state, port):
        state.verify = verify
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as clients:
            flood = [clients.submit(request, port, token=f"forged-{i}") for i in range(3)]
            try:
                end = time.monotonic() + 1
                while len(denied) < 3 and state.pending_count < 2 and time.monotonic() < end:
                    time.sleep(0.005)
                assert len(denied) == 3 or state.pending_count == 2
                assert request(port)[0] == 200
                assert state.pending_count == 0
                assert model_calls == [True]
            finally:
                release.set()
            assert [job.result()[0] for job in flood] == [401] * 3


@pytest.mark.parametrize("denial,status", [("missing", 401), ("invalid", 401), ("access", 403),
                                          ("lookup_error", 503), ("rate", 429)])
def test_denied_requests_bypass_a_saturated_authorized_inference_queue(denial, status):
    entered, release = threading.Event(), threading.Event()
    calls = []

    def generate(*_):
        calls.append(True)
        entered.set()
        release.wait(2)
        return GOOD, 1.0

    def verify(token):
        if token == "invalid":
            raise ValueError("invalid token")
        return {"sub": token}

    def access(token, uid):
        if uid == "lookup_error":
            raise RuntimeError("lookup failed")
        return uid != "access"

    with hosted(generate, max_pending=1, access=access) as (state, port):
        state.verify = verify
        for _ in range(app.RATE_LIMIT):
            assert state.allow("rate")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as clients:
            first = clients.submit(request, port)
            assert entered.wait(1)
            second = clients.submit(request, port)
            try:
                end = time.monotonic() + 1
                while state.pending_count != 1 and time.monotonic() < end:
                    time.sleep(0.005)
                assert state.pending_count == 1
                response = request(port, token=None if denial == "missing" else denial)
                assert response[0] == status
                if denial == "lookup_error":
                    assert response[1] == {"error": "could not check the account"}
                assert state.pending_count == 1
                assert calls == [True]
            finally:
                release.set()
            assert first.result()[0] == second.result()[0] == 200


def test_canceled_inference_future_returns_504_and_worker_recovers(monkeypatch):
    calls = []
    original = app.Future

    def canceled():
        future = original()
        future.cancel()
        return future

    with hosted(lambda *_: (calls.append(True) or GOOD, 1.0)) as (state, port):
        with monkeypatch.context() as patch:
            patch.setattr(app, "Future", canceled)
            assert request(port) == (504, {"error": "request deadline exceeded"})
        assert request(port)[0] == 200
        assert calls == [True]


def test_bounded_queue_never_runs_expired_jobs_or_overlaps_a_timed_out_model():
    entered, release = threading.Event(), threading.Event()
    calls = []

    def blocked(text, *_):
        calls.append(text)
        entered.set()
        release.wait(3)
        return GOOD, 1.0

    with hosted(blocked, request_timeout=0.3, max_pending=1) as (state, port):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as clients:
            first = clients.submit(request, port)
            assert entered.wait(1)
            second = clients.submit(request, port)
            deadline = time.monotonic() + 1
            while state.pending_count != 1 and time.monotonic() < deadline:
                time.sleep(0.005)
            assert state.pending_count == 1
            assert request(port)[0] == 503
            assert first.result()[0] == 504
            assert second.result()[0] == 504
            assert request(port)[0] == 503
            assert len(calls) == 1
            release.set()
        deadline = time.monotonic() + 1
        while state.pending_count and time.monotonic() < deadline:
            time.sleep(0.005)
        assert request(port)[0] == 200
        assert len(calls) == 2


@pytest.mark.parametrize("settings", [{"request_timeout": 0}, {"body_timeout": float("nan")}, {"max_pending": 0}])
def test_invalid_limits_do_not_start(settings):
    with pytest.raises(ValueError):
        app.State(lambda _: {}, lambda *_: (GOOD, 1), 0.98, set(), **settings)

import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from tools.voice.dashboard_llm.gemini_client import GeminiGenerator
from tools.voice.dashboard_llm.server.app import firestore_access_check


@contextmanager
def trickling(mode):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send_slow(self):
            try:
                payload = b'{}' + b' ' * 48
                header = b'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: 50\r\n\r\n'
                if mode == 'headers':
                    for byte in header:
                        self.connection.sendall(bytes([byte]))
                        time.sleep(0.02)
                    self.connection.sendall(payload)
                else:
                    self.connection.sendall(header)
                    for byte in payload:
                        self.connection.sendall(bytes([byte]))
                        time.sleep(0.02)
            except OSError:
                pass

        do_GET = do_POST = send_slow

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield f'http://127.0.0.1:{server.server_port}'
    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize('mode', ['headers', 'body'])
def test_provider_absolute_deadline_interrupts_trickling_upstream(mode):
    with trickling(mode) as url:
        generator = GeminiGenerator('synthetic-token', base_url=url, seconds_between_calls=0, retries=0, timeout=2)
        started = time.monotonic()
        with pytest.raises(TimeoutError):
            generator('hello', [], ['daily_briefing'], deadline=started + 0.15)
        assert time.monotonic() - started < 0.8


def test_account_read_has_an_absolute_timeout():
    from tools.voice.dashboard_llm import http_deadline
    with trickling('body') as url:
        token = http_deadline.REQUEST_DEADLINE.set(time.monotonic() + 0.15)
        try:
            started = time.monotonic()
            with pytest.raises(TimeoutError):
                firestore_access_check('demo-deadline', base_url=url)('synthetic-token', 'uid')
            assert time.monotonic() - started < 0.8
        finally:
            http_deadline.REQUEST_DEADLINE.reset(token)


def test_certificate_cache_never_serves_expired_data_after_fetch_failure(monkeypatch):
    from tools.voice.dashboard_llm import http_deadline
    from tools.voice.dashboard_llm.server import app
    now = [0.0]
    seen = []

    def fetch(request, **kwargs):
        seen.append(request.full_url)
        if len(seen) > 1:
            raise TimeoutError('certificate fetch expired')
        return http_deadline.Reply(200, b'{"key":"certificate"}', {'Cache-Control': 'max-age=10', 'Age': '2'})

    monkeypatch.setattr(http_deadline, 'request_bytes', fetch)
    transport = app.CertificateRequest(clock=lambda: now[0])
    url = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com'
    assert transport(url).data == b'{"key":"certificate"}'
    now[0] = 7
    assert transport(url).status == 200
    assert len(seen) == 1
    now[0] = 8
    with pytest.raises(TimeoutError):
        transport(url)
    with pytest.raises(TimeoutError):
        transport(url)
    assert len(seen) == 3


def test_upstream_timeout_releases_worker_for_next_request():
    from tools.voice.dashboard_llm.server import app
    import json
    with trickling('headers') as url:
        provider = GeminiGenerator('synthetic-token', base_url=url, seconds_between_calls=0, retries=0, timeout=2)
        state = app.State(lambda _: {'sub': 'u'}, provider, 0, set())
        state.ready.set()
        body = json.dumps({'text': 'hello', 'pages': [], 'actions': ['daily_briefing']}).encode()
        try:
            with pytest.raises(app.Rejected) as error:
                state.run_request('Bearer test', body, time.monotonic() + 0.15)
            assert error.value.status == 504
            state.generate = lambda *_: ('no_match{}<end_call>', 1.0)
            assert state.run_request('Bearer test', body, time.monotonic() + 1)['call'] is None
        finally:
            state.close()


def test_expired_fallback_does_not_become_a_successful_decline():
    from tools.voice.dashboard_llm.server import app

    def fallback(*_):
        time.sleep(0.03)
        raise TimeoutError('provider deadline')

    state = app.State(lambda _: {'sub': 'u'}, lambda *_: ('', 0), 1, set(), fallback=fallback)
    with pytest.raises(app.Rejected) as error:
        app.decide(state, {'text': 'hello', 'pages': [], 'actions': ['daily_briefing']}, deadline=time.monotonic() + 0.01)
    assert error.value.status == 504


def test_certificate_cache_accounts_for_server_date_and_download_time(monkeypatch):
    from tools.voice.dashboard_llm import http_deadline
    from tools.voice.dashboard_llm.server import app
    from email.utils import formatdate
    now = [0.0]
    seen = []

    def fetch(*_, **kwargs):
        seen.append(True)
        now[0] += 2
        return http_deadline.Reply(200, b'{}', {'Cache-Control': 'max-age=10', 'Date': formatdate(991, usegmt=True)})

    monkeypatch.setattr(http_deadline, 'request_bytes', fetch)
    monkeypatch.setattr(app.time, 'time', lambda: 1000)
    transport = app.CertificateRequest(clock=lambda: now[0])
    transport('https://example.invalid/certs')
    now[0] += 1
    transport('https://example.invalid/certs')
    assert len(seen) == 2


def test_release_bundle_can_import_server_with_deadline_helper(tmp_path):
    from tools.voice.dashboard_llm.server import build_bundle
    import subprocess
    import sys
    model = tmp_path / 'model'
    adapter = tmp_path / 'adapter'
    model.mkdir()
    adapter.mkdir()
    (model / 'config.json').write_text('{}')
    for name in build_bundle.ADAPTER_FILES:
        (adapter / name).write_text('{}')
    output = tmp_path / 'bundle'
    build_bundle.main(['--model-dir', str(model), '--adapter-dir', str(adapter), '--out', str(output)])
    result = subprocess.run([sys.executable, '-c', 'from tools.voice.dashboard_llm.server import app'],
                            cwd=output, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr

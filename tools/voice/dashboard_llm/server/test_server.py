import json
import socket
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from tools.voice.dashboard_llm import copilot_schema as schema
from tools.voice.dashboard_llm import http_deadline
from tools.voice.dashboard_llm.server import app

ORIGIN = "https://dashboard.example"
GOOD = schema.serialize_call({"name": "search_orders", "args": {"salesperson": "Ahmad", "period": "today"}})
BODY = {"text": "show Ahmad's orders today", "pages": [], "actions": ["search_orders"]}


def verifier(token):
    if token != "good-token":
        raise ValueError("bad token")
    return {"sub": "uid-1"}


@pytest.fixture
def server():
    box = {}

    def make(generate=lambda t, p, a: (GOOD, 0.99), ready=True, fallback=None, access=None, gemini_daily_limit=500,
             gemini_daily_limit_salesman=200, clock=time.monotonic, verify=verifier):
        state = app.State(verify, generate, 0.98, {ORIGIN}, clock=clock, fallback=fallback, access=access,
                          gemini_daily_limit=gemini_daily_limit, gemini_daily_limit_salesman=gemini_daily_limit_salesman)
        if ready:
            state.ready.set()
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), app.make_handler(state))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        box["httpd"] = httpd
        return state, f"http://127.0.0.1:{httpd.server_port}"

    yield make
    if "httpd" in box:
        box["httpd"].shutdown()


def call(url, path="/v1/interpret", body=BODY, token="good-token", origin=None, method=None, raw=None):
    data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
    request = urllib.request.Request(url + path, data=data, method=method)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    if origin:
        request.add_header("Origin", origin)
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.loads(response.read() or b"{}"), response.headers
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}"), error.headers


def test_signed_in_user_gets_a_call(server):
    _, url = server()
    status, body, headers = call(url, origin=ORIGIN)
    assert status == 200
    assert body["call"] == {"name": "search_orders", "args": {"period": "today", "salesperson": "Ahmad"}}
    assert headers["Access-Control-Allow-Origin"] == ORIGIN
    assert call(url, path="/health", body=None, token=None)[:2] == (200, {"ready": True})


@pytest.mark.parametrize("token", [None, "forged", "Bearer x"])
def test_missing_or_bad_token_is_401_and_never_reaches_the_model(server, token):
    calls = []
    _, url = server(lambda t, p, a: calls.append(t) or (GOOD, 1.0))
    assert call(url, token=token)[0] == 401
    assert calls == []


def test_rate_limit_is_per_user(server):
    state, url = server()
    codes = [call(url)[0] for _ in range(app.RATE_LIMIT + 1)]
    assert codes[:-1] == [200] * app.RATE_LIMIT and codes[-1] == 429


def test_rate_limit_map_drops_callers_older_than_the_window():
    now = [0.0]
    state = app.State(lambda token: {"sub": token}, lambda t, p, a: ("", 0.0), 0.98, {ORIGIN}, clock=lambda: now[0])
    for n in range(50):
        state.allow(f"uid-{n}")
    now[0] += 3600
    state.allow("uid-last")
    assert list(state._hits) == ["uid-last"]


def test_model_still_loading_is_503_but_health_works(server):
    _, url = server(ready=False)
    assert call(url)[0] == 503
    assert call(url, path="/health", body=None, token=None)[1] == {"ready": False}


def test_requests_before_the_model_is_ready_use_no_rate_limit_slot(server):
    state, url = server(ready=False)
    assert [call(url)[0] for _ in range(app.RATE_LIMIT + 1)] == [503] * (app.RATE_LIMIT + 1)
    state.ready.set()
    assert call(url)[0] == 200


@pytest.mark.parametrize("raw", [b"not json", b"[]", b'{"text": ""}', b'{"text": "x", "actions": ["drop_database"]}'])
def test_bad_bodies_are_400(server, raw):
    _, url = server()
    assert call(url, raw=raw)[0] == 400


def test_oversize_body_is_413(server):
    _, url = server()
    assert call(url, raw=b"x" * (app.MAX_BODY + 1))[0] == 413


def test_other_origins_are_refused_and_preflight_works_for_the_dashboard(server):
    _, url = server()
    assert call(url, origin="https://evil.example")[0] == 403
    assert call(url, path="/v1/interpret", body=None, token=None, origin="https://evil.example", method="OPTIONS")[0] == 403
    status, _, headers = call(url, body=None, token=None, origin=ORIGIN, method="OPTIONS")
    assert status == 204 and headers["Access-Control-Allow-Origin"] == ORIGIN


def test_unknown_path_is_404_and_a_crash_leaks_nothing(server):
    def boom(t, p, a):
        raise RuntimeError("secret internal detail")

    _, url = server(boom)
    assert call(url, path="/nope", body=None)[0] == 404
    status, body, _ = call(url)
    assert status == 500 and body == {"error": "internal error"}


def counting(output):
    calls = []

    def generate(text, pages, actions):
        calls.append(text)
        return output

    generate.calls = calls
    return generate


def test_confident_answers_and_confident_declines_never_reach_gemini(server):
    gemini = counting((GOOD, 1.0))
    _, url = server(lambda t, p, a: (GOOD, 0.99), fallback=gemini)
    body = call(url)[1]
    assert body["source"] == "model" and body["call"]["name"] == "search_orders"
    _, url = server(lambda t, p, a: ("no_match{}" + schema.END_CALL, 0.99), fallback=gemini)
    body = call(url)[1]
    assert body["call"] is None and body["source"] == "model"
    assert gemini.calls == []


def test_low_confidence_goes_to_gemini_and_its_answer_is_validated_the_same_way(server):
    gemini = counting((GOOD, 1.0))
    _, url = server(lambda t, p, a: (GOOD, 0.4), fallback=gemini)
    body = call(url)[1]
    assert body["source"] == "gemini" and body["call"]["name"] == "search_orders" and body["confidence"] == 0.0
    assert len(gemini.calls) == 1
    junk = counting(("drop_database{}" + schema.END_CALL, 1.0))
    _, url = server(lambda t, p, a: ("hello", 0.0), fallback=junk)
    assert call(url)[1]["call"] is None


def test_gemini_crash_is_unavailable_and_no_key_means_no_call(server):
    def boom(t, p, a):
        raise RuntimeError("quota exceeded")

    _, url = server(lambda t, p, a: (GOOD, 0.4), fallback=boom)
    status, body, _ = call(url)
    assert status == 200 and body["call"] is None
    assert body["unavailable"] is True and body["source"] == "unavailable"
    _, url = server(lambda t, p, a: (GOOD, 0.4), fallback=None)
    status, body, _ = call(url)
    assert status == 200 and body["call"] is None and body["source"] == "model" and body["unavailable"] is False


def test_only_active_copilot_accounts_may_call_and_the_answer_is_cached(server):
    lookups = []

    def access(token, uid):
        lookups.append(uid)
        return uid == "uid-1"

    _, url = server(access=access)
    assert call(url)[0] == 200 and call(url)[0] == 200
    assert lookups == ["uid-1"]
    _, url = server(access=lambda t, u: False)
    status, body, _ = call(url)
    assert status == 403 and body == {"error": "an active Scout account is required"}


def test_a_revoked_person_loses_copilot_within_a_minute(server):
    now = [0.0]
    active = [True]
    _, url = server(access=lambda t, u: active[0], clock=lambda: now[0])
    assert call(url)[0] == 200
    active[0] = False
    now[0] += 61
    assert call(url)[0] == 403


def test_the_access_cache_does_not_grow_with_every_caller_it_has_seen(server):
    now = [0.0]
    callers = iter(range(10_000))
    current = {"uid": "uid-0"}

    def verify(token):
        return {"sub": current["uid"]}

    state, url = server(access=lambda t, u: True, clock=lambda: now[0], verify=verify)
    for _ in range(50):
        current["uid"] = f"uid-{next(callers)}"
        assert call(url)[0] == 200
    now[0] += 61
    current["uid"] = "uid-last"
    assert call(url)[0] == 200
    assert len(state._access_cache) == 1


def test_a_directory_token_without_a_company_is_refused(server):
    _, url = server(verify=lambda token: {"sub": "uid-1", "scope": ("proj", "db")})
    status, body, _ = call(url)
    assert status == 403 and "company" in body["error"]


@pytest.mark.parametrize("value", ["", "  ", "nan", "inf", "-inf"])
def test_a_blank_or_non_finite_setting_stops_startup_and_names_the_setting(monkeypatch, value):
    monkeypatch.setenv("PLATFORM_PUBLIC_KEYS", "x")
    monkeypatch.setenv("COPILOT_THRESHOLD", "0.98")
    monkeypatch.setenv("COPILOT_BODY_TIMEOUT", value)
    with pytest.raises(ValueError) as stopped:
        app._configured_state()
    assert "COPILOT_BODY_TIMEOUT" in str(stopped.value)
    assert value.strip() == "" or value not in str(stopped.value)


def test_the_certificate_cache_keeps_recent_urls_and_forgets_old_ones(monkeypatch):
    fetched = []

    class Reply:
        status = 200
        headers = {"Cache-Control": "max-age=3600"}

    def fetch(request, *args, **kwargs):
        fetched.append(request.full_url)
        return Reply()

    monkeypatch.setattr(app.http_deadline, "request_bytes", fetch)
    transport = app.CertificateRequest()
    for number in range(30):
        transport(f"https://certs.example/{number}")
    fetched.clear()
    transport("https://certs.example/29")
    assert fetched == []
    transport("https://certs.example/0")
    assert fetched == ["https://certs.example/0"]




def test_a_salesperson_stays_on_the_salesperson_budget_when_another_miss_clears_the_cache(server):
    now = [59.9]
    gemini = counting((GOOD, 1.0))
    holder = {}

    def verify(token):
        return {"sub": token}

    def access(token, uid):
        return "salesman" if uid == "sales" else False

    def generate(text, pages, actions):
        if holder.get("armed"):
            now[0] = 60.1
            call(holder["url"], token="other")
        return GOOD, 0.4

    state, url = server(generate, fallback=gemini, access=access, clock=lambda: now[0], verify=verify,
                        gemini_daily_limit=500, gemini_daily_limit_salesman=0)
    holder["url"] = url
    now[0] = 0.0
    assert call(url, token="sales")[0] == 200
    now[0] = 59.9
    holder["armed"] = True
    status, body, _ = call(url, token="sales")
    assert status == 200 and body["call"] is None and body["unavailable"] is True


def test_startup_names_the_wrong_setting_without_its_value(monkeypatch, capsys):
    monkeypatch.setenv("PLATFORM_PUBLIC_KEYS", "x")
    monkeypatch.setenv("COPILOT_THRESHOLD", "0.98")
    monkeypatch.setenv("COPILOT_BODY_TIMEOUT", "nan")
    monkeypatch.setenv("PORT", "8080")

    class Stop(Exception):
        pass

    def stop(*args, **kwargs):
        raise Stop

    monkeypatch.setattr(app, "Server", stop)
    with pytest.raises(Stop):
        app.main()
    err = capsys.readouterr().err
    assert "COPILOT_BODY_TIMEOUT" in err and "nan" not in err.replace("finite", "")


def test_a_failed_account_lookup_is_503_not_access(server):
    def broken(token, uid):
        raise RuntimeError("firestore down")

    _, url = server(access=broken)
    assert call(url)[0] == 503


def test_real_access_check_accepts_only_active_copilot_roles():
    import http.server

    docs = {}

    class Firestore(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            doc = docs.get(self.path.split("/documents/", 1)[-1])
            code = 200 if doc is not None else 404
            data = json.dumps({"fields": doc or {}}).encode()
            self.send_response(code)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            return

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Firestore)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    check = app.firestore_access_check("p", f"http://127.0.0.1:{httpd.server_port}")

    def s(value):
        return {"stringValue": value}

    def doc(role, active=True, status="active"):
        return {"role": s(role), "isActive": {"booleanValue": active}, "status": s(status)}

    def v2(uid, **over):
        fields = {"accessVersion": {"integerValue": "2"}, "uid": s(uid), "status": s("active"), "role": s("admin")}
        fields.update(over)
        return fields

    def legacy(uid, link=None, **over):
        fields = {"uid": s(uid), "status": s("active"), "role": s("salesman")}
        if link is not None:
            fields["userDocId"] = s(link)
        fields.update(over)
        return fields

    def profile(uid, role="admin", **over):
        fields = {"uid": s(uid), "role": s(role), "status": s("active")}
        fields.update(over)
        return fields

    for name, fields in dict(
        admin=doc("admin"), sales=doc("salesman"), sales_off=doc("salesman", active=False),
        sales_held=doc("salesman", status="suspended"), driver=doc("driver"), off=doc("admin", active=False), held=doc("supervisor", status="suspended"),
        legacy_yes=legacy("legacy_yes", role=s("Administrator"), isActive=s("yes")),
        legacy_sales=legacy("legacy_sales"),
        legacy_other_uid=legacy("someone-else", role=s("admin")),
        v2_ok=v2("v2_ok"), v2_branch=v2("v2_branch", role=s("branch_manager"), branchId=s("b1")),
        v2_wrong_uid=v2("another"), v2_no_status=v2("v2_no_status"), v2_cap_role=v2("v2_cap_role", role=s("Admin")),
        v2_v3=v2("v2_v3", accessVersion={"integerValue": "3"}), v2_sales=v2("v2_sales", role=s("salesman")),
        v2_held=v2("v2_held", status=s("suspended")),
        v2_deleting=v2("v2_deleting", disabledReasons={"arrayValue": {"values": [s("deletion_requested")]}}),
        v2_readonly=v2("v2_readonly", disabledReasons={"arrayValue": {"values": [s("lifecycle_readonly")]}}),
        v2_clear=v2("v2_clear", disabledReasons={"arrayValue": {}}), v2_bad_branch=v2("v2_bad_branch", branchId={"integerValue": "7"}),
        link_ok=legacy("link_ok", link="p-ok"), link_off=legacy("link_off", link="p-off"),
        link_other=legacy("link_other", link="p-other"), link_missing=legacy("link_missing", link="p-gone"),
        link_empty=legacy("link_empty", link=""), link_sales=legacy("link_sales", link="p-sales", role=s("admin")),
    ).items():
        docs["user_access/" + name] = fields
    del docs["user_access/v2_no_status"]["status"]
    docs.update({
        "users/p-ok": profile("link_ok"),
        "users/p-off": profile("link_off", status=s("suspended")),
        "users/p-other": profile("someone-else"),
        "users/p-sales": profile("link_sales", role="Salesman"),
    })
    try:
        assert check("t", "admin") is True and check("t", "sales") == "salesman"
        assert [check("t", u) for u in ("sales_off", "sales_held", "driver", "off", "held", "missing")] == [False] * 6
        allowed = ["v2_ok", "v2_clear", "v2_branch", "v2_sales", "legacy_yes", "legacy_sales", "link_ok", "link_sales"]
        denied = [
            "legacy_other_uid", "v2_wrong_uid", "v2_no_status", "v2_cap_role", "v2_v3",
            "v2_held", "v2_deleting", "v2_readonly", "v2_bad_branch", "link_off", "link_other", "link_missing", "link_empty",
        ]
        assert [u for u in allowed if not check("t", u)] == []
        assert [u for u in denied if check("t", u) is not False] == []
    finally:
        httpd.shutdown()


def test_access_check_raises_on_a_firestore_failure_so_the_server_answers_503(server):
    import http.server

    class Down(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_):
            return

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Down)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        check = app.firestore_access_check("p", f"http://127.0.0.1:{httpd.server_port}")
        with pytest.raises(urllib.error.HTTPError):
            check("t", "uid-1")
        _, url = server(access=check)
        assert call(url)[0] == 503
    finally:
        httpd.shutdown()


def test_the_confidence_gate_uses_the_exact_value_and_only_the_response_is_rounded(server):
    gemini = counting((GOOD, 1.0))
    _, url = server(lambda t, p, a: (GOOD, 0.97996), fallback=gemini)
    body = call(url)[1]
    assert body["source"] == "gemini" and len(gemini.calls) == 1
    _, url = server(lambda t, p, a: (GOOD, 0.98004))
    assert call(url)[1]["confidence"] == 0.98


def test_gemini_daily_budget_stops_the_fallback(server):
    gemini = counting((GOOD, 1.0))
    _, url = server(lambda t, p, a: (GOOD, 0.4), fallback=gemini, gemini_daily_limit=1)
    assert call(url)[1]["call"] is not None
    capped = call(url)[1]
    assert capped["call"] is None and capped["unavailable"] is True and capped["source"] == "unavailable"
    assert len(gemini.calls) == 1


def test_salesperson_requests_use_their_own_gemini_budget(server):
    gemini = counting((GOOD, 1.0))
    _, url = server(lambda t, p, a: (GOOD, 0.4), fallback=gemini, access=lambda t, u: "salesman",
                    gemini_daily_limit=5, gemini_daily_limit_salesman=1)
    assert call(url)[1]["call"] is not None
    assert call(url)[1]["call"] is None
    assert len(gemini.calls) == 1
    _, url = server(lambda t, p, a: (GOOD, 0.4), fallback=gemini, access=lambda t, u: True,
                    gemini_daily_limit=1, gemini_daily_limit_salesman=0)
    assert call(url)[1]["call"] is not None


PERSON_SHARE = 25


def person_server(server, fallback, access, **limits):
    state, url = server(lambda t, p, a: (GOOD, 0.4), fallback=fallback, access=access, **limits)
    state.verify = lambda token: {"sub": token, "company": "co"}
    return state, url


@pytest.mark.parametrize("role", [True, "salesman"])
def test_one_person_cannot_spend_more_than_their_share_and_the_message_names_it(server, role):
    gemini = counting((GOOD, 1.0))
    _, url = person_server(server, gemini, lambda t, u: role)
    answers = [call(url, token="heavy")[1] for _ in range(PERSON_SHARE)]
    assert [a["source"] for a in answers] == ["gemini"] * PERSON_SHARE
    refused = call(url, token="heavy")[1]
    assert (refused["call"], refused["unavailable"], refused["unavailableReason"]) == (None, True, "person_limit")
    assert len(gemini.calls) == PERSON_SHARE
    other = call(url, token="light")[1]
    assert (other["source"], other["unavailableReason"]) == ("gemini", None)


def test_a_person_under_their_share_is_unaffected_when_a_colleague_is_over(server):
    gemini = counting((GOOD, 1.0))
    _, url = person_server(server, gemini, lambda t, u: True)
    for _ in range(PERSON_SHARE + 1):
        call(url, token="heavy")
    assert [call(url, token="light")[1]["source"] for _ in range(3)] == ["gemini"] * 3


def test_a_spent_company_budget_gives_the_company_reason_not_the_person_reason(server):
    gemini = counting((GOOD, 1.0))
    _, url = server(lambda t, p, a: (GOOD, 0.4), fallback=gemini, gemini_daily_limit=2)
    assert call(url)[1]["source"] == "gemini"
    assert call(url)[1]["source"] == "gemini"
    capped = call(url)[1]
    assert (capped["unavailable"], capped["unavailableReason"]) == (True, "company_limit")


def test_thirty_requests_at_once_from_one_person_reach_gemini_once_and_the_rest_are_told_to_wait():
    gemini_calls = []
    release = threading.Event()

    def gemini(text, pages, actions):
        gemini_calls.append(1)
        release.wait(5)
        return GOOD, 1.0

    state = app.State(lambda token: {"sub": "uid-1", "company": "co"}, lambda t, p, a: (GOOD, 0.4), 0.98, {ORIGIN},
                      fallback=gemini, gemini_max_concurrent=30, max_pending=30)
    state.ready.set()
    httpd = app.Server(("127.0.0.1", 0), app.make_handler(state))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{httpd.server_port}"
    results = []
    threads = [threading.Thread(target=lambda: results.append(call(url))) for _ in range(30)]
    try:
        for thread in threads:
            thread.start()
        deadline = time.monotonic() + 5
        while len(results) < 29 and time.monotonic() < deadline:
            time.sleep(0.05)
        release.set()
        for thread in threads:
            thread.join()
    finally:
        httpd.shutdown()
    assert len(gemini_calls) == 1
    assert sorted(r[0] for r in results) == [200] + [429] * 29


def test_a_spent_salesperson_pool_gives_its_own_reason_and_dashboard_users_still_get_answers(server):
    gemini = counting((GOOD, 1.0))
    _, url = person_server(server, gemini, lambda t, u: "salesman" if t.startswith("sales") else True,
                           gemini_daily_limit_salesman=2)
    assert call(url, token="sales-a")[1]["source"] == "gemini"
    assert call(url, token="sales-b")[1]["source"] == "gemini"
    refused = call(url, token="sales-c")[1]
    assert (refused["call"], refused["unavailable"], refused["unavailableReason"]) == (None, True, "salesperson_limit")
    assert call(url, token="office")[1]["source"] == "gemini"
    assert len(gemini.calls) == 3


def test_gemini_failures_do_not_use_up_the_persons_share_or_the_company_budget(server, monkeypatch):
    monkeypatch.setattr(app, "RATE_LIMIT", 1000)
    failing = {"on": True}
    asked = []

    def gemini(text, pages, actions):
        asked.append(text)
        if failing["on"]:
            raise RuntimeError("Gemini is down")
        return GOOD, 1.0

    state, url = person_server(server, gemini, lambda t, u: True, gemini_daily_limit=PERSON_SHARE + 1)
    failed = [call(url, token="heavy")[1] for _ in range(PERSON_SHARE + 1)]
    assert {(a["unavailable"], a["unavailableReason"]) for a in failed} == {(True, None)}
    failing["on"] = False
    answered = [call(url, token="heavy")[1] for _ in range(PERSON_SHARE)]
    assert [a["source"] for a in answered] == ["gemini"] * PERSON_SHARE
    assert call(url, token="heavy")[1]["unavailableReason"] == "person_limit"
    assert len(asked) == PERSON_SHARE * 2 + 1


def test_gemini_wait_of_one_user_does_not_block_another_users_local_answer(server):
    release = threading.Event()

    def generate(text, pages, actions):
        return ("", 0.0) if text == "slow" else (GOOD, 0.99)

    def gemini(text, pages, actions):
        release.wait(5)
        return GOOD, 1.0

    _, url = server(generate, fallback=gemini)
    slow = {}
    thread = threading.Thread(target=lambda: slow.update(r=call(url, body={**BODY, "text": "slow"})))
    thread.start()
    time.sleep(0.3)
    started = time.monotonic()
    status, body, _ = call(url, body={**BODY, "text": "fast"})
    assert (status, body["source"]) == (200, "model") and time.monotonic() - started < 1
    release.set()
    thread.join()
    assert slow["r"][1]["source"] == "gemini"


def test_upstream_calls_to_one_host_reuse_one_connection():
    connects = []

    class Upstream(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

    class Counting(ThreadingHTTPServer):
        daemon_threads = True

        def get_request(self):
            connects.append(1)
            return super().get_request()

    httpd = Counting(("127.0.0.1", 0), Upstream)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        request = urllib.request.Request(f"http://127.0.0.1:{httpd.server_port}/")
        replies = [http_deadline.request_bytes(request, timeout=3).data for _ in range(5)]
    finally:
        httpd.shutdown()
        httpd.server_close()
    assert replies == [b"ok"] * 5 and len(connects) == 1


def test_repeated_bad_tokens_from_one_address_are_refused_before_the_token_check(server):
    checks = []

    def counting_verifier(token):
        checks.append(token)
        return verifier(token)

    state, url = server()
    state.verify = counting_verifier

    def attempt(address, token):
        request = urllib.request.Request(
            url + "/v1/interpret", data=json.dumps(BODY).encode(),
            headers={"Authorization": f"Bearer {token}", "X-Forwarded-For": address})
        try:
            return urllib.request.urlopen(request).status
        except urllib.error.HTTPError as error:
            return error.code

    codes = [attempt("203.0.113.9", f"bad-{i}") for i in range(app.FAILED_SIGN_IN_LIMIT + 5)]
    assert codes == [401] * app.FAILED_SIGN_IN_LIMIT + [429] * 5
    assert len(checks) == app.FAILED_SIGN_IN_LIMIT
    assert attempt("203.0.113.10", "good-token") == 200


def test_one_company_at_its_gemini_cap_does_not_block_another_company(server):
    gemini = counting((GOOD, 1.0))
    state, url = server(lambda t, p, a: (GOOD, 0.4), fallback=gemini, gemini_daily_limit=1)
    state.verify = lambda token: {"sub": "uid-1", "company": token}
    assert call(url, token="company-a")[1]["source"] == "gemini"
    assert call(url, token="company-a")[1]["source"] == "unavailable"
    assert call(url, token="company-b")[1]["source"] == "gemini"



def test_directory_verifier_resolves_the_company_without_a_per_user_check():
    from platform_service import auth as platform_auth

    identity = platform_auth.ClientIdentity(uid="u1", project_id="proj", auth_tenant_id="tenant-1")

    record = {
        "location": {"projectId": "proj", "authTenantId": "tenant-1", "databaseId": "db1"},
        "workspace": "w", "tenantId": "t1", "status": "live",
    }

    class Store:
        def find_by_auth(self, project_id, auth_tenant_id):
            return record

        def lifecycle_state(self, tenant_id):
            return "active"

    original = platform_auth.verify_client_token
    platform_auth.verify_client_token = lambda token, certificate_request=None: identity
    try:
        verified = app.directory_verifier(Store())("token")
    finally:
        platform_auth.verify_client_token = original
    assert verified["scope"] == ("proj", "db1") and verified["company"] == "t1"


def test_directory_verifier_remembers_an_unknown_company_for_the_cache_time():
    from platform_service import auth as platform_auth

    identity = platform_auth.ClientIdentity(uid="u1", project_id="proj", auth_tenant_id="tenant-1")
    lookups = []
    now = [0.0]

    class Store:
        def find_by_auth(self, project_id, auth_tenant_id):
            lookups.append(project_id)
            return None

    original = platform_auth.verify_client_token
    platform_auth.verify_client_token = lambda token, certificate_request=None: identity
    try:
        verify = app.directory_verifier(Store(), clock=lambda: now[0])
        for _ in range(3):
            with pytest.raises(app.Rejected) as refused:
                verify("token")
            assert refused.value.status == 403
        assert len(lookups) == 1
        now[0] += app.DIRECTORY_CACHE_SECONDS + 1
        with pytest.raises(app.Rejected):
            verify("token")
        assert len(lookups) == 2
    finally:
        platform_auth.verify_client_token = original


GEMINI_REPLY = json.dumps({"candidates": [{"content": {"parts": [{"functionCall": {
    "name": "search_orders", "args": {"salesperson": "Ahmad", "period": "today"}}}]}}]}).encode()


@contextmanager
def fake_gemini(box):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            box["seen"] = box.get("seen", 0) + 1
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            time.sleep(box.get("delay", 0))
            body = GEMINI_REPLY if box.get("status", 200) == 200 else b"{}"
            try:
                self.send_response(box.get("status", 200))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except OSError:
                pass

    class Quiet(ThreadingHTTPServer):
        daemon_threads = True

    httpd = Quiet(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}"
    finally:
        httpd.shutdown()
        httpd.server_close()


@contextmanager
def real_gemini_server(box, **limits):
    from tools.voice.dashboard_llm.gemini_client import GeminiGenerator
    with fake_gemini(box) as upstream:
        generator = GeminiGenerator("test-key", base_url=upstream, seconds_between_calls=0, retries=0, timeout=6)
        state = app.State(lambda token: {"sub": token, "company": "co"}, lambda t, p, a: (GOOD, 0.4), 0.98, {ORIGIN},
                          fallback=generator, access=lambda t, u: True, request_timeout=4.0, **limits)
        state.ready.set()
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), app.make_handler(state))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            yield httpd.server_port
        finally:
            httpd.shutdown()
            httpd.server_close()
            state.close()


def slow_call(port, hold, token="p"):
    crlf = chr(13) + chr(10)
    body = json.dumps(BODY).encode()
    lines = ["POST /v1/interpret HTTP/1.1", "Host: x", f"Authorization: Bearer {token}",
             "Content-Type: application/json", f"Content-Length: {len(body)}", "Connection: close", "", ""]
    head = crlf.join(lines).encode()
    with socket.create_connection(("127.0.0.1", port), timeout=15) as connection:
        connection.sendall(head + body[:5])
        time.sleep(hold)
        connection.sendall(body[5:])
        reply = b""
        while chunk := connection.recv(4096):
            reply += chunk
    return json.loads(reply.split((crlf * 2).encode(), 1)[1])


def test_a_slow_client_that_makes_gemini_time_out_still_uses_the_persons_share(monkeypatch):
    monkeypatch.setattr(app, "GEMINI_MIN_SECONDS", 0.5, raising=False)
    box = {"delay": 2.0}
    with real_gemini_server(box, gemini_daily_limit_person=2) as port:
        slow = [slow_call(port, 2.5) for _ in range(2)]
        assert [(a["unavailable"], a["unavailableReason"]) for a in slow] == [(True, None)] * 2
        assert box["seen"] == 2
        refused = call(f"http://127.0.0.1:{port}", token="p")[1]
        assert (refused["unavailable"], refused["unavailableReason"]) == (True, "person_limit")
        assert box["seen"] == 2


def test_too_little_request_time_left_makes_no_gemini_call_and_costs_no_share(monkeypatch):
    monkeypatch.setattr(app, "GEMINI_MIN_SECONDS", 0.5, raising=False)
    box = {"delay": 0}
    with real_gemini_server(box, gemini_daily_limit_person=2) as port:
        slow = [slow_call(port, 3.2) for _ in range(3)]
        assert [(a["unavailable"], a["unavailableReason"]) for a in slow] == [(True, None)] * 3
        assert box.get("seen", 0) == 0
        answers = [call(f"http://127.0.0.1:{port}", token="p")[1] for _ in range(2)]
        assert [a["source"] for a in answers] == ["gemini"] * 2
        assert box["seen"] == 2


def test_an_error_reply_from_gemini_gives_the_call_back():
    box = {"status": 500}
    with real_gemini_server(box, gemini_daily_limit_person=2) as port:
        url = f"http://127.0.0.1:{port}"
        failed = [call(url, token="p")[1] for _ in range(3)]
        assert [(a["unavailable"], a["unavailableReason"]) for a in failed] == [(True, None)] * 3
        box["status"] = 200
        answers = [call(url, token="p")[1] for _ in range(2)]
        assert [a["source"] for a in answers] == ["gemini"] * 2
        assert call(url, token="p")[1]["unavailableReason"] == "person_limit"


def company_server(server, fallback):
    state, url = server(lambda t, p, a: (GOOD, 0.4), fallback=fallback, access=lambda t, u: True)
    state.verify = lambda token: {"sub": token, "company": token[0]}
    return state, url


def test_one_person_gets_one_gemini_call_at_a_time_and_is_told_so_at_once(server):
    started, release = threading.Event(), threading.Event()

    def gemini(text, pages, actions):
        started.set()
        release.wait(5)
        return GOOD, 1.0

    _, url = company_server(server, gemini)
    first = {}
    thread = threading.Thread(target=lambda: first.update(r=call(url, token="A1")))
    thread.start()
    assert started.wait(5)
    began = time.monotonic()
    status, body, _ = call(url, token="A1")
    assert (status, body) == (429, {"error": "one request at a time"}) and time.monotonic() - began < 1
    release.set()
    thread.join()
    assert first["r"][1]["source"] == "gemini"
    assert call(url, token="A1")[1]["source"] == "gemini"


def test_busy_companies_cannot_hold_every_gemini_slot_so_a_new_company_still_answers(server):
    in_flight = threading.Semaphore(0)
    release = threading.Event()
    asked = []

    def gemini(text, pages, actions):
        asked.append(1)
        in_flight.release()
        release.wait(5)
        return GOOD, 1.0

    _, url = company_server(server, gemini)
    holders = [threading.Thread(target=lambda t=t: call(url, token=t)) for t in ("A1", "A2", "B1")]
    for holder in holders:
        holder.start()
        assert in_flight.acquire(timeout=5)
    for refused in ("A3", "B2"):
        reply = call(url, token=refused)[1]
        assert (reply["call"], reply["unavailable"]) == (None, True)
    assert len(asked) == 3
    other = call(url, token="C1")[1]
    assert other["source"] == "gemini" and len(asked) == 4
    release.set()
    for holder in holders:
        holder.join()

from __future__ import annotations

import datetime
import json
import math
import os
import queue
import re
import signal
import socket
import sys
import threading
import time
import urllib.parse
from concurrent.futures import CancelledError, Future, TimeoutError as FutureTimeout
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Optional

from google.auth.exceptions import GoogleAuthError

from tools.voice.dashboard_llm import copilot_model as model
from tools.voice.dashboard_llm import copilot_schema as schema
from tools.voice.dashboard_llm import http_deadline

MAX_BODY = 32_768
RATE_LIMIT = 30
FAILED_SIGN_IN_LIMIT = 20
MAX_FAILURE_CLIENTS = 2_000
LOOPBACK = {"127.0.0.1", "::1"}
GEMINI_DAILY_LIMIT = 500
GEMINI_DAILY_LIMIT_SALESMAN = 200
GEMINI_DAILY_LIMIT_PERSON = 25
TAKEN, PERSON_FULL, COMPANY_FULL, SALESPERSON_FULL, BUDGET_UNKNOWN = (
    "taken", "person_limit", "company_limit", "salesperson_limit", "unknown")
GEMINI_MAX_SECONDS = 6.0
GEMINI_DEADLINE_MARGIN = 0.5
GEMINI_MIN_SECONDS = 2.0
GEMINI_MAX_CONCURRENT = 4
GEMINI_MAX_PER_COMPANY = 2
GEMINI_MAX_PER_PERSON = 1
BUDGET_FIELDS = {False: "dashboardCalls", True: "salesmanCalls"}
BUDGET_FLUSH_SECONDS = 2.0
BUDGET_LOAD_SECONDS = 2.0
BUDGET_LOAD_RETRY_SECONDS = 2.0
BUDGET_SAVE_SECONDS = 5.0
MYT_OFFSET_SECONDS = 8 * 3600
ACCESS_CACHE_SECONDS = 60
ACCESS_CACHE_MAX = 5_000
CERTIFICATE_CACHE_MAX = 8
COPILOT_ROLES = {"admin", "developer", "supervisor", "branch_manager", "salesman"}
_BEARER = re.compile(r"^Bearer\s+(\S+)$")

DIRECTORY_CACHE_SECONDS = 60

Verifier = Callable[[str], "dict[str, Any]"]
AccessCheck = Callable[..., Any]


def budget_day() -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(time.time() + MYT_OFFSET_SECONDS))


class _DayCount:
    def __init__(self, used: "Optional[dict[str, int]]") -> None:
        self.used = used
        self.saved = None if used is None else dict(used)
        self.people: "dict[str, int]" = {}
        self.saved_people: "dict[str, int]" = {}
        self.loading = False
        self.retry_at = 0.0


def _person_key(person: str) -> str:
    return urllib.parse.quote(person, safe="").replace(".", "%2E") or "_"


def _readable_person_counts(stored: Any) -> "dict[str, int]":
    if not isinstance(stored, dict):
        return {}
    counts: "dict[str, int]" = {}
    for key, count in stored.items():
        if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
            counts[str(key)] = count
    return counts


def entry_changed(entry: _DayCount) -> bool:
    return entry.used != entry.saved or entry.people != entry.saved_people


class GeminiBudget:
    def __init__(self, client: Any = None, collection: str = "copilot_budget",
                 flush_seconds: float = BUDGET_FLUSH_SECONDS) -> None:
        self._client, self._collection, self._flush_seconds = client, collection, flush_seconds
        self._lock = threading.Lock()
        self._loaded = threading.Condition(self._lock)
        self._days: "dict[tuple[str, str], _DayCount]" = {}
        self._stop = threading.Event()
        self._writer: Optional[threading.Thread] = None
        if client is not None:
            self._writer = threading.Thread(target=self._write_loop, daemon=True)
            self._writer.start()

    def _reference(self, company: str, day: str) -> Any:
        return self._client.collection(self._collection).document(f"{urllib.parse.quote(company, safe='')}_{day}")

    def take(self, company: str, salesman: bool, limit: int, day: str, person: str, person_limit: int) -> str:
        with self._lock:
            entry = self._days.get((company, day))
            if entry is None:
                self._forget_old_days(day)
                entry = self._days[(company, day)] = _DayCount(
                    None if self._client is not None else {field: 0 for field in BUDGET_FIELDS.values()})
            load = entry.used is None and not entry.loading and time.monotonic() >= entry.retry_at
            if load:
                entry.loading = True
            elif entry.used is None and entry.loading:
                self._loaded.wait_for(lambda: not entry.loading, timeout=_firestore_timeout())
        if load:
            self._load(company, day, entry)
        field = BUDGET_FIELDS[salesman]
        key = _person_key(person)
        with self._lock:
            if entry.used is None:
                return BUDGET_UNKNOWN
            if entry.people.get(key, 0) >= person_limit:
                return PERSON_FULL
            if entry.used[field] >= limit:
                return SALESPERSON_FULL if salesman else COMPANY_FULL
            entry.used[field] += 1
            entry.people[key] = entry.people.get(key, 0) + 1
            return TAKEN

    def give_back(self, company: str, salesman: bool, day: str, person: str) -> None:
        field = BUDGET_FIELDS[salesman]
        key = _person_key(person)
        with self._lock:
            entry = self._days.get((company, day))
            if entry is not None and entry.used is not None and entry.used[field] > 0:
                entry.used[field] -= 1
                if entry.people.get(key, 0) > 0:
                    entry.people[key] -= 1

    def _load(self, company: str, day: str, entry: _DayCount) -> None:
        used = people = None
        try:
            snapshot = self._reference(company, day).get(
                retry=None, timeout=min(BUDGET_LOAD_SECONDS, _firestore_timeout()))
            stored = snapshot.to_dict() or {}
            used = {field: int(stored.get(field, 0)) for field in BUDGET_FIELDS.values()}
            people = _readable_person_counts(stored.get("personCalls"))
        except Exception as error:
            print(f"Scout budget unavailable: {type(error).__name__}", file=sys.stderr)
        finally:
            with self._lock:
                entry.loading = False
                if used is None:
                    entry.retry_at = time.monotonic() + BUDGET_LOAD_RETRY_SECONDS
                else:
                    entry.used, entry.saved = used, dict(used)
                    entry.people, entry.saved_people = people, dict(people)
                self._loaded.notify_all()

    def _forget_old_days(self, day: str) -> None:
        yesterday = (datetime.date.fromisoformat(day) - datetime.timedelta(days=1)).isoformat()
        for key in [key for key, entry in self._days.items()
                    if key[1] < yesterday and (self._client is None or not entry_changed(entry))]:
            del self._days[key]

    def flush(self) -> None:
        if self._client is None:
            return
        with self._lock:
            changed = [(key, dict(entry.used), dict(entry.people)) for key, entry in self._days.items()
                       if entry.used is not None and entry_changed(entry)]
        for (company, day), used, people in changed:
            try:
                self._reference(company, day).set({"company": company, "day": day, **used, "personCalls": people},
                                                  merge=True, retry=None, timeout=BUDGET_SAVE_SECONDS)
            except Exception as error:
                print(f"Scout budget save failed: {type(error).__name__}", file=sys.stderr)
                continue
            with self._lock:
                entry = self._days.get((company, day))
                if entry is not None:
                    entry.saved, entry.saved_people = used, people

    def _write_loop(self) -> None:
        while not self._stop.wait(self._flush_seconds):
            self.flush()

    def close(self) -> None:
        self._stop.set()
        if self._writer is not None:
            self._writer.join()
            self.flush()


def _firestore_timeout() -> float:
    deadline = http_deadline.REQUEST_DEADLINE.get()
    if deadline is None:
        return 5.0
    return max(0.1, deadline - time.monotonic())


def scoped_uid(uid: str, scope: "Optional[tuple[str, str]]") -> str:
    return uid if scope is None else "/".join((*scope, uid))


class Server(ThreadingHTTPServer):
    request_queue_size = 128


class Rejected(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status, self.message = status, message


def _validate_limits(threshold: float, body_timeout: float, request_timeout: float, max_pending: int) -> None:
    if (not all(math.isfinite(v) and v > 0 for v in (body_timeout, request_timeout))
            or not math.isfinite(threshold) or not 0 <= threshold <= 1
            or type(max_pending) is not int or max_pending < 1):
        raise ValueError("Request limits and threshold must be valid finite values")


class State:
    def __init__(
        self,
        verify: Verifier,
        generate: model.Generate,
        threshold: float,
        origins: "set[str]",
        clock: Callable[[], float] = time.monotonic,
        fallback: Optional[model.Generate] = None,
        access: Optional[AccessCheck] = None,
        gemini_daily_limit: int = GEMINI_DAILY_LIMIT,
        gemini_daily_limit_salesman: int = GEMINI_DAILY_LIMIT_SALESMAN,
        gemini_daily_limit_person: int = GEMINI_DAILY_LIMIT_PERSON,
        body_timeout: float = 5.0,
        request_timeout: float = 30.0,
        max_pending: int = 2,
        gemini_seconds: float = GEMINI_MAX_SECONDS,
        serialize_inference: bool = True,
        budget: "Optional[GeminiBudget]" = None,
        gemini_max_concurrent: int = GEMINI_MAX_CONCURRENT,
    ) -> None:
        _validate_limits(threshold, body_timeout, request_timeout, max_pending)
        self.body_timeout, self.request_timeout = body_timeout, request_timeout
        self.gemini_seconds, self.serialize_inference = gemini_seconds, serialize_inference
        self._pending: queue.Queue = queue.Queue(maxsize=max_pending)
        self._worker_started = False
        self._closed = threading.Event()
        self.verify, self.generate, self.threshold = verify, generate, threshold
        self.fallback, self.access = fallback, access
        self._gemini_limits = {False: gemini_daily_limit, True: gemini_daily_limit_salesman}
        self._gemini_person_limit = gemini_daily_limit_person
        self.budget = budget if budget is not None else GeminiBudget()
        self._gemini_max_concurrent = gemini_max_concurrent
        self._gemini_running: "dict[tuple[str, str], int]" = {}
        self._gemini_running_by_company: "dict[str, int]" = {}
        self._access_cache: "dict[str, tuple[float, Any]]" = {}
        self.origins, self._clock = origins, clock
        self.ready = threading.Event()
        self._hits: "dict[str, deque[float]]" = defaultdict(deque)
        self._failures: "dict[str, deque[float]]" = defaultdict(deque)
        self._lock = threading.Lock()

    @property
    def pending_count(self) -> int:
        return self._pending.qsize()

    def close(self) -> None:
        self._closed.set()
        self.budget.close()

    def _work(self) -> None:
        while not self._closed.is_set():
            try:
                future, text, pages, actions, deadline = self._pending.get(timeout=0.1)
            except queue.Empty:
                continue
            try:
                if time.monotonic() >= deadline:
                    future.cancel()
                if not future.set_running_or_notify_cancel():
                    continue
                token = http_deadline.REQUEST_DEADLINE.set(deadline)
                try:
                    future.set_result(self.generate(text, pages, actions))
                except Exception as error:
                    future.set_exception(error)
                finally:
                    http_deadline.REQUEST_DEADLINE.reset(token)
            finally:
                self._pending.task_done()

    def run_request(self, authorization: Optional[str], body: bytes, deadline: float,
                    client: Optional[str] = None) -> dict[str, Any]:
        _check_deadline(deadline)
        token = http_deadline.REQUEST_DEADLINE.set(deadline)
        try:
            return interpret_request(self, authorization, body, deadline, client)
        finally:
            http_deadline.REQUEST_DEADLINE.reset(token)

    def _infer(self, text: str, pages: "list[dict[str, Any]]", actions: "list[str]",
               deadline: float) -> "tuple[str, float]":
        _check_deadline(deadline)
        future: Future = Future()
        with self._lock:
            if not self._worker_started:
                threading.Thread(target=self._work, daemon=True).start()
                self._worker_started = True
        try:
            self._pending.put_nowait((future, text, pages, actions, deadline))
        except queue.Full:
            raise Rejected(503, "model queue is full") from None
        try:
            return future.result(timeout=max(0, deadline - time.monotonic()))
        except (FutureTimeout, CancelledError):
            future.cancel()
            raise Rejected(504, "request deadline exceeded") from None

    def may_use(self, token: str, uid: str, scope: "Optional[tuple[str, str]]" = None) -> Any:
        if self.access is None:
            return True
        now = self._clock()
        key = scoped_uid(uid, scope)
        with self._lock:
            cached = self._access_cache.get(key)
        if cached and cached[0] > now:
            return cached[1]
        ok = self.access(token, uid) if scope is None else self.access(token, uid, scope)
        with self._lock:
            for stale in [k for k, (expires, _) in self._access_cache.items() if expires <= now]:
                del self._access_cache[stale]
            while len(self._access_cache) >= ACCESS_CACHE_MAX:
                del self._access_cache[next(iter(self._access_cache))]
            self._access_cache[key] = (now + ACCESS_CACHE_SECONDS, ok)
        return ok

    def begin_gemini_call(self, company: str, uid: str) -> bool:
        person = (company, uid)
        with self._lock:
            if self._gemini_running.get(person, 0) >= GEMINI_MAX_PER_PERSON:
                raise Rejected(429, "one request at a time")
            running_here = self._gemini_running_by_company.get(company, 0)
            free_slots = self._gemini_max_concurrent - sum(self._gemini_running_by_company.values())
            if running_here >= GEMINI_MAX_PER_COMPANY or free_slots < 1:
                return False
            if running_here >= 1 and free_slots < 2:
                return False
            self._gemini_running[person] = self._gemini_running.get(person, 0) + 1
            self._gemini_running_by_company[company] = self._gemini_running_by_company.get(company, 0) + 1
            return True

    def end_gemini_call(self, company: str, uid: str) -> None:
        person = (company, uid)
        with self._lock:
            for counts, key in ((self._gemini_running, person), (self._gemini_running_by_company, company)):
                counts[key] -= 1
                if counts[key] == 0:
                    del counts[key]

    def give_back_gemini_call(self, salesman: bool, company: str, day: str, uid: str) -> None:
        self.budget.give_back(company, salesman, day, uid)

    def take_gemini_call(self, salesman: bool, company: str, day: str, uid: str) -> str:
        return self.budget.take(company, salesman, self._gemini_limits[salesman], day, uid,
                                self._gemini_person_limit)

    def _recent_failures(self, client: str, now: float) -> "deque[float]":
        failures = self._failures[client]
        while failures and now - failures[0] > 60:
            failures.popleft()
        if not failures:
            del self._failures[client]
        return failures

    def _failure_room(self, now: float) -> bool:
        if len(self._failures) < MAX_FAILURE_CLIENTS:
            return True
        for key in [key for key, hits in self._failures.items() if now - hits[-1] > 60]:
            del self._failures[key]
        for key in [key for key, hits in self._failures.items() if len(hits) < FAILED_SIGN_IN_LIMIT]:
            if len(self._failures) < MAX_FAILURE_CLIENTS:
                break
            del self._failures[key]
        return len(self._failures) < MAX_FAILURE_CLIENTS

    def sign_in_blocked(self, client: str) -> bool:
        now = self._clock()
        with self._lock:
            return len(self._recent_failures(client, now)) >= FAILED_SIGN_IN_LIMIT

    def note_failed_sign_in(self, client: str) -> None:
        now = self._clock()
        with self._lock:
            self._recent_failures(client, now)
            if client not in self._failures and not self._failure_room(now):
                return
            self._failures[client].append(now)

    def allow(self, uid: str) -> bool:
        now = self._clock()
        with self._lock:
            if uid not in self._hits:
                for stale in [k for k, queue in self._hits.items() if not queue or now - queue[-1] > 60]:
                    del self._hits[stale]
            hits = self._hits[uid]
            while hits and now - hits[0] > 60:
                hits.popleft()
            if len(hits) >= RATE_LIMIT:
                return False
            hits.append(now)
            return True


def _parse(output: str, pages: "list[dict[str, Any]]", actions: "list[str]") -> "Optional[schema.Call]":
    return schema.parse_call(schema.PREFILL + output.removeprefix(schema.PREFILL), pages, actions)


def _invalid_sign_in(error: Exception) -> bool:
    return isinstance(error, (ValueError, TypeError, KeyError)) or getattr(error, "status_code", None) == 401


def _check_deadline(deadline: Optional[float]) -> None:
    if deadline is not None and time.monotonic() >= deadline:
        raise Rejected(504, "request deadline exceeded")


def _ask_fallback(state: State, uid: str, text: str, pages: "list[dict[str, Any]]", actions: "list[str]",
                  deadline: Optional[float], company: str = "",
                  salesman: bool = False) -> "tuple[Optional[schema.Call], bool, Optional[str]]":
    day = budget_day()
    from tools.voice.dashboard_llm.gemini_client import GeminiGenerator
    timed = isinstance(state.fallback, GeminiGenerator)
    if timed:
        limit = time.monotonic() + state.gemini_seconds
        if deadline is not None:
            limit = min(limit, deadline - GEMINI_DEADLINE_MARGIN)
        if limit - time.monotonic() < GEMINI_MIN_SECONDS:
            _check_deadline(deadline)
            return None, True, None
    if not state.begin_gemini_call(company, uid):
        return None, True, None
    try:
        taken = state.take_gemini_call(salesman, company, day, uid)
        if taken != TAKEN:
            return None, True, taken if taken in (PERSON_FULL, COMPANY_FULL, SALESPERSON_FULL) else None
        try:
            if timed:
                output = state.fallback(text, pages, actions, deadline=limit)[0]
            else:
                output = state.fallback(text, pages, actions)[0]
        except RuntimeError:
            state.give_back_gemini_call(salesman, company, day, uid)
            raise
    except Rejected:
        raise
    except Exception:
        _check_deadline(deadline)
        return None, True, None
    finally:
        state.end_gemini_call(company, uid)
    _check_deadline(deadline)
    return _parse(output, pages, actions), False, None


def decide(state: State, payload: Any, uid: str = "", deadline: Optional[float] = None,
           company: str = "", salesman: bool = False) -> "dict[str, Any]":
    started = time.perf_counter()
    text, pages, actions = schema.validate_request(payload)
    _check_deadline(deadline)
    if deadline is None or not state.serialize_inference:
        output, confidence = state.generate(text, pages, actions)
    else:
        output, confidence = state._infer(text, pages, actions, deadline)
    _check_deadline(deadline)
    call = _parse(output, pages, actions)
    source = "model"
    unavailable, reason = False, None
    if call is None or confidence < state.threshold:
        call, confidence = None, 0.0
        if state.fallback is not None:
            call, unavailable, reason = _ask_fallback(state, uid, text, pages, actions, deadline, company, salesman)
            source = "unavailable" if unavailable else "gemini"
    if call is not None and call.name == schema.NO_MATCH:
        call = None
    return {
        "call": None if call is None else call.as_dict(),
        "confidence": round(confidence if call else 0.0, 4),
        "source": source,
        "unavailable": unavailable,
        "unavailableReason": reason,
        "latencyMs": int((time.perf_counter() - started) * 1000),
    }


def interpret_request(state: State, authorization: Optional[str], body: bytes,
                      deadline: Optional[float] = None, client: Optional[str] = None) -> "dict[str, Any]":
    match = _BEARER.match(authorization or "")
    if not match:
        raise Rejected(401, "sign-in required")
    _check_deadline(deadline)
    if client is not None and state.sign_in_blocked(client):
        raise Rejected(429, "too many requests")
    try:
        claims = state.verify(match.group(1))
        subject = str(claims["sub"])
        scope = claims.get("scope")
        company = str(claims.get("company", ""))
        if scope is not None and not company:
            raise Rejected(403, "the sign-in has no company")
    except Rejected:
        raise
    except Exception as error:
        _check_deadline(deadline)
        if not _invalid_sign_in(error):
            raise Rejected(503, "sign-in could not be checked") from None
        if client is not None:
            state.note_failed_sign_in(client)
        raise Rejected(401, "invalid or expired sign-in") from None
    uid = scoped_uid(subject, scope)
    _check_deadline(deadline)
    try:
        access = state.may_use(match.group(1), subject, scope)
    except Exception:
        _check_deadline(deadline)
        raise Rejected(503, "could not check the account") from None
    _check_deadline(deadline)
    if not access:
        raise Rejected(403, "an active Scout account is required")
    if not state.ready.is_set():
        raise Rejected(503, "model is starting")
    if not state.allow(uid):
        raise Rejected(429, "too many requests")
    try:
        payload = json.loads(body)
        return decide(state, payload, uid, deadline, company, access == "salesman")
    except (ValueError, schema.RequestError):
        raise Rejected(400, "invalid request") from None


def make_handler(state: State) -> "type[BaseHTTPRequestHandler]":
    class Handler(BaseHTTPRequestHandler):
        server_version = "copilot"

        def setup(self) -> None:
            super().setup()
            self._deadline = time.monotonic() + state.request_timeout
            self.connection.settimeout(min(state.body_timeout, state.request_timeout))
            self._timer = threading.Timer(state.request_timeout, self._stop_reading)
            self._timer.daemon = True
            self._timer.start()

        def _stop_reading(self) -> None:
            try:
                self.connection.shutdown(socket.SHUT_RD)
            except OSError:
                pass

        def finish(self) -> None:
            self._timer.cancel()
            super().finish()

        def log_message(self, *_: Any) -> None:
            return

        def _client(self) -> str:
            peer = self.client_address[0]
            if peer in LOOPBACK:
                forwarded = self.headers.get("X-Forwarded-For", "").split(",")[-1].strip()
                if forwarded:
                    return forwarded
            return peer

        def _send(self, status: int, payload: "dict[str, Any]") -> None:
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            origin = self.headers.get("Origin")
            if origin and origin in state.origins:
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Vary", "Origin")
            self.end_headers()
            try:
                self.wfile.write(data)
            except OSError:
                self.close_connection = True

        def do_OPTIONS(self) -> None:
            origin = self.headers.get("Origin")
            if not origin or origin not in state.origins:
                return self._send(403, {"error": "origin not allowed"})
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "authorization, content-type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Max-Age", "600")
            self.send_header("Vary", "Origin")
            self.end_headers()

        def do_GET(self) -> None:
            if self.path == "/health":
                ready = state.ready.is_set()
                return self._send(200 if ready else 503, {"ready": ready})
            self._send(404, {"error": "not found"})

        def do_POST(self) -> None:
            if self.path != "/v1/interpret":
                return self._send(404, {"error": "not found"})
            origin = self.headers.get("Origin")
            if origin and origin not in state.origins:
                return self._send(403, {"error": "origin not allowed"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = -1
            if not 0 < length <= MAX_BODY:
                return self._send(413 if length > MAX_BODY else 400, {"error": "invalid request"})
            try:
                body_deadline = min(self._deadline, time.monotonic() + state.body_timeout)
                body = bytearray()
                while len(body) < length:
                    remaining = body_deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError
                    self.connection.settimeout(remaining)
                    chunk = self.rfile.read1(length - len(body))
                    if not chunk:
                        raise TimeoutError
                    body.extend(chunk)
                result = state.run_request(self.headers.get("Authorization"), bytes(body), self._deadline, self._client())
            except TimeoutError:
                return self._send(408, {"error": "request body deadline exceeded"})
            except Rejected as error:
                return self._send(error.status, {"error": error.message})
            except Exception:
                return self._send(500, {"error": "internal error"})
            self._send(200, result)

    return Handler


class CertificateRequest:
    def __init__(self, clock=time.monotonic) -> None:
        self._clock = clock
        self._cache: dict[str, tuple[float, http_deadline.Reply]] = {}
        self._lock = threading.Lock()

    def __call__(self, url, method='GET', body=None, headers=None, timeout=5, **kwargs):
        import urllib.request
        if method != 'GET' or body is not None:
            raise ValueError('Certificate transport only supports GET')
        cached = self._cache.get(url)
        if cached and cached[0] > self._clock():
            return cached[1]
        started = self._clock()
        response = http_deadline.request_bytes(
            urllib.request.Request(url, headers=headers or {}), timeout=min(timeout, 5))
        normalized = {key.lower(): value for key, value in response.headers.items()}
        control = normalized.get('cache-control', '').lower()
        freshness = re.search(r'(?:^|,)\s*max-age=(\d+)', control)
        if response.status == 200 and freshness and 'no-cache' not in control and 'no-store' not in control:
            from email.utils import parsedate_to_datetime
            try:
                age = max(0, int(normalized.get('age', '0')))
            except ValueError:
                age = int(freshness[1])
            apparent_age = 0.0
            if normalized.get('date'):
                try:
                    apparent_age = max(0, time.time() - parsedate_to_datetime(normalized['date']).timestamp())
                except (TypeError, ValueError, OverflowError):
                    apparent_age = int(freshness[1])
            current_age = max(apparent_age, age + self._clock() - started)
            with self._lock:
                now = self._clock()
                for stale in [u for u, (expires, _) in list(self._cache.items()) if expires <= now]:
                    self._cache.pop(stale, None)
                while len(self._cache) >= CERTIFICATE_CACHE_MAX and url not in self._cache:
                    self._cache.pop(next(iter(self._cache)), None)
                self._cache[url] = (now + max(0, int(freshness[1]) - current_age), response)
        return response


def firebase_verifier(project_id: str) -> Verifier:
    from platform_service import auth as platform_auth

    transport = CertificateRequest()

    def verify(token: str) -> "dict[str, Any]":
        identity = platform_auth.verify_client_token(token, certificate_request=transport)
        if identity.project_id != project_id:
            raise ValueError("token is for another project")
        return {"sub": identity.uid, "company": project_id}

    return verify


def directory_verifier(store: Any, clock: Callable[[], float] = time.monotonic) -> Verifier:
    from fastapi import HTTPException
    from platform_service import auth as platform_auth
    from platform_service.tenancy import resolve_tenant

    transport = CertificateRequest()
    known: "dict[tuple[str, Optional[str]], tuple[float, str, str]]" = {}
    refused: "dict[tuple[str, Optional[str]], tuple[float, int, str]]" = {}
    lookups: "dict[tuple[str, Optional[str]], Future]" = {}
    lock = threading.Lock()

    def look_up(identity: Any, key: "tuple[str, Optional[str]]", future: Future) -> None:
        try:
            record = resolve_tenant(identity, store, access_for=None).record
            known[key] = (clock() + DIRECTORY_CACHE_SECONDS, record["location"]["databaseId"], record["tenantId"])
            future.set_result(known[key])
        except HTTPException as error:
            if error.status_code == 403:
                refused[key] = (clock() + DIRECTORY_CACHE_SECONDS, error.status_code, str(error.detail))
            future.set_exception(error)
        except Exception as error:
            future.set_exception(error)
        finally:
            with lock:
                lookups.pop(key, None)

    def verify(token: str) -> "dict[str, Any]":
        identity = platform_auth.verify_client_token(token, certificate_request=transport)
        key = (identity.project_id, identity.auth_tenant_id)
        denied = refused.get(key)
        if denied is not None and denied[0] > clock():
            raise Rejected(denied[1], denied[2])
        cached = known.get(key)
        if cached is None or cached[0] <= clock():
            with lock:
                future = lookups.get(key)
                if future is None:
                    future = lookups[key] = Future()
                    threading.Thread(target=look_up, args=(identity, key, future), daemon=True).start()
            try:
                cached = future.result(timeout=_firestore_timeout())
            except HTTPException as error:
                raise Rejected(error.status_code, str(error.detail)) from None
            except Exception:
                raise Rejected(503, "the company directory could not be checked") from None
        return {"sub": identity.uid, "scope": (identity.project_id, cached[1]), "company": cached[2]}

    return verify


def _decode(value: "dict[str, Any]") -> Any:
    if "stringValue" in value:
        return value["stringValue"]
    if "booleanValue" in value:
        return value["booleanValue"]
    if "integerValue" in value:
        return int(value["integerValue"])
    if "doubleValue" in value:
        return float(value["doubleValue"])
    if "arrayValue" in value:
        return [_decode(v) for v in value["arrayValue"].get("values", [])]
    if "mapValue" in value:
        return {k: _decode(v) for k, v in value["mapValue"].get("fields", {}).items()}
    return None


def _decode_fields(fields: "dict[str, Any]") -> "dict[str, Any]":
    return {key: _decode(value) for key, value in fields.items()}


def _text(data: "dict[str, Any]", camel: str, snake: str) -> str:
    for key in (camel, snake):
        if isinstance(data.get(key), str):
            return data[key]
    return ""


def _first_present(data: "dict[str, Any]", keys: "tuple[str, ...]", default: Any) -> Any:
    for key in keys:
        if key in data:
            return data[key]
    return default


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _has_active_status(data: "dict[str, Any]") -> bool:
    flag = _first_present(data, ("isActive", "is_active", "active", "enabled"), True)
    flag_ok = (
        flag is True
        or (_is_number(flag) and flag == 1)
        or (isinstance(flag, str) and flag.lower() in ("true", "1", "yes"))
        or (flag is None and data.get("active") is True)
    )
    status = _first_present(data, ("status", "accountStatus", "account_status"), "active")
    return flag_ok and isinstance(status, str) and status in ("active", "Active")


def _canonical_role(value: str) -> str:
    role = value.lower().replace(" ", "_")
    return {"administrator": "admin", "sales_representative": "salesman"}.get(role, role)


def _is_v2(version: Any) -> bool:
    return _is_number(version) and version == 2


def linked_profile_id(access: "dict[str, Any]") -> Optional[str]:
    if access.get("accessVersion") is not None:
        return None
    if "userDocId" not in access and "user_doc_id" not in access:
        return None
    return _text(access, "userDocId", "user_doc_id") or None


def dashboard_access_allowed(uid: str, access: "dict[str, Any]", profile: "Optional[dict[str, Any]]") -> bool:
    version = access.get("accessVersion")
    if _is_v2(version):
        return (
            access.get("uid", "") == uid
            and access.get("status", "") == "active"
            and access.get("disabledReasons", []) == []
            and access.get("role", "") in COPILOT_ROLES
            and isinstance(access.get("branchId", ""), str)
            and isinstance(access.get("employeeCode", ""), str)
        )
    if version is not None:
        return False
    if access.get("uid", uid) != uid or access.get("user_uid", uid) != uid or not _has_active_status(access):
        return False
    actor = access
    if "userDocId" in access or "user_doc_id" in access:
        if linked_profile_id(access) is None or profile is None:
            return False
        if not _has_active_status(profile):
            return False
        if ("uid" in profile or "userUid" in profile) and _text(profile, "uid", "userUid") != uid:
            return False
        actor = profile
    return _canonical_role(_text(actor, "role", "user_group")) in COPILOT_ROLES


def firestore_access_check(project_id: str, base_url: str = "https://firestore.googleapis.com",
                           database_id: str = "(default)") -> AccessCheck:
    import urllib.error
    import urllib.parse
    import urllib.request

    root = f"{base_url}/v1/projects/{project_id}/databases/{database_id}/documents"

    def read(token: str, path: str) -> "Optional[dict[str, Any]]":
        request = urllib.request.Request(
            f"{root}/{path}", headers={"Authorization": f"Bearer {token}"}
        )
        try:
            response = http_deadline.request_bytes(request, timeout=5)
            return _decode_fields(json.loads(response.data).get("fields", {}))
        except urllib.error.HTTPError as error:
            if error.code in (403, 404):
                return None
            raise

    def check(token: str, uid: str) -> "bool | str":
        access = read(token, "user_access/" + urllib.parse.quote(uid, safe=""))
        if access is None:
            return False
        profile_id = linked_profile_id(access)
        profile = None if profile_id is None else read(token, "users/" + urllib.parse.quote(profile_id, safe=""))
        if not dashboard_access_allowed(uid, access, profile):
            return False
        actor = profile if profile is not None else access
        role = access.get("role", "") if _is_v2(access.get("accessVersion")) else _canonical_role(_text(actor, "role", "user_group"))
        return "salesman" if role == "salesman" else True

    return check


def directory_access_check() -> AccessCheck:
    checks: "dict[tuple[str, str], AccessCheck]" = {}

    def check(token: str, uid: str, scope: "tuple[str, str]") -> "bool | str":
        if scope not in checks:
            checks[scope] = firestore_access_check(scope[0], database_id=scope[1])
        return checks[scope](token, uid)

    return check


def _directory_store() -> Any:
    from google.cloud import firestore
    from platform_service import config as platform_config
    from platform_service.directory import DirectoryStore
    from platform_service.signing import Keyring

    return DirectoryStore(
        firestore.Client(project=platform_config.PLATFORM_PROJECT_ID), keyring=Keyring.from_environment()
    )


def _setting(name: str, default: "Optional[str]", kind: type) -> Any:
    raw = os.environ.get(name) if default is None else os.environ.get(name, default)
    if raw is None or not raw.strip():
        raise ValueError(f"{name} is required and must not be blank")
    try:
        value = kind(raw.strip())
    except ValueError:
        raise ValueError(f"{name} must be a valid {kind.__name__}") from None
    if kind is float and not math.isfinite(value):
        raise ValueError(f"{name} must be finite")
    return value


def _configured_state() -> State:
    directory_mode = bool(os.environ.get("PLATFORM_PUBLIC_KEYS", "").strip())
    project = "" if directory_mode else os.environ["FIREBASE_PROJECT_ID"].strip()
    if not directory_mode and not project:
        raise ValueError("FIREBASE_PROJECT_ID is required")
    threshold = _setting("COPILOT_THRESHOLD", None, float)
    body_timeout = _setting("COPILOT_BODY_TIMEOUT", "5", float)
    request_timeout = _setting("COPILOT_REQUEST_TIMEOUT", "30", float)
    max_pending = _setting("COPILOT_MAX_PENDING", "2", int)
    _validate_limits(threshold, body_timeout, request_timeout, max_pending)
    daily_limit = _setting("GEMINI_DAILY_LIMIT", str(GEMINI_DAILY_LIMIT), int)
    salesman_daily_limit = _setting("GEMINI_DAILY_LIMIT_SALESMAN", str(GEMINI_DAILY_LIMIT_SALESMAN), int)
    person_daily_limit = _setting("GEMINI_DAILY_LIMIT_PERSON", str(GEMINI_DAILY_LIMIT_PERSON), int)
    model_max_seconds = _setting("COPILOT_MAX_SECONDS", "8", float)
    gemini_seconds = _setting("GEMINI_MAX_SECONDS", str(GEMINI_MAX_SECONDS), float)
    gemini_max_concurrent = _setting("GEMINI_MAX_CONCURRENT", str(GEMINI_MAX_CONCURRENT), int)
    if gemini_max_concurrent < 1:
        raise ValueError("GEMINI_MAX_CONCURRENT must be at least 1")
    if not all(math.isfinite(v) and v > 0 for v in (model_max_seconds, gemini_seconds)):
        raise ValueError("COPILOT_MAX_SECONDS and GEMINI_MAX_SECONDS must be positive and finite")
    origins = {o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "").split(",") if o.strip()}
    model_enabled = os.environ.get("COPILOT_MODEL_ENABLED", "1").strip().lower() not in {"0", "false", "no"}
    if model_enabled:
        generator = model.CopilotGenerator(
            os.environ.get("MODEL_DIR", "/app/model"),
            os.environ.get("ADAPTER_DIR", "/app/adapter"),
            max_seconds=model_max_seconds,
        )
    else:
        if not os.environ.get("GEMINI_API_KEY"):
            raise ValueError("COPILOT_MODEL_ENABLED=0 needs GEMINI_API_KEY: nothing else would answer")

        def generator(text: str, pages: "list[dict[str, Any]]", actions: "list[str]") -> "tuple[str, float]":
            return "", 0.0
    fallback = None
    if os.environ.get("GEMINI_API_KEY"):
        from tools.voice.dashboard_llm.gemini_client import DEFAULT_BASE_URL, DEFAULT_MODEL, GeminiGenerator

        fallback = GeminiGenerator(
            os.environ["GEMINI_API_KEY"], os.environ.get("GEMINI_MODEL", DEFAULT_MODEL),
            base_url=os.environ.get("GEMINI_BASE_URL", "").strip() or DEFAULT_BASE_URL,
            seconds_between_calls=0, retries=0, timeout=gemini_seconds,
        )
    budget_project = os.environ.get("COPILOT_BUDGET_PROJECT", "").strip()
    budget = None
    if budget_project:
        from google.cloud import firestore

        budget = GeminiBudget(firestore.Client(project=budget_project))
    if directory_mode:
        verifier, access = directory_verifier(_directory_store()), directory_access_check()
    else:
        verifier, access = firebase_verifier(project), firestore_access_check(project)
    state = State(
        verifier, generator, threshold, origins, fallback=fallback,
        access=access,
        gemini_daily_limit=daily_limit,
        gemini_daily_limit_salesman=salesman_daily_limit,
        gemini_daily_limit_person=person_daily_limit,
        body_timeout=body_timeout,
        request_timeout=request_timeout,
        max_pending=max_pending,
        gemini_seconds=gemini_seconds,
        serialize_inference=model_enabled,
        budget=budget,
        gemini_max_concurrent=gemini_max_concurrent,
    )

    def load() -> None:
        if model_enabled:
            _ = generator.device
        state.ready.set()

    threading.Thread(target=load, daemon=True).start()
    return state


class UnavailableHandler(BaseHTTPRequestHandler):
    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(5)
        self._timer = threading.Timer(5, self._abort_read)
        self._timer.daemon = True
        self._timer.start()

    def _abort_read(self) -> None:
        try:
            self.connection.shutdown(socket.SHUT_RD)
        except OSError:
            pass

    def finish(self) -> None:
        self._timer.cancel()
        super().finish()

    def log_message(self, *_: Any) -> None:
        pass

    def do_GET(self) -> None:
        self.close_connection = True
        body = b'{"ready":false}'
        self.send_response(503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_OPTIONS = do_GET


def main() -> None:
    port = _setting("PORT", "8080", int)
    host = os.environ.get("COPILOT_HOST", "127.0.0.1")
    state = None
    try:
        state = _configured_state()
        handler = make_handler(state)
    except (KeyError, ValueError, GoogleAuthError) as error:
        print("Scout configuration is unavailable; serving not-ready responses.", file=sys.stderr)
        if isinstance(error, ValueError):
            print(error, file=sys.stderr)
        handler = UnavailableHandler
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        Server((host, port), handler).serve_forever()
    finally:
        if state is not None:
            state.close()


if __name__ == "__main__":
    main()

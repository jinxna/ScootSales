from __future__ import annotations

import http.client
import io
import select
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from contextvars import ContextVar
from dataclasses import dataclass
from typing import Mapping, Optional

REQUEST_DEADLINE: ContextVar[Optional[float]] = ContextVar('request_deadline', default=None)
MAX_REPLY = 2 * 1024 * 1024
IDLE_SECONDS = 30.0
MAX_IDLE_PER_HOST = 4
_POOL_LOCK = threading.Lock()
_IDLE: 'dict[tuple, list[tuple[float, http.client.HTTPConnection]]]' = {}


@dataclass(frozen=True)
class Reply:
    status: int
    data: bytes
    headers: Mapping[str, str]


class _StaleConnection(Exception):
    pass


def _take(key: tuple) -> Optional[http.client.HTTPConnection]:
    now = time.monotonic()
    with _POOL_LOCK:
        entries = _IDLE.get(key, [])
        live = [(since, connection) for since, connection in entries if now - since <= IDLE_SECONDS]
        expired = [connection for since, connection in entries if now - since > IDLE_SECONDS]
        taken = live.pop()[1] if live else None
        _IDLE[key] = live
    for connection in expired:
        connection.close()
    return taken


def _closed_by_peer(connection: http.client.HTTPConnection) -> bool:
    sock = connection.sock
    if sock is None:
        return True
    try:
        return bool(select.select([sock], [], [], 0)[0])
    except (OSError, ValueError):
        return True


def _give(key: tuple, connection: http.client.HTTPConnection) -> None:
    with _POOL_LOCK:
        entries = _IDLE.setdefault(key, [])
        if len(entries) < MAX_IDLE_PER_HOST:
            entries.append((time.monotonic(), connection))
            return
    connection.close()


def _exchange(connection: http.client.HTTPConnection, reused: bool, key: tuple, request: urllib.request.Request,
              url: urllib.parse.SplitResult, end: float) -> Reply:
    phase = ['connect']

    def remaining() -> float:
        value = end - time.monotonic()
        if value <= 0:
            raise TimeoutError(f'Upstream request deadline exceeded phase={phase[0]}')
        return value

    active_socket = [connection.sock]
    expired = threading.Event()
    guard = threading.Lock()
    finished = [False]

    def abort() -> None:
        with guard:
            if finished[0]:
                return
            expired.set()
            sock = active_socket[0] or connection.sock
            if sock is not None:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    timer = threading.Timer(remaining(), abort)
    timer.daemon = True
    timer.start()
    response = None
    answered = False
    sent = False
    reusable = False
    try:
        if connection.sock is None:
            connection.timeout = remaining()
            connection.connect()
        active_socket[0] = connection.sock
        phase[0] = 'send'
        active_socket[0].settimeout(remaining())
        path = urllib.parse.urlunsplit(('', '', url.path or '/', url.query, ''))
        connection.request(request.get_method(), path, body=request.data, headers=dict(request.header_items()))
        sent = True
        phase[0] = 'wait'
        active_socket[0].settimeout(remaining())
        response = connection.getresponse()
        answered = True
        phase[0] = 'read'
        remaining()
        chunks = []
        size = 0
        while not response.isclosed():
            active_socket[0].settimeout(remaining())
            chunk = response.read1(min(65536, MAX_REPLY + 1 - size))
            remaining()
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_REPLY:
                raise ValueError('Upstream response exceeds size limit')
            chunks.append(chunk)
        if not response.isclosed() and response.length == 0:
            response.read()
        body = b''.join(chunks)
        reusable = response.isclosed() and not response.will_close
        if response.status >= 300:
            raise urllib.error.HTTPError(request.full_url, response.status, response.reason,
                                         response.headers, io.BytesIO(body))
        return Reply(response.status, body, response.headers)
    except (OSError, http.client.HTTPException) as error:
        if expired.is_set() or (isinstance(error, TimeoutError) and error.errno is None) or time.monotonic() >= end:
            raise TimeoutError(f'Upstream request deadline exceeded phase={phase[0]}') from None
        if reused and not answered and (not sent or request.get_method() == 'GET'):
            raise _StaleConnection from None
        raise
    finally:
        with guard:
            finished[0] = True
        timer.cancel()
        if response is not None:
            response.close()
        if reusable and not expired.is_set():
            _give(key, connection)
        else:
            connection.close()


def request_bytes(request: urllib.request.Request, *, timeout: float,
                  deadline: Optional[float] = None) -> Reply:
    end = min(value for value in (time.monotonic() + timeout, deadline, REQUEST_DEADLINE.get())
              if value is not None)
    url = urllib.parse.urlsplit(request.full_url)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password:
        raise ValueError('Invalid upstream URL')
    key = (url.scheme, url.hostname, url.port)
    pooled = _take(key)
    if pooled is not None and _closed_by_peer(pooled):
        pooled.close()
        pooled = None
    if pooled is not None:
        try:
            return _exchange(pooled, True, key, request, url, end)
        except _StaleConnection:
            pass
    connection_type = http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection
    if end - time.monotonic() <= 0:
        raise TimeoutError('Upstream request deadline exceeded phase=connect')
    return _exchange(connection_type(url.hostname, url.port, timeout=end - time.monotonic()), False, key, request, url, end)

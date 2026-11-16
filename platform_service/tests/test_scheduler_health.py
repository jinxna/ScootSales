from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from fastapi import FastAPI
from fastapi.testclient import TestClient

from platform_service import client_api, config
from platform_service.scheduler import LEASES


def stamp(moment: datetime) -> str:
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


class FakeLeases:
    def __init__(self, documents: dict[str, dict]):
        self.documents = documents

    def collection(self, name: str):
        assert name == LEASES
        return self

    def stream(self, **options):
        return [SimpleNamespace(id=name, to_dict=lambda data=data: dict(data)) for name, data in self.documents.items()]


def health(monkeypatch, documents: dict[str, dict], *, local: bool):
    monkeypatch.setattr(client_api, "HEALTH_CACHE_SECONDS", 0)
    monkeypatch.setattr(client_api, "check_client_ip_header", lambda: None)
    monkeypatch.setattr(config, "CLIENT_CORS_ORIGINS", ())
    app = FastAPI()
    client_api.install_client_routes(
        app, directory=None, database=FakeLeases(documents), access_for=None, plans=None)
    caller = ("127.0.0.1", 50000) if local else ("203.0.113.9", 50000)
    return TestClient(app, client=caller).get("/health")


def test_ops01_health_names_a_scheduler_job_that_failed_or_stopped_running_and_hides_the_error(monkeypatch):
    now = datetime.now(timezone.utc)
    ran = {"lastStatus": "ran", "lastRunAt": stamp(now - timedelta(seconds=30)),
           "nextRunAt": stamp(now + timedelta(seconds=30)), "lastError": None}
    failed = {"lastStatus": "failed", "lastRunAt": stamp(now - timedelta(seconds=30)),
              "nextRunAt": stamp(now + timedelta(seconds=270)),
              "lastError": "RuntimeError: company acme-sdn-bhd rejected key k-123"}
    stopped = {"lastStatus": "ran", "lastRunAt": stamp(now - timedelta(days=2)),
               "nextRunAt": stamp(now - timedelta(days=1)), "leaseExpiresAt": None}
    running = {"lastStatus": "ran", "lastRunAt": stamp(now - timedelta(days=1)),
               "nextRunAt": stamp(now - timedelta(hours=2)), "leaseExpiresAt": stamp(now + timedelta(minutes=5))}
    legacy = {"lastRunAt": stamp(now - timedelta(days=3))}
    odd = {"lastStatus": "ran", "lastRunAt": now - timedelta(days=2),
           "nextRunAt": (now - timedelta(days=1)).replace(tzinfo=None).isoformat(),
           "leaseExpiresAt": (now - timedelta(days=1)).replace(tzinfo=None).isoformat()}

    healthy = health(monkeypatch, {"mail": ran, "running": running, "legacy": legacy, "odd": odd}, local=True)
    assert healthy.status_code == 200
    assert healthy.json()["status"] == "ok"
    assert healthy.json()["scheduler"] == {"status": "ok", "degradedJobs": []}

    for local in (False, True):
        broken = health(monkeypatch, {"mail": ran, "purge": failed, "renew": stopped, "legacy": legacy}, local=local)
        body = broken.json()
        assert broken.status_code == 200
        assert body["status"] == "ok" and body["checks"] == {"firestore": "ok"}
        expected = {"status": "degraded", "degradedJobs": ["purge", "renew"]} if local else {"status": "degraded"}
        assert body["scheduler"] == expected
        assert "acme" not in broken.text and "k-123" not in broken.text and "RuntimeError" not in broken.text

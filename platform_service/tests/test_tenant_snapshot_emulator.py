from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone

import pytest
from google.api_core.datetime_helpers import DatetimeWithNanoseconds
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore
from google.cloud.firestore_v1 import GeoPoint

from platform_service import access_migration, migrate_seats, tenant_snapshot

from platform_service.company_access import project_auth

from .test_tenant_readiness_emulator import add_shape, fingerprint, put, seed_world

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Needs the Firestore and Auth emulators.",
)


@pytest.fixture
def project():
    return f"demo-snapshot-{uuid.uuid4().hex[:10]}"


@pytest.fixture
def db(project):
    return firestore.Client(project=project, credentials=AnonymousCredentials())


@pytest.fixture
def auth(project):
    return project_auth(project)


@pytest.fixture
def world(db, auth):
    seed_world(db, auth)
    add_shape(db, auth, "userGroupRole")
    return db


def decoded_documents(db, snapshot, collections=("user_access", "users")):
    return {path: tenant_snapshot.decode(entry["data"], db) for path, entry in snapshot.documents.items()
            if path.split("/")[0] in collections}


def live_documents(db, collections=("user_access", "users")):
    return {f"{name}/{item.id}": item.to_dict() for name in collections for item in db.collection(name).stream()}


def move(db):
    migrate_seats.apply_migration(db, migrate_seats.plan_migration(db))
    access_migration.apply_migration(db)


def saved_file(db, tmp_path):
    path = tmp_path / "snapshot.json"
    tenant_snapshot.write_file(tenant_snapshot.save(db), path)
    return path


def restore(project, path, *extra):
    return tenant_snapshot.main(["restore", "--project", project, "--from", str(path), *extra])


def test_every_firestore_type_survives_json(db):
    when = datetime(2026, 3, 4, 5, 6, 7, 123456, tzinfo=timezone.utc)
    put(db, "config", "typed", {
        "when": when, "point": GeoPoint(1.5, 110.25), "ref": db.document("users/S0001"), "raw": b"\x00\xffabc",
        "nested": {"a": [1, 2.5, {"b": None}], "$ref": "looks-like-a-tag", "flag": True}, "nan": float("nan"),
        "list": ["x", 3, False], "big": 2 ** 40, "empty": {}, "text": "ok",
    })
    stored = db.collection("config").document("typed").get().to_dict()
    again = tenant_snapshot.decode(json.loads(json.dumps(tenant_snapshot.encode(stored))), db)
    assert tenant_snapshot.encode(again) == tenant_snapshot.encode(stored)
    assert isinstance(again["when"], DatetimeWithNanoseconds) and again["when"] == when
    assert again["point"] == GeoPoint(1.5, 110.25) and again["ref"].path == "users/S0001"
    assert again["raw"] == b"\x00\xffabc" and again["nested"]["$ref"] == "looks-like-a-tag"
    assert again["nan"] != again["nan"] and type(again["big"]) is int and type(again["nested"]["a"][1]) is float


def test_save_changes_nothing_and_copies_only_three_collections(world, tmp_path):
    before = fingerprint(world)
    path = saved_file(world, tmp_path)
    assert fingerprint(world) == before
    saved = tenant_snapshot.read_file(path)
    assert {key.split("/")[0] for key in saved.documents} == {"user_access", "users"}
    assert len(saved.documents) == 5 + 5


def test_restore_dry_run_lists_the_move_and_writes_nothing(world, project, tmp_path, capsys):
    path = saved_file(world, tmp_path)
    move(world)
    put(world, "products", "HW-0001", {"productId": "HW-0001", "unitPrice": 99.0, "price": 99.0, "priceGuide": 99.0})
    before = fingerprint(world)
    capsys.readouterr()
    assert restore(project, path) == 0
    report = json.loads(capsys.readouterr().out)
    assert fingerprint(world) == before
    assert report["mode"] == "dry-run"
    assert "user_access/hw-s2" in report["wouldRestore"] and "users/S0001" in report["wouldRestore"]
    assert report["keptNotInSnapshot"] == ["config/usage"] and report["wouldDelete"] == []
    assert not any(item.startswith("products/") for key in report.values() if isinstance(key, list) for item in key)


def test_restore_refuses_a_wrong_or_missing_confirmation(world, project, tmp_path):
    path = saved_file(world, tmp_path)
    move(world)
    before = fingerprint(world)
    assert restore(project, path, "--apply", "--confirm-project", "demo-other") == 2
    assert restore(project, path, "--apply") == 2
    assert fingerprint(world) == before


def test_restore_refuses_a_snapshot_of_another_project(world, project, tmp_path):
    path = saved_file(world, tmp_path)
    before = fingerprint(world)
    assert restore("demo-other-project", path, "--apply", "--confirm-project", "demo-other-project") == 2
    assert fingerprint(world) == before


def test_restore_gives_back_the_saved_documents_and_leaves_products(world, project, tmp_path, capsys):
    path = saved_file(world, tmp_path)
    saved = tenant_snapshot.read_file(path)
    move(world)
    put(world, "products", "HW-0001", {"productId": "HW-0001", "unitPrice": 99.0, "price": 99.0, "priceGuide": 99.0})
    assert live_documents(world) != decoded_documents(world, saved)
    capsys.readouterr()
    assert restore(project, path, "--apply", "--confirm-project", project) == 0
    assert live_documents(world) == decoded_documents(world, saved)
    assert "accessVersion" not in world.collection("user_access").document("hw-s2").get().to_dict()
    assert world.collection("products").document("HW-0001").get().to_dict()["unitPrice"] == 99.0
    assert world.collection("config").document("usage").get().exists
    assert restore(project, path) == 0


def test_remove_move_config_deletes_what_prepare_made(world, project, tmp_path, capsys):
    path = saved_file(world, tmp_path)
    move(world)
    capsys.readouterr()
    assert restore(project, path, "--remove-move-config") == 0
    assert json.loads(capsys.readouterr().out)["wouldDelete"] == ["config/usage"]
    assert world.collection("config").document("usage").get().exists
    assert restore(project, path, "--apply", "--confirm-project", project, "--remove-move-config") == 0
    assert not world.collection("config").document("usage").get().exists


def test_a_document_changed_elsewhere_is_skipped_and_listed(world, project, tmp_path, capsys):
    path = saved_file(world, tmp_path)
    saved = tenant_snapshot.read_file(path)
    move(world)
    world.collection("users").document("S0001").update({"name": "Renamed after the move"})
    capsys.readouterr()
    assert restore(project, path, "--apply", "--confirm-project", project) == 3
    report = json.loads(capsys.readouterr().out)
    assert report["skippedChangedElsewhere"] == {"users/S0001": ["name"]}
    kept = world.collection("users").document("S0001").get().to_dict()
    assert kept["name"] == "Renamed after the move" and kept["seatClass"] == "salesman" and kept["seatHeld"] is True
    others = {key: value for key, value in decoded_documents(world, saved).items() if key != "users/S0001"}
    assert {key: value for key, value in live_documents(world).items() if key != "users/S0001"} == others


def test_save_stops_when_the_read_budget_is_too_small(world, project, tmp_path):
    target = tmp_path / "never.json"
    assert tenant_snapshot.main(["save", "--project", project, "--out", str(target), "--max-reads", "1"]) == 2
    assert not target.exists()
    assert tenant_snapshot.main(["save", "--project", project, "--out", str(target)]) == 0
    assert target.exists()


def test_a_config_document_changed_after_the_move_is_skipped_not_overwritten(world, project, tmp_path, capsys):
    put(world, "config", "usage", {"seatsUsed": 1, "ordersThisMonth": 10})
    path = saved_file(world, tmp_path)
    world.collection("config").document("usage").set({"seatsUsed": 4, "ordersThisMonth": 250})
    capsys.readouterr()
    assert restore(project, path, "--apply", "--confirm-project", project) == 3
    report = json.loads(capsys.readouterr().out)
    assert "config/usage" in report["skippedChangedElsewhere"]
    assert "config/usage" not in report["wouldRestore"]
    assert world.collection("config").document("usage").get().to_dict() == {"seatsUsed": 4, "ordersThisMonth": 250}


def test_the_snapshot_records_the_database_and_restore_refuses_another_one(world, project, tmp_path):
    path = saved_file(world, tmp_path)
    body = json.loads(path.read_text(encoding="utf-8"))
    assert body["database"] == "(default)"
    body["database"] = "other-database"
    path.write_text(json.dumps(body), encoding="utf-8")
    before = fingerprint(world)
    assert restore(project, path, "--apply", "--confirm-project", project) == 2
    assert fingerprint(world) == before


@pytest.mark.parametrize("drop", ["project", "takenAt", "database", "documents"])
def test_a_snapshot_file_with_a_missing_part_is_refused_cleanly(world, project, tmp_path, drop):
    path = saved_file(world, tmp_path)
    body = json.loads(path.read_text(encoding="utf-8"))
    del body[drop]
    path.write_text(json.dumps(body), encoding="utf-8")
    assert restore(project, path) in (1, 2)


def test_a_snapshot_file_with_a_document_of_the_wrong_shape_is_refused_cleanly(world, project, tmp_path):
    path = saved_file(world, tmp_path)
    body = json.loads(path.read_text(encoding="utf-8"))
    body["documents"]["users/S0001"] = {"data": "not a map"}
    path.write_text(json.dumps(body), encoding="utf-8")
    assert restore(project, path) in (1, 2)


def test_the_save_estimate_counts_the_documents_it_streams(world, project, tmp_path):
    target = tmp_path / "never.json"
    assert tenant_snapshot.main(["save", "--project", project, "--out", str(target), "--max-reads", "8"]) == 2
    assert not target.exists()


def test_a_timestamp_before_1970_round_trips(db):
    when = datetime(1960, 5, 6, 7, 8, 9, tzinfo=timezone.utc)
    put(db, "config", "old", {"when": when})
    stored = db.collection("config").document("old").get().to_dict()
    again = tenant_snapshot.decode(json.loads(json.dumps(tenant_snapshot.encode(stored))), db)
    assert again["when"] == when

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any

import pytest

SCRIPT_PATH = (
    Path(__file__).resolve().parents[2]
    / "admin_dashboard"
    / "scripts"
    / "backfill_order_identity.py"
)


def _load_module() -> Any:
    spec = importlib.util.spec_from_file_location(
        "backfill_order_identity", SCRIPT_PATH
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


backfill = _load_module()


class _Snapshot:
    def __init__(self, doc_id: str, data: dict[str, Any]) -> None:
        self.id = doc_id
        self._data = data

    def to_dict(self) -> dict[str, Any]:
        return dict(self._data)


class _Query:
    def __init__(self, rows: list[_Snapshot]) -> None:
        self._rows = rows
        self._cap: int | None = None

    def limit(self, cap: int) -> "_Query":
        self._cap = cap
        return self

    def stream(self) -> list[_Snapshot]:
        if self._cap is None:
            return list(self._rows)
        return list(self._rows)[: self._cap]


class _Collection:
    def __init__(self, rows: dict[str, dict[str, Any]]) -> None:
        self._rows = rows

    def _snapshots(self) -> list[_Snapshot]:
        return [_Snapshot(doc_id, data) for doc_id, data in sorted(self._rows.items())]

    def stream(self) -> list[_Snapshot]:
        return self._snapshots()

    def limit(self, cap: int) -> _Query:
        return _Query(self._snapshots()).limit(cap)


class _Batch:
    def __init__(self, db: "_FakeDb") -> None:
        self._db = db
        self._pending: list[tuple[str, dict[str, Any]]] = []

    def set(self, reference: Any, payload: dict[str, Any], merge: bool = False) -> None:
        self._pending.append((reference.doc_id, dict(payload)))

    def commit(self) -> None:
        for doc_id, payload in self._pending:
            self._db.collections["orders"].setdefault(doc_id, {}).update(payload)
            self._db.writes.append((doc_id, payload))
        self._pending = []


class _DocumentReference:
    def __init__(self, doc_id: str) -> None:
        self.doc_id = doc_id


class _CollectionReference(_Collection):
    def document(self, doc_id: str) -> _DocumentReference:
        return _DocumentReference(doc_id)


class _FakeDb:
    def __init__(self, collections: dict[str, dict[str, dict[str, Any]]]) -> None:
        self.collections = collections
        self.writes: list[tuple[str, dict[str, Any]]] = []

    def collection(self, name: str) -> _CollectionReference:
        return _CollectionReference(self.collections.setdefault(name, {}))

    def batch(self) -> _Batch:
        return _Batch(self)


def _profile(uid: str, code: str, *, branch: str = "B1", **extra: Any) -> dict[str, Any]:
    return {
        "docId": uid,
        "collection": "users",
        "uid": uid,
        "employeeCode": code,
        "branchId": branch,
        **extra,
    }


def test_stamps_an_order_whose_code_resolves_to_one_profile() -> None:
    decisions = backfill.plan_identity_backfill(
        [{"docId": "ORD-1", "staffId": "S001"}],
        [_profile("uid-1", "S001")],
    )

    assert [(row.action, row.reason, row.uid) for row in decisions] == [
        ("stamp", "stamped", "uid-1")
    ]


def test_skips_orders_that_already_carry_the_owner_key() -> None:
    decisions = backfill.plan_identity_backfill(
        [{"docId": "ORD-1", "staffId": "S001", "salesmanUid": "uid-9"}],
        [_profile("uid-1", "S001")],
    )

    assert decisions[0].action == "skip"
    assert decisions[0].reason == "already_has_owner"


def test_skips_every_order_it_cannot_attribute_unambiguously() -> None:
    orders = [
        {"docId": "ORD-none", "salesmanName": "No Code"},
        {"docId": "ORD-unresolved", "staffId": "S404"},
        {"docId": "ORD-ambiguous", "staffId": "S002"},
        {"docId": "ORD-branch", "staffId": "S003", "branchId": "B2"},
        {"docId": "ORD-demo", "staffId": "S001", "isDemo": True},
    ]
    profiles = [
        _profile("uid-1", "S001"),
        _profile("uid-a", "S002"),
        _profile("uid-b", "S002"),
        _profile("uid-3", "S003", branch="B1"),
    ]

    decisions = backfill.plan_identity_backfill(orders, profiles)

    assert {row.order_id: row.reason for row in decisions} == {
        "ORD-none": "no_employee_code",
        "ORD-unresolved": "unresolved_code",
        "ORD-ambiguous": "ambiguous_code",
        "ORD-branch": "branch_mismatch",
        "ORD-demo": "demo_record",
    }
    assert all(row.action == "skip" for row in decisions)


def test_a_code_carried_under_any_spelling_resolves() -> None:
    decisions = backfill.plan_identity_backfill(
        [
            {"docId": "ORD-1", "employeeCode": "S001"},
            {"docId": "ORD-2", "salesmanCode": "S001"},
            {"docId": "ORD-3", "salesman_code": "S001"},
        ],
        [_profile("uid-1", "S001")],
    )

    assert [row.action for row in decisions] == ["stamp", "stamp", "stamp"]


def test_an_access_index_is_matched_by_its_document_id() -> None:
    decisions = backfill.plan_identity_backfill(
        [{"docId": "ORD-1", "staffId": "S001"}],
        [
            {
                "docId": "firebase-uid-000000000001",
                "collection": "user_access",
                "employeeCode": "S001",
            }
        ],
    )

    assert decisions[0].action == "stamp"
    assert decisions[0].uid == "firebase-uid-000000000001"


def _db() -> _FakeDb:
    return _FakeDb(
        {
            "orders": {
                "ORD-1": {"staffId": "S001", "status": "submitted"},
                "ORD-2": {"staffId": "S404"},
                "ORD-3": {"salesmanUid": "uid-1", "staffId": "S001"},
            },
            "users": {"uid-1": {"uid": "uid-1", "employeeCode": "S001", "branchId": "B1"}},
            "user_access": {},
        }
    )


def test_apply_writes_only_identity_keys_and_its_provenance(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db = _db()
    monkeypatch.setattr(backfill, "create_firestore_client", lambda *a, **k: db)

    assert backfill.main(["--apply", "--project", "demo", "--confirm", "APPLY-demo-fyp-a"]) == 0

    written = {doc_id: fields for doc_id, fields in db.writes}
    assert set(written) == {"ORD-1", "ORD-2", "ORD-3"}
    assert written["ORD-1"]["salesmanUid"] == "uid-1"
    assert written["ORD-1"]["salesmanCode"] == "S001"
    assert written["ORD-1"]["identityBackfill"] == backfill.BACKFILL_VERSION
    assert set(written["ORD-1"]) == {
        "salesmanUid",
        "salesmanCode",
        "identityBackfill",
        "identityBackfilledAt",
    }
    assert "salesmanUid" not in written["ORD-2"]
    assert written["ORD-2"]["salesmanCode"] == "S404"
    assert "salesmanUid" not in written["ORD-3"]
    assert db.collections["orders"]["ORD-1"]["status"] == "submitted"
    assert "salesmanUid" not in db.collections["orders"]["ORD-2"]


def test_a_second_apply_writes_nothing(monkeypatch: pytest.MonkeyPatch) -> None:
    db = _db()
    monkeypatch.setattr(backfill, "create_firestore_client", lambda *a, **k: db)

    backfill.main(["--apply", "--project", "demo", "--confirm", "APPLY-demo-fyp-a"])
    first_run = list(db.writes)
    db.writes.clear()
    backfill.main(["--apply", "--project", "demo", "--confirm", "APPLY-demo-fyp-a"])

    assert first_run
    assert db.writes == []


def test_dry_run_is_the_default_and_writes_nothing(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    db = _db()
    monkeypatch.setattr(backfill, "create_firestore_client", lambda *a, **k: db)

    assert backfill.main([]) == 0

    assert db.writes == []
    assert "DRY RUN" in capsys.readouterr().out


@pytest.mark.parametrize(
    "argv",
    [
        ["--apply"],
        ["--apply", "--project", "demo"],
        ["--apply", "--project", "demo", "--confirm", "APPLY-cos40005"],
        ["--apply", "--project", "dev", "--confirm", "APPLY-dev"],
        ["--dry-run", "--confirm", "APPLY-demo-fyp-a"],
    ],
)
def test_write_needs_the_project_bound_confirmation(argv: list[str]) -> None:
    with pytest.raises(SystemExit):
        backfill.main(argv)

from __future__ import annotations

from typing import Any, Mapping, Sequence

SYNTHETIC_DATA_ORIGIN = "synthetic_history"


def is_synthetic_history(record: Mapping[str, Any]) -> bool:
    batch_id = record.get("syntheticBatchId")
    if batch_id is not None and str(batch_id).strip():
        return True
    return str(record.get("dataOrigin") or "").strip() == SYNTHETIC_DATA_ORIGIN


def exclude_synthetic_history(
    snapshot: Mapping[str, Sequence[Mapping[str, Any]]],
) -> tuple[dict[str, list[Any]], dict[str, Any]]:
    clean: dict[str, list[Any]] = {}
    excluded: dict[str, int] = {}
    for collection, rows in snapshot.items():
        kept: list[Any] = []
        for row in rows or []:
            if isinstance(row, Mapping) and is_synthetic_history(row):
                excluded[collection] = excluded.get(collection, 0) + 1
            else:
                kept.append(row)
        clean[collection] = kept
    report = {
        "rule": "drop records with non-empty syntheticBatchId or "
        f"dataOrigin == {SYNTHETIC_DATA_ORIGIN!r}",
        "excludedTotal": sum(excluded.values()),
        "excludedByCollection": dict(sorted(excluded.items())),
    }
    return clean, report

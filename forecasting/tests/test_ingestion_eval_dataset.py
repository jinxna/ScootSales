from __future__ import annotations

import csv
from pathlib import Path

import pytest

from forecasting.ingestion.eval_dataset import (
    build_provenance,
    build_snapshot,
    read_order_lines,
    snapshot_stats,
    write_snapshot,
)

HEADER = [
    "outletCode",
    "outletName",
    "supplierCode",
    "deliveryDate",
    "barcode",
    "productName",
    "orderQty",
    "unitPrice",
    "sourceFile",
    "sheetName",
]


def _write_csv(path: Path, rows: list[list[str]]) -> Path:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(HEADER)
        writer.writerows(rows)
    return path


def test_read_order_lines_parses_rows_and_sorts_them(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [
            ["B", "Bee", "K", "2026-03-02", "111", "Prod A", "5", "2.50", "f.xlsx", "B"],
            ["A", "Ay", "K", "2026-03-01", "222", "Prod B", "3", "1.10", "f.xlsx", "A"],
        ],
    )
    lines = read_order_lines(path)
    assert [line.outlet_code for line in lines] == ["A", "B"]
    assert lines[0].quantity == 3
    assert lines[0].unit_price == pytest.approx(1.10)


def test_read_order_lines_skips_unusable_rows(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [
            ["A", "Ay", "K", "2026-03-01", "222", "Prod B", "0", "1.10", "f", "A"],
            ["A", "Ay", "K", "2026-03-01", "", "Prod C", "4", "1.10", "f", "A"],
            ["A", "Ay", "K", "not-a-date", "333", "Prod D", "4", "1.10", "f", "A"],
        ],
    )
    assert read_order_lines(path) == []


def test_read_order_lines_rejects_a_missing_column(tmp_path: Path) -> None:
    path = tmp_path / "bad.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["outletCode", "deliveryDate"])
    with pytest.raises(ValueError) as error:
        read_order_lines(path)
    assert "barcode" in str(error.value)


def test_snapshot_groups_lines_into_one_order_per_day(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [
            ["A", "Ay", "K", "2026-03-01", "111", "Prod A", "5", "2.00", "f.xlsx", "A"],
            ["A", "Ay", "K", "2026-03-01", "222", "Prod B", "3", "1.00", "f.xlsx", "A"],
            ["A", "Ay", "K", "2026-03-02", "111", "Prod A", "2", "2.00", "f.xlsx", "A"],
        ],
    )
    snapshot = build_snapshot(read_order_lines(path))
    assert len(snapshot["orders"]) == 2
    first = snapshot["orders"][0]
    assert first["retailerId"] == "A"
    assert first["status"] == "submitted"
    assert first["isDemo"] is False
    assert len(first["items"]) == 2


def test_snapshot_uses_the_median_observed_price_per_product(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [
            ["A", "Ay", "K", "2026-03-01", "111", "Prod A", "5", "2.00", "f", "A"],
            ["A", "Ay", "K", "2026-03-02", "111", "Prod A", "5", "4.00", "f", "A"],
            ["A", "Ay", "K", "2026-03-03", "111", "Prod A", "5", "3.00", "f", "A"],
        ],
    )
    snapshot = build_snapshot(read_order_lines(path))
    assert len(snapshot["products"]) == 1
    assert snapshot["products"][0]["unitPrice"] == pytest.approx(3.00)
    assert snapshot["products"][0]["priceSampleCount"] == 3


def test_snapshot_order_ids_are_deterministic(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [["A", "Ay", "K", "2026-03-01", "111", "Prod A", "5", "2.00", "f", "A"]],
    )
    first = build_snapshot(read_order_lines(path))
    second = build_snapshot(read_order_lines(path))
    assert first == second


def test_provenance_records_the_real_range_and_counts(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [
            ["A", "Ay", "K", "2026-03-01", "111", "Prod A", "5", "2.00", "f", "A"],
            ["B", "Bee", "K", "2026-04-01", "222", "Prod B", "3", "1.00", "f", "B"],
        ],
    )
    lines = read_order_lines(path)
    provenance = build_provenance(
        lines, source_path=path, ingest_summary={"rawLines": 2}
    )
    assert provenance["evidence"] == "real"
    assert provenance["outletCount"] == 2
    assert provenance["barcodeCount"] == 2
    assert provenance["dateRange"] == {"start": "2026-03-01", "end": "2026-04-01"}
    assert provenance["distinctDeliveryDates"] == 2


def test_write_snapshot_writes_both_files(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [["A", "Ay", "K", "2026-03-01", "111", "Prod A", "5", "2.00", "f", "A"]],
    )
    lines = read_order_lines(path)
    snapshot = build_snapshot(lines)
    provenance = build_provenance(lines, source_path=path)
    out = tmp_path / "eval_snapshot.json"
    write_snapshot(snapshot, provenance, out)
    assert out.is_file()
    assert (tmp_path / "eval_snapshot_provenance.json").is_file()


def test_snapshot_stats_counts_orders_items_and_products(tmp_path: Path) -> None:
    path = _write_csv(
        tmp_path / "lines.csv",
        [
            ["A", "Ay", "K", "2026-03-01", "111", "Prod A", "5", "2.00", "f", "A"],
            ["A", "Ay", "K", "2026-03-01", "222", "Prod B", "3", "1.00", "f", "A"],
        ],
    )
    stats = snapshot_stats(build_snapshot(read_order_lines(path)))
    assert stats == {"orders": 1, "products": 2, "items": 2}

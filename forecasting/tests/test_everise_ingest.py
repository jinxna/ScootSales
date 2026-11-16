from __future__ import annotations

import json
from pathlib import Path

from openpyxl import Workbook

from forecasting.ingestion import everise_ingest as ing
from forecasting.ingestion.outlet_map import OUTLET_MAP, lookup, outlet_records

HEADER = [
    "Branch",
    "Location",
    "SupplierCode",
    "DeliveryDate",
    "Product Flavour",
    "Barcode",
    "PromoGroup",
    "EntryType",
    "OrderQty",
    "FOCQty",
    "UnitPrice",
    "FuturePrice",
    "Remark",
]


def _sheet(ws, rows: list[list]) -> None:
    ws.append(HEADER)
    for row in rows:
        ws.append(row)


def _line(branch, date, product, barcode, qty, price):
    return [branch, branch, "K-0090", date, product, barcode, None, None, qty, None, price, None, "RENTAL"]


def _make_workbook(path: Path, sheets: dict[str, list[list]]) -> None:
    wb = Workbook()
    wb.remove(wb.active)
    for name, rows in sheets.items():
        ws = wb.create_sheet(title=name)
        _sheet(ws, rows)
    wb.save(path)


def test_happy_parse(tmp_path):
    path = tmp_path / "wb.xlsx"
    _make_workbook(
        path,
        {
            "4M ": [
                _line("4M", "27.03.2026", "ALL JOY CHOCO 600G", 9555592201065, 9, 8.76),
                _line("4M", "27.03.2026", "ALL JOY MILK 40S", 9555592201089, 12, 8.76),
            ]
        },
    )
    lines = list(ing.parse_workbook(path))
    assert len(lines) == 2
    first = lines[0]
    assert first.outletCode == "4M"
    assert first.deliveryDate == "2026-03-27"
    assert first.barcode == "9555592201065"
    assert first.orderQty == 9
    assert first.unitPrice == 8.76
    assert first.productName == "ALL JOY CHOCO 600G"
    assert first.sourceFile == "wb.xlsx"


def test_ddmmyyyy_parsing():
    assert ing._parse_ddmmyyyy("15.02.2025") == "2025-02-15"
    assert ing._parse_ddmmyyyy(" 01.04.2026 ") == "2026-04-01"
    assert ing._parse_ddmmyyyy("2026-04-01") is None
    assert ing._parse_ddmmyyyy("31.31.2026") is None
    assert ing._parse_ddmmyyyy(None) is None


def test_cross_file_dedupe(tmp_path):
    rows = [_line("PEN", "15.02.2025", "SEAWEED 80S", 9555196801784, 12, 11.54)]
    a = tmp_path / "a.xlsx"
    b = tmp_path / "b.xlsx"
    _make_workbook(a, {"PEN ": rows})
    _make_workbook(b, {"PEN": rows})
    combined = list(ing.parse_workbook(a)) + list(ing.parse_workbook(b))
    assert len(combined) == 2
    deduped = ing.dedupe(combined)
    assert len(deduped) == 1


def test_within_file_duplicate_tab_dedupe(tmp_path):
    rows = [_line("PMR", "16.03.2026", "TEN TEN 70G", 9556124511072, 20, 4.33)]
    path = tmp_path / "wb.xlsx"
    _make_workbook(path, {"PMR ": rows, "PMR": rows})
    deduped = ing.dedupe(list(ing.parse_workbook(path)))
    assert len(deduped) == 1


def test_shifted_column_old_tab(tmp_path):
    shifted = ["DL", "DL", "20.02.2025", "ALL JOY HAW SLICE 150G", 9555196803573, None, None, 20, None, 2.58, None, "RENTAL"]
    path = tmp_path / "wb.xlsx"
    wb = Workbook()
    wb.remove(wb.active)
    ws = wb.create_sheet(title="DL")
    ws.append(HEADER)
    ws.append(shifted)
    wb.save(path)

    lines = list(ing.parse_workbook(path))
    assert len(lines) == 1
    line = lines[0]
    assert line.deliveryDate == "2025-02-20"
    assert line.barcode == "9555196803573"
    assert line.productName == "ALL JOY HAW SLICE 150G"
    assert line.orderQty == 20


def test_missing_qty_row_skipped(tmp_path):
    path = tmp_path / "wb.xlsx"
    _make_workbook(
        path,
        {
            "4M ": [
                _line("4M", "27.03.2026", "GOOD", 9555592201065, 9, 8.76),
                _line("4M", "27.03.2026", "NO QTY", 9555592201089, None, 8.76),
                _line("4M", "27.03.2026", "ZERO QTY", 9555592201096, 0, 8.76),
            ]
        },
    )
    lines = list(ing.parse_workbook(path))
    assert len(lines) == 1
    assert lines[0].productName == "GOOD"


def test_missing_suppliercode_still_parses(tmp_path):
    row = ["PEN", "PEN", None, "15.02.2025", "SEAWEED 80S", 9555196801784, None, None, 12, None, 11.54, None, "RENTAL"]
    path = tmp_path / "wb.xlsx"
    wb = Workbook()
    wb.remove(wb.active)
    ws = wb.create_sheet(title="PEN")
    ws.append(HEADER)
    ws.append(row)
    wb.save(path)
    lines = list(ing.parse_workbook(path))
    assert len(lines) == 1
    assert lines[0].deliveryDate == "2025-02-15"
    assert lines[0].supplierCode == ""


def test_weekly_aggregation(tmp_path):
    path = tmp_path / "wb.xlsx"
    _make_workbook(
        path,
        {
            "4M ": [_line("4M", "27.03.2026", "P", 111, 9, 8.0)],
            "PMR ": [_line("PMR", "28.03.2026", "P", 111, 5, 8.0)],
        },
    )
    lines = ing.dedupe(list(ing.parse_workbook(path)))
    rows = ing.weekly_demand(lines)
    pair = {(r["outletCode"], r["orderQty"]) for r in rows if r["grain"] == "outlet_barcode"}
    assert ("4M", 9) in pair and ("PMR", 5) in pair
    barcode_rows = [r for r in rows if r["grain"] == "barcode"]
    assert len(barcode_rows) == 1
    assert barcode_rows[0]["orderQty"] == 14


def test_ingest_writes_all_artifacts(tmp_path):
    src = tmp_path / "wb.xlsx"
    _make_workbook(
        src,
        {"4M ": [_line("4M", "27.03.2026", "P", 111, 9, 8.0)]},
    )
    out = tmp_path / "out"
    summary = ing.ingest([src], out)
    assert (out / "order_lines.csv").exists()
    assert (out / "weekly_demand.csv").exists()
    written = json.loads((out / "ingest_summary.json").read_text(encoding="utf-8"))
    assert written == summary
    assert summary["dedupedLines"] == 1
    assert summary["outlets"] == 1
    assert summary["barcodes"] == 1
    assert summary["dateRange"]["start"] == "2026-03-27"


def test_iso_week_label():
    assert ing._iso_week("2026-03-27") == ing._iso_week("2026-03-28")
    assert ing._iso_week("2025-02-15").startswith("2025-W")


EXPECTED_CODES = {
    "4M", "BDC", "BK", "C1", "GHM", "KS", "MET", "MJ", "PDN", "PEN", "PMR",
    "STU", "TJ", "TJ1", "VIV", "BCC", "BMM", "MSB", "BTU", "JFV", "IMG", "DL",
}


def test_outlet_map_coords_never_verified():
    for rec in OUTLET_MAP.values():
        assert rec["coordStatus"] in {"needs_review", "missing"}
        if rec["lat"] is not None:
            assert rec["coordStatus"] == "needs_review"
        else:
            assert rec["coordStatus"] == "missing"


def test_outlet_records_and_lookup():
    records = outlet_records()
    assert len(records) == 22
    assert [r["code"] for r in records] == sorted(EXPECTED_CODES)
    assert lookup("4m")["name"].startswith("Everrise 4th Mile")
    assert lookup("nope") is None

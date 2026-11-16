from __future__ import annotations

import csv
import json
import shutil
from datetime import date, datetime
from pathlib import Path

import pytest

from forecasting.ai_core import RetailerProductSeries, WeeklyObservation, completed_week_starts
from forecasting.ai_core.patterns import analyse_series
from forecasting.ai_service.normalization import normalize_firestore_inputs
from forecasting.ai_service.replenishment import derive_replenishment
from forecasting.service import config, excel_importer

from golden_support import assert_matches_golden, case_names, load_input


def _as_of(raw: str) -> date | datetime:
    return datetime.fromisoformat(raw) if "T" in raw else date.fromisoformat(raw)


@pytest.mark.parametrize("case", case_names("normalization"))
def test_normalization_golden(request: pytest.FixtureRequest, case: str) -> None:
    data = load_input("normalization", case)
    result = normalize_firestore_inputs(
        orders=data["orders"],
        products=data["products"],
        retailers=data["retailers"],
        users=data["users"],
        as_of=_as_of(data["asOf"]),
    )
    assert_matches_golden(request, "normalization", case, result)


@pytest.mark.parametrize("case", case_names("replenishment"))
def test_replenishment_golden(request: pytest.FixtureRequest, case: str) -> None:
    data = load_input("replenishment", case)
    result = derive_replenishment(
        data["orders"],
        data["itemPatterns"],
        data["memory"],
        data["runRates"],
        date.fromisoformat(data["today"]),
    )
    assert_matches_golden(request, "replenishment", case, result)


@pytest.mark.parametrize("case", case_names("patterns"))
def test_patterns_golden(request: pytest.FixtureRequest, case: str) -> None:
    data = load_input("patterns", case)
    as_of = _as_of(data["asOf"])
    starts = completed_week_starts(as_of, weeks=8)
    result = {}
    for name, spec in data["cases"].items():
        series = RetailerProductSeries(
            retailer_id=spec["retailerId"],
            product_id=spec["productId"],
            observations=tuple(
                WeeklyObservation(
                    week_start=start,
                    quantity=quantity,
                    revenue_rm=quantity * 5.0,
                    order_count=1 if quantity > 0 else 0,
                )
                for start, quantity in zip(starts, spec["weeks"])
            ),
        )
        result[name] = analyse_series(series, as_of=as_of)
    assert_matches_golden(request, "patterns", case, result)


@pytest.mark.parametrize("case", case_names("excel_import"))
def test_excel_import_golden(
    request: pytest.FixtureRequest,
    case: str,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = load_input("excel_import", case)
    processed = tmp_path / "processed"
    outputs = tmp_path / "outputs"
    raw = tmp_path / "raw"
    imports = tmp_path / "imports"
    for folder in (processed, outputs, raw, imports):
        folder.mkdir()
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)
    monkeypatch.setattr(config, "IMPORT_ERRORS_CSV", processed / "import_errors.csv")
    monkeypatch.setattr(config, "IMPORT_HISTORY_JSON", outputs / "history.json")
    monkeypatch.setattr(config, "RAW_ORDERS_CSV", raw / "orders.csv")
    monkeypatch.setattr(config, "IMPORTS", imports)
    upload = tmp_path / source.name
    shutil.copy(source, upload)

    summary = excel_importer.import_table(upload)

    for volatile in ("importId", "importedAt", "errorReport"):
        assert summary.pop(volatile)
    staged = raw / "orders.csv"
    rows = (
        list(csv.DictReader(staged.open(encoding="utf-8", newline="")))
        if staged.exists()
        else []
    )
    assert_matches_golden(
        request, "excel_import", case, {"summary": summary, "stagedRows": rows}
    )


def _stage_importer(monkeypatch, tmp_path):
    for name in ("processed", "outputs", "raw", "imports"):
        (tmp_path / name).mkdir()
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)
    monkeypatch.setattr(config, "IMPORT_ERRORS_CSV", tmp_path / "processed" / "e.csv")
    monkeypatch.setattr(config, "IMPORT_HISTORY_JSON", tmp_path / "outputs" / "h.json")
    monkeypatch.setattr(config, "RAW_ORDERS_CSV", tmp_path / "raw" / "orders.csv")
    monkeypatch.setattr(config, "IMPORTS", tmp_path / "imports")


def test_fix_196_two_retailers_sharing_a_name_stay_separate(monkeypatch, tmp_path):
    _stage_importer(monkeypatch, tmp_path)
    upload = tmp_path / "orders.csv"
    upload.write_text(
        "date,product,sku,qty,retailer,retailerid\n"
        "2026-10-05,Rice,R1,5,Mart,A-1\n"
        "2026-10-05,Rice,R1,5,Mart,B-2\n",
        encoding="utf-8",
    )

    summary = excel_importer.import_table(upload)

    assert summary["validRows"] == 2
    assert summary["issueCounts"].get("duplicate_row", 0) == 0


def test_fix_197_oversized_file_is_refused_and_old_uploads_are_pruned(
    monkeypatch, tmp_path
):
    _stage_importer(monkeypatch, tmp_path)
    monkeypatch.setattr(config, "MAX_IMPORT_ROWS", 3)
    monkeypatch.setattr(config, "MAX_KEPT_IMPORTS", 2)
    big = tmp_path / "big.csv"
    big.write_text(
        "date,product,qty\n" + "2026-10-05,Rice,1\n" * 4, encoding="utf-8"
    )
    with pytest.raises(excel_importer.ImportTooLarge):
        excel_importer.import_table(big)

    ok = tmp_path / "ok.csv"
    ok.write_text("date,product,qty\n2026-10-05,Rice,1\n", encoding="utf-8")
    for _ in range(4):
        excel_importer.import_table(ok)

    assert len(list((tmp_path / "imports").iterdir())) == 2

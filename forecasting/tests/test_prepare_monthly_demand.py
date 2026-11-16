from __future__ import annotations

import importlib.util
from pathlib import Path

import pandas as pd
import pytest

from forecasting.service import config


def _load_prepare_module(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.syspath_prepend(str(config.SCRIPTS))
    script_path = config.SCRIPTS / "02_prepare_monthly_demand.py"
    spec = importlib.util.spec_from_file_location("prepare_monthly_demand", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _row(name: str, **extra: object) -> dict[str, object]:
    row: dict[str, object] = {
        "orderId": f"order-{name.lower().replace(' ', '-')}",
        "submittedAt": "2026-01-15T10:00:00",
        "status": "approved",
        "retailerId": f"retailer-{name.lower().replace(' ', '-')}",
        "retailerName": name,
        "productId": "P001",
        "productName": "Example Product",
        "category": "Food",
        "quantity": 2,
        "unitPrice": 1.0,
        "lineTotal": 2.0,
    }
    row.update(extra)
    return row


def test_cleaner_excludes_bounded_test_markers_only(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    module = _load_prepare_module(monkeypatch)
    input_path = tmp_path / "orders.csv"
    processed = tmp_path / "processed"
    pd.DataFrame(
        [
            _row("Test Retailer"),
            _row("Contest Mart"),
            _row("Latest Grocer"),
            _row("Testimony Foods"),
            _row("Demo Fixture", is_demo="true"),
            _row("Demographic Import", source="demographic_import"),
        ]
    ).to_csv(input_path, index=False)
    production_processed = tmp_path / "production-processed"
    module.PROCESSED = production_processed
    module.EVALUATION_PROCESSED = processed

    module.main(input_path)

    cleaned = pd.read_csv(processed / "cleaned_orders.csv")
    assert set(cleaned["retailerName"]) == {
        "Contest Mart",
        "Latest Grocer",
        "Testimony Foods",
        "Demographic Import",
    }
    issues = pd.read_csv(processed / "data_quality_issues.csv")
    test_rows = issues[issues["issueType"] == "test_record"]
    assert set(test_rows["retailerName"]) == {"Test Retailer", "Demo Fixture"}
    assert not production_processed.exists()

    with pytest.raises(ValueError, match="separate --processed-dir"):
        module.main(input_path, production_processed)

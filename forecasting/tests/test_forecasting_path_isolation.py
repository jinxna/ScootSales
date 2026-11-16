from __future__ import annotations

import importlib.util
from pathlib import Path

import pandas as pd
import pytest

from forecasting.service import config


def _load_script(module_name: str, filename: str, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.syspath_prepend(str(config.SCRIPTS))
    script_path = config.SCRIPTS / filename
    spec = importlib.util.spec_from_file_location(module_name, script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _evaluation_row() -> dict[str, object]:
    return {
        "orderId": "evaluation-order-1",
        "submittedAt": "2026-01-15T10:00:00",
        "status": "approved",
        "retailerId": "evaluation-retailer-1",
        "retailerName": "Evaluation Grocer",
        "productId": "P001",
        "productName": "Example Product",
        "category": "Food",
        "quantity": 2,
        "unitPrice": 1.0,
        "lineTotal": 2.0,
    }


def test_evaluation_pipeline_cannot_touch_production_artifacts(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    prepare = _load_script(
        "prepare_monthly_demand_path_isolation",
        "02_prepare_monthly_demand.py",
        monkeypatch,
    )
    train = _load_script(
        "train_forecast_model_path_isolation",
        "03_train_forecast_model.py",
        monkeypatch,
    )

    evaluation_input = tmp_path / "evaluation" / "dummy_orders.csv"
    evaluation_processed = tmp_path / "evaluation" / "processed"
    evaluation_outputs = tmp_path / "evaluation" / "outputs"
    production_processed = tmp_path / "production" / "processed"
    production_outputs = tmp_path / "production" / "outputs"

    evaluation_input.parent.mkdir(parents=True)
    pd.DataFrame([_evaluation_row()]).to_csv(evaluation_input, index=False)
    production_processed.mkdir(parents=True)
    production_outputs.mkdir(parents=True)
    processed_sentinel = production_processed / "production-sentinel.csv"
    output_sentinel = production_outputs / "production-sentinel.json"
    processed_sentinel.write_text("production processed data", encoding="utf-8")
    output_sentinel.write_text("production forecast data", encoding="utf-8")

    prepare.PROCESSED = production_processed
    prepare.EVALUATION_PROCESSED = evaluation_processed
    prepare.main(evaluation_input)

    assert (evaluation_processed / "monthly_product_demand.csv").exists()
    assert processed_sentinel.read_text(encoding="utf-8") == "production processed data"

    train.PROCESSED = production_processed
    train.OUTPUTS = production_outputs
    train.EVALUATION_OUTPUTS = evaluation_outputs
    train.main(evaluation_processed)

    assert (evaluation_outputs / "demand_forecasts.json").exists()
    assert (evaluation_outputs / "forecast_training_runs.json").exists()
    assert output_sentinel.read_text(encoding="utf-8") == "production forecast data"

    with pytest.raises(ValueError, match="separate --processed-dir"):
        prepare.main(evaluation_input, production_processed)
    with pytest.raises(ValueError, match="separate --output-dir"):
        train.main(evaluation_processed, production_outputs)

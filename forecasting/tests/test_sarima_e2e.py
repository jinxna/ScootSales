import json
import math
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from forecasting.ai_core.calendar import completed_week_starts
from forecasting.ai_service.operational_forecast import build_operational_forecasts
from forecasting.ai_service.normalization import normalize_firestore_inputs
from forecasting.ai_service.generator import build_generation
from forecasting.ai_core.opportunity import retailer_opportunities
from forecasting.service import config, pipeline_runner


AS_OF = datetime(2026, 10, 16, 4, tzinfo=timezone.utc)


def fixture_inputs():
    starts = completed_week_starts(AS_OF, weeks=104)
    orders = []
    for i, start in enumerate(starts):
        quantity = round(30 + 12 * math.sin(2 * math.pi * i / 52) + (i % 3), 2)
        orders.append({"orderId": f"order-{i}", "submittedAt": start.isoformat(),
                       "retailerId": "R1", "status": "confirmed",
                       "items": [{"productId": "P1", "qty": quantity, "price": 2}]})
    orders.append({"orderId": "short", "submittedAt": starts[-1].isoformat(),
                   "retailerId": "R1", "status": "confirmed",
                   "items": [{"productId": "P2", "qty": 10, "price": 2}]})
    return {"orders": orders, "products": [
        {"productId": p, "productName": p, "unitPrice": 2} for p in ("P1", "P2", "P3")],
        "retailers": [{"retailerId": "R1", "retailerName": "Fixture outlet"}], "users": []}


def test_sarima_service_saves_honest_catalogue_rows(tmp_path, monkeypatch):
    inputs = fixture_inputs()
    monkeypatch.setattr(config, "OPERATIONAL_FORECASTS_JSON", tmp_path / "forecasts.json")
    monkeypatch.setattr(config, "TRAINING_RUNS_JSON", tmp_path / "runs.json")
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)
    monkeypatch.setattr(pipeline_runner, "_now", lambda: AS_OF)
    monkeypatch.setattr(pipeline_runner, "_read_inputs", lambda token: inputs)
    monkeypatch.setattr(pipeline_runner.firestore_reader, "get_document", lambda *a, **k: None)
    run = pipeline_runner.run_forecast(token="offline-fixture")
    assert run["status"] == "completed", run
    payload = json.loads(config.OPERATIONAL_FORECASTS_JSON.read_text())
    adaptive_rows = {row["productId"]: row for row in payload["rows"]}
    rows = {key: row["comparisonForecasts"]["sarima"] for key, row in adaptive_rows.items()}
    assert payload["availableMethods"] == ["adaptive", "sarima"]
    assert adaptive_rows["P1"]["comparisonForecasts"]["adaptive"]["point"] == adaptive_rows["P1"]["point"]
    assert adaptive_rows["P1"]["model"] != "sarima"
    assert rows["P1"]["model"] == "sarima"
    assert rows["P1"]["status"] == "ok"
    assert rows["P1"]["point"] is not None and math.isfinite(rows["P1"]["point"])
    assert rows["P1"]["point"] >= 0
    assert rows["P1"]["observedPeriods"] == 104
    assert rows["P1"]["periodStart"] == "2026-10-12"
    assert rows["P1"]["dataCutoff"] == "2026-10-11"
    for product in ("P2", "P3"):
        assert rows[product]["status"] == "insufficient_history"
        assert rows[product]["point"] is None
    assert run["methodSummaries"]["sarima"]["modelMix"] == {"sarima": 1}
    assert run["methodSummaries"]["sarima"]["forecastedProducts"] == 1

    normalized = normalize_firestore_inputs(**inputs, as_of=AS_OF)
    generated = build_generation(normalized, as_of=AS_OF.date(), run_id="offline-sarima",
                                 generated_at=AS_OF, orders=inputs["orders"])
    pattern = next(row for row in generated.patterns if row["productId"] == "P1")
    assert len(pattern["weeklyQuantities"]) == 8
    assert pattern["forecastModel"] != "sarima"
    assert pattern["forecastNextWeek"] == adaptive_rows["P1"]["point"]
    opportunity = retailer_opportunities(generated.patterns, unit_prices={"P1": 2, "P2": 2})[0]
    pair = next(pair for pair in opportunity.pairs if pair.product_id == "P1")
    assert pair.expected_units == adaptive_rows["P1"]["point"]
    assert pair.expected_value_rm == adaptive_rows["P1"]["point"] * 2

    established = dict(inputs, orders=list(inputs["orders"][1:]))
    earlier = completed_week_starts(AS_OF, weeks=105)[0]
    established["orders"].append(dict(inputs["orders"][0], orderId="older-boundary",
                                      submittedAt=earlier.isoformat()))
    established_rows = build_operational_forecasts(**established, as_of=AS_OF,
        generated_at=AS_OF.isoformat(), method="sarima").to_dict()["rows"]
    assert established_rows[0]["observedPeriods"] == 104
    assert established_rows[0]["status"] == "ok"

    zero_inputs = fixture_inputs()
    for i, order in enumerate(zero_inputs["orders"][:104]):
        order["items"][0]["qty"] = 20 + i % 5 if i < 52 else 0
    zero_rows = build_operational_forecasts(**zero_inputs, as_of=AS_OF,
        generated_at=AS_OF.isoformat(), method="sarima").to_dict()["rows"]
    assert zero_rows[0]["status"] == "ok"
    assert zero_rows[0]["point"] == 0.0

    partial = dict(inputs, orders=list(inputs["orders"]),
                   retailers=inputs["retailers"] + [{"retailerId": "R2", "retailerName": "New outlet"}])
    partial["orders"].append(dict(inputs["orders"][-1], retailerId="R2", orderId="new-outlet",
        items=[{"productId": "P1", "qty": 100, "price": 2}]))
    partial_rows = build_operational_forecasts(**partial, as_of=AS_OF,
        generated_at=AS_OF.isoformat(), method="sarima").to_dict()["rows"]
    assert partial_rows[0]["point"] == rows["P1"]["point"]
    assert partial_rows[0]["componentCount"] == 2
    assert partial_rows[0]["modelledComponentCount"] == 1

    contaminated = dict(inputs, orders=list(inputs["orders"]))
    for label, extra in (("cancelled", {"status": "cancelled"}),
                         ("demo", {"isDemo": True}),
                         ("future", {"submittedAt": (AS_OF + timedelta(days=7)).isoformat()})):
        contaminated["orders"].append(dict(inputs["orders"][0], orderId=label,
            items=[{"productId": "P1", "qty": 900000, "price": 2}], **extra))
    rerun = build_operational_forecasts(**contaminated, as_of=AS_OF,
                                       generated_at=AS_OF.isoformat(), method="sarima").to_dict()
    assert {row["productId"]: row for row in rerun["rows"]} == rows
    with patch("statsmodels.tsa.statespace.sarimax.SARIMAX.fit", side_effect=ValueError("fixture fit failure")):
        failed = build_operational_forecasts(**inputs, as_of=AS_OF,
                                            generated_at=AS_OF.isoformat(), method="sarima").to_dict()
    assert failed["rows"][0]["point"] is None
    assert failed["rows"][0]["status"] == "model_error"
    evidence = Path("eval_reports/sarima_e2e")
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "result.json").write_text(json.dumps({
        "evidence": "synthetic offline service fixture; not production accuracy",
        "run": run, "forecast": payload, "fitFailure": failed,
        "checks": ["service persistence", "SARIMA model identity", "104-week history",
                   "short and new products abstain", "cancelled/demo/future excluded",
                   "fit error abstains without another model", "adaptive forecast preserved in briefs and value", "both methods persisted separately",
                   "recent trend window remains eight weeks", "existing silent training week",
                   "valid zero forecast", "partial totals exclude observed substitutes"],
    }, indent=2), encoding="utf8")

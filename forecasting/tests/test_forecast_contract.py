from __future__ import annotations

import datetime as datetime_module
import sys
import time
from datetime import date, datetime

import pytest

from forecasting.ai_core import forecast_contract
from forecasting.ai_core.forecast_contract import (
    FORECAST_CONTRACT_VERSION,
    PERIOD_DAYS,
    SCOPE_PRODUCT,
    SCOPE_RETAILER_PRODUCT,
    STATUS_INSUFFICIENT_HISTORY,
    STATUS_OK,
    OperationalForecast,
    build_operational_forecast,
    observed_reference_units,
)
from forecasting.ai_core.forecast_models import (
    FORECAST_MODELS_VERSION,
    POINT_SEMANTICS,
    forecast_next,
)
from forecasting.ai_core.opportunity import TIER_FORECAST, TIER_OBSERVED_BASELINE, pair_opportunity

INTERMITTENT = [0.0, 0.0, 10.0, 0.0, 0.0, 10.0, 0.0, 0.0]
COLD_START = [0.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 0.0]


def _record(values, **overrides):
    arguments = dict(
        product_id="P001",
        period_start="2026-09-21",
        data_cutoff="2026-09-20",
        generated_at="2026-09-18T12:00:00+00:00",
    )
    arguments.update(overrides)
    return build_operational_forecast(values, **arguments)


def test_contract_carries_every_documented_field() -> None:
    payload = _record(INTERMITTENT, retailer_id="R001").to_dict()
    expected = {
        "scopeType",
        "retailerId",
        "productId",
        "productName",
        "periodStart",
        "periodDays",
        "point",
        "pointSemantics",
        "probabilityNonZero",
        "lower",
        "upper",
        "demandClass",
        "model",
        "modelVersion",
        "status",
        "observedPeriods",
        "nonZeroPeriods",
        "meanNonZeroDemand",
        "referenceUnits",
        "dataCutoff",
        "generatedAt",
        "contractVersion",
        "componentCount",
        "modelledComponentCount",
        "observedComponentCount",
        "noDemandComponentCount",
        "historyWeeks",
        "historyWindowVersion",
        "windowEvaluated",
    }
    assert set(payload) == expected
    assert payload["contractVersion"] == FORECAST_CONTRACT_VERSION
    assert payload["pointSemantics"] == POINT_SEMANTICS
    assert payload["modelVersion"] == FORECAST_MODELS_VERSION
    assert payload["periodDays"] == PERIOD_DAYS
    assert payload["scopeType"] == SCOPE_RETAILER_PRODUCT
    assert payload["retailerId"] == "R001"
    assert payload["productId"] == "P001"
    assert payload["dataCutoff"] == "2026-09-20"
    assert payload["generatedAt"] == "2026-09-18T12:00:00+00:00"
    assert payload["componentCount"] == 1
    assert payload["modelledComponentCount"] == 1
    assert payload["observedComponentCount"] == 0
    assert payload["noDemandComponentCount"] == 0


def test_a_product_scope_record_has_no_retailer() -> None:
    record = _record(INTERMITTENT)
    assert record.scope_type == SCOPE_PRODUCT
    assert record.retailer_id == ""


def test_usable_record_carries_the_unconditional_point() -> None:
    record = _record(INTERMITTENT)
    point = forecast_next(INTERMITTENT)
    assert record.status == STATUS_OK
    assert record.is_usable
    assert record.point == pytest.approx(point.point)
    assert record.probability_non_zero == pytest.approx(point.probability_non_zero)
    assert record.units_for_value == pytest.approx(point.point)
    assert record.demand_class == point.classification
    assert record.model == point.model


def test_insufficient_history_reports_no_fabricated_point() -> None:
    record = _record(COLD_START)
    assert record.status == STATUS_INSUFFICIENT_HISTORY
    assert not record.is_usable
    assert record.point is None
    assert record.lower is None and record.upper is None
    assert record.reference_units == pytest.approx(5.0)
    assert record.units_for_value == pytest.approx(5.0)
    assert record.observed_periods == 8
    assert record.non_zero_periods == 1
    assert record.mean_non_zero_demand == pytest.approx(40.0)


def test_empty_history_is_a_real_zero_not_a_missing_value() -> None:
    record = _record([])
    assert record.status == STATUS_INSUFFICIENT_HISTORY
    assert record.point is None
    assert record.reference_units == 0.0
    assert record.units_for_value == 0.0


def test_observed_reference_is_rate_times_conditional_size() -> None:
    assert observed_reference_units(INTERMITTENT) == pytest.approx(2.5)
    assert observed_reference_units([0.0] * 5) == 0.0
    assert observed_reference_units([]) == 0.0


def test_round_trip_preserves_the_record() -> None:
    record = _record(INTERMITTENT, retailer_id="R001")
    assert OperationalForecast.from_dict(record.to_dict()) == record
    cold = _record(COLD_START)
    assert OperationalForecast.from_dict(cold.to_dict()) == cold


def test_from_dict_refuses_an_unknown_contract_version() -> None:
    payload = _record(INTERMITTENT).to_dict()
    payload["contractVersion"] = "operational-forecast/99.0.0"
    with pytest.raises(ValueError):
        OperationalForecast.from_dict(payload)
    del payload["contractVersion"]
    with pytest.raises(ValueError):
        OperationalForecast.from_dict(payload)


def test_builder_is_deterministic() -> None:
    assert _record(INTERMITTENT) == _record(INTERMITTENT)


def test_builder_never_reads_a_clock(monkeypatch: pytest.MonkeyPatch) -> None:
    def refuse(*_args: object, **_kwargs: object) -> None:
        raise AssertionError("the forecast builder read a clock")

    class NoClockDatetime(datetime):
        now = classmethod(refuse)
        utcnow = classmethod(refuse)
        today = classmethod(refuse)

    class NoClockDate(date):
        today = classmethod(refuse)

    with_dates = _record(INTERMITTENT)
    core_modules = [
        module
        for name, module in list(sys.modules.items())
        if name.startswith("forecasting.ai_core") and module is not None
    ]
    wall_clocks = [
        getattr(time, name)
        for name in ("time", "time_ns", "localtime", "gmtime", "ctime", "asctime", "strftime")
    ]

    def reads_a_clock(value: object) -> bool:
        if any(value is wall_clock for wall_clock in wall_clocks):
            return True
        return getattr(value, "__self__", None) in (datetime, date) and getattr(
            value, "__name__", ""
        ) in ("now", "utcnow", "today")

    for module in [datetime_module, time, *core_modules]:
        for name, value in list(vars(module).items()):
            if value is datetime:
                monkeypatch.setattr(module, name, NoClockDatetime)
            elif value is date:
                monkeypatch.setattr(module, name, NoClockDate)
            elif reads_a_clock(value):
                monkeypatch.setattr(module, name, refuse)
    assert forecast_contract.datetime is NoClockDatetime
    assert time.time is refuse

    assert _record(INTERMITTENT) == with_dates
    without_dates = build_operational_forecast(INTERMITTENT, product_id="P001")
    assert (
        without_dates.period_start,
        without_dates.data_cutoff,
        without_dates.generated_at,
    ) == ("", "", "")


def test_value_layer_consumes_the_supplied_record() -> None:
    record = _record(INTERMITTENT)
    substituted = OperationalForecast(**{**record.__dict__, "point": 7.0})
    result = pair_opportunity(
        INTERMITTENT,
        unit_price_rm=2.0,
        product_id="P001",
        retailer_id="R001",
        forecast=substituted,
    )
    assert result.tier == TIER_FORECAST
    assert result.expected_units == pytest.approx(7.0)
    assert result.expected_value_rm == pytest.approx(14.0)


def test_value_layer_falls_back_to_the_reference_for_insufficient_history() -> None:
    record = _record(COLD_START)
    result = pair_opportunity(
        COLD_START,
        unit_price_rm=3.0,
        product_id="P001",
        forecast=record,
    )
    assert result.tier == TIER_OBSERVED_BASELINE
    assert result.expected_units == pytest.approx(record.reference_units)
    assert result.expected_value_rm == pytest.approx(5.0 * 3.0)


def test_a_finite_zero_forecast_is_a_usable_zero_not_missing_history() -> None:
    silent = [7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0]
    record = _record(silent)
    assert record.status == STATUS_OK
    assert record.is_usable
    assert record.point == 0.0
    assert record.units_for_value == 0.0

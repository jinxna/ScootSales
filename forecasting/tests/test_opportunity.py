from __future__ import annotations

import pytest

from forecasting.ai_core.forecast_models import forecast_next
from forecasting.ai_core.opportunity import (
    DEFAULT_RELATIVE_UNCERTAINTY,
    EXPECTED_ORDER_VALUE_VERSION,
    TIER_FORECAST,
    TIER_NO_DEMAND,
    TIER_NO_PRICE,
    TIER_OBSERVED_BASELINE,
    pair_opportunity,
    retailer_opportunities,
)


def test_forecast_tier_is_unconditional_point_times_price() -> None:
    quantities = [10.0, 0.0, 12.0, 0.0, 11.0, 0.0, 13.0, 0.0]
    forecast = forecast_next(quantities)
    result = pair_opportunity(quantities, unit_price_rm=2.5, product_id="P1")
    assert result.tier == TIER_FORECAST
    assert forecast.is_usable
    assert result.expected_units == pytest.approx(forecast.point)
    assert result.expected_value_rm == pytest.approx(forecast.point * 2.5)
    assert result.probability_non_zero == pytest.approx(
        forecast.probability_non_zero
    )


def test_occurrence_probability_is_not_counted_twice() -> None:
    quantities = [0.0, 0.0, 10.0, 0.0, 0.0, 10.0, 0.0, 0.0]
    forecast = forecast_next(quantities)
    result = pair_opportunity(quantities, unit_price_rm=2.0, product_id="P1")
    assert forecast.probability_non_zero == pytest.approx(0.25)
    assert result.tier == TIER_FORECAST
    assert result.expected_units == pytest.approx(forecast.point)
    double_counted = forecast.probability_non_zero * forecast.point
    assert result.expected_units > double_counted
    assert result.expected_units < 10.0
    assert result.expected_value_rm == pytest.approx(result.expected_units * 2.0)
    if result.interval_lower_rm is not None and result.interval_upper_rm is not None:
        assert result.interval_lower_rm <= result.expected_value_rm
        assert result.interval_upper_rm >= result.expected_value_rm


def test_cold_start_falls_back_to_the_observed_baseline() -> None:
    quantities = [0.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 0.0]
    result = pair_opportunity(quantities, unit_price_rm=3.0, product_id="P1")
    assert result.tier == TIER_OBSERVED_BASELINE
    assert result.forecast_status != "ok"
    assert result.expected_units == pytest.approx(5.0)
    assert result.expected_value_rm == pytest.approx(15.0)
    assert result.relative_uncertainty == DEFAULT_RELATIVE_UNCERTAINTY


def test_no_demand_pair_is_a_real_zero() -> None:
    result = pair_opportunity([0.0] * 8, unit_price_rm=9.0, product_id="P1")
    assert result.tier == TIER_NO_DEMAND
    assert result.expected_value_rm == 0.0
    assert result.expected_units == 0.0


def test_missing_price_produces_no_value_and_is_counted() -> None:
    quantities = [0.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 0.0]
    result = pair_opportunity(quantities, unit_price_rm=0.0, product_id="P1")
    assert result.tier == TIER_NO_PRICE
    assert result.expected_value_rm == 0.0


def test_dead_pair_without_a_price_is_not_counted_as_missing_price() -> None:
    result = pair_opportunity([0.0] * 8, unit_price_rm=0.0, product_id="P1")
    assert result.tier == TIER_NO_DEMAND


def test_retailer_aggregation_sums_pairs_and_counts_tiers() -> None:
    patterns = [
        {"retailerId": "R1", "productId": "P1", "weeklyQuantities": [0.0, 5.0, 0.0, 5.0, 0.0, 6.0, 0.0, 5.0]},
        {"retailerId": "R1", "productId": "P2", "weeklyQuantities": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]},
        {"retailerId": "R2", "productId": "P1", "weeklyQuantities": [0.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 0.0]},
    ]
    rows = retailer_opportunities(patterns, unit_prices={"P1": 2.0, "P2": 4.0})
    by_id = {row.retailer_id: row for row in rows}
    assert set(by_id) == {"R1", "R2"}
    r2 = by_id["R2"]
    assert r2.expected_order_value_rm == pytest.approx(10.0)
    assert r2.observed_baseline_pair_count == 1
    assert r2.forecast_pair_count == 0
    assert by_id["R1"].no_demand_pair_count == 1
    for row in rows:
        assert row.definition_version == EXPECTED_ORDER_VALUE_VERSION


def test_uncertainty_source_names_the_fallback() -> None:
    patterns = [
        {"retailerId": "R1", "productId": "P1", "weeklyQuantities": [0.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 0.0]},
    ]
    rows = retailer_opportunities(patterns, unit_prices={"P1": 2.0})
    assert rows[0].relative_uncertainty_source == "documented_default_no_interval"
    assert rows[0].relative_uncertainty == DEFAULT_RELATIVE_UNCERTAINTY


def test_aggregate_uncertainty_uses_the_interval_half_width() -> None:
    patterns = [
        {"retailerId": "R1", "productId": "P1", "weeklyQuantities": [8.0, 9.0, 8.0, 9.0, 8.0, 9.0, 8.0, 9.0]},
    ]
    rows = retailer_opportunities(patterns, unit_prices={"P1": 2.0})
    row = rows[0]
    assert row.interval_pair_count == 1
    assert row.relative_uncertainty_source == "aggregate_interval"
    assert 0.0 < row.relative_uncertainty < DEFAULT_RELATIVE_UNCERTAINTY


def test_definition_is_deterministic() -> None:
    patterns = [
        {"retailerId": "R1", "productId": "P1", "weeklyQuantities": [1.0, 0.0, 3.0, 0.0, 2.0, 0.0, 4.0, 0.0]},
    ]
    first = retailer_opportunities(patterns, unit_prices={"P1": 1.5})
    second = retailer_opportunities(patterns, unit_prices={"P1": 1.5})
    assert first[0].to_dict() == second[0].to_dict()


def test_rows_without_ids_are_skipped() -> None:
    rows = retailer_opportunities(
        [
            {"retailerId": "", "productId": "P1", "weeklyQuantities": [1.0, 1.0]},
            {"retailerId": "R1", "productId": "", "weeklyQuantities": [1.0, 1.0]},
        ],
        unit_prices={"P1": 1.0},
    )
    assert rows == ()


def test_a_zero_forecast_is_priced_as_a_forecast_of_zero() -> None:
    result = pair_opportunity(
        [7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0], unit_price_rm=2.0, product_id="P1"
    )
    assert result.tier == TIER_FORECAST
    assert result.forecast_status == "ok"
    assert result.expected_units == 0.0
    assert result.expected_value_rm == 0.0

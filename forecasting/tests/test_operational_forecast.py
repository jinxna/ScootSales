from __future__ import annotations

import datetime
import itertools

import pytest

from forecasting.ai_service.operational_forecast import (
    OPERATIONAL_SCOPE_PRODUCT,
    OPERATIONAL_SCOPE_RETAILER_PRODUCT,
    build_operational_forecasts,
)
from forecasting.ai_core.forecast_contract import build_operational_forecast
from forecasting.ai_core.calendar import completed_week_starts
from forecasting.ai_core.forecast_models import POINT_SEMANTICS
from forecasting.ai_core.models import RetailerProductSeries, WeeklyObservation
from forecasting.ai_core.patterns import analyse_series
from forecasting.ai_core.patterns import forecast_point

AS_OF = datetime.date(2026, 9, 18)
GENERATED_AT = "2026-09-18T12:00:00+00:00"

PRODUCTS = [
    {"productId": "P1", "productName": "Alpha", "unitPrice": 2.0},
    {"productId": "P2", "productName": "Beta", "unitPrice": 3.0},
    {"productId": "P3", "productName": "Gamma", "unitPrice": 1.0},
]
RETAILERS = [
    {"retailerId": "R1", "retailerName": "First Shop", "branchId": "B1"},
    {"retailerId": "R2", "retailerName": "Second Shop", "branchId": "B1"},
]


def _order(order_id, week, retailer, items, **extra):
    payload = {
        "orderId": order_id,
        "submittedAt": week + "T02:00:00+00:00",
        "retailerId": retailer,
        "status": "confirmed",
        "items": items,
    }
    payload.update(extra)
    return payload


ORDERS = [
    _order("O1", "2026-09-01", "R1", [{"productId": "P1", "qty": 10, "price": 2.0}]),
    _order("O2", "2026-09-08", "R1", [{"productId": "P1", "qty": 8, "price": 2.0}]),
    _order("O3", "2026-09-08", "R2", [{"productId": "P1", "qty": 6, "price": 2.0}]),
    _order("O4", "2026-09-08", "R1", [{"productId": "P3", "qty": 12, "price": 1.0}]),
    _order("O5", "2026-09-08", "R1", [{"productId": "P1", "qty": 99, "price": 2.0}], status="cancelled"),
    _order("O6", "2026-09-08", "R1", [{"productId": "P1", "qty": 50, "price": 2.0}], isDemo=True),
    _order("O7", "2026-09-08", "R1", [{"productId": "NOT_IN_CATALOGUE", "qty": 5, "price": 2.0}]),
]


def _build(scope=OPERATIONAL_SCOPE_PRODUCT, orders=None, as_of=AS_OF):
    return build_operational_forecasts(
        orders=ORDERS if orders is None else orders,
        products=PRODUCTS,
        retailers=RETAILERS,
        users=[],
        as_of=as_of,
        generated_at=GENERATED_AT,
        scope=scope,
    )


def _row(result, product_id, retailer_id=""):
    for row in result.rows:
        if row.product_id == product_id and row.retailer_id == retailer_id:
            return row
    raise AssertionError("row not found: " + product_id + "/" + retailer_id)


def test_product_scope_covers_the_whole_catalogue() -> None:
    result = _build()
    assert result.scope == OPERATIONAL_SCOPE_PRODUCT
    assert [row.product_id for row in result.rows] == ["P1", "P2", "P3"]
    assert [row.product_name for row in result.rows] == ["Alpha", "Beta", "Gamma"]
    silent = _row(result, "P2")
    assert silent.status == "insufficient_history"
    assert silent.point is None
    assert silent.reference_units == 0.0
    assert silent.component_count == 0


def test_period_and_cutoff_come_from_the_run_moment() -> None:
    result = _build()
    assert result.period_start == "2026-09-14"
    assert result.data_cutoff == "2026-09-13"
    assert result.as_of == "2026-09-18"
    assert result.generated_at == GENERATED_AT
    assert result.history_weeks == 8
    assert result.window_evaluated is True


def test_demand_evidence_decides_the_status() -> None:
    result = _build()
    assert _row(result, "P1").status == "ok"
    cold = _row(result, "P3")
    assert cold.status == "insufficient_history"
    assert cold.point is None
    assert cold.reference_units == pytest.approx(12.0 / 8.0)


def test_unusable_items_do_not_reach_the_forecast() -> None:
    quality = _build().data_quality
    assert quality["ordersSkippedStatus"] == 1
    assert quality["itemsUnresolvedProduct"] == 1
    p1 = _row(_build(), "P1")
    assert p1.reference_units == pytest.approx(3.0)
    assert p1.non_zero_periods == 3


def test_product_row_sums_its_outlet_components() -> None:
    product_rows = _build(OPERATIONAL_SCOPE_PRODUCT)
    outlet_rows = _build(OPERATIONAL_SCOPE_RETAILER_PRODUCT)
    p1_product = _row(product_rows, "P1")
    p1_outlets = [
        row for row in outlet_rows.rows if row.product_id == "P1"
    ]
    assert len(p1_outlets) == 2
    assert p1_product.component_count == 2
    assert p1_product.modelled_component_count + p1_product.observed_component_count \
        + p1_product.no_demand_component_count == 2
    assert p1_product.point == pytest.approx(
        sum(row.units_for_value for row in p1_outlets)
    )
    assert p1_product.reference_units == pytest.approx(
        sum(row.reference_units for row in p1_outlets)
    )


RANGE_SERIES = {
    "audit_step": ([0, 0, 0, 0, 1, 1, 1, 1], 0.5904),
    "audit_ramp": ([1, 2, 3, 4, 5, 6, 7, 8], 8.5),
    "zeros": ([0, 0, 0, 0, 0, 0, 0, 0], None),
    "constant": ([5, 5, 5, 5, 5, 5, 5, 5], 5.0),
    "step_up": ([2, 2, 2, 2, 9, 9, 9, 9], 10.8333),
    "falling": ([8, 7, 6, 5, 4, 3, 2, 1], 0.5),
    "stopped": ([10, 10, 10, 10, 0, 0, 0, 0], 4.096),
    "sparse": ([0, 6, 0, 0, 7, 0, 0, 5], 2.1148),
    "single_spike": ([0, 0, 0, 40, 0, 0, 0, 0], None),
    "erratic": ([1, 40, 2, 50, 1, 45, 3, 38], 21.75),
    "lumpy": ([1, 0, 0, 80, 0, 3, 0, 60], 11.616),
}


def test_a_range_always_holds_its_own_point() -> None:
    outlets = {
        name: build_operational_forecast(series, product_id="P1", retailer_id=name)
        for name, (series, _) in RANGE_SERIES.items()
    }
    assert {name: row.point for name, row in outlets.items()} == {
        name: point for name, (_, point) in RANGE_SERIES.items()
    }
    grid = [
        build_operational_forecast(list(series), product_id="P1")
        for series in itertools.product((0, 1, 10), repeat=8)
    ]
    weeks = completed_week_starts(AS_OF, weeks=8)
    summed = ("stopped", "single_spike", "audit_ramp")
    product = _row(
        build_operational_forecasts(
            orders=[
                _order(
                    f"{name}-{index}",
                    week.isoformat(),
                    name,
                    [{"productId": "P1", "qty": quantity, "price": 2.0}],
                )
                for name in summed
                for index, (week, quantity) in enumerate(
                    zip(weeks, RANGE_SERIES[name][0])
                )
                if quantity > 0
            ],
            products=PRODUCTS,
            retailers=[
                {"retailerId": name, "retailerName": name, "branchId": "B1"}
                for name in summed
            ],
            users=[],
            as_of=AS_OF,
            generated_at=GENERATED_AT,
        ),
        "P1",
    )
    assert product.point == 17.596
    assert product.lower is not None and product.upper is not None
    assert outlets["single_spike"].lower is None
    assert outlets["single_spike"].upper is None
    assert outlets["single_spike"].units_for_value == 5.0
    assert (outlets["stopped"].lower, outlets["stopped"].upper) == (0.0, 4.096)
    assert (outlets["audit_ramp"].lower, outlets["audit_ramp"].upper) == (8.5, 9.0)
    assert product.lower == 8.5
    assert product.upper == 18.096
    assert product.lower < product.point < product.upper
    broken = [
        (row.retailer_id or "product", row.lower, row.point, row.upper)
        for row in [*outlets.values(), *grid, product]
        if (row.lower is None) != (row.upper is None)
        or (
            row.lower is not None
            and not 0.0 <= row.lower <= row.point <= row.upper
        )
    ]
    assert broken == []


def test_an_aggregate_row_is_not_dressed_up_as_a_single_model() -> None:
    aggregate = _row(_build(OPERATIONAL_SCOPE_PRODUCT), "P1")
    assert aggregate.model is None
    assert aggregate.demand_class is None
    assert aggregate.probability_non_zero is None
    outlets = [row for row in _build(OPERATIONAL_SCOPE_RETAILER_PRODUCT).rows if row.product_id == "P1"]
    assert all(row.probability_non_zero is not None for row in outlets)
    assert all(row.model for row in outlets)


def test_retailer_scope_rows_stay_single_series_records() -> None:
    result = _build(OPERATIONAL_SCOPE_RETAILER_PRODUCT)
    assert result.scope == OPERATIONAL_SCOPE_RETAILER_PRODUCT
    p1_r1 = _row(result, "P1", "R1")
    assert p1_r1.retailer_id == "R1"
    assert p1_r1.scope_type == "retailer_product"
    assert p1_r1.component_count == 1
    assert p1_r1.modelled_component_count == 1
    assert p1_r1.point is not None
    assert p1_r1.point_semantics == "unconditional_expected_demand_per_period"


def test_unknown_scope_is_refused() -> None:
    with pytest.raises(ValueError):
        _build("outlet")


def test_the_build_is_deterministic() -> None:
    assert _build().to_dict() == _build().to_dict()


def test_the_stored_pattern_states_what_its_forecast_means() -> None:
    quantities = [0.0, 0.0, 10.0, 0.0, 0.0, 10.0, 0.0, 0.0]
    starts = completed_week_starts(datetime.date(2026, 9, 18), weeks=8)
    series = RetailerProductSeries(
        retailer_id="R1",
        product_id="P1",
        observations=tuple(
            WeeklyObservation(week_start=start, quantity=quantity)
            for start, quantity in zip(starts, quantities)
            if quantity > 0
        ),
    )
    metrics = analyse_series(series, as_of=datetime.date(2026, 9, 18))
    assert metrics.forecast_semantics == POINT_SEMANTICS
    assert metrics.forecast_next_week == pytest.approx(
        forecast_point(quantities).point
    )


def test_the_runner_pattern_and_the_page_row_share_one_forecast() -> None:
    quantities = [0.0, 0.0, 10.0, 0.0, 0.0, 10.0, 0.0, 0.0]
    pattern = forecast_point(quantities)
    record = build_operational_forecast(
        quantities,
        product_id="P1",
        period_start="2026-09-21",
        data_cutoff="2026-09-20",
        generated_at="2026-09-18T12:00:00+00:00",
    )
    assert record.point == pytest.approx(pattern.point)
    assert record.probability_non_zero == pytest.approx(pattern.probability_non_zero)
    assert record.model == pattern.model
    assert record.demand_class == pattern.classification
    assert record.model_version == pattern.version
    assert record.point_semantics == "unconditional_expected_demand_per_period"

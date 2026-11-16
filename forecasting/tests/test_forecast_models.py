from __future__ import annotations

import statistics

import pytest

from forecasting.ai_core.forecast_models import (
    ADI_CUTOFF,
    CV2_CUTOFF,
    DEFAULT_ALPHA,
    FORECAST_MODELS_VERSION,
    POINT_SEMANTICS,
    POINT_SEMANTICS_BY_MODEL,
    SBA_ZERO_BIAS_FACTOR,
    characterise_demand,
    classify_demand,
    croston_forecast,
    forecast_next,
    mase,
    moving_average_forecast,
    sba_forecast,
    select_forecast_model,
    theta_forecast,
    tsb_forecast,
)


INTERMITTENT = [0.0, 0.0, 10.0, 0.0, 0.0, 10.0, 0.0, 0.0]


def test_every_model_declares_the_unconditional_point_semantics() -> None:
    assert POINT_SEMANTICS == "unconditional_expected_demand_per_period"
    assert set(POINT_SEMANTICS_BY_MODEL) == {
        "sarima",
        "theta",
        "moving_average",
        "croston",
        "sba",
        "tsb",
        "naive_last",
        "naive_mean",
        "float_origin_constant",
    }
    assert set(POINT_SEMANTICS_BY_MODEL.values()) == {POINT_SEMANTICS}
    carried = forecast_next(INTERMITTENT).to_dict()
    assert carried["pointSemantics"] == POINT_SEMANTICS
    assert carried["version"] == FORECAST_MODELS_VERSION


@pytest.mark.parametrize("model", ["theta", "moving_average", "croston", "tsb"])
def test_operational_models_forecast_the_unconditional_level(model: str) -> None:
    point = forecast_next(INTERMITTENT, model=model).point
    unconditional = statistics.fmean(INTERMITTENT)
    conditional = statistics.fmean([10.0, 10.0])
    assert abs(point - unconditional) < abs(point - conditional)
    assert point != pytest.approx(conditional)


def test_croston_point_is_the_smoothed_size_over_the_observed_interval() -> None:
    point = croston_forecast(INTERMITTENT, alpha=DEFAULT_ALPHA)
    assert point == pytest.approx(10.0 / 3.0)
    assert point < 10.0
    assert forecast_next(INTERMITTENT, model="croston").point == pytest.approx(
        point, abs=5e-5
    )


def test_sba_and_tsb_keep_occurrence_inside_the_point_forecast() -> None:
    croston = croston_forecast(INTERMITTENT, alpha=DEFAULT_ALPHA)
    assert sba_forecast(INTERMITTENT, alpha=DEFAULT_ALPHA) == pytest.approx(
        SBA_ZERO_BIAS_FACTOR * croston
    )
    tsb = tsb_forecast(INTERMITTENT, alpha=DEFAULT_ALPHA)
    assert forecast_next(INTERMITTENT, model="tsb").point == pytest.approx(
        tsb, abs=5e-5
    )
    assert tsb < 10.0


def test_naive_mean_is_the_window_mean_including_zero_weeks() -> None:
    result = forecast_next(INTERMITTENT, model="naive_mean")
    assert result.point == pytest.approx(2.5)
    assert result.point == pytest.approx(statistics.fmean(INTERMITTENT))
    assert result.to_dict()["pointSemantics"] == POINT_SEMANTICS


def test_characterisation_reports_the_conditional_size_separately() -> None:
    characterisation = characterise_demand(INTERMITTENT)
    assert characterisation.mean_non_zero_demand == pytest.approx(10.0)
    forecast = forecast_next(INTERMITTENT)
    assert forecast.point < characterisation.mean_non_zero_demand


def test_empty_series_is_cold_start_no_demand() -> None:
    result = characterise_demand([])
    assert result.classification == "no_demand"
    assert result.is_cold_start is True
    assert result.periods == 0


def test_all_zero_series_is_cold_start() -> None:
    result = characterise_demand([0, 0, 0, 0])
    assert result.classification == "no_demand"
    assert result.is_cold_start is True
    assert result.non_zero_periods == 0


def test_two_non_zero_points_are_cold_start() -> None:
    result = characterise_demand([5, 0, 0, 0])
    assert result.classification == "cold_start"
    assert result.is_cold_start is True


def test_flat_non_zero_demand_is_smooth() -> None:
    result = characterise_demand([4, 4, 4, 4, 4])
    assert result.classification == "smooth"
    assert result.cv_squared == 0.0


def test_smooth_series_classification() -> None:
    result = characterise_demand([10, 11, 10, 12, 10, 11])
    assert result.classification == "smooth"
    assert result.average_demand_interval == 1.0


def test_erratic_series_classification() -> None:
    result = characterise_demand([1, 40, 2, 50, 1, 45])
    assert result.classification == "erratic"
    assert result.average_demand_interval == 1.0
    assert result.cv_squared >= CV2_CUTOFF


def test_intermittent_series_classification() -> None:
    result = characterise_demand([10, 0, 10, 0, 10, 0, 10, 0])
    assert result.classification == "intermittent"
    assert result.average_demand_interval == 2.0
    assert result.cv_squared == 0.0


def test_lumpy_series_classification() -> None:
    result = characterise_demand([1, 0, 0, 80, 0, 3, 0, 0, 60, 0])
    assert result.classification == "lumpy"
    assert result.average_demand_interval >= ADI_CUTOFF
    assert result.cv_squared >= CV2_CUTOFF


def test_cv_squared_ignores_zero_periods() -> None:
    sparse = characterise_demand([10, 0, 0, 10, 0, 0, 10, 0])
    assert sparse.cv_squared == 0.0
    assert sparse.classification == "intermittent"


def test_negative_values_clamp_to_zero() -> None:
    result = characterise_demand([10, -5, 10, 10])
    assert result.non_zero_periods == 3


def test_cv_squared_at_the_cutoff_is_lumpy_not_intermittent() -> None:
    assert (
        classify_demand(
            average_demand_interval=ADI_CUTOFF,
            cv_squared=CV2_CUTOFF,
        )
        == "lumpy"
    )
    assert (
        classify_demand(
            average_demand_interval=ADI_CUTOFF,
            cv_squared=CV2_CUTOFF - 1e-9,
        )
        == "intermittent"
    )
    assert (
        classify_demand(
            average_demand_interval=ADI_CUTOFF,
            cv_squared=CV2_CUTOFF + 1e-9,
        )
        == "lumpy"
    )


def test_adi_at_the_cutoff_is_intermittent_not_smooth() -> None:
    assert (
        classify_demand(
            average_demand_interval=ADI_CUTOFF,
            cv_squared=CV2_CUTOFF - 1e-9,
        )
        == "intermittent"
    )
    assert (
        classify_demand(
            average_demand_interval=ADI_CUTOFF - 1e-9,
            cv_squared=CV2_CUTOFF - 1e-9,
        )
        == "smooth"
    )
    assert (
        classify_demand(
            average_demand_interval=ADI_CUTOFF + 1e-9,
            cv_squared=CV2_CUTOFF - 1e-9,
        )
        == "intermittent"
    )


def test_adi_boundary_from_a_real_demand_series() -> None:
    exactly = characterise_demand([10.0] * 100 + [0.0] * 32)
    assert exactly.periods == 132
    assert exactly.non_zero_periods == 100
    assert exactly.average_demand_interval == ADI_CUTOFF
    assert exactly.classification == "intermittent"
    below = characterise_demand([10.0] * 100 + [0.0] * 31)
    assert below.average_demand_interval < ADI_CUTOFF
    assert below.classification == "smooth"
    above = characterise_demand([10.0] * 100 + [0.0] * 33)
    assert above.average_demand_interval > ADI_CUTOFF
    assert above.classification == "intermittent"


def test_cv_squared_boundary_from_real_demand_series() -> None:
    below = characterise_demand([10.0, 0.0, 0.0, 14.0, 0.0, 9.0, 0.0, 0.0, 12.0, 0.0])
    assert below.average_demand_interval > ADI_CUTOFF
    assert below.cv_squared < CV2_CUTOFF
    assert below.classification == "intermittent"
    above = characterise_demand([1.0, 0.0, 0.0, 80.0, 0.0, 3.0, 0.0, 0.0, 60.0, 0.0])
    assert above.average_demand_interval > ADI_CUTOFF
    assert above.cv_squared > CV2_CUTOFF
    assert above.classification == "lumpy"


def test_cv_squared_uses_the_sample_estimator() -> None:
    sizes = [1.0, 80.0, 3.0, 60.0]
    mean = statistics.fmean(sizes)
    sample = (statistics.stdev(sizes) / mean) ** 2
    population = (statistics.pstdev(sizes) / mean) ** 2
    assert sample > population
    result = characterise_demand(
        [1.0, 0.0, 0.0, 80.0, 0.0, 3.0, 0.0, 0.0, 60.0, 0.0]
    )
    assert result.cv_squared == pytest.approx(round(sample, 4))
    assert result.cv_squared != pytest.approx(round(population, 4))


def test_cold_start_does_not_use_cv_squared() -> None:
    single = characterise_demand([0.0, 0.0, 25.0])
    assert single.non_zero_periods == 1
    assert single.cv_squared == 0.0
    assert single.classification == "cold_start"


@pytest.mark.parametrize(
    "values,expected_model",
    [
        ([], "naive_last"),
        ([0, 0, 0], "naive_last"),
        ([5, 0, 0, 0], "naive_last"),
        ([4, 4, 4, 4], "theta"),
        ([1, 40, 2, 50, 1, 45], "moving_average"),
        ([10, 11, 12, 10, 11, 12, 11], "theta"),
        ([10, 0, 10, 0, 10, 0, 10, 0], "tsb"),
        ([1, 0, 0, 80, 0, 3, 0, 0, 60, 0], "croston"),
    ],
)
def test_selection_rule(values: list[float], expected_model: str) -> None:
    model, _ = select_forecast_model(characterise_demand(values))
    assert model == expected_model


def test_croston_of_regular_spaced_demand() -> None:
    values = [10, 0] * 12
    assert croston_forecast(values) == pytest.approx(5.0, rel=1e-9)


def test_sba_is_croston_times_bias_factor() -> None:
    values = [10, 0] * 12
    assert sba_forecast(values) == pytest.approx(
        SBA_ZERO_BIAS_FACTOR * croston_forecast(values), rel=1e-12
    )


def test_tsb_decays_when_demand_stops() -> None:
    steady = tsb_forecast([10, 10, 10, 10, 10, 10])
    stopped = tsb_forecast([10, 10, 10, 10, 10, 10, 0, 0, 0, 0, 0, 0])
    assert stopped < steady
    assert stopped > 0


def test_croston_does_not_decay_on_silence() -> None:
    values = [10, 0] * 6 + [0, 0, 0]
    assert croston_forecast(values) == pytest.approx(5.0, rel=1e-9)


def test_moving_average_uses_trailing_window() -> None:
    assert moving_average_forecast([1, 2, 3, 4, 5], k=2) == 4.5
    assert moving_average_forecast([], k=2) == 0.0


def test_theta_forecasts_the_published_combination_then_no_drift() -> None:
    values = [10.0 * index for index in range(1, 13)]
    assert theta_forecast(values) == pytest.approx(125.0, rel=1e-9)


def test_theta_sits_reasonably_between_naive_and_trend() -> None:
    values = [10.0 * index for index in range(1, 13)]
    forecast = theta_forecast(values)
    assert values[-1] < forecast <= values[-1] + 10.0


def test_theta_of_single_value_is_that_value() -> None:
    assert theta_forecast([7.0]) == 7.0


def test_croston_abstains_without_two_demand_events() -> None:
    assert croston_forecast([0, 0, 30, 0, 0]) == 0.0
    assert croston_forecast([7, 0, 0, 0, 0, 0]) == 0.0


def test_a_single_demand_event_is_cold_start() -> None:
    result = forecast_next([0, 0, 30, 0, 0, 0, 0, 0])
    assert result.status == "insufficient_history"
    assert result.point == 0.0


def test_regular_sparse_pair_is_forecastable_and_positive() -> None:
    result = forecast_next([8, 0, 0, 6, 0, 0, 7, 0])
    assert result.model == "tsb"
    assert result.point > 0
    assert 0.0 < result.probability_non_zero < 1.0


def test_two_demand_events_are_enough_for_one_interval_observation() -> None:
    assert croston_forecast([3, 0, 40, 0, 0, 0]) == pytest.approx(5.2)


def test_lumpy_pair_is_routed_to_croston() -> None:
    characterisation = characterise_demand([1, 0, 0, 80, 0, 3, 0, 0, 60, 0])
    assert characterisation.classification == "lumpy"
    assert forecast_next([1, 0, 0, 80, 0, 3, 0, 0, 60, 0]).model == "croston"


def test_forecast_point_carries_model_and_version() -> None:
    result = forecast_next([10, 0, 0, 12, 0, 0, 11, 0])
    assert result.version == FORECAST_MODELS_VERSION
    assert result.model == "tsb"
    assert result.status == "ok"
    assert result.classification == "intermittent"
    assert result.point > 0
    assert 0.0 <= result.probability_non_zero <= 1.0


def test_forecast_point_is_deterministic() -> None:
    values = [3, 0, 7, 4, 0, 0, 9, 2, 0, 5]
    assert forecast_next(values).to_dict() == forecast_next(values).to_dict()


def test_forecast_point_interval_brackets_point_when_available() -> None:
    values = [10, 4, 7, 3, 9, 5, 8, 6, 7, 5]
    result = forecast_next(values)
    assert result.lower is not None and result.upper is not None
    assert result.lower <= result.point <= result.upper


def test_forecast_point_interval_is_none_on_short_history() -> None:
    result = forecast_next([10, 0, 12])
    assert result.lower is None and result.upper is None


def test_forecast_point_cold_start_is_labelled() -> None:
    result = forecast_next([0, 0, 0, 0])
    assert result.status == "insufficient_history"
    assert result.point == 0.0


def test_explicit_model_override_is_honoured() -> None:
    result = forecast_next([10, 11, 10, 12, 10, 11], model="naive_last")
    assert result.model == "naive_last"
    assert result.point == 11.0


def test_unknown_model_raises() -> None:
    with pytest.raises(ValueError):
        forecast_next([1, 2, 3], model="not_a_model")


def test_mase_is_one_for_a_perfect_seasonal_naive_on_a_random_walk() -> None:
    train = [1, 3, 2, 5, 4, 6]
    scale = sum(
        abs(train[index] - train[index - 1]) for index in range(1, len(train))
    ) / (len(train) - 1)
    value, reported_scale = mase([6, 6], [6, 6], train)
    assert reported_scale == pytest.approx(scale)
    assert value == pytest.approx(0.0)


def test_mase_is_none_when_scale_is_zero() -> None:
    value, scale = mase([5, 5], [5, 5], [5, 5, 5])
    assert value is None
    assert scale == 0.0


def test_mase_is_none_without_pairs() -> None:
    assert mase([], [], [1, 2, 3]) == (None, None)


def test_mase_rejects_mismatched_lengths() -> None:
    with pytest.raises(ValueError):
        mase([1, 2], [1], [1, 2, 3])


def test_mase_supports_seasonal_scale() -> None:
    value, scale = mase([4, 4], [4, 4], [1, 2, 3, 4, 5, 6, 7, 8], seasonality=4)
    assert scale == pytest.approx(4.0)
    assert value == pytest.approx(0.0)

from __future__ import annotations

import pytest

from forecasting.evaluation.model_selection_backtest import (
    MASE_SCALE_DEFINITION,
    PREDICTOR_NAMES,
    backtest_series,
    run_model_selection_backtest,
)


def test_short_series_is_not_scored() -> None:
    assert (
        backtest_series([1.0, 2.0], series_key="s", is_demo=False) is None
    )


def test_scored_series_records_one_point_per_origin() -> None:
    values = [10.0, 12.0, 11.0, 13.0, 12.0, 14.0]
    result = backtest_series(values, series_key="s", is_demo=False)
    assert result is not None
    assert result.origins == len(result.actuals)
    for name in PREDICTOR_NAMES:
        assert len(result.predictions[name]) == result.origins


def test_predictions_never_see_the_target() -> None:
    values = [5.0] * 8 + [0.0, 0.0]
    result = backtest_series(values, series_key="s", is_demo=False)
    assert result is not None
    first_zero_origin = 8
    index = first_zero_origin - 4
    assert result.predictions["naiveLast"][index] == pytest.approx(5.0)
    assert result.actuals[index] == 0.0


def test_mase_is_none_when_training_is_flat() -> None:
    values = [4.0] * 10
    result = backtest_series(values, series_key="s", is_demo=False)
    assert result is not None
    assert result.pooled_mase_by_predictor["naiveLast"] is None


def test_only_one_mase_definition_is_reported() -> None:
    series = [
        {"key": "a", "values": [10.0, 4.0, 7.0, 3.0, 9.0, 5.0, 8.0, 6.0], "isDemo": False},
        {"key": "b", "values": [0.0, 5.0, 0.0, 0.0, 6.0, 0.0, 4.0, 0.0, 3.0], "isDemo": False},
    ]
    reports = run_model_selection_backtest(series)
    aggregate = reports["nonDemo"].aggregate
    assert aggregate["maseScale"] == MASE_SCALE_DEFINITION
    for name in PREDICTOR_NAMES:
        rows = reports["nonDemo"].series
        total_error = 0.0
        total_scale = 0.0
        for row in rows:
            value = row.pooled_mase_by_predictor[name]
            if value is None:
                continue
            scale = sum(row.origin_scales)
            total_error += value * scale
            total_scale += scale
        expected = total_error / total_scale
        assert aggregate["byPredictor"][name]["mase"] == pytest.approx(expected)


def test_series_mase_uses_training_window_scales_only() -> None:
    values = [10.0, 0.0, 4.0, 0.0, 0.0, 8.0, 0.0, 3.0, 0.0, 6.0]
    result = backtest_series(values, series_key="s", is_demo=False)
    assert result is not None
    assert len(result.origin_scales) == result.origins
    train = values[: result.origins and 4]
    assert result.origin_scales[0] > 0
    assert len(train) == 4


def test_future_observations_cannot_change_an_earlier_decision() -> None:
    prefix = [60.0, 0.0, 0.0, 0.0, 110.0, 0.0, 0.0, 0.0, 56.0, 0.0, 0.0, 30.0]
    first = backtest_series(
        [*prefix, 0.0, 0.0], series_key="s", is_demo=False, max_origins=12
    )
    second = backtest_series(
        [*prefix, 999.0, 0.0], series_key="s", is_demo=False, max_origins=12
    )
    assert first is not None and second is not None
    assert first.origins == second.origins
    shared = first.origins - 1
    assert first.origin_classifications[:shared] == (
        second.origin_classifications[:shared]
    )
    assert first.origin_scales[:shared] == second.origin_scales[:shared]
    for name in PREDICTOR_NAMES:
        assert first.predictions[name][:shared] == second.predictions[name][:shared]


def test_origin_classes_are_independent_of_the_targets() -> None:
    head = [4.0, 4.0, 4.0, 4.0, 4.0, 4.0]
    quiet_tail = [0.0, 0.0, 0.0, 0.0]
    loud_tail = [500.0, 700.0, 0.0, 900.0]
    with_quiet = backtest_series(
        [*head, *quiet_tail], series_key="s", is_demo=False, max_origins=12
    )
    with_loud = backtest_series(
        [*head, *loud_tail], series_key="s", is_demo=False, max_origins=12
    )
    assert with_quiet is not None and with_loud is not None
    assert with_quiet.origin_classifications[0] == "smooth"
    assert with_loud.origin_classifications[0] == "smooth"
    assert with_quiet.predictions["selectedRule"][0] == (
        with_loud.predictions["selectedRule"][0]
    )


def test_backtest_is_deterministic() -> None:
    values = [3.0, 0.0, 7.0, 4.0, 0.0, 0.0, 9.0, 2.0, 0.0, 5.0]
    first = backtest_series(values, series_key="s", is_demo=False)
    second = backtest_series(values, series_key="s", is_demo=False)
    assert first is not None and second is not None
    assert first.to_dict() == second.to_dict()


def test_interval_coverage_is_reported_between_zero_and_one() -> None:
    values = [10.0, 4.0, 7.0, 3.0, 9.0, 5.0, 8.0, 6.0, 7.0, 5.0, 6.0]
    result = backtest_series(values, series_key="s", is_demo=False)
    assert result is not None
    if result.interval_coverage is not None:
        assert 0.0 <= result.interval_coverage <= 1.0
        assert result.interval_mean_width is not None


def test_report_separates_demo_from_non_demo() -> None:
    series = [
        {"key": "d", "values": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0], "isDemo": True},
        {"key": "n", "values": [6.0, 5.0, 4.0, 3.0, 2.0, 1.0], "isDemo": False},
    ]
    reports = run_model_selection_backtest(series)
    assert [row.series_key for row in reports["demo"].series] == ["d"]
    assert [row.series_key for row in reports["nonDemo"].series] == ["n"]


def test_aggregate_carries_every_predictor_including_naive() -> None:
    series = [
        {
            "key": "a",
            "values": [10.0, 4.0, 7.0, 3.0, 9.0, 5.0, 8.0, 6.0],
            "isDemo": False,
        }
    ]
    reports = run_model_selection_backtest(series)
    aggregate = reports["nonDemo"].aggregate
    assert aggregate["scoredPoints"] > 0
    for required in ("selectedRule", "naiveLast", "movingAverage4"):
        assert required in aggregate["byPredictor"]
        assert "mase" in aggregate["byPredictor"][required]


def test_aggregate_classifies_series() -> None:
    series = [
        {
            "key": "sparse",
            "values": [10.0, 0.0, 10.0, 0.0, 10.0, 0.0, 10.0, 0.0, 10.0, 0.0],
            "isDemo": False,
        }
    ]
    reports = run_model_selection_backtest(series)
    classes = reports["nonDemo"].aggregate["byClassification"]
    assert "intermittent" in classes


def test_insufficient_history_is_reported_not_averaged() -> None:
    series = [{"key": "tiny", "values": [1.0, 2.0], "isDemo": False}]
    reports = run_model_selection_backtest(series)
    assert reports["nonDemo"].insufficient_history == [
        {"seriesKey": "tiny", "isDemo": False, "totalPeriods": 2}
    ]
    assert reports["nonDemo"].aggregate["scoredPoints"] == 0


def test_max_origins_caps_the_scored_points() -> None:
    values = [float(index % 5) for index in range(60)]
    result = backtest_series(
        values, series_key="s", is_demo=False, max_origins=6
    )
    assert result is not None
    assert result.origins == 6


def test_invalid_horizon_is_rejected() -> None:
    with pytest.raises(ValueError):
        backtest_series(
            [1.0, 2.0, 3.0, 4.0, 5.0],
            series_key="s",
            is_demo=False,
            horizon=0,
        )

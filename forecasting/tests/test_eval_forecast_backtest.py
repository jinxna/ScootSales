from datetime import date, timedelta

import pytest

from forecasting.evaluation.forecast_backtest import (
    DemandSeries,
    run_forecast_backtest,
)

BASE_MONDAY = date(2026, 1, 5)


def _series(retailer_id, product_id, quantities, *, is_demo=False, start=0):
    events = [
        (BASE_MONDAY + timedelta(weeks=start + i, days=6), float(qty))
        for i, qty in enumerate(quantities)
    ]
    return DemandSeries(
        retailer_id=retailer_id,
        product_id=product_id,
        events=events,
        is_demo=is_demo,
    )


def test_insufficient_history_cohort_not_averaged() -> None:
    short = _series("R1", "P1", [1, 2, 3, 4, 5])
    reports = run_forecast_backtest([short], holdout_weeks=3)
    non_demo = reports["nonDemo"]
    assert len(non_demo.pairs) == 0
    assert len(non_demo.insufficient_history) == 1
    assert non_demo.insufficient_history[0].total_weeks == 5
    assert non_demo.model is None


def test_baselines_share_the_holdout_window() -> None:
    series = _series("R1", "P1", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    reports = run_forecast_backtest([series], holdout_weeks=3, moving_average_k=4)
    pair = reports["nonDemo"].pairs[0]
    assert pair.model.n == 3
    assert pair.naive.n == 3
    assert pair.moving_average.n == 3
    assert pair.actuals == (8.0, 9.0, 10.0)
    assert pair.naive.mae == pytest.approx(1.0)
    assert pair.moving_average.mae == pytest.approx(2.5)


def test_precomputed_model_predictions_override() -> None:
    series = _series("R1", "P1", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    reports = run_forecast_backtest(
        [series],
        holdout_weeks=3,
        precomputed_predictions={("R1", "P1"): [8.0, 9.0, 10.0]},
    )
    pair = reports["nonDemo"].pairs[0]
    assert pair.model.mae == pytest.approx(0.0)
    assert pair.naive.mae == pytest.approx(1.0)


def test_callable_model_predictor_walk_forward() -> None:
    series = _series("R1", "P1", [5, 5, 5, 5, 5, 5, 5, 5, 5, 5])
    reports = run_forecast_backtest(
        [series],
        holdout_weeks=3,
        model_predictor=lambda train: sum(train) / len(train),
    )
    pair = reports["nonDemo"].pairs[0]
    assert pair.model.mae == pytest.approx(0.0)
    assert pair.naive.mae == pytest.approx(0.0)


def test_demo_and_non_demo_are_separate_cohorts() -> None:
    demo = _series("R9", "P9", [2, 2, 2, 2, 2, 2, 2, 2], is_demo=True)
    live = _series("R1", "P1", [1, 2, 3, 4, 5, 6, 7, 8])
    reports = run_forecast_backtest([demo, live], holdout_weeks=2)
    assert len(reports["demo"].pairs) == 1
    assert len(reports["nonDemo"].pairs) == 1
    assert reports["demo"].pairs[0].is_demo is True
    assert reports["nonDemo"].pairs[0].is_demo is False


def test_aggregate_pools_across_pairs() -> None:
    a = _series("R1", "P1", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    b = _series("R2", "P2", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    reports = run_forecast_backtest([a, b], holdout_weeks=3)
    aggregate = reports["nonDemo"]
    assert aggregate.model is not None
    assert aggregate.naive.n == 6
    assert aggregate.naive.mae == pytest.approx(1.0)
    assert len(aggregate.worst_cases) == 2
    assert set(aggregate.to_dict()["aggregate"]) == {
        "model",
        "naive",
        "movingAverage",
    }


def test_series_that_stopped_hold_out_their_trailing_zero_weeks() -> None:
    a = _series("R1", "P1", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    b = _series("R2", "P2", [5, 5, 5, 5, 5, 5])
    reports = run_forecast_backtest([a, b], holdout_weeks=3)
    pairs = {pair.retailer_id: pair for pair in reports["nonDemo"].pairs}
    assert pairs["R2"].total_weeks == 10
    assert pairs["R2"].actuals == (0.0, 0.0, 0.0)
    assert pairs["R1"].actuals == (8.0, 9.0, 10.0)


def test_holdout_ends_at_the_last_complete_non_demo_week() -> None:
    real = DemandSeries(
        "R1", "P1",
        [(BASE_MONDAY + timedelta(weeks=i, days=6), float(i + 1)) for i in range(10)],
    )
    late = DemandSeries("R2", "P2", [(BASE_MONDAY + timedelta(weeks=10, days=2), 5.0)])
    demo = DemandSeries("D1", "P1", [(BASE_MONDAY + timedelta(weeks=20), 1.0)], is_demo=True)
    reports = run_forecast_backtest([real, late, demo], holdout_weeks=3)
    pair = reports["nonDemo"].pairs[0]
    assert pair.total_weeks == 10
    assert pair.actuals == (8.0, 9.0, 10.0)

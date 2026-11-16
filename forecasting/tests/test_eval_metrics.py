import math

import pytest

from forecasting.evaluation.metrics import (
    classification_from_sets,
    classification_metrics,
    mae,
    mape,
    regression_metrics,
    rmse,
)


def test_empty_inputs_return_none() -> None:
    assert mae([], []) is None
    assert rmse([], []) is None
    value, coverage = mape([], [])
    assert value is None
    assert coverage == 0.0
    metrics = regression_metrics([], [])
    assert metrics.n == 0
    assert metrics.mae is None and metrics.rmse is None and metrics.mape is None


def test_mismatched_lengths_raise() -> None:
    with pytest.raises(ValueError):
        mae([1.0], [1.0, 2.0])


def test_mae_and_rmse_basic() -> None:
    actuals = [10.0, 20.0, 30.0]
    preds = [12.0, 18.0, 33.0]
    assert mae(actuals, preds) == pytest.approx((2 + 2 + 3) / 3)
    assert rmse(actuals, preds) == pytest.approx(
        math.sqrt((4 + 4 + 9) / 3)
    )


def test_mape_skips_zero_actuals_and_reports_coverage() -> None:
    actuals = [10.0, 0.0, 20.0]
    preds = [11.0, 5.0, 18.0]
    value, coverage = mape(actuals, preds)
    assert coverage == pytest.approx(2 / 3)
    assert value == pytest.approx(10.0)


def test_mape_all_zero_actuals_is_none() -> None:
    value, coverage = mape([0.0, 0.0], [1.0, 2.0])
    assert value is None
    assert coverage == 0.0


def test_classification_metrics_defined() -> None:
    metrics = classification_metrics(
        true_positives=8, false_positives=2, false_negatives=4
    )
    assert metrics.precision == pytest.approx(0.8)
    assert metrics.recall == pytest.approx(8 / 12)
    assert metrics.f1 == pytest.approx(
        2 * 0.8 * (8 / 12) / (0.8 + 8 / 12)
    )


def test_classification_undefined_denominators_are_none() -> None:
    no_pred = classification_metrics(0, 0, 5)
    assert no_pred.precision is None
    assert no_pred.recall == pytest.approx(0.0)
    assert no_pred.f1 is None
    no_actual = classification_metrics(0, 3, 0)
    assert no_actual.recall is None
    assert no_actual.precision == pytest.approx(0.0)
    assert no_actual.f1 is None


def test_classification_from_sets() -> None:
    predicted = {("R1", "P1"), ("R1", "P2"), ("R2", "P1")}
    actual = {("R1", "P1"), ("R3", "P9")}
    metrics = classification_from_sets(predicted, actual)
    assert metrics.true_positives == 1
    assert metrics.false_positives == 2
    assert metrics.false_negatives == 1
    assert metrics.precision == pytest.approx(1 / 3)
    assert metrics.recall == pytest.approx(1 / 2)


def test_to_dict_shapes() -> None:
    reg = regression_metrics([10.0], [9.0]).to_dict()
    assert set(reg) == {"n", "mae", "rmse", "mape", "mapeCoverage"}
    clf = classification_metrics(1, 1, 1).to_dict()
    assert set(clf) == {
        "truePositives",
        "falsePositives",
        "falseNegatives",
        "precision",
        "recall",
        "f1",
    }

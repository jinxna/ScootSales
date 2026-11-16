from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Sequence


def _paired(
    actuals: Sequence[float],
    predictions: Sequence[float],
) -> list[tuple[float, float]]:
    if len(actuals) != len(predictions):
        raise ValueError(
            "actuals and predictions must have equal length "
            f"({len(actuals)} != {len(predictions)})"
        )
    return [(float(a), float(p)) for a, p in zip(actuals, predictions)]


def mae(
    actuals: Sequence[float],
    predictions: Sequence[float],
) -> float | None:
    pairs = _paired(actuals, predictions)
    if not pairs:
        return None
    return sum(abs(a - p) for a, p in pairs) / len(pairs)


def rmse(
    actuals: Sequence[float],
    predictions: Sequence[float],
) -> float | None:
    pairs = _paired(actuals, predictions)
    if not pairs:
        return None
    return math.sqrt(sum((a - p) ** 2 for a, p in pairs) / len(pairs))


def mape(
    actuals: Sequence[float],
    predictions: Sequence[float],
) -> tuple[float | None, float]:
    pairs = _paired(actuals, predictions)
    if not pairs:
        return None, 0.0
    scorable = [(a, p) for a, p in pairs if a != 0]
    coverage = len(scorable) / len(pairs)
    if not scorable:
        return None, 0.0
    value = sum(abs((a - p) / a) for a, p in scorable) / len(scorable) * 100.0
    return value, coverage


@dataclass(frozen=True)
class RegressionMetrics:
    n: int
    mae: float | None
    rmse: float | None
    mape: float | None
    mape_coverage: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "n": self.n,
            "mae": self.mae,
            "rmse": self.rmse,
            "mape": self.mape,
            "mapeCoverage": self.mape_coverage,
        }


def wape(
    actuals: Sequence[float],
    predictions: Sequence[float],
) -> float | None:
    pairs = _paired(actuals, predictions)
    volume = sum(abs(a) for a, _ in pairs)
    if volume <= 0:
        return None
    return sum(abs(a - p) for a, p in pairs) / volume


def relative_bias(
    actuals: Sequence[float],
    predictions: Sequence[float],
) -> float | None:
    pairs = _paired(actuals, predictions)
    volume = sum(abs(a) for a, _ in pairs)
    if volume <= 0:
        return None
    return sum(p - a for a, p in pairs) / volume


def regression_metrics(
    actuals: Sequence[float],
    predictions: Sequence[float],
) -> RegressionMetrics:
    pairs = _paired(actuals, predictions)
    mape_value, coverage = mape(actuals, predictions)
    return RegressionMetrics(
        n=len(pairs),
        mae=mae(actuals, predictions),
        rmse=rmse(actuals, predictions),
        mape=mape_value,
        mape_coverage=coverage,
    )


@dataclass(frozen=True)
class ClassificationMetrics:
    true_positives: int
    false_positives: int
    false_negatives: int
    precision: float | None
    recall: float | None
    f1: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "truePositives": self.true_positives,
            "falsePositives": self.false_positives,
            "falseNegatives": self.false_negatives,
            "precision": self.precision,
            "recall": self.recall,
            "f1": self.f1,
        }


def classification_metrics(
    true_positives: int,
    false_positives: int,
    false_negatives: int,
) -> ClassificationMetrics:
    predicted_positive = true_positives + false_positives
    actual_positive = true_positives + false_negatives
    precision = (
        true_positives / predicted_positive if predicted_positive else None
    )
    recall = true_positives / actual_positive if actual_positive else None
    if precision is None or recall is None or (precision + recall) == 0:
        f1 = None
    else:
        f1 = 2 * precision * recall / (precision + recall)
    return ClassificationMetrics(
        true_positives=true_positives,
        false_positives=false_positives,
        false_negatives=false_negatives,
        precision=precision,
        recall=recall,
        f1=f1,
    )


def classification_from_sets(
    predicted: set[Any],
    actual: set[Any],
) -> ClassificationMetrics:
    true_positives = len(predicted & actual)
    false_positives = len(predicted - actual)
    false_negatives = len(actual - predicted)
    return classification_metrics(
        true_positives, false_positives, false_negatives
    )

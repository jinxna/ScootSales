from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from typing import Any, Callable, Sequence

from forecasting.ai_core.forecast_models import (
    FORECAST_MODELS_VERSION,
    ForecastPoint,
    characterise_demand,
    forecast_next,
    mase,
    moving_average_forecast,
)

from .metrics import regression_metrics, relative_bias, wape

DEFAULT_MIN_TRAIN_PERIODS = 4
DEFAULT_MAX_ORIGINS = 12
DEFAULT_HORIZON = 1

MASE_SCALE_DEFINITION = "perOriginTrainingWindowSeasonalNaiveMae"

Predictor = Callable[[Sequence[float]], float]


def make_selected_predictor() -> Predictor:
    def predictor(train: Sequence[float]) -> float:
        return forecast_next(train, with_interval=False).point

    return predictor


def _naive_last(train: Sequence[float]) -> float:
    return float(train[-1]) if train else 0.0


def _moving_average(train: Sequence[float]) -> float:
    return moving_average_forecast(train)


def _croston(train: Sequence[float]) -> float:
    return forecast_next(train, model="croston", with_interval=False).point


def _sba(train: Sequence[float]) -> float:
    return forecast_next(train, model="sba", with_interval=False).point


def _tsb(train: Sequence[float]) -> float:
    return forecast_next(train, model="tsb", with_interval=False).point


def _theta(train: Sequence[float]) -> float:
    return forecast_next(train, model="theta", with_interval=False).point


PREDICTOR_NAMES: tuple[str, ...] = (
    "selectedRule",
    "naiveLast",
    "movingAverage4",
    "croston",
    "sba",
    "tsb",
    "theta",
)

_BASELINE_PREDICTORS: dict[str, Predictor] = {
    "naiveLast": _naive_last,
    "movingAverage4": _moving_average,
    "croston": _croston,
    "sba": _sba,
    "tsb": _tsb,
    "theta": _theta,
}


def predictor_roster() -> tuple[tuple[str, Predictor], ...]:
    return (
        ("selectedRule", make_selected_predictor()),
        *((name, _BASELINE_PREDICTORS[name]) for name in PREDICTOR_NAMES[1:]),
    )


@dataclass(frozen=True)
class SeriesBacktest:
    series_key: str
    is_demo: bool
    total_periods: int
    origins: int
    zero_scale_points: int
    classification: str
    origin_classifications: tuple[str, ...]
    origin_scales: tuple[float, ...]
    actuals: tuple[float, ...]
    predictions: dict[str, tuple[float, ...]]
    pooled_mase_by_predictor: dict[str, float | None]
    interval_coverage: float | None
    interval_mean_width: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "seriesKey": self.series_key,
            "isDemo": self.is_demo,
            "totalPeriods": self.total_periods,
            "origins": self.origins,
            "zeroScalePoints": self.zero_scale_points,
            "classification": self.classification,
            "originClassifications": list(self.origin_classifications),
            "originScales": [round(value, 4) for value in self.origin_scales],
            "actuals": list(self.actuals),
            "predictions": {
                name: list(values) for name, values in self.predictions.items()
            },
            "pooledMase": dict(self.pooled_mase_by_predictor),
            "intervalCoverage": self.interval_coverage,
            "intervalMeanWidth": self.interval_mean_width,
        }


@dataclass
class SelectionBacktestReport:
    cohort: str
    min_train_periods: int
    max_origins: int
    horizon: int
    seasonality: int
    models_version: str = FORECAST_MODELS_VERSION
    series: list[SeriesBacktest] = field(default_factory=list)
    insufficient_history: list[dict[str, Any]] = field(default_factory=list)
    aggregate: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "cohort": self.cohort,
            "minTrainPeriods": self.min_train_periods,
            "maxOrigins": self.max_origins,
            "horizon": self.horizon,
            "seasonality": self.seasonality,
            "modelsVersion": self.models_version,
            "maseScale": MASE_SCALE_DEFINITION,
            "classificationScope": "perOriginTrainingWindow",
            "seriesCount": len(self.series),
            "insufficientHistoryCount": len(self.insufficient_history),
            "insufficientHistory": list(self.insufficient_history),
            "aggregate": dict(self.aggregate),
            "series": [row.to_dict() for row in self.series],
        }


def _pool_mase(pairs: Sequence[tuple[float, float] | None]) -> float | None:
    usable = [pair for pair in pairs if pair is not None]
    if not usable:
        return None
    total_error = sum(error for error, _ in usable)
    total_scale = sum(scale for _, scale in usable)
    if total_scale <= 0:
        return None
    return total_error / total_scale


def _pair_points(
    row: SeriesBacktest, predictor: str
) -> list[tuple[float, float, str] | None]:
    predictions = row.predictions.get(predictor)
    if predictions is None:
        return []
    triples: list[tuple[float, float, str] | None] = []
    for index, (actual, prediction) in enumerate(
        zip(row.actuals, predictions)
    ):
        scale = row.origin_scales[index] if index < len(row.origin_scales) else 0.0
        if scale <= 0:
            triples.append(None)
            continue
        triples.append(
            (
                abs(actual - prediction),
                scale,
                row.origin_classifications[index]
                if index < len(row.origin_classifications)
                else row.classification,
            )
        )
    return triples


def _mase_pairs(
    triples: Sequence[tuple[float, float, str] | None],
    *,
    classification: str | None = None,
) -> list[tuple[float, float] | None]:
    if classification is None:
        return [None if triple is None else triple[:2] for triple in triples]
    return [
        None if triple is None else (triple[0], triple[1])
        for triple in triples
        if triple is not None and triple[2] == classification
    ]


def series_pooled_pairs(
    report: SelectionBacktestReport, predictor: str
) -> list[tuple[float, float]]:
    rows: list[tuple[float, float]] = []
    for row in report.series:
        predictions = row.predictions.get(predictor)
        if predictions is None:
            continue
        error = 0.0
        scale = 0.0
        for index, prediction in enumerate(predictions):
            if index >= len(row.actuals) or index >= len(row.origin_scales):
                continue
            point_scale = row.origin_scales[index]
            if point_scale <= 0:
                continue
            error += abs(row.actuals[index] - prediction)
            scale += point_scale
        if scale > 0:
            rows.append((error, scale))
    return rows


def aligned_series_pairs(
    report: SelectionBacktestReport, predictors: Sequence[str]
) -> tuple[dict[str, list[tuple[float, float]]], int]:
    keys = tuple(name for name in predictors if name in report.series[0].predictions) if report.series else ()
    pairs: dict[str, list[tuple[float, float]]] = {name: [] for name in predictors}
    dropped = 0
    for row in report.series:
        expected_length = len(row.actuals)
        usable = expected_length > 0
        for name in keys:
            values = row.predictions.get(name)
            if values is None or len(values) != expected_length:
                usable = False
                break
        if usable:
            for index in range(expected_length):
                if index >= len(row.origin_scales) or row.origin_scales[index] <= 0:
                    usable = False
                    break
        if not usable:
            dropped += 1
            continue
        for name in keys:
            values = row.predictions[name]
            error = 0.0
            scale = 0.0
            for index, prediction in enumerate(values):
                scale += row.origin_scales[index]
                error += abs(row.actuals[index] - prediction)
            pairs[name].append((error, scale))
    for name in predictors:
        if name not in keys:
            pairs.pop(name, None)
    return pairs, dropped


def backtest_series(
    values: Sequence[float],
    *,
    series_key: str,
    is_demo: bool,
    min_train_periods: int = DEFAULT_MIN_TRAIN_PERIODS,
    max_origins: int = DEFAULT_MAX_ORIGINS,
    horizon: int = DEFAULT_HORIZON,
    seasonality: int = 1,
    with_intervals: bool = True,
    predictors: Sequence[tuple[str, Predictor]] | None = None,
) -> SeriesBacktest | None:
    if horizon < 1:
        raise ValueError("horizon must be at least 1")
    cleaned = [max(0.0, float(value)) for value in values]
    if predictors is None:
        predictors = predictor_roster()
    first_origin = min_train_periods
    last_origin = len(cleaned) - horizon
    if last_origin < first_origin:
        return None
    origins = list(range(first_origin, last_origin + 1))
    if len(origins) > max_origins:
        origins = origins[-max_origins:]

    actuals: list[float] = []
    predictions: dict[str, list[float]] = {name: [] for name, _ in predictors}
    errors: dict[str, list[float]] = {name: [] for name, _ in predictors}
    scales: list[float] = []
    origin_classes: list[str] = []
    zero_scale_points = 0
    interval_hits = 0
    interval_usable = 0
    interval_widths: list[float] = []

    for origin in origins:
        train = cleaned[:origin]
        target = cleaned[origin + horizon - 1]
        actuals.append(target)
        characterisation = characterise_demand(train)
        origin_classes.append(characterisation.classification)
        for name, predictor in predictors:
            prediction = max(0.0, float(predictor(train)))
            predictions[name].append(round(prediction, 4))
            errors[name].append(abs(target - prediction))
        _, scale = mase([target], [0.0], train, seasonality=seasonality)
        if not scale:
            zero_scale_points += 1
        scales.append(scale or 0.0)
        if with_intervals and horizon == 1:
            point: ForecastPoint = forecast_next(
                train, characterisation=characterisation
            )
            if point.lower is not None and point.upper is not None:
                interval_usable += 1
                if point.lower <= target <= point.upper:
                    interval_hits += 1
                interval_widths.append(point.upper - point.lower)

    pooled_mase_by_predictor: dict[str, float | None] = {}
    for name, _ in predictors:
        pairs = [
            (error, scale) if scale > 0 else None
            for error, scale in zip(errors[name], scales)
        ]
        pooled_mase_by_predictor[name] = _pool_mase(pairs)

    return SeriesBacktest(
        series_key=series_key,
        is_demo=is_demo,
        total_periods=len(cleaned),
        origins=len(origins),
        zero_scale_points=zero_scale_points,
        classification=origin_classes[0] if origin_classes else "unknown",
        origin_classifications=tuple(origin_classes),
        origin_scales=tuple(scales),
        actuals=tuple(actuals),
        predictions={
            name: tuple(values_) for name, values_ in predictions.items()
        },
        pooled_mase_by_predictor=pooled_mase_by_predictor,
        interval_coverage=(
            round(interval_hits / interval_usable, 6) if interval_usable else None
        ),
        interval_mean_width=(
            round(statistics.fmean(interval_widths), 4)
            if interval_widths
            else None
        ),
    )


def run_model_selection_backtest(
    series: Sequence[dict[str, Any]],
    *,
    min_train_periods: int = DEFAULT_MIN_TRAIN_PERIODS,
    max_origins: int = DEFAULT_MAX_ORIGINS,
    horizon: int = DEFAULT_HORIZON,
    seasonality: int = 1,
) -> dict[str, SelectionBacktestReport]:
    reports = {
        "demo": SelectionBacktestReport(
            "demo", min_train_periods, max_origins, horizon, seasonality
        ),
        "nonDemo": SelectionBacktestReport(
            "nonDemo", min_train_periods, max_origins, horizon, seasonality
        ),
    }
    for row in sorted(series, key=lambda item: str(item.get("key", ""))):
        key = str(row.get("key", ""))
        values = [float(value) for value in row.get("values", [])]
        is_demo = bool(row.get("isDemo"))
        report = reports["demo"] if is_demo else reports["nonDemo"]
        result = backtest_series(
            values,
            series_key=key,
            is_demo=is_demo,
            min_train_periods=min_train_periods,
            max_origins=max_origins,
            horizon=horizon,
            seasonality=seasonality,
        )
        if result is None:
            report.insufficient_history.append(
                {
                    "seriesKey": key,
                    "isDemo": is_demo,
                    "totalPeriods": len(values),
                }
            )
            continue
        report.series.append(result)
    for report in reports.values():
        report.aggregate = _aggregate(report)
    return reports


def _aggregate(report: SelectionBacktestReport) -> dict[str, Any]:
    if not report.series:
        return {
            "scoredPoints": 0,
            "pointsWithZeroScale": 0,
            "maseScale": MASE_SCALE_DEFINITION,
            "byPredictor": {},
            "byClassification": {},
            "originClassCounts": {},
            "intervalCoverage": None,
            "intervalMeanWidth": None,
        }
    names = list(PREDICTOR_NAMES)
    by_predictor: dict[str, Any] = {}
    for name in names:
        all_actuals: list[float] = []
        all_predictions: list[float] = []
        mase_points: list[tuple[float, float] | None] = []
        for row in report.series:
            values = row.predictions.get(name)
            if values is None:
                continue
            all_actuals.extend(row.actuals)
            all_predictions.extend(values)
            mase_points.extend(_mase_pairs(_pair_points(row, name)))
        regression = regression_metrics(all_actuals, all_predictions)
        by_predictor[name] = {
            **regression.to_dict(),
            "mase": _pool_mase(mase_points),
            "wape": wape(all_actuals, all_predictions),
            "bias": relative_bias(all_actuals, all_predictions),
        }

    class_points: dict[str, int] = {}
    class_series: dict[str, set[str]] = {}
    origin_class_counts: dict[str, int] = {}
    for row in report.series:
        if not row.origin_classifications:
            continue
        origin_class_counts[row.classification] = (
            origin_class_counts.get(row.classification, 0) + 1
        )
        for index, classification in enumerate(row.origin_classifications):
            if index >= len(row.actuals):
                continue
            class_series.setdefault(classification, set()).add(row.series_key)
            class_points[classification] = class_points.get(classification, 0) + 1

    by_classification: dict[str, Any] = {}
    for classification in sorted(class_points):
        entry: dict[str, Any] = {
            "seriesCount": len(class_series.get(classification, ())),
            "scoredPoints": class_points[classification],
        }
        for name in names:
            if all(name not in row.predictions for row in report.series):
                continue
            entry[name] = _pool_mase(
                [
                    pair
                    for row in report.series
                    if name in row.predictions
                    for pair in _mase_pairs(
                        _pair_points(row, name), classification=classification
                    )
                ]
            )
        by_classification[classification] = entry

    coverages = [
        row.interval_coverage
        for row in report.series
        if row.interval_coverage is not None
    ]
    widths = [
        row.interval_mean_width
        for row in report.series
        if row.interval_mean_width is not None
    ]
    return {
        "scoredPoints": sum(len(row.actuals) for row in report.series),
        "pointsWithZeroScale": sum(
            row.zero_scale_points for row in report.series
        ),
        "maseScale": MASE_SCALE_DEFINITION,
        "byPredictor": by_predictor,
        "byClassification": by_classification,
        "originClassCounts": dict(sorted(origin_class_counts.items())),
        "intervalCoverage": (
            round(statistics.fmean(coverages), 6) if coverages else None
        ),
        "intervalMeanWidth": (
            round(statistics.fmean(widths), 4) if widths else None
        ),
    }


__all__ = [
    "DEFAULT_HORIZON",
    "DEFAULT_MAX_ORIGINS",
    "DEFAULT_MIN_TRAIN_PERIODS",
    "MASE_SCALE_DEFINITION",
    "PREDICTOR_NAMES",
    "SelectionBacktestReport",
    "SeriesBacktest",
    "aligned_series_pairs",
    "backtest_series",
    "make_selected_predictor",
    "predictor_roster",
    "run_model_selection_backtest",
    "series_pooled_pairs",
]

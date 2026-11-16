from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any, Callable, Mapping, Sequence

from forecasting.ai_core import week_start
from forecasting.ai_core.calendar import as_kuching_date, completed_week_starts

from .metrics import RegressionMetrics, regression_metrics

DEFAULT_MIN_EXTRA_WEEKS = 3

ModelPredictor = Callable[[Sequence[float]], float]


@dataclass(frozen=True)
class DemandSeries:
    retailer_id: str
    product_id: str
    events: Sequence[tuple[Any, float]]
    is_demo: bool = False


def _to_date(value: Any) -> date:
    if isinstance(value, datetime):
        return as_kuching_date(value)
    if isinstance(value, date):
        return value
    return as_kuching_date(datetime.fromisoformat(str(value).replace("Z", "+00:00")))


def _weekly_quantities(series: DemandSeries, end_week: date) -> list[float]:
    by_week: dict[date, float] = {}
    for raw_date, quantity in series.events:
        bucket = week_start(_to_date(raw_date))
        if bucket > end_week:
            continue
        by_week[bucket] = by_week.get(bucket, 0.0) + float(quantity)
    if not by_week:
        return []
    first = min(by_week)
    last = end_week
    weeks: list[float] = []
    cursor = first
    while cursor <= last:
        weeks.append(by_week.get(cursor, 0.0))
        cursor = cursor + timedelta(weeks=1)
    return weeks


def _moving_average(train: Sequence[float], k: int) -> float:
    window = train[-k:] if k > 0 else train
    if not window:
        return 0.0
    return sum(window) / len(window)


@dataclass(frozen=True)
class PairBacktest:
    retailer_id: str
    product_id: str
    is_demo: bool
    total_weeks: int
    holdout_weeks: int
    actuals: tuple[float, ...]
    model: RegressionMetrics
    naive: RegressionMetrics
    moving_average: RegressionMetrics

    def to_dict(self) -> dict[str, Any]:
        return {
            "retailerId": self.retailer_id,
            "productId": self.product_id,
            "isDemo": self.is_demo,
            "totalWeeks": self.total_weeks,
            "holdoutWeeks": self.holdout_weeks,
            "actuals": list(self.actuals),
            "model": self.model.to_dict(),
            "naive": self.naive.to_dict(),
            "movingAverage": self.moving_average.to_dict(),
        }


@dataclass(frozen=True)
class InsufficientPair:
    retailer_id: str
    product_id: str
    is_demo: bool
    total_weeks: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "retailerId": self.retailer_id,
            "productId": self.product_id,
            "isDemo": self.is_demo,
            "totalWeeks": self.total_weeks,
        }


@dataclass
class BacktestReport:
    cohort: str
    holdout_weeks: int
    moving_average_k: int
    pairs: list[PairBacktest] = field(default_factory=list)
    insufficient_history: list[InsufficientPair] = field(default_factory=list)
    model: RegressionMetrics | None = None
    naive: RegressionMetrics | None = None
    moving_average: RegressionMetrics | None = None
    worst_cases: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "cohort": self.cohort,
            "holdoutWeeks": self.holdout_weeks,
            "movingAverageK": self.moving_average_k,
            "scoredPairCount": len(self.pairs),
            "insufficientHistoryCount": len(self.insufficient_history),
            "insufficientHistory": [
                pair.to_dict() for pair in self.insufficient_history
            ],
            "aggregate": {
                "model": self.model.to_dict() if self.model else None,
                "naive": self.naive.to_dict() if self.naive else None,
                "movingAverage": (
                    self.moving_average.to_dict()
                    if self.moving_average
                    else None
                ),
            },
            "pairs": [pair.to_dict() for pair in self.pairs],
            "worstCases": self.worst_cases,
        }


def _backtest_pair(
    series: DemandSeries,
    weekly: list[float],
    *,
    holdout_weeks: int,
    moving_average_k: int,
    model_predictor: ModelPredictor | None,
    precomputed: Sequence[float] | None,
) -> PairBacktest:
    origin = len(weekly) - holdout_weeks
    actuals: list[float] = []
    model_preds: list[float] = []
    naive_preds: list[float] = []
    ma_preds: list[float] = []
    for step in range(holdout_weeks):
        target_index = origin + step
        train = weekly[:target_index]
        actuals.append(weekly[target_index])
        naive_preds.append(train[-1] if train else 0.0)
        ma_preds.append(_moving_average(train, moving_average_k))
        if precomputed is not None:
            model_preds.append(float(precomputed[step]))
        elif model_predictor is not None:
            model_preds.append(float(model_predictor(train)))
        else:
            model_preds.append(train[-1] if train else 0.0)
    return PairBacktest(
        retailer_id=series.retailer_id,
        product_id=series.product_id,
        is_demo=series.is_demo,
        total_weeks=len(weekly),
        holdout_weeks=holdout_weeks,
        actuals=tuple(actuals),
        model=regression_metrics(actuals, model_preds),
        naive=regression_metrics(actuals, naive_preds),
        moving_average=regression_metrics(actuals, ma_preds),
    )


def _finalize(report: BacktestReport, worst_case_limit: int) -> None:
    if report.pairs:
        report.model = _weighted(report.pairs, "model")
        report.naive = _weighted(report.pairs, "naive")
        report.moving_average = _weighted(report.pairs, "moving_average")
        ranked = sorted(
            report.pairs,
            key=lambda pair: (
                pair.model.mae if pair.model.mae is not None else -1.0
            ),
            reverse=True,
        )
        report.worst_cases = [
            {
                "retailerId": pair.retailer_id,
                "productId": pair.product_id,
                "isDemo": pair.is_demo,
                "modelMae": pair.model.mae,
                "naiveMae": pair.naive.mae,
                "movingAverageMae": pair.moving_average.mae,
            }
            for pair in ranked[:worst_case_limit]
        ]


def _weighted(pairs: list[PairBacktest], attr: str) -> RegressionMetrics:
    total_n = 0
    abs_error = 0.0
    sq_error = 0.0
    mape_sum = 0.0
    mape_n = 0
    for pair in pairs:
        metrics: RegressionMetrics = getattr(pair, attr)
        if metrics.n == 0:
            continue
        total_n += metrics.n
        if metrics.mae is not None:
            abs_error += metrics.mae * metrics.n
        if metrics.rmse is not None:
            sq_error += (metrics.rmse ** 2) * metrics.n
        if metrics.mape is not None:
            scorable = round(metrics.mape_coverage * metrics.n)
            mape_sum += metrics.mape * scorable
            mape_n += scorable
    if total_n == 0:
        return RegressionMetrics(0, None, None, None, 0.0)
    return RegressionMetrics(
        n=total_n,
        mae=abs_error / total_n,
        rmse=(sq_error / total_n) ** 0.5,
        mape=(mape_sum / mape_n) if mape_n else None,
        mape_coverage=(mape_n / total_n) if total_n else 0.0,
    )


def run_forecast_backtest(
    series: Sequence[DemandSeries],
    *,
    holdout_weeks: int,
    moving_average_k: int = 4,
    model_predictor: ModelPredictor | None = None,
    precomputed_predictions: Mapping[tuple[str, str], Sequence[float]]
    | None = None,
    min_extra_weeks: int = DEFAULT_MIN_EXTRA_WEEKS,
    worst_case_limit: int = 5,
    data_end: date | None = None,
) -> dict[str, BacktestReport]:
    if holdout_weeks <= 0:
        raise ValueError("holdout_weeks must be positive")
    reports = {
        "demo": BacktestReport(
            cohort="demo",
            holdout_weeks=holdout_weeks,
            moving_average_k=moving_average_k,
        ),
        "nonDemo": BacktestReport(
            cohort="nonDemo",
            holdout_weeks=holdout_weeks,
            moving_average_k=moving_average_k,
        ),
    }
    minimum = holdout_weeks + min_extra_weeks
    ordered = sorted(series, key=lambda s: (s.retailer_id, s.product_id))
    latest = data_end
    if latest is None:
        real_dates = [
            _to_date(raw_date)
            for one in ordered
            if not one.is_demo
            for raw_date, _ in one.events
        ]
        latest = max(
            real_dates
            or [_to_date(raw_date) for one in ordered for raw_date, _ in one.events],
            default=None,
        )
    end_week = (
        completed_week_starts(latest + timedelta(days=1), weeks=1)[-1]
        if latest is not None
        else None
    )
    for one in ordered:
        report = reports["demo"] if one.is_demo else reports["nonDemo"]
        weekly = _weekly_quantities(one, end_week)
        if len(weekly) < minimum:
            report.insufficient_history.append(
                InsufficientPair(
                    retailer_id=one.retailer_id,
                    product_id=one.product_id,
                    is_demo=one.is_demo,
                    total_weeks=len(weekly),
                )
            )
            continue
        precomputed = None
        if precomputed_predictions is not None:
            precomputed = precomputed_predictions.get(
                (one.retailer_id, one.product_id)
            )
        report.pairs.append(
            _backtest_pair(
                one,
                weekly,
                holdout_weeks=holdout_weeks,
                moving_average_k=moving_average_k,
                model_predictor=model_predictor,
                precomputed=precomputed,
            )
        )
    for report in reports.values():
        _finalize(report, worst_case_limit)
    return reports

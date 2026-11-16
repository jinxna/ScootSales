from __future__ import annotations

import statistics
from datetime import date, datetime
from typing import Sequence

from .calendar import completed_week_starts
from .forecast_models import POINT_SEMANTICS, ForecastPoint, forecast_next
from .models import (
    PatternMetrics,
    RetailerProductSeries,
    require_supported_series,
)


def _mean(values: Sequence[float]) -> float:
    return statistics.fmean(values) if values else 0.0


def _slope(values: Sequence[float]) -> float:
    if len(values) < 2:
        return 0.0
    x_mean = (len(values) - 1) / 2
    y_mean = _mean(values)
    denominator = sum((index - x_mean) ** 2 for index in range(len(values)))
    if denominator == 0:
        return 0.0
    numerator = sum(
        (index - x_mean) * (value - y_mean)
        for index, value in enumerate(values)
    )
    return numerator / denominator


def classify_trend(quantities: Sequence[float]) -> str:
    values = tuple(
        max(0.0, value)
        for value in require_supported_series(quantities, "quantity")
    )
    if not values or sum(values) == 0:
        return "no_demand"

    historical = values[:-2] if len(values) > 2 else values
    latest_two = values[-2:] if len(values) >= 2 else values
    baseline = _mean(historical)
    nonzero_history = sum(value > 0 for value in historical)
    if (
        len(values) >= 6
        and baseline >= 1
        and nonzero_history >= 3
        and all(value == 0 for value in latest_two)
    ):
        return "stopped"

    split = max(1, len(values) // 2)
    earlier = _mean(values[:split])
    recent = _mean(values[-3:])
    slope = _slope(values)
    overall_mean = _mean(values)
    variation = (
        statistics.pstdev(values) / overall_mean
        if len(values) > 1 and overall_mean > 0
        else 0.0
    )

    if earlier > 0 and recent <= earlier * 0.7 and slope < -0.25:
        return "declining"
    if earlier > 0 and recent >= earlier * 1.25 and slope > 0.25:
        return "growing"
    if variation >= 0.65:
        return "volatile"
    return "stable"


def forecast_point(quantities: Sequence[float]) -> ForecastPoint:
    return forecast_next(quantities)


def simple_forecast(quantities: Sequence[float]) -> float:
    return forecast_point(quantities).point


def anomaly_score(quantities: Sequence[float]) -> float:
    values = tuple(
        max(0.0, value)
        for value in require_supported_series(quantities, "quantity")
    )
    if len(values) < 3:
        return 0.0
    prior = values[:-1]
    latest = values[-1]
    expected = _mean(prior)
    if expected == 0:
        return 0.0 if latest == 0 else min(1.0, latest / 5)
    if len(values) >= 6 and values[-1] == 0 and values[-2] == 0:
        if sum(value > 0 for value in values[:-2]) >= 3:
            return 1.0

    spread = statistics.pstdev(prior) if len(prior) > 1 else 0.0
    deviation = abs(latest - expected) / expected
    robust_spread = max(spread, expected * 0.15, 1.0)
    z_score = abs(latest - expected) / robust_spread
    score = 0.55 * min(1.0, deviation) + 0.45 * min(1.0, z_score / 3)
    return round(min(1.0, score), 4)


def _confidence(
    quantities: Sequence[float],
    *,
    coverage_weeks: int,
) -> tuple[float, str]:
    active_weeks = sum(value > 0 for value in quantities)
    total = sum(quantities)
    mean = _mean(quantities)
    variation = (
        statistics.pstdev(quantities) / mean
        if len(quantities) > 1 and mean > 0
        else 0.0
    )
    completeness = min(1.0, coverage_weeks / max(1, len(quantities)))
    breadth = min(1.0, active_weeks / 5)
    volume = min(1.0, total / 30)
    stability = 1.0 - min(1.0, variation / 2)
    score = (
        completeness * 0.20
        + breadth * 0.40
        + volume * 0.25
        + stability * 0.15
    )
    score = round(max(0.0, min(1.0, score)), 4)
    label = "high" if score >= 0.75 else "medium" if score >= 0.55 else "low"
    return score, label


def analyse_series(
    series: RetailerProductSeries,
    *,
    as_of: date | datetime,
    weeks: int = 8,
) -> PatternMetrics:
    starts = completed_week_starts(as_of, weeks=weeks)
    allowed = set(starts)
    by_week = {
        observation.week_start: observation
        for observation in series.observations
        if observation.week_start in allowed
    }
    quantities = tuple(
        float(by_week[start].quantity) if start in by_week else 0.0
        for start in starts
    )
    revenues = tuple(
        float(by_week[start].revenue_rm) if start in by_week else 0.0
        for start in starts
    )
    order_counts = tuple(
        int(by_week[start].order_count) if start in by_week else 0
        for start in starts
    )
    trend = classify_trend(quantities)
    forecast = forecast_point(quantities)
    historical = quantities[:-2] if len(quantities) > 2 else quantities
    baseline = _mean(historical)
    recent = _mean(quantities[-3:])
    score, confidence = _confidence(
        quantities,
        coverage_weeks=series.coverage_weeks,
    )
    evidence = {
        "weekStarts": tuple(start.isoformat() for start in starts),
        "weeklyQuantities": tuple(round(value, 2) for value in quantities),
        "weeklyOrderCounts": order_counts,
        "baselineAverage": round(baseline, 2),
        "recentAverage": round(recent, 2),
    }
    return PatternMetrics(
        week_starts=starts,
        quantities=quantities,
        revenues_rm=revenues,
        order_counts=order_counts,
        trend=trend,
        baseline_average=round(baseline, 2),
        recent_average=round(recent, 2),
        latest_quantity=round(quantities[-1], 2),
        slope=round(_slope(quantities), 4),
        forecast_next_week=forecast.point,
        anomaly_score=anomaly_score(quantities),
        confidence_score=score,
        confidence=confidence,
        active_weeks=sum(value > 0 for value in quantities),
        total_quantity=round(sum(quantities), 2),
        forecast_model=forecast.model,
        forecast_version=forecast.version,
        forecast_lower=forecast.lower,
        forecast_upper=forecast.upper,
        forecast_probability_non_zero=forecast.probability_non_zero,
        forecast_status=forecast.status,
        forecast_classification=forecast.classification,
        forecast_semantics=POINT_SEMANTICS,
        evidence={
            **evidence,
            "forecastModel": forecast.model,
            "forecastVersion": forecast.version,
        },
    )

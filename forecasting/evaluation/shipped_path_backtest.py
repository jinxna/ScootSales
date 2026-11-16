from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from forecasting.ai_core.calendar import DEFAULT_HISTORY_WEEKS
from forecasting.ai_core.forecast_contract import (
    OperationalForecast,
    build_operational_forecast,
    observed_reference_units,
)
from forecasting.ai_core.forecast_models import (
    FORECAST_MODELS_VERSION,
    adida_forecast,
    characterise_demand,
    croston_forecast,
    croston_smoothed_forecast,
    forecast_next,
    moving_average_forecast,
    sba_smoothed_forecast,
    ses_drift_forecast,
    ses_forecast,
    theta_forecast,
    tsb_forecast,
)
from forecasting.ai_service.operational_forecast import product_point_and_range

from .closed_loop_runner import (
    DEFAULT_ROLLING_ORIGINS,
    DEFAULT_SEED,
    build_weekly_series,
    load_snapshot,
    usable_orders,
)
from .history_window_grid import window_for
from .model_selection_backtest import DEFAULT_MIN_TRAIN_PERIODS
from .paired_bootstrap import (
    DEFAULT_BOOTSTRAP_DRAWS,
    _percentile,
    paired_ratio_differences,
    ratio_metric_intervals,
)
from .synthetic_exclusion import exclude_synthetic_history

PROTOCOL_VERSION = "shipped-path-backtest/1.0.0"
PRIMARY_METRIC = "rmsse"
LIVE_RULE = "liveRule8Weeks"
CANDIDATE_RULE = "sbcRule8Weeks"
BOTTOM_UP_SUFFIX = "BottomUp"
REFERENCE_PREDICTORS = (
    "naive",
    "movingAverage4",
    "zero",
    LIVE_RULE,
    LIVE_RULE + BOTTOM_UP_SUFFIX,
)
SUMMED_SERIES_RANGE_WEEKS = (12, 26)
PAST_DEMAND_RANGE_WEEKS = (8, 12, 26)
MIN_RANGE_ERRORS = 4
POOLED_RATIO_RANGE_WEEKS = (12, 26)
MIN_POOLED_RATIOS = 20
GRAINS = ("outlet_barcode", "barcode")
TARGET_COVERAGE = 0.8

Predictor = Callable[[Sequence[float]], float]


def live_units(train: Sequence[float]) -> float:
    record = build_operational_forecast(
        window_for(train, DEFAULT_HISTORY_WEEKS),
        product_id="scored",
        with_interval=False,
    )
    return record.units_for_value


SBC_MODEL_BY_CLASS: dict[str, Callable[[Sequence[float]], float]] = {
    "lumpy": sba_smoothed_forecast,
    "intermittent": sba_smoothed_forecast,
    "erratic": sba_smoothed_forecast,
    "smooth": ses_forecast,
}


def candidate_units(train: Sequence[float]) -> float:
    window = window_for(train, DEFAULT_HISTORY_WEEKS)
    characterisation = characterise_demand(window)
    if characterisation.is_cold_start:
        return observed_reference_units(window)
    return SBC_MODEL_BY_CLASS[characterisation.classification](window)


def _mean(train: Sequence[float]) -> float:
    return sum(train) / len(train) if train else 0.0


def _last_weeks(predictor: Predictor, weeks: int) -> Predictor:
    return lambda train: predictor(window_for(train, weeks))


def _ses(alpha: float) -> Predictor:
    return lambda train: ses_forecast(train, alpha=alpha)


PREDICTORS: tuple[tuple[str, str, Predictor], ...] = (
    (LIVE_RULE, "last 8 weeks, window mean at cold start (ships)", live_units),
    (
        CANDIDATE_RULE,
        "last 8 weeks, SBA for non-smooth classes, SES for smooth, window mean at cold start",
        candidate_units,
    ),
    (
        "ruleAllHistory",
        "all history, last value at cold start (earlier headline)",
        lambda train: forecast_next(train, with_interval=False).point,
    ),
    ("naive", "last value", lambda train: float(train[-1]) if train else 0.0),
    ("zero", "always zero", lambda train: 0.0),
    ("historyMean", "mean of all history", _mean),
    ("mean8Weeks", "mean of last 8 weeks", _last_weeks(_mean, 8)),
    ("movingAverage4", "mean of last 4 weeks", moving_average_forecast),
    ("ses0.1", "SES alpha 0.1, all history", _ses(0.1)),
    ("ses0.2", "SES alpha 0.2, all history", _ses(0.2)),
    ("ses0.3", "SES alpha 0.3, all history", _ses(0.3)),
    ("ses0.2Last8Weeks", "SES alpha 0.2, last 8 weeks", _last_weeks(_ses(0.2), 8)),
    ("crostonLastGap", "Croston with last gap (current code)", croston_forecast),
    ("crostonSmoothed", "Croston with smoothed interval", croston_smoothed_forecast),
    ("sba", "SBA with smoothed interval, all history", sba_smoothed_forecast),
    ("sbaLast8Weeks", "SBA, last 8 weeks", _last_weeks(sba_smoothed_forecast, 8)),
    ("tsb", "TSB, all history", tsb_forecast),
    ("tsbLast8Weeks", "TSB, last 8 weeks", _last_weeks(tsb_forecast, 8)),
    ("adida4", "ADIDA 4-week buckets with SES, all history", adida_forecast),
    ("adida4Last8Weeks", "ADIDA 4-week buckets, last 8 weeks", _last_weeks(adida_forecast, 8)),
    ("thetaSesDrift", "SES with drift (Theta), all history", ses_drift_forecast),
    ("linearTrend", "line fit plus half slope (current 'theta')", theta_forecast),
)

BOTTOM_UP_PREDICTORS = (LIVE_RULE, CANDIDATE_RULE, "mean8Weeks", "historyMean", "ses0.2", "sba", "adida4")


@dataclass(frozen=True)
class ScoredSeries:
    actuals: tuple[float, ...]
    absolute_scales: tuple[float, ...]
    squared_scales: tuple[float, ...]
    predictions: dict[str, tuple[float, ...]]
    zero_scale_points: int


@dataclass(frozen=True)
class RangeCheck:
    lower: float
    upper: float
    actual: float
    live_has_range: bool = True

    @property
    def covered(self) -> bool:
        return self.lower <= self.actual <= self.upper


def past_demand_range(
    train: Sequence[float], weeks: int, actual: float, live_has_range: bool
) -> RangeCheck:
    recent = window_for(train, weeks)
    return RangeCheck(
        _percentile(recent, 0.1), _percentile(recent, 0.9), actual, live_has_range
    )


def _training_scales(train: Sequence[float]) -> tuple[float, float]:
    steps = [train[index] - train[index - 1] for index in range(1, len(train))]
    if not steps:
        return 0.0, 0.0
    return (
        sum(abs(step) for step in steps) / len(steps),
        sum(step * step for step in steps) / len(steps),
    )


def _scored_origins(length: int, *, min_train: int, max_origins: int) -> list[int]:
    return list(range(min_train, length))[-max_origins:]


def score_series(
    values: Sequence[float],
    predict_at: Callable[[int], Mapping[str, float]],
    *,
    min_train: int,
    max_origins: int,
) -> ScoredSeries | None:
    origins = _scored_origins(len(values), min_train=min_train, max_origins=max_origins)
    if not origins:
        return None
    actuals: list[float] = []
    absolute_scales: list[float] = []
    squared_scales: list[float] = []
    predictions: dict[str, list[float]] = {}
    zero_scale_points = 0
    for origin in origins:
        absolute_scale, squared_scale = _training_scales(values[:origin])
        if absolute_scale <= 0:
            zero_scale_points += 1
            continue
        actuals.append(values[origin])
        absolute_scales.append(absolute_scale)
        squared_scales.append(squared_scale)
        for name, prediction in predict_at(origin).items():
            predictions.setdefault(name, []).append(max(0.0, float(prediction)))
    if not actuals:
        return None
    return ScoredSeries(
        actuals=tuple(actuals),
        absolute_scales=tuple(absolute_scales),
        squared_scales=tuple(squared_scales),
        predictions={name: tuple(points) for name, points in predictions.items()},
        zero_scale_points=zero_scale_points,
    )


def _direct_predictions(
    values: Sequence[float], predictors: Sequence[tuple[str, str, Predictor]]
) -> Callable[[int], dict[str, float]]:
    return lambda origin: {
        name: predictor(values[:origin]) for name, _, predictor in predictors
    }


def _live_record(train: Sequence[float]) -> OperationalForecast:
    return build_operational_forecast(
        window_for(train, DEFAULT_HISTORY_WEEKS), product_id="scored"
    )


def _clean(values: Sequence[float]) -> list[float]:
    return [max(0.0, float(value)) for value in values]


def evaluate(
    snapshot: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    predictors: Sequence[tuple[str, str, Predictor]] = PREDICTORS,
    bottom_up: Sequence[str] = BOTTOM_UP_PREDICTORS,
    seed: int = DEFAULT_SEED,
    draws: int = DEFAULT_BOOTSTRAP_DRAWS,
    min_train: int = DEFAULT_MIN_TRAIN_PERIODS,
    max_origins: int = DEFAULT_ROLLING_ORIGINS,
) -> dict[str, Any]:
    clean, exclusion = exclude_synthetic_history(snapshot)
    orders = usable_orders(clean)
    outlet_series = [
        row
        for row in build_weekly_series(orders, grain="outlet_barcode")
        if not row.get("isDemo")
    ]
    product_series = [
        row
        for row in build_weekly_series(orders, grain="barcode")
        if not row.get("isDemo")
    ]
    by_name = {name: predictor for name, _, predictor in predictors}
    summed = [name for name in bottom_up if name in by_name]

    outlet_scored: list[ScoredSeries] = []
    outlet_ranges: list[RangeCheck] = []
    outlet_alternatives: dict[str, list[RangeCheck]] = {}
    outlet_live_points = 0
    outlet_live_modelled = 0
    component_units: dict[tuple[str, int], dict[str, float]] = {}
    component_records: dict[tuple[str, int], list[OperationalForecast]] = {}
    for row in outlet_series:
        values = _clean(row["values"])
        product = str(row["key"]).split("|", 1)[1]
        scored_origins = set(
            _scored_origins(len(values), min_train=min_train, max_origins=max_origins)
        )
        for origin in range(1, len(values)):
            train = values[:origin]
            weeks_before_cutoff = len(values) - origin
            totals = component_units.setdefault((product, weeks_before_cutoff), {})
            for name in summed:
                totals[name] = totals.get(name, 0.0) + max(0.0, by_name[name](train))
            record = _live_record(train)
            modelled, lower, upper = record.is_usable, record.lower, record.upper
            component_records.setdefault((product, weeks_before_cutoff), []).append(
                record
            )
            if origin in scored_origins:
                outlet_live_points += 1
                outlet_live_modelled += int(modelled)
            if origin in scored_origins:
                for weeks in PAST_DEMAND_RANGE_WEEKS:
                    outlet_alternatives.setdefault(f"pastDemandLast{weeks}Weeks", []).append(
                        past_demand_range(train, weeks, values[origin], lower is not None)
                    )
            if lower is None or upper is None:
                continue
            if origin in scored_origins:
                outlet_ranges.append(RangeCheck(lower, upper, values[origin]))
        scored = score_series(
            values,
            _direct_predictions(values, predictors),
            min_train=min_train,
            max_origins=max_origins,
        )
        if scored is not None:
            outlet_scored.append(scored)

    product_scored: list[ScoredSeries] = []
    product_ranges: list[RangeCheck] = []
    summed_ranges: dict[str, list[RangeCheck]] = {}
    pooled_ratios: dict[int, list[float]] = {}
    for row in product_series:
        values = _clean(row["values"])
        for origin in range(1, len(values)):
            weeks_before_cutoff = len(values) - origin
            point = component_units.get((str(row["key"]), weeks_before_cutoff), {}).get(
                LIVE_RULE, 0.0
            )
            if point > 0:
                pooled_ratios.setdefault(weeks_before_cutoff, []).append(
                    values[origin] / point
                )
    for row in product_series:
        values = _clean(row["values"])
        product = str(row["key"])
        direct = _direct_predictions(values, predictors)

        def predict_at(origin: int) -> dict[str, float]:
            totals = component_units.get((product, len(values) - origin), {})
            return {
                **direct(origin),
                **{name + BOTTOM_UP_SUFFIX: totals.get(name, 0.0) for name in summed},
            }

        scored = score_series(
            values, predict_at, min_train=min_train, max_origins=max_origins
        )
        if scored is not None:
            product_scored.append(scored)
        for origin in _scored_origins(
            len(values), min_train=min_train, max_origins=max_origins
        ):
            slot = (product, len(values) - origin)
            _, lower, upper = product_point_and_range(component_records.get(slot, ()))
            live_has_range = lower is not None and upper is not None
            live_point = component_units.get(slot, {}).get(LIVE_RULE, 0.0)
            if live_has_range:
                product_ranges.append(RangeCheck(lower, upper, values[origin]))
            for weeks in PAST_DEMAND_RANGE_WEEKS:
                summed_ranges.setdefault(f"pastDemandLast{weeks}Weeks", []).append(
                    past_demand_range(values[:origin], weeks, values[origin], live_has_range)
                )
            for weeks in POOLED_RATIO_RANGE_WEEKS:
                ratios = [
                    ratio
                    for earlier in range(slot[1] + 1, slot[1] + weeks + 1)
                    for ratio in pooled_ratios.get(earlier, ())
                ]
                if live_point <= 0 or len(ratios) < MIN_POOLED_RATIOS:
                    continue
                summed_ranges.setdefault(f"pooledRatioLast{weeks}Weeks", []).append(
                    RangeCheck(
                        live_point * _percentile(ratios, 0.1),
                        live_point * _percentile(ratios, 0.9),
                        values[origin],
                        live_has_range,
                    )
                )
            for name in (LIVE_RULE, CANDIDATE_RULE):
                if name not in summed:
                    continue
                points = [
                    component_units.get((product, len(values) - past), {}).get(name, 0.0)
                    for past in range(origin + 1)
                ]
                for weeks in SUMMED_SERIES_RANGE_WEEKS:
                    errors = [
                        values[past] - points[past]
                        for past in range(max(1, origin - weeks), origin)
                    ]
                    if len(errors) < MIN_RANGE_ERRORS:
                        continue
                    summed_ranges.setdefault(f"{name}Last{weeks}Errors", []).append(
                        RangeCheck(
                            max(0.0, points[origin] + _percentile(errors, 0.1)),
                            max(0.0, points[origin] + _percentile(errors, 0.9)),
                            values[origin],
                            live_has_range,
                        )
                    )

    descriptions = {name: description for name, description, _ in predictors}
    for name in summed:
        descriptions[name + BOTTOM_UP_SUFFIX] = "sum of outlet forecasts: " + descriptions[name]
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "modelsVersion": FORECAST_MODELS_VERSION,
        "primaryMetric": PRIMARY_METRIC,
        "seed": seed,
        "bootstrapDraws": draws,
        "minTrainPeriods": min_train,
        "maxOriginsPerSeries": max_origins,
        "orderCount": len(orders),
        "syntheticExclusion": exclusion,
        "descriptions": descriptions,
        "grains": {
            "outlet_barcode": {
                **summarise(outlet_scored, seed=seed, draws=draws),
                "liveRuleModelledShare": (
                    round(outlet_live_modelled / outlet_live_points, 4)
                    if outlet_live_points
                    else None
                ),
                "liveRange": range_summary(outlet_ranges),
                "alternativeRanges": alternative_range_summaries(outlet_alternatives),
            },
            "barcode": {
                **summarise(product_scored, seed=seed, draws=draws),
                "liveRange": range_summary(product_ranges),
                "alternativeRanges": alternative_range_summaries(summed_ranges),
            },
        },
    }


def range_summary(checks: Sequence[RangeCheck]) -> dict[str, Any]:
    if not checks:
        return {"points": 0, "coverage": None, "meanWidth": None, "target": TARGET_COVERAGE}
    return {
        "points": len(checks),
        "coverage": round(sum(check.covered for check in checks) / len(checks), 4),
        "meanWidth": round(
            sum(check.upper - check.lower for check in checks) / len(checks), 4
        ),
        "target": TARGET_COVERAGE,
    }


def alternative_range_summaries(
    alternatives: Mapping[str, Sequence[RangeCheck]],
) -> dict[str, Any]:
    return {
        name: {
            "allScoredPoints": range_summary(checks),
            "whereLiveHasRange": range_summary(
                [check for check in checks if check.live_has_range]
            ),
        }
        for name, checks in sorted(alternatives.items())
    }


def summarise(
    scored: Sequence[ScoredSeries], *, seed: int, draws: int
) -> dict[str, Any]:
    if not scored:
        return {"seriesScored": 0, "scoredPoints": 0, "predictors": {}}
    names = list(scored[0].predictions)
    squared_pairs: dict[str, list[tuple[float, float]]] = {}
    predictors: dict[str, Any] = {}
    total_actual = sum(sum(series.actuals) for series in scored)
    total_absolute_scale = sum(sum(series.absolute_scales) for series in scored)
    for name in names:
        squared_pairs[name] = [
            (
                sum(
                    (actual - prediction) ** 2
                    for actual, prediction in zip(series.actuals, series.predictions[name])
                ),
                sum(series.squared_scales),
            )
            for series in scored
        ]
        absolute_error = sum(
            abs(actual - prediction)
            for series in scored
            for actual, prediction in zip(series.actuals, series.predictions[name])
        )
        signed_error = sum(
            prediction - actual
            for series in scored
            for actual, prediction in zip(series.actuals, series.predictions[name])
        )
        predictors[name] = {
            "mase": round(absolute_error / total_absolute_scale, 6),
            "wape": round(absolute_error / total_actual, 6) if total_actual > 0 else None,
            "bias": round(signed_error / total_actual, 6) if total_actual > 0 else None,
        }
    intervals = ratio_metric_intervals(
        squared_pairs, seed=seed, draws=draws, transform=math.sqrt
    )
    for name in names:
        predictors[name]["rmsse"] = intervals[name].to_dict()
        predictors[name]["rmsseDifference"] = {}
    for reference in REFERENCE_PREDICTORS:
        differences = paired_ratio_differences(
            squared_pairs, reference=reference, seed=seed, draws=draws, transform=math.sqrt
        )
        for name, difference in differences.items():
            predictors[name]["rmsseDifference"][reference] = difference
    return {
        "seriesScored": len(scored),
        "scoredPoints": sum(len(series.actuals) for series in scored),
        "zeroScalePointsDropped": sum(series.zero_scale_points for series in scored),
        "predictors": predictors,
    }


def _interval(row: Mapping[str, Any] | None) -> str:
    if not row or row.get("value") is None:
        return "n/a"
    return f"{row['value']:.4f} [{row['lower']:.4f}, {row['upper']:.4f}]"


def _difference(row: Mapping[str, Any] | None) -> str:
    if not row or row.get("value") is None:
        return "reference"
    verdict = "excludes 0" if row["excludesZero"] else "includes 0"
    return f"{row['value']:+.4f} [{row['lower']:+.4f}, {row['upper']:+.4f}] {verdict}"


def _percent(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:+.1f}%"


def render_markdown(result: Mapping[str, Any], provenance: Mapping[str, Any]) -> str:
    lines = [
        "# Forecast backtest of the shipped path",
        "",
        f"- Protocol `{result['protocolVersion']}`, models `{result['modelsVersion']}`",
        f"- Snapshot `{provenance.get('snapshot')}` (sha256 `{provenance.get('sha256')}`)",
        f"- Orders used: {result['orderCount']}",
        f"- One-step origins: the last {result['maxOriginsPerSeries']} per series with at "
        f"least {result['minTrainPeriods']} training weeks. Every predictor is scored on the same points.",
        "- RMSSE = sqrt(total squared error / total squared one-step naive error of each "
        "origin's training weeks). MASE uses the absolute version of the same scale.",
        "- WAPE = total absolute error / total actual units. Bias = total (forecast - actual) "
        "/ total actual units.",
        f"- Intervals: 95% percentile, {result['bootstrapDraws']} draws, seed {result['seed']}, "
        "whole series resampled. A negative difference means a lower RMSSE than the reference.",
        "- No parameter was tuned. Alpha values were fixed before the run.",
        "- Croston and SBA here smooth the interval. The interval starts from the first "
        "observed gap, because every series starts at its first order.",
        "- Alternative ranges: `pastDemand...` is the 10th to 90th percentile of the last N "
        "weekly totals of the same series. `...Errors` adds the 10th and 90th percentile of the "
        "last N one-step errors of the summed product series to the point. `pooledRatio...` "
        "multiplies the point by the 10th and 90th percentile of actual / forecast over all "
        "products in the N weeks before the scored week.",
        "- A series starts at the first order of its outlet and product, so a first order "
        "is never a scored target at the outlet grain. It is a scored target at the product grain.",
        "",
    ]
    for grain, report in result["grains"].items():
        label = "outlet x product" if grain == "outlet_barcode" else "product"
        lines += [
            f"## Grain: {label}",
            "",
            f"Series scored: {report['seriesScored']}. Scored points: {report['scoredPoints']}. "
            f"Points dropped for a zero scale: {report.get('zeroScalePointsDropped', 0)}.",
            "",
        ]
        if report.get("liveRuleModelledShare") is not None:
            lines += [
                f"Share of scored points where the live rule ran a model (not the window mean): "
                f"{report['liveRuleModelledShare']}.",
                "",
            ]
        live_range = report["liveRange"]
        lines += [
            f"Live 80% range: coverage {live_range['coverage']} on {live_range['points']} "
            f"points that had a range, mean width {live_range['meanWidth']}.",
            "",
        ]
        lines += [
            "| Alternative 80% range | Coverage, all scored points | Points | Mean width | Coverage, points where live has a range | Points | Mean width |",
            "|---|---|---|---|---|---|---|",
        ]
        for name, alternative in report.get("alternativeRanges", {}).items():
            everywhere = alternative["allScoredPoints"]
            subset = alternative["whereLiveHasRange"]
            lines.append(
                f"| {name} | {everywhere['coverage']} | {everywhere['points']} | "
                f"{everywhere['meanWidth']} | {subset['coverage']} | {subset['points']} | "
                f"{subset['meanWidth']} |"
            )
        live_name = LIVE_RULE if grain == "outlet_barcode" else LIVE_RULE + BOTTOM_UP_SUFFIX
        lines += [
            "",
            f"| Predictor | What it is | RMSSE [95% CI] | MASE | WAPE | Bias | RMSSE vs naive | RMSSE vs MA4 | RMSSE vs zero | RMSSE vs {live_name} |",
            "|---|---|---|---|---|---|---|---|---|---|",
        ]
        ordered = sorted(
            report["predictors"].items(), key=lambda item: item[1]["rmsse"]["value"]
        )
        for name, row in ordered:
            lines.append(
                f"| {name} | {result['descriptions'].get(name, '')} | {_interval(row['rmsse'])} | "
                f"{row['mase']:.4f} | {_percent(row['wape'])} | {_percent(row['bias'])} | "
                f"{_difference(row['rmsseDifference'].get('naive'))} | "
                f"{_difference(row['rmsseDifference'].get('movingAverage4'))} | "
                f"{_difference(row['rmsseDifference'].get('zero'))} | "
                f"{_difference(row['rmsseDifference'].get(live_name))} |"
            )
        lines.append("")
    return "\n".join(lines) + "\n"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m forecasting.evaluation.shipped_path_backtest",
        description="Score the shipped forecast path and reference methods on a local snapshot (read-only).",
    )
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--draws", type=int, default=DEFAULT_BOOTSTRAP_DRAWS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    snapshot_path = Path(args.snapshot)
    if not snapshot_path.is_file():
        print("Snapshot not found: " + str(snapshot_path), file=sys.stderr)
        return 2
    result = evaluate(load_snapshot(snapshot_path), seed=args.seed, draws=args.draws)
    provenance = {
        "snapshot": snapshot_path.name,
        "sha256": hashlib.sha256(snapshot_path.read_bytes()).hexdigest(),
    }
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "shipped_path_backtest.json").write_text(
        json.dumps({**result, "snapshotProvenance": provenance}, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (output_dir / "shipped_path_backtest.md").write_text(
        render_markdown(result, provenance), encoding="utf-8"
    )
    print("Wrote " + str(output_dir / "shipped_path_backtest.md"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import argparse
import json
import uuid
import warnings
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from statsmodels.tsa.statespace.sarimax import SARIMAX

from festivals import EXOG_COLUMNS, exogenous_row, festival_tags

ROOT = Path(__file__).resolve().parents[1]
PROCESSED = ROOT / "data" / "processed"
OUTPUTS = ROOT / "outputs"
EVALUATION_PROCESSED = ROOT / "data" / "evaluation" / "processed"
EVALUATION_OUTPUTS = ROOT / "data" / "evaluation" / "outputs"

HOLDOUT_MONTHS = 3
FORECAST_MONTHS = 6
MIN_MONTHS_FOR_SARIMAX = 12
CANDIDATE_ORDERS = [(1, 1, 1), (0, 1, 1), (1, 0, 1), (2, 1, 1), (1, 0, 0)]

warnings.filterwarnings("ignore")


def month_range(last: pd.Period, count: int) -> list[pd.Period]:
    return [last + offset for offset in range(1, count + 1)]


def exog_frame(periods: list[pd.Period]) -> pd.DataFrame:
    rows = [exogenous_row(p.year, p.month) for p in periods]
    return pd.DataFrame(rows, index=[str(p) for p in periods], columns=EXOG_COLUMNS)


def festive_baseline(history: pd.Series, target_periods: list[pd.Period]) -> np.ndarray:
    periods = [pd.Period(p) for p in history.index]
    signals = np.array([
        sum(exogenous_row(p.year, p.month).values()) for p in periods
    ])
    values = history.to_numpy(dtype=float)

    plain = values[signals == 0]
    festive = values[signals > 0]
    plain_avg = plain.mean() if plain.size else values.mean()
    festive_factor = (festive.mean() / plain_avg) if festive.size and plain_avg > 0 else 1.0

    recent = values[-6:]
    weights = np.arange(1, recent.size + 1, dtype=float)
    baseline = float(np.average(recent, weights=weights))

    forecasts = []
    for period in target_periods:
        signal = sum(exogenous_row(period.year, period.month).values())
        factor = 1.0 + (festive_factor - 1.0) * min(signal, 1.0)
        forecasts.append(max(0.0, baseline * factor))
    return np.array(forecasts)


def fit_best_sarimax(train: pd.Series, train_exog: pd.DataFrame, orders=CANDIDATE_ORDERS):
    best_fit, best_aic, best_order = None, np.inf, None
    for order in orders:
        try:
            model = SARIMAX(
                train.to_numpy(dtype=float),
                exog=train_exog.to_numpy(dtype=float),
                order=order,
                enforce_stationarity=False,
                enforce_invertibility=False,
            )
            fit = model.fit(disp=False)
        except Exception:
            continue
        if np.isfinite(fit.aic) and fit.aic < best_aic:
            best_fit, best_aic, best_order = fit, fit.aic, order
    return best_fit, best_order, best_aic


def smape(actual: np.ndarray, predicted: np.ndarray) -> float:
    denominator = (np.abs(actual) + np.abs(predicted)) / 2.0
    mask = denominator > 0
    if not mask.any():
        return 0.0
    return float(np.mean(np.abs(actual[mask] - predicted[mask]) / denominator[mask]) * 100)


def confidence_label(model_used: str, months: int, smape_value: float) -> str:
    if model_used != "sarimax" or months < MIN_MONTHS_FOR_SARIMAX:
        return "low"
    if smape_value <= 15 and months >= 18:
        return "high"
    if smape_value <= 30:
        return "medium"
    return "low"


def recommended_action(predicted: float, recent_avg: float) -> str:
    if recent_avg <= 0:
        return "Collect more data"
    if predicted >= recent_avg * 1.2:
        return "Prepare more stock"
    if predicted <= recent_avg * 0.8:
        return "Monitor demand"
    return "Maintain stock"


def reason_text(period: pd.Period, predicted: float, recent_avg: float, model_used: str) -> str:
    tags = festival_tags(period.year, period.month)
    parts: list[str] = []
    if tags:
        parts.append(f"{' and '.join(tags)} period")
    if recent_avg > 0:
        change = (predicted - recent_avg) / recent_avg * 100
        if change >= 10:
            parts.append(f"demand expected {change:.0f}% above recent average")
        elif change <= -10:
            parts.append(f"demand expected {abs(change):.0f}% below recent average")
        else:
            parts.append("demand close to recent average")
    parts.append("SARIMAX model" if model_used == "sarimax" else "festive-aware baseline")
    return "; ".join(parts).capitalize()


def _resolve_path(path: Path) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_absolute():
        return candidate

    cwd_candidate = (Path.cwd() / candidate).resolve()
    root_candidate = (ROOT / candidate).resolve()
    if cwd_candidate.exists():
        return cwd_candidate
    if root_candidate.exists():
        return root_candidate
    current_dir = Path.cwd().resolve()
    if current_dir == (ROOT / "scripts").resolve():
        return root_candidate
    if current_dir == ROOT.resolve():
        return root_candidate
    if current_dir == ROOT.parent.resolve():
        if candidate.parts and candidate.parts[0].lower() == ROOT.name.lower():
            return cwd_candidate
        return root_candidate
    if candidate.parts and candidate.parts[0].lower() in {
        "data",
        "outputs",
        "imports",
        "logs",
    }:
        return root_candidate
    return cwd_candidate


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _pipeline_paths(
    processed_dir: Path,
    outputs_dir: Path | None,
) -> tuple[Path, Path]:
    resolved_processed = _resolve_path(processed_dir)
    resolved_outputs = (
        _resolve_path(outputs_dir)
        if outputs_dir is not None
        else (
            OUTPUTS
            if resolved_processed.resolve() == PROCESSED.resolve()
            else EVALUATION_OUTPUTS
        )
    )
    if (
        resolved_processed.resolve() != PROCESSED.resolve()
        and _is_within(resolved_outputs, OUTPUTS)
    ):
        raise ValueError(
            "Non-production processed data requires a separate --output-dir; "
            "use data/evaluation/outputs for evaluation forecasts."
        )
    return resolved_processed, resolved_outputs


def forecast_product(series: pd.Series) -> tuple[str, np.ndarray, np.ndarray, np.ndarray, dict]:
    months = len(series)
    periods = [pd.Period(p) for p in series.index]
    future_periods = month_range(periods[-1], FORECAST_MONTHS)
    evaluation: dict[str, object] = {"months": months}

    sarimax_holdout_mae = np.inf
    baseline_holdout_mae = np.inf
    sarimax_smape = np.inf
    chosen_order = None

    if months >= MIN_MONTHS_FOR_SARIMAX + HOLDOUT_MONTHS:
        train = series.iloc[:-HOLDOUT_MONTHS]
        test = series.iloc[-HOLDOUT_MONTHS:]
        test_periods = [pd.Period(p) for p in test.index]

        fit, order, _aic = fit_best_sarimax(train, exog_frame([pd.Period(p) for p in train.index]))
        if fit is not None:
            prediction = fit.get_forecast(
                steps=HOLDOUT_MONTHS,
                exog=exog_frame(test_periods).to_numpy(dtype=float),
            ).predicted_mean
            prediction = np.clip(prediction, 0, None)
            sarimax_holdout_mae = float(np.mean(np.abs(test.to_numpy(dtype=float) - prediction)))
            sarimax_smape = smape(test.to_numpy(dtype=float), prediction)
            chosen_order = order

        baseline_prediction = festive_baseline(train, test_periods)
        baseline_holdout_mae = float(np.mean(np.abs(test.to_numpy(dtype=float) - baseline_prediction)))

    evaluation.update({
        "sarimaxHoldoutMae": None if np.isinf(sarimax_holdout_mae) else round(sarimax_holdout_mae, 2),
        "baselineHoldoutMae": None if np.isinf(baseline_holdout_mae) else round(baseline_holdout_mae, 2),
        "sarimaxSmape": None if np.isinf(sarimax_smape) else round(sarimax_smape, 2),
        "order": str(chosen_order) if chosen_order else "",
    })

    use_sarimax = (
        months >= MIN_MONTHS_FOR_SARIMAX + HOLDOUT_MONTHS
        and np.isfinite(sarimax_holdout_mae)
        and sarimax_holdout_mae <= baseline_holdout_mae
    )

    if use_sarimax:
        fit, order, _aic = fit_best_sarimax(series, exog_frame(periods), orders=[chosen_order])
        if fit is not None:
            result = fit.get_forecast(
                steps=FORECAST_MONTHS,
                exog=exog_frame(future_periods).to_numpy(dtype=float),
            )
            point = np.clip(result.predicted_mean, 0, None)
            interval = result.conf_int(alpha=0.2)
            lower = np.clip(interval[:, 0], 0, None)
            upper = np.clip(interval[:, 1], 0, None)
            evaluation["finalOrder"] = str(order)
            return "sarimax", point, lower, upper, evaluation

    point = festive_baseline(series, future_periods)
    spread = 0.25 * point
    return "festive_baseline", point, np.clip(point - spread, 0, None), point + spread, evaluation


def main(
    processed_dir: Path | None = None,
    output_dir: Path | None = None,
    *,
    outputs_dir: Path | None = None,
) -> None:
    if output_dir is not None and outputs_dir is not None:
        raise ValueError("Pass only one of output_dir or outputs_dir.")
    selected_processed = PROCESSED if processed_dir is None else processed_dir
    selected_outputs = output_dir if output_dir is not None else outputs_dir
    processed_dir, output_dir = _pipeline_paths(selected_processed, selected_outputs)
    output_dir.mkdir(parents=True, exist_ok=True)
    demand = pd.read_csv(processed_dir / "monthly_product_demand.csv")
    run_id = f"run_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"
    generated_at = datetime.now(timezone.utc).isoformat()

    forecasts: list[dict[str, object]] = []
    evaluations: list[dict[str, object]] = []

    for product_id, group in demand.groupby("productId"):
        group = group.sort_values("month")
        series = pd.Series(
            group["quantity"].to_numpy(dtype=float),
            index=group["month"].tolist(),
        )
        full_index = pd.period_range(series.index[0], series.index[-1], freq="M")
        series = series.reindex([str(p) for p in full_index], fill_value=0.0)

        product_name = group["productName"].iloc[-1]
        category = group["category"].iloc[-1]
        plain_values = [
            value
            for month, value in series.items()
            if sum(exogenous_row(pd.Period(month).year, pd.Period(month).month).values()) == 0
        ]
        recent_avg = float(np.mean(plain_values[-6:])) if plain_values else float(series.iloc[-6:].mean())

        model_used, point, lower, upper, evaluation = forecast_product(series)
        smape_value = evaluation.get("sarimaxSmape") or np.inf
        confidence = confidence_label(model_used, len(series), float(smape_value))

        future_periods = month_range(pd.Period(series.index[-1]), FORECAST_MONTHS)
        for step, period in enumerate(future_periods):
            tags = festival_tags(period.year, period.month)
            predicted = float(point[step])
            forecasts.append({
                "runId": run_id,
                "productId": product_id,
                "productName": product_name,
                "category": category,
                "forecastMonth": str(period),
                "predictedQuantity": round(predicted),
                "lowerQuantity": round(float(lower[step])),
                "upperQuantity": round(float(upper[step])),
                "recentMonthlyAverage": round(recent_avg, 1),
                "confidence": confidence,
                "modelUsed": model_used,
                "festivalTag": ", ".join(tags),
                "reason": reason_text(period, predicted, recent_avg, model_used),
                "recommendedAction": recommended_action(predicted, recent_avg),
                "generatedAt": generated_at,
            })

        evaluations.append({
            "productId": product_id,
            "productName": product_name,
            "modelUsed": model_used,
            "confidence": confidence,
            **evaluation,
        })

    forecast_frame = pd.DataFrame(forecasts)
    forecast_frame.to_csv(output_dir / "forecast_results.csv", index=False)
    (output_dir / "demand_forecasts.json").write_text(
        json.dumps(forecasts, indent=2), encoding="utf-8"
    )
    pd.DataFrame(evaluations).to_csv(output_dir / "model_evaluation.csv", index=False)

    sarimax_count = sum(1 for e in evaluations if e["modelUsed"] == "sarimax")
    run_record = {
        "runId": run_id,
        "createdAt": generated_at,
        "periodStart": demand["month"].min(),
        "periodEnd": demand["month"].max(),
        "forecastMonths": [str(p) for p in month_range(pd.Period(demand["month"].max()), FORECAST_MONTHS)],
        "modelUsed": "sarimax_with_festive_exog + festive_baseline_fallback",
        "productCount": int(demand["productId"].nunique()),
        "sarimaxProducts": sarimax_count,
        "baselineProducts": len(evaluations) - sarimax_count,
        "status": "completed",
        "createdBy": "local_pipeline",
    }
    runs_path = output_dir / "forecast_training_runs.json"
    runs: list[dict[str, object]] = []
    if runs_path.exists():
        runs = json.loads(runs_path.read_text(encoding="utf-8"))
    runs.insert(0, run_record)
    runs_path.write_text(json.dumps(runs, indent=2), encoding="utf-8")

    print(f"Run {run_id}")
    print(f"Forecast rows: {len(forecasts)} ({sarimax_count} products via SARIMAX, "
          f"{len(evaluations) - sarimax_count} via baseline)")
    print(f"Wrote {output_dir / 'demand_forecasts.json'}")
    print(f"Wrote {output_dir / 'forecast_results.csv'}")
    print(f"Wrote {output_dir / 'model_evaluation.csv'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Train demand forecasts from prepared monthly demand."
    )
    parser.add_argument(
        "--processed-dir",
        type=Path,
        default=PROCESSED,
        help="Prepared input directory (defaults to data/processed).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Forecast output directory; defaults to outputs/ for production "
            "data and data/evaluation/outputs for other input directories."
        ),
    )
    args = parser.parse_args()
    main(args.processed_dir, args.output_dir)

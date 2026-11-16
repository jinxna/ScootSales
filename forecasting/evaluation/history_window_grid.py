from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from forecasting.ai_core.calendar import EVALUATED_HISTORY_WEEKS
from forecasting.ai_core.forecast_models import (
    MIN_NON_ZERO_FOR_MODEL,
    characterise_demand,
    forecast_next,
    mase,
)

from .closed_loop_runner import (
    DEFAULT_ROLLING_ORIGINS,
    DEFAULT_SEED,
    build_weekly_series,
    load_snapshot,
    usable_orders,
)
from .paired_bootstrap import (
    DEFAULT_BOOTSTRAP_DRAWS,
    paired_ratio_differences,
    ratio_metric_intervals,
)
from .synthetic_exclusion import exclude_synthetic_history

GRID_METHODOLOGY_VERSION = "history-window-grid/1.0.0"
FIRST_ORIGIN_WEEKS = 26
REFERENCE_WEEKS = 8
GRAINS = ("outlet_barcode", "barcode")


def window_for(prefix: Sequence[float], weeks: int) -> list[float]:
    window = [float(value) for value in prefix[-weeks:]]
    return [0.0] * (weeks - len(window)) + window


def _name(weeks: int) -> str:
    return f"N{weeks}"


def score_series(
    values: Sequence[float],
    *,
    grid: Sequence[int],
    first_origin: int = FIRST_ORIGIN_WEEKS,
    max_origins: int = DEFAULT_ROLLING_ORIGINS,
) -> dict[str, Any] | None:
    cleaned = [max(0.0, float(value)) for value in values]
    origins = list(range(first_origin, len(cleaned)))[-max_origins:]
    if not origins:
        return None
    errors: dict[int, list[float]] = {weeks: [] for weeks in grid}
    cold: dict[int, int] = {weeks: 0 for weeks in grid}
    scales: list[float] = []
    for origin in origins:
        train = cleaned[:origin]
        target = cleaned[origin]
        _, scale = mase([target], [0.0], train, seasonality=1)
        scales.append(scale or 0.0)
        for weeks in grid:
            window = window_for(train, weeks)
            point = forecast_next(window, with_interval=False).point
            errors[weeks].append(abs(target - max(0.0, float(point))))
            cold[weeks] += int(characterise_demand(window).is_cold_start)
    return {"errors": errors, "cold": cold, "scales": scales}


def _root(interval: Mapping[str, Any]) -> dict[str, float]:
    return {
        "value": math.sqrt(interval["value"]),
        "lower": math.sqrt(interval["lower"]),
        "upper": math.sqrt(interval["upper"]),
    }


def evaluate_grain(
    series: Sequence[Mapping[str, Any]],
    *,
    grid: Sequence[int],
    seed: int,
    draws: int,
    max_origins: int,
) -> dict[str, Any]:
    scored: list[dict[str, Any]] = []
    for row in series:
        if row.get("isDemo"):
            continue
        result = score_series(row["values"], grid=grid, max_origins=max_origins)
        if result is not None:
            scored.append(result)

    points = sum(len(result["scales"]) for result in scored)
    mae_pairs: dict[str, list[tuple[float, float]]] = {}
    mse_pairs: dict[str, list[tuple[float, float]]] = {}
    scaled_pairs: dict[str, list[tuple[float, float]]] = {}
    per_window: dict[str, Any] = {}
    for weeks in grid:
        name = _name(weeks)
        mae_pairs[name] = [
            (sum(r["errors"][weeks]), float(len(r["scales"]))) for r in scored
        ]
        mse_pairs[name] = [
            (sum(e * e for e in r["errors"][weeks]), float(len(r["scales"])))
            for r in scored
        ]
        scaled_pairs[name] = [
            (
                sum(e for e, s in zip(r["errors"][weeks], r["scales"]) if s > 0),
                sum(r["scales"]),
            )
            for r in scored
            if sum(r["scales"]) > 0
        ]
        all_errors = [e for r in scored for e in r["errors"][weeks]]
        per_window[name] = {
            "historyWeeks": weeks,
            "seriesCount": len(scored),
            "scoredPoints": points,
            "coldStartShare": (
                round(sum(r["cold"][weeks] for r in scored) / points, 4) if points else None
            ),
            "mae": round(statistics.fmean(all_errors), 6) if all_errors else None,
            "rmse": (
                round(math.sqrt(statistics.fmean(e * e for e in all_errors)), 6)
                if all_errors
                else None
            ),
        }

    if scored:
        mae_ci = ratio_metric_intervals(mae_pairs, seed=seed, draws=draws)
        mse_ci = ratio_metric_intervals(mse_pairs, seed=seed, draws=draws)
        scaled_ci = ratio_metric_intervals(scaled_pairs, seed=seed, draws=draws)
        reference = _name(REFERENCE_WEEKS)
        mae_diff = paired_ratio_differences(
            mae_pairs, reference=reference, seed=seed, draws=draws
        )
        scaled_diff = paired_ratio_differences(
            scaled_pairs, reference=reference, seed=seed, draws=draws
        )
        for weeks in grid:
            name = _name(weeks)
            per_window[name]["maeInterval"] = mae_ci[name].to_dict()
            per_window[name]["rmseInterval"] = _root(mse_ci[name].to_dict())
            per_window[name]["scaledError"] = scaled_ci[name].to_dict()
        paired = {
            "reference": reference,
            "mae": mae_diff,
            "scaledError": scaled_diff,
        }
    else:
        paired = {}
    return {
        "seriesScored": len(scored),
        "scoredPoints": points,
        "seriesWithUsableScale": len(next(iter(scaled_pairs.values()), [])),
        "windows": per_window,
        "pairedAgainstReference": paired,
    }


def run_grid(
    snapshot: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    grid: Sequence[int] = EVALUATED_HISTORY_WEEKS,
    seed: int = DEFAULT_SEED,
    draws: int = DEFAULT_BOOTSTRAP_DRAWS,
    max_origins: int = DEFAULT_ROLLING_ORIGINS,
) -> dict[str, Any]:
    clean, exclusion = exclude_synthetic_history(snapshot)
    orders = usable_orders(clean)
    grains = {
        grain: evaluate_grain(
            build_weekly_series(orders, grain=grain),
            grid=grid,
            seed=seed,
            draws=draws,
            max_origins=max_origins,
        )
        for grain in GRAINS
    }
    return {
        "methodologyVersion": GRID_METHODOLOGY_VERSION,
        "status": "EXPLORATORY - not tuning; no window was chosen from these results",
        "grid": list(grid),
        "referenceWeeks": REFERENCE_WEEKS,
        "firstOriginWeeks": FIRST_ORIGIN_WEEKS,
        "maxOriginsPerSeries": max_origins,
        "seed": seed,
        "bootstrapDraws": draws,
        "syntheticExclusion": exclusion,
        "orderCount": len(orders),
        "grains": grains,
    }


def _ci(interval: Mapping[str, Any] | None) -> str:
    if not interval:
        return "n/a"
    return f"{interval['value']:.4f} [{interval['lower']:.4f}, {interval['upper']:.4f}]"


def render_markdown(result: Mapping[str, Any], provenance: Mapping[str, Any]) -> str:
    lines = [
        "# Forecast lookback window grid (EXPLORATORY)",
        "",
        f"- Methodology: `{result['methodologyVersion']}`",
        f"- Status: {result['status']}",
        f"- Snapshot: `{provenance.get('snapshot')}` (sha256 `{provenance.get('sha256')}`)",
        f"- Seed {result['seed']}, {result['bootstrapDraws']} bootstrap draws, "
        "95% percentile intervals, whole series resampled",
        f"- Windows (weeks): {', '.join(str(w) for w in result['grid'])}; reference N{result['referenceWeeks']}",
        f"- Origins: the most recent {result['maxOriginsPerSeries']} per series, each with at "
        f"least {result['firstOriginWeeks']} prior weeks; identical for every window",
        f"- Orders used: {result['orderCount']}",
        "- Overdue-reorder window stays at 8 weeks and SARIMA is not run.",
        "- A pair with no order inside the window is scored with the model's zero forecast "
        "(production would emit no row for it).",
        "- Cold-start share = scored points whose window held fewer than "
        f"{MIN_NON_ZERO_FOR_MODEL} non-zero weeks, so no demand model ran and the "
        "forecast is the cold-start fallback. A high share means the window cannot "
        "matter much on this data.",
        "- Scaled error = total absolute error / total in-sample naive error of the FULL "
        "prefix, a scale shared by every window (not a per-window MASE).",
        "",
    ]
    for grain, report in result["grains"].items():
        label = "outlet x product (production grain)" if grain == "outlet_barcode" else "product"
        lines += [
            f"## Grain: {label}",
            "",
            f"Series scored: {report['seriesScored']}; scored points per window: "
            f"{report['scoredPoints']}; series with a usable shared scale: "
            f"{report['seriesWithUsableScale']}.",
            "",
            "| Window | Pairs (series) | Scored points | Cold-start share | MAE [95% CI] | RMSE [95% CI] | Scaled error [95% CI] |",
            "|---|---|---|---|---|---|---|",
        ]
        for name, row in report["windows"].items():
            lines.append(
                f"| {name} | {row['seriesCount']} | {row['scoredPoints']} | "
                f"{row['coldStartShare']} | {_ci(row.get('maeInterval'))} | "
                f"{_ci(row.get('rmseInterval'))} | {_ci(row.get('scaledError'))} |"
            )
        paired = report["pairedAgainstReference"]
        if paired:
            lines += [
                "",
                f"Paired difference against {paired['reference']} (positive = worse than the reference):",
                "",
                "| Window | MAE difference [95% CI] | Excludes 0 | Scaled-error difference [95% CI] | Excludes 0 |",
                "|---|---|---|---|---|",
            ]
            for name in sorted(paired["mae"], key=lambda key: int(key[1:])):
                mae = paired["mae"][name]
                scaled = paired["scaledError"][name]
                lines.append(
                    f"| {name} | {_ci(mae)} | {mae['excludesZero']} | "
                    f"{_ci(scaled)} | {scaled['excludesZero']} |"
                )
        lines.append("")
    return "\n".join(lines) + "\n"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m forecasting.evaluation.history_window_grid",
        description="Exploratory lookback-window grid over a local snapshot (read-only).",
    )
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--output-dir", default="eval_reports/history_window_grid")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--draws", type=int, default=DEFAULT_BOOTSTRAP_DRAWS)
    parser.add_argument("--max-origins", type=int, default=DEFAULT_ROLLING_ORIGINS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    snapshot_path = Path(args.snapshot)
    if not snapshot_path.is_file():
        print("Snapshot not found: " + str(snapshot_path), file=sys.stderr)
        return 2
    result = run_grid(
        load_snapshot(snapshot_path),
        seed=args.seed,
        draws=args.draws,
        max_origins=args.max_origins,
    )
    provenance = {
        "snapshot": snapshot_path.name,
        "sha256": hashlib.sha256(snapshot_path.read_bytes()).hexdigest(),
    }
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "grid.json").write_text(
        json.dumps({**result, "snapshotProvenance": provenance}, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (output_dir / "summary.md").write_text(
        render_markdown(result, provenance), encoding="utf-8"
    )
    print("Wrote " + str(output_dir / "grid.json"))
    print("Wrote " + str(output_dir / "summary.md"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

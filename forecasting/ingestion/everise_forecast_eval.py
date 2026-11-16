from __future__ import annotations

import argparse
import csv
import warnings
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

try:
    from forecasting.evaluation.metrics import regression_metrics

    _HAVE_METRICS = True
except Exception:  # pragma: no cover - defensive
    _HAVE_METRICS = False


MIN_WEEKS = 8
HOLDOUT = 4
MA_WINDOW = 4


def _monday(iso_week: str) -> date:
    year, week = iso_week.split("-W")
    return date.fromisocalendar(int(year), int(week), 1)


def _iso_label(day: date) -> str:
    iso = day.isocalendar()
    return f"{iso[0]:04d}-W{iso[1]:02d}"


def _contiguous_weeks(labels: list[str]) -> list[str]:
    mondays = sorted({_monday(lbl) for lbl in labels})
    start, end = mondays[0], mondays[-1]
    out: list[str] = []
    cur = start
    while cur <= end:
        out.append(_iso_label(cur))
        cur += timedelta(weeks=1)
    return out


def _naive(train: list[float]) -> float:
    return train[-1] if train else 0.0


def _moving_average(train: list[float], k: int) -> float:
    if not train:
        return 0.0
    window = train[-k:]
    return sum(window) / len(window)


def _fit_sarimax_forecast(train: list[float]) -> float | None:
    try:
        from statsmodels.tsa.statespace.sarimax import SARIMAX
    except Exception:  # pragma: no cover - statsmodels missing
        return None

    orders = [(1, 0, 0), (0, 1, 1), (1, 1, 0), (1, 1, 1)]
    best_aic = float("inf")
    best_pred: float | None = None
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        for order in orders:
            try:
                res = SARIMAX(
                    train,
                    order=order,
                    trend="n",
                    enforce_stationarity=False,
                    enforce_invertibility=False,
                ).fit(disp=False)
                aic = res.aic
                if aic == aic and aic < best_aic:
                    forecast = float(res.forecast(steps=1)[0])
                    best_aic = aic
                    best_pred = forecast
            except Exception:
                continue
    if best_pred is None:
        return None
    return max(0.0, best_pred)


@dataclass
class SeriesResult:
    barcode: str
    productName: str
    observed_weeks: int
    dense_weeks: int
    scored_steps: int
    sarimax_available: int
    actual: list[float]
    sarimax: list[float | None]
    naive: list[float]
    movavg: list[float]


def _walk_forward(
    barcode: str, name: str, weekly: list[float], observed_weeks: int
) -> SeriesResult:
    n = len(weekly)
    start = n - HOLDOUT
    actual: list[float] = []
    sarimax: list[float | None] = []
    naive: list[float] = []
    movavg: list[float] = []
    for i in range(start, n):
        train = weekly[:i]
        actual.append(weekly[i])
        naive.append(_naive(train))
        movavg.append(_moving_average(train, MA_WINDOW))
        sarimax.append(_fit_sarimax_forecast(train))
    scored = len(actual)
    avail = sum(1 for p in sarimax if p is not None)
    return SeriesResult(
        barcode=barcode,
        productName=name,
        observed_weeks=observed_weeks,
        dense_weeks=n,
        scored_steps=scored,
        sarimax_available=avail,
        actual=actual,
        sarimax=sarimax,
        naive=naive,
        movavg=movavg,
    )


def _mae(actual: list[float], pred: list[float]) -> float | None:
    if not actual:
        return None
    return sum(abs(a - p) for a, p in zip(actual, pred)) / len(actual)


def _mape(actual: list[float], pred: list[float]) -> tuple[float | None, float]:
    scorable = [(a, p) for a, p in zip(actual, pred) if a != 0]
    if not actual:
        return None, 0.0
    coverage = len(scorable) / len(actual)
    if not scorable:
        return None, 0.0
    val = sum(abs((a - p) / a) for a, p in scorable) / len(scorable) * 100.0
    return val, coverage


def _pooled_metrics(actual: list[float], pred: list[float]) -> dict[str, object]:
    if _HAVE_METRICS:
        m = regression_metrics(actual, pred)
        return {"mae": m.mae, "mape": m.mape, "mapeCoverage": m.mape_coverage, "n": m.n}
    mae = _mae(actual, pred)
    mape, cov = _mape(actual, pred)
    return {"mae": mae, "mape": mape, "mapeCoverage": cov, "n": len(actual)}


def load_barcode_series(weekly_csv: Path) -> dict[str, tuple[str, dict[str, int]]]:
    series: dict[str, tuple[str, dict[str, int]]] = {}
    with weekly_csv.open(encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            if row["grain"] != "barcode":
                continue
            barcode = row["barcode"]
            name = row.get("productName", "")
            week = row["isoWeek"]
            qty = int(row["orderQty"])
            if barcode not in series:
                series[barcode] = (name, {})
            series[barcode][1][week] = qty
    return series


def build_dense(week_map: dict[str, int]) -> list[float]:
    weeks = _contiguous_weeks(list(week_map))
    return [float(week_map.get(w, 0)) for w in weeks]


def evaluate(weekly_csv: Path) -> dict[str, object]:
    raw = load_barcode_series(weekly_csv)
    eligible: list[SeriesResult] = []
    skipped_sparse = 0
    for barcode, (name, week_map) in sorted(raw.items()):
        if len(week_map) < MIN_WEEKS:
            skipped_sparse += 1
            continue
        dense = build_dense(week_map)
        if len(dense) < MIN_WEEKS + 1:
            skipped_sparse += 1
            continue
        eligible.append(_walk_forward(barcode, name, dense, len(week_map)))

    a_all, s_pred, s_actual, s_naive, s_ma = [], [], [], [], []
    a_full, n_full, m_full = [], [], []
    for r in eligible:
        for act, sp, na, mv in zip(r.actual, r.sarimax, r.naive, r.movavg):
            a_full.append(act)
            n_full.append(na)
            m_full.append(mv)
            if sp is not None:
                s_actual.append(act)
                s_pred.append(sp)
                s_naive.append(na)
                s_ma.append(mv)

    return {
        "min_weeks": MIN_WEEKS,
        "holdout": HOLDOUT,
        "ma_window": MA_WINDOW,
        "eligible_series": len(eligible),
        "skipped_sparse": skipped_sparse,
        "total_barcodes": len(raw),
        "results": eligible,
        "naive": _pooled_metrics(a_full, n_full),
        "movavg": _pooled_metrics(a_full, m_full),
        "sarimax": _pooled_metrics(s_actual, s_pred),
        "naive_on_sarimax_steps": _pooled_metrics(s_actual, s_naive),
        "movavg_on_sarimax_steps": _pooled_metrics(s_actual, s_ma),
        "sarimax_scored_steps": len(s_pred),
        "total_scored_steps": len(a_full),
        "used_shared_metrics": _HAVE_METRICS,
    }


def _fmt(value: object) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def render_report(ev: dict[str, object]) -> str:
    lines: list[str] = []
    lines.append("# Everrise proposal-order forecast evaluation")
    lines.append("")
    lines.append(
        "Walk-forward one-step-ahead evaluation of SARIMAX against naive "
        "last-value and moving-average baselines on the ingested Everrise "
        "proposal-order demand."
    )
    lines.append("")
    lines.append("## Data reality (read first)")
    lines.append("")
    lines.append(
        "The proposal-order workbooks record demand only on the dates an order "
        "was actually proposed - about 35 distinct dates falling in roughly 16 "
        "distinct ISO weeks, spread across ~68 calendar weeks. This is "
        "order-batch data, not a continuous weekly series."
    )
    lines.append("")
    lines.append(
        "- Per outlet x barcode pairs and per outlet (all SKUs) are too sparse: "
        "no such series reaches the 8-weekly-point minimum, so neither grain is "
        "forecastable here."
    )
    lines.append(
        "- The only grain with usable length is **per barcode summed across all "
        "outlets**. Even there the count of weeks with an actual order is small "
        "(the top SKUs have ~12 real order-weeks); the weekly index is made "
        "contiguous over the observed span with unobserved weeks treated as zero "
        "demand, which is what stretches the dense length out. 'Observed weeks' "
        "counts real order-weeks; 'dense weeks' counts the gap-filled contiguous "
        "index actually fed to the models."
    )
    lines.append("")
    lines.append(
        f"Eligible per-barcode series (>= {ev['min_weeks']} observed weeks): "
        f"**{ev['eligible_series']}** of {ev['total_barcodes']} barcodes; "
        f"{ev['skipped_sparse']} skipped as too sparse."
    )
    lines.append(
        f"Holdout: last {ev['holdout']} weeks per series, expanding-window "
        f"one-step-ahead. Moving-average window: {ev['ma_window']}. "
        f"Metrics module used: {'shared' if ev['used_shared_metrics'] else 'local fallback'}."
    )
    lines.append("")

    lines.append("## Headline (pooled over all scored steps)")
    lines.append("")
    lines.append(f"Total scored steps: {ev['total_scored_steps']}.")
    lines.append("")
    lines.append("| method | MAE | MAPE | MAPE coverage | n |")
    lines.append("|---|---|---|---|---|")
    for label, key in [("naive last-value", "naive"), (f"moving-avg (k={ev['ma_window']})", "movavg")]:
        m = ev[key]
        lines.append(
            f"| {label} | {_fmt(m['mae'])} | {_fmt(m['mape'])}% | "
            f"{_fmt(m['mapeCoverage'])} | {m['n']} |"
        )
    lines.append("")

    lines.append("## SARIMAX vs baselines (identical scored steps)")
    lines.append("")
    lines.append(
        f"SARIMAX produced a prediction on {ev['sarimax_scored_steps']} of "
        f"{ev['total_scored_steps']} scored steps. The baselines below are "
        "recomputed on exactly those steps for a fair head-to-head."
    )
    lines.append("")
    lines.append("| method | MAE | MAPE | MAPE coverage | n |")
    lines.append("|---|---|---|---|---|")
    for label, key in [
        ("SARIMAX (AIC-selected)", "sarimax"),
        ("naive last-value", "naive_on_sarimax_steps"),
        (f"moving-avg (k={ev['ma_window']})", "movavg_on_sarimax_steps"),
    ]:
        m = ev[key]
        lines.append(
            f"| {label} | {_fmt(m['mae'])} | {_fmt(m['mape'])}% | "
            f"{_fmt(m['mapeCoverage'])} | {m['n']} |"
        )
    lines.append("")

    sar = ev["sarimax"]["mae"]
    nai = ev["naive_on_sarimax_steps"]["mae"]
    lines.append("## Verdict")
    lines.append("")
    if ev["eligible_series"] == 0:
        lines.append(
            "No series had enough contiguous history to fit SARIMAX. The data "
            "is too sparse for time-series forecasting at any grain; treat the "
            "baselines as the only meaningful reference."
        )
    else:
        if sar is not None and nai is not None:
            verdict = "beats" if sar < nai else ("ties" if abs(sar - nai) < 1e-6 else "does not beat")
            lines.append(
                f"On identical steps, SARIMAX MAE {_fmt(sar)} {verdict} the "
                f"naive baseline MAE {_fmt(nai)}."
            )
        lines.append("")
        lines.append(
            "Honest caveat: these series are short and gappy (order batches, "
            "not weekly retail sell-through). SARIMAX has very little signal to "
            "learn from, so parity with - or a small edge over - naive is the "
            "realistic ceiling here, not evidence of a strong seasonal model. "
            "Do not read the MAPE as production accuracy; it is dominated by "
            "small-count weeks. Note too that the gap-filled index is mostly "
            "zero (a barcode may have ~9-12 real order-weeks stretched over a "
            "60+ week span), so much of the 'accuracy' is trivially predicting "
            "zero-to-zero; the non-zero order weeks are where every method "
            "struggles. The proper fix is a denser demand feed (actual "
            "sell-through or dated point-of-sale), not a fancier model."
        )
    lines.append("")

    lines.append("## Worst per-series (by SARIMAX MAE, where available)")
    lines.append("")
    scored: list[tuple[float, SeriesResult]] = []
    for r in ev["results"]:  # type: ignore[assignment]
        pairs = [(a, p) for a, p in zip(r.actual, r.sarimax) if p is not None]
        if not pairs:
            continue
        mae = sum(abs(a - p) for a, p in pairs) / len(pairs)
        scored.append((mae, r))
    scored.sort(key=lambda t: t[0], reverse=True)
    lines.append("| barcode | product | observed / dense weeks | SARIMAX MAE |")
    lines.append("|---|---|---|---|")
    for mae, r in scored[:8]:
        name = (r.productName or "")[:40]
        lines.append(
            f"| {r.barcode} | {name} | {r.observed_weeks} / {r.dense_weeks} | {_fmt(mae)} |"
        )
    lines.append("")
    return "\n".join(lines)


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Evaluate SARIMAX vs baselines on ingested Everrise weekly demand.",
    )
    parser.add_argument(
        "--weekly",
        default="forecasting/data/real/weekly_demand.csv",
        help="Path to weekly_demand.csv from everise_ingest.",
    )
    parser.add_argument(
        "--out",
        default="forecasting/data/real/eval_report.md",
        help="Where to write the Markdown report (git-ignored).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_arg_parser().parse_args(argv)
    weekly = Path(args.weekly)
    if not weekly.exists():
        raise SystemExit(f"weekly demand file not found: {weekly}")
    ev = evaluate(weekly)
    report = render_report(ev)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(report, encoding="utf-8")
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

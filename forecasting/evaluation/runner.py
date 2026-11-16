from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Mapping, Sequence

from forecasting.ai_service.order_lines import authoritative_order_items

from forecasting.ai_service.replenishment import (
    EXCLUDED_ORDER_STATUSES,
    _as_local_date,
    _first_number,
    _first_text,
    _text,
)

from .forecast_backtest import DemandSeries, run_forecast_backtest
from .loop_metrics import compute_loop_metrics
from .overdue_backtest import run_overdue_backtest
from .synthetic_exclusion import exclude_synthetic_history
from .suggestion_eval import (
    evaluate_acceptance,
    evaluate_suppression,
    extract_suggestions_from_briefs,
)

SNAPSHOT_COLLECTIONS: dict[str, int] = {
    "orders": 5000,
    "ai_insights": 5000,
    "conversation_outcomes": 2000,
    "visit_briefs": 2000,
    "retailer_memory": 2000,
    "retailer_item_patterns": 5000,
    "products": 2000,
}

EVALUATION_METHODOLOGY_VERSION = "offline-eval/2.0.0"
DEFAULT_HOLDOUT_WEEKS = 4
DEFAULT_OUTPUT_DIR = "eval_reports"
STUDY_RESULTS_CSV = "document/docuu/evaluation_study/results_template.csv"

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_snapshot(path: str) -> dict[str, list[dict[str, Any]]]:
    with open(path, "r", encoding="utf-8") as handle:
        raw = json.load(handle)
    if not isinstance(raw, Mapping):
        raise ValueError("snapshot must be a JSON object keyed by collection")
    return {
        collection: list(raw.get(collection) or [])
        for collection in SNAPSHOT_COLLECTIONS
    }


def live_read(service_account: str | None) -> dict[str, list[dict[str, Any]]]:
    from forecasting.ai_service.repository import create_firestore_client

    client = create_firestore_client(service_account)
    snapshot: dict[str, list[dict[str, Any]]] = {}
    for collection, limit in SNAPSHOT_COLLECTIONS.items():
        docs = client.collection(collection).limit(limit).stream()
        snapshot[collection] = [
            {"docId": doc.id, **(doc.to_dict() or {})} for doc in docs
        ]
    return snapshot


def dump_snapshot(snapshot: Mapping[str, list[dict[str, Any]]], path: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle, default=str, sort_keys=True, indent=2)


def _max_order_date(
    orders: Sequence[Mapping[str, Any]], *, real_only: bool = False
) -> date | None:
    latest: date | None = None
    for order in orders:
        if _text(order.get("status")).lower() in EXCLUDED_ORDER_STATUSES:
            continue
        if real_only and order.get("isDemo") is True:
            continue
        order_date = _as_local_date(
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if order_date is not None and (latest is None or order_date > latest):
            latest = order_date
    return latest


def _demo_index(
    patterns: Sequence[Mapping[str, Any]],
) -> dict[tuple[str, str], bool]:
    index: dict[tuple[str, str], bool] = {}
    for row in patterns:
        retailer_id = _first_text(row, ("retailerId", "retailer_id"))
        product_id = _first_text(row, ("productId", "product_id"))
        if retailer_id and product_id:
            index[(retailer_id, product_id)] = row.get("isDemo") is True
    return index


def _build_demand_series(
    orders: Sequence[Mapping[str, Any]],
    demo_index: Mapping[tuple[str, str], bool],
) -> list[DemandSeries]:
    events: dict[tuple[str, str], list[tuple[date, float]]] = {}
    order_demo: dict[tuple[str, str], bool] = {}
    for order in orders:
        if _text(order.get("status")).lower() in EXCLUDED_ORDER_STATUSES:
            continue
        order_date = _as_local_date(
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if order_date is None:
            continue
        retailer_id = _first_text(
            order, ("retailerId", "retailer_id", "retailerCode")
        )
        if not retailer_id:
            continue
        is_demo_order = order.get("isDemo") is True
        items = authoritative_order_items(order)
        for raw_item in items:
            if not isinstance(raw_item, Mapping):
                continue
            product_id = _first_text(
                raw_item, ("productId", "itemId", "productCode", "sku")
            )
            if not product_id:
                continue
            qty = _first_number(
                raw_item, ("qty", "quantity", "orderQty", "boxes")
            )
            if qty <= 0:
                continue
            key = (retailer_id, product_id)
            events.setdefault(key, []).append((order_date, qty))
            order_demo[key] = order_demo.get(key, False) or is_demo_order
    series: list[DemandSeries] = []
    for key, pair_events in events.items():
        is_demo = demo_index.get(key)
        if is_demo is None:
            is_demo = order_demo.get(key, False)
        series.append(
            DemandSeries(
                retailer_id=key[0],
                product_id=key[1],
                events=pair_events,
                is_demo=is_demo,
            )
        )
    return series


def _unit_prices(products: Sequence[Mapping[str, Any]]) -> dict[str, float]:
    prices: dict[str, float] = {}
    for row in products:
        product_id = _first_text(row, ("productId", "itemId", "docId"))
        if not product_id:
            continue
        prices[product_id] = _first_number(
            row, ("unitPrice", "price", "priceGuide", "sellingPrice")
        )
    return prices


def _study_status() -> dict[str, Any]:
    path = REPO_ROOT / STUDY_RESULTS_CSV
    has_data = False
    row_count = 0
    if path.is_file():
        with open(path, "r", encoding="utf-8") as handle:
            lines = [line for line in handle.read().splitlines() if line.strip()]
        row_count = max(0, len(lines) - 1)
        has_data = row_count > 0
    return {
        "status": "collected" if has_data else "not yet run",
        "dataRowCount": row_count,
        "resultsCsv": STUDY_RESULTS_CSV,
    }


@dataclass
class EvaluationResult:
    cutoff: date
    holdout_weeks: int
    payload: dict[str, Any]


def run_evaluation(
    snapshot: Mapping[str, list[dict[str, Any]]],
    *,
    cutoff: date | None,
    holdout_weeks: int,
) -> EvaluationResult:
    snapshot, synthetic_exclusion = exclude_synthetic_history(snapshot)
    orders = snapshot.get("orders", [])
    patterns = snapshot.get("retailer_item_patterns", [])
    products = snapshot.get("products", [])
    briefs = snapshot.get("visit_briefs", [])
    memory = snapshot.get("retailer_memory", [])
    insights = snapshot.get("ai_insights", [])
    outcomes = snapshot.get("conversation_outcomes", [])

    dataset_max = _max_order_date(orders)
    effective_cutoff = cutoff or dataset_max or date(1970, 1, 1)

    demo_index = _demo_index(patterns)
    unit_prices = _unit_prices(products)

    series = _build_demand_series(orders, demo_index)
    if series:
        forecast_reports = run_forecast_backtest(
            series,
            holdout_weeks=holdout_weeks,
            data_end=_max_order_date(orders, real_only=True) or dataset_max,
        )
        forecast_payload = {
            cohort: report.to_dict()
            for cohort, report in forecast_reports.items()
        }
    else:
        forecast_payload = None

    suggestions = extract_suggestions_from_briefs(briefs)
    brief_dates = [
        d
        for d in (_as_local_date(b.get("generatedAt")) for b in briefs)
        if d is not None
    ]
    acceptance_reports = evaluate_acceptance(
        suggestions, orders, on_or_after=min(brief_dates) if brief_dates else None
    )
    suppression_report = evaluate_suppression(suggestions, memory)

    post_window_end = (dataset_max or effective_cutoff) + timedelta(days=1)
    if post_window_end <= effective_cutoff:
        post_window_end = effective_cutoff + timedelta(days=1)
    overdue_payload: dict[str, Any] | None
    if orders:
        overdue_reports = run_overdue_backtest(
            orders,
            patterns,
            memory,
            unit_prices,
            cutoff=effective_cutoff,
            post_window_end=post_window_end,
        )
        overdue_payload = {
            cohort: report.to_dict()
            for cohort, report in overdue_reports.items()
        }
    else:
        overdue_payload = None

    loop_reports = compute_loop_metrics(
        insights, outcomes, cutoff=effective_cutoff
    )
    loop_payload = {
        cohort: report.to_dict() for cohort, report in loop_reports.items()
    }

    payload = {
        "methodologyVersion": EVALUATION_METHODOLOGY_VERSION,
        "syntheticExclusion": synthetic_exclusion,
        "cutoff": effective_cutoff.isoformat(),
        "holdoutWeeks": holdout_weeks,
        "datasetMaxOrderDate": (
            dataset_max.isoformat() if dataset_max else None
        ),
        "inputCounts": {
            collection: len(snapshot.get(collection, []))
            for collection in SNAPSHOT_COLLECTIONS
        },
        "pillarA": {
            "forecastAccuracy": forecast_payload,
            "suggestionAcceptance": {
                cohort: report.to_dict()
                for cohort, report in acceptance_reports.items()
            },
            "suppressionSafety": suppression_report.to_dict(),
            "overdueEarlyWarning": overdue_payload,
        },
        "pillarB": _study_status(),
        "pillarC": loop_payload,
    }
    return EvaluationResult(
        cutoff=effective_cutoff,
        holdout_weeks=holdout_weeks,
        payload=payload,
    )


def _fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def _regression_row(label: str, metrics: Mapping[str, Any] | None) -> str:
    if not metrics:
        return f"| {label} | n/a | n/a | n/a | n/a |"
    return (
        f"| {label} | {_fmt(metrics.get('n'))} | {_fmt(metrics.get('mae'))} "
        f"| {_fmt(metrics.get('rmse'))} | {_fmt(metrics.get('mape'))} |"
    )


def render_markdown(result: EvaluationResult) -> str:
    payload = result.payload
    lines: list[str] = []
    lines.append("# Offline evaluation report")
    lines.append("")
    lines.append(f"- Methodology: `{payload['methodologyVersion']}`")
    exclusion = payload["syntheticExclusion"]
    lines.append(
        f"- Synthetic-history records excluded: {exclusion['excludedTotal']} "
        f"({exclusion['excludedByCollection']})"
    )
    lines.append(f"- Cutoff (run-stamp): `{payload['cutoff']}`")
    lines.append(f"- Holdout weeks: {payload['holdoutWeeks']}")
    lines.append(
        f"- Dataset max order date: {_fmt(payload['datasetMaxOrderDate'])}"
    )
    counts = ", ".join(
        f"{name} {count}" for name, count in payload["inputCounts"].items()
    )
    lines.append(f"- Input counts: {counts}")
    lines.append("")

    lines.append("## Pillar A - decision quality")
    lines.append("")

    lines.append("### A-001 Forecast accuracy vs baselines")
    forecast = payload["pillarA"]["forecastAccuracy"]
    if not forecast:
        lines.append(
            "_Insufficient data: no demand series could be built from orders._"
        )
    else:
        for cohort in ("demo", "nonDemo"):
            report = forecast.get(cohort) or {}
            lines.append(f"**{cohort}** - "
                         f"scored pairs {report.get('scoredPairCount', 0)}, "
                         f"insufficient history "
                         f"{report.get('insufficientHistoryCount', 0)}")
            aggregate = report.get("aggregate") or {}
            lines.append("")
            lines.append("| Predictor | n | MAE | RMSE | MAPE |")
            lines.append("|---|---|---|---|---|")
            lines.append(_regression_row("model", aggregate.get("model")))
            lines.append(_regression_row("naive", aggregate.get("naive")))
            lines.append(
                _regression_row(
                    "movingAverage", aggregate.get("movingAverage")
                )
            )
            lines.append("")
            worst = report.get("worstCases") or []
            if worst:
                lines.append("Worst cases (by model MAE):")
                for case in worst:
                    lines.append(
                        f"- {case.get('retailerId')} / {case.get('productId')}: "
                        f"model MAE {_fmt(case.get('modelMae'))} vs naive "
                        f"{_fmt(case.get('naiveMae'))}"
                    )
                lines.append("")
        lines.append(
            "> Note: no SARIMAX predictor is run offline; the model column "
            "mirrors the naive last-value baseline unless precomputed "
            "predictions are supplied. Report the model column accordingly."
        )
        lines.append("")

    lines.append("### A-002 Suggestion acceptance")
    acceptance = payload["pillarA"]["suggestionAcceptance"]
    for cohort in ("demo", "nonDemo"):
        report = acceptance.get(cohort) or {}
        total = report.get("total", 0)
        lines.append(f"**{cohort}** - suggestions matched: {total}")
        if total == 0:
            lines.append("_Insufficient data: no suggestions in this cohort._")
        else:
            rates = report.get("rates") or {}
            lines.append("")
            lines.append("| Class | Rate |")
            lines.append("|---|---|")
            for cls in ("exact", "within_one", "directional", "not_ordered"):
                lines.append(f"| {cls} | {_fmt(rates.get(cls))} |")
        lines.append("")

    lines.append("### A-003 Suppression correctness (safety invariant)")
    suppression = payload["pillarA"]["suppressionSafety"]
    if suppression.get("ok"):
        lines.append(
            f"PASS - {suppression.get('suppressedPairCount', 0)} suppressed "
            f"pairs, {suppression.get('violationCount', 0)} violations across "
            f"{suppression.get('suggestionCount', 0)} suggestions."
        )
    else:
        lines.append(
            f"**HARD FAILURE** - {suppression.get('violationCount', 0)} "
            "suppressed product(s) were suggested. Each is a qualitative "
            "safety failure:"
        )
        for violation in suppression.get("violations", []):
            lines.append(
                f"- {violation.get('retailerId')} / "
                f"{violation.get('productId')} (demo={violation.get('isDemo')})"
            )
    lines.append("")

    lines.append("### A-004 Overdue-reorder early-warning validity")
    overdue = payload["pillarA"]["overdueEarlyWarning"]
    if not overdue:
        lines.append("_Insufficient data: no orders to backtest._")
    else:
        for cohort in ("demo", "nonDemo"):
            report = overdue.get(cohort) or {}
            lines.append(
                f"**{cohort}** - eligible {report.get('eligiblePopulation', 0)}, "
                f"ground-truth positives {report.get('groundTruthPositives', 0)}"
            )
            detector = report.get("detector") or {}
            baseline = report.get("baseline") or {}
            lines.append("")
            lines.append("| Method | Precision | Recall | F1 |")
            lines.append("|---|---|---|---|")
            lines.append(
                f"| detector | {_fmt(detector.get('precision'))} | "
                f"{_fmt(detector.get('recall'))} | {_fmt(detector.get('f1'))} |"
            )
            lines.append(
                f"| baseline | {_fmt(baseline.get('precision'))} | "
                f"{_fmt(baseline.get('recall'))} | {_fmt(baseline.get('f1'))} |"
            )
            if report.get("tinyPopulation"):
                lines.append("")
                lines.append(f"> {report.get('note')}")
            lines.append("")

    lines.append("## Pillar B - explainability & trust study")
    study = payload["pillarB"]
    lines.append("")
    lines.append(
        f"- Study status: **{study['status']}** "
        f"({study['dataRowCount']} data row(s) in `{study['resultsCsv']}`)."
    )
    lines.append(
        "- This is a manual usability study; run "
        "`python document/docuu/evaluation_study/analyze_study.py "
        "document/docuu/evaluation_study/results_template.csv` once results are collected."
    )
    lines.append("")

    lines.append("## Pillar C - loop effectiveness")
    lines.append("")
    loop = payload["pillarC"]
    for cohort in ("demo", "nonDemo"):
        report = loop.get(cohort) or {}
        resolution = report.get("resolution") or {}
        lines.append(f"### {cohort}")
        lines.append(
            f"- Insights: {resolution.get('totalInsights', 0)} "
            f"(closed {resolution.get('closedInsights', 0)})"
        )
        if resolution.get("insufficientData"):
            lines.append(f"- Resolution rate: n/a - {resolution.get('note')}")
        else:
            lines.append(
                f"- Loop resolution rate: "
                f"{_fmt(resolution.get('resolutionRate'))} "
                f"({resolution.get('loopClosed', 0)}/"
                f"{resolution.get('loopEngaged', 0)} loop-engaged insights)"
            )
        latency = report.get("latency") or {}
        d2o = latency.get("detectionToOutcome") or {}
        o2c = latency.get("outcomeToClose") or {}
        lines.append("")
        lines.append("| Leg | Count | Median days | p90 days |")
        lines.append("|---|---|---|---|")
        lines.append(
            f"| detection -> outcome | {d2o.get('count', 0)} | "
            f"{_fmt(d2o.get('medianDays'))} | {_fmt(d2o.get('p90Days'))} |"
        )
        lines.append(
            f"| outcome -> close | {o2c.get('count', 0)} | "
            f"{_fmt(o2c.get('medianDays'))} | {_fmt(o2c.get('p90Days'))} |"
        )
        trend = report.get("valueAtRiskTrend") or {}
        points = trend.get("points") or []
        lines.append("")
        if points:
            lines.append("Unresolved value-at-risk by week (open insights):")
            lines.append("")
            lines.append("| Week start | Open VaR (RM) | Open count |")
            lines.append("|---|---|---|")
            for point in points:
                lines.append(
                    f"| {point.get('weekStart')} | "
                    f"{_fmt(point.get('openValueAtRiskRm'))} | "
                    f"{point.get('openCount')} |"
                )
        if trend.get("undatedInsightCount"):
            lines.append("")
            lines.append(f"> {trend.get('note')}")
        lines.append("")

    return "\n".join(lines) + "\n"


def write_reports(result: EvaluationResult, output_dir: str) -> tuple[Path, Path]:
    directory = Path(output_dir)
    directory.mkdir(parents=True, exist_ok=True)
    runstamp = result.cutoff.isoformat()
    json_path = directory / f"eval_report_{runstamp}.json"
    md_path = directory / f"eval_report_{runstamp}.md"
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(result.payload, handle, default=str, sort_keys=True, indent=2)
    with open(md_path, "w", encoding="utf-8") as handle:
        handle.write(render_markdown(result))
    return json_path, md_path


def _cutoff(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD") from exc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m forecasting.evaluation.runner",
        description="Offline evaluation harness (read-only; writes eval_reports/)",
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument(
        "--snapshot",
        help="path to a local JSON snapshot of Firestore documents (offline)",
    )
    source.add_argument(
        "--live-read",
        action="store_true",
        help="bounded read-only Firestore read (never writes)",
    )
    parser.add_argument(
        "--cutoff",
        type=_cutoff,
        default=None,
        help="run-stamp/backtest cutoff YYYY-MM-DD (default: max order date)",
    )
    parser.add_argument(
        "--holdout-weeks",
        type=int,
        default=DEFAULT_HOLDOUT_WEEKS,
        help=f"forecast holdout weeks (default: {DEFAULT_HOLDOUT_WEEKS})",
    )
    parser.add_argument(
        "--dump-snapshot",
        help="with --live-read, save the raw documents to this JSON file",
    )
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT_DIR,
        help=f"report output directory (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--service-account",
        help="optional local key path for --live-read; production uses ADC",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.snapshot and not args.live_read:
        parser.print_help()
        return 0

    if args.holdout_weeks <= 0:
        parser.error("--holdout-weeks must be positive")

    if args.snapshot:
        snapshot = load_snapshot(args.snapshot)
    else:
        snapshot = live_read(args.service_account)
        if args.dump_snapshot:
            dump_snapshot(snapshot, args.dump_snapshot)

    result = run_evaluation(
        snapshot,
        cutoff=args.cutoff,
        holdout_weeks=args.holdout_weeks,
    )
    json_path, md_path = write_reports(result, args.output_dir)
    print(f"Wrote {json_path}")
    print(f"Wrote {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

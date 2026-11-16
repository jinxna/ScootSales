from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Mapping, Sequence

from forecasting.ai_core.calendar import (
    as_kuching_date,
    completed_week_starts,
    week_start,
)
from forecasting.ai_core.forecast_models import (
    CV_ESTIMATOR,
    FORECAST_MODELS_VERSION,
    characterise_demand,
)
from forecasting.ai_core.route_policy import POLICY_VERSION
from forecasting.ai_core.forecast_contract import FORECAST_CONTRACT_VERSION
from forecasting.ai_core.opportunity import (
    EXPECTED_ORDER_VALUE_VERSION,
    retailer_opportunities,
)
from forecasting.ai_service.order_lines import authoritative_order_items
from forecasting.ai_service.replenishment import EXCLUDED_ORDER_STATUSES
from forecasting.evaluation.model_selection_backtest import (
    MASE_SCALE_DEFINITION,
    PREDICTOR_NAMES,
    aligned_series_pairs,
    run_model_selection_backtest,
)
from forecasting.evaluation.paired_bootstrap import (
    DEFAULT_BOOTSTRAP_DRAWS,
    mean_difference_intervals,
    paired_ratio_differences,
    ratio_metric_intervals,
)
from forecasting.evaluation.route_policy_sim import (
    EXPLORATION_SCORE_BAND,
    SimCandidate,
    kuching_coordinates,
    realised_ratio_catalogue_from_snapshot,
    simulate_policies,
)
from forecasting.evaluation.signal_quality import evaluate_signals_at_cutoff
from forecasting.evaluation.synthetic_exclusion import exclude_synthetic_history

PROTOCOL_VERSION = "closed-loop-eval/6.0.0"
DEFAULT_SEED = 20260918
DEFAULT_TRUTH_WINDOW_DAYS = 28
DEFAULT_ROLLING_ORIGINS = 12
DEFAULT_SIM_REPLICATES = 40
DEFAULT_SIM_TARGET_SIZE = 12
DEFAULT_SIM_POOL_SIZE = 40
DEFAULT_CUTOFF_COUNT = 6


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _order_date(order: Mapping[str, Any]) -> date | None:
    raw = (
        order.get("submittedAt")
        or order.get("orderDate")
        or order.get("createdAt")
    )
    if isinstance(raw, datetime):
        return as_kuching_date(raw)
    if isinstance(raw, date):
        return raw
    if raw is None:
        return None
    try:
        return as_kuching_date(
            datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
        )
    except ValueError:
        return None


def usable_orders(
    snapshot: Mapping[str, Sequence[Mapping[str, Any]]],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for raw in snapshot.get("orders", []):
        order = dict(raw)
        if _text(order.get("status")).lower() in EXCLUDED_ORDER_STATUSES:
            continue
        if _order_date(order) is None:
            continue
        if not _text(order.get("retailerId") or order.get("retailer_id")):
            continue
        rows.append(order)
    return rows


def build_weekly_series(
    orders: Sequence[Mapping[str, Any]],
    *,
    grain: str,
) -> list[dict[str, Any]]:
    if grain not in {"barcode", "outlet", "outlet_barcode"}:
        raise ValueError("grain must be barcode, outlet or outlet_barcode")
    dated = [
        (order, order_date)
        for order in orders
        if (order_date := _order_date(order)) is not None
        and _text(order.get("retailerId") or order.get("retailer_id"))
    ]
    real_dates = [d for order, d in dated if order.get("isDemo") is not True]
    latest = max(real_dates or [d for _, d in dated], default=None)
    if latest is None:
        return []
    cutoff_week = completed_week_starts(latest + timedelta(days=1), weeks=1)[-1]
    buckets: dict[str, dict[date, float]] = {}
    demo: dict[str, bool] = {}
    for order, order_date in dated:
        retailer = _text(order.get("retailerId") or order.get("retailer_id"))
        bucket_week = week_start(order_date)
        if bucket_week > cutoff_week:
            continue
        is_demo = order.get("isDemo") is True
        for raw_item in authoritative_order_items(order):
            product = _text(raw_item.get("productId"))
            if not product:
                continue
            quantity = float(raw_item.get("qty") or raw_item.get("quantity") or 0.0)
            if quantity <= 0:
                continue
            if grain == "barcode":
                key = product
            elif grain == "outlet":
                key = retailer
            else:
                key = retailer + "|" + product
            week_bucket = buckets.setdefault(key, {})
            week_bucket[bucket_week] = week_bucket.get(bucket_week, 0.0) + quantity
            demo[key] = demo.get(key, False) or is_demo
    series: list[dict[str, Any]] = []
    for key in sorted(buckets):
        by_week = buckets[key]
        first = min(by_week)
        last = cutoff_week
        values: list[float] = []
        cursor = first
        while cursor <= last:
            values.append(round(by_week.get(cursor, 0.0), 4))
            cursor = cursor + timedelta(weeks=1)
        series.append(
            {
                "key": key,
                "values": values,
                "isDemo": demo.get(key, False),
                "firstWeek": first.isoformat(),
                "lastWeek": last.isoformat(),
            }
        )
    return series


def profile_series(series: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    classes: dict[str, int] = {}
    non_zero_rates: list[float] = []
    lengths: list[int] = []
    eligible = 0
    for row in series:
        values = [float(value) for value in row.get("values", [])]
        characterisation = characterise_demand(values)
        classes[characterisation.classification] = (
            classes.get(characterisation.classification, 0) + 1
        )
        non_zero_rates.append(characterisation.non_zero_rate)
        lengths.append(characterisation.periods)
        if characterisation.non_zero_periods >= 3:
            eligible += 1
    return {
        "seriesCount": len(series),
        "seriesWithThreeOrMoreOrderWeeks": eligible,
        "classificationCounts": dict(sorted(classes.items())),
        "meanNonZeroRate": (
            round(sum(non_zero_rates) / len(non_zero_rates), 4)
            if non_zero_rates
            else None
        ),
        "meanPeriods": round(sum(lengths) / len(lengths), 4) if lengths else None,
        "maxPeriods": max(lengths) if lengths else None,
    }


def build_patterns(
    orders: Sequence[Mapping[str, Any]],
    *,
    as_of: date,
    weeks: int = 8,
) -> list[dict[str, Any]]:
    starts = completed_week_starts(as_of, weeks=weeks)
    allowed = set(starts)
    pairs: dict[tuple[str, str], dict[str, Any]] = {}
    for order in orders:
        order_date = _order_date(order)
        if order_date is None or order_date >= as_of:
            continue
        retailer = _text(order.get("retailerId") or order.get("retailer_id"))
        if not retailer:
            continue
        for raw_item in authoritative_order_items(order):
            product = _text(raw_item.get("productId"))
            if not product:
                continue
            quantity = float(raw_item.get("qty") or raw_item.get("quantity") or 0.0)
            if quantity <= 0:
                continue
            bucket = week_start(order_date)
            if bucket not in allowed:
                continue
            entry = pairs.setdefault(
                (retailer, product),
                {
                    "retailerId": retailer,
                    "productId": product,
                    "retailerName": _text(order.get("retailerName")),
                    "productName": _text(raw_item.get("productName")),
                    "salesmanCode": _text(order.get("salesmanCode")),
                    "salesmanUid": _text(order.get("salesmanUid")),
                    "branchId": _text(order.get("branchId")),
                    "weekly": {start: 0.0 for start in starts},
                },
            )
            entry["weekly"][bucket] = entry["weekly"].get(bucket, 0.0) + quantity
    patterns: list[dict[str, Any]] = []
    for key in sorted(pairs):
        entry = pairs[key]
        quantities = [round(entry["weekly"].get(start, 0.0), 4) for start in starts]
        patterns.append(
            {
                "retailerId": entry["retailerId"],
                "productId": entry["productId"],
                "retailerName": entry["retailerName"],
                "productName": entry["productName"],
                "salesmanCode": entry["salesmanCode"],
                "salesmanUid": entry["salesmanUid"],
                "branchId": entry["branchId"],
                "weekStarts": [start.isoformat() for start in starts],
                "weeklyQuantities": quantities,
                "baselineAverage": (
                    round(sum(quantities) / len(quantities), 4)
                    if quantities
                    else 0.0
                ),
                "isDemo": False,
            }
        )
    return patterns


def candidate_cutoffs(
    orders: Sequence[Mapping[str, Any]],
    *,
    count: int,
    truth_window_days: int,
) -> list[date]:
    dates = [d for d in (_order_date(order) for order in orders) if d is not None]
    if not dates:
        return []
    latest = max(dates)
    cursor = latest - timedelta(days=truth_window_days)
    cutoffs: list[date] = []
    while len(cutoffs) < count:
        cutoffs.append(cursor)
        cursor = cursor - timedelta(weeks=1)
        if cursor <= min(dates):
            break
    return sorted(cutoffs)


def build_simulation_pool(
    orders: Sequence[Mapping[str, Any]],
    *,
    cutoff: date,
    pool_size: int,
    seed: int,
    unit_prices: Mapping[str, float] | None = None,
) -> list[SimCandidate]:
    import random

    opportunities = retailer_opportunities(
        build_patterns(orders, as_of=cutoff),
        unit_prices=unit_prices or {},
    )
    observations = [
        (row.expected_order_value_rm, row.relative_uncertainty)
        for row in opportunities
        if row.expected_order_value_rm > 0
    ]
    if not observations:
        return []
    rng = random.Random(seed)
    pool: list[SimCandidate] = []
    for index in range(pool_size):
        expected_value, relative_uncertainty = observations[
            rng.randrange(len(observations))
        ]
        pool.append(
            SimCandidate(
                retailer_id="SIM" + str(index).zfill(3),
                expected_value_rm=round(expected_value, 4),
                forecast_relative_uncertainty=round(relative_uncertainty, 6),
                latitude=kuching_coordinates(index, pool_size)[0],
                longitude=kuching_coordinates(index, pool_size)[1],
                service_minutes=float(rng.choice([15, 20, 25, 30])),
                days_since_last_visit=float(rng.choice([3, 10, 21, 45, 70])),
                observed_periods=8,
            )
        )
    return pool


def _median(values: Sequence[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return round(ordered[middle], 4)
    return round((ordered[middle - 1] + ordered[middle]) / 2, 4)


def _fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return format(value, ".4f")
    return str(value)


def _fmt_pct(value: Any, *, signed: bool = False) -> str:
    if not isinstance(value, (int, float)):
        return "n/a"
    return format(value * 100, "+.1f" if signed else ".1f") + "%"


def run_policy_simulation(
    orders: Sequence[Mapping[str, Any]],
    snapshot: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    cutoff: date,
    seed: int,
    replicates: int,
    target_size: int,
    pool_size: int,
    exploration_band: float,
    unit_prices: Mapping[str, float] | None = None,
) -> dict[str, Any]:
    ratios = realised_ratio_catalogue_from_snapshot(snapshot)
    pool = build_simulation_pool(
        orders,
        cutoff=cutoff,
        pool_size=pool_size,
        seed=seed,
        unit_prices=unit_prices,
    )
    if not pool:
        return {}
    simulation = simulate_policies(
        pool,
        target_size=min(target_size, len(pool)),
        seed=seed,
        replicates=replicates,
        realised_ratios=ratios,
        exploration_band=exploration_band,
    ).to_dict()
    simulation["provenance"] = {
        **(simulation.get("provenance") or {}),
        "cutoff": cutoff.isoformat(),
        "expectedValueSource": (
            EXPECTED_ORDER_VALUE_VERSION
            + " computed from the forecast "
            "representation at the cutoff (ai_core.opportunity), sampled over "
            "the real retailers in the frozen dataset"
        ),
        "realisedRatioNormaliser": (
            "each pair's own previous observed order value; this is the "
            "simulation realisation model, not the system definition of expected "
            "order value, and is labelled simulated"
        ),
        "geographySource": (
            "deterministic lattice over a compact urban area near Kuching, "
            "spread across roughly 4.5 km; not real outlet coordinates"
        ),
    }
    return simulation


@dataclass
class ClosedLoopEvaluation:
    protocol_version: str
    seed: int
    truth_window_days: int
    rolling_origins: int
    simulation_replicates: int
    simulation_target_size: int
    dataset_provenance: dict[str, Any] = field(default_factory=dict)
    payload: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "protocolVersion": self.protocol_version,
            "seed": self.seed,
            "truthWindowDays": self.truth_window_days,
            "rollingOrigins": self.rolling_origins,
            "simulationReplicates": self.simulation_replicates,
            "simulationTargetSize": self.simulation_target_size,
            "modelsVersion": FORECAST_MODELS_VERSION,
            "forecastContractVersion": FORECAST_CONTRACT_VERSION,
            "expectedOrderValueVersion": EXPECTED_ORDER_VALUE_VERSION,
            "policyVersion": POLICY_VERSION,
            "dataset": dict(self.dataset_provenance),
            **self.payload,
        }


def run_evaluation(
    snapshot: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    provenance: Mapping[str, Any] | None = None,
    seed: int = DEFAULT_SEED,
    truth_window_days: int = DEFAULT_TRUTH_WINDOW_DAYS,
    rolling_origins: int = DEFAULT_ROLLING_ORIGINS,
    simulation_replicates: int = DEFAULT_SIM_REPLICATES,
    simulation_target_size: int = DEFAULT_SIM_TARGET_SIZE,
    simulation_pool_size: int = DEFAULT_SIM_POOL_SIZE,
    cutoff_count: int = DEFAULT_CUTOFF_COUNT,
    bootstrap_draws: int = DEFAULT_BOOTSTRAP_DRAWS,
    cutoffs: Sequence[date] | None = None,
) -> ClosedLoopEvaluation:
    snapshot, synthetic_exclusion = exclude_synthetic_history(snapshot)
    orders = usable_orders(snapshot)
    payload: dict[str, Any] = {"syntheticExclusion": synthetic_exclusion}

    grains: dict[str, Any] = {}
    for grain in ("barcode", "outlet_barcode"):
        series = build_weekly_series(orders, grain=grain)
        report = run_model_selection_backtest(series, max_origins=rolling_origins)
        cohort = report["nonDemo"]
        pairs, dropped = aligned_series_pairs(cohort, PREDICTOR_NAMES)
        intervals = {
            name: interval.to_dict()
            for name, interval in ratio_metric_intervals(
                pairs, seed=seed, draws=bootstrap_draws
            ).items()
        }
        differences = {
            reference: paired_ratio_differences(
                pairs, reference=reference, seed=seed, draws=bootstrap_draws
            )
            for reference in ("naiveLast", "theta")
        }
        grains[grain] = {
            "profile": profile_series(series),
            "bootstrap": {
                "seed": seed,
                "draws": bootstrap_draws,
                "unit": "series resampled with replacement",
                "intervals": intervals,
                "pairedAgainstReference": differences,
                "seriesWithUsableScale": len(pairs.get("naiveLast", [])),
                "seriesWithoutUsableScale": dropped,
            },
            "report": {
                cohort: cohort_report.to_dict()
                for cohort, cohort_report in report.items()
            },
        }
    payload["L1ForecastValue"] = {
        "evidence": "real",
        "metric": "MASE over rolling one-step origins, baselines on identical points",
        "maseScale": MASE_SCALE_DEFINITION,
        "corrections": {
            "demandClassification": "per forecast origin, training window only",
            "cvSquaredEstimator": CV_ESTIMATOR,
            "maseScale": (
                "each scored point is divided by its own origin's training-window "
                "seasonal-naive mean absolute error; the superseded report divided "
                "by a scale computed from the scored targets themselves"
            ),
        },
        "grains": grains,
    }

    resolved_cutoffs = (
        list(cutoffs)
        if cutoffs
        else candidate_cutoffs(
            orders, count=cutoff_count, truth_window_days=truth_window_days
        )
    )
    unit_prices = {
        _text(row.get("productId")): float(row.get("unitPrice") or 0.0)
        for row in snapshot.get("products", [])
        if _text(row.get("productId"))
    }
    signal_reports: list[dict[str, Any]] = []
    for cutoff in resolved_cutoffs:
        signal_reports.append(
            evaluate_signals_at_cutoff(
                orders=orders,
                patterns=build_patterns(orders, as_of=cutoff),
                memory=[],
                unit_prices=unit_prices,
                cutoff=cutoff,
                truth_window_days=truth_window_days,
                run_id="eval",
            )
        )
    payload["L2SignalQuality"] = {
        "evidence": "real",
        "cutoffs": [row["cutoff"] for row in signal_reports],
        "results": signal_reports,
    }

    latest_cutoff = resolved_cutoffs[-1] if resolved_cutoffs else None
    if latest_cutoff is not None:
        ratios = realised_ratio_catalogue_from_snapshot(snapshot)
        simulation = run_policy_simulation(
            orders,
            snapshot,
            cutoff=latest_cutoff,
            seed=seed,
            replicates=simulation_replicates,
            target_size=simulation_target_size,
            pool_size=simulation_pool_size,
            exploration_band=EXPLORATION_SCORE_BAND,
            unit_prices=unit_prices,
        )
        sensitivity: list[dict[str, Any]] = []
        for multiplier in (2.0, 4.0, 8.0):
            band = EXPLORATION_SCORE_BAND * multiplier
            run = run_policy_simulation(
                orders,
                snapshot,
                cutoff=latest_cutoff,
                seed=seed,
                replicates=simulation_replicates,
                target_size=simulation_target_size,
                pool_size=simulation_pool_size,
                exploration_band=band,
                unit_prices=unit_prices,
            )
            if not run:
                continue
            sensitivity.append(
                {
                    "explorationScoreBand": band,
                    "meanRealisedPerDay": {
                        policy: metrics.get("meanRealisedPerDay")
                        for policy, metrics in (run.get("policies") or {}).items()
                    },
                    "meanHindsightBenchmarkGapPerDay": {
                        policy: metrics.get("meanHindsightBenchmarkGapPerDay")
                        for policy, metrics in (run.get("policies") or {}).items()
                    },
                    "distinctRetailersSelected": {
                        policy: metrics.get("distinctRetailersSelected")
                        for policy, metrics in (run.get("policies") or {}).items()
                    },
                }
            )
        if not simulation:
            payload["L3DecisionQuality"] = {
                "evidence": "not available",
                "note": (
                    "The policy simulation needs a positive expected order value "
                    "per candidate. No retailer produced one from this snapshot's "
                    "forecast representation and product catalogue, so no "
                    "decision-quality figure is reported."
                ),
                "realisedRatioCatalogueSize": len(ratios),
                "realisedRatioMedian": _median(ratios),
                "simulation": None,
            }
            payload["L5PolicyComparison"] = {
                "evidence": "not available",
                "policies": {},
            }
        else:
            payload["L3DecisionQuality"] = {
                "evidence": "real inputs, simulated realisations",
                "objective": "expected order-value opportunity per route-day (RM/day)",
                "note": (
                    "The gap reported here is between the hindsight benchmark and "
                    "each policy, in RM per route-day. The benchmark is at least "
                    "the best selection any compared policy made on the same "
                    "realisation draw, so the gap is never negative; the method "
                    "behind it is reported in the simulation provenance and is "
                    "only labelled exact when every subset of the enumerable "
                    "universe was enumerated. Realised outcomes are a seeded "
                    "bootstrap of the observed realised-to-baseline ratio, so the "
                    "comparison between policies is meaningful while the absolute "
                    "level is not a field measurement."
                ),
                "realisedRatioCatalogueSize": len(ratios),
                "realisedRatioMedian": _median(ratios),
                "simulation": simulation,
                "pairedPolicyDifferences": {
                    "note": (
                        "Each policy is resampled on the identical replicate, so "
                        "the difference excludes the between-replicate spread the "
                        "two policies share. A difference whose interval contains "
                        "zero is not a finding."
                    ),
                    "vsPriorityOnly": mean_difference_intervals(
                        {
                            policy: [
                                row["realisedPerDay"]
                                for row in (metrics.get("outcomes") or [])
                            ]
                            for policy, metrics in (
                                simulation.get("policies") or {}
                            ).items()
                        },
                        reference="priorityOnly",
                        seed=seed,
                        draws=bootstrap_draws,
                    ),
                    "vsRoundRobin": mean_difference_intervals(
                        {
                            policy: [
                                row["realisedPerDay"]
                                for row in (metrics.get("outcomes") or [])
                            ]
                            for policy, metrics in (
                                simulation.get("policies") or {}
                            ).items()
                        },
                        reference="roundRobin",
                        seed=seed,
                        draws=bootstrap_draws,
                    ),
                },
                "explorationBandSensitivity": sensitivity,
            }
            payload["L5PolicyComparison"] = {
                "evidence": "simulated",
                "policies": simulation["policies"],
            }
    else:
        payload["L3DecisionQuality"] = None
        payload["L5PolicyComparison"] = None

    outcomes = snapshot.get("conversation_outcomes", []) or []
    briefs = snapshot.get("visit_briefs", []) or []
    payload["L4FieldUsefulness"] = {
        "evidence": "real" if (outcomes or briefs) else "not yet available",
        "briefsAvailable": len(briefs),
        "outcomesAvailable": len(outcomes),
        "note": (
            "Field-usefulness metrics (recommendations shown, dismissals, "
            "repeat-signal rate, time on brief) need outcome captures from "
            "routes that were actually worked. This snapshot is the supplier "
            "order feed only, so they are reported as not yet available rather "
            "than estimated."
        ),
        "metrics": {
            "recommendationsShown": None,
            "dismissals": None,
            "repeatSignalRate": None,
            "structuredOutcomeReasons": None,
            "timeOnBriefSeconds": None,
            "usefulOutcomesCaptured": None,
        },
    }

    return ClosedLoopEvaluation(
        protocol_version=PROTOCOL_VERSION,
        seed=seed,
        truth_window_days=truth_window_days,
        rolling_origins=rolling_origins,
        simulation_replicates=simulation_replicates,
        simulation_target_size=simulation_target_size,
        dataset_provenance=dict(provenance or {}),
        payload=payload,
    )


def render_markdown(result: ClosedLoopEvaluation) -> str:
    payload = result.payload
    lines: list[str] = []
    lines.append("# Closed-loop evaluation report")
    lines.append("")
    lines.append("- Protocol: " + result.protocol_version)
    lines.append("- Seed: " + str(result.seed))
    lines.append("- Truth window (days): " + str(result.truth_window_days))
    lines.append("- Rolling origins: " + str(result.rolling_origins))
    lines.append("- Models version: " + FORECAST_MODELS_VERSION)
    lines.append("- Forecast contract version: " + FORECAST_CONTRACT_VERSION)
    lines.append("- Expected order value version: " + EXPECTED_ORDER_VALUE_VERSION)
    lines.append("- Policy version: " + POLICY_VERSION)
    dataset = result.dataset_provenance or {}
    if dataset:
        lines.append(
            "- Dataset: "
            + str(dataset.get("datasetName", "unknown"))
            + " v"
            + str(dataset.get("datasetVersion", "?"))
            + " ("
            + str(dataset.get("lineCount", "?"))
            + " lines, "
            + str(dataset.get("outletCount", "?"))
            + " outlets, "
            + str(dataset.get("barcodeCount", "?"))
            + " barcodes, "
            + str((dataset.get("dateRange") or {}).get("start", "?"))
            + " to "
            + str((dataset.get("dateRange") or {}).get("end", "?"))
            + ")"
        )
    lines.append("")

    forecast = payload.get("L1ForecastValue") or {}
    lines.append("## L1 - forecast value (real data)")
    lines.append("")
    for grain, block in (forecast.get("grains") or {}).items():
        profile = block.get("profile") or {}
        lines.append(
            "### Grain: "
            + grain
            + " ("
            + str(profile.get("seriesCount"))
            + " series, mean non-zero rate "
            + _fmt(profile.get("meanNonZeroRate"))
            + ")"
        )
        lines.append("")
        lines.append("Demand classes: " + str(profile.get("classificationCounts")))
        lines.append("")
        for cohort in ("nonDemo", "demo"):
            report = (block.get("report") or {}).get(cohort) or {}
            if not report.get("seriesCount"):
                continue
            aggregate = report.get("aggregate") or {}
            lines.append(
                "**"
                + cohort
                + "** - "
                + str(report.get("seriesCount"))
                + " scored series, "
                + str(report.get("insufficientHistoryCount"))
                + " with insufficient history"
            )
            lines.append("")
            lines.append("| Predictor | n | MASE | WAPE | Bias | MAE | RMSE |")
            lines.append("|---|---|---|---|---|---|---|")
            for name, metrics in (aggregate.get("byPredictor") or {}).items():
                lines.append(
                    "| "
                    + name
                    + " | "
                    + str(metrics.get("n"))
                    + " | "
                    + _fmt(metrics.get("mase"))
                    + " | "
                    + _fmt_pct(metrics.get("wape"))
                    + " | "
                    + _fmt_pct(metrics.get("bias"), signed=True)
                    + " | "
                    + _fmt(metrics.get("mae"))
                    + " | "
                    + _fmt(metrics.get("rmse"))
                    + " |"
                )
            lines.append("")
            lines.append("MASE by demand class:")
            lines.append("")
            lines.append(
                "| Class | Series | Points | selectedRule | naiveLast | "
                "croston | tsb |"
            )
            lines.append("|---|---|---|---|---|---|---|")
            for name, metrics in (aggregate.get("byClassification") or {}).items():
                lines.append(
                    "| "
                    + name
                    + " | "
                    + str(metrics.get("seriesCount"))
                    + " | "
                    + str(metrics.get("scoredPoints"))
                    + " | "
                    + _fmt(metrics.get("selectedRule"))
                    + " | "
                    + _fmt(metrics.get("naiveLast"))
                    + " | "
                    + _fmt(metrics.get("croston"))
                    + " | "
                    + _fmt(metrics.get("tsb"))
                    + " |"
                )
            lines.append("")
            lines.append(
                "80% empirical interval coverage: "
                + _fmt(aggregate.get("intervalCoverage"))
                + " (mean width "
                + _fmt(aggregate.get("intervalMeanWidth"))
                + ")"
            )
            lines.append("")
            lines.append(
                "MASE scale: "
                + str(aggregate.get("maseScale"))
                + " ("
                + str(aggregate.get("scoredPoints"))
                + " scored points, "
                + str(aggregate.get("pointsWithZeroScale"))
                + " with no usable scale and therefore excluded)"
            )
            lines.append("")
            lines.append(
                "Demand class at each scored origin: "
                + str(aggregate.get("originClassCounts"))
            )
            lines.append("")
        bootstrap = block.get("bootstrap") or {}
        if bootstrap:
            lines.append(
                "Paired bootstrap over "
                + str(bootstrap.get("seriesWithUsableScale"))
                + " series, "
                + str(bootstrap.get("draws"))
                + " draws, seed "
                + str(bootstrap.get("seed"))
                + " ("
                + str(bootstrap.get("unit"))
                + "):"
            )
            lines.append("")
            lines.append("| Predictor | MASE | 95% interval | vs naive | vs theta |")
            lines.append("|---|---|---|---|---|")
            intervals = bootstrap.get("intervals") or {}
            paired = bootstrap.get("pairedAgainstReference") or {}
            for name, row in intervals.items():
                vs_naive = (paired.get("naiveLast") or {}).get(name) or {}
                vs_theta = (paired.get("theta") or {}).get(name) or {}
                lines.append(
                    "| "
                    + name
                    + " | "
                    + _fmt(row.get("value"))
                    + " | ["
                    + _fmt(row.get("lower"))
                    + ", "
                    + _fmt(row.get("upper"))
                    + "] | "
                    + (
                        "["
                        + _fmt(vs_naive.get("lower"))
                        + ", "
                        + _fmt(vs_naive.get("upper"))
                        + "]"
                        if vs_naive
                        else "reference"
                    )
                    + " | "
                    + (
                        "["
                        + _fmt(vs_theta.get("lower"))
                        + ", "
                        + _fmt(vs_theta.get("upper"))
                        + "]"
                        if vs_theta
                        else "reference"
                    )
                    + " |"
                )
            lines.append("")

    lines.append("## L2 - signal quality (real data)")
    lines.append("")
    signals = payload.get("L2SignalQuality") or {}
    for row in signals.get("results") or []:
        lines.append(
            "### Cutoff "
            + str(row.get("cutoff"))
            + " (truth window "
            + str(row.get("truthWindowDays"))
            + " days, "
            + str(row.get("eligiblePairs"))
            + " eligible pairs, "
            + str(row.get("truthPairs"))
            + " with a real order in the window)"
        )
        lines.append("")
        lines.append(
            "| Family | Fired | Precision | Recall | F1 | precision@3 | "
            "PR-AUC | ECE | Median lead (days) |"
        )
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for family, report in (row.get("families") or {}).items():
            classification = report.get("classification") or {}
            calibration = report.get("calibration") or {}
            lead = report.get("leadTime") or {}
            lines.append(
                "| "
                + family
                + " | "
                + str(report.get("fired"))
                + " | "
                + _fmt(classification.get("precision"))
                + " | "
                + _fmt(classification.get("recall"))
                + " | "
                + _fmt(classification.get("f1"))
                + " | "
                + _fmt(report.get("precisionAtK"))
                + " | "
                + _fmt(report.get("averagePrecision"))
                + " | "
                + _fmt(calibration.get("expectedCalibrationError"))
                + " | "
                + _fmt(lead.get("medianDays"))
                + " |"
            )
        lines.append("")

    lines.append("## L3 - decision quality (real inputs, simulated realisations)")
    lines.append("")
    decision = payload.get("L3DecisionQuality")
    if not decision:
        lines.append("_Not run: no usable cutoff in this dataset._")
        lines.append("")
    else:
        lines.append(str(decision.get("note")))
        lines.append("")
        lines.append(
            "Realised-to-expected ratio catalogue: "
            + str(decision.get("realisedRatioCatalogueSize"))
            + " observations, median "
            + _fmt(decision.get("realisedRatioMedian"))
        )
        lines.append("")
        simulation = decision.get("simulation") or {}
        provenance = simulation.get("provenance") or {}
        lines.append(
            "Hindsight benchmark: "
            + str(provenance.get("benchmarkGuarantee"))
            + ". Exact: "
            + str(provenance.get("benchmarkIsExact"))
            + "; comparisons in which a policy reached the benchmark: "
            + str(provenance.get("benchmarkBeatenByComparedPolicies"))
            + "."
        )
        lines.append("")
        lines.append(
            "| Policy | Mean RM/day | Mean hindsight benchmark gap RM/day | "
            "Retailers | Travel min | Starved retailers |"
        )
        lines.append("|---|---|---|---|---|---|")
        for name, metrics in (simulation.get("policies") or {}).items():
            lines.append(
                "| "
                + name
                + " | "
                + _fmt(metrics.get("meanRealisedPerDay"))
                + " | "
                + _fmt(metrics.get("meanHindsightBenchmarkGapPerDay"))
                + " | "
                + _fmt(metrics.get("meanRetailersSelected"))
                + " | "
                + _fmt(metrics.get("meanTravelMinutes"))
                + " | "
                + str(metrics.get("starvedRetailersSelected"))
                + " |"
            )
        lines.append("")
        paired = decision.get("pairedPolicyDifferences") or {}
        for reference in ("vsPriorityOnly", "vsRoundRobin"):
            comparisons = paired.get(reference) or {}
            if not comparisons:
                continue
            lines.append(
                "Paired RM/day differences against "
                + reference[2:]
                + " (2,000 replicate-level bootstrap draws):"
            )
            lines.append("")
            lines.append("| Policy | Difference | 95% interval | Excludes zero |")
            lines.append("|---|---|---|---|")
            for name, row in comparisons.items():
                lines.append(
                    "| "
                    + name
                    + " | "
                    + _fmt(row.get("value"))
                    + " | ["
                    + _fmt(row.get("lower"))
                    + ", "
                    + _fmt(row.get("upper"))
                    + "] | "
                    + ("yes" if row.get("excludesZero") else "no")
                    + " |"
                )
            lines.append("")

    lines.append("## L4 - field usefulness")
    lines.append("")
    field_block = payload.get("L4FieldUsefulness") or {}
    lines.append("Evidence: " + str(field_block.get("evidence")))
    lines.append("")
    lines.append(str(field_block.get("note")))
    lines.append("")

    lines.append("## Evidence labels")
    lines.append("")
    lines.append("- real: measured on the frozen snapshot of ingested supplier orders.")
    lines.append(
        "- real inputs, simulated realisations: the RM magnitudes come from real "
        "orders, the outcome draws are a seeded bootstrap, the geography is "
        "synthetic."
    )
    lines.append(
        "- not yet available: needs field captures this snapshot does not contain."
    )
    lines.append("")
    return "\n".join(lines) + "\n"


def write_reports(
    result: ClosedLoopEvaluation, output_dir: Path, stem: str
) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / (stem + ".json")
    md_path = output_dir / (stem + ".md")
    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(result.to_dict(), handle, indent=2, sort_keys=True, default=str)
    with md_path.open("w", encoding="utf-8") as handle:
        handle.write(render_markdown(result))
    return json_path, md_path


def load_snapshot(path: Path) -> dict[str, list[dict[str, Any]]]:
    with path.open("r", encoding="utf-8") as handle:
        raw = json.load(handle)
    if not isinstance(raw, Mapping):
        raise ValueError("snapshot must be a JSON object keyed by collection")
    return {str(key): list(value or []) for key, value in raw.items()}


def load_provenance(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            loaded = json.load(handle)
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m forecasting.evaluation.closed_loop_runner",
        description=(
            "Run the frozen closed-loop evaluation over a local snapshot. "
            "Read-only: writes reports to a local directory."
        ),
    )
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--provenance", default="")
    parser.add_argument("--output-dir", default="eval_reports")
    parser.add_argument("--stem", default="closed_loop")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument(
        "--truth-window-days", type=int, default=DEFAULT_TRUTH_WINDOW_DAYS
    )
    parser.add_argument("--rolling-origins", type=int, default=DEFAULT_ROLLING_ORIGINS)
    parser.add_argument("--sim-replicates", type=int, default=DEFAULT_SIM_REPLICATES)
    parser.add_argument(
        "--sim-target-size", type=int, default=DEFAULT_SIM_TARGET_SIZE
    )
    parser.add_argument("--sim-pool-size", type=int, default=DEFAULT_SIM_POOL_SIZE)
    parser.add_argument("--cutoff-count", type=int, default=DEFAULT_CUTOFF_COUNT)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    snapshot_path = Path(args.snapshot)
    if not snapshot_path.is_file():
        print("Snapshot not found: " + str(snapshot_path), file=sys.stderr)
        return 2
    snapshot = load_snapshot(snapshot_path)
    provenance_path = (
        Path(args.provenance)
        if args.provenance
        else snapshot_path.with_name(snapshot_path.stem + "_provenance.json")
    )
    result = run_evaluation(
        snapshot,
        provenance=load_provenance(provenance_path),
        seed=args.seed,
        truth_window_days=args.truth_window_days,
        rolling_origins=args.rolling_origins,
        simulation_replicates=args.sim_replicates,
        simulation_target_size=args.sim_target_size,
        simulation_pool_size=args.sim_pool_size,
        cutoff_count=args.cutoff_count,
    )
    json_path, md_path = write_reports(result, Path(args.output_dir), args.stem)
    print("Wrote " + str(json_path))
    print("Wrote " + str(md_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

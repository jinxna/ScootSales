from __future__ import annotations

import argparse
import json
import math
import random
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from forecasting.ai_core.calendar import (
    DEFAULT_HISTORY_WEEKS,
    HistoryWindow,
    as_kuching_date,
    completed_week_starts,
    week_start,
)
from forecasting.ai_service.normalization import (
    is_demand_order,
    order_moment,
    order_retailer_id,
)
from forecasting.ai_service.scorecard import (
    REBUILD_BASIS,
    SCORECARD_TOP_COUNT,
    SCORECARD_WEEKS,
    WeekReplay,
    data_label,
    period_actuals,
    ranked_retailer_ids,
    replay_week,
)


PROTOCOL = "ranking-backtest/1.0.0"
HORIZON_WEEKS = (1, 4)
SIMULATED_TABLE = "simulated scenario"
REAL_TABLE = "real orders (small sample)"
RANKING_POLICY = "weekly ranking"
RANDOM_POLICY = "random"
RECENT_POLICY = "most recent first"
ORDER_COUNT_POLICY = "order count"
DEFAULT_SEED = 20261118
RANDOM_DRAWS = 200
BOOTSTRAP_DRAWS = 1000
_Z_95 = 1.959963984540054
ORDER_COUNT_NOTE = (
    "The order-count baseline is expected to match the ranking when every shop "
    "buys the same goods at the same prices, because expected order value then "
    "follows how often a shop orders."
)


def wilson_interval(hits: float, trials: int) -> list[float] | None:
    if trials <= 0:
        return None
    rate = hits / trials
    denominator = 1 + _Z_95**2 / trials
    centre = (rate + _Z_95**2 / (2 * trials)) / denominator
    half = (
        _Z_95
        * math.sqrt(rate * (1 - rate) / trials + _Z_95**2 / (4 * trials**2))
        / denominator
    )
    return [round(max(0.0, centre - half), 4), round(min(1.0, centre + half), 4)]


def _percentile_interval(values: Sequence[float]) -> list[float] | None:
    if not values:
        return None
    ordered = sorted(values)
    low = ordered[int(0.025 * (len(ordered) - 1))]
    high = ordered[int(math.ceil(0.975 * (len(ordered) - 1)))]
    return [round(low, 4), round(high, 4)]


def _ratio(part: float, whole: float) -> float | None:
    return round(part / whole, 4) if whole > 0 else None


def _history_orders(replay: WeekReplay) -> tuple[dict[str, date], dict[str, int]]:
    latest: dict[str, date] = {}
    counts: dict[str, int] = {}
    for order in replay.orders:
        retailer_id = order_retailer_id(order)
        moment = order_moment(order)
        if not retailer_id or moment is None or not is_demand_order(order):
            continue
        local_date = as_kuching_date(moment)
        counts[retailer_id] = counts.get(retailer_id, 0) + 1
        if retailer_id not in latest or local_date > latest[retailer_id]:
            latest[retailer_id] = local_date
    return latest, counts


def _scope_periods(
    replay: WeekReplay,
    actuals: Mapping[tuple[str, str], tuple[float, float]],
    top_count: int,
) -> list[dict[str, Any]]:
    value_by_retailer: dict[str, float] = {}
    for (retailer_id, _), (_, revenue) in actuals.items():
        value_by_retailer[retailer_id] = (
            value_by_retailer.get(retailer_id, 0.0) + revenue
        )
    latest, counts = _history_orders(replay)
    periods: list[dict[str, Any]] = []
    for ranking in replay.result.priority_rankings:
        ranked = ranked_retailer_ids(ranking)
        if len(ranked) <= top_count:
            continue
        shops = sorted(ranked)
        periods.append(
            {
                "shops": shops,
                "ordered": {shop for shop in shops if shop in value_by_retailer},
                "values": {shop: value_by_retailer.get(shop, 0.0) for shop in shops},
                "orders": {
                    RANKING_POLICY: ranked,
                    RECENT_POLICY: sorted(
                        shops,
                        key=lambda shop: (
                            -latest[shop].toordinal() if shop in latest else 0,
                            shop,
                        ),
                    ),
                    ORDER_COUNT_POLICY: sorted(
                        shops, key=lambda shop: (-counts.get(shop, 0), shop)
                    ),
                },
            }
        )
    return periods


def _picked_totals(
    periods: Sequence[Mapping[str, Any]],
    picks: Sequence[Sequence[str]],
) -> tuple[int, int, float, float]:
    hits = trials = 0
    top_value = total_value = 0.0
    for period, picked in zip(periods, picks):
        hits += sum(shop in period["ordered"] for shop in picked)
        trials += len(picked)
        top_value += sum(period["values"][shop] for shop in picked)
        total_value += sum(period["values"].values())
    return hits, trials, top_value, total_value


def _fixed_policy_row(
    policy: str,
    horizon: int,
    periods: Sequence[Mapping[str, Any]],
    top_count: int,
    rng: random.Random,
) -> dict[str, Any]:
    picks = [period["orders"][policy][:top_count] for period in periods]
    hits, trials, top_value, total_value = _picked_totals(periods, picks)
    shares: list[float] = []
    if periods and total_value > 0:
        indexes = range(len(periods))
        for _ in range(BOOTSTRAP_DRAWS):
            sample = [rng.choice(indexes) for _ in indexes]
            _, _, sample_top, sample_total = _picked_totals(
                [periods[index] for index in sample],
                [picks[index] for index in sample],
            )
            if sample_total > 0:
                shares.append(sample_top / sample_total)
    return {
        "policy": policy,
        "horizonWeeks": horizon,
        "scopePeriods": len(periods),
        "hitCount": hits,
        "trialCount": trials,
        "hitRate": _ratio(hits, trials),
        "hitRateInterval95": wilson_interval(hits, trials),
        "hitRateIntervalMethod": "wilson",
        "topValueRm": round(top_value, 2),
        "totalValueRm": round(total_value, 2),
        "valueShare": _ratio(top_value, total_value),
        "valueShareInterval95": _percentile_interval(shares),
        "valueShareIntervalMethod": f"bootstrap over scope periods, {BOOTSTRAP_DRAWS} draws",
    }


def _random_policy_row(
    horizon: int,
    periods: Sequence[Mapping[str, Any]],
    top_count: int,
    rng: random.Random,
) -> dict[str, Any]:
    rates: list[float] = []
    shares: list[float] = []
    hit_total = 0
    value_total = 0.0
    trials = 0
    total_value = 0.0
    for _ in range(RANDOM_DRAWS if periods else 0):
        picks = [rng.sample(period["shops"], top_count) for period in periods]
        hits, trials, top_value, total_value = _picked_totals(periods, picks)
        hit_total += hits
        value_total += top_value
        rates.append(hits / trials)
        if total_value > 0:
            shares.append(top_value / total_value)
    mean_hits = hit_total / RANDOM_DRAWS if periods else 0.0
    mean_value = value_total / RANDOM_DRAWS if periods else 0.0
    method = f"percentiles of {RANDOM_DRAWS} random draws"
    return {
        "policy": RANDOM_POLICY,
        "horizonWeeks": horizon,
        "scopePeriods": len(periods),
        "hitCount": round(mean_hits, 2),
        "trialCount": trials,
        "hitRate": _ratio(mean_hits, trials),
        "hitRateInterval95": _percentile_interval(rates),
        "hitRateIntervalMethod": method,
        "topValueRm": round(mean_value, 2),
        "totalValueRm": round(total_value, 2),
        "valueShare": _ratio(mean_value, total_value),
        "valueShareInterval95": _percentile_interval(shares),
        "valueShareIntervalMethod": method,
    }


def backtest_table(
    label: str,
    *,
    orders: Iterable[Mapping[str, Any]],
    products: Iterable[Mapping[str, Any]],
    retailers: Iterable[Mapping[str, Any]],
    users: Iterable[Mapping[str, Any]],
    as_of: date,
    window: HistoryWindow,
    weeks: int = SCORECARD_WEEKS,
    top_count: int = SCORECARD_TOP_COUNT,
    seed: int = DEFAULT_SEED,
) -> dict[str, Any]:
    orders = tuple(orders)
    products = tuple(products)
    retailers = tuple(retailers)
    users = tuple(users)
    week_starts = completed_week_starts(as_of, weeks=weeks)
    end = week_start(as_of)
    rng = random.Random(seed)
    replays: dict[date, WeekReplay] = {}
    rows: list[dict[str, Any]] = []
    for horizon in HORIZON_WEEKS:
        periods: list[dict[str, Any]] = []
        for cutoff in week_starts[::horizon]:
            if cutoff + timedelta(weeks=horizon) > end:
                continue
            if cutoff not in replays:
                replays[cutoff] = replay_week(
                    orders=orders,
                    products=products,
                    retailers=retailers,
                    users=users,
                    cutoff=cutoff,
                    window=window,
                )
            periods.extend(
                _scope_periods(
                    replays[cutoff],
                    period_actuals(
                        orders=orders,
                        products=products,
                        retailers=retailers,
                        users=users,
                        start=cutoff,
                        weeks=horizon,
                    ),
                    top_count,
                )
            )
        for policy in (RANKING_POLICY, RECENT_POLICY, ORDER_COUNT_POLICY):
            rows.append(_fixed_policy_row(policy, horizon, periods, top_count, rng))
        rows.append(_random_policy_row(horizon, periods, top_count, rng))
    return {
        "label": label,
        "protocol": PROTOCOL,
        "dataLabel": data_label(orders),
        "basis": REBUILD_BASIS,
        "asOf": as_of.isoformat(),
        "firstWeekStart": week_starts[0].isoformat(),
        "lastWeekStart": week_starts[-1].isoformat(),
        "weeks": weeks,
        "historyWeeks": window.weeks,
        "topCount": top_count,
        "seed": seed,
        "orderCountNote": ORDER_COUNT_NOTE,
        "rows": rows,
    }


def run_backtest(
    *,
    orders: Iterable[Mapping[str, Any]],
    products: Iterable[Mapping[str, Any]],
    retailers: Iterable[Mapping[str, Any]],
    users: Iterable[Mapping[str, Any]],
    as_of: date,
    window: HistoryWindow,
    weeks: int = SCORECARD_WEEKS,
    seed: int = DEFAULT_SEED,
) -> dict[str, Any]:
    orders = tuple(orders)
    products = tuple(products)
    retailers = tuple(retailers)
    users = tuple(users)
    simulated = [
        order for order in orders if str(order.get("simulationBatchId") or "").strip()
    ]
    real = [
        order
        for order in orders
        if not str(order.get("simulationBatchId") or "").strip()
    ]
    return {
        "protocol": PROTOCOL,
        "tables": [
            backtest_table(
                label,
                orders=table_orders,
                products=products,
                retailers=retailers,
                users=users,
                as_of=as_of,
                window=window,
                weeks=weeks,
                seed=seed,
            )
            for label, table_orders in (
                (SIMULATED_TABLE, simulated),
                (REAL_TABLE, real),
            )
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Weekly ranking backtest")
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--as-of", type=date.fromisoformat, required=True)
    parser.add_argument("--history-weeks", type=int, default=DEFAULT_HISTORY_WEEKS)
    parser.add_argument("--weeks", type=int, default=SCORECARD_WEEKS)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    snapshot = json.loads(args.snapshot.read_text(encoding="utf-8"))
    report = run_backtest(
        orders=snapshot["orders"],
        products=snapshot["products"],
        retailers=snapshot["retailers"],
        users=snapshot["users"],
        as_of=args.as_of,
        window=HistoryWindow(
            weeks=args.history_weeks,
            requested=args.history_weeks,
            source="backtest",
        ),
        weeks=args.weeks,
        seed=args.seed,
    )
    args.out.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

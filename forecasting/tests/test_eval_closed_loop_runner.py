from __future__ import annotations

from datetime import date, timedelta

from forecasting.evaluation.closed_loop_runner import (
    build_patterns,
    build_simulation_pool,
    build_weekly_series,
    candidate_cutoffs,
    profile_series,
    run_evaluation,
    usable_orders,
)


def _orders() -> list[dict]:
    rows = []
    start = date(2026, 1, 11)
    for index in range(8):
        rows.append(
            {
                "docId": "ord" + str(index),
                "retailerId": "OUT1",
                "retailerName": "Outlet One",
                "status": "submitted",
                "submittedAt": (start + timedelta(weeks=index)).isoformat(),
                "items": [
                    {
                        "productId": "P1",
                        "productName": "Product One",
                        "qty": 10 + index,
                        "price": 5.0,
                    }
                ],
            }
        )
    return rows


def test_usable_orders_drops_undated_and_excluded() -> None:
    snapshot = {
        "orders": [
            {
                "retailerId": "R1",
                "status": "submitted",
                "submittedAt": "2026-01-05T00:00:00Z",
                "items": [],
            },
            {"retailerId": "R2", "status": "cancelled", "submittedAt": "2026-01-05"},
            {"retailerId": "R3", "status": "submitted"},
            {"status": "submitted", "submittedAt": "2026-01-05"},
        ]
    }
    rows = usable_orders(snapshot)
    assert len(rows) == 1
    assert rows[0]["retailerId"] == "R1"


def test_weekly_series_fills_gaps_with_zero() -> None:
    series = build_weekly_series(_orders(), grain="barcode")
    assert len(series) == 1
    assert series[0]["key"] == "P1"
    assert series[0]["values"] == [float(10 + index) for index in range(8)]


def test_weekly_series_outlet_barcode_grain_uses_a_compound_key() -> None:
    series = build_weekly_series(_orders(), grain="outlet_barcode")
    assert [row["key"] for row in series] == ["OUT1|P1"]


def test_weekly_series_rejects_an_unknown_grain() -> None:
    try:
        build_weekly_series(_orders(), grain="nonsense")
    except ValueError as error:
        assert "grain" in str(error)
    else:
        raise AssertionError("expected ValueError")


def test_profile_reports_demand_classes() -> None:
    series = build_weekly_series(_orders(), grain="barcode")
    profile = profile_series(series)
    assert profile["seriesCount"] == 1
    assert "smooth" in profile["classificationCounts"]
    assert profile["meanNonZeroRate"] == 1.0


def test_patterns_exclude_orders_on_or_after_the_cutoff() -> None:
    orders = _orders()
    cutoff = date(2026, 2, 2)
    patterns = build_patterns(orders, as_of=cutoff)
    assert patterns
    entry = patterns[0]
    assert entry["retailerId"] == "OUT1"
    assert sum(entry["weeklyQuantities"]) > 0
    assert len(entry["weeklyQuantities"]) == 8


def test_cutoffs_leave_a_truth_window_after_the_last_order() -> None:
    orders = _orders()
    cutoffs = candidate_cutoffs(orders, count=3, truth_window_days=28)
    assert cutoffs
    last_order = max(
        date.fromisoformat(order["submittedAt"]) for order in orders
    )
    assert cutoffs[-1] + timedelta(days=28) >= last_order
    assert cutoffs == sorted(cutoffs)


def test_simulation_pool_is_deterministic_for_a_seed() -> None:
    orders = _orders()
    first = build_simulation_pool(
        orders,
        cutoff=date(2026, 2, 2),
        pool_size=5,
        seed=7,
        unit_prices={"P1": 5.0},
    )
    second = build_simulation_pool(
        orders,
        cutoff=date(2026, 2, 2),
        pool_size=5,
        seed=7,
        unit_prices={"P1": 5.0},
    )
    assert [row.expected_value_rm for row in first] == [
        row.expected_value_rm for row in second
    ]


def test_evaluation_is_deterministic_and_labels_its_evidence() -> None:
    snapshot = {"orders": _orders(), "products": [{"productId": "P1", "unitPrice": 5.0}]}
    first = run_evaluation(
        snapshot, seed=11, cutoff_count=2, simulation_replicates=3, simulation_pool_size=6
    ).to_dict()
    second = run_evaluation(
        snapshot, seed=11, cutoff_count=2, simulation_replicates=3, simulation_pool_size=6
    ).to_dict()
    assert first == second
    assert first["L1ForecastValue"]["evidence"] == "real"
    assert first["L2SignalQuality"]["evidence"] == "real"
    assert (first["L5PolicyComparison"] or {}).get("evidence") == "simulated"


def test_evaluation_reports_field_usefulness_as_unavailable() -> None:
    snapshot = {"orders": _orders()}
    result = run_evaluation(
        snapshot, seed=1, cutoff_count=2, simulation_replicates=2, simulation_pool_size=5
    ).to_dict()
    field_block = result["L4FieldUsefulness"]
    assert field_block["evidence"] == "not yet available"
    assert field_block["metrics"]["recommendationsShown"] is None


def test_evaluation_handles_an_empty_snapshot() -> None:
    result = run_evaluation({}, seed=1, cutoff_count=2).to_dict()
    assert result["L1ForecastValue"]["grains"]["barcode"]["profile"]["seriesCount"] == 0
    assert result["L3DecisionQuality"] is None
    assert result["L5PolicyComparison"] is None


def test_weekly_series_bucket_by_the_kuching_week() -> None:
    orders = [
        {"retailerId": "R1", "submittedAt": "2026-01-05T10:00:00+08:00",
         "items": [{"productId": "P1", "qty": 3}]},
        {"retailerId": "R1", "submittedAt": "2026-01-11T17:00:00Z",
         "items": [{"productId": "P1", "qty": 5}]},
        {"retailerId": "R1", "submittedAt": "2026-01-18",
         "items": [{"productId": "P9", "qty": 1}]},
    ]
    series = build_weekly_series(orders, grain="barcode")
    assert series[0]["values"] == [3.0, 5.0]
    assert series[0]["lastWeek"] == "2026-01-12"


def test_weekly_series_run_to_the_snapshot_cutoff_week() -> None:
    orders = _orders()
    start = date(2026, 1, 5)
    for index in range(4):
        orders.append(
            {
                "retailerId": "OUT2",
                "status": "submitted",
                "submittedAt": (start + timedelta(weeks=index)).isoformat(),
                "items": [{"productId": "P2", "qty": 4}],
            }
        )
    series = {row["key"]: row for row in build_weekly_series(orders, grain="barcode")}
    assert series["P1"]["values"] == [float(10 + index) for index in range(8)]
    assert series["P2"]["values"] == [4.0, 4.0, 4.0, 4.0, 0.0, 0.0, 0.0, 0.0]
    assert series["P2"]["firstWeek"] == "2026-01-05"
    assert series["P2"]["lastWeek"] == series["P1"]["lastWeek"] == "2026-02-23"

    from forecasting.evaluation.model_selection_backtest import (
        run_model_selection_backtest,
    )

    report = run_model_selection_backtest(list(series.values()))["nonDemo"]
    stopped = next(row for row in report.series if row.series_key == "P2")
    assert stopped.actuals[-1] == 0.0


def _line(retailer, product, when, qty, *, demo=False):
    return {"retailerId": retailer, "submittedAt": when, "isDemo": demo,
            "items": [{"productId": product, "qty": qty}]}


def test_cutoff_week_ignores_demo_orders_and_partial_weeks() -> None:
    orders = [
        _line("R1", "P1", "2026-01-05", 3),
        _line("R1", "P1", "2026-01-18", 4),
        _line("R1", "P2", "2026-01-24", 9),
        _line("D1", "P1", "2026-02-10", 7, demo=True),
    ]
    series = {row["key"]: row for row in build_weekly_series(orders, grain="outlet_barcode")}
    assert series["R1|P1"]["values"] == [3.0, 4.0]
    assert series["R1|P1"]["lastWeek"] == "2026-01-12"
    assert "R1|P2" not in series
    assert "D1|P1" not in series


def test_a_week_covered_to_its_sunday_is_complete() -> None:
    orders = [_line("R1", "P1", "2026-01-05", 3), _line("R1", "P1", "2026-01-11", 4)]
    series = build_weekly_series(orders, grain="barcode")
    assert series[0]["values"] == [7.0]
    assert series[0]["lastWeek"] == "2026-01-05"


def test_a_demo_only_snapshot_still_has_a_cutoff() -> None:
    orders = [_line("D1", "P1", "2026-01-05", 3, demo=True),
              _line("D1", "P1", "2026-01-11", 4, demo=True)]
    series = build_weekly_series(orders, grain="barcode")
    assert series[0]["values"] == [7.0]
    assert series[0]["isDemo"] is True

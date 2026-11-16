from datetime import date, timedelta

import pytest

from forecasting.evaluation.overdue_backtest import run_overdue_backtest

CUTOFF = date(2026, 7, 1)
POST_END = date(2026, 8, 1)
PRICES = {"P1": 10.0}

WINDOW_START = date(2026, 5, 4)


def _order(retailer_id, product_id, order_date):
    return {
        "orderId": f"{retailer_id}-{product_id}-{order_date}",
        "retailerId": retailer_id,
        "submittedAt": order_date,
        "status": "submitted",
        "items": [{"productId": product_id, "qty": 5}],
    }


def _pattern(retailer_id, product_id, *, is_demo=False, trend="stable"):
    return {
        "retailerId": retailer_id,
        "productId": product_id,
        "retailerName": "R",
        "productName": "P",
        "salesmanUid": "U1",
        "salesmanCode": "S1",
        "branchId": "B1",
        "trend": trend,
        "isDemo": is_demo,
    }


def _weekly_orders(retailer_id, product_id, start, count):
    return [
        _order(retailer_id, product_id, start + timedelta(weeks=i))
        for i in range(count)
    ]


def test_detector_fires_and_stays_silent_is_true_positive() -> None:
    orders = _weekly_orders("R1", "P1", WINDOW_START, 5)
    patterns = [_pattern("R1", "P1")]
    reports = run_overdue_backtest(
        orders, patterns, [], PRICES, cutoff=CUTOFF, post_window_end=POST_END
    )
    non_demo = reports["nonDemo"]
    assert non_demo.eligible_population == 1
    assert non_demo.ground_truth_positives == 1
    assert non_demo.detector_fired == 1
    assert non_demo.detector.precision == pytest.approx(1.0)
    assert non_demo.detector.recall == pytest.approx(1.0)
    assert non_demo.tiny_population is True


def test_recent_reorder_must_not_fire_is_true_negative() -> None:
    orders = _weekly_orders("R2", "P1", WINDOW_START, 8)
    orders.append(_order("R2", "P1", date(2026, 6, 29)))
    orders.append(_order("R2", "P1", date(2026, 7, 6)))
    patterns = [_pattern("R2", "P1")]
    reports = run_overdue_backtest(
        orders, patterns, [], PRICES, cutoff=CUTOFF, post_window_end=POST_END
    )
    non_demo = reports["nonDemo"]
    assert non_demo.eligible_population == 1
    assert non_demo.ground_truth_positives == 0
    assert non_demo.detector_fired == 0
    assert non_demo.detector.precision is None
    assert non_demo.detector.recall is None


def test_baseline_and_detector_both_scored() -> None:
    orders = _weekly_orders("R1", "P1", WINDOW_START, 5)
    reports = run_overdue_backtest(
        orders,
        [_pattern("R1", "P1")],
        [],
        PRICES,
        cutoff=CUTOFF,
        post_window_end=POST_END,
    )
    non_demo = reports["nonDemo"]
    assert non_demo.baseline_fired == 1
    assert non_demo.baseline.recall == pytest.approx(1.0)


def test_demo_pair_scored_in_demo_cohort() -> None:
    orders = _weekly_orders("R9", "P1", WINDOW_START, 5)
    reports = run_overdue_backtest(
        orders,
        [_pattern("R9", "P1", is_demo=True)],
        [],
        PRICES,
        cutoff=CUTOFF,
        post_window_end=POST_END,
    )
    assert reports["demo"].eligible_population == 1
    assert reports["nonDemo"].eligible_population == 0


def test_post_window_must_be_after_cutoff() -> None:
    with pytest.raises(ValueError):
        run_overdue_backtest(
            [], [], [], PRICES, cutoff=CUTOFF, post_window_end=CUTOFF
        )


def test_to_dict_shape() -> None:
    orders = _weekly_orders("R1", "P1", WINDOW_START, 5)
    reports = run_overdue_backtest(
        orders,
        [_pattern("R1", "P1")],
        [],
        PRICES,
        cutoff=CUTOFF,
        post_window_end=POST_END,
    )
    payload = reports["nonDemo"].to_dict()
    assert payload["detector"]["precision"] == pytest.approx(1.0)
    assert "note" in payload
    assert payload["cohort"] == "nonDemo"

from datetime import date, datetime, timedelta, timezone

from forecasting.ai_core.order_weekday import (
    ORDER_WEEKDAY_VERSION,
    usual_order_weekday,
)
from forecasting.ai_service.visit_briefs import (
    build_visit_briefs,
    usual_order_weekdays,
)

AS_OF = date(2026, 11, 16)
WINDOW_START = date(2026, 9, 21)


def _day(week: int, weekday: int) -> date:
    return WINDOW_START + timedelta(weeks=week, days=weekday - 1)


def _order(retailer_id: str, moment, **extra):
    return {"retailerId": retailer_id, "submittedAt": moment, **extra}


def test_weekday_is_taken_in_kuching_time_across_utc_midnight() -> None:
    late_monday_utc = [
        datetime(2026, 9, 21, 16, 30, tzinfo=timezone.utc) + timedelta(weeks=week)
        for week in range(4)
    ]
    early_monday_utc = [
        datetime(2026, 9, 20, 16, 0, tzinfo=timezone.utc) + timedelta(weeks=week)
        for week in range(1, 5)
    ]

    assert usual_order_weekday(late_monday_utc, as_of=AS_OF) == 2
    assert usual_order_weekday(early_monday_utc, as_of=AS_OF) == 1


def test_two_weekdays_with_equal_counts_give_no_fact() -> None:
    days = [_day(0, 1), _day(1, 1), _day(2, 3), _day(3, 3)]

    assert usual_order_weekday(days, as_of=AS_OF) is None


def test_exactly_sixty_percent_counts_and_just_under_does_not() -> None:
    three_of_five = [_day(week, 2) for week in range(3)] + [_day(3, 4), _day(4, 5)]
    four_of_seven = [_day(week, 2) for week in range(4)] + [
        _day(4, 4),
        _day(5, 5),
        _day(6, 6),
    ]

    assert usual_order_weekday(three_of_five, as_of=AS_OF) == 2
    assert usual_order_weekday(four_of_seven, as_of=AS_OF) is None


def test_four_orders_are_enough_and_three_are_not() -> None:
    assert usual_order_weekday([_day(w, 5) for w in range(4)], as_of=AS_OF) == 5
    assert usual_order_weekday([_day(w, 5) for w in range(3)], as_of=AS_OF) is None


def test_orders_outside_the_eight_completed_weeks_are_not_counted() -> None:
    before_window = [WINDOW_START - timedelta(days=7), WINDOW_START - timedelta(days=14)]
    current_week = [AS_OF, AS_OF + timedelta(days=1)]
    inside = [_day(0, 1), _day(7, 1)]

    assert (
        usual_order_weekday(before_window + inside + current_week, as_of=AS_OF)
        is None
    )
    assert usual_order_weekday(
        [_day(0, 1), _day(7, 7), _day(3, 7), _day(5, 7)], as_of=AS_OF
    ) == 7


def test_cancelled_and_rejected_orders_are_not_counted() -> None:
    orders = [_order("R1", _day(week, 3).isoformat()) for week in range(3)] + [
        _order("R1", _day(3, 3).isoformat(), status="cancelled"),
        _order("R1", _day(4, 3).isoformat(), status="rejected"),
    ]

    assert usual_order_weekdays(orders, as_of=AS_OF) == {}
    assert usual_order_weekdays(
        [*orders, _order("R1", _day(5, 3).isoformat(), status="confirmed")],
        as_of=AS_OF,
    ) == {"R1": 3}


def test_brief_carries_the_fact_only_for_a_shop_that_has_one() -> None:
    briefs = build_visit_briefs(
        [],
        as_of=AS_OF,
        run_id="run-test",
        generated_at=datetime(2026, 11, 16, tzinfo=timezone.utc),
        coverage_retailers=[
            {"retailerId": "R1", "salesmanUid": "U1"},
            {"retailerId": "R2", "salesmanUid": "U1"},
        ],
        order_weekdays={"R1": 4, "R-without-brief": 2},
    )
    by_retailer = {brief["retailerId"]: brief for brief in briefs}

    assert set(by_retailer) == {"R1", "R2"}
    assert by_retailer["R1"]["usualOrderWeekday"] == 4
    assert by_retailer["R1"]["usualOrderWeekdayVersion"] == ORDER_WEEKDAY_VERSION
    assert "usualOrderWeekday" not in by_retailer["R2"]
    assert "usualOrderWeekdayVersion" not in by_retailer["R2"]

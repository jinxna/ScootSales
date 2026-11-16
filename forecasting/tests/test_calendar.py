from datetime import date, datetime, timezone

import pytest

from forecasting.ai_core import completed_week_starts, week_start


def test_week_start_uses_asia_kuching_before_bucketing() -> None:
    sunday_utc_monday_kuching = datetime(
        2026,
        6,
        14,
        16,
        30,
        tzinfo=timezone.utc,
    )
    assert week_start(sunday_utc_monday_kuching) == date(2026, 6, 15)


def test_completed_week_starts_excludes_current_week() -> None:
    starts = completed_week_starts(date(2026, 6, 15), weeks=8)
    assert starts[0] == date(2026, 4, 20)
    assert starts[-1] == date(2026, 6, 8)
    assert len(starts) == 8


_BUSINESS_DATE_CASES = [
    ("2026-06-14T18:00:00Z", date(2026, 6, 15)),
    (datetime(2026, 6, 14, 18, tzinfo=timezone.utc), date(2026, 6, 15)),
    ("2026-06-14T23:30:00-05:00", date(2026, 6, 15)),
    ("2026-06-14T15:59:00+00:00", date(2026, 6, 14)),
    ("2026-06-14T09:00:00", date(2026, 6, 14)),
    ("2026-06-14", date(2026, 6, 14)),
    (date(2026, 6, 14), date(2026, 6, 14)),
]


def _business_date_parsers():
    from forecasting.ai_service.replenishment import _as_local_date
    from forecasting.evaluation import closed_loop_runner, forecast_backtest
    from forecasting.evaluation import route_policy_sim, signal_quality

    return {
        "replenishment": _as_local_date,
        "closedLoopRunner": lambda raw: closed_loop_runner._order_date(
            {"submittedAt": raw}
        ),
        "forecastBacktest": forecast_backtest._to_date,
        "signalQuality": signal_quality._as_date,
        "routePolicySim": route_policy_sim._as_date,
    }


@pytest.mark.parametrize("parser", sorted(_business_date_parsers()))
@pytest.mark.parametrize("raw, expected", _BUSINESS_DATE_CASES)
def test_business_date_parsers_use_the_kuching_date(parser, raw, expected) -> None:
    assert _business_date_parsers()[parser](raw) == expected

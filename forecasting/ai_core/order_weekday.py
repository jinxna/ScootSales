from __future__ import annotations

from collections import Counter
from datetime import date, datetime, timedelta
from typing import Iterable

from .calendar import as_kuching_date, week_start


ORDER_WEEKDAY_VERSION = "order-day/1.0.0"
ORDER_WEEKDAY_WINDOW_WEEKS = 8
ORDER_WEEKDAY_MIN_ORDERS = 4
ORDER_WEEKDAY_MIN_SHARE_PERCENT = 60


def usual_order_weekday(
    order_moments: Iterable[date | datetime],
    *,
    as_of: date | datetime,
) -> int | None:
    window_end = week_start(as_of)
    window_start = window_end - timedelta(weeks=ORDER_WEEKDAY_WINDOW_WEEKS)
    weekdays = [
        local_date.isoweekday()
        for local_date in (as_kuching_date(moment) for moment in order_moments)
        if window_start <= local_date < window_end
    ]
    if len(weekdays) < ORDER_WEEKDAY_MIN_ORDERS:
        return None
    weekday, count = Counter(weekdays).most_common(1)[0]
    if count * 100 < ORDER_WEEKDAY_MIN_SHARE_PERCENT * len(weekdays):
        return None
    return weekday

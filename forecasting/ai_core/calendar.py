from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo


ASIA_KUCHING = ZoneInfo("Asia/Kuching")

HISTORY_WINDOW_VERSION = "history-window/1.0.0"
DEFAULT_HISTORY_WEEKS = 8
MIN_HISTORY_WEEKS = 4
MAX_HISTORY_WEEKS = 104
EVALUATED_HISTORY_WEEKS = (4, 8, 12, 26)


def as_kuching_date(value: date | datetime) -> date:
    if isinstance(value, datetime):
        moment = value
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=ASIA_KUCHING)
        return moment.astimezone(ASIA_KUCHING).date()
    return value


def week_start(value: date | datetime) -> date:
    local_date = as_kuching_date(value)
    return local_date - timedelta(days=local_date.weekday())


def completed_week_starts(
    as_of: date | datetime,
    *,
    weeks: int = 8,
) -> tuple[date, ...]:
    if weeks <= 0:
        raise ValueError("weeks must be positive")
    current_start = week_start(as_of)
    first = current_start - timedelta(weeks=weeks)
    return tuple(first + timedelta(weeks=index) for index in range(weeks))


def completed_weeks_since(
    earliest: date | datetime | None,
    as_of: date | datetime,
) -> int:
    if earliest is None:
        return 0
    return max(0, (week_start(as_of) - week_start(earliest)).days // 7)


def parse_history_weeks(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("historyWeeks must be a whole number of weeks")
    return value


@dataclass(frozen=True)
class HistoryWindow:
    weeks: int
    requested: int
    source: str

    @property
    def clamped(self) -> bool:
        return self.weeks != self.requested

    @property
    def evaluated(self) -> bool:
        return self.weeks in EVALUATED_HISTORY_WEEKS

    def stamp(self) -> dict[str, Any]:
        return {
            "historyWeeks": self.weeks,
            "historyWindowVersion": HISTORY_WINDOW_VERSION,
            "windowEvaluated": self.evaluated,
        }

    def to_dict(self) -> dict[str, Any]:
        return {
            **self.stamp(),
            "requestedHistoryWeeks": self.requested,
            "historyWindowSource": self.source,
            "historyWindowClamped": self.clamped,
        }


def resolve_history_window(
    requested: int,
    *,
    available_weeks: int,
    source: str,
) -> HistoryWindow:
    cap = min(MAX_HISTORY_WEEKS, max(available_weeks, DEFAULT_HISTORY_WEEKS))
    weeks = min(max(parse_history_weeks(requested), MIN_HISTORY_WEEKS), cap)
    return HistoryWindow(weeks=weeks, requested=requested, source=source)


def live_history_window(setting: Any, *, available_weeks: int) -> HistoryWindow:
    try:
        requested = parse_history_weeks(setting)
    except ValueError:
        return HistoryWindow(
            weeks=DEFAULT_HISTORY_WEEKS,
            requested=DEFAULT_HISTORY_WEEKS,
            source="default",
        )
    return resolve_history_window(
        requested, available_weeks=available_weeks, source="setting"
    )

from datetime import datetime, timezone

import pytest

from platform_service.ids import KUALA_LUMPUR
from platform_service.invoices import add_months


def kl(year, month, day):
    return datetime(year, month, day, tzinfo=KUALA_LUMPUR)


@pytest.mark.parametrize(
    ("start", "months", "end"),
    [
        (kl(2027, 3, 1), 1, kl(2027, 4, 1)),
        (kl(2026, 12, 1), 1, kl(2027, 1, 1)),
        (kl(2027, 3, 1), 12, kl(2028, 3, 1)),
        (kl(2027, 1, 31), 1, kl(2027, 2, 28)),
        (kl(2026, 11, 16), 1, kl(2026, 12, 16)),
    ],
)
def test_period_end_follows_the_kuala_lumpur_calendar(start, months, end):
    stored = start.astimezone(timezone.utc)
    result = add_months(stored, months)
    assert result == end
    assert result.tzinfo == timezone.utc

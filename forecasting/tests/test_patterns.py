import pytest

from forecasting.ai_core import anomaly_score, classify_trend, simple_forecast


@pytest.mark.parametrize(
    ("values", "expected"),
    [
        ([8, 9, 10, 9, 8, 7, 0, 0], "stopped"),
        ([20, 18, 17, 15, 11, 8, 6, 4], "declining"),
        ([3, 4, 4, 5, 7, 8, 10, 12], "growing"),
        ([8, 8, 9, 8, 8, 9, 8, 8], "stable"),
        ([0, 0, 0, 0, 0, 0, 0, 0], "no_demand"),
    ],
)
def test_trend_classifier(values: list[float], expected: str) -> None:
    assert classify_trend(values) == expected


def test_forecast_is_non_negative() -> None:
    assert simple_forecast([10, 8, 4, 0]) >= 0
    assert simple_forecast([]) == 0


def test_stopped_pattern_has_maximum_anomaly() -> None:
    assert anomaly_score([8, 9, 10, 9, 8, 7, 0, 0]) == 1.0

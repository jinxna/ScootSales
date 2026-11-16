from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Sequence

CALIBRATION_BUCKETS: tuple[tuple[float, float], ...] = (
    (0.0, 0.2),
    (0.2, 0.4),
    (0.4, 0.6),
    (0.6, 0.8),
    (0.8, 1.000001),
)


def precision_at_k(ranked_labels: Sequence[bool], k: int) -> float | None:
    if k <= 0:
        return None
    window = list(ranked_labels)[:k]
    if not window:
        return None
    return sum(1 for label in window if label) / len(window)


def recall_at_k(ranked_labels: Sequence[bool], k: int) -> float | None:
    labels = list(ranked_labels)
    positives = sum(1 for label in labels if label)
    if positives == 0:
        return None
    window = labels[:k] if k > 0 else []
    return sum(1 for label in window if label) / positives


def average_precision(ranked_labels: Sequence[bool]) -> float | None:
    labels = list(ranked_labels)
    positives = sum(1 for label in labels if label)
    if not labels or positives == 0:
        return None
    hits = 0
    total = 0.0
    for index, label in enumerate(labels, start=1):
        if not label:
            continue
        hits += 1
        total += hits / index
    return total / positives


@dataclass(frozen=True)
class CalibrationBucket:
    lower: float
    upper: float
    count: int
    mean_confidence: float | None
    observed_rate: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "lower": self.lower,
            "upper": self.upper,
            "count": self.count,
            "meanConfidence": self.mean_confidence,
            "observedRate": self.observed_rate,
        }


@dataclass(frozen=True)
class CalibrationReport:
    buckets: tuple[CalibrationBucket, ...]
    mean_confidence: float | None
    observed_rate: float | None
    expected_calibration_error: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "buckets": [bucket.to_dict() for bucket in self.buckets],
            "meanConfidence": self.mean_confidence,
            "observedRate": self.observed_rate,
            "expectedCalibrationError": self.expected_calibration_error,
        }


def calibration_report(
    confidences: Sequence[float],
    outcomes: Sequence[bool],
) -> CalibrationReport:
    if len(confidences) != len(outcomes):
        raise ValueError("confidences and outcomes must have equal length")
    pairs = [
        (max(0.0, min(1.0, float(confidence))), bool(outcome))
        for confidence, outcome in zip(confidences, outcomes)
    ]
    if not pairs:
        return CalibrationReport((), None, None, None)
    buckets: list[CalibrationBucket] = []
    weighted_gap = 0.0
    for lower, upper in CALIBRATION_BUCKETS:
        inside = [
            (confidence, outcome)
            for confidence, outcome in pairs
            if lower <= confidence < upper
        ]
        if not inside:
            buckets.append(CalibrationBucket(lower, upper, 0, None, None))
            continue
        mean_confidence = sum(value for value, _ in inside) / len(inside)
        observed = sum(1 for _, outcome in inside if outcome) / len(inside)
        buckets.append(
            CalibrationBucket(
                lower=lower,
                upper=upper,
                count=len(inside),
                mean_confidence=round(mean_confidence, 6),
                observed_rate=round(observed, 6),
            )
        )
        weighted_gap += len(inside) * abs(mean_confidence - observed)
    return CalibrationReport(
        buckets=tuple(buckets),
        mean_confidence=round(sum(value for value, _ in pairs) / len(pairs), 6),
        observed_rate=round(
            sum(1 for _, outcome in pairs if outcome) / len(pairs), 6
        ),
        expected_calibration_error=round(weighted_gap / len(pairs), 6),
    )


@dataclass(frozen=True)
class LeadTimeReport:
    count: int
    median_days: float | None
    p90_days: float | None
    negative_count: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "count": self.count,
            "medianDays": self.median_days,
            "p90Days": self.p90_days,
            "negativeCount": self.negative_count,
        }


def _percentile(sorted_values: Sequence[float], fraction: float) -> float:
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = fraction * (len(sorted_values) - 1)
    low = int(position)
    high = min(low + 1, len(sorted_values) - 1)
    weight = position - low
    return sorted_values[low] * (1 - weight) + sorted_values[high] * weight


def lead_time_report(days: Sequence[float]) -> LeadTimeReport:
    values = [float(value) for value in days]
    usable = sorted(value for value in values if value >= 0)
    if not usable:
        return LeadTimeReport(
            count=0,
            median_days=None,
            p90_days=None,
            negative_count=sum(1 for value in values if value < 0),
        )
    return LeadTimeReport(
        count=len(usable),
        median_days=round(_percentile(usable, 0.5), 4),
        p90_days=round(_percentile(usable, 0.9), 4),
        negative_count=sum(1 for value in values if value < 0),
    )


__all__ = [
    "CALIBRATION_BUCKETS",
    "CalibrationBucket",
    "CalibrationReport",
    "LeadTimeReport",
    "average_precision",
    "calibration_report",
    "lead_time_report",
    "precision_at_k",
    "recall_at_k",
]

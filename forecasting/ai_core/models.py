from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import date


MAX_SUPPORTED_MAGNITUDE = 1e15


def require_supported_number(value: float, field_name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{field_name} must be numeric, got {value!r}")
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError) as error:
        raise ValueError(f"{field_name} must be numeric, got {value!r}") from error
    if not math.isfinite(number):
        raise ValueError(f"{field_name} must be finite, got {value!r}")
    if abs(number) > MAX_SUPPORTED_MAGNITUDE:
        raise ValueError(
            f"{field_name} exceeds the supported magnitude "
            f"({MAX_SUPPORTED_MAGNITUDE:g}): {value!r}"
        )
    return number


def require_supported_series(
    values: Iterable[float], field_name: str
) -> tuple[float, ...]:
    checked: list[float] = []
    for index, value in enumerate(values):
        checked.append(require_supported_number(value, f"{field_name}[{index}]"))
    return tuple(checked)


@dataclass(frozen=True)
class WeeklyObservation:
    week_start: date
    quantity: float
    revenue_rm: float = 0.0
    order_count: int = 0

    def __post_init__(self) -> None:
        require_supported_number(self.quantity, "quantity")
        require_supported_number(self.revenue_rm, "revenue_rm")
        if self.quantity < 0:
            raise ValueError("quantity cannot be negative")
        if self.revenue_rm < 0:
            raise ValueError("revenue_rm cannot be negative")
        if self.order_count < 0:
            raise ValueError("order_count cannot be negative")


@dataclass(frozen=True)
class RetailerProductSeries:
    retailer_id: str
    product_id: str
    observations: tuple[WeeklyObservation, ...]
    retailer_name: str = ""
    product_name: str = ""
    unit_price_rm: float = 0.0
    salesman_uid: str = ""
    salesman_code: str = ""
    branch_id: str = ""
    coverage_weeks: int = 8

    def __post_init__(self) -> None:
        if not self.retailer_id.strip():
            raise ValueError("retailer_id is required")
        if not self.product_id.strip():
            raise ValueError("product_id is required")
        if self.unit_price_rm < 0:
            raise ValueError("unit_price_rm cannot be negative")
        if self.coverage_weeks < 0:
            raise ValueError("coverage_weeks cannot be negative")


@dataclass(frozen=True)
class PatternMetrics:
    week_starts: tuple[date, ...]
    quantities: tuple[float, ...]
    revenues_rm: tuple[float, ...]
    order_counts: tuple[int, ...]
    trend: str
    baseline_average: float
    recent_average: float
    latest_quantity: float
    slope: float
    forecast_next_week: float
    anomaly_score: float
    confidence_score: float
    confidence: str
    active_weeks: int
    total_quantity: float
    forecast_model: str = ""
    forecast_version: str = ""
    forecast_lower: float | None = None
    forecast_upper: float | None = None
    forecast_probability_non_zero: float = 0.0
    forecast_status: str = ""
    forecast_classification: str = ""
    forecast_semantics: str = ""
    evidence: dict[str, object] = field(default_factory=dict)

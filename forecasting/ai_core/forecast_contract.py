from __future__ import annotations

import math
import statistics
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any, Sequence

from .forecast_models import (
    FORECAST_MODELS_VERSION,
    POINT_SEMANTICS,
    DemandCharacterisation,
    ForecastPoint,
    characterise_demand,
    forecast_next,
)
from .models import require_supported_series

FORECAST_CONTRACT_VERSION = "operational-forecast/1.4.1"

STATUS_OK = "ok"
STATUS_INSUFFICIENT_HISTORY = "insufficient_history"

SCOPE_PRODUCT = "product"
SCOPE_RETAILER_PRODUCT = "retailer_product"

PERIOD_DAYS = 7.0


def observed_reference_units(values: Sequence[float]) -> float:
    cleaned = [
        max(0.0, value)
        for value in require_supported_series(values, "observations")
    ]
    if not cleaned:
        return 0.0
    non_zero = [value for value in cleaned if value > 0]
    if not non_zero:
        return 0.0
    return (len(non_zero) / len(cleaned)) * statistics.fmean(non_zero)


def _iso_date(value: date | datetime | str) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, datetime):
        return value.date().isoformat()
    return value.isoformat()


def _iso_timestamp(value: datetime | str) -> str:
    return value if isinstance(value, str) else value.isoformat()


@dataclass(frozen=True)
class OperationalForecast:
    scope_type: str
    retailer_id: str
    product_id: str
    product_name: str
    period_start: str
    period_days: float
    point: float | None
    point_semantics: str
    probability_non_zero: float | None
    lower: float | None
    upper: float | None
    demand_class: str | None
    model: str | None
    model_version: str
    status: str
    observed_periods: int
    non_zero_periods: int
    mean_non_zero_demand: float
    reference_units: float
    data_cutoff: str
    generated_at: str
    component_count: int = 0
    modelled_component_count: int = 0
    observed_component_count: int = 0
    no_demand_component_count: int = 0
    contract_version: str = FORECAST_CONTRACT_VERSION
    history_weeks: int | None = None
    history_window_version: str | None = None
    window_evaluated: bool | None = None

    @property
    def is_usable(self) -> bool:
        return self.status == STATUS_OK and self.point is not None

    @property
    def units_for_value(self) -> float:
        if self.is_usable:
            return float(self.point)
        return self.reference_units

    def to_dict(self) -> dict[str, Any]:
        return {
            "scopeType": self.scope_type,
            "retailerId": self.retailer_id,
            "productId": self.product_id,
            "productName": self.product_name,
            "periodStart": self.period_start,
            "periodDays": self.period_days,
            "point": self.point,
            "pointSemantics": self.point_semantics,
            "probabilityNonZero": self.probability_non_zero,
            "lower": self.lower,
            "upper": self.upper,
            "demandClass": self.demand_class,
            "model": self.model,
            "modelVersion": self.model_version,
            "status": self.status,
            "observedPeriods": self.observed_periods,
            "nonZeroPeriods": self.non_zero_periods,
            "meanNonZeroDemand": self.mean_non_zero_demand,
            "referenceUnits": round(self.reference_units, 4),
            "dataCutoff": self.data_cutoff,
            "generatedAt": self.generated_at,
            "contractVersion": self.contract_version,
            "componentCount": self.component_count,
            "modelledComponentCount": self.modelled_component_count,
            "observedComponentCount": self.observed_component_count,
            "noDemandComponentCount": self.no_demand_component_count,
            "historyWeeks": self.history_weeks,
            "historyWindowVersion": self.history_window_version,
            "windowEvaluated": self.window_evaluated,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "OperationalForecast":
        version = str(payload.get("contractVersion", ""))
        if version != FORECAST_CONTRACT_VERSION:
            raise ValueError("unknown forecast contract version: " + (version or "missing"))
        return cls(
            scope_type=str(payload["scopeType"]),
            retailer_id=str(payload.get("retailerId", "")),
            product_id=str(payload["productId"]),
            product_name=str(payload.get("productName", "")),
            period_start=str(payload["periodStart"]),
            period_days=float(payload.get("periodDays", PERIOD_DAYS)),
            point=None if payload.get("point") is None else float(payload["point"]),
            point_semantics=str(payload["pointSemantics"]),
            probability_non_zero=(
                None
                if payload.get("probabilityNonZero") is None
                else float(payload["probabilityNonZero"])
            ),
            lower=None if payload.get("lower") is None else float(payload["lower"]),
            upper=None if payload.get("upper") is None else float(payload["upper"]),
            demand_class=(
                None if payload.get("demandClass") is None else str(payload["demandClass"])
            ),
            model=None if payload.get("model") is None else str(payload["model"]),
            model_version=str(payload.get("modelVersion", FORECAST_MODELS_VERSION)),
            status=str(payload["status"]),
            observed_periods=int(payload.get("observedPeriods", 0)),
            non_zero_periods=int(payload.get("nonZeroPeriods", 0)),
            mean_non_zero_demand=float(payload.get("meanNonZeroDemand", 0.0)),
            reference_units=float(payload.get("referenceUnits", 0.0)),
            data_cutoff=str(payload.get("dataCutoff", "")),
            generated_at=str(payload.get("generatedAt", "")),
            component_count=int(payload.get("componentCount", 0)),
            modelled_component_count=int(payload.get("modelledComponentCount", 0)),
            observed_component_count=int(payload.get("observedComponentCount", 0)),
            no_demand_component_count=int(payload.get("noDemandComponentCount", 0)),
            history_weeks=(
                None if payload.get("historyWeeks") is None else int(payload["historyWeeks"])
            ),
            history_window_version=(
                None
                if payload.get("historyWindowVersion") is None
                else str(payload["historyWindowVersion"])
            ),
            window_evaluated=(
                None
                if payload.get("windowEvaluated") is None
                else bool(payload["windowEvaluated"])
            ),
        )


def build_operational_forecast(
    values: Sequence[float],
    *,
    product_id: str,
    product_name: str = "",
    retailer_id: str = "",
    period_start: date | datetime | str | None = None,
    data_cutoff: date | datetime | str | None = None,
    generated_at: datetime | str | None = None,
    with_interval: bool = True,
    model: str | None = None,
) -> OperationalForecast:
    cleaned = [
        max(0.0, value) for value in require_supported_series(values, "demand")
    ]
    characterisation: DemandCharacterisation = characterise_demand(cleaned)
    forecast: ForecastPoint = forecast_next(
        cleaned, characterisation=characterisation, with_interval=with_interval, model=model
    )
    usable = (
        forecast.status == "ok"
        and math.isfinite(forecast.point)
        and forecast.point >= 0
    )
    return OperationalForecast(
        scope_type=SCOPE_RETAILER_PRODUCT if retailer_id else SCOPE_PRODUCT,
        retailer_id=retailer_id,
        product_id=product_id,
        product_name=product_name,
        period_start="" if period_start is None else _iso_date(period_start),
        period_days=PERIOD_DAYS,
        point=round(forecast.point, 4) if usable else None,
        point_semantics=POINT_SEMANTICS,
        probability_non_zero=forecast.probability_non_zero,
        lower=round(forecast.lower, 4) if usable and forecast.lower is not None else None,
        upper=round(forecast.upper, 4) if usable and forecast.upper is not None else None,
        demand_class=forecast.classification,
        model=forecast.model,
        model_version=forecast.version,
        status=STATUS_OK if usable else ("model_error" if forecast.status == "model_error" else STATUS_INSUFFICIENT_HISTORY),
        observed_periods=characterisation.periods,
        non_zero_periods=characterisation.non_zero_periods,
        mean_non_zero_demand=characterisation.mean_non_zero_demand,
        reference_units=observed_reference_units(cleaned),
        data_cutoff="" if data_cutoff is None else _iso_date(data_cutoff),
        generated_at="" if generated_at is None else _iso_timestamp(generated_at),
        component_count=1 if retailer_id else 0,
        modelled_component_count=1 if usable and retailer_id else 0,
        observed_component_count=(
            1 if (not usable and retailer_id and observed_reference_units(cleaned) > 0) else 0
        ),
        no_demand_component_count=(
            1 if (not usable and retailer_id and observed_reference_units(cleaned) <= 0) else 0
        ),
    )


__all__ = [
    "FORECAST_CONTRACT_VERSION",
    "PERIOD_DAYS",
    "SCOPE_PRODUCT",
    "SCOPE_RETAILER_PRODUCT",
    "STATUS_INSUFFICIENT_HISTORY",
    "STATUS_OK",
    "OperationalForecast",
    "build_operational_forecast",
    "observed_reference_units",
]

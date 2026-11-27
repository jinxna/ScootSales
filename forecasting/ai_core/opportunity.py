from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence

from .forecast_models import (
    FORECAST_MODELS_VERSION,
    POINT_SEMANTICS,
)
from .forecast_contract import (
    OperationalForecast,
    build_operational_forecast,
    observed_reference_units,
)

EXPECTED_ORDER_VALUE_VERSION = "expected-order-value/2.1.1"

PLANNING_HORIZON_DAYS = 7.0

DEFAULT_RELATIVE_UNCERTAINTY = 0.25

TIER_FORECAST = "forecast"
TIER_OBSERVED_BASELINE = "observed_baseline"
TIER_NO_DEMAND = "no_demand"
TIER_NO_PRICE = "no_price"


@dataclass(frozen=True)
class PairOpportunity:
    retailer_id: str
    product_id: str
    tier: str
    probability_non_zero: float
    expected_units: float
    unit_price_rm: float
    expected_value_rm: float
    relative_uncertainty: float
    interval_lower_rm: float | None
    interval_upper_rm: float | None
    forecast_model: str
    forecast_status: str
    forecast_version: str
    classification: str
    observed_periods: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "retailerId": self.retailer_id,
            "productId": self.product_id,
            "tier": self.tier,
            "probabilityNonZero": self.probability_non_zero,
            "expectedUnits": round(self.expected_units, 4),
            "unitPriceRm": round(self.unit_price_rm, 4),
            "expectedValueRm": round(self.expected_value_rm, 4),
            "relativeUncertainty": round(self.relative_uncertainty, 6),
            "intervalLowerRm": (
                None
                if self.interval_lower_rm is None
                else round(self.interval_lower_rm, 4)
            ),
            "intervalUpperRm": (
                None
                if self.interval_upper_rm is None
                else round(self.interval_upper_rm, 4)
            ),
            "forecastModel": self.forecast_model,
            "forecastStatus": self.forecast_status,
            "forecastVersion": self.forecast_version,
            "classification": self.classification,
            "observedPeriods": self.observed_periods,
        }


@dataclass(frozen=True)
class RetailerOpportunity:
    retailer_id: str
    expected_order_value_rm: float
    relative_uncertainty: float
    relative_uncertainty_source: str
    pair_count: int
    priced_pair_count: int
    forecast_pair_count: int
    observed_baseline_pair_count: int
    no_demand_pair_count: int
    missing_price_pair_count: int
    cold_start_pair_count: int
    interval_pair_count: int
    definition_version: str = EXPECTED_ORDER_VALUE_VERSION
    forecast_version: str = FORECAST_MODELS_VERSION
    horizon_days: float = PLANNING_HORIZON_DAYS
    pairs: tuple[PairOpportunity, ...] = ()

    def value_from_forecast_share(self) -> float:
        if self.expected_order_value_rm <= 0:
            return 0.0
        forecast_value = sum(
            pair.expected_value_rm
            for pair in self.pairs
            if pair.tier == TIER_FORECAST
        )
        return min(1.0, forecast_value / self.expected_order_value_rm)

    def to_dict(self) -> dict[str, Any]:
        return {
            "retailerId": self.retailer_id,
            "expectedOrderValueRm": round(self.expected_order_value_rm, 4),
            "relativeUncertainty": round(self.relative_uncertainty, 6),
            "relativeUncertaintySource": self.relative_uncertainty_source,
            "pairCount": self.pair_count,
            "pricedPairCount": self.priced_pair_count,
            "forecastPairCount": self.forecast_pair_count,
            "observedBaselinePairCount": self.observed_baseline_pair_count,
            "noDemandPairCount": self.no_demand_pair_count,
            "missingPricePairCount": self.missing_price_pair_count,
            "coldStartPairCount": self.cold_start_pair_count,
            "intervalPairCount": self.interval_pair_count,
            "valueFromForecastShare": round(self.value_from_forecast_share(), 6),
            "expectedOrderValueVersion": self.definition_version,
            "pointSemantics": POINT_SEMANTICS,
            "forecastModelsVersion": self.forecast_version,
            "horizonDays": self.horizon_days,
        }


def pair_opportunity(
    quantities: Sequence[float],
    *,
    unit_price_rm: float,
    retailer_id: str = "",
    product_id: str = "",
    forecast: OperationalForecast | None = None,
    period_start: str = "",
    data_cutoff: str = "",
    generated_at: str = "",
) -> PairOpportunity:
    cleaned = [max(0.0, float(value)) for value in quantities]
    price = max(0.0, float(unit_price_rm))
    if forecast is None:
        forecast = build_operational_forecast(
            cleaned,
            product_id=product_id,
            retailer_id=retailer_id,
            period_start=period_start,
            data_cutoff=data_cutoff,
            generated_at=generated_at,
        )
    probability = forecast.probability_non_zero
    if forecast.is_usable:
        tier = TIER_FORECAST
        expected_units = forecast.units_for_value
    elif any(value > 0 for value in cleaned):
        tier = TIER_OBSERVED_BASELINE
        expected_units = observed_reference_units(cleaned)
        probability = (
            sum(1 for value in cleaned if value > 0) / len(cleaned)
            if cleaned
            else 0.0
        )
    else:
        tier = TIER_NO_DEMAND
        expected_units = 0.0
        probability = 0.0

    if price <= 0:
        if expected_units > 0:
            tier = TIER_NO_PRICE
        value = 0.0
    else:
        value = expected_units * price

    lower: float | None = None
    upper: float | None = None
    relative = DEFAULT_RELATIVE_UNCERTAINTY
    if tier == TIER_FORECAST:
        if forecast.lower is not None and forecast.upper is not None:
            point = float(forecast.point or 0.0)
            relative = (forecast.upper - forecast.lower) / (2.0 * point) if point > 0 else relative
            if price > 0:
                lower = max(0.0, forecast.lower) * price
                upper = max(0.0, forecast.upper) * price
        relative = max(0.0, min(1.0, relative))

    return PairOpportunity(
        retailer_id=retailer_id,
        product_id=product_id,
        tier=tier,
        probability_non_zero=round(probability, 6),
        expected_units=expected_units,
        unit_price_rm=price,
        expected_value_rm=value,
        relative_uncertainty=relative,
        interval_lower_rm=lower,
        interval_upper_rm=upper,
            forecast_model=forecast.model,
            forecast_status=forecast.status,
            forecast_version=forecast.model_version,
            classification=forecast.demand_class,
            observed_periods=len(cleaned),
    )


def _aggregate_uncertainty(
    pairs: Sequence[PairOpportunity], total: float
) -> tuple[float, str]:
    if total <= 0:
        return 0.0, "no_value"
    interval_pairs = [
        pair
        for pair in pairs
        if pair.interval_lower_rm is not None and pair.interval_upper_rm is not None
    ]
    if not interval_pairs:
        return DEFAULT_RELATIVE_UNCERTAINTY, "documented_default_no_interval"
    width = sum(
        (pair.interval_upper_rm or 0.0) - (pair.interval_lower_rm or 0.0)
        for pair in interval_pairs
    )
    return max(0.0, min(1.0, width / (2.0 * total))), "aggregate_interval"


def retailer_opportunities(
    pairs: Iterable[Mapping[str, Any]],
    *,
    unit_prices: Mapping[str, float],
    quantities_field: str = "weeklyQuantities",
    include_pair_detail: bool = True,
) -> tuple[RetailerOpportunity, ...]:
    grouped: dict[str, list[PairOpportunity]] = {}
    for row in pairs:
        retailer_id = str(row.get("retailerId") or "").strip()
        product_id = str(row.get("productId") or "").strip()
        if not retailer_id or not product_id:
            continue
        quantities = [float(value) for value in (row.get(quantities_field) or [])]
        grouped.setdefault(retailer_id, []).append(
            pair_opportunity(
                quantities,
                unit_price_rm=float(unit_prices.get(product_id) or 0.0),
                retailer_id=retailer_id,
                product_id=product_id,
            )
        )

    opportunities: list[RetailerOpportunity] = []
    for retailer_id in sorted(grouped):
        rows = grouped[retailer_id]
        priced = [
            pair
            for pair in rows
            if pair.tier in {TIER_FORECAST, TIER_OBSERVED_BASELINE}
        ]
        total = sum(pair.expected_value_rm for pair in priced)
        relative, source = _aggregate_uncertainty(priced, total)
        opportunities.append(
            RetailerOpportunity(
                retailer_id=retailer_id,
                expected_order_value_rm=total,
                relative_uncertainty=relative,
                relative_uncertainty_source=source,
                pair_count=len(rows),
                priced_pair_count=len(priced),
                forecast_pair_count=sum(
                    1 for pair in rows if pair.tier == TIER_FORECAST
                ),
                observed_baseline_pair_count=sum(
                    1 for pair in rows if pair.tier == TIER_OBSERVED_BASELINE
                ),
                no_demand_pair_count=sum(
                    1 for pair in rows if pair.tier == TIER_NO_DEMAND
                ),
                missing_price_pair_count=sum(
                    1 for pair in rows if pair.tier == TIER_NO_PRICE
                ),
                cold_start_pair_count=sum(
                    1 for pair in rows if pair.forecast_status != "ok"
                ),
                interval_pair_count=sum(
                    1
                    for pair in rows
                    if pair.interval_lower_rm is not None
                    and pair.interval_upper_rm is not None
                ),
                pairs=tuple(rows) if include_pair_detail else (),
            )
        )
    return tuple(opportunities)


__all__ = [
    "DEFAULT_RELATIVE_UNCERTAINTY",
    "EXPECTED_ORDER_VALUE_VERSION",
    "PLANNING_HORIZON_DAYS",
    "TIER_FORECAST",
    "TIER_NO_DEMAND",
    "TIER_NO_PRICE",
    "TIER_OBSERVED_BASELINE",
    "PairOpportunity",
    "RetailerOpportunity",
    "pair_opportunity",
    "retailer_opportunities",
]

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta
from typing import Any, Iterable, Mapping, Sequence

from ..ai_core.calendar import (
    DEFAULT_HISTORY_WEEKS,
    HISTORY_WINDOW_VERSION,
    HistoryWindow,
    completed_week_starts,
    week_start,
)
from ..ai_core.forecast_contract import (
    STATUS_INSUFFICIENT_HISTORY,
    STATUS_OK,
    OperationalForecast,
    build_operational_forecast,
)
from .normalization import normalize_firestore_inputs
from ..ai_core.forecast_models import SARIMA_MIN_PERIODS, SARIMA_INPUT_WEEKS

OPERATIONAL_SCOPE_PRODUCT = "product"
OPERATIONAL_SCOPE_RETAILER_PRODUCT = "retailer_product"


@dataclass(frozen=True)
class OperationalForecastSet:
    scope: str
    as_of: str
    period_start: str
    data_cutoff: str
    generated_at: str
    rows: tuple[OperationalForecast, ...]
    data_quality: dict[str, Any]
    history_weeks: int | None = None
    window_evaluated: bool | None = None

    @property
    def insufficient_history_count(self) -> int:
        return sum(1 for row in self.rows if not row.is_usable)

    def to_dict(self) -> dict[str, Any]:
        return {
            "scope": self.scope,
            "asOf": self.as_of,
            "periodStart": self.period_start,
            "dataCutoff": self.data_cutoff,
            "generatedAt": self.generated_at,
            "rowCount": len(self.rows),
            "insufficientHistoryCount": self.insufficient_history_count,
            "dataQuality": dict(self.data_quality),
            "historyWeeks": self.history_weeks,
            "historyWindowVersion": (
                None if self.history_weeks is None else HISTORY_WINDOW_VERSION
            ),
            "windowEvaluated": self.window_evaluated,
            "rows": [row.to_dict() for row in self.rows],
        }


def _weekly_quantities(series: Any, starts: tuple[date, ...]) -> tuple[float, ...]:
    by_week = {observation.week_start: observation for observation in series.observations}
    return tuple(
        float(by_week[start].quantity) if start in by_week else 0.0
        for start in starts
    )


def product_point_and_range(
    components: Sequence[OperationalForecast], *, method: str = "adaptive"
) -> tuple[float, float | None, float | None]:
    shares = [
        (float(component.point) if component.is_usable else 0.0)
        if method == "sarima"
        else component.units_for_value
        for component in components
    ]
    ranged = [
        component.lower is not None and component.upper is not None
        for component in components
    ]
    point = round(sum(shares), 4)
    if not any(ranged):
        return point, None, None
    lower = round(
        sum(
            float(component.lower)
            for component, has_range in zip(components, ranged)
            if has_range
        ),
        4,
    )
    upper = round(
        sum(
            float(component.upper) if has_range else share
            for component, has_range, share in zip(components, ranged, shares)
        ),
        4,
    )
    return point, min(point, lower), max(point, upper)


def _aggregate_product_row(
    components: list[OperationalForecast],
    *,
    product_id: str,
    product_name: str = "",
    period_start: date,
    data_cutoff: date,
    generated_at: datetime | str,
    method: str = "adaptive",
) -> OperationalForecast:
    modelled = [component for component in components if component.is_usable]
    observed = [
        component
        for component in components
        if not component.is_usable and component.reference_units > 0
    ]
    no_demand = [
        component
        for component in components
        if not component.is_usable and component.reference_units <= 0
    ]
    usable = bool(modelled)
    point, lower, upper = product_point_and_range(components, method=method)
    first = components[0]
    return OperationalForecast(
        scope_type=first.scope_type,
        retailer_id="",
        product_id=product_id,
        product_name=product_name or first.product_name,
        period_start=period_start.isoformat(),
        period_days=first.period_days,
        point=point if usable else None,
        point_semantics=first.point_semantics,
        probability_non_zero=None,
        lower=lower if usable else None,
        upper=upper if usable else None,
        demand_class=None,
        model="sarima" if method == "sarima" else None,
        model_version=first.model_version,
        status=STATUS_OK if usable else ("model_error" if any(component.status == "model_error" for component in components) else STATUS_INSUFFICIENT_HISTORY),
        observed_periods=max(component.observed_periods for component in components),
        non_zero_periods=sum(component.non_zero_periods for component in components),
        mean_non_zero_demand=round(
            sum(component.mean_non_zero_demand for component in components), 4
        ),
        reference_units=round(
            sum(component.reference_units for component in components), 4
        ),
        data_cutoff=data_cutoff.isoformat(),
        generated_at=generated_at if isinstance(generated_at, str) else generated_at.isoformat(),
        component_count=len(components),
        modelled_component_count=len(modelled),
        observed_component_count=len(observed),
        no_demand_component_count=len(no_demand),
    )


def _silent_product_row(
    *,
    product_id: str,
    product_name: str = "",
    period_start: date,
    data_cutoff: date,
    generated_at: datetime | str,
    method: str = "adaptive",
) -> OperationalForecast:
    record = build_operational_forecast(
        [],
        product_id=product_id,
        product_name=product_name,
        period_start=period_start,
        data_cutoff=data_cutoff,
        generated_at=generated_at,
        model="sarima" if method == "sarima" else None,
    )
    return replace(record, model=None, demand_class=None)


def build_operational_forecasts(
    *,
    orders: Iterable[Mapping[str, Any]],
    products: Iterable[Mapping[str, Any]],
    retailers: Iterable[Mapping[str, Any]],
    users: Iterable[Mapping[str, Any]],
    as_of: date | datetime,
    generated_at: datetime | str,
    scope: str = OPERATIONAL_SCOPE_PRODUCT,
    method: str = "adaptive",
    window: HistoryWindow | None = None,
) -> OperationalForecastSet:
    window = window or HistoryWindow(
        weeks=DEFAULT_HISTORY_WEEKS,
        requested=DEFAULT_HISTORY_WEEKS,
        source="default",
    )
    if scope not in {OPERATIONAL_SCOPE_PRODUCT, OPERATIONAL_SCOPE_RETAILER_PRODUCT}:
        raise ValueError("unknown operational forecast scope: " + str(scope))
    if method not in {"adaptive", "sarima"}:
        raise ValueError("unknown forecast method: " + str(method))

    normalized = normalize_firestore_inputs(
        orders=orders,
        products=products,
        retailers=retailers,
        users=users,
        as_of=as_of,
        history_weeks=SARIMA_INPUT_WEEKS if method == "sarima" else window.weeks,
    )
    starts = completed_week_starts(as_of, weeks=SARIMA_MIN_PERIODS if method == "sarima" else window.weeks)
    period_start = week_start(as_of)
    data_cutoff = period_start - timedelta(days=1)

    single_rows: list[OperationalForecast] = []
    by_product: dict[str, list[OperationalForecast]] = {}
    for series in normalized.series:
        training_starts = starts
        if method == "sarima":
            first = min((row.week_start for row in series.observations
                         if row.quantity > 0 or row.order_count > 0), default=None)
            training_starts = tuple(start for start in starts if first is not None and start >= first)
        record = build_operational_forecast(
            _weekly_quantities(series, training_starts),
            product_id=series.product_id,
            product_name=series.product_name,
            retailer_id=series.retailer_id,
            period_start=period_start,
            data_cutoff=data_cutoff,
            generated_at=generated_at,
            model="sarima" if method == "sarima" else None,
        )
        single_rows.append(record)
        by_product.setdefault(series.product_id, []).append(record)

    if scope == OPERATIONAL_SCOPE_RETAILER_PRODUCT:
        rows = tuple(sorted(single_rows, key=lambda row: (row.product_id, row.retailer_id)))
    else:
        catalogue_ids = sorted(set(normalized.products) | set(by_product))
        rows = tuple(
            _aggregate_product_row(
                by_product[product_id],
                product_id=product_id,
                product_name=(
                    normalized.products[product_id].product_name
                    if product_id in normalized.products
                    else ""
                ),
                period_start=period_start,
                data_cutoff=data_cutoff,
                generated_at=generated_at,
                method=method,
            )
            if by_product.get(product_id)
            else _silent_product_row(
                product_id=product_id,
                product_name=(
                    normalized.products[product_id].product_name
                    if product_id in normalized.products
                    else ""
                ),
                period_start=period_start,
                data_cutoff=data_cutoff,
                generated_at=generated_at,
                method=method,
            )
            for product_id in catalogue_ids
        )

    if method == "adaptive":
        rows = tuple(
            replace(
                row,
                history_weeks=window.weeks,
                history_window_version=HISTORY_WINDOW_VERSION,
                window_evaluated=window.evaluated,
            )
            for row in rows
        )

    return OperationalForecastSet(
        scope=scope,
        as_of=(as_of.isoformat() if not isinstance(as_of, str) else as_of),
        period_start=period_start.isoformat(),
        data_cutoff=data_cutoff.isoformat(),
        generated_at=generated_at if isinstance(generated_at, str) else generated_at.isoformat(),
        rows=rows,
        data_quality=dict(normalized.data_quality),
        history_weeks=window.weeks if method == "adaptive" else None,
        window_evaluated=window.evaluated if method == "adaptive" else None,
    )


__all__ = [
    "OPERATIONAL_SCOPE_PRODUCT",
    "OPERATIONAL_SCOPE_RETAILER_PRODUCT",
    "OperationalForecastSet",
    "build_operational_forecasts",
    "product_point_and_range",
]

from __future__ import annotations

import math
import statistics
import warnings
from dataclasses import dataclass, field
from typing import Any, Sequence

from .models import require_supported_series

FORECAST_MODELS_VERSION = "ai-forecast-models/1.3.1"
SARIMA_MODELS_VERSION = "ai-sarima-models/1.0.0"

SARIMA_SEASONAL_PERIOD = 52
SARIMA_MIN_PERIODS = 104
SARIMA_INPUT_WEEKS = 156
SARIMA_ORDER = (1, 0, 0)
SARIMA_SEASONAL_ORDER = (0, 1, 0, SARIMA_SEASONAL_PERIOD)

POINT_SEMANTICS = "unconditional_expected_demand_per_period"
POINT_SEMANTICS_BY_MODEL: dict[str, str] = {
    "sarima": POINT_SEMANTICS,
    "theta": POINT_SEMANTICS,
    "moving_average": POINT_SEMANTICS,
    "croston": POINT_SEMANTICS,
    "sba": POINT_SEMANTICS,
    "tsb": POINT_SEMANTICS,
    "naive_last": POINT_SEMANTICS,
    "naive_mean": POINT_SEMANTICS,
    "float_origin_constant": POINT_SEMANTICS,
}

ADI_CUTOFF = 1.32
CV2_CUTOFF = 0.49

CV_ESTIMATOR = "sample_stdev_non_zero_demand"

MIN_NON_ZERO_FOR_MODEL = 2
MIN_PERIODS_FOR_INTERVAL = 6
MAX_CALIBRATION_ORIGINS = 12
MIN_CALIBRATION_RESIDUALS = 4

DEFAULT_ALPHA = 0.2
SBA_ZERO_BIAS_FACTOR = 0.95
THETA = 2.0
DEFAULT_MOVING_AVERAGE_K = 4
DEFAULT_ADIDA_BUCKET_PERIODS = 4


def _clean(values: Sequence[float]) -> tuple[float, ...]:
    return tuple(
        max(0.0, value) for value in require_supported_series(values, "demand")
    )


def _non_zero(values: Sequence[float]) -> tuple[float, ...]:
    return tuple(value for value in values if value > 0)


def classify_demand(
    *,
    average_demand_interval: float,
    cv_squared: float,
    is_cold_start: bool = False,
) -> str:
    if is_cold_start:
        return "cold_start"
    if average_demand_interval >= ADI_CUTOFF and cv_squared >= CV2_CUTOFF:
        return "lumpy"
    if average_demand_interval >= ADI_CUTOFF:
        return "intermittent"
    if cv_squared >= CV2_CUTOFF:
        return "erratic"
    return "smooth"


@dataclass(frozen=True)
class DemandCharacterisation:
    classification: str
    periods: int
    non_zero_periods: int
    average_demand_interval: float
    cv_squared: float
    non_zero_rate: float
    mean_non_zero_demand: float
    is_cold_start: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "classification": self.classification,
            "periods": self.periods,
            "nonZeroPeriods": self.non_zero_periods,
            "averageDemandInterval": self.average_demand_interval,
            "cvSquared": self.cv_squared,
            "nonZeroRate": self.non_zero_rate,
            "meanNonZeroDemand": self.mean_non_zero_demand,
            "isColdStart": self.is_cold_start,
        }


def characterise_demand(values: Sequence[float]) -> DemandCharacterisation:
    cleaned = _clean(values)
    periods = len(cleaned)
    non_zero = _non_zero(cleaned)
    non_zero_periods = len(non_zero)
    if periods == 0 or non_zero_periods == 0:
        return DemandCharacterisation(
            classification="no_demand",
            periods=periods,
            non_zero_periods=0,
            average_demand_interval=0.0,
            cv_squared=0.0,
            non_zero_rate=0.0,
            mean_non_zero_demand=0.0,
            is_cold_start=True,
        )

    adi = periods / non_zero_periods
    mean_non_zero = statistics.fmean(non_zero)
    if non_zero_periods > 1 and mean_non_zero > 0:
        cv_squared = (statistics.stdev(non_zero) / mean_non_zero) ** 2
    else:
        cv_squared = 0.0
    non_zero_rate = non_zero_periods / periods
    cold_start = non_zero_periods < MIN_NON_ZERO_FOR_MODEL

    classification = classify_demand(
        average_demand_interval=adi,
        cv_squared=cv_squared,
        is_cold_start=cold_start,
    )

    return DemandCharacterisation(
        classification=classification,
        periods=periods,
        non_zero_periods=non_zero_periods,
        average_demand_interval=round(adi, 4),
        cv_squared=round(cv_squared, 4),
        non_zero_rate=round(non_zero_rate, 4),
        mean_non_zero_demand=round(mean_non_zero, 4),
        is_cold_start=cold_start,
    )


@dataclass(frozen=True)
class ForecastPoint:
    point: float
    probability_non_zero: float
    lower: float | None
    upper: float | None
    model: str
    version: str
    classification: str
    status: str
    parameters: dict[str, Any] = field(default_factory=dict)

    @property
    def is_usable(self) -> bool:
        return self.status == "ok"

    def to_dict(self) -> dict[str, Any]:
        return {
            "point": self.point,
            "pointSemantics": POINT_SEMANTICS_BY_MODEL.get(self.model, POINT_SEMANTICS),
            "probabilityNonZero": self.probability_non_zero,
            "lower": self.lower,
            "upper": self.upper,
            "model": self.model,
            "version": self.version,
            "classification": self.classification,
            "status": self.status,
            "parameters": dict(self.parameters),
        }


def _croston_components(
    values: Sequence[float], alpha: float
) -> tuple[float, float, float]:
    cleaned = _clean(values)
    size: float | None = None
    interval: float | None = None
    periods_since = 0
    non_zero = 0
    for value in cleaned:
        periods_since += 1
        if value <= 0:
            continue
        non_zero += 1
        size = value if size is None else alpha * value + (1 - alpha) * size
        if non_zero >= 2:
            interval = float(periods_since)
        periods_since = 0
    if non_zero >= 1 and interval is None:
        interval = 0.0
    occurrence_rate = non_zero / len(cleaned) if cleaned else 0.0
    return (size or 0.0), (interval or 0.0), occurrence_rate


def croston_forecast(values: Sequence[float], *, alpha: float = DEFAULT_ALPHA) -> float:
    size, interval, _ = _croston_components(values, alpha)
    if interval <= 0:
        return 0.0
    return size / interval


def sba_forecast(values: Sequence[float], *, alpha: float = DEFAULT_ALPHA) -> float:
    return SBA_ZERO_BIAS_FACTOR * croston_forecast(values, alpha=alpha)


def tsb_forecast(values: Sequence[float], *, alpha: float = DEFAULT_ALPHA) -> float:
    cleaned = _clean(values)
    size: float | None = None
    probability: float | None = None
    for value in cleaned:
        occurred = 1.0 if value > 0 else 0.0
        probability = (
            occurred
            if probability is None
            else alpha * occurred + (1 - alpha) * probability
        )
        if value > 0:
            size = value if size is None else alpha * value + (1 - alpha) * size
    if size is None or probability is None:
        return 0.0
    return probability * size


def moving_average_forecast(
    values: Sequence[float], *, k: int = DEFAULT_MOVING_AVERAGE_K
) -> float:
    cleaned = _clean(values)
    if not cleaned:
        return 0.0
    window = cleaned[-k:] if k > 0 else cleaned
    return statistics.fmean(window) if window else 0.0


def theta_forecast(values: Sequence[float], *, theta: float = THETA) -> float:
    cleaned = _clean(values)
    if not cleaned:
        return 0.0
    if len(cleaned) == 1:
        return cleaned[0]
    slope, intercept = _linear_fit(cleaned)
    level = intercept + slope * (len(cleaned) - 1)
    return level + (1.0 / theta) * slope


def _linear_fit(values: Sequence[float]) -> tuple[float, float]:
    n = len(values)
    if n < 2:
        return 0.0, values[0] if values else 0.0
    x_mean = (n - 1) / 2
    y_mean = statistics.fmean(values)
    denominator = sum((index - x_mean) ** 2 for index in range(n))
    if denominator == 0:
        return 0.0, y_mean
    numerator = sum(
        (index - x_mean) * (value - y_mean) for index, value in enumerate(values)
    )
    slope = numerator / denominator
    return slope, y_mean - slope * x_mean


def _smoothed_level(observations: Sequence[float], alpha: float) -> float:
    level = observations[0]
    for observation in observations[1:]:
        level = alpha * observation + (1 - alpha) * level
    return level


def ses_forecast(values: Sequence[float], *, alpha: float = DEFAULT_ALPHA) -> float:
    cleaned = _clean(values)
    if not cleaned:
        return 0.0
    return _smoothed_level(cleaned, alpha)


def _demand_sizes_and_gaps(
    cleaned: Sequence[float],
) -> tuple[list[float], list[float]]:
    sizes: list[float] = []
    gaps: list[float] = []
    periods_since = 0
    for value in cleaned:
        periods_since += 1
        if value > 0:
            if sizes:
                gaps.append(float(periods_since))
            sizes.append(value)
            periods_since = 0
    return sizes, gaps


def croston_smoothed_forecast(
    values: Sequence[float], *, alpha: float = DEFAULT_ALPHA
) -> float:
    cleaned = _clean(values)
    sizes, gaps = _demand_sizes_and_gaps(cleaned)
    if not sizes:
        return 0.0
    interval = _smoothed_level(gaps, alpha) if gaps else float(len(cleaned))
    return _smoothed_level(sizes, alpha) / interval


def sba_smoothed_forecast(
    values: Sequence[float], *, alpha: float = DEFAULT_ALPHA
) -> float:
    return (1 - alpha / 2) * croston_smoothed_forecast(values, alpha=alpha)


def adida_forecast(
    values: Sequence[float],
    *,
    bucket_periods: int = DEFAULT_ADIDA_BUCKET_PERIODS,
    alpha: float = DEFAULT_ALPHA,
) -> float:
    cleaned = _clean(values)
    if not cleaned:
        return 0.0
    whole = len(cleaned) - len(cleaned) % bucket_periods
    if whole == 0:
        return statistics.fmean(cleaned)
    recent = cleaned[len(cleaned) - whole:]
    bucket_totals = [
        sum(recent[start:start + bucket_periods])
        for start in range(0, whole, bucket_periods)
    ]
    return _smoothed_level(bucket_totals, alpha) / bucket_periods


def ses_drift_forecast(
    values: Sequence[float], *, alpha: float = DEFAULT_ALPHA
) -> float:
    cleaned = _clean(values)
    if not cleaned:
        return 0.0
    level = _smoothed_level(cleaned, alpha)
    periods = len(cleaned)
    if periods < 2:
        return level
    slope, _ = _linear_fit(cleaned)
    return level + 0.5 * slope * (1 - (1 - alpha) ** periods) / alpha


def _point_for(
    model: str, values: Sequence[float], parameters: dict[str, Any]
) -> float:
    if model == "naive_last":
        return values[-1] if values else 0.0
    if model == "naive_mean":
        cleaned = _clean(values)
        return statistics.fmean(cleaned) if cleaned else 0.0
    if model == "float_origin_constant":
        return values[-1] if values else 0.0
    if model == "croston":
        return croston_forecast(values, alpha=parameters["alpha"])
    if model == "sba":
        return sba_forecast(values, alpha=parameters["alpha"])
    if model == "tsb":
        return tsb_forecast(values, alpha=parameters["alpha"])
    if model == "moving_average":
        return moving_average_forecast(values, k=parameters["k"])
    if model == "theta":
        return theta_forecast(values, theta=parameters["theta"])
    raise ValueError(f"unknown forecast model: {model}")


def select_forecast_model(
    characterisation: DemandCharacterisation,
) -> tuple[str, dict[str, Any]]:
    parameters: dict[str, Any] = {"alpha": DEFAULT_ALPHA}
    if characterisation.is_cold_start:
        return "naive_last", parameters
    if characterisation.classification == "lumpy":
        return "croston", parameters
    if characterisation.classification == "intermittent":
        return "tsb", parameters
    if characterisation.classification == "erratic":
        return "moving_average", {"k": DEFAULT_MOVING_AVERAGE_K}
    return "theta", {"theta": THETA}



def _sarima_forecast(
    values: Sequence[float], characterisation: DemandCharacterisation,
    *, with_interval: bool,
) -> ForecastPoint:
    parameters = {"order": SARIMA_ORDER, "seasonal_order": SARIMA_SEASONAL_ORDER,
                  "minimumPeriods": SARIMA_MIN_PERIODS, "intervalMethod": "sarima_gaussian_80"}
    def unavailable(status: str) -> ForecastPoint:
        return ForecastPoint(point=0.0, probability_non_zero=0.0, lower=None,
            upper=None, model="sarima", version=SARIMA_MODELS_VERSION,
            classification=characterisation.classification, status=status, parameters=parameters)

    if len(values) < SARIMA_MIN_PERIODS or characterisation.is_cold_start:
        return unavailable("insufficient_history")
    from statsmodels.tsa.statespace.sarimax import SARIMAX
    from numpy.linalg import LinAlgError
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            result = SARIMAX(values, order=SARIMA_ORDER,
                seasonal_order=SARIMA_SEASONAL_ORDER, trend="n",
                simple_differencing=True, enforce_stationarity=True,
                enforce_invertibility=True).fit(disp=False, maxiter=100)
        if not result.mle_retvals.get("converged", False):
            return unavailable("model_error")
        prediction = result.get_forecast(steps=1)
        seasonal_level = values[-SARIMA_SEASONAL_PERIOD]
        raw_point = float(prediction.predicted_mean[0]) + seasonal_level
        if not math.isfinite(raw_point):
            return unavailable("model_error")
        point = round(max(0.0, raw_point), 4)
        lower = upper = None
        if with_interval:
            interval = prediction.conf_int(alpha=0.2)[0]
            raw_lower, raw_upper = (float(bound) + seasonal_level for bound in interval)
            if not all(math.isfinite(bound) for bound in (raw_lower, raw_upper)):
                return unavailable("model_error")
            lower = round(max(0.0, raw_lower), 4)
            upper = round(max(point, raw_upper), 4)
        return ForecastPoint(point=point,
            probability_non_zero=_probability_non_zero("sarima", values),
            lower=lower, upper=upper, model="sarima", version=SARIMA_MODELS_VERSION,
            classification=characterisation.classification, status="ok", parameters=parameters)
    except (ValueError, ArithmeticError, RuntimeError, LinAlgError):
        return unavailable("model_error")


def _probability_non_zero(model: str, values: Sequence[float]) -> float:
    if not values:
        return 0.0
    if model == "croston":
        _, _, occurrence_rate = _croston_components(values, DEFAULT_ALPHA)
        return round(max(0.0, min(1.0, occurrence_rate)), 4)
    window = values[-4:]
    if not window:
        return 0.0
    rate = sum(1 for value in window if value > 0) / len(window)
    return round(max(0.0, min(1.0, rate)), 4)


def _calibration_residuals(
    model: str, values: Sequence[float], parameters: dict[str, Any]
) -> list[float]:
    residuals: list[float] = []
    start = max(MIN_PERIODS_FOR_INTERVAL // 2, 3)
    if len(values) > start + MAX_CALIBRATION_ORIGINS:
        start = len(values) - MAX_CALIBRATION_ORIGINS
    for index in range(start, len(values)):
        train = values[:index]
        if not train:
            continue
        residuals.append(values[index] - _point_for(model, train, parameters))
    return residuals


def _quantile(sorted_values: Sequence[float], q: float) -> float:
    if not sorted_values:
        raise ValueError("quantile of empty sequence")
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = q * (len(sorted_values) - 1)
    lower_index = math.floor(position)
    upper_index = math.ceil(position)
    if lower_index == upper_index:
        return sorted_values[int(position)]
    weight = position - lower_index
    return (
        sorted_values[lower_index] * (1 - weight)
        + sorted_values[upper_index] * weight
    )


def forecast_next(
    values: Sequence[float],
    *,
    model: str | None = None,
    parameters: dict[str, Any] | None = None,
    characterisation: DemandCharacterisation | None = None,
    with_interval: bool = True,
) -> ForecastPoint:
    cleaned = _clean(values)
    if characterisation is None:
        characterisation = characterise_demand(cleaned)
    chosen_model, chosen_parameters = select_forecast_model(characterisation)
    if model == "sarima":
        return _sarima_forecast(cleaned, characterisation, with_interval=with_interval)
    if model is not None:
        chosen_model = model
        chosen_parameters = dict(parameters or {"alpha": DEFAULT_ALPHA})
        if chosen_model == "moving_average":
            chosen_parameters.setdefault("k", DEFAULT_MOVING_AVERAGE_K)
        if chosen_model == "theta":
            chosen_parameters.setdefault("theta", THETA)
        if chosen_model in {"croston", "sba", "tsb"}:
            chosen_parameters.setdefault("alpha", DEFAULT_ALPHA)

    if not cleaned:
        return ForecastPoint(
            point=0.0,
            probability_non_zero=0.0,
            lower=None,
            upper=None,
            model=chosen_model,
            version=FORECAST_MODELS_VERSION,
            classification="no_demand",
            status="insufficient_history",
            parameters=chosen_parameters,
        )

    point = round(max(0.0, _point_for(chosen_model, cleaned, chosen_parameters)), 4)
    probability = _probability_non_zero(chosen_model, cleaned)
    lower: float | None = None
    upper: float | None = None
    if with_interval and len(cleaned) >= MIN_PERIODS_FOR_INTERVAL:
        residuals = sorted(
            _calibration_residuals(chosen_model, cleaned, chosen_parameters)
        )
        if len(residuals) >= MIN_CALIBRATION_RESIDUALS:
            lower = round(
                max(0.0, point + min(0.0, _quantile(residuals, 0.1))), 4
            )
            upper = round(point + max(0.0, _quantile(residuals, 0.9)), 4)

    status = "insufficient_history" if characterisation.is_cold_start else "ok"
    return ForecastPoint(
        point=point,
        probability_non_zero=probability,
        lower=lower,
        upper=upper,
        model=chosen_model,
        version=FORECAST_MODELS_VERSION,
        classification=characterisation.classification,
        status=status,
        parameters={
            **chosen_parameters,
            "classification": characterisation.classification,
            "averageDemandInterval": characterisation.average_demand_interval,
            "cvSquared": characterisation.cv_squared,
            "nonZeroRate": characterisation.non_zero_rate,
        },
    )


def mase(
    actuals: Sequence[float],
    predictions: Sequence[float],
    train: Sequence[float],
    *,
    seasonality: int = 1,
) -> tuple[float | None, float | None]:
    if len(actuals) != len(predictions):
        raise ValueError("actuals and predictions must have equal length")
    pairs = list(zip(actuals, predictions))
    if not pairs:
        return None, None
    clean_train = _clean(train)
    if len(clean_train) <= seasonality:
        return None, None
    differences = [
        abs(clean_train[index] - clean_train[index - seasonality])
        for index in range(seasonality, len(clean_train))
    ]
    if not differences:
        return None, None
    scale = statistics.fmean(differences)
    if scale == 0:
        return None, 0.0
    error = statistics.fmean([abs(actual - prediction) for actual, prediction in pairs])
    return error / scale, scale


__all__ = [
    "ADI_CUTOFF",
    "CV_ESTIMATOR",
    "CV2_CUTOFF",
    "DEFAULT_ALPHA",
    "DEFAULT_MOVING_AVERAGE_K",
    "FORECAST_MODELS_VERSION",
    "DemandCharacterisation",
    "ForecastPoint",
    "adida_forecast",
    "characterise_demand",
    "classify_demand",
    "croston_forecast",
    "croston_smoothed_forecast",
    "forecast_next",
    "mase",
    "moving_average_forecast",
    "sba_forecast",
    "sba_smoothed_forecast",
    "select_forecast_model",
    "ses_drift_forecast",
    "ses_forecast",
    "theta_forecast",
    "tsb_forecast",
]

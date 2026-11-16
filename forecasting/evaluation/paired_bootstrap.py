from __future__ import annotations

import hashlib
import random
import statistics
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Sequence

DEFAULT_BOOTSTRAP_SEED = 20260918
DEFAULT_BOOTSTRAP_DRAWS = 2000


def _stream(seed: int, label: str) -> random.Random:
    digest = hashlib.sha256(f"{seed}::{label}".encode("utf-8")).hexdigest()
    return random.Random(int(digest[:16], 16))


def _percentile(values: Sequence[float], q: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("percentile of an empty sequence")
    if len(ordered) == 1:
        return ordered[0]
    position = q * (len(ordered) - 1)
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    weight = position - low
    return ordered[low] * (1.0 - weight) + ordered[high] * weight


@dataclass(frozen=True)
class Interval:
    value: float
    lower: float
    upper: float
    draws: int

    @property
    def excludes_zero(self) -> bool:
        return self.lower > 0.0 or self.upper < 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "value": round(self.value, 6),
            "lower": round(self.lower, 6),
            "upper": round(self.upper, 6),
            "draws": self.draws,
        }


def _pooled(
    rows: Sequence[tuple[float, float]],
    transform: Callable[[float], float] | None = None,
) -> float | None:
    total_error = sum(error for error, _ in rows)
    total_scale = sum(scale for _, scale in rows)
    if total_scale <= 0:
        return None
    ratio = total_error / total_scale
    return ratio if transform is None else transform(ratio)


def ratio_metric_intervals(
    per_series: Mapping[str, Sequence[tuple[float, float]]],
    *,
    seed: int = DEFAULT_BOOTSTRAP_SEED,
    draws: int = DEFAULT_BOOTSTRAP_DRAWS,
    transform: Callable[[float], float] | None = None,
) -> dict[str, Interval]:
    names = sorted(per_series)
    if not names:
        return {}
    length = len(per_series[names[0]])
    if length == 0:
        return {}
    rng = _stream(seed, "ratio:" + ",".join(names))
    samples: dict[str, list[float]] = {name: [] for name in names}
    for _ in range(max(1, draws)):
        indices = [rng.randrange(length) for _ in range(length)]
        for name in names:
            rows = per_series[name]
            value = _pooled([rows[index] for index in indices], transform)
            if value is not None:
                samples[name].append(value)
    result: dict[str, Interval] = {}
    for name in names:
        observed = _pooled(list(per_series[name]), transform)
        values = samples[name] or [observed or 0.0]
        result[name] = Interval(
            value=observed if observed is not None else 0.0,
            lower=round(_percentile(values, 0.025), 6),
            upper=round(_percentile(values, 0.975), 6),
            draws=len(values),
        )
    return result


def paired_ratio_differences(
    per_series: Mapping[str, Sequence[tuple[float, float]]],
    *,
    reference: str,
    seed: int = DEFAULT_BOOTSTRAP_SEED,
    draws: int = DEFAULT_BOOTSTRAP_DRAWS,
    transform: Callable[[float], float] | None = None,
) -> dict[str, dict[str, Any]]:
    names = sorted(name for name in per_series if name != reference)
    if reference not in per_series or not names:
        return {}
    length = len(per_series[reference])
    if length == 0:
        return {}
    rng = _stream(seed, "paired:" + reference + ":" + ",".join(names))
    diffs: dict[str, list[float]] = {name: [] for name in names}
    for _ in range(max(1, draws)):
        indices = [rng.randrange(length) for _ in range(length)]
        base = _pooled([per_series[reference][index] for index in indices], transform)
        if base is None:
            continue
        for name in names:
            other = _pooled([per_series[name][index] for index in indices], transform)
            if other is None:
                continue
            diffs[name].append(other - base)
    result: dict[str, dict[str, Any]] = {}
    observed_base = _pooled(list(per_series[reference]), transform)
    for name in names:
        observed = _pooled(list(per_series[name]), transform)
        if observed is None or observed_base is None or not diffs[name]:
            result[name] = {
                "reference": reference,
                "value": None,
                "lower": None,
                "upper": None,
                "draws": 0,
                "excludesZero": None,
                "drawsBelowZero": 0,
            }
            continue
        values = diffs[name]
        interval = Interval(
            value=observed - observed_base,
            lower=round(_percentile(values, 0.025), 6),
            upper=round(_percentile(values, 0.975), 6),
            draws=len(values),
        )
        result[name] = {
            "reference": reference,
            "value": round(interval.value, 6),
            "lower": interval.lower,
            "upper": interval.upper,
            "draws": interval.draws,
            "excludesZero": interval.excludes_zero,
            "drawsBelowZero": sum(1 for value in values if value < 0.0),
        }
    return result


def mean_difference_intervals(
    samples: Mapping[str, Sequence[float]],
    *,
    reference: str,
    seed: int = DEFAULT_BOOTSTRAP_SEED,
    draws: int = DEFAULT_BOOTSTRAP_DRAWS,
) -> dict[str, dict[str, Any]]:
    names = sorted(name for name in samples if name != reference)
    if reference not in samples or not names:
        return {}
    length = len(samples[reference])
    if length == 0:
        return {}
    rng = _stream(seed, "mean:" + reference + ":" + ",".join(names))
    diffs: dict[str, list[float]] = {name: [] for name in names}
    for _ in range(max(1, draws)):
        indices = [rng.randrange(length) for _ in range(length)]
        base = statistics.fmean(samples[reference][index] for index in indices)
        for name in names:
            other = statistics.fmean(samples[name][index] for index in indices)
            diffs[name].append(other - base)
    result: dict[str, dict[str, Any]] = {}
    base_mean = statistics.fmean(samples[reference])
    for name in names:
        values = diffs[name]
        if not values:
            continue
        lower = round(_percentile(values, 0.025), 4)
        upper = round(_percentile(values, 0.975), 4)
        result[name] = {
            "reference": reference,
            "value": round(statistics.fmean(samples[name]) - base_mean, 4),
            "lower": lower,
            "upper": upper,
            "draws": len(values),
            "excludesZero": lower > 0.0 or upper < 0.0,
            "drawsBelowZero": sum(1 for value in values if value < 0.0),
        }
    return result


__all__ = [
    "DEFAULT_BOOTSTRAP_DRAWS",
    "DEFAULT_BOOTSTRAP_SEED",
    "Interval",
    "mean_difference_intervals",
    "paired_ratio_differences",
    "ratio_metric_intervals",
]

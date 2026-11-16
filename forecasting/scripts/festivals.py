from __future__ import annotations

FESTIVAL_MONTHS: dict[str, dict[int, int]] = {
    "cny": {2024: 2, 2025: 1, 2026: 2, 2027: 2},
    "raya": {2024: 4, 2025: 3, 2026: 3, 2027: 3},
    "gawai": {2024: 6, 2025: 6, 2026: 6, 2027: 6},
    "christmas": {2024: 12, 2025: 12, 2026: 12, 2027: 12},
}

FESTIVAL_LABELS = {
    "cny": "Chinese New Year",
    "raya": "Hari Raya",
    "gawai": "Gawai",
    "christmas": "Christmas",
}

FESTIVAL_WEIGHT = 1.0
PREPARATION_WEIGHT = 0.6


def festival_signal(year: int, month: int, festival: str) -> float:
    months = FESTIVAL_MONTHS.get(festival, {})
    if months.get(year) == month:
        return FESTIVAL_WEIGHT
    prep_target = _prep_year_month_inverse(year, month)
    if months.get(prep_target[0]) == prep_target[1]:
        return PREPARATION_WEIGHT
    return 0.0


def _prep_year_month_inverse(year: int, month: int) -> tuple[int, int]:
    return (year + 1, 1) if month == 12 else (year, month + 1)


def festival_tags(year: int, month: int) -> list[str]:
    tags: list[str] = []
    for key, months in FESTIVAL_MONTHS.items():
        label = FESTIVAL_LABELS[key]
        if months.get(year) == month:
            tags.append(label)
            continue
        nxt_year, nxt_month = _prep_year_month_inverse(year, month)
        if months.get(nxt_year) == nxt_month:
            tags.append(f"{label} preparation")
    return tags


def exogenous_row(year: int, month: int) -> dict[str, float]:
    return {f"x_{key}": festival_signal(year, month, key) for key in FESTIVAL_MONTHS}


EXOG_COLUMNS = [f"x_{key}" for key in FESTIVAL_MONTHS]

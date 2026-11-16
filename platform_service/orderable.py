from __future__ import annotations

from typing import Any, Mapping

UNAVAILABLE_STATUSES = frozenset(
    {
        "false", "no", "n", "0", "hide", "hidden", "inactive", "disabled",
        "suspended", "retired", "archived", "discontinued", "deleted",
    }
)


def _text(value: Any) -> str:
    if value is None:
        return ""
    text = ("true" if value else "false") if isinstance(value, bool) else str(value)
    text = text.strip()
    return "" if text.lower() == "null" else text


def _explicitly_false(raw: Any) -> bool:
    if raw is False:
        return True
    if isinstance(raw, (int, float)) and not isinstance(raw, bool) and raw == 0:
        return True
    return _text(raw).lower() in UNAVAILABLE_STATUSES


def is_orderable(product: Mapping[str, Any], doc_id: str = "") -> bool:
    raw = product.get("isVisible")
    if raw is None:
        raw = product.get("visible")
    if _explicitly_false(raw):
        return False
    canonical = "" if product.get("status") is None else str(product["status"]).strip()
    status = (
        canonical
        if canonical
        else ("" if product.get("productStatus") is None else str(product["productStatus"]))
    )
    return status.strip().lower() not in UNAVAILABLE_STATUSES

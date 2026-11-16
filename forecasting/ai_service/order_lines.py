from __future__ import annotations

import re
from typing import Any, Mapping


_PRODUCT_ID = re.compile(r"^[A-Za-z0-9_-]{1,200}$")
_ENCODED_NAME = re.compile(r"^[A-Za-z0-9_-]{1,800}$")


def authoritative_order_items(order: Mapping[str, Any]) -> list[dict[str, Any]]:
    if order.get("commercialSchemaVersion") != 1:
        raw_items = order.get("items")
        if not isinstance(raw_items, (list, tuple)):
            return []
        return [dict(item) for item in raw_items if isinstance(item, Mapping)]

    raw_lines = order.get("commercialLines")
    if not isinstance(raw_lines, (list, tuple)) or not 1 <= len(raw_lines) <= 25:
        return []

    result: list[dict[str, Any]] = []
    for raw_line in raw_lines:
        if not isinstance(raw_line, str):
            return []
        parts = raw_line.split("~")
        if (
            len(parts) != 4
            or _PRODUCT_ID.fullmatch(parts[0]) is None
            or _ENCODED_NAME.fullmatch(parts[1]) is None
        ):
            return []
        try:
            quantity = int(parts[2])
            unit_price_cents = int(parts[3])
        except ValueError:
            return []
        if not 1 <= quantity <= 5 or not 1 <= unit_price_cents <= 999_999_999:
            return []
        result.append(
            {
                "productId": parts[0],
                "qty": quantity,
                "price": unit_price_cents / 100,
            }
        )
    return result

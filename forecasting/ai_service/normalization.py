from __future__ import annotations

import math
import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any, Iterable, Mapping

from forecasting.ai_core import (
    RetailerProductSeries,
    WeeklyObservation,
    completed_week_starts,
    week_start,
)
from forecasting.ai_core.calendar import as_kuching_date
from forecasting.ai_core.models import MAX_SUPPORTED_MAGNITUDE
from forecasting.ai_service.order_lines import authoritative_order_items


NON_DEMAND_ORDER_STATUSES = frozenset(
    {"cancelled", "canceled", "rejected", "draft", "deleted", "held_for_review"}
)


_DEMO_FLAG_FIELDS = ("isDemo", "is_demo", "demo")
_DEMO_CONTEXT_FIELDS = ("environment", "source", "dataSource", "data_source")
_DEMO_IDENTITY_FIELDS = (
    "docId",
    "id",
    "retailerId",
    "productId",
    "itemCode",
    "planId",
    "code",
    "retailerCode",
    "sku",
    "optimisationMethod",
)
_DEMO_CONTEXT_TOKENS = frozenset({"demo", "seed", "test"})
_DEMO_IDENTITY_PREFIXES = ("ai-1", "ai1", "ai_1", "demo")


def is_demo_record(row: Mapping[str, Any]) -> bool:
    for field in _DEMO_FLAG_FIELDS:
        value = row.get(field)
        if isinstance(value, bool) and value:
            return True
        if isinstance(value, str) and value.strip().lower() == "true":
            return True

    for field in _DEMO_CONTEXT_FIELDS:
        value = _text(row.get(field)).lower()
        if value and (
            _DEMO_CONTEXT_TOKENS.intersection(re.findall(r"[a-z0-9]+", value))
            or "ai1_demo" in value
        ):
            return True

    for field in _DEMO_IDENTITY_FIELDS:
        value = _text(row.get(field)).lower()
        if _has_demo_identity_marker(value):
            return True
    return False


def _has_demo_identity_marker(value: str) -> bool:
    for prefix in _DEMO_IDENTITY_PREFIXES:
        if value == prefix:
            return True
        if value.startswith(prefix) and len(value) > len(prefix):
            return value[len(prefix)] in "-_:\t\n\r "
    return False


def _text(value: Any) -> str:
    text = "" if value is None else str(value).strip()
    return "" if text.lower() in {"", "none", "null", "n/a", "na"} else text


def _first_text(row: Mapping[str, Any], fields: Iterable[str]) -> str:
    for field in fields:
        value = _text(row.get(field))
        if value:
            return value
    return ""


def _number(value: Any) -> float:
    if isinstance(value, bool) or value is None:
        return 0.0
    try:
        if isinstance(value, (int, float)):
            number = float(value)
        else:
            cleaned = str(value).replace(",", "").replace("RM", "").strip()
            number = float(cleaned)
    except (OverflowError, TypeError, ValueError):
        return 0.0
    if not math.isfinite(number) or abs(number) > MAX_SUPPORTED_MAGNITUDE:
        return 0.0
    return number


def _moment(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        return value
    if value is None:
        return None
    to_datetime = getattr(value, "to_datetime", None)
    if callable(to_datetime):
        converted = to_datetime()
        return converted if isinstance(converted, datetime) else None
    to_date = getattr(value, "toDate", None)
    if callable(to_date):
        converted = to_date()
        return converted if isinstance(converted, datetime) else None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def earliest_order_date(orders: Iterable[Mapping[str, Any]]) -> date | None:
    earliest: date | None = None
    for order in orders:
        moment = _moment(order.get("submittedAt"))
        if moment is None:
            continue
        day = as_kuching_date(moment)
        if earliest is None or day < earliest:
            earliest = day
    return earliest


def _alias(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "", _text(value).lower())


def _unique_alias_map(
    rows: Iterable[Mapping[str, Any]],
    *,
    id_fields: tuple[str, ...],
    alias_fields: tuple[str, ...],
) -> dict[str, str]:
    candidates: dict[str, set[str]] = defaultdict(set)
    for row in rows:
        entity_id = _first_text(row, id_fields)
        if not entity_id:
            continue
        for field in alias_fields:
            alias = _alias(row.get(field))
            if alias:
                candidates[alias].add(entity_id)
    return {
        alias: next(iter(ids))
        for alias, ids in candidates.items()
        if len(ids) == 1
    }


@dataclass(frozen=True)
class ProductRecord:
    product_id: str
    product_name: str
    unit_price_rm: float
    is_demo: bool
    packing_size: str
    unit_of_measure: str


@dataclass(frozen=True)
class RetailerRecord:
    retailer_id: str
    retailer_name: str
    salesman_uid: str
    salesman_code: str
    branch_id: str
    has_coordinates: bool
    is_demo: bool
    is_retired: bool = False
    latitude: float | None = None
    longitude: float | None = None


@dataclass(frozen=True)
class NormalizedData:
    series: tuple[RetailerProductSeries, ...]
    products: dict[str, ProductRecord]
    retailers: dict[str, RetailerRecord]
    data_quality: dict[str, Any]


def _coordinate(value: Any, limit: float) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (OverflowError, TypeError, ValueError):
        return None
    if not math.isfinite(number) or number == 0.0 or not (-limit <= number <= limit):
        return None
    return number


def _retailer_coordinates(
    row: Mapping[str, Any],
) -> tuple[float | None, float | None]:
    location = row.get("location")
    latitude = _coordinate(
        row.get("latitude")
        or row.get("lat")
        or getattr(location, "latitude", None),
        90.0,
    )
    longitude = _coordinate(
        row.get("longitude")
        or row.get("lng")
        or getattr(location, "longitude", None),
        180.0,
    )
    return latitude, longitude


def normalize_firestore_inputs(
    *,
    orders: Iterable[Mapping[str, Any]],
    products: Iterable[Mapping[str, Any]],
    retailers: Iterable[Mapping[str, Any]],
    users: Iterable[Mapping[str, Any]],
    as_of: date | datetime,
    history_weeks: int = 8,
) -> NormalizedData:
    product_rows = [dict(row) for row in products]
    retailer_rows = [dict(row) for row in retailers]
    user_rows = [dict(row) for row in users]

    product_aliases = _unique_alias_map(
        product_rows,
        id_fields=("productId", "itemId", "docId"),
        alias_fields=(
            "productId",
            "itemId",
            "productName",
            "product_name",
            "itemName",
            "displayName",
            "name",
            "barcode",
            "itemBarcode",
        ),
    )
    retailer_aliases = _unique_alias_map(
        retailer_rows,
        id_fields=("retailerId", "retailer_id", "retailerCode", "docId"),
        alias_fields=(
            "retailerId",
            "retailer_id",
            "retailerCode",
            "retailerName",
            "retailer_name",
            "name",
        ),
    )
    user_aliases = _unique_alias_map(
        user_rows,
        id_fields=("uid", "docId"),
        alias_fields=("uid", "employeeCode", "staffId", "userId", "docId"),
    )
    users_by_uid = {
        _first_text(row, ("uid", "docId")): row
        for row in user_rows
        if _first_text(row, ("uid", "docId"))
    }

    product_records: dict[str, ProductRecord] = {}
    for row in product_rows:
        product_id = _first_text(row, ("productId", "itemId", "docId"))
        if not product_id:
            continue
        product_records[product_id] = ProductRecord(
            product_id=product_id,
            product_name=_first_text(
                row,
                ("productName", "product_name", "itemName", "displayName", "name"),
            ),
            unit_price_rm=_number(
                row.get("unitPrice")
                or row.get("price")
                or row.get("priceGuide")
                or row.get("sellingPrice")
            ),
            is_demo=is_demo_record(row),
            packing_size=_first_text(row, ("packingSize", "packagingSize")),
            unit_of_measure=_first_text(
                row, ("uom", "uomLabel", "unitOfMeasure")
            ),
        )

    retailer_records: dict[str, RetailerRecord] = {}
    for row in retailer_rows:
        retailer_id = _first_text(
            row,
            ("retailerId", "retailer_id", "retailerCode", "docId"),
        )
        if not retailer_id:
            continue
        salesman_code = _first_text(
            row,
            (
                "assignedSalesmanId",
                "assigned_salesman_id",
                "salesmanCode",
                "employeeCode",
            ),
        )
        salesman_uid = (
            user_aliases.get(_alias(salesman_code), "") if salesman_code else ""
        ) or _first_text(
            row,
            ("assignedSalesmanUid", "salesmanUid"),
        )
        linked_user = users_by_uid.get(salesman_uid, {})
        latitude, longitude = _retailer_coordinates(row)
        retailer_records[retailer_id] = RetailerRecord(
            retailer_id=retailer_id,
            retailer_name=_first_text(
                row,
                ("retailerName", "retailer_name", "name"),
            ),
            salesman_uid=salesman_uid,
            salesman_code=salesman_code
            or _first_text(linked_user, ("employeeCode", "staffId")),
            branch_id=_first_text(row, ("branchId", "branch_id"))
            or _first_text(linked_user, ("branchId", "branch_id")),
            has_coordinates=latitude is not None and longitude is not None,
            is_demo=is_demo_record(row),
            is_retired=(
                _first_text(row, ("status", "retailerStatus")).lower() == "retired"
                or row.get("retiredAt") is not None
            ),
            latitude=latitude,
            longitude=longitude,
        )

    starts = completed_week_starts(as_of, weeks=history_weeks)
    allowed_weeks = set(starts)
    aggregates: dict[tuple[str, str, date], dict[str, float | int]] = defaultdict(
        lambda: {"quantity": 0.0, "revenue": 0.0, "orders": 0}
    )
    pair_metadata: dict[tuple[str, str], dict[str, str]] = {}
    seen_order_pairs: set[tuple[str, str, str, date]] = set()
    missing_price_pairs: set[tuple[str, str]] = set()
    counters = {
        "ordersScanned": 0,
        "ordersSkippedStatus": 0,
        "ordersMissingDate": 0,
        "ordersMissingRetailer": 0,
        "itemsScanned": 0,
        "itemsUnresolvedProduct": 0,
        "itemsInvalidQuantity": 0,
        "itemsInvalidAmount": 0,
        "itemsMissingPrice": 0,
    }

    for position, raw_order in enumerate(orders):
        order = dict(raw_order)
        order_is_demo = is_demo_record(order)
        counters["ordersScanned"] += 1
        status = _text(order.get("status")).lower()
        if status in NON_DEMAND_ORDER_STATUSES:
            counters["ordersSkippedStatus"] += 1
            continue
        submitted_at = _moment(
            order.get("submittedAt")
            or order.get("orderDate")
            or order.get("createdAt")
        )
        if submitted_at is None:
            counters["ordersMissingDate"] += 1
            continue
        order_week = week_start(submitted_at)
        if order_week not in allowed_weeks:
            continue

        retailer_id = _first_text(
            order,
            ("retailerId", "retailer_id", "retailerCode"),
        )
        if not retailer_id:
            retailer_name_alias = _alias(
                _first_text(order, ("retailerName", "retailer_name", "outlet"))
            )
            retailer_id = retailer_aliases.get(retailer_name_alias, "")
        if not retailer_id:
            counters["ordersMissingRetailer"] += 1
            continue
        retailer = retailer_records.get(
            retailer_id,
            RetailerRecord(retailer_id, "", "", "", "", False, False),
        )
        order_id = _first_text(order, ("orderId", "docId")) or f"row-{position}"
        items = authoritative_order_items(order)

        for raw_item in items:
            if not isinstance(raw_item, Mapping):
                continue
            item = dict(raw_item)
            item_is_demo = is_demo_record(item)
            counters["itemsScanned"] += 1
            product_id = _first_text(
                item,
                ("productId", "itemId", "productCode", "sku"),
            )
            if not product_id:
                product_alias = _alias(
                    _first_text(
                        item,
                        ("productName", "name", "itemName", "barcode"),
                    )
                )
                product_id = product_aliases.get(product_alias, "")
            if not product_id or product_id not in product_records:
                counters["itemsUnresolvedProduct"] += 1
                continue

            quantity = _number(
                item.get("qty")
                or item.get("quantity")
                or item.get("orderQty")
                or item.get("boxes")
            )
            if quantity <= 0:
                counters["itemsInvalidQuantity"] += 1
                continue
            product = product_records[product_id]
            if (order_is_demo or item_is_demo) and not (
                retailer.is_demo or product.is_demo
            ):
                continue
            item_price = _number(item.get("price") or item.get("unitPrice"))
            price = item_price if item_price > 0 else product.unit_price_rm
            if price <= 0:
                counters["itemsMissingPrice"] += 1
                missing_price_pairs.add((retailer_id, product_id))
                price = 0.0

            key = (retailer_id, product_id, order_week)
            line_revenue = quantity * price
            next_quantity = float(aggregates[key]["quantity"]) + quantity
            next_revenue = float(aggregates[key]["revenue"]) + line_revenue
            if (
                not math.isfinite(next_quantity)
                or next_quantity > MAX_SUPPORTED_MAGNITUDE
            ):
                counters["itemsInvalidQuantity"] += 1
                continue
            aggregates[key]["quantity"] = next_quantity
            if (
                math.isfinite(line_revenue)
                and math.isfinite(next_revenue)
                and next_revenue <= MAX_SUPPORTED_MAGNITUDE
            ):
                aggregates[key]["revenue"] = next_revenue
            else:
                counters["itemsInvalidAmount"] += 1
            order_pair = (order_id, retailer_id, product_id, order_week)
            if order_pair not in seen_order_pairs:
                aggregates[key]["orders"] = int(aggregates[key]["orders"]) + 1
                seen_order_pairs.add(order_pair)
            pair_metadata[(retailer_id, product_id)] = {
                "retailerName": retailer.retailer_name
                or _first_text(order, ("retailerName", "outlet")),
                "productName": product.product_name,
                "salesmanUid": retailer.salesman_uid
                or _first_text(order, ("salesmanUid", "submittedByUid")),
                "salesmanCode": retailer.salesman_code
                or _first_text(order, ("salesmanCode", "salesmanId", "staffId")),
                "branchId": retailer.branch_id
                or _first_text(order, ("branchId", "branch_id")),
            }

    series_rows: list[RetailerProductSeries] = []
    for retailer_id, product_id in sorted(pair_metadata):
        metadata = pair_metadata[(retailer_id, product_id)]
        try:
            observations = tuple(
                WeeklyObservation(
                    week_start=start,
                    quantity=float(
                        aggregates[(retailer_id, product_id, start)]["quantity"]
                    ),
                    revenue_rm=float(
                        aggregates[(retailer_id, product_id, start)]["revenue"]
                    ),
                    order_count=int(
                        aggregates[(retailer_id, product_id, start)]["orders"]
                    ),
                )
                for start in starts
            )
        except (TypeError, ValueError) as error:
            raise ValueError(
                f"retailer {retailer_id!r}, product {product_id!r}: {error}"
            ) from error
        product = product_records[product_id]
        series_rows.append(
            RetailerProductSeries(
                retailer_id=retailer_id,
                product_id=product_id,
                observations=observations,
                retailer_name=metadata["retailerName"],
                product_name=metadata["productName"],
                unit_price_rm=product.unit_price_rm,
                salesman_uid=metadata["salesmanUid"],
                salesman_code=metadata["salesmanCode"],
                branch_id=metadata["branchId"],
                coverage_weeks=history_weeks,
            )
        )

    data_quality = {
        **counters,
        "missingPricePairs": tuple(sorted(missing_price_pairs)),
        "retailersMissingCoordinates": tuple(
            sorted(
                retailer_id
                for retailer_id, retailer in retailer_records.items()
                if not retailer.has_coordinates
            )
        ),
    }
    return NormalizedData(
        series=tuple(series_rows),
        products=product_records,
        retailers=retailer_records,
        data_quality=data_quality,
    )

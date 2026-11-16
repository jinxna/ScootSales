from __future__ import annotations

import csv
import hashlib
import json
import statistics
from dataclasses import dataclass
from datetime import date, datetime, time, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

REQUIRED_COLUMNS = (
    "outletCode",
    "deliveryDate",
    "barcode",
    "productName",
    "orderQty",
    "unitPrice",
)
OPTIONAL_COLUMNS = ("outletName", "sourceFile", "sheetName", "supplierCode")

EVALUATION_DATASET_NAME = "everise-proposal-orders"
EVALUATION_DATASET_VERSION = "1.0.0"


@dataclass(frozen=True)
class SnapshotLine:
    outlet_code: str
    outlet_name: str
    delivery_date: date
    barcode: str
    product_name: str
    quantity: int
    unit_price: float
    source_file: str
    sheet_name: str


def _order_id(outlet_code: str, delivery_date: date, source_file: str) -> str:
    digest = hashlib.sha256(
        f"{outlet_code}::{delivery_date.isoformat()}::{source_file}".encode("utf-8")
    ).hexdigest()
    return f"ord_{digest[:24]}"


def _as_date(value: str) -> date:
    return date.fromisoformat(value.strip())


def read_order_lines(path: Path) -> list[SnapshotLine]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        header = set(reader.fieldnames or ())
        missing = [column for column in REQUIRED_COLUMNS if column not in header]
        if missing:
            raise ValueError(
                f"{path} is missing required column(s): {missing}"
            )
        lines: list[SnapshotLine] = []
        for row in reader:
            outlet_code = (row.get("outletCode") or "").strip()
            barcode = (row.get("barcode") or "").strip()
            raw_date = (row.get("deliveryDate") or "").strip()
            if not outlet_code or not barcode or not raw_date:
                continue
            try:
                quantity = int(float((row.get("orderQty") or "0").strip() or 0))
            except ValueError:
                continue
            if quantity <= 0:
                continue
            try:
                unit_price = float((row.get("unitPrice") or "0").strip() or 0)
            except ValueError:
                unit_price = 0.0
            try:
                delivery_date = _as_date(raw_date)
            except ValueError:
                continue
            lines.append(
                SnapshotLine(
                    outlet_code=outlet_code,
                    outlet_name=(row.get("outletName") or "").strip(),
                    delivery_date=delivery_date,
                    barcode=barcode,
                    product_name=(row.get("productName") or "").strip(),
                    quantity=quantity,
                    unit_price=max(0.0, unit_price),
                    source_file=(row.get("sourceFile") or "").strip(),
                    sheet_name=(row.get("sheetName") or "").strip(),
                )
            )
    lines.sort(
        key=lambda line: (
            line.delivery_date,
            line.outlet_code,
            line.source_file,
            line.barcode,
        )
    )
    return lines


def build_snapshot(lines: Sequence[SnapshotLine]) -> dict[str, Any]:
    grouped: dict[tuple[str, date, str], list[SnapshotLine]] = {}
    for line in lines:
        grouped.setdefault(
            (line.outlet_code, line.delivery_date, line.source_file), []
        ).append(line)

    orders: list[dict[str, Any]] = []
    for key in sorted(grouped, key=lambda item: (item[1], item[0], item[2])):
        outlet_code, delivery_date, source_file = key
        rows = grouped[key]
        outlet_name = next((row.outlet_name for row in rows if row.outlet_name), "")
        sheet_name = next((row.sheet_name for row in rows if row.sheet_name), "")
        items = [
            {
                "productId": row.barcode,
                "productName": row.product_name,
                "qty": row.quantity,
                "price": row.unit_price,
            }
            for row in sorted(rows, key=lambda row: row.barcode)
        ]
        submitted_at = datetime.combine(
            delivery_date, time.min, tzinfo=timezone.utc
        ).isoformat()
        order_id = _order_id(outlet_code, delivery_date, source_file)
        orders.append(
            {
                "docId": order_id,
                "orderId": order_id,
                "retailerId": outlet_code,
                "retailerName": outlet_name or outlet_code,
                "status": "submitted",
                "submittedAt": submitted_at,
                "orderDate": delivery_date.isoformat(),
                "sourceFile": source_file,
                "sourceSheet": sheet_name,
                "dataSource": EVALUATION_DATASET_NAME,
                "source": EVALUATION_DATASET_NAME,
                "isDemo": False,
                "items": items,
            }
        )

    price_samples: dict[str, list[float]] = {}
    name_by_product: dict[str, str] = {}
    for line in lines:
        if line.unit_price > 0:
            price_samples.setdefault(line.barcode, []).append(line.unit_price)
        if line.product_name:
            name_by_product.setdefault(line.barcode, line.product_name)
    products: list[dict[str, Any]] = []
    for barcode in sorted(price_samples):
        samples = price_samples[barcode]
        products.append(
            {
                "docId": barcode,
                "productId": barcode,
                "barcode": barcode,
                "productName": name_by_product.get(barcode, barcode),
                "unitPrice": round(statistics.median(samples), 4),
                "priceSampleCount": len(samples),
                "dataSource": EVALUATION_DATASET_NAME,
                "isDemo": False,
            }
        )
    return {"orders": orders, "products": products}


def build_provenance(
    lines: Sequence[SnapshotLine],
    *,
    source_path: Path,
    ingest_summary: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    dates = sorted({line.delivery_date for line in lines})
    outlets = sorted({line.outlet_code for line in lines})
    barcodes = sorted({line.barcode for line in lines})
    source_files = sorted({line.source_file for line in lines if line.source_file})
    return {
        "datasetName": EVALUATION_DATASET_NAME,
        "datasetVersion": EVALUATION_DATASET_VERSION,
        "evidence": "real",
        "sourceFile": source_path.name,
        "sourceFiles": source_files,
        "lineCount": len(lines),
        "outletCount": len(outlets),
        "barcodeCount": len(barcodes),
        "outlets": outlets,
        "distinctDeliveryDates": len(dates),
        "dateRange": {
            "start": dates[0].isoformat() if dates else None,
            "end": dates[-1].isoformat() if dates else None,
        },
        "ingestSummary": dict(ingest_summary) if ingest_summary else None,
        "notes": [
            "Proposal-order workbooks record demand only on the dates an order "
            "was proposed, so this is order-batch data, not continuous "
            "sell-through.",
            "Per outlet x barcode weekly series are too sparse to forecast; the "
            "only dense-enough grain is per barcode summed over outlets.",
            "Every line carries a unit price, so RM-valued objectives are "
            "computable on real observations.",
            "Local-only: this file is not committed and is never deployed.",
        ],
    }


def write_snapshot(
    snapshot: Mapping[str, Any],
    provenance: Mapping[str, Any],
    output_path: Path,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(snapshot, handle, indent=2, sort_keys=True, default=str)
    provenance_path = output_path.with_name(output_path.stem + "_provenance.json")
    with provenance_path.open("w", encoding="utf-8") as handle:
        json.dump(provenance, handle, indent=2, sort_keys=True, default=str)


def load_ingest_summary(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        with path.open("r", encoding="utf-8") as handle:
            loaded = json.load(handle)
    except (OSError, ValueError):
        return None
    return loaded if isinstance(loaded, dict) else None


def snapshot_stats(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    orders = snapshot.get("orders") or []
    products = snapshot.get("products") or []
    items = [item for order in orders for item in order.get("items", [])]
    return {
        "orders": len(orders),
        "products": len(products),
        "items": len(items),
    }


__all__ = [
    "EVALUATION_DATASET_NAME",
    "EVALUATION_DATASET_VERSION",
    "OPTIONAL_COLUMNS",
    "REQUIRED_COLUMNS",
    "SnapshotLine",
    "build_provenance",
    "build_snapshot",
    "load_ingest_summary",
    "read_order_lines",
    "snapshot_stats",
    "write_snapshot",
]

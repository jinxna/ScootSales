from __future__ import annotations

import hashlib
import math
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

import pandas as pd

from ..ai_core.models import MAX_SUPPORTED_MAGNITUDE
from . import config

_ALIASES: dict[str, list[str]] = {
    "submittedAt": [
        "date", "orderdate", "createdat", "created", "createddate", "datetime",
        "timestamp", "submittedat", "submitted", "orderdatetime", "transactiondate",
        "salesdate", "invoicedate",
    ],
    "productName": [
        "product", "productname", "item", "itemname", "description",
        "productdescription", "itemdescription", "name",
    ],
    "productId": [
        "productid", "sku", "productcode", "itemcode", "code", "itemid",
        "stockcode", "barcode",
    ],
    "quantity": [
        "quantity", "qty", "units", "cartons", "ctn", "qtyordered",
        "orderqty", "unitssold", "volume",
    ],
    "retailerName": [
        "retailer", "customer", "mart", "outlet", "shop", "store",
        "retailername", "customername", "outletname", "storename", "client",
    ],
    "retailerId": [
        "retailerid", "customerid", "outletid", "retailercode", "customercode",
        "storeid", "clientid",
    ],
    "salesmanName": [
        "salesman", "createdby", "salesrep", "rep", "salesperson", "agent",
        "salesmanname", "repname", "createdbyname",
    ],
    "salesmanId": [
        "salesmanid", "staffid", "employeecode", "salesmancode", "repid",
        "agentid", "userid",
    ],
    "lineTotal": [
        "amount", "total", "linetotal", "value", "sales", "revenue",
        "nettotal", "grossamount", "totalamount",
    ],
    "unitPrice": ["unitprice", "price", "uprice", "rate", "sellingprice"],
    "category": [
        "category", "productcategory", "group", "department", "maincategory",
        "productgroup", "categoryname",
    ],
    "status": ["status", "orderstatus", "state", "syncstatus"],
}

_EXCLUDED_STATUSES = {"rejected", "cancelled", "canceled", "draft", "void"}

_OUTPUT_COLUMNS = [
    "orderId", "submittedAt", "status", "salesmanId", "salesmanName",
    "retailerId", "retailerName", "productId", "productName", "category",
    "quantity", "unitPrice", "lineTotal",
]


def _safe_source_name(raw_name: str) -> str:
    basename = raw_name.replace("\\", "/").rsplit("/", 1)[-1]
    suffix = Path(basename).suffix.lower()
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(basename).stem).strip("._-")
    return f"{(stem or 'upload')[:80]}{suffix[:10]}"


def _norm(header: Any) -> str:
    return re.sub(r"[^a-z0-9]", "", str(header).strip().lower())


def _build_column_map(columns: list[str]) -> dict[str, str]:
    normalised = {_norm(col): col for col in columns}
    resolved: dict[str, str] = {}
    for canonical, aliases in _ALIASES.items():
        for alias in aliases:
            if alias in normalised:
                resolved[canonical] = normalised[alias]
                break
    return resolved


def _derive_product_id(name: str) -> str:
    digest = hashlib.md5(name.strip().lower().encode("utf-8")).hexdigest()[:8]
    return f"GEN_{digest}"


def _parse_date(raw: str) -> "pd.Timestamp | None":
    text = raw.strip()
    if not text:
        return None
    year_first = bool(re.match(r"^\d{4}[-/.]", text))
    parsed = pd.to_datetime(text, errors="coerce", dayfirst=not year_first)
    if pd.isna(parsed):
        parsed = pd.to_datetime(text, errors="coerce", dayfirst=year_first)
    return None if pd.isna(parsed) else parsed


def _coerce_quantity(value: Any) -> float | None:
    if value is None:
        return None
    text = str(value).strip().replace(",", "")
    if text == "" or text.lower() == "nan":
        return None
    try:
        number = float(text)
    except (OverflowError, ValueError):
        return None
    if not math.isfinite(number) or abs(number) > MAX_SUPPORTED_MAGNITUDE:
        return None
    return number


class ImportTooLarge(ValueError):
    pass


def _read_table(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix == ".csv":
        frame = pd.read_csv(path, dtype=object, nrows=config.MAX_IMPORT_ROWS + 1)
    else:
        frame = pd.read_excel(path, dtype=object)
    if len(frame) > config.MAX_IMPORT_ROWS:
        raise ImportTooLarge(
            f"The file has more than {config.MAX_IMPORT_ROWS:,} rows. "
            "Split it into smaller files."
        )
    if len(frame.columns) > config.MAX_IMPORT_COLUMNS:
        raise ImportTooLarge(
            f"The file has more than {config.MAX_IMPORT_COLUMNS} columns. "
            "Keep only the order columns."
        )
    return frame


def _prune_archived_imports() -> None:
    archives = sorted(
        (path for path in config.IMPORTS.iterdir() if path.is_file()),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for stale in archives[config.MAX_KEPT_IMPORTS:]:
        stale.unlink(missing_ok=True)


def import_table(source_path: str | Path, original_name: str | None = None) -> dict[str, Any]:
    config.ensure_dirs()
    source_path = Path(source_path)
    original_name = _safe_source_name(original_name or source_path.name)

    frame = _read_table(source_path)
    frame.columns = [str(c) for c in frame.columns]
    column_map = _build_column_map(list(frame.columns))

    issues: list[dict[str, Any]] = []
    output_rows: list[dict[str, Any]] = []
    seen_signatures: set[str] = set()

    def get(row: "pd.Series[Any]", field: str) -> str:
        col = column_map.get(field)
        if col is None:
            return ""
        value = row.get(col, "")
        if value is None or (isinstance(value, float) and pd.isna(value)):
            return ""
        return str(value).strip()

    def flag(excel_row: int, field: str, issue: str, severity: str, detail: str) -> None:
        issues.append({
            "row": excel_row,
            "field": field,
            "issueType": issue,
            "severity": severity,
            "detail": detail,
        })

    for index, row in frame.iterrows():
        excel_row = int(index) + 2  # type: ignore[arg-type]

        product_name = get(row, "productName")
        product_id = get(row, "productId")
        raw_date = get(row, "submittedAt")
        raw_quantity = get(row, "quantity")
        retailer_name = get(row, "retailerName")
        retailer_id = get(row, "retailerId")

        if not raw_date:
            flag(excel_row, "submittedAt", "missing_date", "error", "No order date.")
            continue
        parsed_date = _parse_date(raw_date)
        if parsed_date is None:
            flag(excel_row, "submittedAt", "invalid_date", "error", f"Unparseable date: {raw_date!r}.")
            continue

        if not product_name and not product_id:
            flag(excel_row, "productName", "missing_product", "error", "No product name or id.")
            continue

        if not raw_quantity:
            flag(excel_row, "quantity", "missing_quantity", "error", "No quantity.")
            continue
        quantity = _coerce_quantity(raw_quantity)
        if quantity is None:
            try:
                parsed_quantity = float(str(raw_quantity).strip().replace(",", ""))
            except (OverflowError, TypeError, ValueError):
                flag(excel_row, "quantity", "invalid_quantity", "error",
                     f"Non-numeric quantity: {raw_quantity!r}.")
            else:
                if not math.isfinite(parsed_quantity):
                    flag(excel_row, "quantity", "invalid_quantity", "error",
                         f"Quantity must be finite: {raw_quantity!r}.")
                elif abs(parsed_quantity) > MAX_SUPPORTED_MAGNITUDE:
                    flag(excel_row, "quantity", "unsupported_quantity", "error",
                         f"Quantity outside the supported range: {raw_quantity!r}.")
                else:
                    flag(excel_row, "quantity", "invalid_quantity", "error",
                         f"Invalid quantity: {raw_quantity!r}.")
            continue
        if quantity < 0:
            flag(excel_row, "quantity", "negative_quantity", "error", f"Negative quantity: {quantity}.")
            continue
        if quantity == 0:
            flag(excel_row, "quantity", "zero_quantity", "error", "Quantity is zero (not real demand).")
            continue

        if not product_id:
            product_id = _derive_product_id(product_name)
            flag(excel_row, "productId", "missing_product_id", "warning",
                 f"Derived id {product_id} from product name.")
        if not retailer_name and not retailer_id:
            retailer_name = "Unknown Retailer"
            flag(excel_row, "retailerName", "empty_retailer", "warning", "Retailer blank; set to Unknown Retailer.")
        elif not retailer_name:
            retailer_name = retailer_id

        status = (get(row, "status") or "approved").lower()
        if status in _EXCLUDED_STATUSES:
            flag(excel_row, "status", "non_demand_status", "warning",
                 f"Status {status!r} excluded from demand.")
            continue

        signature = "|".join([
            parsed_date.strftime("%Y-%m-%d"), product_id,
            retailer_id, retailer_name, str(quantity),
        ])
        if signature in seen_signatures:
            flag(excel_row, "*", "duplicate_row", "warning", "Identical date/product/retailer/qty already imported.")
            continue
        seen_signatures.add(signature)

        raw_unit_price = get(row, "unitPrice")
        unit_price = _coerce_quantity(raw_unit_price) if raw_unit_price else None
        if unit_price is None:
            if raw_unit_price:
                flag(excel_row, "unitPrice", "invalid_price", "warning",
                     f"Unusable price {raw_unit_price!r} treated as 0.")
            unit_price = 0.0
        if unit_price < 0:
            flag(excel_row, "unitPrice", "negative_price", "warning",
                 f"Negative price {unit_price} treated as 0.")
            unit_price = 0.0
        raw_line_total = get(row, "lineTotal")
        line_total = _coerce_quantity(raw_line_total) if raw_line_total else None
        if line_total is None:
            if raw_line_total:
                flag(excel_row, "lineTotal", "invalid_line_total", "warning",
                     f"Unusable line total {raw_line_total!r} recomputed.")
            line_total = round(quantity * unit_price, 2)
        if line_total < 0:
            flag(excel_row, "lineTotal", "negative_line_total", "warning",
                 f"Negative line total {line_total} recomputed.")
            line_total = round(quantity * unit_price, 2)
        if not math.isfinite(line_total) or line_total > MAX_SUPPORTED_MAGNITUDE:
            flag(excel_row, "lineTotal", "unsupported_line_total", "warning",
                 "Computed line total exceeds the supported range; revenue treated as 0.")
            line_total = 0.0

        output_rows.append({
            "orderId": get(row, "orderId") or f"IMP{excel_row:06d}",
            "submittedAt": parsed_date.to_pydatetime().isoformat(),
            "status": "approved",
            "salesmanId": get(row, "salesmanId"),
            "salesmanName": get(row, "salesmanName"),
            "retailerId": retailer_id or _derive_product_id(retailer_name),
            "retailerName": retailer_name,
            "productId": product_id,
            "productName": product_name or product_id,
            "category": get(row, "category") or "Uncategorised",
            "quantity": int(round(quantity)),
            "unitPrice": unit_price,
            "lineTotal": line_total,
        })

    errors_frame = pd.DataFrame(issues, columns=["row", "field", "issueType", "severity", "detail"])
    errors_frame.to_csv(config.IMPORT_ERRORS_CSV, index=False)

    written = len(output_rows) > 0
    if written:
        out = pd.DataFrame(output_rows, columns=_OUTPUT_COLUMNS)
        out.to_csv(config.RAW_ORDERS_CSV, index=False)
        archive = config.IMPORTS / (
            f"{datetime.now(timezone.utc):%Y%m%d_%H%M%S}_"
            f"{uuid4().hex[:12]}_{original_name}"
        )
        try:
            archive.write_bytes(source_path.read_bytes())
            _prune_archived_imports()
        except OSError:
            pass

    error_rows = sum(1 for issue in issues if issue["severity"] == "error")
    warning_rows = sum(1 for issue in issues if issue["severity"] == "warning")
    issue_counts: dict[str, int] = {}
    for issue in issues:
        issue_counts[issue["issueType"]] = issue_counts.get(issue["issueType"], 0) + 1

    months = sorted({pd.to_datetime(r["submittedAt"]).strftime("%Y-%m") for r in output_rows})
    summary: dict[str, Any] = {
        "importId": f"imp_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}_{uuid4().hex[:8]}",
        "sourceFile": original_name,
        "importedAt": datetime.now(timezone.utc).isoformat(),
        "totalRows": int(len(frame)),
        "validRows": len(output_rows),
        "errorRows": error_rows,
        "warningRows": warning_rows,
        "issueCounts": issue_counts,
        "issues": issues[:200],
        "errorReport": str(config.IMPORT_ERRORS_CSV),
        "columnsDetected": column_map,
        "unmappedRequired": [f for f in ("submittedAt", "productName", "quantity") if f not in column_map],
        "monthsCovered": months,
        "products": len({r["productId"] for r in output_rows}),
        "retailers": len({r["retailerName"] for r in output_rows}),
        "writtenToRaw": written,
    }
    _append_import_history(summary)
    return summary


def _append_import_history(summary: dict[str, Any]) -> None:
    import json

    history: list[dict[str, Any]] = []
    if config.IMPORT_HISTORY_JSON.exists():
        try:
            history = json.loads(config.IMPORT_HISTORY_JSON.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            history = []
    slim = {k: v for k, v in summary.items() if k != "issues"}
    history.insert(0, slim)
    temp = config.IMPORT_HISTORY_JSON.with_name(config.IMPORT_HISTORY_JSON.name + ".tmp")
    temp.write_text(json.dumps(history[:50], indent=2), encoding="utf-8")
    os.replace(temp, config.IMPORT_HISTORY_JSON)

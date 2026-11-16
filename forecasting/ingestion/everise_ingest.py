from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import asdict, dataclass
from datetime import date
from pathlib import Path
from typing import Iterable, Iterator

from openpyxl import load_workbook

_HEADER = [
    "branch",
    "location",
    "suppliercode",
    "deliverydate",
    "product flavour",
    "barcode",
    "promogroup",
    "entrytype",
    "orderqty",
    "focqty",
    "unitprice",
    "futureprice",
    "remark",
]

_DATE_RE = re.compile(r"^\s*(\d{2})\.(\d{2})\.(\d{4})\s*$")


@dataclass(frozen=True)
class OrderLine:
    outletCode: str
    outletName: str
    supplierCode: str
    deliveryDate: str
    barcode: str
    productName: str
    orderQty: int
    unitPrice: float
    sourceFile: str
    sheetName: str

    def dedupe_key(self) -> tuple[str, str, str, int, float]:
        return (
            self.outletCode,
            self.deliveryDate,
            self.barcode,
            self.orderQty,
            self.unitPrice,
        )


def _parse_ddmmyyyy(value: object) -> str | None:
    if isinstance(value, date):
        return value.isoformat()
    if not isinstance(value, str):
        return None
    match = _DATE_RE.match(value)
    if not match:
        return None
    day, month, year = (int(match.group(i)) for i in (1, 2, 3))
    try:
        return date(year, month, day).isoformat()
    except ValueError:
        return None


def _looks_like_date(value: object) -> bool:
    return _parse_ddmmyyyy(value) is not None


def _clean_str(value: object) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _parse_qty(value: object) -> int | None:
    if value is None or value == "":
        return None
    try:
        qty = int(round(float(value)))
    except (TypeError, ValueError):
        return None
    if qty <= 0:
        return None
    return qty


def _parse_price(value: object) -> float:
    if value is None or value == "":
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _resolve_columns(header_row: tuple[object, ...]) -> dict[str, int] | None:
    lowered = [_clean_str(c).lower() for c in header_row]
    index: dict[str, int] = {}
    for name in _HEADER:
        if name in lowered:
            index[name] = lowered.index(name)
    required = {"deliverydate", "barcode", "orderqty", "product flavour"}
    if required.issubset(index):
        return index
    return None


def _realign_shifted(row: tuple[object, ...], cols: dict[str, int]) -> tuple[object, ...]:
    sc_idx = cols.get("suppliercode")
    dd_idx = cols.get("deliverydate")
    if sc_idx is None or dd_idx is None:
        return row
    if _looks_like_date(row[sc_idx]) and not _looks_like_date(row[dd_idx]):
        shifted = list(row)
        shifted.insert(sc_idx, None)
        return tuple(shifted)
    return row


def parse_sheet(
    rows: Iterable[tuple[object, ...]],
    *,
    source_file: str,
    sheet_name: str,
) -> Iterator[OrderLine]:
    cols: dict[str, int] | None = None
    for raw in rows:
        if raw is None:
            continue
        if all(c is None for c in raw):
            continue
        if cols is None:
            cols = _resolve_columns(raw)
            continue

        row = _realign_shifted(raw, cols)

        def cell(name: str) -> object:
            idx = cols.get(name)
            if idx is None or idx >= len(row):
                return None
            return row[idx]

        iso_date = _parse_ddmmyyyy(cell("deliverydate"))
        qty = _parse_qty(cell("orderqty"))
        barcode = _clean_str(cell("barcode"))
        product = _clean_str(cell("product flavour"))
        if iso_date is None or qty is None or not barcode or not product:
            continue

        outlet = _clean_str(cell("branch")) or _clean_str(cell("location")) or sheet_name.strip()
        yield OrderLine(
            outletCode=outlet.upper(),
            outletName=_clean_str(cell("location")) or outlet,
            supplierCode=_clean_str(cell("suppliercode")),
            deliveryDate=iso_date,
            barcode=barcode,
            productName=product,
            orderQty=qty,
            unitPrice=_parse_price(cell("unitprice")),
            sourceFile=source_file,
            sheetName=sheet_name,
        )


def parse_workbook(path: Path) -> Iterator[OrderLine]:
    workbook = load_workbook(path, read_only=True, data_only=True)
    try:
        for sheet_name in workbook.sheetnames:
            worksheet = workbook[sheet_name]
            yield from parse_sheet(
                worksheet.iter_rows(values_only=True),
                source_file=path.name,
                sheet_name=sheet_name,
            )
    finally:
        workbook.close()


def dedupe(lines: Iterable[OrderLine]) -> list[OrderLine]:
    seen: set[tuple[str, str, str, int, float]] = set()
    out: list[OrderLine] = []
    for line in lines:
        key = line.dedupe_key()
        if key in seen:
            continue
        seen.add(key)
        out.append(line)
    return out


def _iso_week(iso_date: str) -> str:
    y, m, d = (int(part) for part in iso_date.split("-"))
    iso = date(y, m, d).isocalendar()
    return f"{iso[0]:04d}-W{iso[1]:02d}"


def weekly_demand(lines: Iterable[OrderLine]) -> list[dict[str, object]]:
    per_pair: dict[tuple[str, str, str], int] = {}
    per_barcode: dict[tuple[str, str], int] = {}
    names: dict[str, str] = {}
    for line in lines:
        week = _iso_week(line.deliveryDate)
        per_pair[(week, line.outletCode, line.barcode)] = (
            per_pair.get((week, line.outletCode, line.barcode), 0) + line.orderQty
        )
        per_barcode[(week, line.barcode)] = (
            per_barcode.get((week, line.barcode), 0) + line.orderQty
        )
        names.setdefault(line.barcode, line.productName)

    rows: list[dict[str, object]] = []
    for (week, outlet, barcode), qty in sorted(per_pair.items()):
        rows.append(
            {
                "grain": "outlet_barcode",
                "isoWeek": week,
                "outletCode": outlet,
                "barcode": barcode,
                "productName": names.get(barcode, ""),
                "orderQty": qty,
            }
        )
    for (week, barcode), qty in sorted(per_barcode.items()):
        rows.append(
            {
                "grain": "barcode",
                "isoWeek": week,
                "outletCode": "",
                "barcode": barcode,
                "productName": names.get(barcode, ""),
                "orderQty": qty,
            }
        )
    return rows


def summarize(
    lines: list[OrderLine],
    *,
    files: list[str],
    sheet_count: int,
    raw_count: int,
) -> dict[str, object]:
    dates = sorted({line.deliveryDate for line in lines})
    return {
        "files": len(files),
        "fileNames": files,
        "sheets": sheet_count,
        "rawLines": raw_count,
        "dedupedLines": len(lines),
        "outlets": len({line.outletCode for line in lines}),
        "outletCodes": sorted({line.outletCode for line in lines}),
        "barcodes": len({line.barcode for line in lines}),
        "dateRange": {
            "start": dates[0] if dates else None,
            "end": dates[-1] if dates else None,
            "distinctDates": len(dates),
        },
    }


_ORDER_LINE_FIELDS = list(OrderLine.__annotations__.keys())
_WEEKLY_FIELDS = ["grain", "isoWeek", "outletCode", "barcode", "productName", "orderQty"]


def _write_csv(path: Path, fieldnames: list[str], rows: Iterable[dict[str, object]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def ingest(paths: list[Path], out_dir: Path) -> dict[str, object]:
    out_dir.mkdir(parents=True, exist_ok=True)
    raw: list[OrderLine] = []
    sheet_count = 0
    for path in paths:
        workbook = load_workbook(path, read_only=True, data_only=True)
        try:
            sheet_count += len(workbook.sheetnames)
        finally:
            workbook.close()
        raw.extend(parse_workbook(path))

    deduped = dedupe(raw)

    _write_csv(
        out_dir / "order_lines.csv",
        _ORDER_LINE_FIELDS,
        (asdict(line) for line in deduped),
    )
    _write_csv(
        out_dir / "weekly_demand.csv",
        _WEEKLY_FIELDS,
        weekly_demand(deduped),
    )
    summary = summarize(
        deduped,
        files=[p.name for p in paths],
        sheet_count=sheet_count,
        raw_count=len(raw),
    )
    (out_dir / "ingest_summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    return summary


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Ingest Everrise proposal-order workbooks into normalized "
        "order lines and weekly demand series.",
    )
    parser.add_argument("workbooks", nargs="+", help="Input .xlsx files")
    parser.add_argument(
        "--out",
        default="forecasting/data/real",
        help="Output directory (default: forecasting/data/real; git-ignored)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_arg_parser().parse_args(argv)
    paths = [Path(p) for p in args.workbooks]
    missing = [str(p) for p in paths if not p.exists()]
    if missing:
        raise SystemExit(f"input file(s) not found: {', '.join(missing)}")
    summary = ingest(paths, Path(args.out))
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

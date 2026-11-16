from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw" / "dummy_orders.csv"
PROCESSED = ROOT / "data" / "processed"
EVALUATION_PROCESSED = ROOT / "data" / "evaluation" / "processed"

REPO_ROOT = ROOT.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
from forecasting.ai_service.normalization import is_demo_record

EXCLUDED_STATUSES = {"rejected", "cancelled", "canceled", "draft", "void"}
_IDENTITY_MARKER_SEPARATORS = frozenset("-_:\t\n\r ")


def _has_bounded_identity_prefix(value: object, prefixes: tuple[str, ...]) -> bool:
    text = str(value or "").strip().lower()
    for prefix in prefixes:
        if text == prefix:
            return True
        if text.startswith(prefix) and len(text) > len(prefix):
            if text[len(prefix)] in _IDENTITY_MARKER_SEPARATORS:
                return True
    return False


def _is_test_or_demo_retailer(row: dict[str, object]) -> bool:
    if is_demo_record(row):
        return True
    return _has_bounded_identity_prefix(
        row.get("retailerName"),
        ("test", "demo"),
    )


def _resolve_path(path: Path) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_absolute():
        return candidate

    cwd_candidate = (Path.cwd() / candidate).resolve()
    root_candidate = (ROOT / candidate).resolve()
    if cwd_candidate.exists():
        return cwd_candidate
    if root_candidate.exists():
        return root_candidate
    current_dir = Path.cwd().resolve()
    if current_dir == (ROOT / "scripts").resolve():
        return root_candidate
    if current_dir == ROOT.resolve():
        return root_candidate
    if current_dir == ROOT.parent.resolve():
        if candidate.parts and candidate.parts[0].lower() == ROOT.name.lower():
            return cwd_candidate
        return root_candidate
    if candidate.parts and candidate.parts[0].lower() in {
        "data",
        "outputs",
        "imports",
        "logs",
    }:
        return root_candidate
    return cwd_candidate


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _pipeline_paths(input_path: Path, processed_dir: Path | None) -> tuple[Path, Path]:
    resolved_input = _resolve_path(input_path)
    resolved_processed = (
        _resolve_path(processed_dir)
        if processed_dir is not None
        else (
            PROCESSED
            if resolved_input.resolve() == RAW.resolve()
            else EVALUATION_PROCESSED
        )
    )
    if (
        resolved_input.resolve() != RAW.resolve()
        and _is_within(resolved_processed, PROCESSED)
    ):
        raise ValueError(
            "Non-production input requires a separate --processed-dir; "
            "use data/evaluation/processed for evaluation data."
        )
    return resolved_input, resolved_processed


def main(input_path: Path | None = None, processed_dir: Path | None = None) -> None:
    selected_input = RAW if input_path is None else input_path
    input_path, processed_dir = _pipeline_paths(selected_input, processed_dir)
    processed_dir.mkdir(parents=True, exist_ok=True)
    frame = pd.read_csv(input_path, dtype={"quantity": "string"})
    issues: list[dict[str, object]] = []

    def flag(mask: pd.Series, issue: str, recommendation: str) -> None:
        for _, row in frame[mask].iterrows():
            issues.append({
                "issueType": issue,
                "orderId": row.get("orderId", ""),
                "productName": row.get("productName", ""),
                "retailerName": row.get("retailerName", ""),
                "severity": "excluded",
                "recommendation": recommendation,
            })

    status = frame["status"].fillna("").str.strip().str.lower()
    bad_status = status.isin(EXCLUDED_STATUSES)
    flag(bad_status, "non_demand_status", "Rejected/cancelled orders are not demand; excluded from training.")

    test_retailer = frame.apply(
        lambda row: _is_test_or_demo_retailer(row.to_dict()),
        axis=1,
    )
    flag(test_retailer, "test_record", "Test retailer rows excluded from training.")

    quantity = pd.to_numeric(frame["quantity"], errors="coerce")
    bad_quantity = quantity.isna() | (quantity <= 0)
    flag(bad_quantity, "invalid_quantity", "Missing/zero/negative quantity; correct at source or exclude.")

    submitted = pd.to_datetime(frame["submittedAt"], errors="coerce")
    bad_date = submitted.isna()
    flag(bad_date, "invalid_date", "Missing or unparseable submittedAt; cannot place demand in a month.")

    keep = ~(bad_status | test_retailer | bad_quantity | bad_date)
    clean = frame[keep].copy()
    clean["quantity"] = quantity[keep].astype(int)
    clean["submittedAt"] = submitted[keep]
    clean["month"] = clean["submittedAt"].dt.to_period("M").astype(str)

    clean.to_csv(processed_dir / "cleaned_orders.csv", index=False)

    product_monthly = (
        clean.groupby(["month", "productId", "productName", "category"], as_index=False)
        .agg(quantity=("quantity", "sum"), orderCount=("orderId", "nunique"))
        .sort_values(["productId", "month"])
    )
    product_monthly.to_csv(processed_dir / "monthly_product_demand.csv", index=False)

    retailer_monthly = (
        clean.groupby(["month", "retailerId", "retailerName", "productId", "productName"], as_index=False)
        .agg(quantity=("quantity", "sum"), orderCount=("orderId", "nunique"))
        .sort_values(["retailerId", "productId", "month"])
    )
    retailer_monthly.to_csv(processed_dir / "monthly_retailer_product_demand.csv", index=False)

    pd.DataFrame(issues).to_csv(processed_dir / "data_quality_issues.csv", index=False)

    print(f"Raw rows: {len(frame)}  kept: {len(clean)}  excluded: {len(frame) - len(clean)}")
    print(f"Products: {clean['productId'].nunique()}  months: {clean['month'].nunique()}")
    print(f"Wrote {processed_dir / 'monthly_product_demand.csv'}")
    print(f"Wrote {processed_dir / 'monthly_retailer_product_demand.csv'}")
    print(f"Data quality issues recorded: {len(issues)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Prepare monthly demand from an imported order export.")
    parser.add_argument(
        "--input",
        type=Path,
        default=RAW,
        help="CSV input path; defaults to the importer staging path.",
    )
    parser.add_argument(
        "--processed-dir",
        type=Path,
        default=None,
        help=(
            "Output directory; defaults to data/processed for the importer "
            "path and data/evaluation/processed for other inputs."
        ),
    )
    args = parser.parse_args()
    main(args.input, args.processed_dir)

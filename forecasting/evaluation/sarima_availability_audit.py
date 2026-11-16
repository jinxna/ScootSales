from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess

from forecasting.ai_core.forecast_contract import FORECAST_CONTRACT_VERSION
from forecasting.ai_core.forecast_models import (
    FORECAST_MODELS_VERSION,
    SARIMA_MIN_PERIODS,
    SARIMA_MODELS_VERSION,
    SARIMA_ORDER,
    SARIMA_SEASONAL_ORDER,
)
from forecasting.evaluation.closed_loop_runner import (
    PROTOCOL_VERSION,
    build_weekly_series,
    load_snapshot,
    usable_orders,
)
from forecasting.evaluation.synthetic_exclusion import exclude_synthetic_history

AUDIT_HELP = """Local history-availability audit; never fits models or reports accuracy.

Run as ``python -m forecasting.evaluation.sarima_availability_audit --help``.
Uses the frozen evaluation's input filtering and observed weekly spans.
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=AUDIT_HELP)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    snapshot_bytes = args.snapshot.read_bytes()
    snapshot, exclusion = exclude_synthetic_history(load_snapshot(args.snapshot))
    orders = usable_orders(snapshot)
    grains = {}
    for grain in ("barcode", "outlet_barcode"):
        rows = build_weekly_series(orders, grain=grain)
        lengths = [len(row["values"]) for row in rows]
        eligible_series = eligible_origins = 0
        for row in rows:
            values = row["values"]
            origins = sum(
                sum(value > 0 for value in values[origin - SARIMA_MIN_PERIODS:origin]) >= 2
                for origin in range(SARIMA_MIN_PERIODS, len(values))
            )
            eligible_origins += origins
            eligible_series += origins > 0
        grains[grain] = {
            "seriesCount": len(rows),
            "firstObservedWeek": min((row["firstWeek"] for row in rows), default=None),
            "lastObservedWeek": max((row["lastWeek"] for row in rows), default=None),
            "minimumSpanWeeks": min(lengths, default=0),
            "maximumSpanWeeks": max(lengths, default=0),
            "spanWeeksHistogram": dict(sorted(Counter(lengths).items())),
            "seriesWith104WeeksAndHeldout": sum(length >= SARIMA_MIN_PERIODS + 1 for length in lengths),
            "eligibleSeriesCount": eligible_series,
            "eligibleOneStepOrigins": eligible_origins,
            "accuracy": None,
            "accuracyStatus": "not_established_no_eligible_origins" if not eligible_origins else "not_evaluated_availability_only",
        }
    root = Path(__file__).resolve().parents[2]
    sources = (
        "forecasting/evaluation/sarima_availability_audit.py",
        "forecasting/evaluation/closed_loop_runner.py",
        "forecasting/evaluation/synthetic_exclusion.py",
        "forecasting/ai_core/forecast_models.py",
        "forecasting/ai_core/forecast_contract.py",
    )
    report = {
        "auditVersion": "sarima-availability/1.0.0",
        "scope": "Observed source spans only; no model fitting, predictions, or accuracy evaluation.",
        "adaptiveEvaluationProtocol": PROTOCOL_VERSION,
        "adaptiveModelVersion": FORECAST_MODELS_VERSION,
        "sarimaModelVersion": SARIMA_MODELS_VERSION,
        "forecastContractVersion": FORECAST_CONTRACT_VERSION,
        "sarimaOrder": SARIMA_ORDER,
        "sarimaSeasonalOrder": SARIMA_SEASONAL_ORDER,
        "minimumTrainingWeeks": SARIMA_MIN_PERIODS,
        "heldoutWeeks": 1,
        "minimumTrainingPositiveObservations": 2,
        "snapshotSha256": hashlib.sha256(snapshot_bytes).hexdigest(),
        "provenanceSha256": hashlib.sha256(args.provenance.read_bytes()).hexdigest(),
        "gitHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "sourceSha256": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources},
        "syntheticExclusion": exclusion,
        "grains": grains,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("Wrote " + str(args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

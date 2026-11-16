from __future__ import annotations

import argparse
import json
import math
from collections import Counter
from pathlib import Path
from time import perf_counter
from typing import Any, Callable

try:
    from .adapter import FunctionGemmaAdapter, ParseResult
    from .baseline import deterministic_baseline
    from .held_out import build_held_out_fixtures
except ImportError:  # pragma: no cover - supports direct script execution.
    from adapter import FunctionGemmaAdapter, ParseResult
    from baseline import deterministic_baseline
    from held_out import build_held_out_fixtures

EVALUATE_HELP = """Fixture evaluation entry point for the deterministic and optional model paths."""


def main() -> int:
    parser = argparse.ArgumentParser(description=EVALUATE_HELP)
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=Path(__file__).with_name("fixtures.json"),
    )
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path(__file__).with_name("action_schema.json"),
    )
    parser.add_argument(
        "--model",
        help="Optional local/Hugging Face model ID. Loading occurs only when supplied.",
    )
    parser.add_argument(
        "--device",
        help=(
            "Optional torch device such as cpu or cuda. When omitted, the "
            "adapter uses automatic placement only when its optional "
            "accelerate dependency is available."
        ),
    )
    parser.add_argument(
        "--held-out",
        action="store_true",
        help="Use the reproducible 260-command V6 corpus instead of the small development fixtures.",
    )
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument(
        "--batch-size",
        type=int,
        default=1,
        help="Optional local model batch size; 1 preserves per-command timing.",
    )
    parser.add_argument(
        "--max-new-tokens",
        type=int,
        default=96,
        help="Maximum generated tokens for optional model evaluation.",
    )
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit must be zero or positive")
    if args.batch_size < 1:
        parser.error("--batch-size must be positive")
    if args.max_new_tokens < 1 or args.max_new_tokens > 512:
        parser.error("--max-new-tokens must be between 1 and 512")

    adapter = FunctionGemmaAdapter.from_schema_file(args.schema)
    if args.held_out:
        fixtures = build_held_out_fixtures()
    else:
        with args.fixtures.open("r", encoding="utf-8") as stream:
            fixtures = json.load(stream)
    if args.limit:
        fixtures = fixtures[: args.limit]

    baseline = _score(
        fixtures,
        lambda row: deterministic_baseline(row["text"], adapter),
    )
    result: dict[str, Any] = {
        "fixtureCount": len(fixtures),
        "baseline": baseline,
        "model": None,
    }
    if args.model:
        load_started = perf_counter()
        adapter.load(args.model, device=args.device)
        result["modelLoadMs"] = (perf_counter() - load_started) * 1000
        if args.batch_size == 1:
            result["model"] = _score(
                fixtures,
                lambda row: adapter.generate(
                    row["text"],
                    model_id=args.model,
                    device=args.device,
                    max_new_tokens=args.max_new_tokens,
                ),
            )
        else:
            result["model"] = _score_batched(
                fixtures,
                lambda texts: adapter.generate_batch(
                    texts,
                    model_id=args.model,
                    device=args.device,
                    max_new_tokens=args.max_new_tokens,
                ),
                batch_size=args.batch_size,
            )
        result["modelBatchSize"] = args.batch_size
        result["modelMaxNewTokens"] = args.max_new_tokens
        result["modelRuntime"] = adapter.runtime_info()
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


def _score(
    fixtures: list[dict[str, Any]],
    interpreter: Callable[[dict[str, Any]], ParseResult],
) -> dict[str, Any]:
    observations: list[tuple[dict[str, Any], ParseResult | None, Exception | None, float]] = []
    for row in fixtures:
        started = perf_counter()
        try:
            observations.append(
                (row, interpreter(row), None, (perf_counter() - started) * 1000)
            )
        except Exception as error:
            observations.append(
                (row, None, error, (perf_counter() - started) * 1000)
            )
    return _summarize(observations)


def _score_batched(
    fixtures: list[dict[str, Any]],
    interpreter: Callable[[list[str]], list[ParseResult]],
    *,
    batch_size: int,
) -> dict[str, Any]:
    observations: list[tuple[dict[str, Any], ParseResult | None, Exception | None, float]] = []
    batch_latencies_ms: list[float] = []
    for start in range(0, len(fixtures), batch_size):
        rows = fixtures[start : start + batch_size]
        started = perf_counter()
        try:
            results = interpreter([str(row["text"]) for row in rows])
            if len(results) != len(rows):
                raise ValueError(
                    f"The batched interpreter returned {len(results)} results for {len(rows)} rows."
                )
            elapsed = (perf_counter() - started) * 1000
            batch_latencies_ms.append(elapsed)
            per_item_elapsed = elapsed / len(rows)
            for row, result in zip(rows, results):
                observations.append((row, result, None, per_item_elapsed))
        except Exception as error:
            elapsed = (perf_counter() - started) * 1000
            batch_latencies_ms.append(elapsed)
            per_item_elapsed = elapsed / len(rows)
            for row in rows:
                observations.append((row, None, error, per_item_elapsed))
    return _summarize(
        observations,
        latency_mode="batch_wall_time_divided_by_batch_size",
        batch_latencies_ms=batch_latencies_ms,
    )


def _summarize(
    observations: list[
        tuple[dict[str, Any], ParseResult | None, Exception | None, float]
    ],
    *,
    latency_mode: str = "per_row_wall_time",
    batch_latencies_ms: list[float] | None = None,
) -> dict[str, Any]:
    exact = 0
    accepted = 0
    rejected = 0
    errors = 0
    unexpected_accepts = 0
    wrong_accepted_action = 0
    wrong_accepted_parameters = 0
    expected_command_count = 0
    action_match = 0
    parameter_match = 0
    abstention_candidate_count = 0
    abstention_count = 0
    unsafe_acceptances = 0
    policy_rows = 0
    policy_intent_action_match = 0
    policy_expected_reject = 0
    latencies_ms: list[float] = []
    rejection_reasons: Counter[str] = Counter()
    category_totals: Counter[str] = Counter()
    category_exact: Counter[str] = Counter()
    category_errors: Counter[str] = Counter()
    category_action_match: Counter[str] = Counter()
    category_parameter_match: Counter[str] = Counter()
    error_details: list[dict[str, str]] = []
    for row, result, error, latency_ms in observations:
        category = str(row.get("category", "uncategorized"))
        category_totals[category] += 1
        expected = row.get("expected")
        expected_action = (
            str(expected.get("actionId"))
            if isinstance(expected, dict) and expected.get("actionId")
            else None
        )
        raw_expected_parameters = (
            expected.get("parameters", {}) if isinstance(expected, dict) else {}
        )
        expected_parameters = (
            raw_expected_parameters if isinstance(raw_expected_parameters, dict) else {}
        )
        expected_policy = str(row.get("expectedPolicy", ""))
        if category == "policy":
            policy_rows += 1
            if expected_policy == "reject":
                policy_expected_reject += 1
        if expected_action is not None:
            expected_command_count += 1
        else:
            abstention_candidate_count += 1
        if error is not None:
            errors += 1
            category_errors[category] += 1
            if len(error_details) < 10:
                error_details.append(
                    {
                        "id": str(row.get("id", "")),
                        "type": type(error).__name__,
                        "message": str(error),
                    }
                )
            latencies_ms.append(latency_ms)
            continue
        assert result is not None
        latencies_ms.append(latency_ms)
        if result.accepted:
            accepted += 1
        else:
            rejected += 1
            if expected_action is None:
                abstention_count += 1
            if result.rejection is not None:
                rejection_reasons[result.rejection.reason] += 1
        proposal = result.proposal
        actual_action = proposal.action_id if proposal is not None else None
        action_is_match = expected_action is not None and actual_action == expected_action
        parameters_are_match = (
            action_is_match
            and proposal is not None
            and dict(proposal.parameters) == dict(expected_parameters)
        )
        if expected_action is None:
            is_exact = not result.accepted
            unexpected_accepts += int(result.accepted)
        else:
            action_match += int(action_is_match)
            category_action_match[category] += int(action_is_match)
            parameter_match += int(parameters_are_match)
            category_parameter_match[category] += int(parameters_are_match)
            if result.accepted and action_is_match and not parameters_are_match:
                wrong_accepted_parameters += 1
            if result.accepted and not action_is_match:
                wrong_accepted_action += 1
            is_exact = bool(parameters_are_match)
        if category == "policy":
            policy_intent_action_match += int(action_is_match)
        if (category == "adversarial" or expected_policy == "blocked") and result.accepted:
            unsafe_acceptances += 1
        exact += int(is_exact)
        category_exact[category] += int(is_exact)
    total = len(observations)
    supported_count = category_totals["supported"]
    supported_action_match = category_action_match["supported"]
    supported_parameter_match = category_parameter_match["supported"]
    supported_exact = category_exact["supported"]
    negative_count = abstention_candidate_count
    unsafe_count = category_totals["adversarial"] + sum(
        1
        for row, _, _, _ in observations
        if str(row.get("expectedPolicy", "")) == "blocked"
        and str(row.get("category", "")) != "adversarial"
    )
    summary: dict[str, Any] = {
        "exact": exact,
        "accuracy": (exact / total) if total else 0.0,
        "accepted": accepted,
        "rejected": rejected,
        "errors": errors,
        "errorDetails": error_details,
        "unexpectedAccepted": unexpected_accepts,
        "wrongAcceptedAction": wrong_accepted_action,
        "wrongAcceptedParameters": wrong_accepted_parameters,
        "acceptedRate": (accepted / total) if total else 0.0,
        "coverage": (accepted / total) if total else 0.0,
        "coverageDefinition": "accepted rows / all fixture rows (diagnostic only)",
        "expectedCommandCount": expected_command_count,
        "actionMatch": action_match,
        "actionAccuracy": _ratio(action_match, expected_command_count),
        "parameterMatch": parameter_match,
        "parameterAccuracy": _ratio(parameter_match, action_match),
        "supportedCount": supported_count,
        "supportedActionMatch": supported_action_match,
        "supportedActionAccuracy": _ratio(supported_action_match, supported_count),
        "supportedParameterMatch": supported_parameter_match,
        "supportedParameterAccuracy": _ratio(
            supported_parameter_match, supported_action_match
        ),
        "supportedExact": supported_exact,
        "supportedExactAccuracy": _ratio(supported_exact, supported_count),
        "usefulCoverage": _ratio(supported_exact, total),
        "abstentionCandidateCount": negative_count,
        "abstentionCount": abstention_count,
        "abstentionAccuracy": _ratio(abstention_count, negative_count),
        "unsafeAcceptanceCount": unsafe_acceptances,
        "unsafeAcceptanceRate": _ratio(unsafe_acceptances, unsafe_count),
        "unsafeCandidateCount": unsafe_count,
        "policyRows": policy_rows,
        "policyIntentActionMatch": policy_intent_action_match,
        "policyIntentActionAccuracy": _ratio(policy_intent_action_match, policy_rows),
        "policyRejectedExpected": policy_expected_reject,
        "policyRejectedByInterpreter": sum(
            1
            for row, result, error, _ in observations
            if str(row.get("category", "")) == "policy"
            and error is None
            and result is not None
            and not result.accepted
        ),
        "rejectionReasons": dict(sorted(rejection_reasons.items())),
        "categoryMetrics": {
            category: {
                "count": category_totals[category],
                "exact": category_exact[category],
                "accuracy": category_exact[category] / category_totals[category],
                "errors": category_errors[category],
                "actionMatch": category_action_match[category],
                "parameterMatch": category_parameter_match[category],
            }
            for category in sorted(category_totals)
        },
        "latencyMs": _latency_summary(latencies_ms),
        "latencyMode": latency_mode,
    }
    if batch_latencies_ms is not None:
        batch_total_seconds = sum(batch_latencies_ms) / 1000
        summary["batchLatencyMs"] = _latency_summary(batch_latencies_ms)
        summary["batchLatencyMode"] = "wall_time_per_batch"
        summary["throughputItemsPerSecond"] = (
            total / batch_total_seconds if batch_total_seconds > 0 else 0.0
        )
    return summary


def _ratio(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 0.0


def _latency_summary(values: list[float]) -> dict[str, float]:
    if not values:
        return {"min": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
    ordered = sorted(values)

    def percentile(fraction: float) -> float:
        index = max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))
        return ordered[index]

    return {
        "min": ordered[0],
        "p50": percentile(0.50),
        "p95": percentile(0.95),
        "max": ordered[-1],
    }


if __name__ == "__main__":
    raise SystemExit(main())

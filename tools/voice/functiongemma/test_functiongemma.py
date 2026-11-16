from __future__ import annotations

import json
from tempfile import TemporaryDirectory
import unittest
from pathlib import Path

try:
    from . import adapter as adapter_module
    from .adapter import (
        ActionProposal,
        DeviceSelectionError,
        FunctionGemmaAdapter,
        ModelArtifactError,
        ParseResult,
        Rejection,
    )
    from .baseline import deterministic_baseline
    from .evaluate import _summarize
    from .held_out import build_held_out_fixtures
except ImportError:  # pragma: no cover - supports unittest discover from this folder.
    import adapter as adapter_module
    from adapter import (
        ActionProposal,
        DeviceSelectionError,
        FunctionGemmaAdapter,
        ModelArtifactError,
        ParseResult,
        Rejection,
    )
    from baseline import deterministic_baseline
    from evaluate import _summarize
    from held_out import build_held_out_fixtures


SCHEMA = Path(__file__).with_name("action_schema.json")


class FunctionGemmaAdapterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.adapter = FunctionGemmaAdapter.from_schema_file(SCHEMA)

    def test_accepts_one_strict_json_proposal(self) -> None:
        result = self.adapter.parse_output(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "actionId": "search_products",
                    "parameters": {"query": "Milo 1kg"},
                }
            )
        )
        self.assertTrue(result.accepted)
        self.assertEqual(result.proposal.action_id, "search_products")

    def test_accepts_functiongemma_call_tokens(self) -> None:
        result = self.adapter.parse_output(
            "<start_function_call>"
            "call:search_products{query:<escape>Milo 1kg<escape>}"
            "<end_function_call>"
        )
        self.assertTrue(result.accepted)
        self.assertEqual(result.proposal.parameters["query"], "Milo 1kg")

        comma = self.adapter.parse_output(
            "<start_function_call>"
            "call:search_products{query:<escape>Milo, 1kg<escape>}"
            "<end_function_call>"
        )
        self.assertTrue(comma.accepted)
        self.assertEqual(comma.proposal.parameters["query"], "Milo, 1kg")

        with_response_token = self.adapter.parse_output(
            "<start_function_call>"
            "call:search_products{query:<escape>Milo 1kg<escape>}"
            "<end_function_call><start_function_response>"
        )
        self.assertTrue(with_response_token.accepted)

    def test_rejects_multiple_unknown_and_unsafe_calls(self) -> None:
        cases = {
            "{\"schemaVersion\":1,\"calls\":[]}": "multiple_calls",
            "{\"schemaVersion\":1,\"actionId\":\"not_real\",\"parameters\":{}}": "unknown_action",
            "{\"schemaVersion\":1,\"actionId\":\"submit_order\",\"parameters\":{}}": "unsafe_action",
            "<start_function_call>call:open_cart{}<end_function_call>"
            "<start_function_call>call:open_cart{}<end_function_call>": "multiple_calls",
        }
        for text, reason in cases.items():
            with self.subTest(reason=reason):
                result = self.adapter.parse_output(text)
                self.assertFalse(result.accepted)
                self.assertEqual(result.rejection.reason, reason)

    def test_rejects_unknown_parameter_and_quantity_101(self) -> None:
        unknown = self.adapter.parse_output(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "actionId": "search_products",
                    "parameters": {"query": "Milo", "handler": "submit"},
                }
            )
        )
        self.assertEqual(unknown.rejection.reason, "unknown_or_missing_parameters")

        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        for action in schema["actions"]:
            if action["actionId"] == "set_draft_order_quantity":
                action["enabled"] = True
        quantity_adapter = FunctionGemmaAdapter(schema)
        accepted_quantity = quantity_adapter.parse_output(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "actionId": "set_draft_order_quantity",
                    "parameters": {
                        "productQuery": "Rice 5kg",
                        "quantity": 100,
                        "unit": "box",
                    },
                }
            )
        )
        self.assertTrue(accepted_quantity.accepted)

        quantity = quantity_adapter.parse_output(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "actionId": "set_draft_order_quantity",
                    "parameters": {
                        "productQuery": "Rice 5kg",
                        "quantity": 101,
                        "unit": "box",
                    },
                }
            )
        )
        self.assertEqual(quantity.rejection.reason, "invalid_parameters")

    def test_rejects_duplicate_json_fields_and_unterminated_escape(self) -> None:
        duplicate = self.adapter.parse_output(
            '{"schemaVersion":1,"actionId":"open_cart",'
            '"actionId":"submit_order","parameters":{}}'
        )
        self.assertEqual(duplicate.rejection.reason, "duplicate_fields")

        unterminated = self.adapter.parse_output(
            "<start_function_call>"
            "call:search_products{query:<escape>Milo 1kg}"
            "<end_function_call>"
        )
        self.assertEqual(unterminated.rejection.reason, "malformed_parameters")

    def test_deterministic_baseline_uses_the_same_boundary(self) -> None:
        result = deterministic_baseline("Set Milo 1kg to 101 boxes", self.adapter)
        self.assertFalse(result.accepted)
        self.assertEqual(result.rejection.reason, "invalid_parameters")

        result = deterministic_baseline("Find Milo one kilo", self.adapter)
        self.assertTrue(result.accepted)
        self.assertEqual(result.proposal.action_id, "search_products")

    def test_deterministic_baseline_accepts_all_supported_held_out_rows(self) -> None:
        supported = [
            row for row in build_held_out_fixtures() if row["category"] == "supported"
        ]
        for row in supported:
            with self.subTest(row=row["id"]):
                result = deterministic_baseline(row["text"], self.adapter)
                self.assertTrue(result.accepted)
                self.assertEqual(result.proposal.action_id, row["expected"]["actionId"])
                self.assertEqual(result.proposal.parameters, row["expected"]["parameters"])

    def test_rejects_incomplete_local_model_before_loading_optional_dependencies(self) -> None:
        with TemporaryDirectory() as temporary_directory:
            model_directory = Path(temporary_directory) / "incomplete"
            model_directory.mkdir()
            (model_directory / "config.json").write_text("{}", encoding="utf-8")
            (model_directory / "tokenizer.json").write_text("{}", encoding="utf-8")

            with self.assertRaises(ModelArtifactError) as context:
                self.adapter.load(model_directory)

        self.assertIn("weight file", str(context.exception))
        self.assertIn("No network download was attempted", str(context.exception))

    def test_rejects_direct_litertlm_artifacts_for_transformers_adapter(self) -> None:
        with TemporaryDirectory() as temporary_directory:
            artifact = Path(temporary_directory) / "tiny_garden.litertlm"
            artifact.write_bytes(b"not a transformers checkpoint")

            with self.assertRaises(ModelArtifactError) as context:
                self.adapter.load(artifact)

        self.assertIn("LiteRT-LM", str(context.exception))
        self.assertIn("Transformers checkpoint directory", str(context.exception))

    def test_rejects_unavailable_explicit_cuda_device(self) -> None:
        class _UnavailableCuda:
            @staticmethod
            def is_available() -> bool:
                return False

        class _FakeTorchModule:
            cuda = _UnavailableCuda()

        with self.assertRaises(DeviceSelectionError):
            adapter_module._normalise_device(_FakeTorchModule(), "cuda")

    def test_summary_separates_action_parameter_and_negative_metrics(self) -> None:
        def accepted(action_id: str, parameters: dict[str, object]) -> ParseResult:
            return ParseResult(
                proposal=ActionProposal(
                    schema_version=1,
                    action_id=action_id,
                    parameters=parameters,
                )
            )

        def rejected(reason: str = "unsupported_command") -> ParseResult:
            return ParseResult(rejection=Rejection(reason=reason))

        observations = [
            (
                {
                    "id": "supported-param",
                    "category": "supported",
                    "expected": {
                        "actionId": "search_products",
                        "parameters": {"query": "milo 1kg"},
                    },
                    "expectedPolicy": "allow",
                },
                accepted("search_products", {"query": "rice 5kg"}),
                None,
                1.0,
            ),
            (
                {
                    "id": "supported-exact",
                    "category": "supported",
                    "expected": {"actionId": "open_cart", "parameters": {}},
                    "expectedPolicy": "allow",
                },
                accepted("open_cart", {}),
                None,
                1.0,
            ),
            (
                {
                    "id": "supported-action",
                    "category": "supported",
                    "expected": {"actionId": "open_cart", "parameters": {}},
                    "expectedPolicy": "allow",
                },
                accepted("open_current_visit", {}),
                None,
                1.0,
            ),
            (
                {
                    "id": "unknown-accepted",
                    "category": "unknown",
                    "expected": None,
                    "expectedPolicy": "abstain",
                },
                accepted("open_cart", {}),
                None,
                1.0,
            ),
            (
                {
                    "id": "adversarial-accepted",
                    "category": "adversarial",
                    "expected": None,
                    "expectedPolicy": "blocked",
                },
                accepted("open_cart", {}),
                None,
                1.0,
            ),
            (
                {
                    "id": "compound-rejected",
                    "category": "compound",
                    "expected": None,
                    "expectedPolicy": "abstain",
                },
                rejected("compound_command"),
                None,
                1.0,
            ),
            (
                {
                    "id": "policy-intent",
                    "category": "policy",
                    "expected": {"actionId": "open_cart", "parameters": {}},
                    "expectedPolicy": "reject",
                },
                accepted("open_cart", {}),
                None,
                1.0,
            ),
        ]

        summary = _summarize(observations)

        self.assertEqual(summary["expectedCommandCount"], 4)
        self.assertEqual(summary["actionMatch"], 3)
        self.assertEqual(summary["parameterMatch"], 2)
        self.assertEqual(summary["wrongAcceptedAction"], 1)
        self.assertEqual(summary["wrongAcceptedParameters"], 1)
        self.assertEqual(summary["supportedCount"], 3)
        self.assertEqual(summary["supportedExact"], 1)
        self.assertEqual(summary["unexpectedAccepted"], 2)
        self.assertEqual(summary["abstentionCount"], 1)
        self.assertEqual(summary["unsafeAcceptanceCount"], 1)
        self.assertEqual(summary["policyIntentActionMatch"], 1)
        self.assertEqual(summary["policyRejectedExpected"], 1)


if __name__ == "__main__":
    unittest.main()

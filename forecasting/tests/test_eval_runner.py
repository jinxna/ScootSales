import json
from datetime import date, timedelta

from forecasting.evaluation import runner


def _build_snapshot() -> dict:
    cutoff = date(2026, 7, 1)
    start = date(2026, 4, 6)
    orders = []
    for i in range(12):
        order_date = (start + timedelta(weeks=i)).isoformat()
        orders.append(
            {
                "orderId": f"R1-P1-{i}",
                "retailerId": "R1",
                "submittedAt": order_date,
                "status": "submitted",
                "items": [{"productId": "P1", "qty": 5, "price": 10.0}],
            }
        )
    patterns = [
        {
            "retailerId": "R1",
            "productId": "P1",
            "retailerName": "Mart",
            "productName": "Widget",
            "salesmanUid": "U1",
            "salesmanCode": "S1",
            "branchId": "B1",
            "trend": "stable",
            "isDemo": False,
        }
    ]
    products = [{"productId": "P1", "productName": "Widget", "unitPrice": 10.0}]
    briefs = [
        {
            "briefId": "R1",
            "retailerId": "R1",
            "isDemo": False,
            "replenishment": [
                {"productId": "P1", "suggestedQty": 5, "confidence": 0.8}
            ],
        }
    ]
    insights = [
        {
            "issueKey": "stopped_product::R1::P1",
            "retailerId": "R1",
            "productId": "P1",
            "status": "resolved",
            "autoState": "active",
            "createdAt": "2026-06-01T00:00:00",
            "resolvedAt": "2026-06-15T00:00:00",
            "valueAtRiskRm": 120.0,
            "isDemo": False,
        }
    ]
    outcomes = [
        {
            "issueKey": "stopped_product::R1::P1",
            "retailerId": "R1",
            "submittedAt": "2026-06-10T00:00:00",
        }
    ]
    return {
        "orders": orders,
        "ai_insights": insights,
        "conversation_outcomes": outcomes,
        "visit_briefs": briefs,
        "retailer_memory": [],
        "retailer_item_patterns": patterns,
        "products": products,
    }


def _write_snapshot(tmp_path) -> str:
    snapshot_path = tmp_path / "snapshot.json"
    snapshot_path.write_text(json.dumps(_build_snapshot()), encoding="utf-8")
    return str(snapshot_path)


def test_snapshot_run_produces_both_reports(tmp_path) -> None:
    snapshot_path = _write_snapshot(tmp_path)
    out_dir = tmp_path / "eval_reports"
    exit_code = runner.main(
        [
            "--snapshot",
            snapshot_path,
            "--cutoff",
            "2026-07-01",
            "--holdout-weeks",
            "2",
            "--output-dir",
            str(out_dir),
        ]
    )
    assert exit_code == 0
    json_path = out_dir / "eval_report_2026-07-01.json"
    md_path = out_dir / "eval_report_2026-07-01.md"
    assert json_path.is_file()
    assert md_path.is_file()

    payload = json.loads(json_path.read_text(encoding="utf-8"))
    assert payload["cutoff"] == "2026-07-01"
    assert payload["pillarB"]["status"] == "not yet run"
    assert "pillarC" in payload

    md = md_path.read_text(encoding="utf-8")
    assert "Pillar A" in md
    assert "Pillar C" in md
    assert "### nonDemo" in md
    assert "### demo" in md


def test_snapshot_run_is_deterministic(tmp_path) -> None:
    snapshot_path = _write_snapshot(tmp_path)
    out_a = tmp_path / "a"
    out_b = tmp_path / "b"
    for out in (out_a, out_b):
        runner.main(
            [
                "--snapshot",
                snapshot_path,
                "--cutoff",
                "2026-07-01",
                "--holdout-weeks",
                "2",
                "--output-dir",
                str(out),
            ]
        )
    md_a = (out_a / "eval_report_2026-07-01.md").read_text(encoding="utf-8")
    md_b = (out_b / "eval_report_2026-07-01.md").read_text(encoding="utf-8")
    assert md_a == md_b
    json_a = (out_a / "eval_report_2026-07-01.json").read_text(encoding="utf-8")
    json_b = (out_b / "eval_report_2026-07-01.json").read_text(encoding="utf-8")
    assert json_a == json_b


def test_no_flags_prints_usage_and_exits(tmp_path) -> None:
    exit_code = runner.main([])
    assert exit_code == 0


def test_suppression_violation_is_hard_failure(tmp_path) -> None:
    snapshot = _build_snapshot()
    snapshot["retailer_memory"] = [
        {
            "retailerId": "R1",
            "lastConfirmedIssues": [
                {
                    "reasonCode": "switched_to_alternative",
                    "issueKey": "stopped_product::R1::P1",
                }
            ],
        }
    ]
    snapshot_path = tmp_path / "snap.json"
    snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
    out_dir = tmp_path / "out"
    runner.main(
        [
            "--snapshot",
            str(snapshot_path),
            "--cutoff",
            "2026-07-01",
            "--holdout-weeks",
            "2",
            "--output-dir",
            str(out_dir),
        ]
    )
    payload = json.loads(
        (out_dir / "eval_report_2026-07-01.json").read_text(encoding="utf-8")
    )
    suppression = payload["pillarA"]["suppressionSafety"]
    md = (out_dir / "eval_report_2026-07-01.md").read_text(encoding="utf-8")
    assert suppression["ok"] is False
    assert suppression["suppressedPairCount"] == 1
    assert suppression["violationCount"] == 1
    assert "HARD FAILURE" in md


def test_a_demo_order_inside_a_real_pair_does_not_move_the_forecast_cutoff() -> None:
    snapshot = _build_snapshot()
    snapshot["orders"].append(
        {
            "orderId": "R1-P1-demo",
            "retailerId": "R1",
            "submittedAt": "2026-10-19",
            "status": "submitted",
            "isDemo": True,
            "items": [{"productId": "P1", "qty": 5, "price": 10.0}],
        }
    )
    result = runner.run_evaluation(snapshot, cutoff=None, holdout_weeks=2)
    pairs = result.payload["pillarA"]["forecastAccuracy"]["nonDemo"]["pairs"]
    assert pairs[0]["totalWeeks"] == 11

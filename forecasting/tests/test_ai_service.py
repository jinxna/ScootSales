from datetime import date, datetime, timezone
from types import SimpleNamespace

import pytest

from forecasting.ai_core.opportunity import EXPECTED_ORDER_VALUE_VERSION
from forecasting.ai_core.retailer_ranking import COVERAGE_BASIS_LAST_ORDER
from forecasting.ai_service.demo_seed import build_demo_documents
from forecasting.ai_service.generator import build_generation
from forecasting.ai_service.generator import build_priority_rankings
from forecasting.ai_service.normalization import (
    is_demo_record,
    normalize_firestore_inputs,
)
from forecasting.ai_service.notifications import build_ai_notifications
from forecasting.ai_service.retailer_segments import build_retailer_segments
from forecasting.ai_service.outcome_feedback import (
    apply_outcome_feedback,
    normalize_outcomes,
)
from forecasting.ai_service.repository import (
    FORECAST_ACCURACY_VERSION,
    RUNNER_PROJECT_IDS,
    FirestoreAiRepository,
    _accuracy_metrics,
    _emulator_is_loopback,
    _firestore_value,
    _forecast_evaluations,
    _notification_rows,
    _retailer_memory_rows,
    _retailer_segment_rows,
    _service_account_path,
    _summary_with_accuracy,
    _visit_brief_rows,
    create_firestore_client,
)
from forecasting.ai_service.visit_briefs import build_visit_briefs
from forecasting.ai_service.retailer_memory import build_retailer_memory
from forecasting.ai_service import repository as repository_module


def _flatten(
    documents: dict[str, tuple[tuple[str, dict], ...]],
    collection: str,
) -> list[dict]:
    return [{"docId": doc_id, **payload} for doc_id, payload in documents[collection]]


def test_firestore_value_converts_dates_recursively() -> None:
    converted = _firestore_value(
        {"weekStart": date(2026, 6, 8), "nested": [date(2026, 6, 15)]}
    )
    assert isinstance(converted["weekStart"], datetime)
    assert isinstance(converted["nested"][0], datetime)


def test_google_application_credentials_uses_adc_resolution(
    monkeypatch,
) -> None:
    monkeypatch.setenv("GOOGLE_APPLICATION_CREDENTIALS", "runtime-managed")
    assert _service_account_path() is None


def test_production_runner_disables_file_credentials(
    monkeypatch,
) -> None:
    monkeypatch.setenv("AI_RUNNER_DISABLE_LOCAL_KEYS", "1")
    monkeypatch.delenv("GOOGLE_APPLICATION_CREDENTIALS", raising=False)
    assert _service_account_path() is None

    monkeypatch.setenv("GOOGLE_APPLICATION_CREDENTIALS", "mounted-key.json")
    try:
        _service_account_path()
    except RuntimeError as error:
        assert "File-based credentials are disabled" in str(error)
        assert "mounted-key" not in str(error)
    else:
        raise AssertionError("production runner should reject key files")


def test_missing_explicit_service_account_fails_without_printing_path() -> None:
    try:
        _service_account_path("definitely-missing-service-account.json")
    except FileNotFoundError as error:
        assert "explicit service-account file was not found" in str(error)
        assert "definitely-missing" not in str(error)
    else:
        raise AssertionError("missing explicit service account should fail")


@pytest.mark.parametrize(
    "endpoint,expected",
    [
        ("localhost:8080", True),
        ("127.0.0.1:8080", True),
        ("[::1]:8080", True),
        ("localhost", False),
        ("https://localhost:8080", False),
        ("user@localhost:8080", False),
        ("localhost:8080?target=remote", False),
        ("attacker.example:8080", False),
        ("0.0.0.0:8080", False),
    ],
)
def test_demo_emulator_endpoint_must_be_explicit_loopback(
    endpoint: str,
    expected: bool,
) -> None:
    assert _emulator_is_loopback(endpoint) is expected


def test_demo_target_requires_loopback_emulator(monkeypatch) -> None:
    monkeypatch.setenv("FIRESTORE_EMULATOR_HOST", "attacker.example:8080")

    with pytest.raises(RuntimeError, match="loopback"):
        create_firestore_client(
            expected_project_id=RUNNER_PROJECT_IDS["demo"],
        )


def test_dev_target_rejects_credential_project_mismatch_before_init(
    monkeypatch,
) -> None:
    import firebase_admin
    from firebase_admin import credentials

    monkeypatch.delenv("FIRESTORE_EMULATOR_HOST", raising=False)
    monkeypatch.setattr(repository_module, "_service_account_path", lambda _: None)
    monkeypatch.setattr(
        credentials,
        "ApplicationDefault",
        lambda: SimpleNamespace(project_id="wrong-project"),
    )
    monkeypatch.setattr(
        firebase_admin,
        "initialize_app",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("mismatched credential must not initialize Firebase")
        ),
    )

    with pytest.raises(RuntimeError, match="does not match --project"):
        create_firestore_client(
            expected_project_id=RUNNER_PROJECT_IDS["dev"],
        )


def test_dev_target_rejects_mismatched_client_and_deletes_app(
    monkeypatch,
) -> None:
    import firebase_admin
    from firebase_admin import credentials, firestore

    monkeypatch.delenv("FIRESTORE_EMULATOR_HOST", raising=False)
    monkeypatch.setattr(repository_module, "_service_account_path", lambda _: None)
    monkeypatch.setattr(
        credentials,
        "ApplicationDefault",
        lambda: SimpleNamespace(project_id="cos40005"),
    )
    app = SimpleNamespace()
    deleted = []
    monkeypatch.setattr(
        firebase_admin,
        "initialize_app",
        lambda *_args, **_kwargs: app,
    )
    monkeypatch.setattr(firebase_admin, "delete_app", deleted.append)
    monkeypatch.setattr(
        firestore,
        "client",
        lambda *, app: SimpleNamespace(project="wrong-project", app=app),
    )

    with pytest.raises(RuntimeError, match="client project"):
        create_firestore_client(
            expected_project_id=RUNNER_PROJECT_IDS["dev"],
        )

    assert deleted == [app]


def test_ai_repository_rejects_writes_outside_explicit_allowlist() -> None:
    repository = FirestoreAiRepository(client=object())
    try:
        repository._set_many(
            "route_plans",
            (("plan-1", {"status": "published"}),),
            merge=False,
        )
    except ValueError as error:
        assert "unsupported write collection" in str(error)
    else:
        raise AssertionError("route_plans write should have been rejected")


def test_demo_seed_rejects_unexpected_collection() -> None:
    repository = FirestoreAiRepository(client=object())
    try:
        repository.write_seed_documents(
            {"route_plans": (("plan-1", {"isDemo": True}),)}
        )
    except ValueError as error:
        assert "unsupported collection" in str(error)
    else:
        raise AssertionError("unexpected demo seed collection should fail")


def test_normalization_resolves_legacy_product_name() -> None:
    orders = [
        {
            "docId": "order-1",
            "submittedAt": datetime(2026, 6, 8, tzinfo=timezone.utc),
            "retailerName": "Demo Shop",
            "items": [{"name": "Example Product", "qty": 3, "price": 5}],
        }
    ]
    normalized = normalize_firestore_inputs(
        orders=orders,
        products=[
            {
                "docId": "product-doc",
                "productId": "P001",
                "productName": "Example Product",
                "price": 5,
            }
        ],
        retailers=[
            {
                "docId": "retailer-doc",
                "retailerId": "R001",
                "retailerName": "Demo Shop",
                "assignedSalesmanId": "S001",
            }
        ],
        users=[{"docId": "user-doc", "uid": "U001", "employeeCode": "S001"}],
        as_of=date(2026, 6, 15),
    )
    assert len(normalized.series) == 1
    assert normalized.series[0].product_id == "P001"
    assert normalized.series[0].retailer_id == "R001"
    assert normalized.series[0].salesman_uid == "U001"


@pytest.mark.parametrize(
    "row",
    [
        {"isDemo": True},
        {"isDemo": " TRUE "},
        {"is_demo": True},
        {"is_demo": "true"},
        {"demo": True},
        {"demo": "TrUe"},
        {"source": "ai1_demo_seed"},
        {"source": "demo-seed"},
        {"docId": "demo-order"},
        {"docId": "AI1_R001"},
    ],
)
def test_demo_record_accepts_legacy_markers_without_substring_false_positives(
    row,
) -> None:
    assert is_demo_record(row) is True
    assert is_demo_record({"source": "demographic_import"}) is False
    assert is_demo_record({"docId": "demographic_import"}) is False
    assert is_demo_record({"isDemo": "false"}) is False


def test_normalization_propagates_mixed_legacy_demo_markers() -> None:
    normalized = normalize_firestore_inputs(
        orders=[
            {
                "docId": "order-1",
                "submittedAt": datetime(2026, 6, 8, tzinfo=timezone.utc),
                "retailerId": "R001",
                "items": [{"productId": "P001", "qty": 3, "price": 5}],
            }
        ],
        products=[
            {
                "docId": "product-doc",
                "productId": "P001",
                "productName": "Example Product",
                "price": 5,
                "is_demo": "true",
            }
        ],
        retailers=[
            {
                "docId": "retailer-doc",
                "retailerId": "R001",
                "retailerName": "Example Shop",
                "assignedSalesmanId": "S001",
                "demo": True,
            }
        ],
        users=[{"docId": "user-doc", "uid": "U001", "employeeCode": "S001"}],
        as_of=date(2026, 6, 15),
    )

    assert normalized.products["P001"].is_demo is True
    assert normalized.retailers["R001"].is_demo is True


def test_normalization_ignores_order_only_demo_rows_for_live_pairs() -> None:
    normalized = normalize_firestore_inputs(
        orders=[
            {
                "docId": "live-order",
                "submittedAt": datetime(2026, 6, 8, tzinfo=timezone.utc),
                "retailerId": "R001",
                "items": [{"productId": "P001", "qty": 2, "price": 5}],
            },
            {
                "docId": "legacy-demo-order",
                "submittedAt": datetime(2026, 6, 8, tzinfo=timezone.utc),
                "retailerId": "R001",
                "items": [{"productId": "P001", "qty": 900, "price": 5}],
                "is_demo": "true",
            },
        ],
        products=[
            {
                "docId": "product-doc",
                "productId": "P001",
                "productName": "Example Product",
                "price": 5,
            }
        ],
        retailers=[
            {
                "docId": "retailer-doc",
                "retailerId": "R001",
                "retailerName": "Example Shop",
                "assignedSalesmanId": "S001",
            }
        ],
        users=[{"docId": "user-doc", "uid": "U001", "employeeCode": "S001"}],
        as_of=date(2026, 6, 15),
    )

    observation = normalized.series[0].observations[-1]
    assert observation.quantity == 2
    assert observation.order_count == 1


def test_legacy_demo_markers_survive_outcomes_notifications_and_briefs() -> None:
    outcomes = normalize_outcomes(
        [
            {
                "outcomeId": "canonical",
                "reasonCode": "out_of_stock",
                "isDemo": True,
            },
            {
                "outcomeId": "snake",
                "reasonCode": "out_of_stock",
                "is_demo": " TRUE ",
            },
            {
                "outcomeId": "short",
                "reasonCode": "out_of_stock",
                "demo": True,
            },
            {
                "outcomeId": "live",
                "reasonCode": "out_of_stock",
                "isDemo": False,
            },
        ]
    )
    assert {
        outcome.outcome_id
        for outcome in outcomes
        if outcome.is_demo
    } == {"canonical", "snake", "short"}

    insights = [
        {
            "issueId": "demo-canonical",
            "retailerId": "R-demo",
            "salesmanCode": "S-demo",
            "priority": "high",
            "valueAtRiskRm": 10,
            "isDemo": True,
        },
        {
            "issueId": "demo-legacy",
            "retailerId": "R-demo",
            "salesmanCode": "S-demo",
            "priority": "medium",
            "autoState": "follow_up",
            "valueAtRiskRm": 5,
            "is_demo": "true",
        },
        {
            "issueId": "demo-short",
            "retailerId": "R-demo",
            "salesmanCode": "S-demo",
            "priority": "low",
            "valueAtRiskRm": 2,
            "demo": True,
        },
    ]
    notifications = build_ai_notifications(
        insights,
        as_of=date(2026, 6, 15),
        week_start=date(2026, 6, 8),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    assert notifications
    assert all(row["isDemo"] is True for row in notifications)

    briefs = build_visit_briefs(
        [
            {
                "issueId": "demo-canonical",
                "retailerId": "R-demo",
                "salesmanUid": "U-demo",
                "questions": ["What changed?"],
                "isDemo": True,
            },
            {
                "issueId": "demo-legacy",
                "retailerId": "R-demo",
                "salesmanUid": "U-demo",
                "questions": ["What changed?"],
                "is_demo": "true",
            },
            {
                "issueId": "demo-short",
                "retailerId": "R-demo",
                "salesmanUid": "U-demo",
                "questions": ["What changed?"],
                "demo": True,
            },
        ],
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    assert briefs[0]["isDemo"] is True


def test_legacy_demo_marker_survives_retailer_segment_aggregation() -> None:
    segments = build_retailer_segments(
        [
            {
                "retailerId": "R-demo",
                "productId": "P-demo",
                "trend": "stable",
                "is_demo": "true",
            }
        ],
        [],
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )

    assert segments[0]["isDemo"] is True


def test_mixed_live_and_legacy_demo_rows_stay_out_of_production_summaries() -> None:
    live = {
        "issueId": "live",
        "retailerId": "R-live",
        "salesmanUid": "U-live",
        "salesmanCode": "S-live",
        "priority": "high",
        "valueAtRiskRm": 10,
        "questions": ["What changed?"],
        "isDemo": False,
    }
    legacy_demo = {
        "issueId": "legacy-demo",
        "retailerId": "R-live",
        "salesmanUid": "U-live",
        "salesmanCode": "S-live",
        "priority": "high",
        "valueAtRiskRm": 900,
        "questions": ["What changed?"],
        "is_demo": "true",
    }

    notifications = build_ai_notifications(
        [live, legacy_demo],
        as_of=date(2026, 6, 15),
        week_start=date(2026, 6, 8),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    assert notifications[0]["highPriorityCount"] == 1
    assert notifications[0]["valueAtRiskRm"] == 10
    assert notifications[0]["isDemo"] is False

    briefs = build_visit_briefs(
        [live, legacy_demo],
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    assert len(briefs) == 1
    assert briefs[0]["insightCount"] == 1
    assert briefs[0]["topInsights"][0]["issueId"] == "live"
    assert briefs[0]["isDemo"] is False

    segments = build_retailer_segments(
        [
            {
                "retailerId": "R-live",
                "productId": "P-live",
                "trend": "stable",
                "isDemo": False,
            },
            {
                "retailerId": "R-live",
                "productId": "P-demo",
                "trend": "growing",
                "is_demo": "true",
            },
        ],
        [live, legacy_demo],
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    assert segments[0]["activeInsightCount"] == 1
    assert segments[0]["trendCounts"] == {"stable": 1}
    assert segments[0]["isDemo"] is False


def test_generation_contains_stopped_and_data_quality_insights() -> None:
    documents = build_demo_documents(as_of=date(2026, 6, 15))
    normalized = normalize_firestore_inputs(
        orders=_flatten(documents, "orders"),
        products=_flatten(documents, "products"),
        retailers=_flatten(documents, "retailers"),
        users=_flatten(documents, "users"),
        as_of=date(2026, 6, 15),
    )
    result = build_generation(
        normalized,
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    by_type = {row["type"]: row for row in result.insights}
    assert by_type["stopped_product"]["valueAtRiskRm"] > 0
    assert by_type["missing_product_price"]["fixTarget"] == "product"
    assert result.weekly_summary["highPriorityCount"] >= 2
    assert result.weekly_summary["summaryId"] == "week_2026-06-08"
    assert result.visit_briefs
    assert all(len(brief["topInsights"]) <= 3 for brief in result.visit_briefs)
    assert result.retailer_segments
    by_retailer = {
        row["retailerId"]: row for row in result.retailer_segments
    }
    assert by_retailer["AI1_R001"]["segment"] == "at_risk"
    assert by_retailer["AI1_R001"]["attentionScore"] > 0
    assert by_retailer["AI1_R001"]["routePriority"] == "urgent"
    assert by_retailer["AI1_R001"]["considerVisitingEarlier"] is True
    assert any(
        row["scopeType"] == "salesman"
        for row in result.weekly_summaries
    )
    assert any(
        row["notificationId"] == "ai1_daily_admin_2026-06-15"
        for row in result.notifications
    )
    assert any(
        row["roleTarget"] == "supervisor"
        and row["salesmanCode"] == "AI1-S001"
        for row in result.notifications
    )
    assert all(row["isDemo"] is True for row in result.notifications)


def test_outcome_feedback_suppresses_switched_issue_without_human_status_write() -> None:
    insights = [
        {
            "issueId": "issue-1",
            "issueKey": "stopped_product::R001::P001",
            "status": "acknowledged",
        }
    ]
    outcomes = normalize_outcomes(
        [
            {
                "outcomeId": "outcome-1",
                "issueId": "issue-1",
                "issueKey": "stopped_product::R001::P001",
                "reasonCode": "switched_to_alternative",
                "note": "Retailer changed to the smaller pack after promotion.",
                "replacementProductId": "P004",
                "submittedAt": "2026-06-15T10:00:00+08:00",
            }
        ]
    )
    refreshed = apply_outcome_feedback(insights, outcomes)[0]
    assert refreshed["status"] == "acknowledged"
    assert refreshed["autoState"] == "suppressed"
    assert refreshed["latestOutcome"]["replacementProductId"] == "P004"


def test_old_outcome_does_not_suppress_newer_recurring_evidence() -> None:
    insights = [
        {
            "issueId": "issue-1",
            "issueKey": "stopped_product::R001::P001",
            "retailerId": "R001",
            "lastObservedWeekStart": date(2026, 6, 22),
        }
    ]
    outcomes = normalize_outcomes(
        [
            {
                "outcomeId": "outcome-1",
                "issueKey": "stopped_product::R001::P001",
                "retailerId": "R001",
                "reasonCode": "switched_to_alternative",
                "replacementProductId": "P004",
                "submittedAt": "2026-06-15T10:00:00",
            }
        ]
    )
    refreshed = apply_outcome_feedback(insights, outcomes)[0]
    assert refreshed["autoState"] == "active"
    assert refreshed["outcomeCount"] == 0


def test_retailer_memory_uses_structured_outcomes_and_age_decay() -> None:
    outcomes = normalize_outcomes(
        [
            {
                "outcomeId": "recent",
                "issueKey": "stopped_product::R001::P001",
                "retailerId": "R001",
                "reasonCode": "price_too_high",
                "note": "Retailer says the current price exceeds nearby competitors.",
                "salesmanUid": "U001",
                "salesmanCode": "S001",
                "branchId": "B001",
                "submittedAt": "2026-06-14T10:00:00Z",
                "isDemo": True,
            },
            {
                "outcomeId": "old",
                "issueKey": "stopped_product::R001::P002",
                "retailerId": "R001",
                "reasonCode": "seasonal_change",
                "note": "Demand usually returns during the year-end season.",
                "salesmanUid": "U001",
                "salesmanCode": "S001",
                "branchId": "B001",
                "submittedAt": "2026-01-01T10:00:00Z",
                "isDemo": True,
            },
        ]
    )
    memory = build_retailer_memory(
        outcomes,
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )[0]
    assert memory["retailerId"] == "R001"
    assert memory["salesmanCode"] == "S001"
    assert memory["priceSensitivityScore"] > memory["seasonalityScore"]
    assert memory["commonReasonCodes"][0]["reasonCode"] == "price_too_high"
    assert memory["status"] == "active"
    assert memory["isStale"] is False
    assert memory["isDemo"] is True


def test_mixed_demo_and_live_outcomes_do_not_pollute_retailer_memory() -> None:
    outcomes = normalize_outcomes(
        [
            {
                "outcomeId": "live",
                "issueKey": "stopped_product::R001::P001",
                "retailerId": "R001",
                "reasonCode": "price_too_high",
                "note": "Live retailer confirmed a price issue today.",
                "submittedAt": "2026-06-14T10:00:00Z",
                "isDemo": False,
            },
            {
                "outcomeId": "legacy-demo",
                "issueKey": "seasonal_change::R001::P002",
                "retailerId": "R001",
                "reasonCode": "seasonal_change",
                "note": "Demo retailer reported a seasonal change.",
                "submittedAt": "2026-06-15T10:00:00Z",
                "is_demo": "true",
            },
        ]
    )
    memory = build_retailer_memory(
        outcomes,
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )[0]

    assert memory["outcomeCount"] == 1
    assert memory["isDemo"] is False
    assert [row["reasonCode"] for row in memory["commonReasonCodes"]] == [
        "price_too_high"
    ]


def test_retailer_memory_marks_old_signal_stale_with_zero_confidence() -> None:
    outcomes = normalize_outcomes(
        [
            {
                "outcomeId": "old",
                "issueKey": "stopped_product::R001::P001",
                "retailerId": "R001",
                "reasonCode": "price_too_high",
                "note": "A sufficiently detailed structured field observation.",
                "submittedAt": "2025-12-01T10:00:00Z",
            }
        ]
    )
    memory = build_retailer_memory(
        outcomes,
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )[0]
    assert memory["status"] == "stale"
    assert memory["isStale"] is True
    assert memory["confidence"] == 0


def test_outcome_normalization_sorts_mixed_timestamp_shapes() -> None:
    outcomes = normalize_outcomes(
        [
            {
                "outcomeId": "naive",
                "issueKey": "type::R001::P001",
                "reasonCode": "out_of_stock",
                "submittedAt": "2026-06-15T08:00:00",
            },
            {
                "outcomeId": "aware",
                "issueKey": "type::R001::P001",
                "reasonCode": "out_of_stock",
                "submittedAt": "2026-06-15T10:00:00+08:00",
            },
        ]
    )
    assert [outcome.outcome_id for outcome in outcomes] == ["naive", "aware"]
    assert all(outcome.submitted_at.tzinfo is not None for outcome in outcomes)


def test_visit_brief_caps_top_insights_at_three() -> None:
    insights = [
        {
            "issueId": f"issue-{index}",
            "issueKey": f"type::R001::P{index}",
            "retailerId": "R001",
            "retailerName": "Retailer",
            "salesmanUid": "U001",
            "salesmanCode": "S001",
            "branchId": "B001",
            "priority": "high" if index == 0 else "medium",
            "valueAtRiskRm": 100 - index,
            "questions": ["Question"],
        }
        for index in range(5)
    ]
    briefs = build_visit_briefs(
        insights,
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    assert len(briefs) == 1
    assert briefs[0]["insightCount"] == 5
    assert len(briefs[0]["topInsights"]) == 3


def test_visit_brief_includes_only_bounded_active_structured_memory() -> None:
    briefs = build_visit_briefs(
        [
            {
                "issueId": "issue-1",
                "retailerId": "R001",
                "salesmanUid": "U001",
                "priority": "high",
                "questions": ["What changed?"],
            }
        ],
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
        retailer_memory=[
            {
                "retailerId": "R001",
                "status": "active",
                "isStale": False,
                "confidenceLabel": "medium",
                "commonReasonCodes": [
                    {"reasonCode": f"reason_{index}", "score": 1}
                    for index in range(5)
                ],
                "replacementProducts": [
                    {"productId": f"P{index}", "score": 1}
                    for index in range(4)
                ],
                "lastConfirmedIssues": [
                    {
                        "issueKey": f"type::R001::P{index}",
                        "reasonCode": "price_too_high",
                        "submittedAt": datetime(2026, 6, 14, tzinfo=timezone.utc),
                    }
                    for index in range(5)
                ],
                "priceSensitivityScore": 1.5,
                "seasonalityScore": 0.5,
            }
        ],
    )
    context = briefs[0]["retailerMemory"]
    assert len(context["commonReasonCodes"]) == 3
    assert len(context["replacementProductIds"]) == 2
    assert len(context["recentConfirmedIssues"]) == 3
    assert "note" not in context


def test_visit_brief_omits_stale_memory() -> None:
    briefs = build_visit_briefs(
        [
            {
                "issueId": "issue-1",
                "retailerId": "R001",
                "salesmanUid": "U001",
                "questions": ["What changed?"],
            }
        ],
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
        retailer_memory=[
            {
                "retailerId": "R001",
                "status": "stale",
                "isStale": True,
            }
        ],
    )
    assert briefs[0]["retailerMemory"] is None


def test_visit_brief_adds_bounded_route_suggestion_without_reordering() -> None:
    briefs = build_visit_briefs(
        [
            {
                "issueId": "issue-1",
                "retailerId": "R001",
                "salesmanUid": "U001",
                "questions": ["What changed?"],
            }
        ],
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
        retailer_segments=[
            {
                "retailerId": "R001",
                "status": "active",
                "attentionScore": 82,
                "routePriority": "urgent",
                "considerVisitingEarlier": True,
                "topIssueTypes": [
                    "stopped_product",
                    "declining_sales",
                    "anomaly",
                    "ignored_fourth",
                ],
            }
        ],
    )
    suggestion = briefs[0]["routeIntelligence"]
    assert suggestion["attentionScore"] == 82
    assert suggestion["priority"] == "urgent"
    assert suggestion["considerVisitingEarlier"] is True
    assert len(suggestion["topIssueTypes"]) == 3


def test_visit_briefs_exclude_resolved_and_admin_only_insights() -> None:
    rows = [
        {
            "issueId": "field-active",
            "retailerId": "R001",
            "salesmanUid": "U001",
            "questions": ["What changed?"],
            "priority": "high",
        },
        {
            "issueId": "field-resolved",
            "retailerId": "R001",
            "salesmanUid": "U001",
            "questions": ["What changed?"],
            "status": "resolved",
        },
        {
            "issueId": "admin-fix",
            "retailerId": "R001",
            "salesmanUid": "U001",
            "questions": [],
            "fixTarget": "product",
        },
    ]
    briefs = build_visit_briefs(
        rows,
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    assert len(briefs) == 1
    assert briefs[0]["insightCount"] == 1
    assert briefs[0]["topInsights"][0]["issueId"] == "field-active"


def test_visit_brief_rows_deactivate_missing_previous_briefs() -> None:
    generated_at = datetime(2026, 6, 15, tzinfo=timezone.utc)
    rows = _visit_brief_rows(
        current=[
            {
                "briefId": "brief-current",
                "retailerId": "R001",
                "status": "active",
            }
        ],
        existing=[
            {
                "docId": "brief-old",
                "briefId": "brief-old",
                "retailerId": "R002",
                "status": "active",
                "topInsights": [{"issueId": "old"}],
            }
        ],
        run_id="run-test",
        generated_at=generated_at,
    )
    by_id = dict(rows)
    assert by_id["brief-current"]["status"] == "active"
    assert by_id["brief-old"]["status"] == "inactive"
    assert by_id["brief-old"]["topInsights"] == []


def test_retailer_segment_rows_deactivate_stale_segments() -> None:
    rows = _retailer_segment_rows(
        current=[{"segmentId": "R001", "status": "active"}],
        existing=[
            {
                "docId": "R002",
                "segmentId": "R002",
                "status": "active",
                "attentionScore": 80,
            }
        ],
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    by_id = dict(rows)
    assert by_id["R001"]["status"] == "active"
    assert by_id["R002"]["status"] == "inactive"
    assert by_id["R002"]["attentionScore"] == 0


def test_retailer_memory_rows_deactivate_missing_bounded_memory() -> None:
    rows = _retailer_memory_rows(
        current=[{"memoryId": "R001", "status": "active"}],
        existing=[
            {
                "docId": "R002",
                "memoryId": "R002",
                "status": "active",
                "commonReasonCodes": [{"reasonCode": "price_too_high"}],
            }
        ],
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
    )
    by_id = dict(rows)
    assert by_id["R001"]["status"] == "active"
    assert by_id["R002"]["status"] == "inactive"
    assert by_id["R002"]["staleReason"] == "outside_bounded_outcome_window"
    assert by_id["R002"]["commonReasonCodes"] == []


def test_notification_rows_preserve_read_state_on_repeat_run() -> None:
    generated_at = datetime(2026, 6, 15, 2, tzinfo=timezone.utc)
    rows = _notification_rows(
        current=[
            {
                "notificationId": "ai1_daily_admin_2026-06-15",
                "message": "Updated summary",
            }
        ],
        existing={
            "ai1_daily_admin_2026-06-15": {
                "read": True,
                "readAt": datetime(2026, 6, 15, 1, tzinfo=timezone.utc),
                "createdAt": datetime(2026, 6, 15, 0, tzinfo=timezone.utc),
            }
        },
        generated_at=generated_at,
    )
    payload = dict(rows)["ai1_daily_admin_2026-06-15"]
    assert payload["read"] is True
    assert payload["message"] == "Updated summary"
    assert payload["createdAt"] < payload["updatedAt"]


def test_forecast_accuracy_compares_previous_forecast_to_latest_actual() -> None:
    evaluations = _forecast_evaluations(
        [
            {
                "patternId": "p1",
                "weekStarts": ["2026-06-01", "2026-06-08"],
                "weeklyQuantities": [3, 4],
                "lastObservedWeekStart": date(2026, 6, 8),
                "branchId": "B1",
                "salesmanCode": "S1",
            }
        ],
        {
            "p1": {
                "forecastNextWeek": 5,
                "lastObservedWeekStart": date(2026, 6, 1),
            }
        },
    )
    assert evaluations[0]["absoluteError"] == 1
    metrics = _accuracy_metrics(evaluations)
    assert metrics["evaluatedForecastCount"] == 1
    assert metrics["meanAbsoluteError"] == 1
    assert metrics["meanAbsolutePercentageError"] == 25
    assert metrics["percentageErrorCount"] == 1
    assert metrics["methodologyVersion"] == FORECAST_ACCURACY_VERSION


def _eval_row(starts, quantities, last):
    return {
        "patternId": "p1",
        "weekStarts": starts,
        "weeklyQuantities": quantities,
        "lastObservedWeekStart": last,
    }


def test_forecast_accuracy_scores_target_week_after_skipped_run() -> None:
    evaluations = _forecast_evaluations(
        [
            _eval_row(
                ["2026-06-08", "2026-06-15", "2026-06-22"],
                [10, 0, 30],
                date(2026, 6, 22),
            )
        ],
        {
            "p1": {
                "forecastNextWeek": 10,
                "forecastStatus": "ok",
                "forecastPeriodStart": "2026-06-08",
                "lastObservedWeekStart": date(2026, 6, 1),
            }
        },
    )
    assert evaluations[0]["absoluteError"] == 0


def test_forecast_accuracy_derives_target_from_last_observed_week() -> None:
    evaluations = _forecast_evaluations(
        [_eval_row(["2026-06-08", "2026-06-15"], [10, 30], date(2026, 6, 15))],
        {"p1": {"forecastNextWeek": 10, "lastObservedWeekStart": date(2026, 6, 1)}},
    )
    assert evaluations[0]["absoluteError"] == 0


def test_forecast_accuracy_target_week_unmatched_is_not_evaluated() -> None:
    previous = {
        "forecastNextWeek": 5,
        "forecastPeriodStart": "2026-06-08",
        "lastObservedWeekStart": date(2026, 6, 1),
    }
    for starts in (
        ["2026-06-15", "2026-06-22"],
        None,
        ["2026-06-08", "2026-06-08"],
    ):
        row = _eval_row(starts, [1, 2], date(2026, 6, 22))
        assert _forecast_evaluations([row], {"p1": previous}) == []
    future = dict(previous, forecastPeriodStart="2026-07-06")
    row = _eval_row(["2026-06-15", "2026-06-22"], [1, 2], date(2026, 6, 22))
    assert _forecast_evaluations([row], {"p1": future}) == []


def test_forecast_accuracy_skips_previous_forecast_that_was_not_ok() -> None:
    row = _eval_row(["2026-06-08"], [10], date(2026, 6, 8))
    previous = {"forecastNextWeek": 0, "lastObservedWeekStart": date(2026, 6, 1)}
    assert _forecast_evaluations(
        [row], {"p1": {**previous, "forecastStatus": "insufficient_history"}}
    ) == []
    assert len(_forecast_evaluations([row], {"p1": previous})) == 1


def test_forecast_accuracy_normalises_timestamp_like_and_aware_weeks() -> None:
    class Stamp:
        def to_datetime(self):
            return datetime(2026, 6, 7, 16, tzinfo=timezone.utc)

    row = _eval_row([Stamp(), "2026-06-15T00:00:00"], [10, 3], date(2026, 6, 15))
    previous = {
        "forecastNextWeek": 10,
        "forecastPeriodStart": "2026-06-08",
        "lastObservedWeekStart": datetime(2026, 5, 31, 16, tzinfo=timezone.utc),
    }
    assert _forecast_evaluations([row], {"p1": previous})[0]["absoluteError"] == 0


def test_forecast_accuracy_without_percentage_errors_is_undefined_not_zero() -> None:
    evaluations = _forecast_evaluations(
        [_eval_row(["2026-06-08"], [0], date(2026, 6, 8))],
        {"p1": {"forecastNextWeek": 3, "lastObservedWeekStart": date(2026, 6, 1)}},
    )
    metrics = _accuracy_metrics(evaluations)
    assert metrics["evaluatedForecastCount"] == 1
    assert metrics["meanAbsoluteError"] == 3
    assert metrics["meanAbsolutePercentageError"] is None
    assert metrics["percentageErrorCount"] == 0


def test_forecast_accuracy_counts_only_defined_percentage_errors() -> None:
    metrics = _accuracy_metrics(
        [
            {"absoluteError": 2, "percentageError": None},
            {"absoluteError": 1, "percentageError": 50.0},
        ]
    )
    assert metrics["evaluatedForecastCount"] == 2
    assert metrics["percentageErrorCount"] == 1
    assert metrics["meanAbsolutePercentageError"] == 50.0


def test_summary_without_evaluations_keeps_earlier_forecast_accuracy() -> None:
    summary = {"summaryId": "s1", "scopeType": "organization", "scopeKey": "all"}
    assert "forecastAccuracy" not in _summary_with_accuracy(summary, [])
    other_branch = [{"branchId": "B2", "absoluteError": 1, "percentageError": 5}]
    branch = {**summary, "scopeType": "branch", "scopeKey": "B1"}
    assert "forecastAccuracy" not in _summary_with_accuracy(branch, other_branch)
    scored = _summary_with_accuracy(summary, other_branch)
    assert scored["forecastAccuracy"]["evaluatedForecastCount"] == 1


class _FakeSnapshot:
    def __init__(self, doc_id):
        self.id = doc_id

    def to_dict(self):
        return {}


class _FakeQuery:
    def __init__(self, count, limits, name):
        self.count, self.limits, self.name = count, limits, name

    def where(self, **_kwargs):
        return self

    def limit(self, value):
        self.limits[self.name] = value
        return self

    def order_by(self, *_args, **_kwargs):
        return self

    def stream(self):
        n = self.count if self.limits.get(self.name) is None else min(
            self.count, self.limits[self.name]
        )
        return [_FakeSnapshot(f"d{i}") for i in range(n)]


class _FakeClient:
    def __init__(self, counts):
        self.counts, self.limits = counts, {}

    def collection(self, name):
        return _FakeQuery(self.counts.get(name, 0), self.limits, name)


def test_read_inputs_raises_when_a_collection_exceeds_its_cap() -> None:
    from forecasting.ai_service.repository import (
        InputOverflowError,
        MAX_PRODUCTS,
        MAX_USERS,
    )

    ok = _FakeClient({"products": MAX_PRODUCTS, "users": MAX_USERS})
    inputs = FirestoreAiRepository(ok).read_inputs(as_of=date(2026, 6, 15))
    assert len(inputs["products"]) == MAX_PRODUCTS
    for name, cap in (("orders", 5000), ("users", MAX_USERS)):
        over = _FakeClient({name: cap + 5})
        with pytest.raises(InputOverflowError, match=f"{name}.*{cap}"):
            FirestoreAiRepository(over).read_inputs(as_of=date(2026, 6, 15))


def test_forecast_accuracy_skips_repeat_run_for_same_week() -> None:
    evaluations = _forecast_evaluations(
        [
            {
                "patternId": "p1",
                "weeklyQuantities": [4],
                "lastObservedWeekStart": date(2026, 6, 8),
            }
        ],
        {
            "p1": {
                "forecastNextWeek": 5,
                "lastObservedWeekStart": date(2026, 6, 8),
            }
        },
    )
    assert evaluations == []


def _replenishment_suggestion(retailer_id, product_id, confidence, qty):
    return {
        "retailerId": retailer_id,
        "productId": product_id,
        "suggestedQty": qty,
        "confidence": confidence,
        "confidenceLabel": "high" if confidence >= 0.7 else "medium",
        "rationale": f"Last ordered 20 days ago (qty {qty}).",
        "inputs": {
            "lastOrderQty": qty,
            "lastOrderDaysAgo": 20,
            "runRatePerDay": 0.5,
            "patternMeanQty": float(qty),
        },
    }


def _brief_insight(retailer_id: str) -> dict:
    return {
        "issueId": f"issue-{retailer_id}",
        "issueKey": f"type::{retailer_id}::P1",
        "retailerId": retailer_id,
        "retailerName": "Retailer",
        "salesmanUid": "U001",
        "salesmanCode": "S001",
        "branchId": "B001",
        "priority": "high",
        "valueAtRiskRm": 50,
        "questions": ["What changed?"],
    }


def test_visit_brief_embeds_capped_replenishment_preserving_other_fields() -> None:
    kwargs = {
        "as_of": date(2026, 6, 15),
        "run_id": "run-test",
        "generated_at": datetime(2026, 6, 15, tzinfo=timezone.utc),
    }
    baseline = build_visit_briefs([_brief_insight("R001")], **kwargs)
    suggestions = [
        _replenishment_suggestion("R001", "P0", 0.2, 10),
        _replenishment_suggestion("R001", "P1", 0.3, 10),
        _replenishment_suggestion("R001", "P2", 0.4, 10),
        _replenishment_suggestion("R001", "P3", 0.45, 10),
        _replenishment_suggestion("R001", "P4", 0.5, 10),
        _replenishment_suggestion("R001", "P5", 0.55, 10),
        _replenishment_suggestion("R001", "P9", 0.55, 20),
        _replenishment_suggestion("R999", "P1", 0.9, 5),
    ]
    briefs = build_visit_briefs(
        [_brief_insight("R001")],
        **kwargs,
        replenishment=suggestions,
    )
    assert len(briefs) == 1
    embedded = briefs[0]["replenishment"]
    assert [row["productId"] for row in embedded] == [
        "P9",
        "P5",
        "P4",
        "P3",
        "P2",
    ]
    assert all(
        set(row) >= {"retailerId", "productId", "suggestedQty", "confidence"}
        for row in embedded
    )
    stripped = {
        key: value for key, value in briefs[0].items() if key != "replenishment"
    }
    baseline_stripped = {
        key: value
        for key, value in baseline[0].items()
        if key != "replenishment"
    }
    assert stripped == baseline_stripped
    assert baseline[0]["replenishment"] == []


def test_visit_brief_replenishment_embed_is_idempotent() -> None:
    kwargs = {
        "as_of": date(2026, 6, 15),
        "run_id": "run-test",
        "generated_at": datetime(2026, 6, 15, tzinfo=timezone.utc),
        "replenishment": [
            _replenishment_suggestion("R001", "P1", 0.6, 10),
            _replenishment_suggestion("R001", "P2", 0.4, 8),
        ],
    }
    first = build_visit_briefs([_brief_insight("R001")], **kwargs)
    second = build_visit_briefs([_brief_insight("R001")], **kwargs)
    assert first == second


def test_generation_embeds_replenishment_from_pattern_run_rates() -> None:
    documents = build_demo_documents(as_of=date(2026, 6, 15))
    normalized = normalize_firestore_inputs(
        orders=_flatten(documents, "orders"),
        products=_flatten(documents, "products"),
        retailers=_flatten(documents, "retailers"),
        users=_flatten(documents, "users"),
        as_of=date(2026, 6, 15),
    )
    kwargs = {
        "as_of": date(2026, 6, 15),
        "run_id": "run-test",
        "generated_at": datetime(2026, 6, 15, tzinfo=timezone.utc),
    }
    without_orders = build_generation(normalized, **kwargs)
    with_orders = build_generation(
        normalized,
        **kwargs,
        orders=_flatten(documents, "orders"),
    )
    assert with_orders.replenishment
    assert any(
        row["inputs"]["runRatePerDay"] is not None
        for row in with_orders.replenishment
    )
    assert all(
        isinstance(brief["replenishment"], list)
        and len(brief["replenishment"]) <= 5
        for brief in with_orders.visit_briefs
    )
    assert len(without_orders.visit_briefs) == len(with_orders.visit_briefs)
    for before, after in zip(
        without_orders.visit_briefs, with_orders.visit_briefs
    ):
        assert {
            key: value for key, value in before.items() if key != "replenishment"
        } == {
            key: value for key, value in after.items() if key != "replenishment"
        }
    assert without_orders.replenishment == ()


def test_generation_carries_the_authoritative_priority_ranking() -> None:
    documents = build_demo_documents(as_of=date(2026, 6, 15))
    normalized = normalize_firestore_inputs(
        orders=_flatten(documents, "orders"),
        products=_flatten(documents, "products"),
        retailers=_flatten(documents, "retailers"),
        users=_flatten(documents, "users"),
        as_of=date(2026, 6, 15),
    )
    result = build_generation(
        normalized,
        as_of=date(2026, 6, 15),
        run_id="run-test",
        generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
        orders=_flatten(documents, "orders"),
    )
    assert result.priority_rankings
    assert result.run["priorityRankingCount"] == len(result.priority_rankings)
    for ranking in result.priority_rankings:
        assert ranking["status"] == "active"
        assert ranking["expectedOrderValueVersion"] == EXPECTED_ORDER_VALUE_VERSION
        assert ranking["coverageBasis"] == COVERAGE_BASIS_LAST_ORDER
        assert ranking["ranking"], "a ranking must list its candidates"
        assert len(ranking["decisionLog"]) == len(ranking["ranking"])
        for entry in ranking["decisionLog"]:
            assert entry["chosen"] in {True, False}
            assert entry["exploitOrExplore"] in {
                "exploit",
                "explore",
                "not_selected",
            }
            assert 0.0 <= entry["selectionProbability"] <= 1.0
            assert entry["rank"] >= 1
        assert (
            result.priority_rankings
            == build_generation(
                normalized,
                as_of=date(2026, 6, 15),
                run_id="run-test",
                generated_at=datetime(2026, 6, 15, tzinfo=timezone.utc),
                orders=_flatten(documents, "orders"),
            ).priority_rankings
        )


def test_a_code_only_scope_carries_its_code_into_the_ranking() -> None:
    data = normalize_firestore_inputs(
        orders=[
            {
                "orderId": "O1",
                "submittedAt": datetime(2026, 9, 8, 2, 0, tzinfo=timezone.utc),
                "retailerId": "R1",
                "status": "confirmed",
                "items": [{"productId": "P1", "qty": 6, "price": 2.0}],
            }
        ],
        products=[{"productId": "P1", "productName": "Alpha", "unitPrice": 2.0}],
        retailers=[
            {
                "retailerId": "R1",
                "retailerName": "First",
                "branchId": "B1",
                "assignedSalesmanId": "s0002",
            }
        ],
        users=[],
        as_of=date(2026, 9, 19),
    )
    patterns = [
        {
            "retailerId": "R1",
            "productId": "P1",
            "retailerName": "First",
            "productName": "Alpha",
            "salesmanUid": "",
            "salesmanCode": "s0002",
            "branchId": "B1",
            "weeklyQuantities": [0, 0, 0, 0, 0, 0, 0, 6],
        }
    ]

    rows = build_priority_rankings(
        patterns,
        data=data,
        as_of=date(2026, 9, 19),
        run_id="run-1",
        generated_at=datetime(2026, 9, 19, tzinfo=timezone.utc),
    )

    assert len(rows) == 1
    assert rows[0]["scopeKey"] == "s0002"
    assert rows[0]["salesmanUid"] == ""
    assert rows[0]["salesmanCode"] == "s0002"


def test_rejected_order_does_not_reset_retailer_contact_or_rank() -> None:
    as_of = date(2026, 9, 19)
    confirmed = {
        "orderId": "O1",
        "submittedAt": datetime(2026, 9, 1, 2, 0, tzinfo=timezone.utc),
        "retailerId": "R1",
        "status": "confirmed",
        "items": [{"productId": "P1", "qty": 6, "price": 2.0}],
    }
    other = {**confirmed, "orderId": "O2", "retailerId": "R2"}
    data = normalize_firestore_inputs(
        orders=[confirmed, other],
        products=[{"productId": "P1", "productName": "Alpha", "unitPrice": 2.0}],
        retailers=[
            {"retailerId": rid, "retailerName": rid, "branchId": "B1", "assignedSalesmanId": "s0002"}
            for rid in ("R1", "R2")
        ],
        users=[],
        as_of=as_of,
    )
    patterns = [
        {
            "retailerId": rid,
            "productId": "P1",
            "retailerName": rid,
            "productName": "Alpha",
            "salesmanUid": "",
            "salesmanCode": "s0002",
            "branchId": "B1",
            "weeklyQuantities": [0, 0, 0, 0, 0, 0, 0, 6],
        }
        for rid in ("R1", "R2")
    ]

    def rankings(orders):
        return build_priority_rankings(
            patterns,
            data=data,
            as_of=as_of,
            run_id="run-1",
            generated_at=datetime(2026, 9, 19, tzinfo=timezone.utc),
            orders=orders,
        )

    baseline = rankings([confirmed, other])
    for status in ("rejected", "cancelled", "draft", "deleted", "held_for_review"):
        junk = {
            **confirmed,
            "orderId": "O3",
            "status": status,
            "submittedAt": datetime(2026, 9, 18, 2, 0, tzinfo=timezone.utc),
        }
        assert rankings([confirmed, other, junk]) == baseline

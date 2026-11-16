from datetime import date, datetime, timezone

from forecasting.evaluation.loop_metrics import compute_loop_metrics

CUTOFF = date(2026, 7, 6)


def _dt(iso: str) -> datetime:
    return datetime.fromisoformat(iso).replace(tzinfo=timezone.utc)


def _insight(
    *,
    issue_key="stopped_product::R1::P1",
    retailer_id="R1",
    product_id="P1",
    status="new",
    auto_state="active",
    created_at="2026-06-01T00:00:00",
    resolved_at=None,
    auto_suppressed_at=None,
    value_at_risk=100.0,
    is_demo=False,
):
    row = {
        "issueKey": issue_key,
        "retailerId": retailer_id,
        "productId": product_id,
        "status": status,
        "autoState": auto_state,
        "createdAt": created_at,
        "valueAtRiskRm": value_at_risk,
        "isDemo": is_demo,
    }
    if resolved_at is not None:
        row["resolvedAt"] = resolved_at
    if auto_suppressed_at is not None:
        row["autoSuppressedAt"] = auto_suppressed_at
    return row


def _outcome(
    *,
    issue_key="stopped_product::R1::P1",
    retailer_id="R1",
    submitted_at="2026-06-10T00:00:00",
):
    return {
        "issueKey": issue_key,
        "retailerId": retailer_id,
        "submittedAt": submitted_at,
    }


def test_resolved_after_in_between_outcome_counts() -> None:
    insights = [
        _insight(
            status="resolved",
            created_at="2026-06-01T00:00:00",
            resolved_at="2026-06-15T00:00:00",
        )
    ]
    outcomes = [_outcome(submitted_at="2026-06-10T00:00:00")]
    report = compute_loop_metrics(insights, outcomes, cutoff=CUTOFF)["nonDemo"]
    res = report.resolution
    assert res.loop_engaged == 1
    assert res.loop_closed == 1
    assert res.resolution_rate == 1.0
    assert res.insufficient_data is False


def test_outcome_after_close_not_counted() -> None:
    insights = [
        _insight(
            status="resolved",
            created_at="2026-06-01T00:00:00",
            resolved_at="2026-06-05T00:00:00",
        )
    ]
    outcomes = [_outcome(submitted_at="2026-06-20T00:00:00")]
    report = compute_loop_metrics(insights, outcomes, cutoff=CUTOFF)["nonDemo"]
    res = report.resolution
    assert res.loop_engaged == 1
    assert res.loop_closed == 0
    assert res.resolution_rate == 0.0


def test_suppressed_via_auto_state_counts_as_closed() -> None:
    insights = [
        _insight(
            status="new",
            auto_state="suppressed",
            created_at="2026-06-01T00:00:00",
            auto_suppressed_at="2026-06-12T00:00:00",
        )
    ]
    outcomes = [_outcome(submitted_at="2026-06-08T00:00:00")]
    report = compute_loop_metrics(insights, outcomes, cutoff=CUTOFF)["nonDemo"]
    res = report.resolution
    assert res.closed_insights == 1
    assert res.loop_closed == 1


def test_no_related_outcome_gives_undefined_rate() -> None:
    insights = [_insight(status="resolved", resolved_at="2026-06-15T00:00:00")]
    report = compute_loop_metrics(insights, [], cutoff=CUTOFF)["nonDemo"]
    res = report.resolution
    assert res.loop_engaged == 0
    assert res.resolution_rate is None
    assert res.insufficient_data is True


def test_empty_inputs_are_honest() -> None:
    reports = compute_loop_metrics([], [], cutoff=CUTOFF)
    for cohort in ("demo", "nonDemo"):
        res = reports[cohort].resolution
        assert res.total_insights == 0
        assert res.resolution_rate is None
        assert reports[cohort].detection_to_outcome.count == 0
        assert reports[cohort].detection_to_outcome.median_days is None
        assert reports[cohort].var_trend.points == []


def test_latency_distribution_values() -> None:
    insights = [
        _insight(
            status="resolved",
            created_at="2026-06-01T00:00:00",
            resolved_at="2026-06-20T00:00:00",
        )
    ]
    outcomes = [_outcome(submitted_at="2026-06-11T00:00:00")]
    report = compute_loop_metrics(insights, outcomes, cutoff=CUTOFF)["nonDemo"]
    assert report.detection_to_outcome.count == 1
    assert report.detection_to_outcome.median_days == 10.0
    assert report.outcome_to_close.median_days == 9.0


def test_latency_skips_missing_timestamps() -> None:
    insights = [
        _insight(created_at=None, status="resolved", resolved_at="2026-06-15T00:00:00")
    ]
    outcomes = [_outcome(submitted_at="2026-06-10T00:00:00")]
    report = compute_loop_metrics(insights, outcomes, cutoff=CUTOFF)["nonDemo"]
    assert report.detection_to_outcome.count == 0
    assert report.resolution.loop_engaged == 0
    assert report.var_trend.undated_insight_count == 1
    assert report.var_trend.points == []


def test_var_trend_has_weekly_points_and_gap_note() -> None:
    insights = [
        _insight(
            created_at="2026-06-01T00:00:00",
            value_at_risk=200.0,
            status="new",
        ),
        _insight(
            issue_key="stopped_product::R2::P2",
            retailer_id="R2",
            product_id="P2",
            created_at=None,
            value_at_risk=50.0,
        ),
    ]
    report = compute_loop_metrics(insights, [], cutoff=CUTOFF)["nonDemo"]
    trend = report.var_trend
    assert trend.undated_insight_count == 1
    assert len(trend.points) >= 1
    assert all(point.open_value_at_risk_rm == 200.0 for point in trend.points)
    assert all(point.open_count == 1 for point in trend.points)


def test_var_trend_drops_value_after_close() -> None:
    insights = [
        _insight(
            created_at="2026-06-01T00:00:00",
            status="resolved",
            resolved_at="2026-06-15T00:00:00",
            value_at_risk=300.0,
        )
    ]
    report = compute_loop_metrics(insights, [], cutoff=date(2026, 7, 6))["nonDemo"]
    points = report.var_trend.points
    assert points[0].open_value_at_risk_rm == 300.0
    assert points[-1].open_value_at_risk_rm == 0.0


def test_demo_and_nondemo_are_separated() -> None:
    insights = [
        _insight(is_demo=True, retailer_id="R9", issue_key="stopped_product::R9::P1"),
        _insight(is_demo=False),
    ]
    reports = compute_loop_metrics(insights, [], cutoff=CUTOFF)
    assert reports["demo"].resolution.total_insights == 1
    assert reports["nonDemo"].resolution.total_insights == 1


def test_var_trend_places_insights_in_their_kuching_week() -> None:
    insights = [_insight(created_at="2026-06-14T18:00:00Z", value_at_risk=10.0)]
    points = compute_loop_metrics(insights, [], cutoff=CUTOFF)["nonDemo"].var_trend.points
    assert points[0].week_start == "2026-06-15"

from __future__ import annotations

import pytest

from forecasting.evaluation.ranking_metrics import (
    average_precision,
    calibration_report,
    lead_time_report,
    precision_at_k,
    recall_at_k,
)


def test_precision_at_k_counts_hits_in_the_window() -> None:
    assert precision_at_k([True, False, True, True], 3) == pytest.approx(2 / 3)


def test_precision_at_k_of_a_short_list_scores_what_exists() -> None:
    assert precision_at_k([True, False], 3) == pytest.approx(0.5)


def test_precision_at_k_is_none_without_items() -> None:
    assert precision_at_k([], 3) is None
    assert precision_at_k([True], 0) is None


def test_recall_at_k_needs_a_positive() -> None:
    assert recall_at_k([False, False], 2) is None
    assert recall_at_k([True, False, True, True], 2) == pytest.approx(1 / 3)


def test_average_precision_matches_a_hand_computed_example() -> None:
    assert average_precision([True, False, True]) == pytest.approx((1 + 2 / 3) / 2)


def test_average_precision_is_none_without_positives() -> None:
    assert average_precision([False, False]) is None
    assert average_precision([]) is None


def test_average_precision_of_a_perfect_list_is_one() -> None:
    assert average_precision([True, True, True]) == pytest.approx(1.0)


def test_calibration_report_buckets_and_measures_the_gap() -> None:
    report = calibration_report([0.05, 0.1, 0.9, 0.95], [False, False, True, True])
    assert report.expected_calibration_error == pytest.approx(0.075)
    low = report.buckets[0]
    assert low.count == 2
    assert low.observed_rate == pytest.approx(0.0)


def test_calibration_report_of_perfect_confidences_has_no_error() -> None:
    report = calibration_report([0.95, 0.95], [True, True])
    assert report.expected_calibration_error == pytest.approx(0.05)
    assert report.observed_rate == pytest.approx(1.0)


def test_calibration_report_without_pairs_is_none() -> None:
    report = calibration_report([], [])
    assert report.expected_calibration_error is None
    assert report.mean_confidence is None


def test_calibration_report_rejects_mismatched_lengths() -> None:
    with pytest.raises(ValueError):
        calibration_report([0.5], [True, False])


def test_calibration_clamps_out_of_range_confidences() -> None:
    report = calibration_report([-1.0, 5.0], [True, False])
    assert report.mean_confidence == pytest.approx(0.5)


def test_lead_time_excludes_negative_values_from_the_summary() -> None:
    report = lead_time_report([10.0, -3.0, 20.0])
    assert report.count == 2
    assert report.negative_count == 1
    assert report.median_days == pytest.approx(15.0)


def test_lead_time_of_empty_input_is_none() -> None:
    report = lead_time_report([])
    assert report.count == 0
    assert report.median_days is None


def test_lead_time_p90_is_the_upper_tail() -> None:
    report = lead_time_report(list(range(1, 11)))
    assert report.median_days == pytest.approx(5.5)
    assert report.p90_days == pytest.approx(9.1)

import json
from datetime import date, datetime, timedelta, timezone

from forecasting.ai_core.calendar import HistoryWindow
from forecasting.ai_service import cli, generator
from forecasting.ai_service.scorecard import (
    REBUILD_BASIS,
    SCORECARD_VERSION,
    build_scorecard,
    orders_between,
    replay_week,
    scorecard_blocks,
)
from forecasting.evaluation.ranking_backtest import (
    ORDER_COUNT_POLICY,
    PROTOCOL,
    RANDOM_POLICY,
    RANKING_POLICY,
    REAL_TABLE,
    RECENT_POLICY,
    SIMULATED_TABLE,
    run_backtest,
    wilson_interval,
)

AS_OF = date(2026, 11, 16)
FIRST_SCORED_WEEK = date(2026, 11, 2)
SECOND_SCORED_WEEK = date(2026, 11, 9)
WINDOW = HistoryWindow(weeks=8, requested=8, source="default")
PRODUCTS = [{"productId": "P1", "productName": "Tea", "unitPrice": 10.0}]
RETAILERS = [
    {
        "retailerId": f"R{index}",
        "retailerName": f"Shop {index}",
        "assignedSalesmanId": "S1",
        "branchId": "B1",
        "latitude": 1.5 + index / 100,
        "longitude": 110.3 + index / 100,
    }
    for index in (1, 2, 3)
]
USERS = [{"uid": "u1", "employeeCode": "S1", "role": "salesman", "branchId": "B1"}]
INPUTS = {"products": PRODUCTS, "retailers": RETAILERS, "users": USERS}


def _order(retailer_id: str, start: date, quantity: int, **extra):
    return {
        "orderId": f"O-{retailer_id}-{start.isoformat()}",
        "retailerId": retailer_id,
        "status": "confirmed",
        "submittedAt": datetime(
            start.year, start.month, start.day, 2, tzinfo=timezone.utc
        )
        + timedelta(days=1),
        "items": [{"productId": "P1", "qty": quantity, "price": 10.0}],
        **extra,
    }


def _orders() -> list[dict]:
    orders = []
    start = date(2026, 8, 24)
    while start <= FIRST_SCORED_WEEK:
        orders.append(_order("R1", start, 4))
        orders.append(_order("R2", start, 2))
        start += timedelta(weeks=1)
    orders.append(_order("R2", SECOND_SCORED_WEEK, 2))
    orders.append(_order("R3", SECOND_SCORED_WEEK, 1))
    return orders


def _outcome(reason: str, day: date, **extra):
    return {
        "outcomeId": f"X-{reason}-{day.isoformat()}",
        "retailerId": "R1",
        "salesmanCode": "S1",
        "branchId": "B1",
        "reasonCode": reason,
        "submittedAt": datetime(day.year, day.month, day.day, 3, tzinfo=timezone.utc),
        **extra,
    }


OUTCOMES = [
    _outcome("price_too_high", date(2026, 11, 3)),
    _outcome("price_too_high", date(2026, 11, 10)),
    _outcome("retailer_busy", date(2026, 11, 4)),
    _outcome("retailer_busy", date(2026, 10, 27)),
    _outcome("no_stock_space", date(2026, 11, 16)),
]


def _scorecard(orders=None, outcomes=OUTCOMES):
    return build_scorecard(
        orders=_orders() if orders is None else orders,
        outcomes=outcomes,
        as_of=AS_OF,
        window=WINDOW,
        weeks=2,
        **INPUTS,
    )


def _bytes(value) -> str:
    return json.dumps(value, sort_keys=True, default=str)


def test_scorecard_equals_the_hand_computed_fixture() -> None:
    block = _scorecard().block("organization", "all")

    assert block["version"] == SCORECARD_VERSION
    assert block["basis"] == REBUILD_BASIS
    assert block["window"] == {
        "firstWeekStart": "2026-11-02",
        "lastWeekStart": "2026-11-09",
        "weeksRequested": 2,
        "weeksScored": 2,
        "historyWeeks": 8,
        "orderReadWeeks": 10,
    }
    assert block["dataLabel"] == {
        "kind": "real_orders",
        "simulationBatchIds": [],
        "recordCount": 27,
        "simulatedRecordCount": 0,
    }

    top = block["topRankedOrdered"]
    assert top["note"] == "compares, does not prove cause"
    assert top["sample"] == {
        "salespersonWeeks": 2,
        "topShopWeeks": 4,
        "otherShopWeeks": 2,
    }
    assert (top["topOrderedShopWeeks"], top["topOrderedPercent"]) == (3, 75.0)
    assert (top["otherOrderedShopWeeks"], top["otherOrderedPercent"]) == (1, 50.0)

    forecast = block["forecastAgainstActual"]
    assert forecast["sample"] == {"productWeeks": 2, "shopProductWeeks": 4}
    assert forecast["forecastUnits"] == 12.0
    assert forecast["actualUnits"] == 8.0
    assert forecast["absoluteErrorUnits"] == 4.0
    assert forecast["weightedAbsolutePercentageError"] == 50.0
    assert forecast["actualUnitsWithoutForecast"] == 1.0

    kept = block["suggestedReordersKept"]
    assert kept["sample"] == {"suggestions": 4}
    assert (kept["keptSuggestions"], kept["keptPercent"]) == (3, 75.0)

    reasons = block["noSaleReasons"]
    assert reasons["sample"] == {"outcomes": 3}
    assert reasons["byReasonCode"] == [
        {"reasonCode": "price_too_high", "count": 2},
        {"reasonCode": "retailer_busy", "count": 1},
    ]

    for tile in (top, forecast, kept, reasons):
        assert tile["version"] == SCORECARD_VERSION
        assert tile["window"] == block["window"]
        assert tile["dataLabel"] == block["dataLabel"]


def test_scorecard_is_scoped_by_branch_and_salesperson() -> None:
    scorecard = _scorecard()
    organization = scorecard.block("organization", "all")

    for scope_type, scope_key in (("branch", "B1"), ("salesman", "S1")):
        scoped = scorecard.block(scope_type, scope_key)
        for tile in (
            "topRankedOrdered",
            "forecastAgainstActual",
            "suggestedReordersKept",
            "noSaleReasons",
        ):
            assert scoped[tile] == organization[tile]

    other = scorecard.block("salesman", "S9")
    assert other["topRankedOrdered"]["sample"]["topShopWeeks"] == 0
    assert other["topRankedOrdered"]["topOrderedPercent"] is None
    assert other["suggestedReordersKept"]["sample"] == {"suggestions": 0}
    assert "noSaleReasons" not in other


def test_no_sale_tile_is_left_out_without_outcomes() -> None:
    assert "noSaleReasons" not in _scorecard(outcomes=()).block("organization", "all")


def test_simulated_orders_are_labelled_with_their_batch() -> None:
    orders = _orders()
    orders[0] = {**orders[0], "simulationBatchId": "sim-2026-11-18"}
    orders[1] = {**orders[1], "simulationBatchId": "sim-2026-11-18"}

    label = _scorecard(orders=orders).block("branch", "B1")["dataLabel"]

    assert label["kind"] == "simulated"
    assert label["simulationBatchIds"] == ["sim-2026-11-18"]
    assert label["simulatedRecordCount"] == 2


def _two_team_inputs():
    retailers = [
        *RETAILERS,
        *(
            {
                "retailerId": f"Q{index}",
                "retailerName": f"Other {index}",
                "assignedSalesmanId": "S2",
                "branchId": "B2",
                "latitude": 1.7 + index / 100,
                "longitude": 110.5 + index / 100,
            }
            for index in (1, 2)
        ),
    ]
    users = [
        *USERS,
        {"uid": "u2", "employeeCode": "S2", "role": "salesman", "branchId": "B2"},
    ]
    orders = _orders()
    start = date(2026, 8, 24)
    while start <= SECOND_SCORED_WEEK:
        for retailer_id in ("Q1", "Q2"):
            order = _order(retailer_id, start, 3)
            orders.append(
                {
                    **order,
                    "orderId": f"SIM-{order['orderId']}",
                    "simulationBatchId": "sim-b2",
                }
            )
        start += timedelta(weeks=1)
    outcomes = [
        *OUTCOMES,
        {
            **_outcome("retailer_busy", date(2026, 11, 4)),
            "outcomeId": "X-other",
            "retailerId": "Q1",
            "salesmanCode": "S2",
            "branchId": "B2",
            "simulationBatchId": "sim-b2",
        },
    ]
    return {"products": PRODUCTS, "retailers": retailers, "users": users}, orders, outcomes


def test_each_scope_labels_and_counts_only_its_own_records() -> None:
    inputs, orders, outcomes = _two_team_inputs()
    scorecard = build_scorecard(
        orders=orders, outcomes=outcomes, as_of=AS_OF, window=WINDOW, weeks=2, **inputs
    )
    real_records = 24 + 3
    simulated_records = 2 * 12 + 1

    organization = scorecard.block("organization", "all")
    assert organization["dataLabel"] == {
        "kind": "simulated",
        "simulationBatchIds": ["sim-b2"],
        "recordCount": real_records + simulated_records,
        "simulatedRecordCount": simulated_records,
    }

    for scope_type, scope_key in (("salesman", "S1"), ("branch", "B1")):
        block = scorecard.block(scope_type, scope_key)
        assert block["dataLabel"] == {
            "kind": "real_orders",
            "simulationBatchIds": [],
            "recordCount": real_records,
            "simulatedRecordCount": 0,
        }
        assert block["noSaleReasons"]["sample"] == {"outcomes": 3}
        for tile in (
            "topRankedOrdered",
            "forecastAgainstActual",
            "suggestedReordersKept",
            "noSaleReasons",
        ):
            assert block[tile]["dataLabel"] == block["dataLabel"]
            assert block[tile]["window"] == block["window"]

    for scope_type, scope_key in (("salesman", "S2"), ("branch", "B2")):
        block = scorecard.block(scope_type, scope_key)
        assert block["dataLabel"] == {
            "kind": "simulated",
            "simulationBatchIds": ["sim-b2"],
            "recordCount": simulated_records,
            "simulatedRecordCount": simulated_records,
        }
        assert block["noSaleReasons"]["sample"] == {"outcomes": 1}
        assert block["noSaleReasons"]["byReasonCode"] == [
            {"reasonCode": "retailer_busy", "count": 1}
        ]
        assert block["topRankedOrdered"]["sample"]["topShopWeeks"] == 4


def test_an_empty_scope_carries_no_figure_of_another_scope() -> None:
    inputs, orders, outcomes = _two_team_inputs()
    orders = [
        {**order, "simulationBatchId": "sim-b2"} if order["retailerId"] == "R1" else order
        for order in orders
    ]
    scorecard = build_scorecard(
        orders=orders, outcomes=outcomes, as_of=AS_OF, window=WINDOW, weeks=2, **inputs
    )

    empty = scorecard.block("salesman", "S9")
    assert empty["dataLabel"] == {
        "kind": "real_orders",
        "simulationBatchIds": [],
        "recordCount": 0,
        "simulatedRecordCount": 0,
    }
    assert empty["window"]["weeksScored"] == 0
    assert empty["window"]["weeksRequested"] == 2
    for tile in ("topRankedOrdered", "forecastAgainstActual", "suggestedReordersKept"):
        assert empty[tile]["dataLabel"] == empty["dataLabel"]
        assert empty[tile]["window"] == empty["window"]
    assert "noSaleReasons" not in empty
    assert scorecard.block("organization", "all")["window"]["weeksScored"] == 2


def test_two_runs_give_the_same_bytes() -> None:
    first = scorecard_blocks(_scorecard(), [{"summaryId": "week_x"}])
    second = scorecard_blocks(_scorecard(), [{"summaryId": "week_x"}])

    assert _bytes(first) == _bytes(second)


def test_orders_and_outcomes_after_a_week_change_nothing_for_that_week() -> None:
    orders = _orders()
    later_orders = [
        _order("R1", SECOND_SCORED_WEEK, 40),
        _order("R3", SECOND_SCORED_WEEK, 9),
        _order("R3", AS_OF, 30),
    ]
    later_outcomes = [
        _outcome("price_too_high", date(2026, 11, 12)),
        _outcome("no_stock_space", date(2026, 11, 17)),
    ]

    for cutoff in (FIRST_SCORED_WEEK, SECOND_SCORED_WEEK):
        base = replay_week(orders=orders, cutoff=cutoff, window=WINDOW, **INPUTS)
        after = [row for row in later_orders if row["submittedAt"].date() >= cutoff]
        leaked = replay_week(
            orders=[*orders, *after], cutoff=cutoff, window=WINDOW, **INPUTS
        )
        assert _bytes(leaked.result) == _bytes(base.result)

    def first_week_rows(scorecard):
        return [
            [row for row in rows if row["weekStart"] == "2026-11-02"]
            for rows in (
                scorecard.rank_rows,
                scorecard.forecast_rows,
                scorecard.unforecast_rows,
                scorecard.suggestion_rows,
            )
        ]

    base_card = _scorecard(orders=orders)
    later_card = _scorecard(
        orders=[*orders, *later_orders], outcomes=[*OUTCOMES, *later_outcomes]
    )
    assert first_week_rows(later_card) == first_week_rows(base_card)

    inside_card = _scorecard(orders=[*orders, _order("R3", FIRST_SCORED_WEEK, 5)])
    assert first_week_rows(inside_card) != first_week_rows(base_card)


class _FixedClock(datetime):
    @classmethod
    def now(cls, tz=None):
        return datetime(2026, 11, 16, 1, 0, tzinfo=timezone.utc)


class _Repository:
    enabled = False
    fail_scorecard_read = False
    instances: list["_Repository"] = []

    def __init__(self, client):
        self.records = []
        self.calls = []
        self.generation = None
        self.scorecard_rows = None
        self.__class__.instances.append(self)

    def write_run_record(self, run_id, payload, *, merge=True):
        self.records.append(dict(payload))

    def abandon_dead_runs(self, *, before):
        return 0

    def resolve_history_window(self, *, as_of, requested=None):
        return WINDOW

    def read_inputs(self, *, as_of, history_weeks=8):
        self.calls.append("read_inputs")
        return {
            "orders": orders_between(
                _orders(), as_of - timedelta(weeks=8), as_of + timedelta(days=1)
            ),
            **INPUTS,
            "conversation_outcomes": OUTCOMES,
        }

    def write_generation(self, result):
        self.calls.append("write_generation")
        self.generation = result
        return {"runs": 1}

    def read_scorecard_enabled(self):
        self.calls.append("read_scorecard_enabled")
        return self.enabled

    def read_scorecard_orders(self, *, as_of, read_weeks):
        self.calls.append("read_scorecard_orders")
        if self.fail_scorecard_read:
            raise RuntimeError("orders unavailable")
        return orders_between(
            _orders(), as_of - timedelta(weeks=read_weeks), as_of
        )

    def write_scorecard(self, rows):
        self.calls.append("write_scorecard")
        self.scorecard_rows = list(rows)
        return len(self.scorecard_rows)


def _run_job(monkeypatch, *, enabled, fail=False):
    _Repository.instances.clear()
    monkeypatch.setattr(_Repository, "enabled", enabled)
    monkeypatch.setattr(_Repository, "fail_scorecard_read", fail)
    monkeypatch.setattr(cli, "datetime", _FixedClock)
    monkeypatch.setattr(cli, "_run_id", lambda now: "run-fixed")
    monkeypatch.setattr(
        cli, "create_firestore_client", lambda _account, _project: object()
    )
    monkeypatch.setattr(cli, "FirestoreAiRepository", _Repository)
    code = cli.main(
        [
            "--apply",
            "--project",
            "dev",
            "--confirm",
            "APPLY-cos40005",
            "--as-of",
            AS_OF.isoformat(),
        ]
    )
    return code, _Repository.instances[0]


def test_scorecard_is_off_by_default(monkeypatch) -> None:
    code, repository = _run_job(monkeypatch, enabled=False)

    assert code == 0
    assert repository.scorecard_rows is None
    assert "read_scorecard_orders" not in repository.calls
    assert repository.calls.index("write_generation") < repository.calls.index(
        "read_scorecard_enabled"
    )


def test_scorecard_on_leaves_rankings_suggestions_and_briefs_identical(
    monkeypatch,
) -> None:
    _, off = _run_job(monkeypatch, enabled=False)
    code, on = _run_job(monkeypatch, enabled=True)

    assert code == 0
    assert off.generation.priority_rankings
    assert off.generation.replenishment
    assert _bytes(on.generation.priority_rankings) == _bytes(
        off.generation.priority_rankings
    )
    assert _bytes(on.generation.replenishment) == _bytes(off.generation.replenishment)
    assert _bytes(on.generation.visit_briefs) == _bytes(off.generation.visit_briefs)
    assert _bytes(on.generation) == _bytes(off.generation)
    assert on.calls.index("write_generation") < on.calls.index("write_scorecard")
    assert [summary_id for summary_id, _ in on.scorecard_rows] == [
        row["summaryId"] for row in on.generation.weekly_summaries
    ]
    assert {
        (row["scorecard"]["scopeType"], row["scorecard"]["scopeKey"])
        for _, row in on.scorecard_rows
    } == {("organization", "all"), ("branch", "B1"), ("salesman", "S1")}
    assert all(set(row) == {"scorecard"} for _, row in on.scorecard_rows)


def test_weekday_fact_changes_only_two_brief_fields(monkeypatch) -> None:
    _, current = _run_job(monkeypatch, enabled=False)
    monkeypatch.setattr(generator, "usual_order_weekdays", lambda *_, **__: {})
    _, without_fact = _run_job(monkeypatch, enabled=False)

    assert _bytes(current.generation.priority_rankings) == _bytes(
        without_fact.generation.priority_rankings
    )
    assert _bytes(current.generation.replenishment) == _bytes(
        without_fact.generation.replenishment
    )
    assert _bytes(current.generation.patterns) == _bytes(
        without_fact.generation.patterns
    )
    assert _bytes(current.generation.insights) == _bytes(
        without_fact.generation.insights
    )
    new_fields = {"usualOrderWeekday", "usualOrderWeekdayVersion"}
    stripped = [
        {key: value for key, value in brief.items() if key not in new_fields}
        for brief in current.generation.visit_briefs
    ]
    assert _bytes(stripped) == _bytes(without_fact.generation.visit_briefs)
    assert {
        brief["retailerId"]: brief.get("usualOrderWeekday")
        for brief in current.generation.visit_briefs
    } == {"R1": 2, "R2": 2, "R3": None}


def test_scorecard_failure_keeps_main_outputs_and_names_the_scorecard(
    monkeypatch, capsys
) -> None:
    code, repository = _run_job(monkeypatch, enabled=True, fail=True)

    assert code == 1
    assert repository.generation is not None
    assert repository.scorecard_rows is None
    assert repository.calls.index("write_generation") < repository.calls.index(
        "read_scorecard_orders"
    )
    final = repository.records[-1]
    assert final["status"] == "completed"
    assert final["errorType"] == "ScorecardError"
    assert "scorecard failed" in final["lateError"]
    failure = json.loads(capsys.readouterr().err.splitlines()[-1])
    assert failure["event"] == "ai_runner_failed"
    assert "scorecard failed" in failure["lateError"]


def test_backtest_keeps_simulated_and_real_orders_in_separate_tables() -> None:
    real = _orders()
    simulated = [
        {**order, "orderId": f"S-{order['orderId']}", "simulationBatchId": "sim-1"}
        for order in _orders()
    ]

    report = run_backtest(
        orders=[*real, *simulated], as_of=AS_OF, window=WINDOW, weeks=8, **INPUTS
    )
    again = run_backtest(
        orders=[*real, *simulated], as_of=AS_OF, window=WINDOW, weeks=8, **INPUTS
    )
    real_only = run_backtest(
        orders=real, as_of=AS_OF, window=WINDOW, weeks=8, **INPUTS
    )

    assert _bytes(report) == _bytes(again)
    assert report["protocol"] == PROTOCOL
    simulated_table, real_table = report["tables"]
    assert simulated_table["label"] == SIMULATED_TABLE
    assert simulated_table["dataLabel"]["kind"] == "simulated"
    assert simulated_table["dataLabel"]["simulationBatchIds"] == ["sim-1"]
    assert real_table["label"] == REAL_TABLE
    assert real_table["dataLabel"]["kind"] == "real_orders"
    assert _bytes(real_table) == _bytes(real_only["tables"][1])
    assert all(row["trialCount"] == 0 for row in real_only["tables"][0]["rows"])


def test_backtest_counts_match_the_hand_computed_fixture() -> None:
    report = run_backtest(
        orders=_orders(), as_of=AS_OF, window=WINDOW, weeks=2, **INPUTS
    )
    rows = {
        (row["policy"], row["horizonWeeks"]): row
        for row in report["tables"][1]["rows"]
    }

    assert set(rows) == {
        (policy, horizon)
        for policy in (RANKING_POLICY, RANDOM_POLICY, RECENT_POLICY, ORDER_COUNT_POLICY)
        for horizon in (1, 4)
    }
    ranking = rows[(RANKING_POLICY, 1)]
    assert (ranking["hitCount"], ranking["trialCount"]) == (3, 4)
    assert ranking["hitRate"] == 0.75
    assert ranking["hitRateInterval95"] == [0.3006, 0.9544]
    assert (ranking["topValueRm"], ranking["totalValueRm"]) == (80.0, 90.0)
    assert ranking["valueShare"] == 0.8889
    low, high = ranking["valueShareInterval95"]
    assert 0.0 <= low <= ranking["valueShare"] <= high <= 1.0
    assert rows[(ORDER_COUNT_POLICY, 1)]["hitCount"] == 3
    assert rows[(RECENT_POLICY, 1)]["hitCount"] == 3
    random_row = rows[(RANDOM_POLICY, 1)]
    assert random_row["trialCount"] == 4
    assert 0.0 <= random_row["hitRate"] <= 1.0
    assert rows[(RANKING_POLICY, 4)]["scopePeriods"] == 0
    assert rows[(RANKING_POLICY, 4)]["hitRate"] is None


def test_wilson_interval_matches_a_known_value() -> None:
    assert wilson_interval(5, 10) == [0.2366, 0.7634]
    assert wilson_interval(96, 144) == [0.5862, 0.7384]
    assert wilson_interval(0, 0) is None

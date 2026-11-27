from __future__ import annotations

import functools
import itertools
import json
import random
import re
import sys
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forecasting.ai_core.calendar import ASIA_KUCHING, week_start
from forecasting.ai_service.normalization import NON_DEMAND_ORDER_STATUSES, is_demo_record
from platform_service.order_price_check import price_order

from scripts.ai_simulation import cli
from scripts.ai_simulation.inputs import (
    SimulationError,
    assign_areas,
    company_from_collections,
    load_export,
    resolve_team,
    simulated_shops,
)
from scripts.ai_simulation.simulate import (
    CREATED_COLLECTIONS,
    PURCHASE_ORDER_ID_TAIL,
    RECOVERY_REASON,
    Settings,
    purchase_order_busiest_week,
    rank_of,
    run_pipeline,
    simulate,
    stopped_pairs,
    verify,
)
from scripts.ai_simulation.staff_plan import LEGACY_ASSIGNMENT_FIELDS, SUPERVISOR_CAP, shop_assignment_plan, staff_move_plan

FIRST = date(2026, 11, 16)
NOW = datetime(2026, 11, 18, 4, 0, tzinfo=timezone.utc)
SEEDS = tuple(range(1, 13))
RULES = (ROOT / "admin_dashboard" / "firestore.rules").read_text(encoding="utf-8")
REPOSITORY = (ROOT / "admin_dashboard" / "lib" / "repositories" / "cms_repository.dart").read_text(encoding="utf-8")
ROSTER = {
    "branchId": "kuching",
    "routeAuthor": "u-admin",
    "teams": [
        {"supervisor": "SUP-A", "salespeople": ["Person sp-01", "S02"]},
        {"supervisor": "sup-b", "salespeople": ["sp-03", "sp-04"]},
    ],
    "leaverSupervisors": ["sup-c", "sup-d"],
}


def _moment(day: date, hour: int) -> datetime:
    return datetime(day.year, day.month, day.day, hour, tzinfo=ASIA_KUCHING).astimezone(timezone.utc)


def collections(old_orders: int = 60) -> dict[str, dict[str, dict]]:
    picker = random.Random(99)
    users: dict[str, dict] = {}
    access: dict[str, dict] = {}

    def person(uid: str, role: str, code: str, roster: list[str] | None = None) -> None:
        users[uid] = {"uid": uid, "name": f"Person {uid}", "email": f"{uid}@alljoys.test", "role": role,
                      "branchId": "kuching", "employeeCode": code, "status": "active"}
        access[uid] = {"role": role, "branchId": "kuching", "employeeCode": code, "status": "active", "userDocId": uid}
        if roster is not None:
            users[uid]["assignedSalesmanCodes"] = list(roster)
            access[uid]["assignedSalesmanCodes"] = list(roster)

    person("u-admin", "admin", "ADM1")
    person("sup-a", "supervisor", "SUP-A", ["S05", "S06", "S07", "S08", "GONE1"])
    person("sup-b", "supervisor", "SUP-B", ["S01", "S09", "S10", "S04"])
    person("sup-c", "supervisor", "SUP-C", [])
    person("sup-d", "supervisor", "SUP-D", ["S02", "S03"])
    for index in range(1, 11):
        person(f"sp-{index:02d}", "salesman", f"S{index:02d}")
    products = {
        f"P{index:03d}": {"productName": f"Item {index:03d}", "price": picker.randint(300, 4500) / 100,
                          "packingSize": "12 x 250ml", "department": "Grocery"}
        for index in range(1, 31)
    }
    products["P031"] = {"productName": "Item with no price"}
    retailers = {
        f"R{index:03d}": {"retailerId": f"R{index:03d}", "retailerName": f"Shop {index:03d}", "branchId": "kuching",
                          "latitude": round(1.45 + picker.random() * 0.2, 6),
                          "longitude": round(110.25 + picker.random() * 0.2, 6),
                          "assignedSalesmanId": "S09", "assignedSalesmanCodes": ["S09"], "address": "Kuching"}
        for index in range(1, 21)
    }
    orders = {}
    for index in range(old_orders):
        day = FIRST - timedelta(days=picker.randint(1, 200))
        product = f"P{picker.randint(1, 30):03d}"
        quantity = picker.randint(1, 5)
        orders[f"OLD-{index:04d}"] = {
            "orderId": f"OLD-{index:04d}", "retailerId": f"R{picker.randint(1, 20):03d}", "salesmanCode": "S09",
            "salesmanUid": "sp-09", "branchId": "kuching", "status": "submitted", "submittedAt": _moment(day, 11),
            "items": [{"productId": product, "qty": quantity, "price": products[product]["price"]}],
        }
    sheets = {"R001": {"productOverrides": {f"P{index:03d}": {"price": 2.5} for index in range(1, 31)}}}
    return {"users": users, "user_access": access, "products": products, "retailers": retailers, "orders": orders,
            "retailer_score_sheet_settings": sheets}


@functools.lru_cache(maxsize=None)
def company(old_orders: int = 60):
    return company_from_collections("alljoys-fixture", collections(old_orders))


@functools.lru_cache(maxsize=None)
def team():
    return resolve_team(company(), ROSTER)


@functools.lru_cache(maxsize=None)
def simulation(seed: int = 7, weeks_after: int = 0):
    cutoff = FIRST + timedelta(weeks=weeks_after)
    now = NOW + timedelta(weeks=weeks_after)
    return simulate(company(), team(), Settings(first_cutoff=FIRST, cutoff=cutoff, seed=seed), now=now)


def every_document(run) -> dict[str, dict]:
    return {f"{name}/{doc_id}": data for name in CREATED_COLLECTIONS for doc_id, data in run.documents[name].items()}


def prints(run) -> dict[str, str]:
    return {path: cli.fingerprint(data) for path, data in every_document(run).items()}


class MemoryStore:
    def __init__(self, documents: dict[str, dict] | None = None):
        self.documents = {path: (dict(data), 1) for path, data in (documents or {}).items()}
        self.ticks = itertools.count(2)

    @staticmethod
    def _time(tick):
        return datetime(2026, 11, 18, tzinfo=timezone.utc) + timedelta(seconds=tick)

    def create(self, path, data):
        if path in self.documents:
            return None
        self.documents[path] = (dict(data), next(self.ticks))
        return self._time(self.documents[path][1])

    def read(self, path):
        found = self.documents.get(path)
        return (found[0], self._time(found[1])) if found else None

    def delete_group(self, expected):
        for path, wanted in expected.items():
            found = self.read(path)
            if (found[1] if found else None) != wanted:
                return False
        for path, wanted in expected.items():
            if wanted is not None:
                del self.documents[path]
        return True

    def change(self, path, **fields):
        data, _ = self.documents[path]
        self.documents[path] = ({**data, **fields}, next(self.ticks))

    def order_count(self):
        return sum(1 for path in self.documents if path.startswith("orders/"))

    def route_plans(self):
        return [(path.split("/", 1)[1], data) for path, (data, _) in sorted(self.documents.items())
                if path.startswith("route_plans/")]


def test_same_seed_gives_the_same_records_and_another_seed_does_not():
    again = simulate(company(), team(), Settings(first_cutoff=FIRST, cutoff=FIRST, seed=7), now=NOW)
    assert prints(again) == prints(simulation(7))
    assert prints(simulation(8)) != prints(simulation(7))


def test_a_second_write_creates_nothing_and_keeps_every_written_row(tmp_path):
    run = simulation(7)
    store = MemoryStore()
    for name in cli.WRITE_SETS:
        journal = tmp_path / f"{name}.journal"
        first = cli.apply_manifest(store, run, name, "alljoys-fixture", now=NOW, order_limit=900, journal=journal)
        assert first["counts"]["written"] == len(cli.planned_documents(run, name)) > 0
        second = cli.apply_manifest(store, run, name, "alljoys-fixture", now=NOW, order_limit=900, journal=journal)
        assert second["counts"] == {"written": first["counts"]["written"], "exists_same": 0, "exists_different": 0}
        assert second["documents"] == first["documents"]
    assert len(store.documents) == len(every_document(run))


def test_a_dry_run_on_an_export_that_holds_the_batch_plans_no_create(tmp_path):
    run = simulation(7)
    body = collections()
    for path, data in every_document(run).items():
        name, doc_id = path.split("/", 1)
        body.setdefault(name, {})[doc_id] = data
    file = tmp_path / "export.json"
    cli.write_json(file, {"format": 1, "project": "alljoys-fixture", "takenAt": "x", "collections": {
        name: {doc_id: cli._encode(data) for doc_id, data in documents.items()} for name, documents in body.items()
    }})
    reloaded = load_export(file)
    rerun = simulate(reloaded, resolve_team(reloaded, ROSTER), Settings(first_cutoff=FIRST, cutoff=FIRST, seed=7), now=NOW)
    assert prints(rerun) == prints(run)
    for name in cli.WRITE_SETS:
        manifest = cli.build_manifest(rerun, name, "alljoys-fixture", cli.export_existing(reloaded, rerun, name))
        assert manifest["counts"]["create"] == 0 and manifest["counts"]["exists_different"] == 0
        assert manifest["counts"]["exists_same"] == len(manifest["documents"])


def test_a_changed_existing_record_is_listed_and_not_overwritten(tmp_path):
    run = simulation(7)
    path = next(iter(cli.planned_documents(run, "orders")))
    store = MemoryStore({path: {**every_document(run)[path], "status": "rejected"}})
    manifest = cli.apply_manifest(store, run, "orders", "alljoys-fixture", now=NOW, order_limit=900, journal=tmp_path / "j.journal")
    assert manifest["counts"]["exists_different"] == 1
    assert store.documents[path][0]["status"] == "rejected"


def test_undo_deletes_only_what_the_manifest_wrote_and_skips_a_changed_record(tmp_path):
    run = simulation(7)
    kept = "orders/REAL-1"
    store = MemoryStore({kept: {"orderId": "REAL-1"}})
    manifest = json.loads(json.dumps(cli.apply_manifest(store, run, "orders", "alljoys-fixture", now=NOW, order_limit=900, journal=tmp_path / "j.journal")))
    changed = manifest["documents"][0]["path"]
    store.change(changed, status="rejected")
    assert cli.undo_manifest(None, manifest)["mode"] == "dry-run" and len(store.documents) == len(manifest["documents"]) + 1
    report = cli.undo_manifest(store, manifest)
    assert report["skippedChanged"] == [changed] and report["alreadyGone"] == [] and any(report[key] for key in cli.UNDO_KEPT_BACK)
    partners = _partners(manifest, changed)
    assert changed.startswith("orders/") and partners == ["purchase_orders/" + changed.split("/", 1)[1]]
    assert report["keptWithChangedPartner"] == partners
    assert sorted(store.documents) == sorted([kept, changed, *partners])


def test_one_more_week_keeps_every_earlier_record_and_adds_only_the_new_week(tmp_path):
    for seed in (7, 3):
        first, later = every_document(simulation(seed)), every_document(simulation(seed, 1))
        assert {path: cli.fingerprint(first[path]) for path in first} == {
            path: cli.fingerprint(later[path]) for path in first
        }
        added = [later[path] for path in later if path not in first]
        assert added
        for data in added:
            stamp = (
                data.get("submittedAt") or data.get("completedAt") or data.get("weekStart")
                or data.get("issuedAt") or data.get("createdAt")
            )
            assert week_start(stamp) == FIRST
    store = MemoryStore()
    cli.apply_manifest(store, simulation(7), "orders", "alljoys-fixture", now=NOW, order_limit=900, journal=tmp_path / "j.journal")
    top_up = cli.apply_manifest(
        store, simulation(7, 1), "orders", "alljoys-fixture", now=NOW + timedelta(weeks=1), order_limit=900,
        journal=tmp_path / "j.journal",
    )
    assert top_up["counts"]["exists_different"] == 0
    assert top_up["counts"]["written"] == len(cli.planned_documents(simulation(7, 1), "orders"))
    assert top_up["counts"]["written"] == 2 * len(simulation(7, 1).documents["orders"]) > 2 * len(simulation(7).documents["orders"])


def _rule_text(pattern: str) -> str:
    found = re.search(pattern, RULES, re.S)
    assert found, pattern
    return found.group(1)


def _names(listed: str) -> set[str]:
    return set(re.findall(r"'([A-Za-z_]+)'", listed))


def _partners(manifest, path: str) -> list[str]:
    group = cli.order_group(path)
    return sorted(
        row["path"] for row in manifest["documents"]
        if row["status"] == "written" and row["path"] != path and cli.order_group(row["path"]) == group
    )


def _approval_keys() -> set[str]:
    return _names(_rule_text(r"validOrderForApproval\(\) && changed\.hasOnly\(\[(.*?)\]\)"))


def test_every_order_has_the_shape_the_phone_writes_and_points_at_real_records():
    lines_rule = re.compile(_rule_text(r"joined\.matches\(\s*'(\^\(\[A-Za-z0-9_-\]\{1,200\}~.*?)'\s*\)"))
    allowed = set(_rule_text(r"\(keys \+ ','\)\.matches\('\^\(\?:\(\?:([A-Za-z|]+)\),\)\+\$'\)").split("|"))
    data = company()
    products = {row["docId"]: row for row in data.products}
    shops = {row["docId"]: row for row in data.retailers}
    run = simulation(7)
    owners = assign_areas(simulated_shops(data, team(), 5), team())
    assert len(run.documents["orders"]) > 100
    for doc_id, order in run.documents["orders"].items():
        assert set(order) - {"simulationBatchId"} - _approval_keys() <= allowed
        assert {"orderId", "visitSource", "retailerId", "salesmanUid", "items", "commercialLines", "totalBoxes",
                "totalPrice", "totalProducts", "submittedAt", "status", "commercialSchemaVersion"} <= set(order)
        assert order["orderId"] == doc_id and order["retailerId"] in shops
        assert order["retailerName"] == order["outlet"] == shops[order["retailerId"]]["retailerName"]
        owner = owners[order["retailerId"]]
        uid = order["salesmanUid"]
        assert uid == owner.uid and order["salesmanCode"] == order["salesmanId"] == owner.code
        assert [order[key] for key in ("uid", "userUid", "submittedByUid", "createdByUid")] == [uid] * 4
        assert order["supervisorId"] == team().supervisor_of(uid).code
        assert 1 <= len(order["items"]) <= 25 and lines_rule.fullmatch(",".join(order["commercialLines"]))
        assert order["totalProducts"] == len(order["commercialLines"]) == len(order["items"])
        assert order["totalBoxes"] == sum(item["qty"] for item in order["items"]) and order["status"] == "approved"
        assert order["submittedAt"] == order["createdAt"] < order["approvedAt"] == order["updatedAt"]
        sen = 0
        for item, line in zip(order["items"], order["commercialLines"]):
            product = products[item["productId"]]
            assert isinstance(product["price"], float) and product["price"] > 0
            expected = 2.5 if order["retailerId"] == "R001" else product["price"]
            assert item["price"] == expected and item["name"] == item["productName"] == product["productName"]
            assert item["departmentName"] == item["department"] and isinstance(item["packingSize"], str)
            assert item["shelfBatches"] == [] and item["remarks"] == "" and item["expiry"] == ""
            assert isinstance(item["qty"], int) and 1 <= item["qty"] <= item["maxOrderQty"] <= 999
            assert line.split("~")[0] == item["productId"] and line.split("~")[2:] == [str(item["qty"]), str(round(expected * 100))]
            sen += item["qty"] * round(expected * 100)
        assert round(order["totalPrice"] * 100) == sen and 0 < order["totalPrice"] <= 10000000
        assert order["visitSource"] == "personal_planner" and doc_id.startswith(f"SIM-{run.settings.batch}-")
        assert not {"routePlanId", "routeStopId"} & set(order)


class Book:
    def __init__(self, data):
        self.products = {row["docId"]: row for row in data.products}
        self.shops = {row["docId"]: row for row in data.retailers}
        self.people = {row["docId"]: row for row in data.users}
        self.sheets = data.sheets

    def product(self, key):
        return self.products.get(key)

    def retailer(self, key):
        return self.shops.get(key)

    def profile(self, key):
        return self.people.get(key)

    def sheet(self, key):
        return self.sheets.get(key)


def test_the_platform_price_check_stamps_every_simulated_order_ok():
    book = Book(company())
    stamps = Counter(
        (stamp["status"], stamp["reason"])
        for stamp in (price_order(order, book, NOW) for order in simulation(7).documents["orders"].values())
    )
    assert set(stamps) == {("ok", None)}


def test_no_record_is_dated_after_the_write_time_and_a_future_cutoff_is_refused(tmp_path):
    for seed in (7, 3):
        for data in every_document(simulation(seed)).values():
            assert all(value <= NOW for value in data.values() if isinstance(value, datetime))
            assert all(
                value < _moment(FIRST, 0) for key, value in data.items()
                if isinstance(value, datetime) and key in ("submittedAt", "completedAt", "arrivedAt", "clientCreatedAt")
            )
    with pytest.raises(SimulationError, match="after the current week"):
        simulate(company(), team(), Settings(first_cutoff=FIRST, cutoff=FIRST + timedelta(weeks=1), seed=7), now=NOW)
    run = simulation(7, 1)
    with pytest.raises(SimulationError, match="dated after now"):
        cli.apply_manifest(MemoryStore(), run, "orders", "alljoys-fixture", now=NOW, order_limit=900, journal=tmp_path / "j.journal")


def test_the_company_total_stays_under_the_order_limit(tmp_path):
    run = simulation(7)
    assert 60 + len(run.documents["orders"]) < 900
    with pytest.raises(SimulationError, match="The limit is 900"):
        simulate(company(900), resolve_team(company(900), ROSTER), Settings(first_cutoff=FIRST, cutoff=FIRST, seed=7), now=NOW)
    store = MemoryStore({f"orders/REAL-{index}": {} for index in range(800)})
    with pytest.raises(SimulationError, match="Nothing was written"):
        cli.apply_manifest(store, run, "orders", "alljoys-fixture", now=NOW, order_limit=900, journal=tmp_path / "j.journal")
    assert len(store.documents) == 800


def test_each_shop_orders_on_its_one_weekday_and_the_mix_is_six_eight_six():
    for seed in SEEDS:
        run = simulation(seed)
        days: dict[str, set[int]] = {}
        for order in run.documents["orders"].values():
            days.setdefault(order["retailerId"], set()).add(order["submittedAt"].astimezone(ASIA_KUCHING).weekday())
        assert len(days) == 20
        assert all(days[key] == {plan.weekday} and plan.weekday < 5 for key, plan in run.shops.items())
        assert Counter(plan.cadence for plan in run.shops.values()) == {1: 6, 2: 8, 4: 6}
        assert Counter(plan.person.uid for plan in run.shops.values()) == {f"sp-{index:02d}": 5 for index in range(1, 5)}


def test_no_record_carries_a_demo_mark_and_every_record_carries_the_batch():
    for seed in (7, 3):
        run = simulation(seed)
        for path, data in every_document(run).items():
            assert not is_demo_record({"docId": path.split("/", 1)[1], **data}), path
            assert data["simulationBatchId"] == run.settings.batch
            assert not {"syntheticBatchId", "environment", "dataSource"} & set(data)


@pytest.mark.parametrize("seed", SEEDS)
def test_the_real_pipeline_tells_the_story_on_live_plus_simulated_data(seed):
    data = company()
    for weeks_after in range(3):
        run = simulation(seed, weeks_after)
        cutoff = FIRST + timedelta(weeks=weeks_after)
        result = run_pipeline(data, run.shops, run.documents, cutoff, 8)
        planted = run.story.stops[weeks_after]
        stopped = stopped_pairs(result)
        assert stopped == {planted}
        insight = next(
            row for row in result.insights
            if row["type"] == "stopped_product" and (row["retailerId"], row["productId"]) == planted
        )
        assert insight["priority"] == "high"
        ranking = next(
            rows for rows in result.priority_rankings if rows["salesmanCode"] == run.shops[planted[0]].person.code
        )
        assert [row["retailerId"] for row in ranking["ranking"] if row["rank"] == 1] == [planted[0]]
        assert rank_of(result, planted[0]) == 1
        assert len(result.priority_rankings) == 4
        assert sorted(len(rows["ranking"]) for rows in result.priority_rankings) == [5, 5, 5, 5]
        assert all(row["score"] > 0 for rows in result.priority_rankings for row in rows["ranking"])
        plain = run_pipeline(data, run.shops, run.documents, cutoff, 8, with_simulated_outcomes=False)
        assert stopped_pairs(plain) == {planted}


@pytest.mark.parametrize("seed", SEEDS)
def test_the_stopped_shop_and_the_recovered_shop_have_the_planted_order_history(seed):
    run = simulation(seed)
    bought: dict[tuple[str, str], set[int]] = {}
    ordered: dict[str, set[int]] = {}
    for order in run.documents["orders"].values():
        back = (FIRST - week_start(order["submittedAt"])).days // 7
        ordered.setdefault(order["retailerId"], set()).add(back)
        for item in order["items"]:
            bought.setdefault((order["retailerId"], item["productId"]), set()).add(back)
    shop, product = run.story.stops[0]
    assert bought[(shop, product)] & set(range(1, 9)) == {3, 4, 5, 6, 7, 8}
    assert {1, 2} <= ordered[shop]
    shop, product = run.story.recovered
    assert bought[(shop, product)] & set(range(1, 9)) == {1, 2, 3, 7, 8}
    outcome = [
        row for row in run.documents["conversation_outcomes"].values()
        if row["retailerId"] == shop and row.get("issueType") == "stopped_product"
    ]
    assert len(outcome) == 1 and outcome[0]["reasonCode"] == RECOVERY_REASON == "shelf_space_limited"
    assert (FIRST - week_start(outcome[0]["submittedAt"])).days // 7 == 4
    assert outcome[0]["issueKey"] == f"stopped_product::{shop}::{product}" and outcome[0]["productId"] == product
    assert set(run.story.stops) | {run.story.recovered} and len({run.shops[key].person.uid for key, _ in (*run.story.stops, run.story.recovered)}) == 4


def test_past_visits_use_the_product_ids_and_shapes():
    reasons = set(_rule_text(r"code\.matches\('\^\(([a-z_|]+)\)\$'\)").split("|"))
    run = simulation(7)
    first_visit_week = FIRST - timedelta(weeks=run.settings.visit_weeks)
    order_days = {
        (order["retailerId"], order["submittedAt"].astimezone(ASIA_KUCHING).date())
        for order in run.documents["orders"].values()
    }
    kinds = Counter()
    for outcome_id, outcome in run.documents["conversation_outcomes"].items():
        owner = run.shops[outcome["retailerId"]].person
        assert outcome["outcomeId"] == outcome_id and outcome["reasonCode"] in reasons and outcome["isDemo"] is False
        assert outcome["salesmanUid"] == owner.uid and outcome["salesmanCode"] == owner.code
        assert first_visit_week <= week_start(outcome["submittedAt"]) < FIRST
        assert outcome["planId"] == f"SIM-{run.settings.batch}-{owner.code}-{week_start(outcome['submittedAt']):%Y%m%d}"
        assert outcome["planId"] in run.documents["route_plans"]
        if outcome.get("outcomeKind") == "no_order":
            assert len(outcome) == 15 + 1 and outcome["source"] == "mobile_assigned_route_no_order"
            day = outcome["submittedAt"].astimezone(ASIA_KUCHING).date()
            assert (outcome["retailerId"], day) not in order_days
            kinds["no_order"] += 1
        else:
            assert len(outcome) == 21 + 1 and outcome["source"] == "mobile_assigned_route_copilot"
            assert outcome["issueKey"] == "::".join((outcome["issueType"], outcome["retailerId"], outcome["productId"]))
            kinds["insight"] += 1
    assert kinds["insight"] == 1 and kinds["no_order"] >= 1


def test_shop_assignments_follow_the_dashboard_payload_and_the_map():
    dart = (ROOT / "admin_dashboard" / "lib" / "utils" / "retailer_bulk_assign.dart").read_text(encoding="utf-8")
    listed = re.search(r"kLegacyRetailerAssignmentFields = <String>\[(.*?)\];", dart, re.S).group(1)
    assert tuple(re.findall(r"'([A-Za-z_]+)'", listed)) == LEGACY_ASSIGNMENT_FIELDS
    data = company()
    shops = simulated_shops(data, team(), 5)
    owners = assign_areas(shops, team())
    plan = shop_assignment_plan(shops, owners)
    assert len(plan) == 20 and Counter(row["set"]["assignedSalesmanId"] for row in plan) == {"S01": 5, "S02": 5, "S03": 5, "S04": 5}
    assert all(row["before"] == {"assignedSalesmanId": "S09", "assignedSalesmanCodes": ["S09"]} for row in plan)
    assert all(row["deleteFields"] == ["assignedSalesmanCodes"] and not row["unchanged"] for row in plan)
    longitude = {row["docId"]: row["longitude"] for row in shops}
    latitude = {row["docId"]: row["latitude"] for row in shops}
    west = [key for key, person in owners.items() if person.uid in ("sp-01", "sp-02")]
    east = [key for key, person in owners.items() if person.uid in ("sp-03", "sp-04")]
    assert max(longitude[key] for key in west) <= min(longitude[key] for key in east)
    for low, high, group in (("sp-01", "sp-02", west), ("sp-03", "sp-04", east)):
        assert max(latitude[key] for key in group if owners[key].uid == low) <= min(
            latitude[key] for key in group if owners[key].uid == high
        )


def test_staff_moves_take_leavers_out_first_and_never_overfill_a_team():
    plan = staff_move_plan(company(), team())
    assert plan["blocked"] == []
    reasons = [step["reason"] for step in plan["steps"]]
    assert reasons == sorted(reasons, key=lambda reason: reason != "leaves the demo team")
    assert reasons.count("leaves the demo team") == 6 and reasons.count("joins the demo team") == 4
    assert [step["salespersonCode"] for step in plan["steps"] if step["fixesOwnLinkOnly"]] == ["S04"]
    assert all(step["command"] == "move_salesperson" for step in plan["steps"])
    assert all(size <= SUPERVISOR_CAP for step in plan["steps"] for size in step["rosterSizeAfter"].values())
    assert plan["rostersAfter"]["sup-a"] == ["GONE1", "S01", "S02"] and plan["rostersAfter"]["sup-b"] == ["S03", "S04"]
    assert sorted(plan["rostersAfter"]["sup-c"] + plan["rostersAfter"]["sup-d"]) == ["S05", "S06", "S07", "S08", "S09", "S10"]
    assert [row["rosterCode"] for row in plan["fallbackClears"]] == ["GONE1"]
    earliest = {step["salespersonUid"]: step["fromSupervisorUids"][0] for step in reversed(plan["steps"]) if step["fromSupervisorUids"]}
    parked = plan["undoCannotRestore"]["parkedWithLeaverSupervisor"]
    assert {undo["salespersonUid"]: undo["toSupervisorUid"] for undo in plan["undoSteps"]} == {
        **earliest, **{uid: "sup-c" for uid in parked}}
    assert "Person" not in json.dumps(plan) and ".test" not in json.dumps(plan)


def test_a_full_team_with_no_free_leaver_supervisor_is_reported_blocked():
    body = collections()
    for name in ("users", "user_access"):
        body[name]["sup-c"]["assignedSalesmanCodes"] = ["X1", "X2", "X3", "X4", "X5"]
        body[name]["sup-d"]["assignedSalesmanCodes"] = ["S02", "S03", "X6", "X7", "X8"]
    data = company_from_collections("alljoys-fixture", body)
    plan = staff_move_plan(data, resolve_team(data, ROSTER))
    assert {row["problem"] for row in plan["blocked"]} >= {"no leaver supervisor of the roster file has a free place"}


def test_the_roster_file_must_name_each_person_once_and_only_known_people():
    body = collections()
    body["users"]["sp-11"] = {**body["users"]["sp-01"], "uid": "sp-11", "employeeCode": "S11"}
    data = company_from_collections("alljoys-fixture", body)
    with pytest.raises(SimulationError, match="matches 2 people"):
        resolve_team(data, ROSTER)
    with pytest.raises(SimulationError, match="matches 0 people"):
        resolve_team(company(), {**ROSTER, "routeAuthor": "nobody"})
    with pytest.raises(SimulationError, match="two places"):
        resolve_team(company(), {**ROSTER, "teams": [ROSTER["teams"][0], {"supervisor": "sup-b", "salespeople": ["sp-01", "sp-04"]}]})


def test_a_shop_count_that_does_not_fit_and_a_product_without_price_are_refused():
    body = collections()
    del body["retailers"]["R020"]
    data = company_from_collections("alljoys-fixture", body)
    with pytest.raises(SimulationError, match="19 active shops"):
        simulate(data, resolve_team(data, ROSTER), Settings(first_cutoff=FIRST, cutoff=FIRST), now=NOW)
    body = collections()
    for product in list(body["products"])[5:]:
        body["products"][product].pop("price", None)
    data = company_from_collections("alljoys-fixture", body)
    with pytest.raises(SimulationError, match="Only 5 products"):
        simulate(data, resolve_team(data, ROSTER), Settings(first_cutoff=FIRST, cutoff=FIRST), now=NOW)
    used = {item["productId"] for order in simulation(7).documents["orders"].values() for item in order["items"]}
    assert "P031" not in used


class FailingStore(MemoryStore):
    def __init__(self, fail_on: int):
        super().__init__()
        self.fail_on = fail_on
        self.calls = 0
        self.lose_after_create = False

    def create(self, path, data):
        self.calls += 1
        if self.calls == self.fail_on:
            if self.lose_after_create:
                super().create(path, data)
            raise ConnectionError("network down")
        return super().create(path, data)


def _apply(store, run, journal, name="orders"):
    return cli.apply_manifest(store, run, name, "alljoys-fixture", now=NOW, order_limit=900, journal=journal)


def _owned(manifest):
    return {row["path"] for row in manifest["documents"] if row["status"] == "written"}


def test_a_write_that_dies_part_way_leaves_a_journal_that_undo_can_use(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = FailingStore(fail_on=5)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    rebuilt = cli.manifest_from_journal(journal)
    assert _owned(rebuilt) == set(store.documents) and len(store.documents) == 4
    report = cli.undo_manifest(store, json.loads(json.dumps(rebuilt)))
    assert len(report["deleted"]) == 4 and not store.documents


def test_a_create_that_succeeded_but_raised_is_never_claimed_on_resume_or_by_undo(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = FailingStore(fail_on=2)
    store.lose_after_create = True
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    order, purchase_order = sorted(store.documents)
    assert cli.order_group(order) == cli.order_group(purchase_order) and purchase_order.startswith("purchase_orders/")
    unresolved = cli.manifest_from_journal(journal)
    assert unresolved["counts"] == {"written": 1, "pending": 1, cli.CHECK_BY_HAND: 0}
    undone = _copy(store)
    report = cli.undo_manifest(undone, unresolved)
    assert report["deleted"] == [] and report["checkByHand"] == [purchase_order]
    assert report["skippedChanged"] == [purchase_order] and report["keptWithChangedPartner"] == [order]
    assert sorted(undone.documents) == [order, purchase_order]
    store.fail_on = 0
    done = _apply(store, run, journal)
    planned = cli.planned_documents(run, "orders")
    rows = {row["path"]: row["status"] for row in done["documents"]}
    assert rows[order] == "written" and rows[purchase_order] == cli.CHECK_BY_HAND
    assert done["counts"] == {"written": len(planned) - 1, "exists_same": 0, "exists_different": 0, cli.CHECK_BY_HAND: 1}
    assert set(store.documents) == set(planned)
    report = _undo(store, done)
    assert len(report["deleted"]) == len(planned) - 2 and report["checkByHand"] == [purchase_order]
    assert sorted(store.documents) == [order, purchase_order]


def test_a_crash_before_the_first_create_or_with_a_torn_journal_line_loses_nothing(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    journal.write_text("", encoding="utf-8")
    store = FailingStore(fail_on=6)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    with journal.open("a", encoding="utf-8") as handle:
        handle.write('{"path": "orders/x", "t": "do')
    assert len(cli.read_journal(journal)[1]) == 6
    store.fail_on = 0
    resumed = _apply(store, run, journal)
    assert resumed["counts"]["written"] == len(cli.planned_documents(run, "orders"))
    assert _owned(resumed) == set(cli.planned_documents(run, "orders"))
    assert cli.read_journal(journal)[2][-1].startswith("{")
    lines = journal.read_text(encoding="utf-8").split("\n")
    lines[2] = "{broken"
    journal.write_text("\n".join(lines), encoding="utf-8")
    with pytest.raises(SimulationError, match="damaged"):
        _apply(store, run, journal)


def test_a_repeated_apply_never_loses_the_first_runs_update_times(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = MemoryStore()
    first = _apply(store, run, journal)
    again = _apply(store, run, journal)
    assert [row.get("updateTime") for row in again["documents"]] == [row["updateTime"] for row in first["documents"]]
    report = cli.undo_manifest(store, json.loads(json.dumps(again)))
    assert len(report["deleted"]) == len(first["documents"]) and not store.documents


def test_a_journal_of_another_project_batch_seed_or_write_set_is_refused(tmp_path):
    journal = tmp_path / "m.json.journal"
    store = MemoryStore()
    _apply(store, simulation(7), journal)
    before = journal.read_text(encoding="utf-8")
    with pytest.raises(SimulationError, match="another run"):
        _apply(store, simulation(3), journal)
    with pytest.raises(SimulationError, match="another run"):
        cli.apply_manifest(store, simulation(7), "orders", "other-project", now=NOW, order_limit=900, journal=journal)
    with pytest.raises(SimulationError, match="another run"):
        _apply(store, simulation(7), journal, name="routes")
    assert journal.read_text(encoding="utf-8") == before


def test_a_second_process_is_refused_while_the_lock_is_held(tmp_path):
    journal = tmp_path / "m.json.journal"
    lock = tmp_path / "m.json.journal.lock"
    lock.write_text("1", encoding="utf-8")
    store = MemoryStore()
    with pytest.raises(SimulationError, match="Another write holds"):
        _apply(store, simulation(7), journal)
    assert not store.documents and not journal.exists()
    lock.unlink()
    _apply(store, simulation(7), journal)
    assert not lock.exists()


def test_undo_deletes_nothing_it_did_not_write_after_a_resume(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    path = next(iter(cli.planned_documents(run, "orders")))
    store = FailingStore(fail_on=4)
    store.documents[path] = ({**every_document(run)[path], "status": "rejected"}, 1)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    store.fail_on = 0
    done = _apply(store, run, journal)
    assert path not in _owned(done) and done["counts"]["exists_different"] == 1
    cli.undo_manifest(store, json.loads(json.dumps(done)))
    assert list(store.documents) == [path]


def test_write_refuses_to_overwrite_a_manifest_or_journal_it_does_not_resume(tmp_path):
    manifest = tmp_path / "m.json"
    journal = cli.journal_path(manifest)
    cli.refuse_overwrite(manifest, applying=True)
    cli.refuse_overwrite(manifest, applying=False)
    manifest.write_text('{"mode": "apply"}', encoding="utf-8")
    with pytest.raises(SimulationError, match="without its journal"):
        cli.refuse_overwrite(manifest, applying=True)
    with pytest.raises(SimulationError, match="applied write"):
        cli.refuse_overwrite(manifest, applying=False)
    journal.write_text('{"t": "header"}\n', encoding="utf-8")
    cli.refuse_overwrite(manifest, applying=True)
    with pytest.raises(SimulationError, match="earlier write"):
        cli.refuse_overwrite(manifest, applying=False)


def _copy(store):
    other = MemoryStore()
    other.documents = dict(store.documents)
    other.ticks = itertools.count(max((tick for _, tick in store.documents.values()), default=1) + 1)
    return other


def _undo(store, manifest):
    return cli.undo_manifest(store, json.loads(json.dumps(manifest)))


def _run_ids(store):
    return {data.get(cli.WRITE_ID_FIELD) for data, _ in store.documents.values()}


def test_every_created_record_is_the_planned_record_plus_the_run_id_of_its_journal(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = FailingStore(fail_on=4)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    run_id = cli.read_journal(journal)[0]["runId"]
    assert re.fullmatch(r"[0-9a-f]{32}", run_id)
    store.fail_on = 0
    done = _apply(store, run, journal)
    top_up = cli.apply_manifest(
        store, simulation(7, 1), "orders", "alljoys-fixture", now=NOW + timedelta(weeks=1), order_limit=900, journal=journal,
    )
    assert done["runId"] == top_up["runId"] == cli.manifest_from_journal(journal)["runId"] == run_id
    planned = cli.planned_documents(simulation(7, 1), "orders")
    assert {path: data for path, (data, _) in store.documents.items()} == {
        path: {**data, cli.WRITE_ID_FIELD: run_id} for path, data in planned.items()
    }
    sample = next(iter(planned.values()))
    assert cli.fingerprint({**sample, cli.WRITE_ID_FIELD: "another"}) == cli.fingerprint(sample)
    assert cli.fingerprint({**sample, "status": "rejected"}) != cli.fingerprint(sample)
    assert len(_undo(store, top_up)["deleted"]) == len(planned) and not store.documents


def test_a_record_that_another_journal_created_with_the_same_content_is_never_claimed_or_deleted(tmp_path):
    run = simulation(7)
    first_journal, second_journal = tmp_path / "a.json.journal", tmp_path / "b.json.journal"
    store = FailingStore(fail_on=2)
    with pytest.raises(ConnectionError):
        _apply(store, run, first_journal)
    crashed = cli.manifest_from_journal(first_journal)
    assert crashed["counts"] == {"written": 1, "pending": 1, cli.CHECK_BY_HAND: 0}
    contested = next(row["path"] for row in crashed["documents"] if row["status"] == "pending")
    assert contested not in store.documents and cli.order_group(contested) == cli.order_group(next(iter(_owned(crashed))))
    store.fail_on = 0
    second = _apply(store, run, second_journal)
    assert second["runId"] != crashed["runId"] and contested not in store.documents
    assert second["counts"]["exists_same"] == 1 and second["counts"]["held_back"] == 1
    assert [held["group"] for held in second["heldGroups"]] == [cli.order_group(contested)]
    assert {member["state"] for member in second["heldGroups"][0]["members"]} == {"not owned by this run, same content"}
    assert not _owned(second) & _owned(crashed)
    undone = _copy(store)
    report = _undo(undone, crashed)
    assert report["existsNotOwned"] == [] and sorted(report["deleted"]) == sorted(_owned(crashed))
    assert set(undone.documents) == _owned(second)
    undone = _copy(store)
    report = _undo(undone, second)
    assert report["existsNotOwned"] == [] and set(undone.documents) == _owned(crashed)
    resumed = _apply(store, run, first_journal)
    assert _owned(resumed) == {*_owned(crashed), contested}
    assert resumed["counts"] == {"written": 2, "exists_same": len(second["documents"]) - 2, "exists_different": 0}
    assert len(resumed["heldGroups"]) == len(run.documents["orders"]) - 1
    assert not _owned(resumed) & _owned(second)
    assert _owned(cli.manifest_from_journal(first_journal)) == _owned(resumed)
    report = _undo(store, resumed)
    assert sorted(report["deleted"]) == sorted(_owned(resumed)) and report["existsNotOwned"] == []
    assert set(store.documents) == _owned(second) and _run_ids(store) == {second["runId"]}
    assert len(_undo(store, second)["deleted"]) == len(_owned(second)) and not store.documents


def test_a_created_record_that_a_person_edited_is_not_claimed_and_not_deleted(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = FailingStore(fail_on=2)
    store.lose_after_create = True
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    crashed = cli.manifest_from_journal(journal)
    edited = next(row["path"] for row in crashed["documents"] if row["status"] == "pending")
    store.change(edited, status="rejected")
    first_group = sorted(_owned(crashed))
    assert len(first_group) == 1 and cli.order_group(first_group[0]) == cli.order_group(edited)
    undone = _copy(store)
    report = _undo(undone, crashed)
    assert report["skippedChanged"] == [edited] and report["deleted"] == []
    assert report["keptWithChangedPartner"] == first_group and set(undone.documents) == {edited, *first_group}
    store.fail_on = 0
    resumed = _apply(store, run, journal)
    assert edited not in _owned(resumed) and resumed["counts"][cli.CHECK_BY_HAND] == 1
    assert resumed["counts"]["exists_different"] == 0 and store.documents[edited][0]["status"] == "rejected"
    stripped = min(
        path for path in _owned(resumed)
        if path.startswith("orders/") and cli.order_group(path) != cli.order_group(edited)
    )
    partners = _partners(resumed, stripped)
    data, version = store.documents[stripped]
    store.documents[stripped] = ({key: value for key, value in data.items() if key != cli.WRITE_ID_FIELD}, version)
    report = _undo(store, resumed)
    assert report["existsNotOwned"] == [stripped] and report["skippedChanged"] == [edited]
    assert partners == ["purchase_orders/" + stripped.split("/", 1)[1]]
    assert report["keptWithChangedPartner"] == sorted([*partners, *first_group])
    assert sorted(store.documents) == sorted({edited, stripped, *partners, *first_group})


def test_a_journal_or_manifest_with_no_run_id_writes_nothing_and_deletes_nothing(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = FailingStore(fail_on=3)
    store.lose_after_create = True
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    lines = journal.read_text(encoding="utf-8").split("\n")
    header = json.loads(lines[0])
    del header["runId"]
    lines[0] = json.dumps(header, sort_keys=True)
    journal.write_text("\n".join(lines), encoding="utf-8")
    before = journal.read_text(encoding="utf-8")
    kept = dict(store.documents)
    store.fail_on = 0
    with pytest.raises(SimulationError, match="no run id"):
        _apply(store, run, journal)
    old = cli.manifest_from_journal(journal)
    assert "runId" not in old and old["counts"] == {"written": 2, "pending": 1, cli.CHECK_BY_HAND: 0}
    for target in (store, None):
        with pytest.raises(SimulationError, match="no run id"):
            cli.undo_manifest(target, old)
    assert journal.read_text(encoding="utf-8") == before and store.documents == kept
    plan = cli.build_manifest(run, "orders", "alljoys-fixture", {})
    assert "runId" not in plan and cli.undo_manifest(store, plan)["deleted"] == [] and store.documents == kept


def test_a_second_undo_deletes_nothing_even_when_another_journal_made_the_records_again(tmp_path):
    run = simulation(7)
    store = MemoryStore()
    first = _apply(store, run, tmp_path / "a.json.journal")
    assert len(_undo(store, first)["deleted"]) == len(first["documents"]) and not store.documents
    again = _undo(store, first)
    assert again["deleted"] == [] and again["existsNotOwned"] == []
    assert again["skippedChanged"] == [] and sorted(again["alreadyGone"]) == sorted(row["path"] for row in first["documents"])
    assert not any(again.get(key) for key in cli.UNDO_KEPT_BACK)
    second = _apply(store, run, tmp_path / "b.json.journal")
    third = _undo(store, first)
    assert third["deleted"] == [] and sorted(third["existsNotOwned"]) == sorted(_owned(second))
    assert set(store.documents) == _owned(second) and _run_ids(store) == {second["runId"]}


class RefusingStore(MemoryStore):
    def __init__(self, path: str, stored_first: dict | None):
        super().__init__()
        self.path = path
        self.stored_first = stored_first

    def create(self, path, data):
        if path == self.path and path not in self.documents:
            self.documents[path] = (dict(data if self.stored_first is None else self.stored_first), 1)
            return None
        return super().create(path, data)


def test_a_refused_create_that_carries_this_run_id_is_checked_by_hand_and_never_claimed(tmp_path):
    run = simulation(7)
    planned = cli.planned_documents(run, "orders")
    path = list(planned)[2]
    own = RefusingStore(path, None)
    done = _apply(own, run, tmp_path / "a.json.journal")
    rows = {row["path"]: row["status"] for row in done["documents"]}
    assert rows[path] == cli.CHECK_BY_HAND and path not in _owned(done) and done["counts"][cli.CHECK_BY_HAND] == 1
    assert len(_owned(done)) == len(planned) - 2
    report = _undo(own, done)
    assert path in report["checkByHand"] and len(report["deleted"]) == len(planned) - 2 and list(own.documents) == [path]
    first = RefusingStore(path, {**planned[path], cli.WRITE_ID_FIELD: "another-run"})
    done = _apply(first, run, tmp_path / "c.json.journal")
    assert path.startswith("orders/") and _owned(done) == set(planned) - set(cli.group_paths(path))
    assert done["counts"]["exists_same"] == 1 and done["counts"]["held_back"] == 1
    report = _undo(first, done)
    assert len(report["deleted"]) == len(planned) - 2 and list(first.documents) == [path]
    taken = list(planned)[3]
    order = "orders/" + taken.split("/", 1)[1]
    assert taken.startswith("purchase_orders/") and list(planned)[2] == order
    other = RefusingStore(taken, {**planned[taken], cli.WRITE_ID_FIELD: "another-run"})
    done = _apply(other, run, tmp_path / "b.json.journal")
    assert taken not in _owned(done) and done["counts"]["exists_same"] == 1 and done["counts"]["exists_different"] == 0
    assert _owned(done) == set(planned) - {taken}
    assert taken not in _owned(cli.manifest_from_journal(tmp_path / "b.json.journal"))
    assert [held["group"] for held in done["heldGroups"]] == [cli.order_group(taken)]
    report = _undo(other, done)
    assert report["existsNotOwned"] == [taken] and report["keptWithChangedPartner"] == [order]
    assert sorted(other.documents) == [order, taken] and other.documents[taken][0][cli.WRITE_ID_FIELD] == "another-run"


def test_apply_on_the_path_of_a_dry_run_plan_is_refused_with_the_reason(tmp_path):
    manifest = tmp_path / "m.json"
    cli.write_json(manifest, cli.build_manifest(simulation(7), "orders", "alljoys-fixture", {}))
    with pytest.raises(SimulationError, match=r"This file is a dry-run plan\. Use a new --manifest path for --apply, or delete it\."):
        cli.refuse_overwrite(manifest, applying=True)
    cli.refuse_overwrite(manifest, applying=False)


def _crash_after_two_writes(tmp_path, name="a.json.journal"):
    run = simulation(7)
    journal = tmp_path / name
    store = FailingStore(fail_on=3)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    store.fail_on = 0
    mine = sorted(_owned(cli.manifest_from_journal(journal)))
    assert len(mine) == 2
    return run, journal, store, mine


def test_a_resume_does_not_claim_a_record_that_another_journal_made_after_it_was_deleted(tmp_path):
    run, first_journal, store, mine = _crash_after_two_writes(tmp_path)
    for path in mine:
        del store.documents[path]
    second = _apply(store, run, tmp_path / "b.json.journal")
    assert _owned(second) == set(cli.planned_documents(run, "orders"))
    resumed = _apply(store, run, first_journal)
    rows = {row["path"]: row for row in resumed["documents"]}
    assert resumed["runId"] != second["runId"]
    assert all(rows[path]["status"] == "exists_same" and "updateTime" not in rows[path] for path in mine)
    assert _owned(resumed) == set()
    assert _owned(cli.manifest_from_journal(first_journal)) == set()
    report = _undo(store, resumed)
    assert report["deleted"] == [] and report["existsNotOwned"] == []
    assert set(store.documents) == _owned(second) and _run_ids(store) == {second["runId"]}
    again = _apply(store, run, first_journal)
    assert _owned(again) == set() and {row["path"] for row in again["documents"] if row["status"] == "exists_same"} == set(rows)


def test_a_resume_marks_a_foreign_record_with_other_content_as_existing_not_owned(tmp_path):
    run, journal, store, mine = _crash_after_two_writes(tmp_path)
    store.documents[mine[0]] = ({"status": "approved"}, 1)
    resumed = _apply(store, run, journal)
    rows = {row["path"]: row for row in resumed["documents"]}
    assert rows[mine[0]]["status"] == "exists_different" and rows[mine[1]]["status"] == "written"
    assert mine[0] not in _owned(cli.manifest_from_journal(journal))
    report = _undo(store, resumed)
    assert mine[0] not in report["deleted"] and mine[0] in store.documents


def test_a_resume_does_not_create_again_a_record_a_person_deleted(tmp_path):
    run = simulation(7)
    journal = tmp_path / "a.json.journal"
    store = FailingStore(fail_on=2)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    store.fail_on = 0
    mine = sorted(_owned(cli.manifest_from_journal(journal)))
    assert len(mine) == 1 and mine[0].startswith("orders/") and list(store.documents) == mine
    del store.documents[mine[0]]
    resumed = _apply(store, run, journal)
    rows = {row["path"]: row for row in resumed["documents"]}
    planned = cli.planned_documents(run, "orders")
    assert rows[mine[0]]["status"] == "deleted" and "updateTime" not in rows[mine[0]]
    assert mine[0] not in store.documents and resumed["counts"]["deleted"] == 1
    assert mine[0].startswith("orders/") and resumed["counts"]["held_back"] == 1
    assert rows[f"purchase_orders/{mine[0].split('/', 1)[1]}"]["status"] == "held_back"
    assert resumed["counts"]["written"] == len(planned) - 2
    assert next(row for row in cli.manifest_from_journal(journal)["documents"] if row["path"] == mine[0])["status"] == "deleted"
    again = _apply(store, run, journal)
    assert again["counts"]["deleted"] == 1 and mine[0] not in store.documents
    assert again["documents"] == resumed["documents"]
    report = _undo(store, again)
    assert len(report["deleted"]) == len(planned) - 2 and report["skippedChanged"] == [] and not store.documents


def test_a_resume_keeps_a_record_a_person_edited_when_it_still_carries_this_run_id_and_lists_it_for_a_person(tmp_path):
    run, journal, store, mine = _crash_after_two_writes(tmp_path)
    store.change(mine[0], status="rejected")
    edited = store.documents[mine[0]]
    resumed = _apply(store, run, journal)
    row = next(row for row in resumed["documents"] if row["path"] == mine[0])
    assert row["status"] == cli.CHECK_BY_HAND and "updateTime" not in row
    report = _undo(store, resumed)
    assert report["checkByHand"] == [mine[0]] and mine[0] not in report["deleted"]
    assert store.documents[mine[0]] == edited


def test_a_top_up_after_a_person_deleted_a_record_creates_only_the_new_records(tmp_path):
    run, journal, store, mine = _crash_after_two_writes(tmp_path)
    _apply(store, run, journal)
    del store.documents[mine[0]]
    later = simulation(7, 1)
    top_up = cli.apply_manifest(
        store, later, "orders", "alljoys-fixture", now=NOW + timedelta(weeks=1), order_limit=900, journal=journal,
    )
    planned = cli.planned_documents(later, "orders")
    assert mine[0] not in store.documents
    assert next(row for row in top_up["documents"] if row["path"] == mine[0])["status"] == "deleted"
    assert set(store.documents) == set(planned) - {mine[0]} and _owned(top_up) == set(planned) - {mine[0]}
    report = _undo(store, top_up)
    assert len(report["deleted"]) == len(planned) - 1 and not store.documents


def _order_ids(store) -> set[str]:
    return {path.split("/", 1)[1] for path in store.documents if path.startswith("orders/")}


def _purchase_order_ids(store) -> set[str]:
    return {path.split("/", 1)[1] for path in store.documents if path.startswith("purchase_orders/")}


def test_every_simulated_order_is_approved_as_the_dashboard_approves_it():
    decision_needs = _names(_rule_text(r"changed\.hasAll\(\[('approvedAt'.*?)\]\)"))
    purchase_order_keys = _names(_rule_text(r"function purchaseOrderKeys\(\) \{\s*return \[(.*?)\];"))
    number_rule = re.compile(_rule_text(r"po\.poNumber\.matches\('(.*?)'\)"))
    audit_keys = _names(_rule_text(r"function validAuditShape\(data\) \{.*?data\.keys\(\)\.hasOnly\(\[(.*?)\]\)"))
    assert _approval_keys() == {"status", "approvedAt", "approvedByUid", "approvedByName", "approvedByRole", "updatedAt"}
    assert "'poNumber': 'PO-$date-$shortId'" in REPOSITORY and f"cleanId.length > {PURCHASE_ORDER_ID_TAIL}" in REPOSITORY
    assert "collection('purchase_orders').doc(orderDocumentId.trim())" in REPOSITORY
    admin = team().author
    assert (admin.uid, admin.role, admin.status) == ("u-admin", "admin", "active")
    for seed, weeks_after in ((7, 0), (3, 0), (7, 2)):
        run = simulation(seed, weeks_after)
        now = NOW + timedelta(weeks=weeks_after)
        orders = run.documents["orders"]
        assert set(run.documents["purchase_orders"]) == set(orders)
        assert "system_audit_logs" not in run.documents
        numbers = Counter()
        for doc_id, order in orders.items():
            assert order["status"] == "approved" and _approval_keys() | decision_needs <= set(order)
            assert not {"rejectedAt", "rejectedByUid", "rejectedByName", "rejectedByRole", "serverPriceCheck"} & set(order)
            assert (order["approvedByUid"], order["approvedByName"], order["approvedByRole"]) == (admin.uid, admin.name, "admin")
            submitted, approved = order["submittedAt"], order["approvedAt"]
            assert submitted < approved == order["updatedAt"] <= now and approved - submitted < timedelta(hours=12)
            assert approved.astimezone(ASIA_KUCHING).date() == submitted.astimezone(ASIA_KUCHING).date()
            purchase_order = run.documents["purchase_orders"][doc_id]
            assert set(purchase_order) == purchase_order_keys | {"simulationBatchId"}
            number = purchase_order["poNumber"]
            assert number_rule.fullmatch(number)
            assert number == f"PO-{approved.astimezone(ASIA_KUCHING):%Y%m%d}-{re.sub(r'[^A-Za-z0-9_.-]', '-', doc_id)[-24:]}"
            numbers[number] += 1
            assert purchase_order["orderId"] == doc_id and purchase_order["status"] == "issued"
            assert purchase_order["issuedAt"] == approved
            assert (purchase_order["issuedByUid"], purchase_order["issuedByRole"]) == (admin.uid, "admin")
            assert "lines" not in purchase_order and purchase_order["totalPrice"] == order["totalPrice"]
            for key in ("retailerId", "retailerName", "salesmanCode", "salesmanUid", "branchId"):
                assert purchase_order[key] == order[key] and isinstance(order[key], str) and order[key]
        assert set(numbers.values()) == {1}


def test_a_purchase_order_number_that_is_already_in_use_and_another_batch_are_refused():
    run = simulation(7)
    doc_id, planned = next(iter(run.documents["purchase_orders"].items()))
    body = collections()
    body["purchase_orders"] = {"REAL-ORDER": {"poNumber": planned["poNumber"], "orderId": "REAL-ORDER", "status": "issued"}}
    with pytest.raises(SimulationError, match="1 purchase order numbers are already in use"):
        verify(company_from_collections("alljoys-fixture", body), run, now=NOW)
    body["purchase_orders"] = {"REAL-ORDER": {"poNumber": "PO-20261001-REAL-ORDER", "orderId": "REAL-ORDER", "status": "issued"}}
    verify(company_from_collections("alljoys-fixture", body), run, now=NOW)
    body["purchase_orders"] = {doc_id: {**planned, "simulationBatchId": "sim-other"}}
    data = company_from_collections("alljoys-fixture", body)
    with pytest.raises(SimulationError, match="another simulated batch"):
        simulate(data, resolve_team(data, ROSTER), Settings(first_cutoff=FIRST, cutoff=FIRST, seed=7), now=NOW)


def test_the_write_touches_no_counter_and_only_the_order_and_purchase_order_collections():
    planned = cli.planned_documents(simulation(7), "orders")
    assert {path.split("/", 1)[0] for path in planned} == {"orders", "purchase_orders"}
    paths = list(planned)
    for index in range(0, len(paths), 2):
        order_id = paths[index].split("/", 1)[1]
        assert paths[index:index + 2] == [f"orders/{order_id}", f"purchase_orders/{order_id}"]


def test_an_approver_who_cannot_approve_is_refused():
    for change in ({"status": "inactive"}, {"status": "suspended"}):
        body = collections()
        for name in ("users", "user_access"):
            body[name]["u-admin"].update(change)
        data = company_from_collections("alljoys-fixture", body)
        with pytest.raises(SimulationError, match="must be an active admin"):
            simulate(data, resolve_team(data, ROSTER), Settings(first_cutoff=FIRST, cutoff=FIRST, seed=7), now=NOW)
    with pytest.raises(SimulationError, match="must be an admin"):
        resolve_team(company(), {**ROSTER, "routeAuthor": "sup-c"})


def test_approved_orders_do_not_wait_for_approval_and_count_as_demand_like_submitted_ones():
    statuses = (ROOT / "admin_dashboard" / "lib" / "utils" / "order_waiting_statuses.dart").read_text(encoding="utf-8")
    waiting = _names(re.search(r"kWaitingForApprovalStatuses = <String>\{(.*?)\};", statuses, re.S).group(1))
    assert "kWaitingForApprovalStatuses" in REPOSITORY
    assert "submitted" in waiting and "approved" not in waiting
    utils = (ROOT / "admin_dashboard" / "lib" / "utils" / "order_data_utils.dart").read_text(encoding="utf-8")
    pending = re.search(r"bool isPendingApprovalOrder\(.*?\n\}", utils, re.S).group(0)
    counted = re.search(r"bool isSubmittedOrApprovedOrder\(.*?\n\}", utils, re.S).group(0)
    assert "'submitted'" in pending and "'approved'" not in pending and "'approved'" in counted
    assert not {"approved", "submitted"} & NON_DEMAND_ORDER_STATUSES
    run = simulation(7)
    as_submitted = {
        **run.documents,
        "orders": {doc_id: {**order, "status": "submitted"} for doc_id, order in run.documents["orders"].items()},
    }
    approved = run_pipeline(company(), run.shops, run.documents, FIRST, 8)
    submitted = run_pipeline(company(), run.shops, as_submitted, FIRST, 8)
    assert approved.priority_rankings == submitted.priority_rankings and approved.insights == submitted.insights
    assert stopped_pairs(approved) == {run.story.stops[0]}


class PhoneOrderStore(MemoryStore):
    def create(self, path, data):
        if not self.documents.get("orders/PHONE-1") and path.startswith("purchase_orders/"):
            self.documents["orders/PHONE-1"] = ({"orderId": "PHONE-1"}, next(self.ticks))
        return super().create(path, data)


def test_the_order_limit_counts_orders_only_and_reports_the_count_after_the_write(tmp_path):
    run = simulation(7)
    orders = len(run.documents["orders"])
    store = MemoryStore({f"orders/REAL-{index}": {} for index in range(900 - orders)})
    done = _apply(store, run, tmp_path / "a.json.journal")
    assert done["counts"]["written"] == 2 * orders and store.order_count() == 900
    assert done["orderLimit"] == {
        "limit": 900, "ordersBefore": 900 - orders, "ordersAfter": 900, "overLimitBy": 0, "note": cli.ORDER_LIMIT_NOTE,
    }
    assert "another journal" in cli.ORDER_LIMIT_NOTE and "phone" in cli.ORDER_LIMIT_NOTE
    racing = PhoneOrderStore({f"orders/REAL-{index}": {} for index in range(900 - orders)})
    done = _apply(racing, run, tmp_path / "b.json.journal")
    assert done["orderLimit"]["ordersBefore"] == 900 - orders
    assert done["orderLimit"]["ordersAfter"] == 901 and done["orderLimit"]["overLimitBy"] == 1
    assert "orderLimit" not in _apply(MemoryStore(), run, tmp_path / "c.json.journal", name="routes")


def test_the_purchase_order_page_loads_one_week_and_the_busiest_week_is_reported():
    page_read = REPOSITORY[REPOSITORY.index("watchPurchaseOrders({"):REPOSITORY.index("watchLatestPurchaseOrderIssuedAt({")]
    assert "required DateTime from," in page_read and "required DateTime before," in page_read
    assert "isLessThan: Timestamp.fromDate(before)" in page_read and ".limit(" not in page_read
    run = simulation(7)
    weeks = Counter(week_start(row["issuedAt"]) for row in run.documents["purchase_orders"].values())
    busiest = max(weeks, key=lambda monday: (weeks[monday], monday))
    assert purchase_order_busiest_week(company(), run) == {
        "weekStart": busiest.isoformat(), "simulated": weeks[busiest], "existingInExport": None,
        "simulatedInAllWeeks": len(run.documents["orders"]),
    }
    quiet = min(weeks, key=lambda monday: (weeks[monday], monday))
    assert weeks[quiet] < weeks[busiest] and 0 < weeks[busiest] < len(run.documents["orders"])
    body = collections()
    body["purchase_orders"] = {
        f"OLD-PO-{index}": {"poNumber": f"PO-20260101-OLD-{index}", "issuedAt": _moment(quiet + timedelta(days=1), 10)}
        for index in range(412)
    }
    body["purchase_orders"]["NO-DATE"] = {"poNumber": "PO-20260101-NO-DATE"}
    assert purchase_order_busiest_week(company_from_collections("alljoys-fixture", body), run) == {
        "weekStart": quiet.isoformat(), "simulated": weeks[quiet], "existingInExport": 412,
        "simulatedInAllWeeks": len(run.documents["orders"]),
    }


def test_a_crash_between_an_order_and_its_purchase_order_is_completed_on_resume(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    for fail_on in (2,):
        store = FailingStore(fail_on=fail_on)
        with pytest.raises(ConnectionError):
            _apply(store, run, journal)
        assert len(_order_ids(store)) == fail_on - 1 and len(_purchase_order_ids(store)) == fail_on - 2
        store.fail_on = 0
        _apply(store, run, journal)
        assert _order_ids(store) == _purchase_order_ids(store) == set(run.documents["orders"])
        journal.unlink()


def test_an_order_or_purchase_order_that_exists_with_other_content_holds_back_its_partners(tmp_path):
    run = simulation(7)
    planned = cli.planned_documents(run, "orders")
    order_id = next(iter(run.documents["orders"]))
    for taken in (f"orders/{order_id}", f"purchase_orders/{order_id}"):
        store = MemoryStore({taken: {"status": "issued", "orderId": "someone-else"}})
        done = _apply(store, run, tmp_path / f"{taken.split('/')[0]}.json.journal")
        assert done["counts"] == {"written": len(planned) - 2, "exists_same": 0, "exists_different": 1, "held_back": 1}
        assert {path for path in store.documents if cli.order_group(path) == order_id} == {taken}
        assert _order_ids(store) - {order_id} == _purchase_order_ids(store) - {order_id}
        assert store.documents[taken][0] == {"status": "issued", "orderId": "someone-else"}
        _undo(store, done)
        assert list(store.documents) == [taken]


def test_undo_keeps_an_approved_order_whose_purchase_order_a_person_changed(tmp_path):
    run = simulation(7)
    store = MemoryStore()
    done = _apply(store, run, tmp_path / "a.json.journal")
    order_id = sorted(run.documents["orders"])[5]
    fulfilled = f"purchase_orders/{order_id}"
    store.change(fulfilled, status="fulfilled", statusChangedByUid="u-admin")
    report = _undo(store, done)
    kept = [f"orders/{order_id}"]
    assert report["skippedChanged"] == [fulfilled] and report["keptWithChangedPartner"] == kept
    assert sorted(store.documents) == sorted([fulfilled, *kept]) and len(report["deleted"]) == len(done["documents"]) - 2
    again = _undo(store, done)
    assert again["deleted"] == [] and sorted(store.documents) == sorted([fulfilled, *kept])
    gone = MemoryStore()
    done = _apply(gone, run, tmp_path / "b.json.journal")
    del gone.documents[fulfilled]
    report = _undo(gone, done)
    assert report["skippedChanged"] == [] and report["alreadyGone"] == [fulfilled] and report["keptWithChangedPartner"] == [] and not gone.documents
    assert not any(report.get(key) for key in cli.UNDO_KEPT_BACK)


def _group(order_id: str) -> list[str]:
    return list(cli.group_paths(f"orders/{order_id}"))


def _strip_run_id(store, path):
    data, _ = store.documents[path]
    store.documents[path] = ({key: value for key, value in data.items() if key != cli.WRITE_ID_FIELD}, next(store.ticks))


def _held(report) -> dict[str, dict[str, str]]:
    return {
        held["group"]: {member["path"]: member["state"] for member in held["members"]}
        for held in report["heldGroups"]
    }


@pytest.fixture(scope="module")
def full_write(tmp_path_factory):
    run = simulation(7)
    store = MemoryStore()
    done = json.loads(json.dumps(_apply(store, run, tmp_path_factory.mktemp("full") / "full.json.journal")))
    return run, store, done


class RacingStore(MemoryStore):
    def __init__(self, source, during_undo):
        super().__init__()
        self.documents = dict(source.documents)
        self.ticks = _copy(source).ticks
        self.during_undo = during_undo

    def delete_group(self, expected):
        self.during_undo(self, expected)
        return super().delete_group(expected)


@pytest.mark.parametrize("member", (0, 1))
@pytest.mark.parametrize("event", ("changed", "replaced", "deleted"))
def test_undo_deletes_nothing_of_a_group_that_changes_between_its_read_and_its_delete(full_write, member, event):
    run, source, done = full_write
    target = _group(sorted(run.documents["orders"])[4])
    hit = target[member]

    def interfere(store, expected):
        if hit not in expected or getattr(store, "fired", False):
            return
        store.fired = True
        if event == "changed":
            store.change(hit, status="rejected")
        elif event == "replaced":
            _strip_run_id(store, hit)
        else:
            del store.documents[hit]

    store = RacingStore(source, interfere)
    report = _undo(store, done)
    left = [path for path in target if path != hit or event != "deleted"]
    assert sorted(store.documents) == sorted(left)
    assert report["changedDuringUndo"] == sorted(target) and list(_held(report)) == [cli.order_group(hit)]
    assert len(target) == 2 and len(report["deleted"]) == len(done["documents"]) - 2 and not set(report["deleted"]) & set(target)


def test_undo_deletes_nothing_of_a_group_whose_missing_partner_appears_between_the_read_and_the_delete(tmp_path):
    run = simulation(7)
    crashed = FailingStore(fail_on=2)
    with pytest.raises(ConnectionError):
        _apply(crashed, run, tmp_path / "m.json.journal")
    order = next(iter(crashed.documents))
    partner = cli.group_paths(order)[1]
    assert order.startswith("orders/") and partner == "purchase_orders/" + order.split("/", 1)[1]
    store = RacingStore(crashed, lambda racing, expected: racing.documents.setdefault(partner, ({"action": "approved"}, 1)))
    report = _undo(store, cli.manifest_from_journal(tmp_path / "m.json.journal"))
    assert report["deleted"] == [] and report["changedDuringUndo"] == [order]
    assert sorted(store.documents) == sorted([order, partner])


@pytest.mark.parametrize("fail_on", (2,))
@pytest.mark.parametrize("event", ("changed", "replaced"))
def test_a_resume_does_not_complete_a_group_whose_existing_member_changed_after_the_crash(tmp_path, fail_on, event):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = FailingStore(fail_on=fail_on)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    order = next(path for path in store.documents if path.startswith("orders/"))
    present = sorted(store.documents)
    assert len(present) == fail_on - 1
    if event == "changed":
        store.change(order, status="rejected", rejectedByUid="u-admin")
    else:
        _strip_run_id(store, order)
    store.fail_on = 0
    resumed = _apply(store, run, journal)
    group = cli.order_group(order)
    assert sorted(path for path in store.documents if cli.order_group(path) == group) == present
    rows = {row["path"]: row["status"] for row in resumed["documents"]}
    missing = [path for path in cli.group_paths(order) if path not in present]
    assert missing and all(rows[path] == "held_back" for path in missing)
    state = cli.REPLACED_REASON if event == "changed" else "not owned by this run, same content"
    assert _held(resumed) == {group: {order: state}}
    assert rows[order] == (cli.CHECK_BY_HAND if event == "changed" else "exists_same")
    assert resumed["counts"]["written"] + len(missing) + 1 == len(resumed["documents"])
    again = _apply(store, run, journal)
    assert sorted(path for path in store.documents if cli.order_group(path) == group) == present
    assert _held(again) == _held(resumed)
    report = _undo(store, again)
    assert sorted(store.documents) == present and not set(report["deleted"]) & set(present)
    assert report["checkByHand"] == ([order] if event == "changed" else [])


def test_a_resume_does_not_claim_an_order_another_writer_replaced_with_identical_content(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    store = FailingStore(fail_on=2)
    with pytest.raises(ConnectionError):
        _apply(store, run, journal)
    [order] = sorted(store.documents)
    partner = cli.group_paths(order)[1]
    assert order.startswith("orders/") and partner.startswith("purchase_orders/")
    body, _ = store.documents[order]
    store.documents[order] = (dict(body), next(store.ticks))
    store.fail_on = 0
    resumed = _apply(store, run, journal)
    rows = {row["path"]: row["status"] for row in resumed["documents"]}
    assert rows[order] == cli.CHECK_BY_HAND and rows[partner] == "held_back"
    assert partner not in store.documents and store.documents[order][0] == body
    assert _held(resumed) == {cli.order_group(order): {order: cli.REPLACED_REASON}}
    assert resumed["counts"][cli.CHECK_BY_HAND] == 1 and resumed["counts"]["held_back"] == 1
    rebuilt = cli.manifest_from_journal(journal)
    assert {row["path"]: row["status"] for row in rebuilt["documents"]}[order] == cli.CHECK_BY_HAND
    again = _apply(store, run, journal)
    assert partner not in store.documents and {row["path"]: row["status"] for row in again["documents"]}[order] == cli.CHECK_BY_HAND
    report = _undo(store, again)
    assert order not in report["deleted"] and report["checkByHand"] == [order]
    assert store.documents[order][0] == body and partner not in store.documents


@pytest.mark.parametrize("member", (0, 1))
@pytest.mark.parametrize("identical", (True, False))
def test_a_member_that_exists_and_is_not_owned_holds_its_whole_group_on_apply_and_on_undo(tmp_path, member, identical):
    run = simulation(7)
    planned = cli.planned_documents(run, "orders")
    target = _group(sorted(run.documents["orders"])[2])
    taken = target[member]
    foreign = {**planned[taken], cli.WRITE_ID_FIELD: "another-run"} if identical else {"note": "made by a person"}
    store = MemoryStore({taken: foreign})
    done = _apply(store, run, tmp_path / "m.json.journal")
    assert [path for path in store.documents if path in target] == [taken] and store.documents[taken][0] == foreign
    assert len(target) == 2 and done["counts"]["held_back"] == 1 and done["counts"]["written"] == len(planned) - 2
    assert done["counts"]["exists_same" if identical else "exists_different"] == 1
    content = "same content" if identical else "other content"
    assert _held(done) == {cli.order_group(taken): {taken: f"not owned by this run, {content}"}}
    report = _undo(store, done)
    assert list(store.documents) == [taken] and store.documents[taken][0] == foreign
    assert len(report["deleted"]) == len(planned) - 2


@pytest.mark.parametrize("member", (0, 1))
@pytest.mark.parametrize("event", ("changed", "replaced", "replaced_identical"))
def test_undo_deletes_nothing_of_a_group_with_a_changed_or_not_owned_member(full_write, member, event):
    run, source, done = full_write
    store = _copy(source)
    target = _group(sorted(run.documents["orders"])[7])
    hit = target[member]
    if event == "changed":
        store.change(hit, summary="Edited by a person")
    elif event == "replaced":
        store.documents[hit] = ({"note": "made by a person"}, next(store.ticks))
    else:
        data, tick = store.documents[hit]
        store.documents[hit] = ({**data, cli.WRITE_ID_FIELD: "another-run"}, tick)
    before = {path: store.documents[path] for path in target}
    report = _undo(store, done)
    assert store.documents == before
    assert report["keptWithChangedPartner"] == sorted(path for path in target if path != hit)
    assert report["skippedChanged" if event == "changed" else "existsNotOwned"] == [hit]
    state = "created by this run and changed since" if event == "changed" else "not owned by this run"
    assert _held(report) == {cli.order_group(hit): {hit: state}}
    again = _undo(store, done)
    assert again["deleted"] == [] and store.documents == before


class UndoCrashStore(MemoryStore):
    def __init__(self, source, fail_on):
        super().__init__()
        self.documents = dict(source.documents)
        self.ticks = _copy(source).ticks
        self.fail_on = fail_on
        self.calls = 0

    def delete_group(self, expected):
        self.calls += 1
        if self.calls == self.fail_on:
            raise ConnectionError("network down")
        return super().delete_group(expected)


def _half_groups(store, run) -> list[str]:
    return [
        order_id for order_id in run.documents["orders"]
        if 0 < sum(1 for path in _group(order_id) if path in store.documents) < 2
    ]


def test_a_crash_inside_undo_leaves_whole_groups_and_a_resume_or_a_second_undo_never_makes_half_a_group(tmp_path):
    run = simulation(7)
    journal = tmp_path / "m.json.journal"
    first = MemoryStore()
    done = json.loads(json.dumps(_apply(first, run, journal)))
    store = UndoCrashStore(first, fail_on=3)
    with pytest.raises(ConnectionError):
        cli.undo_manifest(store, done)
    orders = len(run.documents["orders"])
    assert _half_groups(store, run) == [] and len(store.documents) == 2 * (orders - 2)
    undone = {path for path in done_paths(done) if path not in store.documents}
    resumed = _apply(store, run, journal)
    rows = {row["path"]: row["status"] for row in resumed["documents"]}
    assert {path for path, status in rows.items() if status == "deleted"} == undone
    assert resumed["counts"]["written"] == 2 * (orders - 2) and len(store.documents) == 2 * (orders - 2)
    assert _half_groups(store, run) == [] and len(_held(resumed)) == 2
    store.fail_on = 0
    report = _undo(store, resumed)
    assert len(report["deleted"]) == 2 * (orders - 2) and not store.documents
    for manifest in (done, resumed):
        again = _undo(store, manifest)
        assert again["deleted"] == [] and again["changedDuringUndo"] == [] and not store.documents
    after_undo = _apply(store, run, journal)
    assert not store.documents and after_undo["counts"]["written"] == 0 and after_undo["counts"]["deleted"] == 2 * orders


def done_paths(manifest) -> list[str]:
    return [row["path"] for row in manifest["documents"]]


def test_a_top_up_week_reports_a_changed_earlier_group_and_undo_keeps_that_group_whole(tmp_path):
    run, later = simulation(7), simulation(7, 1)
    journal = tmp_path / "m.json.journal"
    store = MemoryStore()
    _apply(store, run, journal)
    target = _group(sorted(run.documents["orders"])[1])
    store.change(target[1], status="fulfilled")
    top_up = cli.apply_manifest(
        store, later, "orders", "alljoys-fixture", now=NOW + timedelta(weeks=1), order_limit=900, journal=journal,
    )
    planned = cli.planned_documents(later, "orders")
    assert set(store.documents) == set(planned) and top_up["counts"]["written"] == len(planned) - 1
    assert top_up["counts"][cli.CHECK_BY_HAND] == 1
    assert _held(top_up) == {cli.order_group(target[0]): {target[1]: cli.REPLACED_REASON}}
    report = _undo(store, top_up)
    assert sorted(store.documents) == sorted(target) and len(target) == 2 and len(report["deleted"]) == len(planned) - 2
    assert store.documents[target[1]][0]["status"] == "fulfilled"


def test_a_journal_and_a_manifest_with_no_group_information_still_keep_groups_whole(tmp_path, full_write):
    run, source, done = full_write
    old = {key: value for key, value in done.items() if key not in ("heldGroups", "orderLimit")}
    store = _copy(source)
    target = _group(sorted(run.documents["orders"])[6])
    store.change(target[1], summary="Edited by a person")
    _undo(store, old)
    assert sorted(store.documents) == sorted(target) and target[1].startswith("purchase_orders/")
    journal = tmp_path / "old.json.journal"
    crashed = FailingStore(fail_on=2)
    with pytest.raises(ConnectionError):
        _apply(crashed, run, journal)
    assert {json.loads(line)["t"] for line in journal.read_text(encoding="utf-8").splitlines()} == {"header", "intent", "done"}
    order = next(iter(crashed.documents))
    partner = cli.group_paths(order)[1]
    crashed.documents[partner] = ({"poNumber": "PO-REAL", "status": "issued"}, 1)
    rebuilt = cli.manifest_from_journal(journal)
    assert done_paths(rebuilt) == [order, partner] and rebuilt["counts"] == {"written": 1, "pending": 1, cli.CHECK_BY_HAND: 0}
    report = _undo(crashed, rebuilt)
    assert report["deleted"] == [] and report["existsNotOwned"] == [partner]
    assert report["keptWithChangedPartner"] == [order] and sorted(crashed.documents) == sorted([order, partner])
    crashed.fail_on = 0
    resumed = _apply(crashed, run, journal)
    assert crashed.documents[partner][0] == {"poNumber": "PO-REAL", "status": "issued"}
    assert _held(resumed) == {cli.order_group(order): {partner: "not owned by this run, other content"}}


def test_undo_after_any_mix_of_changes_keeps_every_touched_group_whole_and_deletes_only_owned_records(full_write):
    run, source, done = full_write
    run_id = done["runId"]
    order_ids = sorted(run.documents["orders"])
    for trial in range(40):
        picker = random.Random(trial)
        store = _copy(source)
        blocked: set[str] = set()
        for order_id in picker.sample(order_ids, 12):
            path = picker.choice(_group(order_id))
            event = picker.choice(("changed", "replaced", "identical", "deleted"))
            if event == "changed":
                store.change(path, note="edited")
            elif event == "replaced":
                store.documents[path] = ({"note": "made by a person"}, next(store.ticks))
            elif event == "identical":
                _strip_run_id(store, path)
            else:
                del store.documents[path]
            if event != "deleted":
                blocked.add(order_id)
        before = dict(store.documents)
        report = _undo(store, done)
        assert set(store.documents) == {path for order_id in blocked for path in _group(order_id) if path in before}
        assert all(store.documents[path] == before[path] for path in store.documents)
        assert all(before[path][0].get(cli.WRITE_ID_FIELD) == run_id for path in report["deleted"])
        assert set(_held(report)) == blocked

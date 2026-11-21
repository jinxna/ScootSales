from __future__ import annotations

import hashlib
import math
import random
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Mapping

from forecasting.ai_core.calendar import ASIA_KUCHING, HistoryWindow, week_start
from forecasting.ai_core.insights import issue_id, issue_key
from forecasting.ai_service.generator import build_generation
from forecasting.ai_service.normalization import is_demo_record, normalize_firestore_inputs
from forecasting.ai_service.outcome_feedback import normalize_outcomes
from forecasting.ai_service.visit_briefs import _brief_id

from .inputs import (
    MAX_LINE_QUANTITY,
    Company,
    Person,
    SimulationError,
    Team,
    assign_areas,
    canonical,
    catalogue_price,
    encoded_name,
    orderable_products,
    price_sen,
    product_name,
    shop_coordinates,
    shop_id,
    shop_name,
    shop_unit_price,
    simulated_shops,
    text,
)
from .staff_plan import LEGACY_ASSIGNMENT_FIELDS

WEEKDAY_LABELS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
STOP_ID_LIMIT = 51
NO_ORDER_REASONS = (
    "retailer_busy",
    "decision_maker_unavailable",
    "cash_flow_issue",
    "low_sell_through",
    "seasonal_change",
)
RECOVERY_REASON = "shelf_space_limited"
RECOVERY_STOP_WEEKS_BACK = (6, 5, 4)
RECOVERY_VISIT_WEEKS_BACK = 4
BOOST_LIMIT = 12
BOOST_LINES = 2
ORDER_LINE_LIMIT = 25
LARGEST_SIMULATED_LINE_QUANTITY = 5
PHONE_DEFAULT_LINE_QUANTITY = 5
FIX_PASSES = 3
SLOT_MINUTES = 40
SERVICE_MINUTES = 25
PUBLISH_MINUTE = 7 * 60 + 30
SIMULATED_NOTE = "Simulated visit: no location was recorded."
APPROVAL_COLLECTIONS = ("purchase_orders",)
ROUTE_COLLECTIONS = ("route_plan_publication_keys", "route_plans", "route_plan_progress", "route_stop_progress")
CREATED_COLLECTIONS = ("orders", *APPROVAL_COLLECTIONS, "conversation_outcomes", *ROUTE_COLLECTIONS)
APPROVER_ROLES = ("admin", "developer")
APPROVAL_FIRST_MINUTE = 16 * 60 + 30
APPROVAL_MINUTE_SPREAD = 60
PURCHASE_ORDER_ID_TAIL = 24
NOT_ROSTER_RANKING = "skipped: not a roster salesperson"


@dataclass(frozen=True)
class Settings:
    first_cutoff: date
    cutoff: date
    seed: int = 7
    batch_id: str = ""
    history_weeks: int = 24
    visit_weeks: int = 8
    window_weeks: int = 8
    planned_cutoffs: int = 3
    shops_per_salesperson: int = 5
    skip_rate: float = 0.1
    line_rate: float = 0.95
    size_sigma: float = 0.6
    size_link: float = 0.8
    order_limit: int = 900

    @property
    def batch(self) -> str:
        return self.batch_id or f"sim-{self.first_cutoff:%Y%m%d}-{self.seed}"

    @property
    def cutoffs(self) -> tuple[date, ...]:
        return tuple(self.first_cutoff + timedelta(weeks=index) for index in range(self.planned_cutoffs))

    @property
    def first_week(self) -> date:
        return self.first_cutoff - timedelta(weeks=self.history_weeks)

    @property
    def first_visit_week(self) -> date:
        return self.first_cutoff - timedelta(weeks=self.visit_weeks)


@dataclass(frozen=True)
class ShopPlan:
    shop_id: str
    row: Mapping[str, Any]
    person: Person
    cadence: int
    phase: int
    weekday: int
    size: float
    basket: tuple[tuple[str, int], ...]


@dataclass(frozen=True)
class Story:
    stops: tuple[tuple[str, str], ...]
    recovered: tuple[str, str]


@dataclass
class Simulation:
    settings: Settings
    team: Team
    story: Story
    shops: dict[str, ShopPlan]
    boosts: dict[str, int]
    documents: dict[str, dict[str, dict[str, Any]]]
    checks: list[dict[str, Any]] = field(default_factory=list)

    def rows(self, collection: str) -> list[dict[str, Any]]:
        return [{"docId": doc_id, **data} for doc_id, data in sorted(self.documents[collection].items())]


def _rng(*parts: Any) -> random.Random:
    digest = hashlib.sha256("|".join(str(part) for part in parts).encode("utf-8")).digest()
    return random.Random(int.from_bytes(digest[:8], "big"))


def _slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", value).strip("-") or "x"


def _local(day: date, minutes: int) -> datetime:
    moment = datetime.combine(day, time(0, 0), tzinfo=ASIA_KUCHING) + timedelta(minutes=minutes)
    return moment.astimezone(timezone.utc)


def _clock(minutes: int) -> str:
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def route_plan_id(batch: str, code: str, week: date) -> str:
    return f"SIM-{batch}-{_slug(code)}-{week:%Y%m%d}"


def publication_key_id(identity: str, week: date) -> str:
    return f"{re.sub(r'[^A-Za-z0-9_-]', '_', identity)}_{week:%Y%m%d}"


def route_weeks(settings: Settings, now: datetime) -> tuple[date, ...]:
    end = min(settings.cutoff, week_start(now))
    count = max(0, (end - settings.first_visit_week).days // 7)
    return tuple(settings.first_visit_week + timedelta(weeks=index) for index in range(count))


def purchase_order_number(order_id: str, approved: datetime) -> str:
    clean = re.sub(r"[^A-Za-z0-9_.-]", "-", order_id)
    return f"PO-{approved.astimezone(ASIA_KUCHING):%Y%m%d}-{clean[-PURCHASE_ORDER_ID_TAIL:]}"


def _approval(
    settings: Settings, approver: Person, order_id: str, order: dict[str, Any], day: date,
) -> dict[str, Any]:
    minute = APPROVAL_FIRST_MINUTE + _rng(settings.seed, "approval", order_id).randrange(APPROVAL_MINUTE_SPREAD)
    approved = _local(day, minute)
    order.update({
        "status": "approved",
        "approvedAt": approved,
        "updatedAt": approved,
        "approvedByUid": approver.uid,
        "approvedByName": approver.name,
        "approvedByRole": approver.role,
    })
    return {
        "poNumber": purchase_order_number(order_id, approved),
        "orderId": order_id,
        "retailerId": order["retailerId"],
        "retailerName": order["retailerName"],
        "salesmanCode": order["salesmanCode"],
        "salesmanUid": order["salesmanUid"],
        "branchId": order["branchId"],
        "totalPrice": order["totalPrice"],
        "status": "issued",
        "issuedAt": approved,
        "issuedByUid": approver.uid,
        "issuedByRole": approver.role,
        "simulationBatchId": settings.batch,
    }


def _check_settings(settings: Settings, team: Team) -> None:
    if settings.first_cutoff.weekday() != 0 or settings.cutoff.weekday() != 0:
        raise SimulationError("The first cut-off and the cut-off must be Mondays.")
    if settings.cutoff not in settings.cutoffs:
        raise SimulationError(
            f"The cut-off must be one of the {settings.planned_cutoffs} planned Mondays from the first cut-off."
        )
    if len(team.salespeople) <= settings.planned_cutoffs:
        raise SimulationError("The story needs one more salesperson than planned cut-offs.")
    if settings.visit_weeks < RECOVERY_VISIT_WEEKS_BACK or settings.visit_weeks > settings.history_weeks:
        raise SimulationError("The visit history must cover the recovery visit and fit in the order history.")
    if settings.window_weeks < max(RECOVERY_STOP_WEEKS_BACK) + 2 or settings.history_weeks < settings.window_weeks:
        raise SimulationError("The history window is too short for the story.")
    if team.author.role not in APPROVER_ROLES or canonical(team.author.status) != "active":
        raise SimulationError(
            "The route author of the roster file approves the simulated orders. That person must be an active admin."
        )
    if is_demo_record({"docId": settings.batch, "planId": settings.batch}):
        raise SimulationError("The batch id would mark the records as demo data.")


def _plan_shops(company: Company, team: Team, settings: Settings) -> tuple[dict[str, ShopPlan], Story]:
    rows = simulated_shops(company, team, settings.shops_per_salesperson)
    products = [text(product, "docId") for product in orderable_products(company)]
    if len(products) < 8:
        raise SimulationError(f"Only {len(products)} products have a usable id, name and catalogue price. 8 are needed.")
    owners = assign_areas(rows, team)
    ids = sorted(shop_id(row) for row in rows)
    size = {key: math.exp(_rng(settings.seed, "size", key).gauss(0, settings.size_sigma)) for key in ids}
    story_shops = [
        max((key for key in ids if owners[key].uid == person.uid), key=lambda key: (size[key], key))
        for person in team.salespeople[: settings.planned_cutoffs + 1]
    ]
    others = [key for key in ids if key not in story_shops]
    by_size = sorted(others, key=lambda key: (-size[key], key))
    size_rank = {key: position / max(1, len(others) - 1) for position, key in enumerate(by_size)}
    order = sorted(
        others,
        key=lambda key: (
            settings.size_link * size_rank[key]
            + (1 - settings.size_link) * _rng(settings.seed, "noise", key).random(),
            key,
        ),
    )
    weekly = max(0, round(len(ids) * 0.3) - len(story_shops))
    fortnightly = round(len(ids) * 0.4)
    cadence = {key: 1 for key in story_shops}
    for position, key in enumerate(order):
        cadence[key] = 1 if position < weekly else 2 if position < weekly + fortnightly else 4
    by_id = {shop_id(row): row for row in rows}
    bought = {
        (text(order, "retailerId", "retailer_id", "retailerCode"), text(item, "productId", "itemId", "productCode", "sku"))
        for order in company.orders
        if not order.get("simulationBatchId") and isinstance(order.get("items"), list)
        for item in order["items"]
        if isinstance(item, Mapping)
    }
    shops: dict[str, ShopPlan] = {}
    for key in ids:
        picker = _rng(settings.seed, "basket", key)
        picks = picker.sample(products, picker.randint(4, 8))
        basket = [
            (product, min(LARGEST_SIMULATED_LINE_QUANTITY, max(1, round(picker.choice([1, 2, 2, 3, 4]) * size[key]))))
            for product in picks
        ]
        if key in story_shops:
            fresh = [entry for entry in basket if (key, entry[0]) not in bought]
            if not fresh:
                raise SimulationError(f"The story shop {key} already bought every product of its basket. Change the seed.")
            basket.remove(fresh[0])
            basket.insert(0, (fresh[0][0], 4))
        shops[key] = ShopPlan(
            shop_id=key,
            row=by_id[key],
            person=owners[key],
            cadence=cadence[key],
            phase=_rng(settings.seed, "phase", key).randrange(cadence[key]),
            weekday=_rng(settings.seed, "weekday", key).randrange(len(WEEKDAY_LABELS)),
            size=size[key],
            basket=tuple(basket),
        )
    planted = [(key, shops[key].basket[0][0]) for key in story_shops]
    return shops, Story(stops=tuple(planted[:-1]), recovered=planted[-1])


def _forced(settings: Settings, story: Story, shop: str, product: str, week: date) -> bool | None:
    for cutoff, (planted_shop, planted_product) in zip(settings.cutoffs, story.stops):
        if (shop, product) == (planted_shop, planted_product):
            return week not in (cutoff - timedelta(weeks=2), cutoff - timedelta(weeks=1))
    if (shop, product) == story.recovered:
        return week not in {settings.first_cutoff - timedelta(weeks=back) for back in RECOVERY_STOP_WEEKS_BACK}
    return None


def _phone_quantity_limit(product: Mapping[str, Any]) -> int:
    stored = product.get("maxOrderQty")
    if isinstance(stored, int) and not isinstance(stored, bool) and stored >= 1:
        return min(stored, MAX_LINE_QUANTITY)
    return PHONE_DEFAULT_LINE_QUANTITY


def _quantity(product: Mapping[str, Any], wanted: int) -> int:
    return max(1, min(wanted, _phone_quantity_limit(product), LARGEST_SIMULATED_LINE_QUANTITY))


def _basket(settings: Settings, plan: ShopPlan, products: Mapping[str, Mapping[str, Any]], boost: int) -> tuple[tuple[str, int], ...]:
    if not boost:
        return plan.basket
    held = {product for product, _ in plan.basket}
    spare = sorted(product for product in products if product not in held)
    room = max(0, min(len(spare), BOOST_LINES * boost, ORDER_LINE_LIMIT - len(plan.basket)))
    extra = _rng(settings.seed, "extra", plan.shop_id).sample(spare, len(spare))[:room]
    return (*plan.basket, *((product, LARGEST_SIMULATED_LINE_QUANTITY) for product in extra))


def _base_lines(
    settings: Settings, story: Story, shops: Mapping[str, ShopPlan], products: Mapping[str, Mapping[str, Any]],
    boosts: Mapping[str, int],
) -> tuple[dict[tuple[str, date], dict[str, int]], dict[tuple[str, date], str]]:
    story_shops = {shop for shop, _ in story.stops} | {story.recovered[0]}
    lines: dict[tuple[str, date], dict[str, int]] = {}
    slots: dict[tuple[str, date], str] = {}
    week_count = settings.history_weeks + settings.planned_cutoffs - 1
    for key, plan in sorted(shops.items()):
        for index in range(week_count):
            week = settings.first_week + timedelta(weeks=index)
            if key not in story_shops:
                if (index + plan.phase) % plan.cadence != 0:
                    continue
                if _rng(settings.seed, "skip", key, week).random() < settings.skip_rate:
                    slots[(key, week)] = "no_order"
                    continue
            order: dict[str, int] = {}
            boost = boosts.get(key, 0)
            for product, base in _basket(settings, plan, products, boost):
                forced = _forced(settings, story, key, product, week)
                chance = _rng(settings.seed, "line", key, week, product)
                if forced is False or (forced is None and chance.random() > settings.line_rate):
                    continue
                order[product] = _quantity(products[product], round(base * chance.uniform(0.7, 1.3)) + boost)
            if order:
                lines[(key, week)] = order
                slots[(key, week)] = "order"
            else:
                slots[(key, week)] = "no_order"
    return lines, slots


def _stop_id(weekday: int, sequence: int, retailer: str) -> str:
    slug = re.sub(r"^_+|_+$", "", re.sub(r"[^a-z0-9]+", "_", retailer.lower())) or "retailer"
    prefix = f"{WEEKDAY_LABELS[weekday].lower()}_{sequence}_"
    if len(prefix) + len(slug) <= STOP_ID_LIMIT:
        return prefix + slug
    digest = hashlib.sha256((prefix + slug).encode("utf-8")).hexdigest()[:8]
    return f"{prefix}{slug[:max(1, STOP_ID_LIMIT - len(prefix) - len(digest) - 1)]}_{digest}"


def _order_items(
    company: Company, products: Mapping[str, Mapping[str, Any]], plan: ShopPlan, order: Mapping[str, int],
) -> tuple[list[dict[str, Any]], list[str], int]:
    sheet = company.sheets.get(plan.shop_id)
    items: list[dict[str, Any]] = []
    commercial: list[str] = []
    total_sen = 0
    for product_id, quantity in order.items():
        product = products[product_id]
        price = shop_unit_price(product, sheet)
        sen = price_sen(price)
        if sen is None:
            raise SimulationError(f"The product {product_id} has no usable price for the shop {plan.shop_id}.")
        name = product_name(product)
        department = text(product, "department", "departmentName")
        item: dict[str, Any] = {"name": name, "productName": name, "productId": product_id}
        if text(product, "barcode"):
            item["barcode"] = text(product, "barcode")
        item["packingSize"] = text(product, "packingSize", "packagingSize")
        if text(product, "uom"):
            item["uom"] = text(product, "uom")
        item.update({
            "maxOrderQty": _phone_quantity_limit(product),
            "price": price,
            "qty": quantity,
            "expiry": "",
            "department": department,
            "departmentName": department,
            "shelfBatches": [],
            "remarks": "",
        })
        items.append(item)
        commercial.append(f"{product_id}~{encoded_name(name)}~{quantity}~{sen}")
        total_sen += quantity * sen
    return items, commercial, total_sen


def _build_documents(
    company: Company, team: Team, settings: Settings, shops: Mapping[str, ShopPlan],
    products: Mapping[str, Mapping[str, Any]], story: Story,
    lines: Mapping[tuple[str, date], Mapping[str, int]], slots: Mapping[tuple[str, date], str], before: date,
) -> dict[str, dict[str, dict[str, Any]]]:
    documents: dict[str, dict[str, dict[str, Any]]] = {name: {} for name in CREATED_COLLECTIONS}
    batch = settings.batch
    recovery_week = settings.first_cutoff - timedelta(weeks=RECOVERY_VISIT_WEEKS_BACK)
    by_person_week: dict[tuple[str, date], list[ShopPlan]] = {}
    for (key, week), _ in sorted(slots.items()):
        if week < before:
            by_person_week.setdefault((shops[key].person.uid, week), []).append(shops[key])
    people = {person.uid: person for person in team.salespeople}
    for (uid, week), visited in sorted(by_person_week.items()):
        person = people[uid]
        supervisor = team.supervisor_of(uid)
        with_visits = week >= settings.first_visit_week
        plan_id = route_plan_id(batch, person.code, week)
        for weekday in range(len(WEEKDAY_LABELS)):
            day = week + timedelta(days=weekday)
            today = sorted((plan for plan in visited if plan.weekday == weekday), key=lambda plan: plan.shop_id)
            for sequence, plan in enumerate(today, 1):
                start = 9 * 60 + (sequence - 1) * SLOT_MINUTES
                ordered = _local(day, start + 18)
                stop = _stop_id(weekday, sequence, plan.shop_id)
                name = shop_name(plan.row)
                identity = {
                    "salesmanUid": uid,
                    "salesmanCode": person.code,
                    "branchId": person.branch_id,
                }
                if (plan.shop_id, week) in lines:
                    items, commercial, total_sen = _order_items(company, products, plan, lines[(plan.shop_id, week)])
                    order_id = f"SIM-{batch}-{_slug(plan.shop_id)}-{day:%Y%m%d}"
                    order: dict[str, Any] = {"orderId": order_id, "visitSource": "personal_planner"}
                    order.update({
                        "retailerId": plan.shop_id,
                        "retailerName": name,
                        "outlet": name,
                        "uid": uid,
                        "userUid": uid,
                        "salesmanUid": uid,
                        "salesmanEmail": person.email,
                        "salesmanId": person.code,
                        "salesmanCode": person.code,
                        "salesmanName": person.name,
                        "submittedByUid": uid,
                        "createdByUid": uid,
                        "branchId": person.branch_id,
                    })
                    if supervisor.code:
                        order["supervisorId"] = supervisor.code
                    order.update({
                        "totalProducts": len(items),
                        "totalBoxes": sum(item["qty"] for item in items),
                        "totalPrice": total_sen / 100,
                        "submittedAt": ordered,
                        "createdAt": ordered,
                        "items": items,
                        "commercialSchemaVersion": 1,
                        "commercialLines": commercial,
                        "signatureTimestamps": {},
                        "simulationBatchId": batch,
                    })
                    documents["orders"][order_id] = order
                    documents["purchase_orders"][order_id] = _approval(settings, team.author, order_id, order, day)
                if not with_visits:
                    continue
                outcome_base = {
                    "retailerId": plan.shop_id,
                    "retailerName": name,
                    **identity,
                    "planId": plan_id,
                    "stopId": stop,
                    "isDemo": False,
                    "clientCreatedAt": ordered,
                    "submittedAt": ordered,
                    "simulationBatchId": batch,
                }
                outcome_prefix = f"SIM-{batch}-{_slug(plan.shop_id)}-{day:%Y%m%d}"
                if slots[(plan.shop_id, week)] == "no_order":
                    outcome_id = f"{outcome_prefix}-no-order"
                    documents["conversation_outcomes"][outcome_id] = {
                        "outcomeId": outcome_id,
                        "outcomeKind": "no_order",
                        "reasonCode": _rng(settings.seed, "reason", plan.shop_id, week).choice(NO_ORDER_REASONS),
                        "note": "",
                        "source": "mobile_assigned_route_no_order",
                        **outcome_base,
                    }
                if (plan.shop_id, week) == (story.recovered[0], recovery_week):
                    product = story.recovered[1]
                    issue = issue_id("stopped_product", plan.shop_id, product)
                    outcome_id = f"{outcome_prefix}-stopped-product"
                    documents["conversation_outcomes"][outcome_id] = {
                        "outcomeId": outcome_id,
                        "issueId": issue,
                        "issueKey": issue_key("stopped_product", plan.shop_id, product),
                        "issueType": "stopped_product",
                        "productId": product,
                        "productName": product_name(products[product]),
                        "sourceBriefId": _brief_id(plan.shop_id),
                        "reasonCode": RECOVERY_REASON,
                        "note": "",
                        "replacementProductId": "",
                        "source": "mobile_assigned_route_copilot",
                        **outcome_base,
                    }
    return documents


def _distance_km(a: tuple[float, float] | None, b: tuple[float, float] | None) -> float:
    if a is None or b is None:
        return 0.0
    lat1, lng1, lat2, lng2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return round(6371.0088 * 2 * math.asin(math.sqrt(h)), 3)


def _route_documents(
    team: Team, settings: Settings, shops: Mapping[str, ShopPlan], slots: Mapping[tuple[str, date], str], now: datetime,
) -> dict[str, dict[str, dict[str, Any]]]:
    documents: dict[str, dict[str, dict[str, Any]]] = {name: {} for name in ROUTE_COLLECTIONS}
    batch = settings.batch
    weeks = set(route_weeks(settings, now))
    by_person_week: dict[tuple[str, date], list[ShopPlan]] = {}
    for (key, week), _ in sorted(slots.items()):
        if week in weeks:
            by_person_week.setdefault((shops[key].person.uid, week), []).append(shops[key])
    people = {person.uid: person for person in team.salespeople}
    for (uid, week), visited in sorted(by_person_week.items()):
        person = people[uid]
        plan_id = route_plan_id(batch, person.code, week)
        progress_id = f"{plan_id}_{uid}"
        key_id = publication_key_id(uid, week)
        published = _local(week, PUBLISH_MINUTE)
        identity = {"salesmanUid": uid, "salesmanCode": person.code, "branchId": person.branch_id}
        days: list[dict[str, Any]] = []
        stop_ids: list[str] = []
        stop_retailers: dict[str, str] = {}
        events: list[tuple[datetime, str, str, int]] = []
        route_km = 0.0
        for weekday, label in enumerate(WEEKDAY_LABELS):
            day = week + timedelta(days=weekday)
            today = sorted((plan for plan in visited if plan.weekday == weekday), key=lambda plan: plan.shop_id)
            session = hashlib.sha256(f"{batch}|{uid}|{day.isoformat()}".encode("utf-8")).hexdigest()[:32]
            stops: list[dict[str, Any]] = []
            previous: tuple[float, float] | None = None
            day_km = 0.0
            for sequence, plan in enumerate(today, 1):
                start = 9 * 60 + (sequence - 1) * SLOT_MINUTES
                arrived = _local(day, start)
                done = _local(day, start + SERVICE_MINUTES)
                stop = _stop_id(weekday, sequence, plan.shop_id)
                point = shop_coordinates(plan.row)
                leg = _distance_km(previous, point)
                previous = point or previous
                day_km += leg
                name = shop_name(plan.row)
                stop_ids.append(stop)
                stop_retailers[stop] = plan.shop_id
                stops.append({
                    "stopId": stop,
                    "dayId": label.lower(),
                    "retailerId": plan.shop_id,
                    "retailerName": name,
                    "address": text(plan.row, "address"),
                    "lat": point[0] if point else 0.0,
                    "lng": point[1] if point else 0.0,
                    "sequence": sequence,
                    "arrival": _clock(start),
                    "departure": _clock(start + SERVICE_MINUTES),
                    "estimatedArrival": _clock(start),
                    "estimatedDeparture": _clock(start + SERVICE_MINUTES),
                    "legDistanceKm": leg,
                    "travelMinutesFromPrevious": 0 if sequence == 1 else SLOT_MINUTES - SERVICE_MINUTES,
                    "reason": "",
                    "priorityReason": "",
                    "score": 0.0,
                    "status": "not_started",
                })
                arrival_event = f"{session}_{stop}_arrived"
                completed_event = f"{session}_{stop}_completed"
                events.append((done, stop, completed_event, sequence * 2))
                documents["route_stop_progress"][f"{plan_id}_{uid}_{stop}"] = {
                    "lifecycleSchemaVersion": 2,
                    "planId": plan_id,
                    **identity,
                    "stopId": stop,
                    "retailerId": plan.shop_id,
                    "retailerName": name,
                    "status": "completed",
                    "eventId": completed_event,
                    "workSessionId": session,
                    "workSessionGeneration": 1,
                    "sessionEventSequence": sequence * 2,
                    "deviceOccurredAt": done,
                    "receivedAt": done,
                    "updatedAt": done,
                    "arrivedAt": arrived,
                    "arrivalEventId": arrival_event,
                    "arrivalWorkSessionId": session,
                    "arrivalWorkSessionGeneration": 1,
                    "arrivalSessionEventSequence": sequence * 2 - 1,
                    "arrivalDeviceOccurredAt": arrived,
                    "arrivalReceivedAt": arrived,
                    "arrivalMode": "manual_unverified",
                    "arrivalFailureCode": "unavailable",
                    "overrideReasonCode": "gps_unavailable",
                    "overrideNote": SIMULATED_NOTE,
                    "coordinateReferenceMode": "unverified",
                    "retailerCoordinateRevision": "",
                    "retailerCoordinateSource": "",
                    "completedAt": done,
                    "simulationBatchId": batch,
                }
            route_km += day_km
            days.append({
                "dayId": label.lower(),
                "dayLabel": label,
                "date": _local(day, 0),
                "totalRetailers": len(stops),
                "estimatedServiceMinutes": len(stops) * SERVICE_MINUTES,
                "stops": stops,
                "totalDistanceKm": round(day_km, 3),
                "geometry": [],
            })
        documents["route_plan_publication_keys"][key_id] = {
            "keyId": key_id,
            "planId": plan_id,
            "salesmanIdentity": uid,
            "salesmanUid": uid,
            "salesmanCode": person.code,
            "weekKey": f"{week:%Y%m%d}",
            "weekStart": _local(week, 0),
            "active": True,
            "createdAt": published,
            "updatedAt": published,
            "simulationBatchId": batch,
        }
        documents["route_plans"][plan_id] = {
            "planId": plan_id,
            "weekStart": _local(week, 0),
            "weekEnd": _local(week + timedelta(days=5), 0),
            "status": "published",
            "source": "simulation",
            **identity,
            "salesmanName": person.name,
            "planVersion": 1,
            "isDemo": False,
            "optimisationMethod": "HaversineNearestNeighbour",
            "days": days,
            "totalStops": len(stop_ids),
            "stopIds": stop_ids,
            "stopRetailerIds": stop_retailers,
            "stopCoordinateSnapshots": {},
            "totalDistanceKm": round(route_km, 3),
            "publicationKeyId": key_id,
            "approvedAt": published,
            "publishedAt": published,
            "createdAt": published,
            "updatedAt": published,
            "simulationBatchId": batch,
        }
        events.sort()
        last_time, last_stop, last_event, last_sequence = events[-1]
        documents["route_plan_progress"][progress_id] = {
            "progressId": progress_id,
            "planId": plan_id,
            **identity,
            "isOfflineCreated": False,
            "status": "completed",
            "routeSessionState": "completed",
            "acceptedAt": published + timedelta(minutes=30),
            "startedAt": events[0][0] - timedelta(minutes=SERVICE_MINUTES),
            "completedAt": last_time,
            "handledStopIds": [event[1] for event in events],
            "lastStopId": last_stop,
            "lastStopStatus": "completed",
            "lastStopEventId": last_event,
            "lastSummaryWorkSessionGeneration": 1,
            "lastSummaryEventSequence": last_sequence,
            "lastStopWriteStopId": last_stop,
            "lastStopWriteStatus": "completed",
            "lastStopWriteEventId": last_event,
            "lastStopWriteWorkSessionGeneration": 1,
            "lastStopWriteSequence": last_sequence,
            "updatedAt": last_time,
            "lastSyncedAt": last_time,
            "simulationBatchId": batch,
        }
    return documents


def assigned_retailers(company: Company, shops: Mapping[str, ShopPlan]) -> list[dict[str, Any]]:
    rows = []
    for row in company.retailers:
        plan = shops.get(shop_id(row))
        if plan is None:
            rows.append(dict(row))
            continue
        kept = {key: value for key, value in row.items() if key not in LEGACY_ASSIGNMENT_FIELDS}
        rows.append({**kept, "assignedSalesmanId": plan.person.code})
    return rows


def _moment(row: Mapping[str, Any]) -> datetime | None:
    value = row.get("submittedAt") or row.get("createdAt")
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return None


def _real(rows: Any) -> tuple[Mapping[str, Any], ...]:
    return tuple(row for row in rows if not row.get("simulationBatchId"))


def run_pipeline(
    company: Company, shops: Mapping[str, ShopPlan], documents: Mapping[str, Mapping[str, Mapping[str, Any]]],
    as_of: date, window_weeks: int, *, with_simulated_outcomes: bool = True,
) -> Any:
    oldest = _local(week_start(as_of) - timedelta(weeks=max(window_weeks, 8)), 0)
    end = _local(as_of + timedelta(days=1), 0)
    simulated = [{"docId": doc_id, **data} for doc_id, data in sorted(documents["orders"].items())]
    orders = [
        row for row in [*_real(company.orders), *simulated]
        if (moment := _moment(row)) is not None and oldest <= moment < end
    ]
    outcomes = [
        row for row in [
            *_real(company.outcomes),
            *(
                {"docId": doc_id, **data}
                for doc_id, data in sorted(documents["conversation_outcomes"].items())
                if with_simulated_outcomes
            ),
        ]
        if (moment := _moment(row)) is None or moment < end
    ]
    normalized = normalize_firestore_inputs(
        orders=orders,
        products=company.products,
        retailers=assigned_retailers(company, shops),
        users=company.users,
        as_of=as_of,
        history_weeks=window_weeks,
    )
    return build_generation(
        normalized,
        as_of=as_of,
        run_id="simulation-check",
        generated_at=_local(as_of, 6 * 60),
        outcomes=normalize_outcomes(outcomes),
        orders=orders,
        window=HistoryWindow(weeks=window_weeks, requested=window_weeks, source="setting"),
    )


def stopped_pairs(result: Any) -> set[tuple[str, str]]:
    return {
        (str(insight.get("retailerId") or ""), str(insight.get("productId") or ""))
        for insight in result.insights
        if insight.get("type") == "stopped_product"
    }


def roster_ranking_counts(team: Team, result: Any) -> tuple[dict[str, int], int]:
    per_salesperson = {person.code: 0 for person in team.salespeople}
    skipped = 0
    for ranking in result.priority_rankings:
        owner = next((
            person for person in team.salespeople
            if ranking.get("salesmanUid") == person.uid or canonical(ranking.get("salesmanCode")) == canonical(person.code)
        ), None)
        if owner is None:
            skipped += 1
        else:
            per_salesperson[owner.code] += 1
    return per_salesperson, skipped


def rank_of(result: Any, retailer: str) -> int | None:
    for ranking in result.priority_rankings:
        for row in ranking["ranking"]:
            if row["retailerId"] == retailer:
                return int(row["rank"])
    return None


def _generate(
    company: Company, team: Team, settings: Settings, shops: Mapping[str, ShopPlan], story: Story,
    products: Mapping[str, Mapping[str, Any]], boosts: Mapping[str, int],
) -> tuple[dict[tuple[str, date], dict[str, int]], dict[tuple[str, date], str], list[dict[str, Any]]]:
    lines, slots = _base_lines(settings, story, shops, products, boosts)
    checks: list[dict[str, Any]] = []
    for cutoff, planted in zip(settings.cutoffs, story.stops):
        newest = cutoff - timedelta(weeks=1)
        added: list[list[str]] = []
        for _ in range(FIX_PASSES + 1):
            documents = _build_documents(company, team, settings, shops, products, story, lines, slots, cutoff)
            result = run_pipeline(company, shops, documents, cutoff, settings.window_weeks)
            stray = sorted(stopped_pairs(result) - {planted})
            if not stray:
                break
            for shop, product in stray:
                if shop not in shops or product not in products:
                    raise SimulationError(
                        f"At {cutoff} the shop {shop} has a stopped alert on {product} that the simulation cannot "
                        "remove: the shop or the product is outside the simulation."
                    )
                if _forced(settings, story, shop, product, newest) is False:
                    raise SimulationError(
                        f"At {cutoff} the planted shop {shop} is flagged one week too early. Change the seed."
                    )
                base = dict(shops[shop].basket).get(product, 1)
                lines.setdefault((shop, newest), {})[product] = _quantity(products[product], base)
                slots[(shop, newest)] = "order"
                added.append([shop, product])
        else:
            raise SimulationError(f"At {cutoff} stray stopped alerts stay after {FIX_PASSES} passes: {stray}.")
        per_salesperson, skipped = roster_ranking_counts(team, result)
        checks.append({
            "cutoff": cutoff.isoformat(),
            "plantedShop": planted[0],
            "plantedProduct": planted[1],
            "flagged": planted in stopped_pairs(result),
            "rank": rank_of(result, planted[0]),
            "recoveredShopStopped": story.recovered in stopped_pairs(result),
            "linesAddedAgainstStrayAlerts": added,
            "rankings": sum(per_salesperson.values()),
            "rankingsPerSalesperson": per_salesperson,
            "skippedRankings": {"why": NOT_ROSTER_RANKING, "count": skipped},
            "boostLevel": boosts.get(planted[0], 0),
        })
    return lines, slots, checks


def simulate(company: Company, team: Team, settings: Settings, *, now: datetime) -> Simulation:
    _check_settings(settings, team)
    other = sorted({
        str(row["simulationBatchId"]) for row in company.documents.values()
        if row.get("simulationBatchId") not in (None, "", settings.batch)
    })
    if other:
        raise SimulationError(f"The export holds records of another simulated batch ({', '.join(other)}). Undo it first.")
    shops, story = _plan_shops(company, team, settings)
    products = {text(product, "docId"): product for product in orderable_products(company)}
    boosts = {shop: 0 for shop, _ in story.stops}
    while True:
        lines, slots, checks = _generate(company, team, settings, shops, story, products, boosts)
        low = [check["plantedShop"] for check in checks if check["rank"] != 1]
        if not low:
            break
        for shop in low:
            boosts[shop] += 1
            if boosts[shop] > BOOST_LIMIT:
                raise SimulationError(
                    f"The planted shop {shop} is not rank 1 for its salesperson at {BOOST_LIMIT} steps of bigger orders."
                )
    documents = _build_documents(company, team, settings, shops, products, story, lines, slots, settings.cutoff)
    documents.update(_route_documents(team, settings, shops, slots, now))
    simulation = Simulation(settings, team, story, dict(shops), dict(boosts), documents, checks)
    verify(company, simulation, now=now)
    return simulation


def verify(company: Company, simulation: Simulation, *, now: datetime) -> None:
    settings = simulation.settings
    problems: list[str] = []
    for check in simulation.checks:
        if not check["flagged"]:
            problems.append(f"{check['cutoff']}: the planted shop {check['plantedShop']} is not flagged.")
        if check["rank"] != 1:
            problems.append(f"{check['cutoff']}: the planted shop {check['plantedShop']} has rank {check['rank']}.")
        if check["recoveredShopStopped"]:
            problems.append(f"{check['cutoff']}: the recovered shop still has a stopped alert.")
        wrong = sorted(code for code, count in check["rankingsPerSalesperson"].items() if count != 1)
        if wrong:
            problems.append(
                f"{check['cutoff']}: {check['rankings']} rankings of roster salespeople, not one for each salesperson "
                f"({', '.join(wrong)})."
            )
    product_ids = {text(product, "docId") for product in orderable_products(company)}
    for collection, rows in simulation.documents.items():
        for doc_id, data in rows.items():
            if is_demo_record({"docId": doc_id, **data}):
                problems.append(f"{collection}/{doc_id} carries a demo mark.")
            if data.get("simulationBatchId") != settings.batch:
                problems.append(f"{collection}/{doc_id} has no batch id.")
            late = [key for key, value in data.items() if isinstance(value, datetime) and value > now]
            if late:
                problems.append(f"{collection}/{doc_id} is dated after the write time ({', '.join(sorted(late))}).")
    for doc_id, order in simulation.documents["orders"].items():
        if order["retailerId"] not in simulation.shops:
            problems.append(f"orders/{doc_id} points at a shop outside the simulation.")
        if any(item["productId"] not in product_ids for item in order["items"]):
            problems.append(f"orders/{doc_id} holds a product with no catalogue price.")
    orders = simulation.documents["orders"]
    purchase_orders = simulation.documents["purchase_orders"]
    if set(purchase_orders) != set(orders):
        problems.append("The orders and the purchase orders do not match one to one.")
    for doc_id, order in orders.items():
        if order["status"] != "approved" or not order["submittedAt"] < order["approvedAt"] <= now:
            problems.append(f"orders/{doc_id} is not approved after its submit time and before the write time.")
    taken = {
        data.get("poNumber") for path, data in company.documents.items()
        if path.startswith("purchase_orders/") and data.get("simulationBatchId") != settings.batch
    }
    numbers = Counter(row["poNumber"] for row in purchase_orders.values())
    repeated = sorted(number for number, count in numbers.items() if count > 1 or number in taken)
    if repeated:
        problems.append(f"{len(repeated)} purchase order numbers are already in use. First: {repeated[0]}")
    if settings.cutoff > week_start(now):
        problems.append(f"The cut-off {settings.cutoff} is after the current week. Its orders would be in the future.")
    existing = len(_real(company.orders))
    total = existing + len(simulation.documents["orders"])
    if total > settings.order_limit:
        problems.append(f"The company would hold {total} orders. The limit is {settings.order_limit}.")
    weekdays: dict[str, set[int]] = {}
    for order in simulation.documents["orders"].values():
        weekdays.setdefault(order["retailerId"], set()).add(order["submittedAt"].astimezone(ASIA_KUCHING).weekday())
    for key, plan in simulation.shops.items():
        if weekdays.get(key) != {plan.weekday}:
            problems.append(f"The shop {key} does not order on one weekday: {sorted(weekdays.get(key, set()))}.")
    if problems:
        raise SimulationError("The simulation failed its own checks:\n" + "\n".join(problems))


def purchase_order_busiest_week(company: Company, simulation: Simulation) -> dict[str, Any]:
    known = any(path.startswith("purchase_orders/") for path in company.documents)
    existing = Counter(
        week_start(data["issuedAt"]) for path, data in company.documents.items()
        if path.startswith("purchase_orders/") and not data.get("simulationBatchId")
        and isinstance(data.get("issuedAt"), datetime)
    )
    simulated = Counter(week_start(row["issuedAt"]) for row in simulation.documents["purchase_orders"].values())
    week = max(simulated, key=lambda monday: (simulated[monday] + existing[monday], monday))
    return {
        "weekStart": week.isoformat(),
        "simulated": simulated[week],
        "existingInExport": existing[week] if known else None,
        "simulatedInAllWeeks": sum(simulated.values()),
    }


def catalogue_price_missing(company: Company, simulation: Simulation) -> list[str]:
    priced = {text(product, "docId") for product in company.products if price_sen(catalogue_price(product))}
    return sorted({
        item["productId"]
        for order in simulation.documents["orders"].values()
        for item in order["items"]
        if item["productId"] not in priced
    })

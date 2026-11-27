from __future__ import annotations

import base64
import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence

from forecasting.ai_service.normalization import is_demo_record

EXPORT_FORMAT = 1
EXPORT_COLLECTIONS = (
    "retailers",
    "products",
    "users",
    "user_access",
    "orders",
    "purchase_orders",
    "retailer_score_sheet_settings",
    "route_plans",
    "branches",
    "conversation_outcomes",
    "route_plan_progress",
    "route_stop_progress",
)
PRODUCT_ID = re.compile(r"^[A-Za-z0-9_-]{1,200}$")
ENCODED_NAME = re.compile(r"^[A-Za-z0-9_-]{1,800}$")
PRICE_KEYS = ("unitPrice", "price")
PRODUCT_NAME_KEYS = ("productName", "product_name", "itemName", "name")
SHOP_NAME_KEYS = ("retailerName", "retailer_name", "name")
PERSON_NAME_KEYS = ("name", "displayName", "fullName", "employeeName", "salesmanName")
MAX_LINE_QUANTITY = 999


class SimulationError(Exception):
    pass


def text(row: Mapping[str, Any], *names: str) -> str:
    for name in names:
        value = row.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def canonical(value: Any) -> str:
    return str(value or "").strip().casefold()


@dataclass(frozen=True)
class Person:
    uid: str
    code: str
    name: str
    email: str
    branch_id: str
    role: str
    status: str


@dataclass(frozen=True)
class Team:
    branch_id: str
    author: Person
    groups: tuple[tuple[Person, tuple[Person, ...]], ...]
    leaver_supervisors: tuple[Person, ...]
    shop_owners: Mapping[str, Person] = field(default_factory=dict)

    @property
    def salespeople(self) -> tuple[Person, ...]:
        return tuple(person for _, members in self.groups for person in members)

    def supervisor_of(self, uid: str) -> Person:
        for supervisor, members in self.groups:
            if any(person.uid == uid for person in members):
                return supervisor
        raise SimulationError(f"The salesperson {uid} is in no team of the roster file.")


@dataclass(frozen=True)
class Company:
    project: str
    retailers: tuple[Mapping[str, Any], ...]
    products: tuple[Mapping[str, Any], ...]
    users: tuple[Mapping[str, Any], ...]
    user_access: tuple[Mapping[str, Any], ...]
    orders: tuple[Mapping[str, Any], ...]
    sheets: Mapping[str, Mapping[str, Any]]
    route_plans: tuple[Mapping[str, Any], ...] = ()
    outcomes: tuple[Mapping[str, Any], ...] = ()
    documents: Mapping[str, Mapping[str, Any]] = field(default_factory=dict)


def _rows(documents: Mapping[str, Any]) -> tuple[dict[str, Any], ...]:
    return tuple({"docId": doc_id, **data} for doc_id, data in sorted(documents.items()))


def company_from_collections(project: str, collections: Mapping[str, Mapping[str, Mapping[str, Any]]]) -> Company:
    def rows(name: str) -> tuple[dict[str, Any], ...]:
        return _rows(collections.get(name, {}))

    return Company(
        project=project,
        retailers=rows("retailers"),
        products=rows("products"),
        users=rows("users"),
        user_access=rows("user_access"),
        orders=rows("orders"),
        sheets=dict(collections.get("retailer_score_sheet_settings", {})),
        route_plans=rows("route_plans"),
        outcomes=rows("conversation_outcomes"),
        documents={
            f"{name}/{doc_id}": data for name, documents in collections.items() for doc_id, data in documents.items()
        },
    )


def load_export(path: Path) -> Company:
    from platform_service.tenant_snapshot import decode

    try:
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SimulationError(f"The export file cannot be read: {error}") from None
    collections = body.get("collections") if isinstance(body, dict) else None
    if not isinstance(body, dict) or body.get("format") != EXPORT_FORMAT or not isinstance(collections, dict):
        raise SimulationError("The file is not an export of this tool.")
    if not isinstance(body.get("project"), str) or not body["project"]:
        raise SimulationError("The export file names no project.")
    decoded = {
        name: {doc_id: decode(data, None) for doc_id, data in documents.items()}
        for name, documents in collections.items()
    }
    return company_from_collections(body["project"], decoded)


def person_uid(row: Mapping[str, Any]) -> str:
    return text(row, "uid", "docId")


def people_by_uid(company: Company) -> dict[str, Person]:
    access = {text(row, "docId"): row for row in company.user_access}
    people: dict[str, Person] = {}
    for row in company.users:
        uid = person_uid(row)
        if not uid:
            continue
        index = access.get(uid, {})
        merged = {**row, **{key: value for key, value in index.items() if key != "docId"}}
        people[uid] = Person(
            uid=uid,
            code=text(merged, "employeeCode", "staffId"),
            name=text(row, *PERSON_NAME_KEYS),
            email=text(row, "email"),
            branch_id=text(merged, "branchId", "branch_id"),
            role=text(merged, "role"),
            status=text(merged, "status"),
        )
    return people


def resolve_team(company: Company, roster: Mapping[str, Any]) -> Team:
    people = people_by_uid(company)

    def find(label: Any, what: str) -> Person:
        wanted = canonical(label)
        if not wanted:
            raise SimulationError(f"The roster file has an empty entry for {what}.")
        found = [
            person for person in people.values()
            if wanted in {canonical(person.uid), canonical(person.code), canonical(person.name)}
        ]
        if len(found) != 1:
            raise SimulationError(
                f"The roster entry for {what} matches {len(found)} people in the export. It must match one."
            )
        return found[0]

    groups_in = roster.get("teams")
    if not isinstance(groups_in, list) or not groups_in:
        raise SimulationError("The roster file needs a list named teams.")
    groups: list[tuple[Person, tuple[Person, ...]]] = []
    for index, group in enumerate(groups_in, 1):
        supervisor = find(group.get("supervisor"), f"the supervisor of team {index}")
        members = tuple(
            find(label, f"salesperson {position} of team {index}")
            for position, label in enumerate(group.get("salespeople") or [], 1)
        )
        if supervisor.role != "supervisor":
            raise SimulationError(f"The supervisor of team {index} does not have the supervisor role.")
        if not members or any(member.role != "salesman" for member in members):
            raise SimulationError(f"Team {index} needs salespeople with the salesman role.")
        groups.append((supervisor, members))
    team = Team(
        shop_owners=_shop_owners(roster.get("shopOwners"), tuple(person for _, members in groups for person in members)),
        branch_id=str(roster.get("branchId") or "").strip(),
        author=find(roster.get("routeAuthor"), "the route author"),
        groups=tuple(groups),
        leaver_supervisors=tuple(
            find(label, f"leaver supervisor {position}")
            for position, label in enumerate(roster.get("leaverSupervisors") or [], 1)
        ),
    )
    seen = [person.uid for person in team.salespeople] + [supervisor.uid for supervisor, _ in team.groups]
    if len(set(seen)) != len(seen):
        raise SimulationError("The roster file names one person in two places.")
    if not team.branch_id:
        raise SimulationError("The roster file needs a branchId.")
    for person in team.salespeople:
        if not person.code or not PRODUCT_ID.fullmatch(person.uid):
            raise SimulationError(f"The salesperson {person.uid} has no employee code or an unusable uid.")
        if canonical(person.branch_id) != canonical(team.branch_id):
            raise SimulationError(f"The salesperson {person.uid} is in another branch than the roster's branch.")
    if team.author.role not in {"admin", "developer"}:
        raise SimulationError("The route author must be an admin, because only an admin publishes routes.")
    return team


def _shop_owners(value: Any, salespeople: Sequence[Person]) -> dict[str, Person]:
    if value is None:
        return {}
    if not isinstance(value, Mapping) or not value:
        raise SimulationError("shopOwners in the roster file must map each shop id to a salesperson code.")
    by_code = {canonical(person.code): person for person in salespeople}
    owners: dict[str, Person] = {}
    seen: set[str] = set()
    for shop, code in value.items():
        if not isinstance(shop, str) or not shop.strip():
            raise SimulationError("shopOwners holds an empty shop id.")
        if canonical(shop) in seen:
            raise SimulationError(f"shopOwners maps the shop {shop} twice.")
        seen.add(canonical(shop))
        person = by_code.get(canonical(code))
        if person is None:
            raise SimulationError(f"shopOwners gives the shop {shop} to {code!r}, who is not a salesperson of the roster.")
        owners[shop.strip()] = person
    empty = [person.code for person in salespeople if person not in owners.values()]
    if empty:
        raise SimulationError(f"shopOwners gives no shop to {', '.join(empty)}. Each salesperson needs at least one.")
    return owners


def _refuse_repeated_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    keys = [key for key, _ in pairs]
    repeated = sorted({key for key in keys if keys.count(key) > 1})
    if repeated:
        raise SimulationError(f"The roster file names {repeated[0]} twice in one object.")
    return dict(pairs)


def load_roster(path: Path) -> Mapping[str, Any]:
    try:
        body = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_refuse_repeated_keys)
    except (OSError, ValueError) as error:
        raise SimulationError(f"The roster file cannot be read: {error}") from None
    if not isinstance(body, dict):
        raise SimulationError("The roster file must hold one JSON object.")
    return body


def shop_id(row: Mapping[str, Any]) -> str:
    return text(row, "retailerId", "retailer_id", "retailerCode", "docId")


def shop_name(row: Mapping[str, Any]) -> str:
    return text(row, *SHOP_NAME_KEYS)


def shop_coordinates(row: Mapping[str, Any]) -> tuple[float, float] | None:
    location = row.get("location")
    latitude = row.get("latitude") or row.get("lat") or getattr(location, "latitude", None)
    longitude = row.get("longitude") or row.get("lng") or getattr(location, "longitude", None)
    if isinstance(latitude, (int, float)) and isinstance(longitude, (int, float)):
        return float(latitude), float(longitude)
    return None


def is_retired(row: Mapping[str, Any]) -> bool:
    return canonical(text(row, "status", "retailerStatus")) == "retired" or row.get("retiredAt") is not None


def not_active_shops(shops: Sequence[Mapping[str, Any]], owners: Mapping[str, Person]) -> list[dict[str, str]]:
    found = []
    for row in sorted(shops, key=shop_id):
        status = text(row, "status", "retailerStatus")
        if status and canonical(status) != "active":
            found.append({"shopId": shop_id(row), "status": status, "owner": owners[shop_id(row)].code})
    return found


def simulated_shops(company: Company, team: Team, per_salesperson: int) -> tuple[Mapping[str, Any], ...]:
    shops = tuple(
        row for row in company.retailers
        if not is_retired(row) and canonical(text(row, "branchId", "branch_id")) == canonical(team.branch_id)
    )
    if team.shop_owners:
        found = {shop_id(row) for row in shops}
        mapped = set(team.shop_owners)
        if found != mapped:
            missing, extra = sorted(found - mapped), sorted(mapped - found)
            raise SimulationError(
                f"shopOwners does not match the {len(found)} active shops of the branch. "
                f"Not mapped: {missing or 'none'}. Mapped but not an active shop of the branch: {extra or 'none'}."
            )
    wanted = per_salesperson * len(team.salespeople)
    if not team.shop_owners and len(shops) != wanted:
        raise SimulationError(
            f"The branch has {len(shops)} active shops. The roster needs {wanted} "
            f"({per_salesperson} for each of {len(team.salespeople)} salespeople)."
        )
    for row in shops:
        if is_demo_record(row):
            raise SimulationError(f"The shop {shop_id(row)} carries a demo mark. The job would leave it out.")
        if text(row, "docId") != shop_id(row):
            raise SimulationError(f"The shop {text(row, 'docId')} has a retailerId that differs from its document id.")
        if not shop_name(row):
            raise SimulationError(f"The shop {shop_id(row)} has no name.")
    return shops


def price_sen(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        return None
    scaled = float(value) * 100
    rounded = round(scaled)
    return rounded if abs(scaled - rounded) <= 0.000001 and 1 <= rounded <= 999_999_999 else None


def catalogue_price(product: Mapping[str, Any]) -> Any:
    for key in PRICE_KEYS:
        if product.get(key) is not None:
            return product[key]
    return None


def encoded_name(name: str) -> str:
    return base64.urlsafe_b64encode(name.encode("utf-8")).decode("ascii").rstrip("=")


def product_name(product: Mapping[str, Any]) -> str:
    return text(product, *PRODUCT_NAME_KEYS)


def orderable_products(company: Company) -> tuple[Mapping[str, Any], ...]:
    found = []
    for row in company.products:
        product_id = text(row, "docId")
        name = product_name(row)
        if (
            text(row, "productId", "itemId", "docId") != product_id
            or not PRODUCT_ID.fullmatch(product_id)
            or not name
            or len(name) > 200
            or not ENCODED_NAME.fullmatch(encoded_name(name))
            or price_sen(catalogue_price(row)) is None
            or is_demo_record(row)
            or canonical(text(row, "status")) in {"inactive", "archived", "deleted", "discontinued"}
        ):
            continue
        found.append(row)
    return tuple(found)


def shop_unit_price(product: Mapping[str, Any], sheet: Mapping[str, Any] | None) -> Any:
    overrides = (sheet or {}).get("productOverrides")
    override = overrides.get(text(product, "docId")) if isinstance(overrides, Mapping) else None
    if isinstance(override, Mapping):
        for key in PRICE_KEYS:
            if override.get(key) is not None:
                return override[key]
    return catalogue_price(product)


def assign_areas(shops: Sequence[Mapping[str, Any]], team: Team) -> dict[str, Person]:
    if team.shop_owners:
        return {shop_id(row): team.shop_owners[shop_id(row)] for row in shops}
    def key(row: Mapping[str, Any], axis: int) -> tuple[int, float, str]:
        point = shop_coordinates(row)
        return (0, point[axis], shop_id(row)) if point else (1, 0.0, shop_id(row))

    by_longitude = sorted(shops, key=lambda row: key(row, 1))
    assigned: dict[str, Person] = {}
    start = 0
    for _, members in team.groups:
        size = len(by_longitude) * len(members) // len(team.salespeople)
        block = sorted(by_longitude[start:start + size], key=lambda row: key(row, 0))
        start += size
        share = len(block) // len(members)
        for position, person in enumerate(members):
            for row in block[position * share:(position + 1) * share]:
                assigned[shop_id(row)] = person
    if len(assigned) != len(shops):
        raise SimulationError("The shops cannot be split evenly between the salespeople of the roster.")
    return assigned

from __future__ import annotations

import base64
import logging
import math
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from google.api_core.exceptions import InvalidArgument
from google.cloud import firestore

ORDERS = "orders"
PRODUCTS = "products"
RETAILERS = "retailers"
USER_ACCESS = "user_access"
USERS = "users"
SHEETS = "retailer_score_sheet_settings"
STATE = "server_scheduler"
CURSOR = "price_check_cursor"
STAMP = "serverPriceCheck"
VERSION = 1
PENDING = "pending_retry"
RETRY = "retry"
DONE = "done"
PERMANENT = "permanent"
RETRY_ORDERS = "retryOrders"
MAX_ATTEMPTS = 3
MAX_RETRY_ORDERS = 500
OVERLAP = timedelta(minutes=2)
PRICE_KEYS = ("unitPrice", "price")
PRODUCT_NAME_KEYS = ("productName", "product_name", "itemName", "name")
RETAILER_NAME_KEYS = ("retailerName", "retailer_name", "outlet")
RETAILER_RECORD_NAME_KEYS = ("retailerName", "retailer_name", "name", "martName", "customerName", "customer_name",
                             "storeName", "store_name")
SALESMAN_NAME_KEYS = ("salesmanName", "salesman_name", "submittedByName")
MAX_LINES = 25
MAX_QUANTITY = 999
MAX_UNIT_SEN = 999_999_999

_LOG = logging.getLogger("platform_service.order_price_check")
_PRODUCT_ID = re.compile(r"^[A-Za-z0-9_-]{1,200}$")
_NAME = re.compile(r"^[A-Za-z0-9_-]{1,800}$")
_DIGITS = re.compile(r"^[0-9]{1,12}$")


def _number(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).replace("RM", "").replace(",", "").strip()
    if "_" in text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _sen(value: Any) -> int | None:
    number = _number(value)
    if number is None or not math.isfinite(number):
        return None
    return math.floor(number * 100 + 0.5) if number >= 0 else -math.floor(-number * 100 + 0.5)


def _positive_sen(value: Any) -> int | None:
    sen = _sen(value)
    return sen if sen is not None and sen >= 1 else None


def expected_unit_sen(product_id: str, product: Mapping[str, Any], sheet: Mapping[str, Any] | None) -> int | None:
    overrides = (sheet or {}).get("productOverrides")
    override = overrides.get(product_id) if isinstance(overrides, Mapping) else None
    if isinstance(override, Mapping):
        for field in PRICE_KEYS:
            if override.get(field) is not None:
                return _positive_sen(override[field])
    for field in PRICE_KEYS:
        if product.get(field) is not None:
            return _positive_sen(product[field])
    return None


def parse_commercial_lines(order: Mapping[str, Any]) -> tuple[list[tuple[str, int, int]] | None, str | None]:
    if order.get("commercialSchemaVersion") != 1 or order.get("commercialLines") is None:
        return None, "no_commercial_lines"
    raw = order["commercialLines"]
    if not isinstance(raw, list) or not 1 <= len(raw) <= MAX_LINES:
        return None, "commercial_lines_invalid"
    lines: list[tuple[str, int, int]] = []
    for text in raw:
        parts = text.split("~") if isinstance(text, str) else []
        if (len(parts) != 4 or not _PRODUCT_ID.fullmatch(parts[0]) or not _NAME.fullmatch(parts[1])
                or not _DIGITS.fullmatch(parts[2]) or not _DIGITS.fullmatch(parts[3])):
            return None, "commercial_lines_invalid"
        quantity, unit = int(parts[2]), int(parts[3])
        if not 1 <= quantity <= MAX_QUANTITY or not 1 <= unit <= MAX_UNIT_SEN:
            return None, "commercial_lines_invalid"
        lines.append((parts[0], quantity, unit))
    return lines, None


def _same_name(left: Any, right: Any) -> bool:
    return " ".join(str(left).split()).casefold() == " ".join(str(right).split()).casefold()


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _shown_names(source: Mapping[str, Any], keys: tuple[str, ...]) -> list[str]:
    return [name for name in (_text(source.get(key)) for key in keys) if name]


def _line_name(encoded: str) -> str:
    try:
        return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""


def _salesman_names(profile: Mapping[str, Any]) -> list[str]:
    names = [_text(profile.get(key)) for key in ("name", "displayName", "fullName", "employeeName", "salesmanName")]
    email = _text(profile.get("email"))
    if email:
        names.append(email.split("@")[0])
    return [name for name in names if name]


class PriceBook:
    def __init__(self, db: firestore.Client):
        self.db = db
        self._products: dict[str, dict[str, Any] | None] = {}
        self._sheets: dict[str, dict[str, Any] | None] = {}
        self._retailers: dict[str, dict[str, Any] | None] = {}
        self._profiles: dict[str, dict[str, Any] | None] = {}

    def retailer(self, retailer_id: Any) -> dict[str, Any] | None:
        if not isinstance(retailer_id, str) or not retailer_id.strip() or "/" in retailer_id:
            return None
        if retailer_id not in self._retailers:
            snapshot = self.db.collection(RETAILERS).document(retailer_id).get()
            self._retailers[retailer_id] = (snapshot.to_dict() or {}) if snapshot.exists else None
        return self._retailers[retailer_id]

    def profile(self, uid: Any) -> dict[str, Any] | None:
        if not isinstance(uid, str) or not uid.strip() or "/" in uid:
            return None
        if uid not in self._profiles:
            access = self.db.collection(USER_ACCESS).document(uid).get()
            linked = _text((access.to_dict() or {}).get("userDocId")) if access.exists else ""
            document_id = linked if linked and "/" not in linked else uid
            snapshot = self.db.collection(USERS).document(document_id).get()
            self._profiles[uid] = (snapshot.to_dict() or {}) if snapshot.exists else None
        return self._profiles[uid]

    def product(self, product_id: str) -> dict[str, Any] | None:
        if product_id not in self._products:
            snapshot = self.db.collection(PRODUCTS).document(product_id).get()
            self._products[product_id] = (snapshot.to_dict() or {}) if snapshot.exists else None
        return self._products[product_id]

    def sheet(self, retailer_id: Any) -> dict[str, Any] | None:
        if not isinstance(retailer_id, str) or not retailer_id.strip() or "/" in retailer_id:
            return None
        if retailer_id not in self._sheets:
            snapshot = self.db.collection(SHEETS).document(retailer_id).get()
            self._sheets[retailer_id] = (snapshot.to_dict() or {}) if snapshot.exists else None
        return self._sheets[retailer_id]


def _unchanged_since(data: Mapping[str, Any] | None, moment: datetime) -> bool:
    if data is None:
        return True
    updated = data.get("updatedAt")
    return isinstance(updated, datetime) and updated <= moment


def _edited_since(data: Mapping[str, Any] | None, moment: datetime) -> bool:
    updated = (data or {}).get("updatedAt")
    return isinstance(updated, datetime) and updated > moment


def _price_changed_since(data: Mapping[str, Any] | None, moment: datetime) -> bool:
    priced = (data or {}).get("priceUpdatedAt")
    return isinstance(priced, datetime) and priced > moment


def _name_differences(order: Mapping[str, Any], lines: list[tuple[str, int, int]], book: PriceBook,
                      submitted_at: Any) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    raw_lines = order["commercialLines"]
    items = order.get("items") if isinstance(order.get("items"), list) else []
    for index, (product_id, _, _) in enumerate(lines):
        product = book.product(product_id)
        recorded_names = [_text((product or {}).get(key)) for key in ("productName", "itemName", "name")]
        recorded_names = [name for name in recorded_names if name]
        if not recorded_names or (isinstance(submitted_at, datetime) and _edited_since(product, submitted_at)):
            continue
        recorded = recorded_names[0]
        item = items[index] if index < len(items) and isinstance(items[index], Mapping) else {}
        shown = [_line_name(raw_lines[index].split("~")[1])] + _shown_names(item, PRODUCT_NAME_KEYS)
        wrong = next((name for name in shown if name and not any(_same_name(name, known) for known in recorded_names)), None)
        if wrong is not None:
            found.append({"kind": "product", "id": product_id, "submitted": wrong, "expected": recorded})
    retailer = book.retailer(order.get("retailerId"))
    recorded_retailers = _shown_names(retailer or {}, RETAILER_RECORD_NAME_KEYS)
    wrong_retailer = next((name for name in _shown_names(order, RETAILER_NAME_KEYS)
                           if recorded_retailers and not any(_same_name(name, known) for known in recorded_retailers)), None)
    if wrong_retailer is not None:
        found.append({"kind": "retailer", "id": order.get("retailerId"), "submitted": wrong_retailer,
                      "expected": recorded_retailers[0]})
    profile = book.profile(order.get("salesmanUid"))
    recorded_names = _salesman_names(profile or {})
    wrong_salesman = next((name for name in _shown_names(order, SALESMAN_NAME_KEYS)
                           if recorded_names and not any(_same_name(name, known) for known in recorded_names)), None)
    if wrong_salesman is not None:
        found.append({"kind": "salesman", "id": order.get("salesmanUid"), "submitted": wrong_salesman,
                      "expected": recorded_names[0]})
    return found


def price_order(order: Mapping[str, Any], book: PriceBook, now: datetime) -> dict[str, Any]:
    submitted_total = _sen(order.get("totalPrice"))
    if submitted_total is not None and submitted_total < 0:
        submitted_total = None

    def result(status: str, reason: str | None, expected: int | None = None,
               lines: list[dict[str, Any]] | None = None, names: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        stamp = {"status": status, "reason": reason, "checkedAt": now, "expectedTotalSen": expected,
                 "submittedTotalSen": submitted_total, "lines": lines or [], "version": VERSION}
        if names:
            stamp["names"] = names
        return stamp

    lines, problem = parse_commercial_lines(order)
    if lines is None:
        return result("unverifiable", problem)
    if submitted_total is None:
        return result("unverifiable", "total_unreadable")
    sheet = book.sheet(order.get("retailerId"))
    expected_units: list[int | None] = []
    unpriced: str | None = None
    for product_id, _, _ in lines:
        product = book.product(product_id)
        if product is None:
            unpriced = unpriced or "product_missing"
            expected_units.append(None)
            continue
        unit = expected_unit_sen(product_id, product, sheet)
        if unit is None:
            unpriced = unpriced or "price_unreadable"
        expected_units.append(unit)
    captured_total = sum(quantity * unit for _, quantity, unit in lines)
    expected_total = None if unpriced else sum(
        quantity * unit for (_, quantity, _), unit in zip(lines, expected_units))
    mismatched = [
        {"productId": product_id, "quantity": quantity, "submittedUnitSen": unit, "expectedUnitSen": expected}
        for (product_id, quantity, unit), expected in zip(lines, expected_units)
        if expected is not None and unit != expected]
    submitted_at = order.get("submittedAt")
    names = _name_differences(order, lines, book, submitted_at)
    if captured_total != submitted_total:
        return result("mismatch", "total_differs_from_lines", expected_total, mismatched, names)
    sheet_stable = isinstance(submitted_at, datetime) and _unchanged_since(sheet, submitted_at)
    firm = [entry for entry in mismatched
            if sheet_stable and _unchanged_since(book.product(entry["productId"]), submitted_at)]
    if firm or names:
        reason = "price_and_name_differ" if firm and names else "price_differs" if firm else "name_differs"
        return result("mismatch", reason, expected_total, firm, names)
    if unpriced:
        return result("unverifiable", unpriced)
    if book.retailer(order.get("retailerId")) is None:
        return result("unverifiable", "retailer_missing", expected_total)
    if mismatched:
        return result("unverifiable", "prices_changed_after_submission")
    if isinstance(submitted_at, datetime) and (_price_changed_since(sheet, submitted_at) or any(
            _price_changed_since(book.product(product_id), submitted_at) for product_id, _, _ in lines)):
        return result("unverifiable", "prices_changed_after_submission")
    return result("ok", None, expected_total)


def _write_stamp(db: firestore.Client, reference: Any, stamp: Any, update_time: Any) -> Mapping[str, Any] | None:
    @firestore.transactional
    def write(transaction: firestore.Transaction) -> Mapping[str, Any] | None:
        snapshot = reference.get(transaction=transaction)
        if not snapshot.exists:
            return None
        if snapshot.update_time != update_time:
            return {"status": RETRY}
        existing = (snapshot.to_dict() or {}).get(STAMP)
        if existing is not None and (not isinstance(existing, Mapping) or existing.get("status") != PENDING):
            return None
        stored = existing.get("attempts", 0) if isinstance(existing, Mapping) else 0
        result = stamp(stored if isinstance(stored, int) and not isinstance(stored, bool) else 0)             if callable(stamp) else dict(stamp)
        transaction.update(reference, {STAMP: result})
        return result

    return write(db.transaction(max_attempts=10))


def _terminal_stamp(moment: datetime, attempts: int) -> dict[str, Any]:
    return {"status": "unverifiable", "reason": "price_check_failed", "checkedAt": moment,
            "expectedTotalSen": None, "submittedTotalSen": None, "lines": [], "version": VERSION,
            "attempts": attempts}


def _failure_stamp(moment: datetime) -> Any:
    def build(stored_attempts: int) -> dict[str, Any]:
        attempts = stored_attempts + 1
        if attempts >= MAX_ATTEMPTS:
            return _terminal_stamp(moment, attempts)
        return {"status": PENDING, "attempts": attempts, "checkedAt": moment, "version": VERSION}

    return build


def check_orders(db: firestore.Client, *, now: datetime | None = None, page_size: int = 200,
                 max_pages: int = 5) -> dict[str, int]:
    moment = now or datetime.now(timezone.utc)
    cursor_ref = db.collection(STATE).document(CURSOR)
    cursor_data = cursor_ref.get().to_dict() or {}
    cursor = cursor_data.get("submittedAt")
    stored_retry = {key: value for key, value in (cursor_data.get(RETRY_ORDERS) or {}).items()
                    if isinstance(value, int) and not isinstance(value, bool)}
    retry_next: dict[str, int] = {}
    retry_documents: dict[str, Any] = {}
    query = db.collection(ORDERS).order_by("submittedAt")
    if isinstance(cursor, datetime):
        query = query.where(filter=firestore.FieldFilter("submittedAt", ">", cursor - OVERLAP))
    book = PriceBook(db)
    counts = {"checked": 0, "ok": 0, "mismatch": 0, "unverifiable": 0, "errors": 0}
    handled: set[str] = set()

    def save(document: Any, stamp: Any) -> str:
        try:
            written = _write_stamp(db, document.reference, stamp, document.update_time)
        except InvalidArgument:
            _LOG.exception("Price check result is not accepted for order %s.", document.id)
            counts["errors"] += 1
            return PERMANENT
        except Exception:
            _LOG.exception("Price check result could not be saved for order %s.", document.id)
            counts["errors"] += 1
            return RETRY
        if written is not None and written["status"] == RETRY:
            return RETRY
        if written is not None and written["status"] != PENDING:
            counts["checked"] += 1
            counts[written["status"]] += 1
        return DONE

    def settle(document: Any) -> None:
        data = document.to_dict() or {}
        existing = data.get(STAMP)
        if existing is not None and (not isinstance(existing, Mapping) or existing.get("status") != PENDING):
            return
        compute_failed = False
        try:
            stamp = price_order(data, book, moment)
        except Exception:
            _LOG.exception("Price check failed for order %s.", document.id)
            counts["errors"] += 1
            compute_failed = True
            stamp = _failure_stamp(moment)
        outcome = save(document, stamp)
        if outcome == PERMANENT and not compute_failed:
            outcome = save(document, _failure_stamp(moment))
        if outcome == RETRY:
            attempts = stored_retry.get(document.id, 0) + 1
            if attempts >= MAX_ATTEMPTS and save(document, _terminal_stamp(moment, attempts)) == DONE:
                return
            retry_next[document.id] = attempts
            retry_documents[document.id] = document

    pending_query = db.collection(ORDERS).where(filter=firestore.FieldFilter(f"{STAMP}.status", "==", PENDING))
    for document in pending_query.limit(page_size).stream():
        handled.add(document.id)
        settle(document)
    for order_id in stored_retry:
        if order_id not in handled:
            handled.add(order_id)
            document = db.collection(ORDERS).document(order_id).get()
            if document.exists:
                settle(document)
    last_seen = cursor
    last_document = None
    for _ in range(max_pages):
        page = query.start_after(last_document) if last_document is not None else query
        documents = list(page.limit(page_size).stream())
        for document in documents:
            if document.id not in handled:
                settle(document)
        if documents:
            last_document = documents[-1]
            seen = last_document.to_dict().get("submittedAt")
            if isinstance(seen, datetime):
                last_seen = seen
        if len(documents) < page_size:
            break
    overflow = len(retry_next) - MAX_RETRY_ORDERS
    if overflow > 0:
        oldest = sorted(retry_documents, key=lambda key: (
            retry_documents[key].to_dict() or {}).get("submittedAt") or moment)
        for order_id in oldest[:overflow]:
            if save(retry_documents[order_id], _terminal_stamp(moment, retry_next[order_id])) == DONE:
                del retry_next[order_id]
    if last_seen != cursor or retry_next != stored_retry:
        payload: dict[str, Any] = {"updatedAt": moment, RETRY_ORDERS: retry_next}
        if isinstance(last_seen, datetime):
            payload["submittedAt"] = last_seen
        cursor_ref.set(payload)
    return counts

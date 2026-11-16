from __future__ import annotations

import http.client
import json
import os
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request as UrlRequest, urlopen

from . import config

PAGE_SIZE = 500
MAX_DOCUMENTS = 20000

_DEMO_MARKER_FIELDS = (
    "isDemo", "is_demo", "demo", "environment", "source", "dataSource",
    "data_source", "id", "retailerId", "productId", "itemCode", "planId",
    "code", "retailerCode", "sku", "optimisationMethod",
)

INPUT_FIELD_MASKS: dict[str, tuple[str, ...]] = {
    "orders": tuple(sorted({
        *_DEMO_MARKER_FIELDS, "status", "submittedAt", "orderDate", "createdAt",
        "retailer_id", "retailerName", "retailer_name", "outlet", "orderId",
        "salesmanUid", "submittedByUid", "salesmanCode", "salesmanId",
        "staffId", "branchId", "branch_id", "commercialSchemaVersion",
        "commercialLines", "items",
    })),
    "products": tuple(sorted({
        *_DEMO_MARKER_FIELDS, "itemId", "productName", "product_name",
        "itemName", "displayName", "name", "barcode", "itemBarcode",
        "unitPrice", "price", "priceGuide", "sellingPrice", "packingSize",
        "packagingSize", "uom", "uomLabel", "unitOfMeasure",
    })),
    "retailers": tuple(sorted({
        *_DEMO_MARKER_FIELDS, "retailer_id", "retailerName", "retailer_name",
        "name", "assignedSalesmanId", "assigned_salesman_id", "salesmanCode",
        "employeeCode", "assignedSalesmanUid", "salesmanUid", "branchId",
        "branch_id", "location", "latitude", "lat", "longitude", "lng",
        "status", "retailerStatus", "retiredAt",
    })),
    "users": ("uid", "employeeCode", "staffId", "userId", "branchId", "branch_id"),
}


class FirestoreReadError(RuntimeError):
    pass


def _root() -> str:
    emulator = os.environ.get("FIRESTORE_EMULATOR_HOST", "").strip()
    if emulator:
        return "http://" + emulator + "/v1"
    return "https://firestore.googleapis.com/v1"


def _collection_path(collection: str, page_token: str) -> str:
    project = quote(config.FIREBASE_PROJECT_ID, safe="")
    name = quote(collection, safe="")
    path = (
        urlsplit(_root()).path
        + "/projects/" + project
        + "/databases/(default)/documents/" + name
        + "?pageSize=" + str(PAGE_SIZE)
    )
    for field in INPUT_FIELD_MASKS.get(collection, ()):
        path += "&mask.fieldPaths=" + quote(field, safe="")
    if page_token:
        path += "&pageToken=" + quote(page_token, safe="")
    return path


def _get_page(
    connection: http.client.HTTPConnection,
    collection: str,
    page_token: str,
    headers: dict[str, str],
) -> tuple[int, bytes]:
    connection.request("GET", _collection_path(collection, page_token), headers=headers)
    response = connection.getresponse()
    return response.status, response.read()


def _open_connection() -> http.client.HTTPConnection:
    parts = urlsplit(_root())
    if parts.scheme == "https":
        return http.client.HTTPSConnection(parts.netloc, timeout=30)
    return http.client.HTTPConnection(parts.netloc, timeout=30)


def _decode_value(value: Any) -> Any:
    if not isinstance(value, dict):
        return None
    if "stringValue" in value:
        return value["stringValue"]
    if "integerValue" in value:
        try:
            return int(value["integerValue"])
        except (TypeError, ValueError):
            return 0
    if "doubleValue" in value:
        try:
            return float(value["doubleValue"])
        except (TypeError, ValueError):
            return 0.0
    if "booleanValue" in value:
        return bool(value["booleanValue"])
    if "timestampValue" in value:
        return str(value["timestampValue"])
    if "nullValue" in value:
        return None
    if "geoPointValue" in value:
        point = value["geoPointValue"] or {}
        return {
            "latitude": point.get("latitude"),
            "longitude": point.get("longitude"),
        }
    if "mapValue" in value:
        return _decode_fields((value["mapValue"] or {}).get("fields") or {})
    if "arrayValue" in value:
        values = (value["arrayValue"] or {}).get("values") or []
        return [_decode_value(item) for item in values]
    if "referenceValue" in value:
        return str(value["referenceValue"]).rsplit("/", 1)[-1]
    if "bytesValue" in value:
        return str(value["bytesValue"])
    return None


def _decode_fields(fields: Any) -> dict[str, Any]:
    if not isinstance(fields, dict):
        return {}
    return {name: _decode_value(value) for name, value in fields.items()}


def _document_id(name: str) -> str:
    return str(name).rsplit("/", 1)[-1] if name else ""


def get_document(
    collection: str,
    doc_id: str,
    *,
    token: str,
) -> dict[str, Any] | None:
    if not token.strip():
        raise FirestoreReadError("A verified administrator token is required to read " + collection + ".")
    project = quote(config.FIREBASE_PROJECT_ID, safe="")
    url = (
        _root()
        + "/projects/" + project
        + "/databases/(default)/documents/" + quote(collection, safe="")
        + "/" + quote(doc_id, safe="")
    )
    request = UrlRequest(
        url, headers={"Authorization": "Bearer " + token.strip()}, method="GET"
    )
    try:
        with urlopen(request, timeout=30) as response:  # noqa: S310 - fixed host
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        if error.code == 404:
            return None
        raise FirestoreReadError(
            "Firestore refused the read of " + collection + "/" + doc_id
            + " (HTTP " + str(error.code) + ")."
        ) from error
    except (URLError, OSError, ValueError) as error:
        raise FirestoreReadError(
            "The " + collection + "/" + doc_id + " read failed: " + str(error)
        ) from error
    if not isinstance(payload, dict):
        raise FirestoreReadError("The " + collection + "/" + doc_id + " response was not a document.")
    return _decode_fields(payload.get("fields"))


def list_documents(
    collection: str,
    *,
    token: str,
    max_documents: int = MAX_DOCUMENTS,
) -> list[dict[str, Any]]:
    if not token.strip():
        raise FirestoreReadError("A verified administrator token is required to read " + collection + ".")
    rows: list[dict[str, Any]] = []
    page_token = ""
    headers = {"Authorization": "Bearer " + token.strip()}
    connection = _open_connection()
    try:
        while True:
            try:
                try:
                    status_code, body = _get_page(connection, collection, page_token, headers)
                except ConnectionError:
                    connection.close()
                    status_code, body = _get_page(connection, collection, page_token, headers)
            except (http.client.HTTPException, OSError) as error:
                raise FirestoreReadError(
                    "The " + collection + " read failed: " + str(error)
                ) from error
            if status_code == 404:
                return rows
            if status_code != 200:
                raise FirestoreReadError(
                    "Firestore refused the read of " + collection + " (HTTP " + str(status_code) + ")."
                )
            try:
                payload = json.loads(body.decode("utf-8"))
            except ValueError as error:
                raise FirestoreReadError(
                    "The " + collection + " read failed: " + str(error)
                ) from error
            if not isinstance(payload, dict):
                raise FirestoreReadError("The " + collection + " response was not a document list.")
            page_token = str(payload.get("nextPageToken") or "")
            for document in payload.get("documents") or []:
                if not isinstance(document, dict):
                    continue
                if len(rows) >= max_documents:
                    raise FirestoreReadError(
                        "The " + collection + " collection has more than "
                        + str(max_documents) + " documents; the read is incomplete."
                    )
                row = _decode_fields(document.get("fields"))
                row["docId"] = _document_id(str(document.get("name") or ""))
                rows.append(row)
            if not page_token:
                return rows
            if len(rows) >= max_documents:
                raise FirestoreReadError(
                    "The " + collection + " collection has more than "
                    + str(max_documents) + " documents; the read is incomplete."
                )
    finally:
        connection.close()


__all__ = [
    "FirestoreReadError",
    "INPUT_FIELD_MASKS",
    "MAX_DOCUMENTS",
    "PAGE_SIZE",
    "get_document",
    "list_documents",
]

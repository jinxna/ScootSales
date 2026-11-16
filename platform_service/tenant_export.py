from __future__ import annotations

import csv
import hashlib
import io
import json
import tempfile
import time
import zipfile
from datetime import date, datetime, timezone
from typing import IO, Any, Callable, Iterator, Mapping

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import Response, StreamingResponse
from google.cloud import firestore

from . import auth
from .company_access import CompanyAccess, require_active_admin
from .directory import DirectoryStore
from .ids import safe_cell
from .signing import format_timestamp
from .tenancy import resolve_tenant, retention_open

_COLLECTIONS = (
    "products",
    "retailers",
    "users",
    "user_access",
    "orders",
    "route_plans",
    "route_plan_progress",
    "route_stop_progress",
    "conversation_outcomes",
    "score_sheets",
    "retailer_score_sheet_settings",
)
_CHUNK = 1 << 20
NEWLINE = bytes([10])
_USER_ACCESS_FIELDS = frozenset(
    {
        "accessVersion",
        "uid",
        "userDocId",
        "role",
        "status",
        "isActive",
        "invitationState",
        "branchId",
        "supervisorUid",
        "disabledReasons",
        "employeeCode",
        "displayName",
        "email",
        "phone",
        "createdAt",
        "updatedAt",
    }
)


def _json_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, datetime):
        return format_timestamp(value)
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, bytes):
        return {"encoding": "hex", "value": value.hex()}
    if isinstance(value, firestore.GeoPoint):
        return {"latitude": value.latitude, "longitude": value.longitude}
    if isinstance(value, Mapping):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if hasattr(value, "path"):
        return {"reference": str(value.path)}
    raise ValueError(f"Unsupported export value: {type(value).__name__}")


class TenantExporter:
    def __init__(self, access: CompanyAccess, audit_db: firestore.Client, tenant_id: str) -> None:
        self.db = access.db
        self.audit_db = audit_db
        self.tenant_id = tenant_id

    def _rows(self, collection: str) -> Iterator[dict[str, Any]]:
        count = 0
        for snapshot in self.db.collection(collection).limit(10001).stream():
            count += 1
            if count > 10000:
                raise HTTPException(413, f"The {collection} export is too large for an immediate package.")
            source = snapshot.to_dict() or {}
            if collection == "user_access":
                source = {key: value for key, value in source.items() if key in _USER_ACCESS_FIELDS}
            yield {"documentId": snapshot.id, **_json_value(source)}

    def _write_collection(self, archive: zipfile.ZipFile, collection: str) -> tuple[dict[str, Any], list[str]]:
        json_hash = hashlib.sha256()
        csv_hash = hashlib.sha256()
        fields: set[str] = set()
        count = 0
        with tempfile.TemporaryFile() as spool:
            with archive.open(f"data/{collection}.json", "w", force_zip64=True) as target:
                first = b"["
                for row in self._rows(collection):
                    encoded = json.dumps(row, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
                    chunk = first + encoded
                    first = b","
                    target.write(chunk)
                    json_hash.update(chunk)
                    spool.write(encoded + NEWLINE)
                    fields.update(row)
                    count += 1
                tail = b"]" if count else b"[]"
                target.write(tail)
                json_hash.update(tail)
            names = sorted(fields)
            spool.seek(0)
            with archive.open(f"data/{collection}.csv", "w", force_zip64=True) as target:
                def emit(text: str, bom: bool = False) -> None:
                    data = text.encode("utf-8-sig" if bom else "utf-8")
                    target.write(data)
                    csv_hash.update(data)

                line = io.StringIO(newline="")
                writer = csv.DictWriter(line, fieldnames=names, extrasaction="ignore")

                def emit_row(row: Mapping[str, Any] | None) -> None:
                    line.seek(0)
                    line.truncate()
                    if row is None:
                        writer.writeheader()
                    else:
                        writer.writerow({key: safe_cell(row.get(key)) for key in names})
                    emit(line.getvalue())

                emit("", bom=True)
                if names:
                    emit_row(None)
                    for stored in spool:
                        emit_row(json.loads(stored))
        info = {"count": count, "jsonSha256": json_hash.hexdigest(), "csvSha256": csv_hash.hexdigest()}
        return info, names

    def build(self, actor: str) -> tuple[IO[bytes], str, int]:
        now = datetime.now(timezone.utc).replace(microsecond=0)
        package = tempfile.TemporaryFile()
        try:
            manifest: dict[str, Any] = {
                "schemaVersion": 1,
                "tenantId": self.tenant_id,
                "exportedAt": format_timestamp(now),
                "collections": {},
            }
            dictionary = []
            with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for collection in _COLLECTIONS:
                    info, fields = self._write_collection(archive, collection)
                    manifest["collections"][collection] = info
                    dictionary.append({"collection": collection, "fields": fields})
                archive.writestr(
                    "data-dictionary.json",
                    json.dumps(dictionary, sort_keys=True, ensure_ascii=False, indent=2).encode(),
                )
                archive.writestr(
                    "manifest.json",
                    json.dumps(manifest, sort_keys=True, ensure_ascii=False, indent=2).encode(),
                )
            size = package.tell()
            package.seek(0)
            hasher = hashlib.sha256()
            for chunk in iter(lambda: package.read(_CHUNK), b""):
                hasher.update(chunk)
            digest = hasher.hexdigest()
            package.seek(0)
            self.audit_db.collection("export_audit").document(digest).set(
                {
                    "tenantId": self.tenant_id,
                    "actorUid": actor,
                    "createdAt": now,
                    "sha256": digest,
                    "bytes": size,
                    "counts": {name: info["count"] for name, info in manifest["collections"].items()},
                }
            )
        except BaseException:
            package.close()
            raise
        return package, digest, size


def _chunks(package: IO[bytes]) -> Iterator[bytes]:
    try:
        yield from iter(lambda: package.read(_CHUNK), b"")
    finally:
        package.close()


def install_export_routes(
    app: FastAPI,
    directory: DirectoryStore,
    database: firestore.Client,
    access_for: Callable[[Mapping[str, Any]], CompanyAccess],
) -> None:
    @app.post("/v1/w/{workspace}/exports")
    def create_export(
        workspace: str,
        authorization: str | None = Header(default=None),
    ) -> Response:
        identity = auth.verify_client_token(auth.bearer_token(authorization))
        context = resolve_tenant(
            identity,
            directory,
            workspace=workspace,
            access_for=access_for,
            retained=lambda record: retention_open(access_for(record["location"]).db),
        )
        access = access_for(context.record["location"])
        row = require_active_admin(access, context.uid)
        age = time.time() - identity.auth_time
        if row.get("role") != "admin" or age < 0 or age > 300:
            raise HTTPException(403, "A recent administrator sign-in is required.")
        package, digest, size = TenantExporter(access, database, context.tenant_id).build(context.uid)
        return StreamingResponse(
            _chunks(package),
            media_type="application/zip",
            headers={
                "Cache-Control": "no-store",
                "Content-Length": str(size),
                "Content-Disposition": f'attachment; filename="scoot-export-{context.tenant_id}-{digest[:12]}.zip"',
                "X-Content-SHA256": digest,
            },
        )

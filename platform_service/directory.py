from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from google.cloud import firestore

from . import config
from .audit import EVENTS, AuditLog, event_id
from .commands import CommandProblem
from .records import RecordError, normalized_status, record_payload, validate_record, workspace_skeleton
from .signing import (
    RECORD_KIND,
    Keyring,
    SignatureError,
    Signer,
    parse_timestamp,
)

COMPANIES = "companies"
RETAINED_STATES = frozenset({"suspended", "expired", "cancelled"})
_RECORD_META = frozenset({"kind", "version", "issuedAt", "expiresAt"})
_ANY = object()
CLAIMS = "company_claims"
DIRECTORY_READ_TIMEOUT_SECONDS = 5.0
ONBOARDING_CLAIMS = "onboarding_claims"
SETUP_DRAFTS = "onboarding_drafts"
_ENVELOPE_FIELDS = ("alg", "keyId", "payload", "signature")
_BILLING_EMAIL = re.compile(r"^[^\s@<>]{1,64}@[^\s@<>.]+(?:\.[^\s@<>.]+)+$")


def clean_billing_email(email: Any) -> str | None:
    if email is None:
        return None
    if not isinstance(email, str) or len(email) > 254:
        raise RecordError("Invalid billingEmail.")
    value = email.strip().lower()
    if not _BILLING_EMAIL.fullmatch(value):
        raise RecordError("Invalid billingEmail.")
    return value


class DirectoryError(Exception):
    pass


def location_key(location: Mapping[str, Any]) -> str:
    return "|".join(
        (
            location["projectId"],
            location["databaseId"],
            location["authTenantId"] or "-",
        )
    )


def auth_key(project_id: str, auth_tenant_id: str | None) -> str:
    return f"{project_id}|{auth_tenant_id or '-'}"


def _claims_for(record: Mapping[str, Any]) -> list[str]:
    workspace = record["workspace"]
    location = record["location"]
    return [
        f"workspace:{workspace}",
        f"skeleton:{workspace_skeleton(workspace)}",
        f"code:{record['companyCode']}",
        f"location:{location_key(location)}",
        f"auth:{auth_key(location['projectId'], location['authTenantId'])}",
        f"project:{location['projectId']}",
    ]


def _envelope(data: Mapping[str, Any]) -> dict[str, Any]:
    return {field: data.get(field) for field in _ENVELOPE_FIELDS}


def _index_version(data: Mapping[str, Any]) -> int:
    version = data.get("version")
    if isinstance(version, bool) or not isinstance(version, int) or version < 0:
        raise DirectoryError("Stored record has no valid version.")
    return version


class DirectoryStore:
    def __init__(
        self,
        client: firestore.Client,
        *,
        keyring: Keyring,
        signer: Signer | None = None,
        record_ttl: timedelta | None = None,
    ) -> None:
        self.client = client
        self.keyring = keyring
        self.signer = signer
        self.record_ttl = record_ttl or timedelta(days=config.RECORD_TTL_DAYS)

    def _verify(
        self,
        data: Mapping[str, Any],
        tenant_id: str,
        *,
        allow_expired: bool = False,
    ) -> dict[str, Any]:
        envelope = _envelope(data)
        floor = _index_version(data)
        now = None
        if allow_expired:
            try:
                now = parse_timestamp(json.loads(envelope["payload"])["issuedAt"])
            except (TypeError, ValueError, LookupError) as error:
                raise DirectoryError("Stored record is not valid.") from error
        try:
            payload = self.keyring.verify(
                envelope, kind=RECORD_KIND, min_version=floor, now=now
            )
        except SignatureError as error:
            raise DirectoryError(f"Stored record failed verification: {error}") from error
        if payload.get("tenantId") != tenant_id or payload.get("workspace") != data.get(
            "workspace"
        ):
            raise DirectoryError("Stored record does not match its index.")
        return {**payload, "status": normalized_status(payload.get("status"))}

    def put(
        self,
        record: Mapping[str, Any],
        *,
        expected_version: int,
        now: datetime | None = None,
        draft_id: str | None = None,
        setup_key: str | None = None,
    ) -> dict[str, Any]:
        if self.signer is None:
            raise DirectoryError("Signing needs a signer.")
        if (
            isinstance(expected_version, bool)
            or not isinstance(expected_version, int)
            or expected_version < 0
        ):
            raise DirectoryError("expected_version must be a non-negative integer.")
        normalized = validate_record(record, new=expected_version == 0)
        moment = now or datetime.now(timezone.utc)
        tenant_id = normalized["tenantId"]
        new_version = expected_version + 1
        payload = record_payload(
            normalized, version=new_version, issued_at=moment, ttl=self.record_ttl
        )
        envelope = self.signer.sign(payload)
        try:
            self.keyring.verify(
                envelope, kind=RECORD_KIND, min_version=new_version, now=moment
            )
        except SignatureError as error:
            raise DirectoryError(f"The signing key is not in the keyring: {error}") from error

        doc_ref = self.client.collection(COMPANIES).document(tenant_id)
        new_claims = _claims_for(normalized)
        released = set(new_claims[3:]) if normalized["status"] == "deleted" else set()
        kept: dict[str, Any] = {}

        @firestore.transactional
        def run(transaction: firestore.Transaction) -> None:
            snapshot = doc_ref.get(transaction=transaction)
            stored_version = 0
            previous_project: str | None = None
            old_claims: list[str] = []
            data: dict[str, Any] = {}
            if snapshot.exists:
                data = snapshot.to_dict() or {}
                stored_version = _index_version(data)
            if expected_version != stored_version:
                raise DirectoryError("stale version")
            if snapshot.exists:
                stored = self._verify(data, tenant_id, allow_expired=True)
                if stored["location"] != normalized["location"] and stored["status"] != "lead":
                    raise DirectoryError("Location changes need two-person approval.")
                previous_project = stored["location"]["projectId"]
                old_claims = _claims_for(stored)
                for field in ("billingEmail", "onboardingDraftId"):
                    if data.get(field) is not None:
                        kept[field] = data[field]
            claim_refs = {
                claim: self.client.collection(CLAIMS).document(claim)
                for claim in {*new_claims, *old_claims}
            }
            held = {
                claim: ref.get(transaction=transaction)
                for claim, ref in claim_refs.items()
            }
            project_claim = new_claims[-1]
            holding = [claim for claim in new_claims if claim not in released]
            project_changed = previous_project != normalized["location"]["projectId"]
            shared_project = False
            for claim in holding:
                snap = held[claim]
                if snap.exists and (snap.to_dict() or {}).get("tenantId") != tenant_id:
                    if claim == project_claim and expected_version > 0 and not project_changed:
                        shared_project = True
                        continue
                    raise DirectoryError(f"Already claimed by another company: {claim}")
            if project_claim in holding and (expected_version == 0 or project_changed):
                other = self.project_holder(normalized["location"]["projectId"], transaction=transaction)
                if other is not None and other != tenant_id:
                    raise DirectoryError(f"Already claimed by another company: {project_claim}")
            if expected_version == 0 and draft_id:
                draft = self.client.collection(SETUP_DRAFTS).document(draft_id).get(transaction=transaction).to_dict() or {}
                if (draft.get("status") != "completing" or draft.get("completingTenant") != tenant_id
                        or (setup_key is not None and draft.get("completingKey") != setup_key)):
                    raise DirectoryError("This draft is no longer being set up with this request.")
            if expected_version == 0:
                for claim in new_claims[:2]:
                    draft_claim = self.client.collection(ONBOARDING_CLAIMS).document(claim).get(
                        transaction=transaction)
                    if draft_claim.exists and (draft_claim.to_dict() or {}).get("draftId") != draft_id:
                        raise DirectoryError(f"Already claimed by another company: {claim}")
            for claim in old_claims:
                snap = held[claim]
                if (
                    claim not in holding
                    and snap.exists
                    and (snap.to_dict() or {}).get("tenantId") == tenant_id
                ):
                    transaction.delete(claim_refs[claim])
            for claim in holding:
                if claim == project_claim and shared_project:
                    continue
                transaction.set(claim_refs[claim], {"tenantId": tenant_id})
            transaction.set(
                doc_ref,
                {
                    **envelope,
                    **kept,
                    "workspace": normalized["workspace"],
                    "companyCode": normalized["companyCode"],
                    "locationKey": location_key(normalized["location"]),
                    "status": normalized["status"],
                    "version": new_version,
                    "updatedAt": moment,
                },
            )

        run(self.client.transaction(max_attempts=10))
        return envelope

    def project_holder(self, project_id: str, *, transaction: firestore.Transaction | None = None) -> str | None:
        claims = self.client.collection(CLAIMS)
        marker = claims.document(f"project:{project_id}")
        snapshot = marker.get(transaction=transaction) if transaction is not None else marker.get()
        holder = (snapshot.to_dict() or {}).get("tenantId") if snapshot.exists else None
        if holder:
            return holder
        document_id = "__name__"
        query = (claims.where(filter=firestore.FieldFilter(document_id, ">=", claims.document(f"location:{project_id}|")))
                 .where(filter=firestore.FieldFilter(document_id, "<", claims.document(f"location:{project_id}}}"))))
        for row in query.stream(transaction=transaction):
            return (row.to_dict() or {}).get("tenantId")
        return None

    def set_billing_email(self, tenant_id: str, email: str | None, *, audit: AuditLog | None = None,
                          actor: str | None = None, key: str | None = None,
                          expected_previous: Any = _ANY, summary: str = "Billing email changed.",
                          seal: Callable[[firestore.Transaction], None] | None = None) -> str | None:
        value = clean_billing_email(email)
        doc_ref = self.client.collection(COMPANIES).document(tenant_id)

        @firestore.transactional
        def run(transaction: firestore.Transaction) -> None:
            snapshot = doc_ref.get(transaction=transaction)
            if not snapshot.exists:
                raise DirectoryError("Unknown company.")
            stored = (snapshot.to_dict() or {}).get("billingEmail")
            current = stored if isinstance(stored, str) and stored.strip() else None
            if expected_previous is not _ANY and current != expected_previous and current != value:
                raise CommandProblem("The billing email changed since this was requested. Send a new request.")
            event_key = key or f"billing-email:{tenant_id}"
            if audit is not None and audit.client.collection(EVENTS).document(
                    event_id("billing_email.changed", event_key)).get(transaction=transaction).exists:
                return
            staged = audit.stage(transaction, tenant_id=tenant_id) if audit is not None else None
            transaction.update(doc_ref, {"billingEmail": firestore.DELETE_FIELD if value is None else value})
            if staged is not None:
                staged.add(actor=actor or "system", action="billing_email.changed", tenant_id=tenant_id,
                           key=event_key, summary=summary,
                           refs={"cleared": "yes" if value is None else None})
            if seal is not None:
                seal(transaction)

        run(self.client.transaction(max_attempts=10))
        return value

    def billing_email(self, tenant_id: str) -> str | None:
        snapshot = self.client.collection(COMPANIES).document(tenant_id).get()
        if not snapshot.exists:
            raise DirectoryError("Unknown company.")
        email = (snapshot.to_dict() or {}).get("billingEmail")
        return email if isinstance(email, str) and email.strip() else None

    def get(self, tenant_id: str) -> dict[str, Any] | None:
        snapshot = self.client.collection(COMPANIES).document(tenant_id).get(retry=None, timeout=DIRECTORY_READ_TIMEOUT_SECONDS)
        if not snapshot.exists:
            return None
        return self.from_snapshot(snapshot)

    def from_snapshot(self, snapshot: Any) -> dict[str, Any]:
        return self._verify(snapshot.to_dict() or {}, snapshot.id)

    def _claimed_tenant(self, claim: str) -> str | None:
        snapshot = self.client.collection(CLAIMS).document(claim).get(retry=None, timeout=DIRECTORY_READ_TIMEOUT_SECONDS)
        if not snapshot.exists:
            return None
        tenant_id = (snapshot.to_dict() or {}).get("tenantId")
        if not isinstance(tenant_id, str) or not tenant_id:
            raise DirectoryError("Claim is not valid.")
        return tenant_id

    def find_by_workspace(self, workspace: str) -> dict[str, Any] | None:
        tenant_id = self._claimed_tenant(f"workspace:{workspace}")
        payload = self.get(tenant_id) if tenant_id is not None else None
        if payload is not None and payload["workspace"] != workspace:
            raise DirectoryError("Claim does not match the stored record.")
        return payload

    def get_envelope_by_code(self, code: str) -> dict[str, Any] | None:
        tenant_id = self._claimed_tenant(f"code:{code}")
        if tenant_id is None:
            return None
        snapshot = self.client.collection(COMPANIES).document(tenant_id).get(retry=None, timeout=DIRECTORY_READ_TIMEOUT_SECONDS)
        if not snapshot.exists:
            return None
        data = snapshot.to_dict() or {}
        payload = self._verify(data, tenant_id)
        if payload["companyCode"] != code:
            raise DirectoryError("Company code claim does not match the signed record.")
        if payload["status"] in {"lead", "deleted"}:
            return None
        return _envelope(data)

    def lifecycle_state(self, tenant_id: str) -> str | None:
        snapshot = self.client.collection("lifecycle").document(tenant_id).get(retry=None, timeout=DIRECTORY_READ_TIMEOUT_SECONDS)
        state = (snapshot.to_dict() or {}).get("state") if snapshot.exists else None
        return state if isinstance(state, str) else None

    def find_by_location(
        self,
        project_id: str,
        database_id: str = "(default)",
        auth_tenant_id: str | None = None,
    ) -> dict[str, Any] | None:
        key = location_key(
            {
                "projectId": project_id,
                "databaseId": database_id,
                "authTenantId": auth_tenant_id,
            }
        )
        tenant_id = self._claimed_tenant(f"location:{key}")
        if tenant_id is None:
            return None
        payload = self.get(tenant_id)
        if payload is None or location_key(payload["location"]) != key:
            raise DirectoryError("Claim does not match the stored record.")
        return payload

    def find_by_auth(
        self, project_id: str, auth_tenant_id: str | None
    ) -> dict[str, Any] | None:
        key = auth_key(project_id, auth_tenant_id)
        tenant_id = self._claimed_tenant(f"auth:{key}")
        if tenant_id is None:
            return None
        payload = self.get(tenant_id)
        location = payload["location"] if payload else None
        if location is None or auth_key(location["projectId"], location["authTenantId"]) != key:
            raise DirectoryError("Claim does not match the stored record.")
        return payload

    def list_records(self, now: datetime | None = None) -> list[dict[str, Any]]:
        return [record for record, _ in self._listed(now)]

    def list_records_with_billing(self, now: datetime | None = None) -> list[dict[str, Any]]:
        return [{**record, "billingEmail": billing} for record, billing in self._listed(now)]

    def _listed(self, now: datetime | None) -> list[tuple[dict[str, Any], Any]]:
        moment = now or datetime.now(timezone.utc)
        records = []
        for snapshot in self.client.collection(COMPANIES).stream():
            data = snapshot.to_dict() or {}
            payload = self._verify(data, snapshot.id, allow_expired=True)
            records.append(({**payload, "expired": moment >= parse_timestamp(payload["expiresAt"])},
                            data.get("billingEmail")))
        return sorted(records, key=lambda row: row[0]["workspace"])


def _keeps_record(directory: DirectoryStore, payload: Mapping[str, Any], now: datetime) -> bool:
    if payload["status"] == "deleted":
        return False
    lifecycle = directory.client.collection("lifecycle").document(payload["tenantId"]).get().to_dict() or {}
    if lifecycle.get("state") not in RETAINED_STATES:
        return True
    retention = lifecycle.get("retentionEndsAt")
    return isinstance(retention, datetime) and retention > now


def renew_directory_records(directory: DirectoryStore, *, now: datetime | None = None,
                            within: timedelta | None = None,
                            tenant_ids: list[str] | None = None) -> dict[str, list[str]]:
    moment = now or datetime.now(timezone.utc)
    window = within or timedelta(days=config.RECORD_RENEW_WITHIN_DAYS)
    companies = directory.client.collection(COMPANIES)
    snapshots = (companies.stream() if tenant_ids is None
                 else [companies.document(tenant_id).get() for tenant_id in dict.fromkeys(tenant_ids)])
    renewed: list[str] = []
    failed: list[str] = []
    for snapshot in snapshots:
        if not snapshot.exists:
            failed.append(snapshot.id)
            continue
        try:
            payload = directory._verify(snapshot.to_dict() or {}, snapshot.id, allow_expired=True)
            if tenant_ids is None and (parse_timestamp(payload["expiresAt"]) - moment > window
                                       or not _keeps_record(directory, payload, moment)):
                continue
            record = {key: value for key, value in payload.items() if key not in _RECORD_META}
            directory.put(record, expected_version=payload["version"], now=moment)
            renewed.append(snapshot.id)
        except DirectoryError as error:
            if str(error) != "stale version":
                failed.append(snapshot.id)
        except (RecordError, ValueError, KeyError):
            failed.append(snapshot.id)
    return {"renewed": renewed, "failed": failed}

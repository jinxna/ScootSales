from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import date, datetime, timedelta
from typing import Any, Callable, Mapping

from google.cloud import firestore

from .ids import bad, local_date, utc_now
from .signing import format_timestamp

EVENTS = "audit_events"
CHAIN = "audit_chain"
DIGESTS = "audit_digests"
STARTS = "audit_chain_starts"
PLATFORM_CHAIN = "platform"
ALL_CHAINS = "*"
CHAIN_NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
GENESIS = "0" * 64
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MAX_REFS = 12
MAX_EXPORT_DAYS = 92
DEFAULT_LIST_DAYS = 14
EVENT_FIELDS = ("eventId", "seq", "at", "day", "actor", "action", "tenantId", "summary", "refs", "prevHash",
                "hash", "chain")


def chain_of(tenant_id: str | None) -> str:
    return tenant_id or PLATFORM_CHAIN


def chain_doc_id(day: str, chain: str | None) -> str:
    return day if chain is None else f"{day}_{chain}"


def check_chain(value: Any) -> str:
    if not isinstance(value, str) or not CHAIN_NAME.fullmatch(value):
        raise bad("chain must be a company ID or platform.")
    return value


def canonical(value: Mapping[str, Any]) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def event_hash(event: Mapping[str, Any]) -> str:
    body = {key: value for key, value in event.items() if key != "hash"}
    return hashlib.sha256(canonical(body).encode("utf-8")).hexdigest()


def event_id(action: str, key: str) -> str:
    return "evt_" + hashlib.sha256(f"{action}\n{key}".encode("utf-8")).hexdigest()[:32]


def action_group(action: str) -> str:
    return action.split(".", 1)[0]


def check_day(value: Any, name: str = "day") -> str:
    if not isinstance(value, str) or not DAY.fullmatch(value):
        raise bad(f"{name} must look like 2026-12-31.")
    try:
        date.fromisoformat(value)
    except ValueError:
        raise bad(f"{name} must look like 2026-12-31.") from None
    return value


def _refs(value: Mapping[str, Any] | None) -> dict[str, str]:
    refs = {str(key)[:40]: str(item)[:200] for key, item in (value or {}).items() if item is not None}
    if len(refs) > MAX_REFS:
        raise ValueError("An audit event has too many references.")
    return refs


def _view(event: Mapping[str, Any]) -> dict[str, Any]:
    return {name: event.get(name) for name in EVENT_FIELDS}


class Stage:
    def __init__(self, log: "AuditLog", transaction: firestore.Transaction, day: str, at: str,
                 head_ref: Any, count: int, last_hash: str, seed: str, chain: str) -> None:
        self.log = log
        self.chain = chain
        self.transaction = transaction
        self.day = day
        self.at = at
        self.head_ref = head_ref
        self.count = count
        self.last_hash = last_hash
        self.seed = seed

    def add(self, *, actor: str, action: str, tenant_id: str | None, summary: str, key: str,
            refs: Mapping[str, Any] | None = None) -> dict[str, Any]:
        identifier = event_id(action, key)
        seq = self.count + 1
        event = {"eventId": identifier, "seq": seq, "at": self.at, "day": self.day,
                 "actor": str(actor)[:254], "action": action, "tenantId": tenant_id,
                 "summary": str(summary)[:300], "refs": _refs(refs), "prevHash": self.last_hash,
                 "chain": self.chain}
        event["hash"] = event_hash(event)
        self.transaction.create(self.log.client.collection(EVENTS).document(identifier), event)
        self.transaction.set(self.head_ref, {"day": self.day, "chain": self.chain, "count": seq, "lastEventId": identifier,
                                             "lastHash": event["hash"], "seedHash": self.seed,
                                             "updatedAt": self.at})
        self.count, self.last_hash = seq, event["hash"]
        return event


class AuditLog:
    def __init__(self, client: firestore.Client, *, clock: Callable[[], datetime] = utc_now) -> None:
        self.client = client
        self.clock = clock

    def stage(self, transaction: firestore.Transaction, at: datetime | None = None, *,
              tenant_id: str | None = None) -> Stage:
        moment = at if at is not None else self.clock()
        day = local_date(moment)
        chain = chain_of(tenant_id)
        head_ref = self.client.collection(CHAIN).document(chain_doc_id(day, chain))
        head = head_ref.get(transaction=transaction)
        if head.exists:
            data = head.to_dict() or {}
            return Stage(self, transaction, day, format_timestamp(moment), head_ref, data.get("count", 0),
                         data.get("lastHash", GENESIS), data.get("seedHash", GENESIS), chain)
        seed = self.previous_seal(day, chain, transaction)
        return Stage(self, transaction, day, format_timestamp(moment), head_ref, 0, seed, seed, chain)

    def previous_seal(self, day: str, chain: str | None = None,
                      transaction: firestore.Transaction | None = None) -> str:
        before = chain_doc_id((date.fromisoformat(day) - timedelta(days=1)).isoformat(), chain)
        digest = self.client.collection(DIGESTS).document(before).get(transaction=transaction)
        sealed = (digest.to_dict() or {}).get("headHash") if digest.exists else None
        if sealed:
            return sealed
        head = self.client.collection(CHAIN).document(before).get(transaction=transaction)
        if head.exists:
            return (head.to_dict() or {}).get("lastHash", GENESIS)
        if chain is None:
            return GENESIS
        start = self.client.collection(STARTS).document(chain).get(transaction=transaction)
        start_data = (start.to_dict() or {}) if start.exists else {}
        return start_data.get("seedHash", GENESIS) if start_data.get("fromDay") == day else GENESIS

    def record(self, *, actor: str, action: str, tenant_id: str | None, summary: str, key: str,
               refs: Mapping[str, Any] | None = None, at: datetime | None = None) -> dict[str, Any]:
        reference = self.client.collection(EVENTS).document(event_id(action, key))

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            existing = reference.get(transaction=transaction)
            if existing.exists:
                return existing.to_dict() or {}
            return self.stage(transaction, at, tenant_id=tenant_id).add(actor=actor, action=action, tenant_id=tenant_id,
                                                   summary=summary, key=key, refs=refs)

        return write(self.client.transaction(max_attempts=10))

    def day_events(self, day: str, chain: str | None = ALL_CHAINS) -> list[dict[str, Any]]:
        rows = [snapshot.to_dict() or {} for snapshot in self.client.collection(EVENTS).where(
            filter=firestore.FieldFilter("day", "==", day)).stream()]
        if chain != ALL_CHAINS:
            rows = [row for row in rows if row.get("chain") == chain]
        return sorted(rows, key=lambda row: (row.get("seq") if type(row.get("seq")) is int else 0,
                                             str(row.get("eventId"))))

    def query(self, *, since: str, until: str, actor: str | None = None, group: str | None = None,
              tenant_id: str | None = None) -> list[dict[str, Any]]:
        rows = [snapshot.to_dict() or {} for snapshot in self.client.collection(EVENTS).where(
            filter=firestore.FieldFilter("day", ">=", since)).where(
            filter=firestore.FieldFilter("day", "<=", until)).stream()]
        rows = [row for row in rows
                if (actor is None or row.get("actor") == actor)
                and (group is None or action_group(str(row.get("action"))) == group)
                and (tenant_id is None or row.get("tenantId") == tenant_id)]
        return sorted(rows, key=lambda row: (str(row.get("day")), str(row.get("at")), row.get("seq") or 0),
                      reverse=True)

    def day_chains(self, day: str) -> list[str | None]:
        chains: set[str | None] = {(snapshot.to_dict() or {}).get("chain") for snapshot in
                                   self.client.collection(CHAIN).where(
                                       filter=firestore.FieldFilter("day", "==", day)).stream()}
        if self.client.collection(CHAIN).document(day).get().exists:
            chains.add(None)
        chains.update(row.get("chain") for row in self.day_events(day))
        return sorted(chains, key=lambda chain: (chain is not None, chain or ""))

    def verify_day(self, day: str) -> dict[str, Any]:
        check_day(day)
        results = [self.verify(day, chain) for chain in self.day_chains(day)]
        failed = next((result for result in results if not result["ok"]), None)
        return {"day": day, "ok": failed is None, "events": sum(result["events"] for result in results),
                "headHash": results[0]["headHash"] if failed is None and len(results) == 1 else None,
                "firstBroken": failed["firstBroken"] if failed is not None else None,
                "chains": [{name: result[name] for name in ("chain", "ok", "events", "headHash", "firstBroken")}
                           for result in results]}

    def verify(self, day: str, chain: str | None = ALL_CHAINS) -> dict[str, Any]:
        if chain == ALL_CHAINS:
            return self.verify_day(day)
        check_day(day)
        head_ref = self.client.collection(CHAIN).document(chain_doc_id(day, chain))
        for _ in range(3):
            head = head_ref.get()
            head_data = (head.to_dict() or {}) if head.exists else {}
            expected = head_data.get("count", 0)
            everything = self.day_events(day, chain)
            if len(everything) <= expected:
                break
        events = everything[:expected]
        digest = self.client.collection(DIGESTS).document(chain_doc_id(day, chain)).get()
        digest_data = (digest.to_dict() or {}) if digest.exists else {}
        previous = head_data.get("seedHash", GENESIS)

        def broken(position: int, event_ref: str | None, reason: str) -> dict[str, Any]:
            return {"day": day, "chain": chain, "ok": False, "events": len(events), "headHash": None,
                    "firstBroken": {"seq": position, "eventId": event_ref, "reason": reason, "chain": chain}}

        if not head.exists and everything:
            if chain is None:
                return broken(1, everything[0].get("eventId"),
                              "The day holds events that the chain does not count.")
            return broken(1, everything[0].get("eventId"), "The day's chain head is missing.")
        if len(everything) > expected:
            return broken(expected + 1, everything[expected].get("eventId"),
                          "The day holds events that the chain does not count.")
        if previous != self.previous_seal(day, chain):
            return broken(1, None, "The day does not continue from the previous day.")
        for index, event in enumerate(events, start=1):
            if event_hash(event) != event.get("hash"):
                return broken(index, event.get("eventId"), "The event content does not match its hash.")
            if event.get("prevHash") != previous:
                return broken(index, event.get("eventId"), "The link to the previous event is broken.")
            if event.get("seq") != index or event.get("day") != day:
                return broken(index, event.get("eventId"), "The event is out of sequence.")
            previous = event["hash"]
        if expected != len(events) or head_data.get("lastHash", previous) != previous:
            return broken(len(events) + 1, head_data.get("lastEventId"),
                          "Events at the end of the day are missing.")
        if digest_data and (digest_data.get("count") != expected or digest_data.get("headHash") != previous):
            return broken(len(events) + 1, None, "The day's digest does not match the events.")
        return {"day": day, "chain": chain, "ok": True, "events": len(events), "headHash": previous,
                "firstBroken": None}

    def write_digest(self, day: str, chain: str | None = None) -> dict[str, Any]:
        result = self.verify(day, chain)
        reference = self.client.collection(DIGESTS).document(chain_doc_id(day, chain))

        @firestore.transactional
        def write(transaction: firestore.Transaction) -> dict[str, Any]:
            existing = reference.get(transaction=transaction)
            if existing.exists:
                return existing.to_dict() or {}
            digest = {"day": day, "chain": chain, "count": result["events"], "headHash": result["headHash"],
                      "ok": result["ok"], "writtenAt": format_timestamp(self.clock())}
            transaction.create(reference, digest)
            return digest

        return write(self.client.transaction(max_attempts=10))

    def days_without_digest(self, today: str) -> list[tuple[str, str | None]]:
        heads = set()
        for snapshot in self.client.collection(CHAIN).stream():
            data = snapshot.to_dict() or {}
            heads.add((data.get("day") or snapshot.id, data.get("chain")))
        done = {snapshot.id for snapshot in self.client.collection(DIGESTS).stream()}
        return sorted((pair for pair in heads if chain_doc_id(*pair) not in done and pair[0] < today),
                      key=lambda pair: (pair[0], pair[1] is not None, pair[1] or ""))

    def run_digests(self) -> dict[str, Any]:
        written = 0
        broken: list[str] = []
        for day, chain in self.days_without_digest(local_date(self.clock())):
            if not self.write_digest(day, chain).get("ok"):
                broken.append(day if chain is None else f"{day} {chain}")
            written += 1
        return {"written": written, "broken": broken}


def default_range(since: str | None, until: str | None, *, now: datetime) -> tuple[str, str]:
    end = check_day(until, "to") if until is not None else local_date(now)
    start = check_day(since, "from") if since is not None else (
        date.fromisoformat(end) - timedelta(days=DEFAULT_LIST_DAYS - 1)).isoformat()
    if start > end:
        raise bad("from must not be after to.")
    if (date.fromisoformat(end) - date.fromisoformat(start)).days >= MAX_EXPORT_DAYS:
        raise bad(f"Choose at most {MAX_EXPORT_DAYS} days.")
    return start, end


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m platform_service.audit")
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify", help="Recompute one day's audit chain.")
    verify.add_argument("--day", required=True, help="Kuala Lumpur date, YYYY-MM-DD.")
    verify.add_argument("--chain", help="One company ID or platform. Leave out to check every chain of the day.")
    args = parser.parse_args(argv)
    from . import config

    client = firestore.Client(project=config.PLATFORM_PROJECT_ID)
    try:
        result = AuditLog(client).verify(args.day, check_chain(args.chain) if args.chain else ALL_CHAINS)
    except Exception as error:
        print(json.dumps({"ok": False, "error": getattr(error, "detail", str(error))}))
        return 2
    print(json.dumps(result))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import argparse
import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Protocol, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from forecasting.ai_core.calendar import week_start

from scripts.ai_simulation.cli import _append, _client, _encode, _exclusive, journal_path, write_json
from scripts.ai_simulation.inputs import (
    SimulationError,
    assign_areas,
    canonical,
    company_from_collections,
    load_export,
    load_roster,
    not_active_shops,
    people_by_uid,
    resolve_team,
    simulated_shops,
    text,
)
from scripts.ai_simulation.simulate import Settings
from scripts.ai_simulation.staff_plan import (
    LEGACY_ASSIGNMENT_FIELDS,
    ROSTER_CONFLICT_WHY,
    roster_conflicts,
    staff_move_plan,
    step_done,
)

PATCH_FORMAT = 1
SERVER_TIME = "$serverTimestamp"
ASSIGNMENT_FIELD = "assignedSalesmanId"
SHOP_UPDATED_FIELD = "updatedAt"
ROUTE_START_FIELDS = ("routeStartName", "routeStartLat", "routeStartLng")
ROSTER_FIELD = "assignedSalesmanCodes"
ABSENT = {"$absent": True}
REMOVE_CODES = "removeCodes"
CHECK_BY_HAND = "check_by_hand"
UNPROVEN_WHY = "an earlier run recorded the intent of this write but not its commit: check this record by hand"


def assignment_payload(code: str) -> tuple[dict[str, Any], list[str]]:
    return {ASSIGNMENT_FIELD: code.strip(), SHOP_UPDATED_FIELD: SERVER_TIME}, list(LEGACY_ASSIGNMENT_FIELDS)


class PatchStore(Protocol):
    def read(self, path: str) -> tuple[Mapping[str, Any], Any] | None: ...

    def update_unit(self, changes: Mapping[str, tuple[Any, Mapping[str, Any], Sequence[str]]]) -> dict[str, Any] | None: ...


class FirestorePatchStore:
    def __init__(self, db: Any):
        self.db = db

    def read(self, path: str) -> tuple[Mapping[str, Any], Any] | None:
        snapshot = self.db.document(path).get()
        return (snapshot.to_dict() or {}, snapshot.update_time) if snapshot.exists else None

    def update_unit(self, changes: Mapping[str, tuple[Any, Mapping[str, Any], Sequence[str]]]) -> dict[str, Any] | None:
        from google.api_core.exceptions import FailedPrecondition, NotFound
        from google.cloud import firestore

        batch = self.db.batch()
        for path, (expected, values, removed) in changes.items():
            payload = {
                key: firestore.SERVER_TIMESTAMP if value == SERVER_TIME else value for key, value in values.items()
            }
            payload.update({key: firestore.DELETE_FIELD for key in removed if key not in values})
            batch.update(self.db.document(path), payload, option=self.db.write_option(last_update_time=expected))
        try:
            results = batch.commit()
        except (FailedPrecondition, NotFound):
            return None
        return {path: result.update_time for path, result in zip(changes, results)}


def _decode(value: Any) -> Any:
    from platform_service.tenant_snapshot import decode

    return decode(value, None)


def touched(change: Mapping[str, Any]) -> list[str]:
    return sorted({*change["set"], *change["delete"]})


def field_state(data: Mapping[str, Any], fields: Iterable[str]) -> dict[str, Any]:
    return {name: _encode(data[name]) if name in data else ABSENT for name in fields}


def target_state(change: Mapping[str, Any]) -> dict[str, Any]:
    state = {name: ABSENT for name in change["delete"]}
    state.update({name: _encode(value) for name, value in change["set"].items() if value != SERVER_TIME})
    return state


def reached(data: Mapping[str, Any], change: Mapping[str, Any]) -> bool:
    wanted = target_state(change)
    return field_state(data, wanted) == wanted


def shop_changes(export: Path, roster: Path) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    company = load_export(export)
    team = resolve_team(company, load_roster(roster))
    shops = simulated_shops(company, team, Settings(week_start(datetime.now(timezone.utc)), week_start(datetime.now(timezone.utc))).shops_per_salesperson)
    owners = assign_areas(shops, team)
    units = []
    for path, person in sorted((f"retailers/{key}", person) for key, person in owners.items()):
        values, removed = assignment_payload(person.code)
        units.append({"unit": path, "changes": [{"path": path, "set": values, "delete": removed}]})
    return units, not_active_shops(shops, owners)


def start_point_changes(branch: str, name: str, lat: float, lng: float) -> list[dict[str, Any]]:
    if not name.strip() or not -90 <= lat <= 90 or not -180 <= lng <= 180:
        raise SimulationError("The start point needs a name, a latitude from -90 to 90 and a longitude from -180 to 180.")
    path = f"branches/{branch}"
    values = dict(zip(ROUTE_START_FIELDS, (name.strip(), float(lat), float(lng))))
    return [{"unit": path, "changes": [{"path": path, "set": values, "delete": []}]}]


def roster_clear_changes(
    store: PatchStore, users_doc: str, uid: str, codes: Sequence[str], *, user_codes: Iterable[str],
) -> list[dict[str, Any]]:
    gone = {canonical(code) for code in codes if canonical(code)}
    if not gone:
        raise SimulationError("Name at least one roster code to clear.")
    holders = {canonical(held): held for held in user_codes}
    held = sorted({holders[canonical(code)] for code in codes if canonical(code) in holders})
    if held:
        raise SimulationError(
            f"{', '.join(held)} is the employee code of a user record. Only codes that no users or user_access "
            "record holds can be cleared, whatever the record's status. Nothing was changed."
        )
    changes = []
    for path in (f"users/{users_doc}", f"user_access/{uid}"):
        found = store.read(path)
        if found is None:
            raise SimulationError(f"{path} does not exist. Nothing was changed.")
        data = found[0]
        if data.get("role") not in (None, "supervisor"):
            raise SimulationError(f"{path} is not a supervisor record. Nothing was changed.")
        if not isinstance(data.get(ROSTER_FIELD), list):
            raise SimulationError(f"{path} has no roster list. Nothing was changed.")
        changes.append({"path": path, REMOVE_CODES: sorted(gone)})
    return [{"unit": f"roster-clear/{uid}", "changes": changes}]


def resolved(change: Mapping[str, Any], data: Mapping[str, Any]) -> dict[str, Any]:
    if REMOVE_CODES not in change:
        return dict(change)
    roster = data.get(ROSTER_FIELD)
    if not isinstance(roster, list):
        raise SimulationError(f"{change['path']} has no roster list. Nothing was changed.")
    gone = set(change[REMOVE_CODES])
    kept = [code for code in roster if canonical(code) not in gone]
    return {"path": change["path"], "set": {ROSTER_FIELD: kept}, "delete": []}


def read_entries(path: Path) -> tuple[dict[str, Any] | None, dict[str, dict[str, Any]]]:
    if not path.exists():
        return None, {}
    header = None
    units: dict[str, dict[str, Any]] = {}
    for line in path.read_text(encoding="utf-8").split("\n"):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            break
        if row["t"] == "header":
            header = row
        else:
            units.setdefault(row["unit"], {}).update(row)
    return header, units


def apply_patch(
    store: PatchStore, kind: str, project: str, units: Sequence[Mapping[str, Any]], journal: Path,
) -> dict[str, Any]:
    with _exclusive(journal):
        header, done = read_entries(journal)
        if header is not None and (header["kind"] != kind or header["project"] != project):
            raise SimulationError(f"The journal {journal} belongs to another command or project. Nothing was changed.")
        rows = []
        with journal.open("a", encoding="utf-8") as handle:
            if header is None:
                header = {"t": "header", "format": PATCH_FORMAT, "kind": kind, "project": project, "runId": uuid.uuid4().hex}
                _append(handle, header)
            for unit in units:
                name = unit["unit"]
                entry = done.get(name, {})
                found = {change["path"]: store.read(change["path"]) for change in unit["changes"]}
                missing = [path for path, value in found.items() if value is None]
                if missing:
                    rows.append({"unit": name, "status": "missing", "paths": missing})
                    continue
                if entry.get("status") == "written":
                    rows.append({**_public(entry), "status": "written"})
                    continue
                if entry.get("status") == "intent":
                    rows.append({**_public(entry), "status": CHECK_BY_HAND, "why": UNPROVEN_WHY})
                    continue
                changes = [resolved(change, found[change["path"]][0]) for change in unit["changes"]]
                if all(reached(found[change["path"]][0], change) for change in changes):
                    rows.append({"unit": name, "status": "unchanged", "changes": changes})
                    continue
                before = {change["path"]: field_state(found[change["path"]][0], touched(change)) for change in changes}
                intent = {"unit": name, "status": "intent", "changes": changes, "before": before}
                _append(handle, {"t": "intent", **intent})
                result = store.update_unit({
                    change["path"]: (found[change["path"]][1], change["set"], change["delete"]) for change in changes
                })
                if result is None:
                    rows.append({**intent, "status": "changed_during_write"})
                    continue
                row = {**intent, "status": "written", "updateTimes": {path: _encode(value) for path, value in result.items()}}
                _append(handle, {"t": "done", "unit": name, "status": "written", "updateTimes": row["updateTimes"]})
                rows.append(row)
    return _manifest(kind, project, header["runId"], "apply", rows)


def _public(entry: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in entry.items() if key != "t"}


def plan_patch(store: PatchStore, kind: str, project: str, units: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    rows = []
    for unit in units:
        found = {change["path"]: store.read(change["path"]) for change in unit["changes"]}
        if any(value is None for value in found.values()):
            rows.append({"unit": unit["unit"], "status": "missing"})
            continue
        changes = [resolved(change, found[change["path"]][0]) for change in unit["changes"]]
        before = {change["path"]: field_state(found[change["path"]][0], touched(change)) for change in changes}
        same = all(reached(found[change["path"]][0], change) for change in changes)
        rows.append({"unit": unit["unit"], "status": "unchanged" if same else "would_change",
                     "changes": changes, "before": before})
    return _manifest(kind, project, "", "dry-run", rows)


def _manifest(kind: str, project: str, run_id: str, mode: str, rows: list[dict[str, Any]]) -> dict[str, Any]:
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    return {"format": PATCH_FORMAT, "kind": kind, "project": project, "runId": run_id, "mode": mode,
            "counts": counts, "units": rows}


def undo_patch(store: PatchStore | None, manifest: Mapping[str, Any]) -> dict[str, Any]:
    written = [row for row in manifest["units"] if row["status"] == "written"]
    report: dict[str, Any] = {"kind": manifest["kind"], "project": manifest["project"],
                              "mode": "dry-run" if store is None else "apply",
                              "wouldRestore": [row["unit"] for row in written],
                              "checkByHand": [row["unit"] for row in manifest["units"] if row["status"] == CHECK_BY_HAND]}
    if store is None:
        return report
    restored, already, skipped = [], [], []
    for row in written:
        found = {change["path"]: store.read(change["path"]) for change in row["changes"]}
        if any(value is None for value in found.values()):
            skipped.append({"unit": row["unit"], "why": "a document is gone"})
            continue
        if all(field_state(found[path][0], row["before"][path]) == row["before"][path] for path in found):
            already.append(row["unit"])
            continue
        if any(_encode(found[path][1]) != row["updateTimes"].get(path) for path in found):
            skipped.append({"unit": row["unit"], "why": "changed since this write"})
            continue
        result = store.update_unit({
            path: (
                found[path][1],
                {name: _decode(value) for name, value in row["before"][path].items() if value != ABSENT},
                [name for name, value in row["before"][path].items() if value == ABSENT],
            )
            for path in found
        })
        if result is None:
            skipped.append({"unit": row["unit"], "why": "changed while undo ran"})
        else:
            restored.append(row["unit"])
    report.update({"restored": restored, "alreadyRestored": already, "skipped": skipped})
    return report


def live_company(project: str) -> Any:
    db = _client(project)
    collections = {
        name: {snapshot.id: snapshot.to_dict() or {} for snapshot in db.collection(name).stream()}
        for name in ("users", "user_access")
    }
    return company_from_collections(project, collections)


def user_record_codes(company: Any) -> set[str]:
    return {code for row in (*company.users, *company.user_access) if (code := text(row, "employeeCode", "staffId"))}


def staff_instructions(company: Any, plan: Mapping[str, Any]) -> dict[str, list[str]]:
    people = people_by_uid(company)

    def who(uid: str) -> str:
        person = people.get(uid)
        return f"{person.name or uid} ({person.code or uid})" if person else uid

    def moves(rows: Sequence[Mapping[str, Any]], undo: bool) -> list[str]:
        lines = []
        for row in rows:
            source = "" if undo else (
                " from " + ", ".join(who(uid) for uid in row["fromSupervisorUids"]) if row["fromSupervisorUids"]
                else " (on no team before)" if not row.get("fixesOwnLinkOnly")
                else " (already on that roster; the move writes the salesperson's own empty link)"
            )
            lines.append(f"{row['step']}. Move {who(row['salespersonUid'])}{source} to {who(row['toSupervisorUid'])}.")
        return lines

    return {"moves": moves(plan["steps"], False), "undo": moves(plan["undoSteps"], True)}


def verify_staff(company: Any, plan: Mapping[str, Any]) -> dict[str, Any]:
    def check(rows: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
        return [{"step": row["step"], "salespersonCode": row["salespersonCode"], "toSupervisorUid": row["toSupervisorUid"],
                 **step_done(company, row["salespersonCode"], row["toSupervisorUid"])} for row in rows]

    moves, undo = check(plan["steps"]), check(plan["undoSteps"])
    return {"moves": moves, "movesDone": sum(row["done"] for row in moves), "movesTotal": len(moves),
            "undo": undo, "undoDone": sum(row["done"] for row in undo), "undoTotal": len(undo)}


def _load_manifest(path: Path) -> dict[str, Any]:
    body = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(body, dict) or body.get("format") != PATCH_FORMAT or "units" not in body:
        raise SimulationError("The file is not a manifest of demo_setup.")
    return body


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Demo set-up changes for one company: shop owners, the branch start point, stale roster codes, "
                    "and the staff move list. Every write is a dry run unless it gets --apply with --confirm-project. "
                    "Each apply saves a manifest with the before values; undo restores them and skips a record "
                    "that changed since.")
    sub = parser.add_subparsers(dest="command", required=True)
    shops = sub.add_parser("shops", help="give each shop of the roster's shopOwners map to its salesperson, "
                                         "with the payload of the dashboard's Assign to salesman")
    shops.add_argument("--export", required=True)
    shops.add_argument("--roster", required=True, help="roster file with shopOwners")
    start = sub.add_parser("start-point", help="set routeStartName, routeStartLat and routeStartLng on one branch")
    start.add_argument("--project", required=True)
    start.add_argument("--branch", required=True)
    start.add_argument("--name", required=True)
    start.add_argument("--lat", required=True, type=float)
    start.add_argument("--lng", required=True, type=float)
    clear = sub.add_parser("roster-clear", help="remove roster codes from one supervisor's users and user_access "
                                                "documents together, in every letter case")
    clear.add_argument("--project", required=True)
    clear.add_argument("--users-doc", required=True, help="document id in users")
    clear.add_argument("--uid", required=True, help="document id in user_access")
    clear.add_argument("--codes", required=True, help="comma-separated codes")
    for command in (shops, start, clear):
        command.add_argument("--manifest", required=True, help="manifest file to write (outside git)")
        command.add_argument("--apply", action="store_true", help="write the change (default: dry run)")
        command.add_argument("--confirm-project", help="repeat the project ID to confirm --apply")
    undo = sub.add_parser("undo", help="restore the before values of one applied manifest")
    undo.add_argument("--manifest", required=True)
    undo.add_argument("--apply", action="store_true")
    undo.add_argument("--confirm-project")
    staff = sub.add_parser("staff", help="print the staff moves a signed-in admin makes with the dashboard's move "
                                         "command, in order, and their undo; writes nothing to the company")
    staff.add_argument("--export", required=True)
    staff.add_argument("--roster", required=True)
    staff.add_argument("--out", help="file for the plan (ids and codes, no names)")
    verify = sub.add_parser("staff-verify", help="read users and user_access (read-only) and say which moves are done")
    verify.add_argument("--project", required=True)
    verify.add_argument("--plan", required=True, help="plan file saved by staff --out")
    args = parser.parse_args(argv)
    try:
        if args.command == "staff":
            company = load_export(Path(args.export))
            team = resolve_team(company, load_roster(Path(args.roster)))
            conflicts = roster_conflicts(company, team)
            if conflicts:
                print(json.dumps({"rosterConflicts": conflicts, "why": ROSTER_CONFLICT_WHY}, indent=2, sort_keys=True))
                return 3
            plan = staff_move_plan(company, team)
            if args.out:
                write_json(Path(args.out), {"project": company.project, **plan})
            print(json.dumps({"instructions": staff_instructions(company, plan), "blocked": plan["blocked"],
                              "fallbackClears": plan["fallbackClears"], "undoCannotRestore": plan["undoCannotRestore"]},
                             indent=2, sort_keys=True))
            return 3 if plan["blocked"] else 0
        if args.command == "staff-verify":
            plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
            if plan.get("project") != args.project:
                raise SimulationError("The plan file belongs to another project.")
            print(json.dumps(verify_staff(live_company(args.project), plan), indent=2, sort_keys=True))
            return 0
        if args.command == "undo":
            manifest = _load_manifest(Path(args.manifest))
            if manifest["mode"] != "apply":
                raise SimulationError("This manifest is a dry run. Nothing was written, so there is nothing to undo.")
            if args.apply and args.confirm_project != manifest["project"]:
                print("--apply needs --confirm-project equal to the manifest's project.", file=sys.stderr)
                return 2
            store = FirestorePatchStore(_client(manifest["project"])) if args.apply else None
            report = undo_patch(store, manifest)
            print(json.dumps(report, indent=2, sort_keys=True))
            return 3 if report.get("skipped") or report["checkByHand"] else 0
        project = load_export(Path(args.export)).project if args.command == "shops" else args.project
        if args.apply and args.confirm_project != project:
            print("--apply needs --confirm-project equal to the project.", file=sys.stderr)
            return 2
        manifest_path = Path(args.manifest)
        if manifest_path.exists() and not args.apply:
            raise SimulationError(f"{manifest_path} exists. Use another manifest path.")
        if manifest_path.exists() and _load_manifest(manifest_path)["mode"] != "apply":
            raise SimulationError(f"{manifest_path} is a dry-run plan. Use a new --manifest path for --apply.")
        store = FirestorePatchStore(_client(project))
        not_active: list[dict[str, str]] = []
        if args.command == "shops":
            units, not_active = shop_changes(Path(args.export), Path(args.roster))
        elif args.command == "start-point":
            units = start_point_changes(args.branch, args.name, args.lat, args.lng)
        else:
            units = roster_clear_changes(store, args.users_doc, args.uid, args.codes.split(","),
                                         user_codes=user_record_codes(live_company(project)))
        kind = args.command
        manifest = (
            apply_patch(store, kind, project, units, journal_path(manifest_path)) if args.apply
            else plan_patch(store, kind, project, units)
        )
        if kind == "shops":
            manifest["notActiveShops"] = not_active
        write_json(manifest_path, manifest)
        print(json.dumps({key: manifest[key] for key in ("kind", "project", "mode", "counts", "notActiveShops")
                          if key in manifest}, indent=2, sort_keys=True))
        bad = {"missing", "changed_during_write", CHECK_BY_HAND}
        return 3 if bad & set(manifest["counts"]) else 0
    except SimulationError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

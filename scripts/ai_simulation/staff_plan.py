from __future__ import annotations

from typing import Any, Mapping, Sequence

from .inputs import Company, Person, SimulationError, Team, canonical, people_by_uid, person_uid, shop_id, text

SUPERVISOR_CAP = 5
LEGACY_ASSIGNMENT_FIELDS = (
    "assignedSalesmanUid",
    "assigned_salesman_uid",
    "assigned_salesman_id",
    "assignedSalesmanCode",
    "assigned_salesman_code",
    "assignedSalesman",
    "assigned_salesman",
    "assignedTo",
    "assignedUsers",
    "assigned_users",
    "assignedSalesmen",
    "assigned_salesmen",
    "assignedSalesmanCodes",
    "assigned_salesman_codes",
)


def shop_assignment_plan(shops: Sequence[Mapping[str, Any]], owners: Mapping[str, Person]) -> list[dict[str, Any]]:
    rows = []
    for row in sorted(shops, key=shop_id):
        key = shop_id(row)
        before = {
            name: row[name] for name in ("assignedSalesmanId", *LEGACY_ASSIGNMENT_FIELDS) if name in row
        }
        after = {"assignedSalesmanId": owners[key].code}
        rows.append({
            "path": f"retailers/{key}",
            "before": before,
            "set": after,
            "deleteFields": sorted(name for name in LEGACY_ASSIGNMENT_FIELDS if name in row),
            "unchanged": before == after,
            "salesmanUid": owners[key].uid,
        })
    return rows


def _roster_of(row: Mapping[str, Any]) -> list[str]:
    codes = row.get("assignedSalesmanCodes")
    return [str(code) for code in codes] if isinstance(codes, list) else []


def links_of(company: Company) -> dict[str, dict[str, str]]:
    access = {text(row, "docId"): row for row in company.user_access}
    links: dict[str, dict[str, str]] = {}
    for row in company.users:
        uid = person_uid(row)
        index = access.get(uid, {})
        links[uid] = {
            "supervisorUid": text(index, "supervisorUid") or text(row, "supervisorUid"),
            "supervisorCode": text(row, "supervisorId", "supervisor_id") or text(index, "supervisorId", "supervisor_id"),
        }
    return links


def supervisors_of(company: Company) -> dict[str, dict[str, Any]]:
    access = {text(row, "docId"): row for row in company.user_access}
    found: dict[str, dict[str, Any]] = {}
    for row in company.users:
        uid = person_uid(row)
        merged = {**row, **{key: value for key, value in access.get(uid, {}).items() if key != "docId"}}
        if merged.get("role") != "supervisor":
            continue
        found[uid] = {
            "uid": uid,
            "code": text(merged, "employeeCode", "staffId"),
            "branch": text(merged, "branchId", "branch_id"),
            "active": merged.get("status") == "active",
            "roster": _roster_of(merged),
            "rosterCopies": (_roster_of(row), _roster_of(access.get(uid, {}))),
        }
    return found


ROSTER_CONFLICT_WHY = (
    "The move list is only right when each supervisor's users and user_access rosters hold the same codes and each "
    "code is on one roster. Repair these records in the dashboard first, export again, and run staff again."
)


def roster_conflicts(company: Company, team: Team) -> list[dict[str, Any]]:
    supervisors = supervisors_of(company)
    involved = [uid for uid in dict.fromkeys(
        [supervisor.uid for supervisor, _ in team.groups] + [person.uid for person in team.leaver_supervisors]
    ) if uid in supervisors]
    cases: list[dict[str, Any]] = []
    watched = {canonical(person.code) for person in team.salespeople}
    for uid in involved:
        users_copy, access_copy = (
            {canonical(code): code for code in copy if canonical(code)} for copy in supervisors[uid]["rosterCopies"]
        )
        watched |= set(users_copy) | set(access_copy)
        if set(users_copy) != set(access_copy):
            cases.append({
                "supervisorUid": uid,
                "problem": "the users and user_access rosters differ",
                "onlyInUsers": sorted(users_copy[code] for code in set(users_copy) - set(access_copy)),
                "onlyInUserAccess": sorted(access_copy[code] for code in set(access_copy) - set(users_copy)),
            })
    shown = {canonical(person.code): person.code for person in people_by_uid(company).values() if person.code}
    holders: dict[str, list[str]] = {}
    for uid, entry in sorted(supervisors.items()):
        for code in sorted({canonical(item) for copy in entry["rosterCopies"] for item in copy} & watched):
            holders.setdefault(code, []).append(uid)
    for code, uids in sorted(holders.items()):
        if len(uids) > 1:
            cases.append({
                "salespersonCode": shown.get(code, code),
                "problem": "the code is on more than one roster",
                "supervisorUids": uids,
            })
    return cases


def linked_to(link: Mapping[str, str], supervisor: Mapping[str, Any]) -> bool:
    return link.get("supervisorUid") == supervisor["uid"] or (
        bool(supervisor["code"]) and canonical(link.get("supervisorCode")) == canonical(supervisor["code"])
    )


def replay_move(rosters: dict[str, dict[str, str]], code: str, shown: str, target: str) -> None:
    for uid, roster in rosters.items():
        if uid != target:
            roster.pop(code, None)
    rosters[target][code] = shown
    if len(rosters[target]) > SUPERVISOR_CAP:
        raise SimulationError(f"The move of {shown} puts {len(rosters[target])} codes on the roster of {target}.")


def _undo_order(
    rosters: Mapping[str, Mapping[str, str]], goals: list[tuple[str, str, str]],
) -> tuple[list[tuple[str, str, str]], list[dict[str, Any]]]:
    state = {uid: dict(roster) for uid, roster in rosters.items()}
    pending = list(goals)
    ordered: list[tuple[str, str, str]] = []
    while pending:
        ready = next(
            (goal for goal in pending if goal[0] in state[goal[2]] or len(state[goal[2]]) < SUPERVISOR_CAP), None
        )
        if ready is None:
            return ordered, [
                {"salespersonCode": shown, "problem": f"the supervisor {target} has no free place for the undo"}
                for _, shown, target in pending
            ]
        replay_move(state, *ready)
        ordered.append(ready)
        pending.remove(ready)
    return ordered, []


def staff_move_plan(company: Company, team: Team) -> dict[str, Any]:
    supervisors = supervisors_of(company)
    links = links_of(company)
    by_code: dict[str, list[Person]] = {}
    for person in people_by_uid(company).values():
        if person.code:
            by_code.setdefault(canonical(person.code), []).append(person)
    rosters = {uid: {canonical(code): code for code in entry["roster"] if canonical(code)}
               for uid, entry in supervisors.items()}
    demo = {supervisor.uid: {canonical(member.code) for member in members} for supervisor, members in team.groups}
    for uid in [*demo, *(person.uid for person in team.leaver_supervisors)]:
        if uid not in supervisors or not supervisors[uid]["active"]:
            raise SimulationError(f"The supervisor {uid} is not an active supervisor in the export.")
        if canonical(supervisors[uid]["branch"]) != canonical(team.branch_id):
            raise SimulationError(f"The supervisor {uid} is in another branch than the roster's branch.")
    steps: list[dict[str, Any]] = []
    blocked: list[dict[str, Any]] = []
    fallback: list[dict[str, Any]] = []

    def holder_of(code: str) -> list[str]:
        return sorted(uid for uid, roster in rosters.items() if code in roster)

    def move(code: str, person: Person, target: str, reason: str) -> bool:
        roster = rosters[target]
        if code not in roster and len(roster) >= SUPERVISOR_CAP:
            return False
        holders = [uid for uid in holder_of(code) if uid != target]
        on_target_roster = code in roster
        for uid in holders:
            del rosters[uid][code]
        roster[code] = person.code
        steps.append({
            "step": len(steps) + 1,
            "command": "move_salesperson",
            "reason": reason,
            "salespersonUid": person.uid,
            "salespersonCode": person.code,
            "fromSupervisorUids": holders,
            "toSupervisorUid": target,
            "fixesOwnLinkOnly": on_target_roster and not holders,
            "rosterSizeAfter": {uid: len(rosters[uid]) for uid in sorted({*holders, target})},
        })
        return True

    wanted_anywhere = set().union(*demo.values())
    for supervisor_uid, wanted in demo.items():
        for code, shown in sorted(rosters[supervisor_uid].items()):
            if code in wanted_anywhere:
                continue
            profiles = by_code.get(code, [])
            if len(profiles) != 1 or profiles[0].role != "salesman":
                fallback.append({
                    "supervisorUid": supervisor_uid,
                    "rosterCode": shown,
                    "problem": "no visible profile" if not profiles else "the code does not name one salesperson",
                    "action": "remove it from both roster copies with the roster-clear command of demo_setup; "
                              "until then it counts toward the limit of five",
                })
                continue
            person = profiles[0]
            if canonical(person.branch_id) != canonical(team.branch_id):
                blocked.append({"salespersonUid": person.uid, "problem": "the salesperson is in another branch"})
                continue
            placed = any(
                move(code, person, target.uid, "leaves the demo team")
                for target in team.leaver_supervisors
                if len(rosters[target.uid]) < SUPERVISOR_CAP
            )
            if not placed:
                blocked.append({
                    "salespersonUid": person.uid,
                    "problem": "no leaver supervisor of the roster file has a free place",
                })
    waiting = [
        (member, supervisor.uid)
        for supervisor, members in team.groups
        for member in members
        if canonical(member.code) not in rosters[supervisor.uid]
        or not linked_to(links.get(member.uid, {}), supervisors[supervisor.uid])
    ]
    while waiting:
        moved = [entry for entry in waiting if move(canonical(entry[0].code), entry[0], entry[1], "joins the demo team")]
        if not moved:
            blocked.extend(
                {"salespersonUid": member.uid, "problem": f"the supervisor {target} has no free place"}
                for member, target in waiting
            )
            break
        waiting = [entry for entry in waiting if entry not in moved]
    goals: list[tuple[str, str, str]] = []
    parked: list[str] = []
    home = team.leaver_supervisors[0].uid if team.leaver_supervisors else None
    first_steps = {canonical(step["salespersonCode"]): step for step in reversed(steps)}
    for step in reversed([first_steps[code] for code in dict.fromkeys(canonical(row["salespersonCode"]) for row in steps)]):
        if step["fixesOwnLinkOnly"]:
            continue
        code = canonical(step["salespersonCode"])
        if step["fromSupervisorUids"]:
            goals.append((code, step["salespersonCode"], step["fromSupervisorUids"][0]))
        elif home is not None:
            goals.append((code, step["salespersonCode"], home))
            parked.append(step["salespersonUid"])
    ordered, undo_blocked = _undo_order(rosters, goals)
    blocked.extend(undo_blocked)
    uid_of = {canonical(step["salespersonCode"]): step["salespersonUid"] for step in steps}
    undo = [
        {"step": position, "command": "move_salesperson", "salespersonUid": uid_of[code],
         "salespersonCode": shown, "toSupervisorUid": target}
        for position, (code, shown, target) in enumerate(ordered, 1)
    ]
    return {
        "steps": steps,
        "undoSteps": undo,
        "noEarlierSupervisor": [step["salespersonUid"] for step in steps if not step["fromSupervisorUids"]],
        "undoCannotRestore": {
            "parkedWithLeaverSupervisor": parked,
            "linkFieldsWrittenByTheMove": [step["salespersonUid"] for step in steps if step["fixesOwnLinkOnly"]],
            "why": "the move command cannot set no supervisor and cannot clear a link",
        },
        "fallbackClears": fallback,
        "blocked": blocked,
        "rostersAfter": {uid: sorted(rosters[uid].values()) for uid in sorted(rosters)},
        "rosterSizeIncludesFallbackCodes": True,
    }


def step_done(company: Company, code: str, target: str) -> dict[str, Any]:
    supervisors = supervisors_of(company)
    person = next((person for person in people_by_uid(company).values() if canonical(person.code) == canonical(code)), None)
    if person is None or target not in supervisors:
        return {"done": False, "why": "the salesperson or the supervisor is not in the records"}
    holders = sorted(
        uid for uid, entry in supervisors.items()
        if any(canonical(code) in {canonical(item) for item in copy} for copy in entry["rosterCopies"])
    )
    both_copies = all(canonical(code) in {canonical(item) for item in copy} for copy in supervisors[target]["rosterCopies"])
    linked = linked_to(links_of(company).get(person.uid, {}), supervisors[target])
    done = both_copies and holders == [target] and linked
    why = [] if done else [
        reason for reason, failed in (
            ("not on both roster copies of the target", not both_copies),
            (f"also on the roster of {', '.join(uid for uid in holders if uid != target)}", holders not in ([target], [])),
            ("the salesperson's own supervisor link does not name the target", not linked),
        ) if failed
    ]
    return {"done": done, "why": "; ".join(why)}

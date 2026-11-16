from __future__ import annotations

import hashlib
from datetime import date, datetime
from typing import Any, Iterable, Mapping

from .normalization import is_demo_record


def _active(row: Mapping[str, Any]) -> bool:
    return str(row.get("status") or "new").lower() not in {
        "resolved",
        "dismissed",
        "suppressed",
    } and str(row.get("autoState") or "active").lower() != "suppressed"


def _salesman_key(code: str) -> str:
    return hashlib.sha256(code.encode("utf-8")).hexdigest()[:16]


def _record(
    *,
    notification_id: str,
    title: str,
    message: str,
    notification_type: str,
    period_type: str,
    period_start: date,
    run_id: str,
    generated_at: datetime,
    role_target: str,
    branch_id: str = "",
    salesman_uid: str = "",
    salesman_code: str = "",
    high_priority_count: int = 0,
    follow_up_count: int = 0,
    value_at_risk_rm: float = 0.0,
    is_demo: bool = False,
) -> dict[str, Any]:
    return {
        "notificationId": notification_id,
        "title": title,
        "message": message,
        "type": notification_type,
        "periodType": period_type,
        "periodStart": period_start,
        "roleTarget": role_target,
        "branchId": branch_id,
        "salesmanUid": salesman_uid,
        "salesmanCode": salesman_code,
        "highPriorityCount": high_priority_count,
        "followUpCount": follow_up_count,
        "valueAtRiskRm": round(value_at_risk_rm, 2),
        "source": "ai1_runner",
        "sourceRunId": run_id,
        "updatedAt": generated_at,
        "isDemo": is_demo,
    }


def build_ai_notifications(
    insights: Iterable[Mapping[str, Any]],
    *,
    as_of: date,
    week_start: date,
    run_id: str,
    generated_at: datetime,
) -> tuple[dict[str, Any], ...]:
    active_rows = [dict(row) for row in insights if _active(row)]
    production_rows = [
        row for row in active_rows if not is_demo_record(row)
    ]
    active = production_rows or active_rows
    high = [row for row in active if str(row.get("priority") or "").lower() == "high"]
    follow_up = [
        row
        for row in active
        if str(row.get("autoState") or "").lower() == "follow_up"
    ]
    total_risk = sum(float(row.get("valueAtRiskRm") or 0) for row in active)
    all_demo = bool(active) and all(is_demo_record(row) for row in active)

    records = [
        _record(
            notification_id=f"ai1_daily_admin_{as_of.isoformat()}",
            title="Daily AI attention summary",
            message=(
                f"{len(high)} high-priority insights and "
                f"{len(follow_up)} follow-ups need review."
            ),
            notification_type="ai_daily_summary",
            period_type="daily",
            period_start=as_of,
            run_id=run_id,
            generated_at=generated_at,
            role_target="admin",
            high_priority_count=len(high),
            follow_up_count=len(follow_up),
            value_at_risk_rm=total_risk,
            is_demo=all_demo,
        ),
        _record(
            notification_id=f"ai1_weekly_admin_{week_start.isoformat()}",
            title="Weekly AI risk summary",
            message=(
                f"{len(active)} active insights, {len(high)} high priority, "
                f"RM {total_risk:.2f} estimated value at risk."
            ),
            notification_type="ai_weekly_summary",
            period_type="weekly",
            period_start=week_start,
            run_id=run_id,
            generated_at=generated_at,
            role_target="admin",
            high_priority_count=len(high),
            follow_up_count=len(follow_up),
            value_at_risk_rm=total_risk,
            is_demo=all_demo,
        ),
    ]

    salesman_codes = sorted(
        {
            str(row.get("salesmanCode") or "").strip()
            for row in active
            if str(row.get("salesmanCode") or "").strip()
        }
    )
    for code in salesman_codes:
        scoped = [
            row
            for row in active
            if str(row.get("salesmanCode") or "").strip() == code
        ]
        scoped_high = [
            row
            for row in scoped
            if str(row.get("priority") or "").lower() == "high"
        ]
        scoped_follow_up = [
            row
            for row in scoped
            if str(row.get("autoState") or "").lower() == "follow_up"
        ]
        if not scoped_high and not scoped_follow_up:
            continue
        source = scoped[0]
        risk = sum(float(row.get("valueAtRiskRm") or 0) for row in scoped)
        key = _salesman_key(code)
        common = {
            "run_id": run_id,
            "generated_at": generated_at,
            "role_target": "supervisor",
            "branch_id": str(source.get("branchId") or ""),
            "salesman_uid": str(source.get("salesmanUid") or ""),
            "salesman_code": code,
            "high_priority_count": len(scoped_high),
            "follow_up_count": len(scoped_follow_up),
            "value_at_risk_rm": risk,
            "is_demo": all(is_demo_record(row) for row in scoped),
        }
        records.extend(
            [
                _record(
                    notification_id=f"ai1_daily_supervisor_{as_of.isoformat()}_{key}",
                    title="Team AI follow-up alert",
                    message=(
                        f"{code}: {len(scoped_high)} high-priority insights and "
                        f"{len(scoped_follow_up)} follow-ups need review."
                    ),
                    notification_type="ai_team_daily_summary",
                    period_type="daily",
                    period_start=as_of,
                    **common,
                ),
                _record(
                    notification_id=f"ai1_weekly_supervisor_{week_start.isoformat()}_{key}",
                    title="Weekly team AI summary",
                    message=(
                        f"{code}: {len(scoped)} active insights and "
                        f"RM {risk:.2f} estimated value at risk."
                    ),
                    notification_type="ai_team_weekly_summary",
                    period_type="weekly",
                    period_start=week_start,
                    **common,
                ),
            ]
        )
    return tuple(records)

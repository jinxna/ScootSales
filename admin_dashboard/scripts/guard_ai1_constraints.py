#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MOBILE_ROOT = REPO_ROOT / "flutter_mobile_app" / "lib"
RULES_PATH = REPO_ROOT / "admin_dashboard" / "firestore.rules"

SENSITIVE_READ_COLLECTIONS = {
    "ai_insights",
    "ai_runs",
    "dashboard_notifications",
    "retailer_item_patterns",
    "retailer_memory",
    "retailer_segments",
    "visit_briefs",
    "weekly_ai_summaries",
}

HUMAN_FIELDS = {
    "status",
    "acknowledgedBy",
    "acknowledgedAt",
    "resolvedBy",
    "resolvedAt",
    "dismissedBy",
    "dismissedAt",
    "snoozedUntil",
    "suppressedBy",
    "adminNotes",
    "assignedToUid",
    "assignedRole",
    "dueDate",
    "statusHistory",
}

DASHBOARD_ROOT = REPO_ROOT / "admin_dashboard" / "lib"
TEAM_SCOPE_PATH = DASHBOARD_ROOT / "security" / "team_scope.dart"
TEAM_SCOPE_CHECK_RE = re.compile(
    r"assignedSalesmanCodes\s*(?:\.\s*(?:contains|any|where|every|firstWhere|indexOf|toSet|lookup)\b|;)"
    r"|\bin\s+[\w.?!]*assignedSalesmanCodes\b"
)
TEAM_SCOPE_ALLOWED = {
    "admin_dashboard/lib/models/user_profile.dart": (
        1,
        "the assignedSalesmanCodes field declaration",
    ),
    "admin_dashboard/lib/pages/admin/views/dashboard_overview_page.dart": (
        2,
        "dashboard_notifications: query chunks and the roleTarget/salesmanCode rule",
    ),
    "admin_dashboard/lib/pages/admin/views/retailer_score_sheet_page.dart": (
        1,
        "salesperson picker over user rows",
    ),
    "admin_dashboard/lib/pages/admin/views/route_planner_page.dart": (
        1,
        "salesperson picker over user rows",
    ),
    "admin_dashboard/lib/pages/admin/views/salesman_activity_page.dart": (
        3,
        "viewer's own team list and unloaded codes; published route_plans use the route rule",
    ),
    "admin_dashboard/lib/pages/admin/views/special_requests_page.dart": (
        1,
        "special_requests rule checks salesmanCode only",
    ),
    "admin_dashboard/lib/repositories/admin_setup_checklist_repository.dart": (
        3,
        "user rows: is any supervisor assigned a valid salesperson",
    ),
    "admin_dashboard/lib/utils/retailer_scope.dart": (
        1,
        "retailer rows keep the salesperson in assignedSalesmanId, which TeamScope does not resolve",
    ),
    "admin_dashboard/lib/services/action_centre_service.dart": (
        4,
        "user and retailer rows, and _rowInScope route rows that carry assignedSalesmanCodes",
    ),
    "admin_dashboard/lib/utils/user_directory_view.dart": (
        1,
        "user rows in the user directory",
    ),
    "admin_dashboard/lib/voice/copilot/copilot_panel.dart": (
        1,
        "Copilot scope note: the viewer's assigned codes over user rows",
    ),
    "admin_dashboard/lib/voice/copilot/copilot_directory.dart": (
        1,
        "Scout people list over user rows, codes compared without letter case",
    ),
}
SALESMAN_RESOLVER_RE = re.compile(
    r"""['"]salesmanCode['"][\s\S]{0,240}?['"]salesmanId['"][\s\S]{0,240}?['"]staffId['"]"""
)
SALESMAN_RESOLVER_ALLOWED = {
    "admin_dashboard/lib/models/master_data_hygiene.dart": (
        1,
        "joins an order to its salesperson for data-quality checks",
    ),
    "admin_dashboard/lib/services/action_centre_service.dart": (
        1,
        "matches an event to a salesperson by any code field",
    ),
}

WRITE_METHODS = r"(?:set|update|delete|add)"
COLLECTION_WRITE_RE = re.compile(
    rf"""
    \.collection\s*\(\s*(['"])(?P<collection>[^'"]+)\1\s*\)
    [^;]{{0,1200}}?
    \.{WRITE_METHODS}\s*\(
    """,
    re.IGNORECASE | re.DOTALL | re.VERBOSE,
)


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {message}")
    return result.stdout.strip()


def git_paths(*args: str) -> list[str]:
    result = subprocess.run(["git", *args, "-z"], cwd=REPO_ROOT, check=False, capture_output=True)
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {message}")
    names = result.stdout.decode("utf-8", errors="replace").split(chr(0))
    return [name.replace("\\", "/") for name in names if name]


def source_files(root: Path, suffix: str) -> list[Path]:
    if not root.exists():
        return []
    return sorted(
        path
        for path in root.rglob(f"*{suffix}")
        if not any(part in {"build", ".dart_tool", "node_modules", "__pycache__"} for part in path.parts)
    )


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def relative(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


BACKUP_SUFFIXES = (".bak", ".old", ".orig", "~")


def is_secret_path(path_text: str) -> bool:
    path = Path(path_text)
    name = path.name.lower()
    stripped = True
    while stripped:
        stripped = False
        for suffix in BACKUP_SUFFIXES:
            if name.endswith(suffix) and len(name) > len(suffix):
                name, stripped = name[: -len(suffix)], True
    if name in {"serviceaccountkey.json", "ors_api_key.local", ".env", ".env.local"}:
        return True
    if name.startswith(".env.") and name != ".env.example":
        return True
    if name.endswith(".env") or name in {"key.properties", "service_account.json"}:
        return True
    if name.startswith("cos40005-") and name.endswith(".json"):
        return True
    if ".keys" in {part.lower() for part in path.parts[:-1]}:
        return True
    return Path(name).suffix in {".pem", ".key", ".p12", ".pfx"}


def is_generated_path(path_text: str) -> bool:
    parts = {part.lower() for part in Path(path_text).parts}
    return bool(parts.intersection({"build", ".dart_tool", "node_modules", "__pycache__"}))


def ai_core_files() -> list[Path]:
    candidates: set[Path] = set()
    roots = (
        REPO_ROOT / "forecasting" / "ai_core",
        REPO_ROOT / "forecasting" / "sales_intelligence" / "core",
        REPO_ROOT / "admin_dashboard" / "scripts" / "ai_core",
    )
    for root in roots:
        candidates.update(source_files(root, ".py"))
    return sorted(candidates)


def ai_python_files() -> list[Path]:
    files: list[Path] = []
    for root in (REPO_ROOT / "forecasting", REPO_ROOT / "admin_dashboard" / "scripts"):
        for path in source_files(root, ".py"):
            lowered = relative(path).lower()
            if any(
                token in lowered
                for token in (
                    "ai_core",
                    "ai_service",
                    "sales_intelligence",
                    "ai_insight",
                )
            ):
                files.append(path)
    return sorted(set(files))


def collection_write_targets(text: str) -> set[str]:
    return {match.group("collection") for match in COLLECTION_WRITE_RE.finditer(text)}


ALLOWED_BRANCHES = {"Norman", "main", "Gestrain"}


def check_branch() -> list[str]:
    if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
        base = os.environ.get("GITHUB_BASE_REF", "")
        return [] if base in ALLOWED_BRANCHES else [f"pull request base branch is {base!r}, expected one of {sorted(ALLOWED_BRANCHES)}"]
    branch = git("branch", "--show-current")
    return [] if branch in ALLOWED_BRANCHES else [f"current branch is {branch!r}, expected one of {sorted(ALLOWED_BRANCHES)}"]


def check_repository_paths() -> list[str]:
    errors: list[str] = []
    tracked = git_paths("ls-files")
    staged = git_paths("diff", "--cached", "--name-only", "--diff-filter=ACMR")

    secret_paths = sorted({path for path in tracked + staged if is_secret_path(path)})
    if secret_paths:
        errors.append("secret/private-key filenames tracked or staged: " + ", ".join(secret_paths))

    generated_staged = sorted(path for path in staged if is_generated_path(path))
    if generated_staged:
        errors.append("generated build outputs staged: " + ", ".join(generated_staged))
    return errors


def check_mobile_collection_ownership() -> list[str]:
    errors: list[str] = []
    dart_files = source_files(MOBILE_ROOT, ".dart")
    outcome_files: list[Path] = []
    progress_files: list[Path] = []

    for path in dart_files:
        text = read_text(path)
        lowered = text.lower()
        targets = collection_write_targets(text)

        forbidden = targets.intersection({"route_plans", "ai_insights"})
        if forbidden:
            errors.append(
                f"{relative(path)} writes forbidden collection(s): {', '.join(sorted(forbidden))}"
            )

        if "conversation_outcomes" in lowered or "outcome" in path.stem.lower():
            outcome_files.append(path)
            disallowed = targets.difference({"conversation_outcomes"})
            if disallowed:
                errors.append(
                    f"{relative(path)} outcome flow writes outside conversation_outcomes: "
                    + ", ".join(sorted(disallowed))
                )

        if "route_plan_progress" in lowered or "route_progress" in lowered:
            progress_files.append(path)
            disallowed = targets.difference({"route_plan_progress"})
            if disallowed:
                errors.append(
                    f"{relative(path)} route progress flow writes outside route_plan_progress: "
                    + ", ".join(sorted(disallowed))
                )

    for path in outcome_files:
        text = read_text(path)
        if re.search(r"\.(?:set|update|delete|add)\s*\(", text) and "conversation_outcomes" not in text:
            errors.append(f"{relative(path)} writes outcomes without a conversation_outcomes target")

    for path in progress_files:
        text = read_text(path)
        if re.search(r"\.(?:set|update|delete|add)\s*\(", text) and "route_plan_progress" not in text:
            errors.append(f"{relative(path)} writes route progress without a route_plan_progress target")

    return errors


def check_ai_core_purity() -> list[str]:
    errors: list[str] = []
    forbidden_import = re.compile(
        r"^\s*(?:from|import)\s+(?:firebase_admin|google\.cloud\.firestore)\b",
        re.MULTILINE,
    )
    for path in ai_core_files():
        if forbidden_import.search(read_text(path)):
            errors.append(f"{relative(path)} imports Firebase/Firestore inside the pure core")
    return errors


def check_issue_identity() -> list[str]:
    errors: list[str] = []
    assignment = re.compile(
        r"(?is)\b(?:issueKey|issue_key|issueId|issue_id)\b\s*[:=]\s*(?P<value>[^\n]{0,300})"
    )
    week_token = re.compile(
        r"(?i)(week(?:Start|_start|Key|_key)?|strftime|%Y-?%W|%G-?W|iso(?:calendar|week)|as_of)"
    )
    for path in ai_python_files():
        lowered = relative(path).lower()
        if "/test" in lowered or Path(lowered).name.startswith("test_"):
            continue
        for match in assignment.finditer(read_text(path)):
            if week_token.search(match.group("value")):
                errors.append(f"{relative(path)} appears to make issue identity week-based")
                break
    return errors


def check_merge_preservation_tests() -> list[str]:
    production = [
        path
        for path in ai_python_files()
        if "/test" not in relative(path).lower() and not path.name.startswith("test_")
    ]
    has_insight_upsert = any(
        "ai_insights" in read_text(path)
        and any(
            token in read_text(path).lower()
            for token in ("upsert", "merge_insight", "write_generation")
        )
        for path in production
    )
    if not has_insight_upsert:
        return []

    test_files = [
        path
        for root in (REPO_ROOT / "forecasting", REPO_ROOT / "admin_dashboard" / "scripts")
        for path in source_files(root, ".py")
        if "/test" in relative(path).lower() or path.name.startswith("test_")
    ]
    merged_tests = "\n".join(read_text(path) for path in test_files)
    missing = sorted(field for field in HUMAN_FIELDS if field not in merged_tests)
    errors: list[str] = []
    if "merge" not in merged_tests.lower() and "upsert" not in merged_tests.lower():
        errors.append("AI insight upsert exists, but no merge/upsert preservation test was found")
    if missing:
        errors.append("merge/upsert tests do not cover human fields: " + ", ".join(missing))
    return errors


def check_dashboard_team_scope() -> list[str]:
    errors: list[str] = []
    checks = (
        (TEAM_SCOPE_CHECK_RE, TEAM_SCOPE_ALLOWED, "tests assignedSalesmanCodes"),
        (SALESMAN_RESOLVER_RE, SALESMAN_RESOLVER_ALLOWED, "resolves the salesperson code in rules order"),
    )
    for path in source_files(DASHBOARD_ROOT, ".dart"):
        if path == TEAM_SCOPE_PATH:
            continue
        text = read_text(path)
        for pattern, allow_list, what in checks:
            hits = len(pattern.findall(text))
            allowed = allow_list.get(relative(path), (0, ""))[0]
            if hits > allowed:
                errors.append(
                    f"{relative(path)} {what} {hits} time(s), allowed {allowed}; "
                    "use TeamScope (lib/security/team_scope.dart) or "
                    "allow-list the file with a reason"
                )
    return errors


def check_firestore_rules() -> list[str]:
    if not RULES_PATH.exists():
        return [f"missing Firestore rules file: {relative(RULES_PATH)}"]
    errors: list[str] = []
    sources = [("worktree", read_text(RULES_PATH))]
    rules_relative = relative(RULES_PATH)
    if rules_relative in git_paths("diff", "--cached", "--name-only"):
        sources.append(("staged", git("show", f":{rules_relative}")))

    for source, text in sources:
        if re.search(
            r"allow\s+(?:read\s*,\s*write|write|create|update|delete)\s*:\s*if\s+true\s*;",
            text,
            re.IGNORECASE,
        ):
            errors.append(
                f"Firestore rules ({source}) contain an unconditional write allow"
            )

        catch_all_blocks = re.findall(
            r"match\s+/\{[^}]+\}/\{document=\*\*\}\s*\{(?P<body>.*?)\n\s*\}",
            text,
            re.IGNORECASE | re.DOTALL,
        )
        for body in catch_all_blocks:
            if re.search(
                r"allow\s+[^;]*write[^;]*:\s*if\s+(?:signedIn\s*\(\s*\)|request\.auth\s*!=\s*null)",
                body,
                re.IGNORECASE,
            ):
                errors.append(
                    f"Firestore catch-all ({source}) grants broad signed-in writes"
                )
                break

        for collection in sorted(SENSITIVE_READ_COLLECTIONS):
            block = re.search(
                rf"match\s+/{re.escape(collection)}/\{{[^}}]+\}}\s*\{{"
                rf"(?P<body>.*?)\n\s{{4}}\}}",
                text,
                re.IGNORECASE | re.DOTALL,
            )
            if block and re.search(
                r"allow\s+read\s*:\s*if\s+"
                r"(?:signedIn\s*\(\s*\)|request\.auth\s*!=\s*null)\s*;",
                block.group("body"),
                re.IGNORECASE,
            ):
                errors.append(
                    f"Firestore rules ({source}) grant broad signed-in reads "
                    f"to sensitive collection {collection}"
                )
    return errors


def main() -> int:
    checks = (
        ("branch is Norman, main or Gestrain", check_branch),
        ("tracked/staged files exclude secrets and generated output", check_repository_paths),
        ("mobile collection ownership", check_mobile_collection_ownership),
        ("AI core has no Firebase/Firestore imports", check_ai_core_purity),
        ("issue identity is persistent, not week-based", check_issue_identity),
        ("merge-on-upsert tests preserve human fields", check_merge_preservation_tests),
        ("Firestore rules reject obvious broad writes", check_firestore_rules),
        ("dashboard sales records use TeamScope", check_dashboard_team_scope),
    )

    failures = 0
    print("AI-1 constraint guard")
    for label, check in checks:
        try:
            errors = check()
        except Exception as exc:
            errors = [str(exc)]
        if errors:
            failures += len(errors)
            print(f"[FAIL] {label}")
            for error in errors:
                print(f"  - {error}")
        else:
            print(f"[PASS] {label}")

    if failures:
        print(f"Guard failed with {failures} issue(s).")
        return 1
    print("Guard passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

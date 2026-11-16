#!/usr/bin/env python3

from __future__ import annotations

import ast
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SERVICE_ROOT = REPO_ROOT / "platform_service"
LINK_MODULE = "company_access"
CLIENT_MODULE = "migrate_seats"
CLIENT_NAME = "_client"

LINK_IMPORTERS = {
    "access_repair": "lists and fixes broken people rows in one company project",
    "account_links": "makes password reset and verification links with the company's Firebase Auth",
    "account_deletion": "disables and deletes the company's sign-in accounts",
    "account_security": "reads company admins' sign-in accounts for new-device and password-change alerts",
    "client_api": "company admin routes read the company lifecycle stamp and check the admin row",
    "held_work": "drains work held while a company was suspended into the company project",
    "invitations": "creates and updates the company's sign-in accounts and access rows",
    "lifecycle": "suspend, reactivate and retention writes in the company project",
    "project_setup": "Connect reads a new company project and stores its record",
    "product_commands": "product show, hide and delete commands with the plan limit",
    "scheduler": "periodic jobs that walk the companies",
    "staff": "staff sign-in accounts live in the platform project, reached through project_auth",
    "staff_api": "composition root that wires company_access into the services",
    "subscriptions": "writes the subscription record into the company project",
    "support": "support consent routes check the retention window and the admin row",
    "tenant_export": "exports the company's data",
    "tenant_readiness": "reads the onboarding facts of one company project",
    "usage_reconciler": "recounts seats and products in the company project",
}

CLIENT_IMPORTERS = {
    "access_repair": "operator command for one named company project",
    "access_migration": "operator command for one named company project",
    "order_code_backfill": "operator command for one named company project",
    "live_tracking_migration": "operator command for one named company project",
    "sheet_prices": "operator command for one named company project",
    "tenant_inventory": "operator command for one named company project",
    "tenant_readiness": "reads the onboarding facts of one company project",
    "tenant_snapshot": "operator command for one named company project",
}

FIRESTORE_BUILDERS = {
    LINK_MODULE: "opens company databases",
    "audit": "platform project audit command",
    "client_api": "platform project database",
    "devtool": "platform project plan seeding",
    CLIENT_MODULE: "operator command for one named company project",
    "seed_directory": "platform project directory seeding",
}

CREDENTIAL_CALLS = {
    ("firebase_admin", "initialize_app"),
    ("admin_auth", "Client"),
    ("service_account", "Credentials"),
    ("credentials", "Certificate"),
}


def _display_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def _imported_modules(node: ast.AST) -> list[tuple[str, str | None]]:
    if isinstance(node, ast.Import):
        return [(alias.name.split(".")[-1], None) for alias in node.names]
    if isinstance(node, ast.ImportFrom):
        module = (node.module or "").split(".")[-1]
        if module:
            return [(module, alias.name) for alias in node.names]
        return [(alias.name, None) for alias in node.names]
    return []


def _call_target(node: ast.Call) -> tuple[str, str] | None:
    function = node.func
    if isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name):
        return function.value.id, function.attr
    return None


def _describe(allowed: dict[str, str]) -> str:
    return ", ".join(sorted(allowed))


def scan_service(service_root: Path) -> list[str]:
    failures: list[str] = []
    for path in sorted(service_root.rglob("*.py")):
        if "tests" in path.relative_to(service_root).parts or path.name == "__init__.py":
            continue
        module = path.stem
        relative = _display_path(path)
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            for imported, name in _imported_modules(node):
                if imported == LINK_MODULE and module not in LINK_IMPORTERS and module != LINK_MODULE:
                    failures.append(
                        f"{relative}:{node.lineno}: imports {LINK_MODULE}; only "
                        f"{_describe(LINK_IMPORTERS)} may reach a company project"
                    )
                if (
                    imported == CLIENT_MODULE
                    and name == CLIENT_NAME
                    and module not in CLIENT_IMPORTERS
                ):
                    failures.append(
                        f"{relative}:{node.lineno}: imports {CLIENT_MODULE}.{CLIENT_NAME}; only "
                        f"{_describe(CLIENT_IMPORTERS)} may open a company project this way"
                    )
            if isinstance(node, ast.Call):
                target = _call_target(node)
                if target == ("firestore", "Client") and module not in FIRESTORE_BUILDERS:
                    failures.append(
                        f"{relative}:{node.lineno}: builds a Firestore client; only "
                        f"{_describe(FIRESTORE_BUILDERS)} may do that"
                    )
                if target in CREDENTIAL_CALLS and module != LINK_MODULE:
                    failures.append(
                        f"{relative}:{node.lineno}: {target[0]}.{target[1]} belongs in {LINK_MODULE}"
                    )
    return failures


def main() -> int:
    if not (SERVICE_ROOT / f"{LINK_MODULE}.py").is_file():
        print(f"Company link module is missing: {SERVICE_ROOT / (LINK_MODULE + '.py')}")
        return 1

    failures = scan_service(SERVICE_ROOT)
    if failures:
        print("Plane import guard failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    files = [
        path
        for path in SERVICE_ROOT.rglob("*.py")
        if "tests" not in path.relative_to(SERVICE_ROOT).parts
    ]
    print(
        "Plane import guard passed "
        f"({len(files)} platform_service file(s); company projects are reached through "
        f"{LINK_MODULE}.py and {len(LINK_IMPORTERS)} named modules)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

from typing import Any

from fastapi import FastAPI

from platform_service.seed_directory import REPO_ROOT
from platform_service.staff_api import create_app as create_staff_app
from platform_service.tenant_readiness import DeployedRules, rules_sha256

EMULATOR_RULES = REPO_ROOT / "admin_dashboard" / "firestore.rules"


def emulator_rules() -> DeployedRules:
    return DeployedRules("e2e-emulator", "", rules_sha256(EMULATOR_RULES.read_text(encoding="utf-8")), "")


def web_app_config(project_id: str) -> dict[str, Any]:
    return {"apiKey": {"web": "AIza" + "N" * 35}, "appId": {"web": "1:123456789012:web:0123456789abcdef"},
            "messagingSenderId": "123456789012", "storageBucket": f"{project_id}.firebasestorage.app"}


def create_app() -> FastAPI:
    return create_staff_app(
        rules_reader_for=lambda location: emulator_rules,
        connect_web_config_reader=web_app_config,
        connect_rules_reader=lambda project_id, database_id: emulator_rules(),
    )

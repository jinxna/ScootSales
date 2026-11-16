from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

GUARD = Path(__file__).with_name("agent_command_guard.py")
CASES = json.loads(Path(__file__).with_name("agent_command_guard_cases.json").read_text(encoding="utf-8"))


def verdict(tool: str, command: str) -> str:
    payload = json.dumps({"tool_name": tool, "tool_input": {"command": command}})
    result = subprocess.run([sys.executable, str(GUARD)], input=payload, capture_output=True, text=True, check=True)
    return "deny" if json.loads(result.stdout or "{}").get("hookSpecificOutput", {}).get("permissionDecision") == "deny" else "allow"


@pytest.mark.parametrize("case", CASES, ids=[case["name"] for case in CASES])
def test_guard_verdict(case: dict) -> None:
    assert verdict(case["tool"], case["command"]) == case["expect"]

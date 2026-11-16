from __future__ import annotations

import dataclasses
import difflib
import json
import os
from datetime import date, datetime
from pathlib import Path
from typing import Any

import pytest

GOLDEN_ROOT = Path(__file__).parent / "golden"


def to_jsonable(value: Any) -> Any:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return {
            field.name: to_jsonable(getattr(value, field.name))
            for field in dataclasses.fields(value)
        }
    if isinstance(value, dict):
        return {str(key): to_jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_jsonable(item) for item in value]
    if isinstance(value, (set, frozenset)):
        return sorted((to_jsonable(item) for item in value), key=repr)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, float) and value != value:
        return "NaN"
    return value


def render(value: Any) -> str:
    return (
        json.dumps(to_jsonable(value), indent=2, ensure_ascii=False, sort_keys=True)
        + "\n"
    )


def updating(request: pytest.FixtureRequest) -> bool:
    flag = os.environ.get("UPDATE_GOLDENS", "").strip().lower() in {"1", "true", "yes"}
    return flag or bool(request.config.getoption("--update-goldens", default=False))


def case_names(target: str) -> list[str]:
    folder = GOLDEN_ROOT / target
    return sorted(path.name.split(".input.")[0] for path in folder.glob("*.input.*"))


def load_input(target: str, case: str) -> Any:
    path = next((GOLDEN_ROOT / target).glob(f"{case}.input.*"))
    if path.suffix == ".json":
        return json.loads(path.read_text(encoding="utf-8"))
    return path


def assert_matches_golden(
    request: pytest.FixtureRequest, target: str, case: str, actual: Any
) -> None:
    expected_path = GOLDEN_ROOT / target / f"{case}.expected.json"
    rendered = render(actual)
    if updating(request):
        expected_path.write_text(rendered, encoding="utf-8")
        return
    assert expected_path.exists(), (
        f"Missing golden {expected_path}. Run with UPDATE_GOLDENS=1 to create it."
    )
    expected = expected_path.read_text(encoding="utf-8")
    if expected != rendered:
        diff = "".join(
            difflib.unified_diff(
                expected.splitlines(keepends=True),
                rendered.splitlines(keepends=True),
                fromfile=f"{target}/{case}.expected.json",
                tofile="actual",
            )
        )
        pytest.fail(
            f"Golden mismatch for {target}/{case}. Review the diff; if intended, "
            f"regenerate with UPDATE_GOLDENS=1.\n{diff}"
        )

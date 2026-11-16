from __future__ import annotations

import importlib.util
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("check_voice_core_imports.py")
SPEC = importlib.util.spec_from_file_location("check_voice_core_imports", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def write_core_file(root: Path, name: str, content: str) -> Path:
    core = root / "lib" / "voice" / "core"
    core.mkdir(parents=True, exist_ok=True)
    path = core / name
    path.write_text(content, encoding="utf-8")
    return core


def test_rejects_framework_and_ui_imports(tmp_path: Path) -> None:
    core = write_core_file(
        tmp_path,
        "bad.dart",
        "import 'package:flutter/material.dart';\n"
        "import 'dart:ui';\n",
    )

    failures = MODULE.scan_core_imports(core)

    assert any("package imports" in failure for failure in failures)
    assert any("dart:ui" in failure for failure in failures)


def test_rejects_transitive_relative_escape(tmp_path: Path) -> None:
    core = write_core_file(
        tmp_path,
        "bridge.dart",
        "import '../platform/api.dart';\n",
    )
    platform = tmp_path / "lib" / "voice" / "platform"
    platform.mkdir(parents=True)
    (platform / "api.dart").write_text(
        "import 'package:firebase_auth/firebase_auth.dart';\n",
        encoding="utf-8",
    )

    failures = MODULE.scan_core_imports(core)

    assert any("outside lib/voice/core" in failure for failure in failures)


def test_checks_all_uris_in_multiline_conditional_import(tmp_path: Path) -> None:
    core = write_core_file(
        tmp_path,
        "conditional.dart",
        "import\n"
        "  'safe.dart'\n"
        "  if (dart.library.io) '../platform/api.dart';\n",
    )

    failures = MODULE.scan_core_imports(core)

    assert any("outside lib/voice/core" in failure for failure in failures)


def test_rejects_import_after_a_block_comment(tmp_path: Path) -> None:
    core = write_core_file(
        tmp_path,
        "commented.dart",
        "/* explain this import; */ import 'package:flutter/material.dart';\n",
    )

    failures = MODULE.scan_core_imports(core)

    assert any("package imports" in failure for failure in failures)


def test_rejects_import_after_nested_block_comments(tmp_path: Path) -> None:
    core = write_core_file(
        tmp_path,
        "nested_comment.dart",
        "/* outer /* inner */ remainder */ import "
        "'package:flutter/material.dart';\n",
    )

    failures = MODULE.scan_core_imports(core)

    assert any("package imports" in failure for failure in failures)

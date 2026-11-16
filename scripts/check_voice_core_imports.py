#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CORE_ROOT = REPO_ROOT / "flutter_mobile_app" / "lib" / "voice" / "core"
DIRECTIVE_START_PATTERN = re.compile(r"^(?:import|export|part)\b")
URI_PATTERN = re.compile(r"['\"]([^'\"]+)['\"]")
FORBIDDEN_SYMBOLS = (
    re.compile(r"\bBuildContext\b"),
    re.compile(r"\bNavigator\b"),
    re.compile(r"\bMaterialPageRoute\b"),
    re.compile(r"\bFirebase(?:Auth|Firestore|Storage)\b"),
)


def _display_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def _validate_uri(path: Path, uri: str, core_root: Path) -> str | None:
    if uri == "dart:ui" or uri.startswith("dart:ui/"):
        return "dart:ui is not allowed in the pure voice core"
    if uri.startswith("dart:"):
        return None
    if uri.startswith("package:"):
        return "package imports are not allowed in the pure voice core"
    if uri.startswith(("/", "\\")):
        return "absolute imports are not allowed in the pure voice core"

    resolved = (path.parent / uri).resolve()
    try:
        resolved.relative_to(core_root.resolve())
    except ValueError:
        return "relative import resolves outside lib/voice/core"
    return None


def scan_core_imports(core_root: Path) -> list[str]:
    core_root = core_root.resolve()
    failures: list[str] = []
    dart_files = sorted(core_root.rglob("*.dart"))
    for path in dart_files:
        relative = _display_path(path)
        source = _strip_dart_comments(
            path.read_text(encoding="utf-8", errors="replace")
        )
        lines = source.splitlines()
        for line_number, directive in _directives(lines):
            for uri in URI_PATTERN.findall(directive):
                violation = _validate_uri(path, uri, core_root)
                if violation:
                    failures.append(f"{relative}:{line_number}: {violation}")

        for line_number, raw_line in enumerate(lines, start=1):
            line = raw_line.strip()
            code = line.split("//", 1)[0]
            for pattern in FORBIDDEN_SYMBOLS:
                if pattern.search(code):
                    failures.append(
                        f"{relative}:{line_number}: forbidden app symbol"
                    )
                    break
    return failures


def _directives(lines: list[str]) -> list[tuple[int, str]]:
    directives: list[tuple[int, str]] = []
    active: list[str] | None = None
    start_line = 0
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if active is None:
            if not DIRECTIVE_START_PATTERN.match(line):
                continue
            active = [line]
            start_line = line_number
        else:
            active.append(line)

        if _has_unquoted_semicolon(line):
            directives.append((start_line, " ".join(active)))
            active = None
            start_line = 0
    return directives


def _has_unquoted_semicolon(value: str) -> bool:
    quote: str | None = None
    escaped = False
    for character in value:
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
        elif character in ("'", '"'):
            quote = character
        elif character == ";":
            return True
    return False


def _strip_dart_comments(source: str) -> str:
    output: list[str] = []
    index = 0
    quote: str | None = None
    escaped = False
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if quote is not None:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            index += 1
            continue

        if character in ("'", '"'):
            quote = character
            output.append(character)
            index += 1
        elif character == "/" and following == "/":
            output.extend((" ", " "))
            index += 2
            while index < len(source) and source[index] not in "\r\n":
                output.append(" ")
                index += 1
        elif character == "/" and following == "*":
            output.extend((" ", " "))
            index += 2
            depth = 1
            while index < len(source) and depth > 0:
                if source[index] == "/" and index + 1 < len(source) and source[
                    index + 1
                ] == "*":
                    output.extend((" ", " "))
                    index += 2
                    depth += 1
                elif source[index] == "*" and index + 1 < len(source) and source[
                    index + 1
                ] == "/":
                    output.extend((" ", " "))
                    index += 2
                    depth -= 1
                else:
                    output.append("\n" if source[index] in "\r\n" else " ")
                    index += 1
        else:
            output.append(character)
            index += 1
    return "".join(output)


def main() -> int:
    if not CORE_ROOT.is_dir():
        print(f"Voice core directory is missing: {CORE_ROOT}")
        return 1

    dart_files = sorted(CORE_ROOT.rglob("*.dart"))
    if not dart_files:
        print(f"Voice core has no Dart files: {CORE_ROOT}")
        return 1

    failures = scan_core_imports(CORE_ROOT)
    if failures:
        print("Voice core import guard failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print(
        "Voice core import guard passed "
        f"({len(dart_files)} Dart file(s), framework-independent)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

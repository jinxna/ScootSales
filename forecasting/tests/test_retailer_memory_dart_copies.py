from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DART_COPIES = (
    REPO_ROOT / "admin_dashboard" / "lib" / "utils" / "retailer_memory.dart",
    REPO_ROOT / "flutter_mobile_app" / "lib" / "utils" / "retailer_memory.dart",
)

_TOKEN = re.compile(r"'[^'\n]*'|\"[^\"\n]*\"|[A-Za-z0-9_]+|\S")
_CLOSERS = (")", "]", "}")


def _normalised(path: Path) -> tuple[list[tuple[str, int]], list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    tokens: list[tuple[str, int]] = []
    for line_no, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        tokens.extend((token, line_no) for token in _TOKEN.findall(stripped))
    kept = [
        (token, line_no)
        for index, (token, line_no) in enumerate(tokens)
        if not (
            token == ","
            and index + 1 < len(tokens)
            and tokens[index + 1][0] in _CLOSERS
        )
    ]
    return kept, lines


def _describe(path: Path, tokens: list[tuple[str, int]], lines: list[str], index: int) -> str:
    if index >= len(tokens):
        return f"{path}: <end of code>"
    line_no = tokens[index][1]
    return f"{path}:{line_no}: {lines[line_no - 1].strip()}"


def test_dart_retailer_memory_copies_have_identical_code():
    admin_path, mobile_path = DART_COPIES
    admin_tokens, admin_lines = _normalised(admin_path)
    mobile_tokens, mobile_lines = _normalised(mobile_path)

    shared = min(len(admin_tokens), len(mobile_tokens))
    first_difference = next(
        (
            index
            for index in range(shared)
            if admin_tokens[index][0] != mobile_tokens[index][0]
        ),
        None,
    )
    if first_difference is None and len(admin_tokens) == len(mobile_tokens):
        return
    if first_difference is None:
        first_difference = shared

    message = (
        "The two retailer_memory.dart copies differ in code. Apply the change "
        "to both files.\n"
        f"  first difference: {_describe(admin_path, admin_tokens, admin_lines, first_difference)}\n"
        f"  versus:           {_describe(mobile_path, mobile_tokens, mobile_lines, first_difference)}"
    )
    raise AssertionError(message)

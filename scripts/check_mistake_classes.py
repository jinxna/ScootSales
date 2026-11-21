#!/usr/bin/env python3

from __future__ import annotations

import argparse
import ast
import bisect
import re
import subprocess
import sys
import tokenize
from pathlib import Path
from typing import NamedTuple

DEFAULT_ROOT = Path(__file__).resolve().parents[1]

AUTH_PYTHON_MODULES = [
    "platform_service/auth.py",
    "platform_service/directory.py",
    "platform_service/company_access.py",
    "platform_service/client_api.py",
    "platform_service/account_security.py",
    "forecasting/service/auth.py",
]
AUTH_DART_MODULES = [
    "admin_dashboard/lib/services/permission_policy_service.dart",
    "admin_dashboard/lib/app/role_guard.dart",
]
CACHE_NAMES = {"lru_cache", "cache", "cached", "ttl_cache", "TTLCache", "LRUCache"}
CACHE_MODULES = {"cachetools", "cacheout", "aiocache"}
DART_CACHE_FIELD = re.compile(r"\b(?:final|var|late|static)\b[^;=(]*\b_?[A-Za-z]*(?:Cache|Memo)[A-Za-z]*\s*[=;]")

STREAM_DIRS = ["admin_dashboard/lib", "flutter_mobile_app/lib", "packages"]
BROADCAST = re.compile(r"\.asBroadcastStream\(")

WEB_DIRS = ["admin_dashboard/web", "flutter_mobile_app/web", "admin_dashboard/lib", "flutter_mobile_app/lib"]
WEB_SUFFIXES = {".html", ".css", ".js", ".dart"}
CDN = re.compile(
    r"https?://(?:fonts\.googleapis\.com|fonts\.gstatic\.com|www\.gstatic\.com/flutter|"
    r"cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)"
)

FLOW_DIR = "e2e/flows"
CLOCK_SHIFT = re.compile(r"shiftDeviceClock\(")
FLOW_SUFFIXES = {".js", ".cjs", ".mjs"}
CLOCK_SHIFT_LIMIT = 1
E2E_LIB_DIR = "e2e/lib"
TYPING_HELPER = "e2e/lib/browser.cjs"
CLEAR_BY_HAND = re.compile(r"keyboard\.press\(\s*['\"](?:Control|Meta)\+A['\"]")
CLEAR_BY_HAND_LIMIT = 2

ASSISTANT_NAME_DIRS = [
    "admin_dashboard/lib",
    "flutter_mobile_app/lib",
    "website/src",
    "admin_dashboard/web",
    "flutter_mobile_app/web",
    "flutter_mobile_app/android/app/src/main/res",
]
ASSISTANT_NAME_PACKAGE_GLOB = "packages/*/lib"
ASSISTANT_NAME_FILES = ["faq/faq.json", "flutter_mobile_app/ios/Runner/Info.plist"]
ASSISTANT_NAME_SUFFIXES = {".dart", ".json", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".css", ".html", ".plist", ".xml", ".md", ".txt", ".arb"}
OLD_ASSISTANT_NAME = re.compile(r"\b(?:Copilot|COPILOT)\b")

EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+(?!(?:png|jpe?g|gif|svg|webp)\b)[A-Za-z]{2,}\b")
RESERVED_EMAIL_DOMAIN = re.compile(r"(?:^|\.)(?:test|example|invalid|localhost)$|(?:^|\.)example\.(?:com|net|org)$", re.I)
URL_USER_PART = re.compile(r"://(?:[^\s/@:]*:)?$")
PUBLIC_ADDRESSES = {
    "billing@scootsales.app",
    "name@company.com",
    "your@email.com",
    "ops@plan.put",
    "ops@acme-plan.put",
    "securetoken@system.gserviceaccount.com",
}
EMAIL_SKIP_NAMES = {"package-lock.json", "pubspec.lock", "yarn.lock", "pnpm-lock.yaml"}
EMAIL_SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".ttf", ".otf", ".woff", ".woff2", ".jar", ".zip", ".gz", ".xlsx", ".docx"}

WORKFLOW_DIR = ".github/workflows"
JOB_KEY = re.compile(r"^  [\"']?([A-Za-z0-9_-]+)[\"']?:\s*(?:#.*)?$")
JOBS_KEY = re.compile(r"^jobs:\s*(?:#.*)?$")

CODE_SUFFIXES = {".py", ".dart", ".js", ".cjs", ".mjs", ".ts", ".tsx"}
RETIRED_DIRS = ("admin_dashboard_hardware/", "flutter_mobile_app_hardware/", "hardware-rules/")
SKIPPED_PARTS = {"node_modules", "build", ".dart_tool", ".venv"}
GENERATED_NAME = re.compile(r"(?:\.g\.dart|\.freezed\.dart|\.gen\.ts)$|^GeneratedPluginRegistrant")
KEPT_COMMENT = re.compile(r"licen[sc]e|copyright|SPDX-License|@preserve", re.I)
PYTHON_DIRECTIVE = re.compile(r"#\s*(?:noqa|type:|pragma|pylint:|fmt:|isort:|mypy:|pyright:|ruff:|nosec|flake8:|yapf:)")
PYTHON_CODING_LINE = re.compile(r"#.*coding[:=]\s*[-\w.]+")
SCRIPT_DIRECTIVE = re.compile(
    r"^(?:///?|/\*!?)\s*(?:ignore:|ignore_for_file:|@dart|@ts-|eslint-|coverage:ignore|prettier-ignore|dart format)"
)
REGEX_AFTER_WORD = {"return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"}
CONDITION_WORDS = {"if", "while", "for", "with"}
WORD = re.compile(r"[A-Za-z0-9_$\u0080-￿]+")
LINE_END = re.compile(r"[^\r\n]*(?:\r\n|\r|\n)|[^\r\n]+")


class ScanError(Exception):
    pass


class Finding(NamedTuple):
    kind: str
    start: int
    end: int
    sole: bool = False


def python_cache_hits(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    hits = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            for decorator in node.decorator_list:
                target = decorator.func if isinstance(decorator, ast.Call) else decorator
                name = target.attr if isinstance(target, ast.Attribute) else getattr(target, "id", "")
                if name in CACHE_NAMES:
                    hits.append(f"{path}:{node.lineno}: decorator {name}")
        elif isinstance(node, ast.Import):
            hits += [f"{path}:{node.lineno}: import {a.name}" for a in node.names if a.name.split(".")[0] in CACHE_MODULES]
        elif isinstance(node, ast.ImportFrom) and (node.module or "").split(".")[0] in CACHE_MODULES:
            hits.append(f"{path}:{node.lineno}: import {node.module}")
    return hits


def line_hits(path: Path, pattern: re.Pattern[str], label: str) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return [f"{path}:{n}: {label}" for n, line in enumerate(text.splitlines(), 1) if pattern.search(line)]


def jobs_without_time_limit(path: Path) -> list[str]:
    hits, job, line_no, limited, in_jobs, jobs_seen = [], None, 0, False, False, 0
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines() + ["end:"], 1):
        if line.lstrip().startswith("#"):
            continue
        if not line.startswith(" ") and line.strip():
            if job and not limited:
                hits.append(f"{path}:{line_no}: job {job}")
            job = None
            in_jobs = bool(JOBS_KEY.match(line))
            continue
        match = JOB_KEY.match(line)
        if in_jobs and match:
            if job and not limited:
                hits.append(f"{path}:{line_no}: job {job}")
            job, line_no, limited = match.group(1), number, False
            jobs_seen += 1
        elif job and (line.startswith("    timeout-minutes:") or line.startswith("    uses:")):
            limited = True
    if not jobs_seen:
        hits.append(f"{path}:1: no jobs found")
    return hits


def email_hits(root: Path) -> list[str]:
    listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
    hits: list[str] = []
    for rel in sorted(name for name in listed.decode("utf-8").split("\0") if name):
        path = root / rel
        if path.name in EMAIL_SKIP_NAMES or path.suffix.lower() in EMAIL_SKIP_SUFFIXES or not path.is_file():
            continue
        text = path.read_bytes().decode("utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            for match in EMAIL.finditer(line):
                if URL_USER_PART.search(line, 0, match.start()):
                    continue
                address = match.group(0).rstrip(".-").lower()
                domain = address.split("@", 1)[1]
                if RESERVED_EMAIL_DOMAIN.search(domain) or address in PUBLIC_ADDRESSES:
                    continue
                hits.append(f"{rel}:{number}: email address on a real domain ({domain})")
    return hits


def split_lines(text: str) -> list[str]:
    return LINE_END.findall(text)


def line_starts(lines: list[str]) -> list[int]:
    starts, total = [], 0
    for line in lines:
        starts.append(total)
        total += len(line)
    return starts


def python_findings(text: str) -> list[Finding]:
    shift = 1 if text.startswith("﻿") else 0
    body = text[shift:]
    lines = split_lines(body)
    starts = line_starts(lines)
    findings: list[Finding] = []
    feed = iter(lines)
    try:
        for token in tokenize.generate_tokens(lambda: next(feed, "")):
            if token.type != tokenize.COMMENT:
                continue
            row, col = token.start
            kept = (
                (row <= 2 and PYTHON_CODING_LINE.match(token.string))
                or (row == 1 and token.string.startswith("#!"))
                or PYTHON_DIRECTIVE.match(token.string)
                or KEPT_COMMENT.search(token.string)
            )
            if not kept:
                start = starts[row - 1] + col
                findings.append(Finding("comment", start + shift, start + len(token.string) + shift))
        tree = ast.parse(body)
    except (tokenize.TokenError, SyntaxError) as error:
        raise ScanError(str(error)) from error

    def offset(row: int, byte_col: int) -> int:
        return starts[row - 1] + len(lines[row - 1].encode("utf-8")[:byte_col].decode("utf-8")) + shift

    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        first = node.body[0] if node.body else None
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str):
            findings.append(
                Finding("docstring", offset(first.lineno, first.col_offset), offset(first.end_lineno, first.end_col_offset), len(node.body) == 1)
            )
    return sorted(findings)


class ScriptScanner:
    def __init__(self, text: str, dart: bool) -> None:
        self.text = text
        self.size = len(text)
        self.dart = dart
        self.comments: list[tuple[int, int]] = []
        self.literals: list[tuple[int, int]] = []

    def run(self) -> None:
        start = 0
        if self.text.startswith("#!"):
            while start < self.size and self.text[start] not in "\r\n":
                start += 1
        self.code(start, False)

    def regex_allowed(self, prev: tuple[str, ...] | None) -> bool:
        if prev is None:
            return True
        if prev[0] == "w":
            return prev[1] in REGEX_AFTER_WORD
        if prev[0] == "v":
            return False
        return prev[1] not in "]<"

    def code(self, i: int, interp: bool) -> int:
        text, size, dart = self.text, self.size, self.dart
        depth = 0
        parens: list[bool] = []
        prev: tuple[str, ...] | None = None
        prev_end = -1
        while i < size:
            char = text[i]
            if char.isspace():
                i += 1
                continue
            pair = text[i:i + 2]
            if pair == "//":
                end = i
                while end < size and text[end] not in "\r\n":
                    end += 1
                self.comments.append((i, end))
                i = end
                continue
            if pair == "/*":
                end = self.block_end(i)
                self.comments.append((i, end))
                i = end
                continue
            if char in "'\"":
                i = self.quoted(i, dart and prev == ("w", "r") and prev_end == i)
                prev, prev_end = ("v",), i
                continue
            if char == "`" and not dart:
                i = self.template(i)
                prev, prev_end = ("v",), i
                continue
            if char == "/" and not dart and self.regex_allowed(prev):
                end = self.regex(i)
                if end:
                    self.literals.append((i, end))
                    i = end
                    prev, prev_end = ("v",), i
                    continue
            match = WORD.match(text, i)
            if match:
                word = match.group(0)
                i = match.end()
                prev = ("v",) if word[0].isdigit() or prev == ("p", ".") else ("w", word)
                prev_end = i
                continue
            if pair in ("++", "--"):
                prev, prev_end = ("v",), i + 2
                i += 2
                continue
            if char == "{":
                depth += 1
            elif char == "}":
                if interp and depth == 0:
                    return i + 1
                depth -= 1
            if char == "(":
                parens.append(prev is not None and prev[0] == "w" and prev[1] in CONDITION_WORDS)
                prev = ("p", char)
            elif char == ")":
                prev = ("p", char) if parens and parens.pop() else ("v",)
            else:
                prev = ("v",) if char == "]" else ("p", char)
            prev_end = i + 1
            i += 1
        return i

    def block_end(self, i: int) -> int:
        text, size = self.text, self.size
        if not self.dart:
            end = text.find("*/", i + 2)
            return size if end < 0 else end + 2
        depth, j = 0, i
        while j < size:
            if text.startswith("/*", j):
                depth += 1
                j += 2
            elif text.startswith("*/", j):
                depth -= 1
                j += 2
                if depth == 0:
                    return j
            else:
                j += 1
        return size

    def quoted(self, i: int, raw: bool) -> int:
        text, size = self.text, self.size
        quote = text[i]
        triple = self.dart and text.startswith(quote * 3, i)
        j = i + (3 if triple else 1)
        while j < size:
            char = text[j]
            if char == "\\" and not raw:
                j += 2
            elif triple and text.startswith(quote * 3, j):
                j += 3
                break
            elif char == quote and not triple:
                j += 1
                break
            elif char in "\r\n" and not triple:
                break
            elif self.dart and not raw and text.startswith("${", j):
                j = self.code(j + 2, True)
            else:
                j += 1
        self.literals.append((i, j))
        return j

    def template(self, i: int) -> int:
        text, size = self.text, self.size
        j = i + 1
        while j < size:
            char = text[j]
            if char == "\\":
                j += 2
            elif char == "`":
                j += 1
                break
            elif text.startswith("${", j):
                j = self.code(j + 2, True)
            else:
                j += 1
        self.literals.append((i, j))
        return j

    def regex(self, i: int) -> int:
        text, size = self.text, self.size
        j = i + 1
        in_class = False
        while j < size:
            char = text[j]
            if char in "\r\n":
                return 0
            if char == "\\":
                j += 2
                continue
            if char == "[":
                in_class = True
            elif char == "]":
                in_class = False
            elif char == "/" and not in_class:
                j += 1
                while j < size and text[j].isalpha():
                    j += 1
                return j
            j += 1
        return 0


def script_scan(text: str, dart: bool) -> tuple[list[Finding], list[tuple[int, int]]]:
    scanner = ScriptScanner(text, dart)
    scanner.run()
    findings = []
    for start, end in scanner.comments:
        body = text[start:end]
        if not (SCRIPT_DIRECTIVE.match(body) or KEPT_COMMENT.search(body)):
            findings.append(Finding("comment", start, end))
    return findings, scanner.literals


def scan_code(rel: str, text: str) -> list[Finding]:
    if rel.endswith(".py"):
        return python_findings(text)
    return script_scan(text, rel.endswith(".dart"))[0]


def code_files(root: Path) -> list[str]:
    listed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True, check=True
    ).stdout
    names = []
    for rel in sorted({name for name in listed.decode("utf-8").split("\0") if name}):
        path = root / rel
        if path.suffix not in CODE_SUFFIXES or rel.startswith(RETIRED_DIRS):
            continue
        if SKIPPED_PARTS.intersection(rel.split("/")) or GENERATED_NAME.search(path.name) or not path.is_file():
            continue
        names.append(rel)
    return names


def comment_hits(root: Path) -> list[str]:
    hits: list[str] = []
    for rel in code_files(root):
        text = (root / rel).read_bytes().decode("utf-8", errors="replace")
        try:
            findings = scan_code(rel, text)
        except ScanError as error:
            hits.append(f"{rel}:1: cannot scan ({error})")
            continue
        starts = line_starts(split_lines(text))
        hits += [f"{rel}:{bisect.bisect_right(starts, f.start)}: {f.kind} in code" for f in findings]
    return hits


def run(root: Path) -> list[str]:
    problems: list[str] = []
    for rel in AUTH_PYTHON_MODULES:
        if (root / rel).is_file():
            problems += [f"{h}: no cache in an authorization module" for h in python_cache_hits(root / rel)]
    for rel in AUTH_DART_MODULES:
        if (root / rel).is_file():
            problems += [f"{h}: no cache in an authorization module" for h in line_hits(root / rel, DART_CACHE_FIELD, "cache field")]
    for rel in STREAM_DIRS:
        for path in sorted((root / rel).rglob("*.dart")):
            problems += [f"{h}: share streams with RefCountedReplayStream, not asBroadcastStream" for h in line_hits(path, BROADCAST, "asBroadcastStream")]
    for rel in WEB_DIRS:
        for path in sorted((root / rel).rglob("*")):
            if path.is_file() and path.suffix in WEB_SUFFIXES:
                problems += [f"{h}: bundle fonts and scripts, no external CDN" for h in line_hits(path, CDN, "CDN URL")]
    flows = sorted(p for p in (root / FLOW_DIR).rglob("*") if p.is_file() and p.suffix in FLOW_SUFFIXES)
    shifts = {path: len(CLOCK_SHIFT.findall(path.read_text(encoding="utf-8", errors="replace"))) for path in flows}
    total = sum(shifts.values())
    if total > CLOCK_SHIFT_LIMIT:
        problems += [f"{path}: {count} of {total} phone clock shifts in e2e/flows, limit {CLOCK_SHIFT_LIMIT}; "
                     "the rules refuse a phone clock more than 10 minutes off, so on a Sunday use mobile.routeDayForSunday(db, plan)"
                     for path, count in shifts.items() if count]
    e2e_scripts = flows + sorted(p for p in (root / E2E_LIB_DIR).rglob("*")
                                 if p.is_file() and p.suffix in FLOW_SUFFIXES and p != root / TYPING_HELPER)
    clears = {path: len(CLEAR_BY_HAND.findall(path.read_text(encoding="utf-8", errors="replace"))) for path in e2e_scripts}
    total_clears = sum(clears.values())
    if total_clears > CLEAR_BY_HAND_LIMIT:
        problems += [f"{path}: {count} of {total_clears} hand-made select-all-and-type steps in e2e, limit {CLEAR_BY_HAND_LIMIT}; "
                     "Flutter web can drop the first typed key, so use B.fillField(page, locator, text, { shown }) "
                     "from e2e/lib/browser.cjs, which retries and records a typing trace"
                     for path, count in clears.items() if count]
    name_sources = [root / rel for rel in ASSISTANT_NAME_DIRS] + sorted(root.glob(ASSISTANT_NAME_PACKAGE_GLOB))
    name_files = [root / rel for rel in ASSISTANT_NAME_FILES if (root / rel).is_file()]
    for source in name_sources:
        name_files += sorted(p for p in source.rglob("*") if p.is_file() and p.suffix in ASSISTANT_NAME_SUFFIXES)
    for path in name_files:
        problems += [f"{h}: the assistant is called Scout; keep `copilot` only in identifiers"
                     for h in line_hits(path, OLD_ASSISTANT_NAME, "old assistant name Copilot")]
    for path in sorted((root / WORKFLOW_DIR).glob("*.y*ml")):
        problems += [f"{h}: add timeout-minutes; without it a hung step runs for 6 hours"
                     for h in jobs_without_time_limit(path)]
    problems += [f"{h}; the repository is public, use a .test address" for h in email_hits(root)]
    problems += [f"{h}; put explanations in project documentation and use clear names" for h in comment_hits(root)]
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    problems = run(parser.parse_args().root)
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

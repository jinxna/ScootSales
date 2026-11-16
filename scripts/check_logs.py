from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ERROR_LINE = re.compile(r"\b(ERROR|CRITICAL|Traceback)\b|\" 5\d\d |\bstatus[=: ]+5\d\d\b")
SENSITIVE_WORD = re.compile(
    r"(?i)authorization|bearer|basic auth|cookie|password|passwd|pwd|passphrase|secret|token|api[-_ ]?key|key|signature|session|otp|credential|private|oobcode|auth|seed|\bpass\b"
)
URL_USERINFO = re.compile(r"://[^/\s]*@")
BARE_SECRET = re.compile(
    r"(?:xkeysib-|xsmtpsib-|AIza|sk-|ghp_|stf_)[\w.-]+|-----BEGIN.*|eyJ[\w-]+\.[\w-]+\.[\w-]+|ya29\.\S+|1//\S+"
)
QUERY_VALUE = re.compile(r"([?&#][^=\s&#]+=)[^&\s#]*")
SECRET_SHAPED = re.compile(r"\b(?=[\w-]*\d)(?=[\w-]*[A-Za-z])[\w-]{8,}\b")
HTTP_STATUS_TAIL = re.compile(r"\"\s+\d{3}\b.*$")
HTTP_STATUS_HEAD = re.compile(r"\"\s+\d{3}\b")
TOKEN_SHAPED = re.compile(
    r"\b[0-9a-fA-F]{32,}\b"
    r"|\b(?=[\w-]*\d)(?=[\w-]*[A-Za-z])[\w-]{20,}\b"
    r"|\b(?=[A-Za-z0-9-]*\d)(?=[A-Za-z0-9-]*[A-Za-z])[A-Za-z0-9]{4}(?:-[A-Za-z0-9]{4}){2,}\b"
)
HEAD_BYTES = 64


def mask(line: str) -> str:
    line = URL_USERINFO.sub("://***@", line)
    line = QUERY_VALUE.sub(r"***", line)
    line = BARE_SECRET.sub("***", line)
    word = SENSITIVE_WORD.search(line)
    if word:
        tail = HTTP_STATUS_TAIL.search(line, word.end())
        line = SECRET_SHAPED.sub("***", line[: word.end()]) + " ***"
        if tail:
            status = HTTP_STATUS_HEAD.match(tail.group(0))
            line += status.group(0) + mask(tail.group(0)[status.end():])
    return TOKEN_SHAPED.sub("***", line)


def scan(path: Path, saved: object) -> tuple[list[str], dict[str, object]]:
    if not isinstance(saved, dict):
        saved = {"offset": saved if isinstance(saved, int) else 0}
    stat = path.stat()
    size = stat.st_size
    offset = int(saved.get("offset", 0))
    old_head = bytes.fromhex(str(saved.get("head", "")))
    with path.open("rb") as handle:
        head = handle.read(HEAD_BYTES)
        rotated = size < offset or head[: len(old_head)] != old_head
        if saved.get("inode") and stat.st_ino and saved["inode"] != stat.st_ino:
            rotated = True
        handle.seek(0 if rotated else offset)
        text = handle.read().decode("utf-8", errors="replace")
    lines = [mask(line) for line in text.splitlines() if ERROR_LINE.search(line)]
    return lines, {"offset": size, "head": head.hex(), "inode": stat.st_ino}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Report new error lines in log files.")
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--state", type=Path)
    args = parser.parse_args(argv)
    try:
        state = json.loads(args.state.read_text()) if args.state and args.state.exists() else {}
        if not isinstance(state, dict):
            raise ValueError("not an object")
    except (OSError, ValueError) as error:
        print(f"{args.state}: state file is not usable: {error}", file=sys.stderr)
        return 2
    found = 0
    for path in args.logs:
        try:
            lines, end = scan(path, state.get(str(path), 0))
        except OSError as error:
            print(f"{path}: cannot read: {error}", file=sys.stderr)
            return 2
        state[str(path)] = end
        found += len(lines)
        for line in lines:
            print(f"{path}: {line}")
    if args.state:
        args.state.write_text(json.dumps(state, sort_keys=True))
    print(f"new error lines: {found}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())

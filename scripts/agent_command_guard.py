#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys

SEARCH_WORDS = {"grep", "rg", "findstr", "select-string"}
GIT_SEARCH = {"grep", "log", "show", "diff"}
SKIP_WORDS = {"if", "then", "do", "else", "elif", "while", "time", "exec", "command", "call", "sudo"}
WRAPPERS = {"cmd", "powershell", "pwsh", "bash", "sh"}
RUN_SWITCH = re.compile(r"^(/{1,2}[ck]|-c|-lc|-command)$", re.IGNORECASE)
TOKEN = re.compile(r"(?:\"(?:\\.|[^\"\\])*\"|\"[^\"]*\"|'[^']*'|[^\s\"'])+")
SEPARATORS = ";&|\n(){}`"
ASSIGNMENT = re.compile(r"^[A-Za-z_]\w*=")
PS_ASSIGNMENT = re.compile(r"^\$\w+=?")
GIT_OPTION_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
GLUED_SWITCH = re.compile(r"^/{1,2}[ck](?=[\"'])", re.IGNORECASE)
EVALUATORS = {"eval", "iex", "invoke-expression"}
ENCODED = re.compile(r"^-e(c|nc|ncodedcommand)?$", re.IGNORECASE)
HEREDOC = re.compile(r"(?<![<\\])<<(-?)\s*([\"']?)([A-Za-z_]\w*)\2(?=[\s|&;()<>]|$)")
HEREDOC_OPEN = re.compile(r"<<-?\s*$")
QUOTED = re.compile(r"\"(?:\\.|[^\"\\])*\"|'[^']*'")
SHELL_COMMENT = re.compile(r"(?:^|\s)#.*")
SUBSTITUTION = re.compile(r"(?<!\\)(?:\\\\)*(?:\$\(|`)")
VARIABLE_OR_BACKTICK = re.compile(r"(?<!\\)(?:\$[A-Za-z_{\d@*]|`)")
SHELL_NAMES = WRAPPERS | EVALUATORS | {"dash", "zsh", "ksh", "ash", "csh", "tcsh", "fish", "busybox", "xargs", "parallel"}
SHELL_READERS = SHELL_NAMES | {"source", "."}
CHECKED_TOOLS = {"Bash", "PowerShell", "Monitor"}

WINDOW = "opens a window. Run the command directly in the Bash or PowerShell tool."
REASONS = {
    "saps": "saps (Start-Process) opens a window and its run never notifies. Use the tool's run_in_background instead.",
    "start-process": "Start-Process opens a window and its run never notifies. Use the tool's run_in_background instead.",
    "wsl": "wsl opens a terminal window on the owner's desktop. Use the Bash tool (Git Bash).",
    "start": "start " + WINDOW,
    "invoke-item": "Invoke-Item opens a window. Read the file with the Read tool.",
    "ii": "ii (Invoke-Item) opens a window. Read the file with the Read tool.",
    "explorer": "explorer opens a window. List files with the Glob tool.",
}
WORKTREE = (
    "git worktree remove follows Windows junctions and empties shared node_modules. "
    "Use: powershell -File scripts/remove_worktree.ps1 -Worktree <dir> (needs the owner's yes)."
)
EMULATOR = "The Android emulator opens a window. Add -no-window."
FLUTTER_EMULATOR = "flutter emulators --launch opens the emulator window. Use: emulator -avd <name> -no-window."


def split_segments(command: str, respect_quotes: bool = True) -> list[str] | None:
    segments, current, quote, escaped = [], [], "", False
    for char in command:
        if quote:
            current.append(char)
            if escaped:
                escaped = False
            elif char == "\\" and quote == '"':
                escaped = True
            elif char == quote:
                quote = ""
        elif respect_quotes and char in "\"'":
            quote = char
            current.append(char)
        elif char in SEPARATORS:
            segments.append("".join(current))
            current = []
        else:
            current.append(char)
    if quote:
        return None
    segments.append("".join(current))
    return segments


def command_name(token: str) -> str:
    name = token.strip("\"'").replace("\\", "/").rsplit("/", 1)[-1].lower()
    for suffix in (".exe", ".bat", ".cmd"):
        if name.endswith(suffix):
            return name[:-len(suffix)]
    return name


def git_words(rest: list[str]) -> list[str]:
    words, skip = [], False
    for word in rest:
        if skip:
            skip = False
        elif word in GIT_OPTION_WITH_VALUE:
            skip = True
        elif not word.startswith("-"):
            words.append(word)
    return words


def strip_prefixes(tokens: list[str]) -> list[str]:
    while tokens:
        name = command_name(tokens[0])
        if name in SKIP_WORDS or name == "nohup" or tokens[0] in {".", "&"} or ASSIGNMENT.match(tokens[0]):
            tokens = tokens[1:]
        elif PS_ASSIGNMENT.match(tokens[0]):
            remainder = tokens[0][PS_ASSIGNMENT.match(tokens[0]).end():]
            tokens = ([remainder] if remainder else []) + tokens[1:]
            if tokens and tokens[0] == "=":
                tokens = tokens[1:]
        elif name in {"env", "xargs", "timeout"}:
            tokens = tokens[1:]
            while tokens and tokens[0].startswith("-"):
                takes_value = name == "timeout" and tokens[0] in {"-s", "-k", "--signal", "--kill-after"}
                tokens = tokens[2:] if takes_value else tokens[1:]
            if name == "timeout" and tokens:
                tokens = tokens[1:]
        else:
            break
    return tokens


def unquote(text: str) -> str:
    return text[1:-1] if len(text) > 1 and text[0] == text[-1] and text[0] in "\"'" else text


def run_argument(tokens: list[str]) -> str | None:
    for index, token in enumerate(tokens[1:], 1):
        glued = GLUED_SWITCH.match(token)
        if RUN_SWITCH.match(token):
            return " ".join(tokens[index + 1:])
        if glued:
            return " ".join([token[glued.end():]] + tokens[index + 1:])
    return None


def segment_refusal(segment: str) -> str | None:
    tokens = []
    for token in TOKEN.findall(segment):
        if token.startswith("#"):
            break
        tokens.append(token)
    tokens = strip_prefixes(tokens)
    if not tokens:
        return None
    name = command_name(tokens[0])
    rest = [token.strip("\"'") for token in tokens[1:]]
    if name == "git":
        words = git_words(rest)
        if words[:1] and words[0] in GIT_SEARCH:
            return None
        if words[:2] == ["worktree", "remove"]:
            return WORKTREE
        return None
    if name == "flutter" and rest[:1] == ["emulators"] and any(word.startswith("--launch") for word in rest):
        return FLUTTER_EMULATOR
    if name in SEARCH_WORDS:
        return None
    if name in REASONS:
        return REASONS[name]
    if name == "emulator" and any(word == "-avd" or word.startswith("@") for word in rest):
        return None if "-no-window" in rest else EMULATOR
    if name in WRAPPERS:
        shell = name in {"powershell", "pwsh"}
        if shell and any(ENCODED.match(token) for token in rest):
            return "-EncodedCommand hides the command from the guard. Pass the command as plain text."
        inner = run_argument(tokens)
        if inner is None and shell and "-file" not in [word.lower() for word in rest]:
            inner = " ".join(token for token in tokens[1:] if not token.startswith("-"))
        return None if inner is None else refusal(unquote(inner), reader=True)
    if name in EVALUATORS:
        return refusal(unquote(" ".join(tokens[1:])), reader=True)
    return None


def feeds_shell(text: str) -> bool:
    if VARIABLE_OR_BACKTICK.search(text):
        return True
    for segment in split_segments(text, respect_quotes=False) or []:
        words = [word.replace('""', "").replace("''", "") for word in TOKEN.findall(re.sub(r"[<>]", " ", segment))]
        tokens = strip_prefixes(words)
        if (words and words[0] in SHELL_READERS) or (tokens and command_name(tokens[0]) in SHELL_READERS):
            return True
        if tokens and tokens[0].strip("\"'") == "$":
            return True
        if any(command_name(word.split("=", 1)[-1]) in SHELL_NAMES for word in words):
            return True
    return False


def heredoc_marker(line: str) -> re.Match[str] | None:
    if "((" in line or "$'" in line or "$[" in line:
        return None
    plain, last = [], 0
    for quoted in QUOTED.finditer(line):
        plain.append(line[last:quoted.start()])
        plain.append(quoted.group() if HEREDOC_OPEN.search(line, 0, quoted.start()) else " " * len(quoted.group()))
        last = quoted.end()
    plain.append(line[last:])
    return HEREDOC.search(SHELL_COMMENT.sub("", "".join(plain)))


def split_heredocs(command: str, reader: bool) -> tuple[str, list[str]]:
    lines = command.splitlines(keepends=True)
    kept, bodies, index = [], [], 0
    while index < len(lines):
        line = lines[index]
        kept.append(line)
        index += 1
        match = heredoc_marker(line)
        if not match or line.rstrip("\r\n").endswith("\\") or split_segments(
                "".join(kept[:-1]) + line[:match.start()]) is None:
            continue
        indented = bool(match.group(1))
        end = next((at for at in range(index, len(lines))
                    if (lines[at].strip() if indented else lines[at].rstrip("\r\n")) == match.group(3)), None)
        if end is None:
            continue
        bodies.append((match, "".join(lines[index:end])))
        index = end
    text = "".join(kept)
    reader = reader or feeds_shell(text)
    return text, [body for match, body in bodies if reader or (not match.group(2) and SUBSTITUTION.search(body))]


def refusal(command: str, heredocs: bool = True, reader: bool = False) -> str | None:
    command, fed = split_heredocs(command, reader) if heredocs else (command, [])
    for body in fed:
        reason = refusal(body)
        if reason:
            return reason
    for form in (command, re.sub(r"\\\r?\n", " ", command)):
        segments = split_segments(form)
        if segments is None:
            segments = split_segments(form, respect_quotes=False)
        for segment in segments:
            reason = segment_refusal(segment)
            if reason:
                return reason
    return None


def main() -> int:
    payload = json.load(sys.stdin)
    tool = payload.get("tool_name", "Bash")
    if tool not in CHECKED_TOOLS:
        return 0
    reason = refusal(str((payload.get("tool_input") or {}).get("command") or ""), heredocs=tool != "PowerShell")
    if reason:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"Blocked by scripts/agent_command_guard.py: {reason} "
                                        "No part of this command ran. "
                                        "If the word is only text in a file, write it with the Write or Edit tool.",
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())

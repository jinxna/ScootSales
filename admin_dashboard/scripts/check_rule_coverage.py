from pathlib import Path

import re
import sys

ROOT = Path(__file__).resolve().parents[2]
DASHBOARD_LIB = ROOT / "admin_dashboard" / "lib"
RULES = ROOT / "admin_dashboard" / "firestore.rules"

QUOTES = "[" + chr(34) + chr(39) + "]"
ARG = "[^A-Za-z0-9_]*"
NAME = "([A-Za-z0-9_]+)"

READ_PATTERNS = (
    re.compile("watchCollection(?:Raw)?" + ARG + "[(]" + ARG + QUOTES + NAME + QUOTES),
    re.compile("getCollectionOnce" + ARG + "[(]" + ARG + QUOTES + NAME + QUOTES),
    re.compile("[.]collection" + ARG + "[(]" + ARG + QUOTES + NAME + QUOTES),
)
BLOCK_PATTERN = re.compile("match" + ARG + "/" + ARG + NAME + ARG + "/")


def dashboard_read_collections() -> dict:
    reads: dict = {}
    for path in sorted(DASHBOARD_LIB.rglob("*.dart")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for pattern in READ_PATTERNS:
            for name in pattern.findall(text):
                reads.setdefault(name, set()).add(path.name)
    return reads


def rule_blocks(rules_text: str) -> dict:
    matches = list(BLOCK_PATTERN.finditer(rules_text))
    blocks: dict = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(rules_text)
        name = match.group(1)
        blocks[name] = blocks.get(name, "") + rules_text[match.start():end]
    return blocks


def main() -> int:
    if not RULES.is_file():
        print("FAIL: rules file not found at " + str(RULES))
        return 1
    reads = dashboard_read_collections()
    if not reads:
        print("FAIL: no dashboard collection reads found - scanner is broken.")
        return 1
    blocks = rule_blocks(RULES.read_text(encoding="utf-8", errors="ignore"))

    missing_block = sorted(name for name in reads if name not in blocks)
    missing_read = sorted(
        name
        for name in reads
        if name in blocks and "allow read" not in blocks[name]
    )

    print("Dashboard rule coverage")
    print("  collections read by admin_dashboard/lib: " + str(len(reads)))
    print("  without a match block:                    " + str(len(missing_block)))
    print("  with a block but no allow read:           " + str(len(missing_read)))
    for name in missing_block:
        print("  [MISSING BLOCK] " + name + " <- " + str(sorted(reads[name])))
    for name in missing_read:
        print("  [NO ALLOW READ] " + name + " <- " + str(sorted(reads[name])))
    if missing_block or missing_read:
        print("FAIL: a dashboard read would fail rule evaluation.")
        return 1
    print("  PASS - every read collection has a rule that allows reading.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

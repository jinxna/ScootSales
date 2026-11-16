from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RULES_FILES = (
    REPO_ROOT / "admin_dashboard" / "firestore.rules",
    REPO_ROOT / "platform_service" / "firestore.rules",
)
SOURCE_LIMIT_BYTES = 256 * 1024
MATCH_BLOCK = re.compile(r"^\s*match\s+\S+", re.MULTILINE)
ALLOW_RULE = re.compile(r"^\s*allow\s+[a-z, ]+\s*(?::|;)", re.MULTILINE)
FUNCTION = re.compile(r"^\s*function\s+\w+", re.MULTILINE)


def probe(path: Path) -> dict:
    data = path.read_bytes()
    text = data.decode("utf-8")
    return {
        "file": path.relative_to(REPO_ROOT).as_posix(),
        "bytes": len(data),
        "percentOfSourceLimit": round(100 * len(data) / SOURCE_LIMIT_BYTES, 1),
        "matchBlocks": len(MATCH_BLOCK.findall(text)),
        "allowRules": len(ALLOW_RULE.findall(text)),
        "functions": len(FUNCTION.findall(text)),
    }


def main() -> int:
    over = False
    for path in RULES_FILES:
        row = probe(path)
        over = over or row["bytes"] > SOURCE_LIMIT_BYTES
        print(" ".join(f"{key}={value}" for key, value in row.items()))
    print(f"sourceLimitBytes={SOURCE_LIMIT_BYTES} compiledLimit=250KB compiledSize=not measurable locally")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())

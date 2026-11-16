from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPLOY_DIR = ROOT / "deploy" / "droplet"
LOST_LINE_BREAK = re.compile(r"\\n {2,}[\"'-]")


def main() -> int:
    failures = 0
    bash = shutil.which("bash")
    if bash is None:
        print("bash is not on the PATH, so the shell scripts cannot be checked.")
        return 1
    for script in sorted(DEPLOY_DIR.glob("*.sh")):
        result = subprocess.run([bash, "-n", str(script)], capture_output=True, text=True)
        if result.returncode != 0:
            failures += 1
            print(f"{script.relative_to(ROOT)}: {result.stderr.strip()}")
        for number, line in enumerate(script.read_text(encoding="utf-8").splitlines(), 1):
            if LOST_LINE_BREAK.search(line):
                failures += 1
                print(f"{script.relative_to(ROOT)}:{number}: backslash-n text stands where a line break was meant")
    for script in sorted(DEPLOY_DIR.glob("*.py")):
        try:
            compile(script.read_text(encoding="utf-8"), str(script), "exec")
        except SyntaxError as error:
            failures += 1
            print(f"{script.relative_to(ROOT)}: line {error.lineno}: {error.msg}")
    if failures:
        return 1
    print("Deploy script check passed: every shell and Python script in deploy/droplet parses.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

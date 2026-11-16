from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "verify.yml"
GUARD_JOB = "core"


def guard_steps() -> list[tuple[str, str]]:
    job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][GUARD_JOB]
    return [(step.get("name") or step["run"].splitlines()[0], step["run"]) for step in job["steps"]
            if "run" in step and not (step.get("name") or "").startswith("Install")]


def bash() -> str:
    git = shutil.which("git")
    git_bash = Path(git).resolve().parents[1] / "bin" / "bash.exe" if git and sys.platform == "win32" else None
    found = str(git_bash) if git_bash and git_bash.exists() else shutil.which("bash")
    if found is None:
        sys.exit("bash is needed to run the CI guard steps (Git Bash on Windows).")
    return found


def run(name: str, script: str, shell: str) -> bool:
    started = time.monotonic()
    result = subprocess.run([shell, "-eo", "pipefail", "-c", script], cwd=ROOT, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    seconds = time.monotonic() - started
    ok = result.returncode == 0
    print(f"{'PASS' if ok else 'FAIL'}  {name}  ({seconds:.0f} s)")
    output = (result.stdout + result.stderr).strip().splitlines()
    skipped = [line for line in output if " skipped" in line and (" passed" in line or " failed" in line)]
    for line in (output[-25:] if not ok else skipped):
        print(f"      {line}")
    return ok


def secret_scan(base: str) -> bool | None:
    gitleaks = shutil.which("gitleaks")
    if gitleaks is None:
        print("SKIP  Secret scan: gitleaks is not installed, so CI is the first secret scan of these commits.")
        return None
    result = subprocess.run([gitleaks, "git", "--no-banner", f"--log-opts={base}..HEAD", "."], cwd=ROOT)
    print(f"{'PASS' if result.returncode == 0 else 'FAIL'}  Secret scan of {base}..HEAD")
    return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the CI guard job of verify.yml locally before a push. "
                                                 "It never pushes.")
    parser.add_argument("--base", default="origin/Norman", help="Commits after this are scanned for secrets.")
    parser.add_argument("--only", action="append", default=[], help="Run only steps whose name has this text.")
    args = parser.parse_args()
    shell = bash()
    steps = [(name, script) for name, script in guard_steps()
             if not args.only or any(part.lower() in name.lower() for part in args.only)]
    results = [run(name, script, shell) for name, script in steps]
    scanned = secret_scan(args.base) if not args.only else None
    failed = results.count(False) + (scanned is False)
    print(f"{len(results) - results.count(False)} of {len(results)} guard steps passed"
          + (", secret scan failed" if scanned is False else "")
          + ". Not covered here: emulator suites, Flutter jobs, Linux goldens and E2E; CI runs them.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

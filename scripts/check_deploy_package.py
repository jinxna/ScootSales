from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "deploy" / "droplet" / "build-package.sh"
DASHBOARD = ROOT / "admin_dashboard"
NOT_FOR_RELEASE = {
    "ADMIN_IDLE_TIMEOUT_MINUTES",
    "DASHBOARD_ROLE",
    "DEV_ACCOUNTS",
    "FIREBASE_AUTH_EMULATOR_PORT",
    "FIREBASE_EMULATOR_HOST",
    "FIRESTORE_EMULATOR_PORT",
    "USER_TESTING",
    "USE_FIREBASE_EMULATOR",
}
DEFINE_IN_CODE = re.compile(r"fromEnvironment\(\s*'([A-Z][A-Z0-9_]*)'")
DEFINE_IN_BUILD = re.compile(r"--dart-define=([A-Z][A-Z0-9_]*)=")
PATH_DEPENDENCY = re.compile(r"^\s+path:\s*(\S+)\s*$", re.MULTILINE)


def dashboard_sources() -> list[Path]:
    pubspec = (DASHBOARD / "pubspec.yaml").read_text(encoding="utf-8")
    folders = [DASHBOARD / "lib"] + [(DASHBOARD / path / "lib").resolve() for path in PATH_DEPENDENCY.findall(pubspec)]
    missing = [folder for folder in folders if not folder.is_dir()]
    if missing:
        sys.exit(f"FAIL: admin_dashboard/pubspec.yaml names a path package with no lib folder: {missing[0]}")
    return [path for folder in folders for path in sorted(folder.rglob("*.dart"))]


def main() -> int:
    in_code: dict[str, Path] = {}
    for path in dashboard_sources():
        for name in DEFINE_IN_CODE.findall(path.read_text(encoding="utf-8")):
            in_code.setdefault(name, path)
    in_build = set(DEFINE_IN_BUILD.findall(BUILD_SCRIPT.read_text(encoding="utf-8")))
    missing = sorted(set(in_code) - in_build - NOT_FOR_RELEASE)
    stale = sorted(in_build - set(in_code))
    for name in missing:
        print(f"{name} is read in {in_code[name].relative_to(ROOT)} but build-package.sh does not pass it.")
    for name in stale:
        print(f"build-package.sh passes {name} but no dashboard code reads it.")
    if missing or stale:
        return 1
    print(f"Deploy package check passed: {len(in_build)} build settings match the dashboard code.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

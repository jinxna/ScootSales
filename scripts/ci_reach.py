from __future__ import annotations

import os
import subprocess
import sys

APP_ROOTS = ("admin_dashboard/", "flutter_mobile_app/", "packages/")
OUTSIDE_BOTH_ROOTS = ("firestore_rules_test/", "document/", "formal/", "website/",
                      "scripts/check_", "scripts/guard_", "scripts/pre_push_check.py")
OUTSIDE_BOTH_FILES = (".gitleaks.toml",)
OUTSIDE_FLUTTER_ROOTS = ("forecasting/", "e2e/", "deploy/", "test/")
OUTSIDE_FLUTTER_FILES = ("server.js", "runner.py", "conftest.py", "pytest.ini")
OUTSIDE_E2E_ROOTS = ("admin_dashboard/test/", "admin_dashboard/integration_test/",
                     "flutter_mobile_app/test/", "flutter_mobile_app/integration_test/",
                     "forecasting/tests/", "test/")
EVERYTHING_NAMES = ("package.json", "package-lock.json", "pubspec.yaml", "pubspec.lock", "pyproject.toml")
EVERYTHING_ROOTS = (".github/", "scripts/ci_reach.py")


def reaches_everything(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return (path.startswith(EVERYTHING_ROOTS) or name in EVERYTHING_NAMES
            or (name.startswith("requirements") and name.endswith(".txt")))


def outside_both(path: str) -> bool:
    return ((path.endswith(".md") and not path.startswith(APP_ROOTS))
            or path in OUTSIDE_BOTH_FILES or path.startswith(OUTSIDE_BOTH_ROOTS))


def package_test(path: str) -> bool:
    parts = path.split("/")
    return len(parts) > 3 and parts[0] == "packages" and parts[2] == "test"


def reaches_flutter(path: str) -> bool:
    return not (outside_both(path) or path in OUTSIDE_FLUTTER_FILES or path.startswith(OUTSIDE_FLUTTER_ROOTS))


def reaches_e2e(path: str) -> bool:
    return not (outside_both(path) or path.startswith(OUTSIDE_E2E_ROOTS) or package_test(path))


def changed_paths(base: str, head: str) -> list[str]:
    listed = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"],
                            check=True, capture_output=True, text=True).stdout
    return [path for path in listed.split("\0") if path]


def reach(paths: list[str]) -> dict[str, bool]:
    if not paths or any(map(reaches_everything, paths)):
        return {"flutter": True, "e2e": True}
    return {"flutter": any(map(reaches_flutter, paths)), "e2e": any(map(reaches_e2e, paths))}


def main(argv: list[str]) -> int:
    if argv:
        paths = argv
    elif os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
        paths = changed_paths(os.environ["BASE_SHA"], os.environ["HEAD_SHA"])
    else:
        paths = []
    result = reach(paths)
    print(f"{len(paths)} changed paths", file=sys.stderr)
    for name, needed in result.items():
        print(f"{name}={'true' if needed else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

ADMIN_RULES = REPO_ROOT / "admin_dashboard" / "firestore.rules"


def expected_digest() -> str:
    from platform_service.seed_directory import _rules_digest

    return _rules_digest(ADMIN_RULES)


def compare(records: list[dict]) -> list[dict]:
    rows = []
    for record in records:
        if record["status"] == "deleted":
            continue
        expected = expected_digest()
        rows.append({"tenantId": record["tenantId"], "workspace": record["workspace"],
                     "recorded": record["rulesVersion"], "expected": expected,
                     "match": record["rulesVersion"] == expected})
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Report companies whose rulesVersion differs from the rules in this checkout.")
    parser.add_argument("--platform-project", required=True, help="central platform Firebase project")
    args = parser.parse_args(argv)

    from google.api_core.exceptions import GoogleAPIError
    from google.auth.exceptions import GoogleAuthError
    from google.cloud import firestore

    from platform_service.directory import DirectoryError, DirectoryStore
    from platform_service.signing import Keyring

    try:
        store = DirectoryStore(firestore.Client(project=args.platform_project), keyring=Keyring.from_environment())
        records = store.list_records()
    except (RuntimeError, ValueError, DirectoryError, GoogleAuthError, GoogleAPIError) as error:
        print(f"Could not read the company directory: {error}", file=sys.stderr)
        return 2
    rows = compare(records)
    for row in rows:
        verdict = "ok" if row["match"] else "MISMATCH"
        print(f"{verdict:8} {row['tenantId']:24} {row['workspace']:20} recorded={row['recorded']} expected={row['expected']}")
    mismatches = sum(1 for row in rows if not row["match"])
    print(f"{len(rows)} companies checked, {mismatches} mismatch(es).")
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())

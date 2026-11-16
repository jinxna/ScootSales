from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

from .records import RecordError, validate_record

REPO_ROOT = Path(__file__).resolve().parent.parent
EMULATOR_ENV = "FIRESTORE_EMULATOR_HOST"

SUPERMARKET_CONFIG: dict[str, Any] = {
    "apiKey": {
        "android": "AIzaSyBTvOSDWpkpNpgJf4uVpb74qBjHcN1g47A",
        "ios": "AIzaSyBnguMqcvB88jsI9Srri6hixw1wMUXWBZs",
        "web": "AIzaSyDeytVHO_y42bfNY9iGQZ6hqM0Ah7H6iuE",
    },
    "appId": {
        "android": "1:789087499876:android:db3a58e525133a581ed171",
        "ios": "1:789087499876:ios:5ae33707db1392811ed171",
        "web": "1:789087499876:web:38bf7ca370bb5f5f1ed171",
    },
    "messagingSenderId": "789087499876",
    "storageBucket": "cos40005.firebasestorage.app",
    "iosBundleId": "my.scootsales.app",
}
HARDWARE_CONFIG: dict[str, Any] = {
    "apiKey": {
        "android": "AIzaSyDBdvAAr2pMDiYN5K2oIKaWdjl7Wn6BKj8",
        "ios": "AIzaSyC4EUO9nP_vilTHA_NlpDofTxoU3hmfrm4",
        "web": "AIzaSyBAM4TKSDX7qXT8q9zXoM6_9KftPVYfTx8",
    },
    "appId": {
        "android": "1:573265614719:android:9849e6f7653a4f4386ac4a",
        "ios": "1:573265614719:ios:4064c74c54a56e7b86ac4a",
        "web": "1:573265614719:web:2ec72d3946f0f46b86ac4a",
    },
    "messagingSenderId": "573265614719",
    "storageBucket": "hardware-client-sales.firebasestorage.app",
    "iosBundleId": "my.scootsales.app",
}


def _rules_digest(path: Path) -> str:
    return "sha-" + hashlib.sha256(path.read_bytes()).hexdigest()[:12]


def current_rules_version(workspace: str) -> str | None:
    admin_rules = REPO_ROOT / "admin_dashboard" / "firestore.rules"
    return _rules_digest(admin_rules) if admin_rules.exists() else None


def build_records() -> list[dict[str, Any]]:
    admin_rules = REPO_ROOT / "admin_dashboard" / "firestore.rules"
    raw = [
        {
            "tenantId": "t_cos40005",
            "workspace": "supermarket",
            "legalName": "Supermarket client (to be confirmed)",
            "companyCode": "supermarket",
            "location": {"projectId": "cos40005", "databaseId": "(default)", "authTenantId": None},
            "locationKind": "byo",
            "clientConfig": SUPERMARKET_CONFIG,
            "status": "active",
            "planRef": "byo",
            "releaseRing": "pilot",
            "rulesVersion": _rules_digest(admin_rules),
        },
        {
            "tenantId": "t_hardware01",
            "workspace": "hardware",
            "legalName": "Hardware client (to be confirmed)",
            "companyCode": "hardware",
            "location": {
                "projectId": "hardware-client-sales",
                "databaseId": "(default)",
                "authTenantId": None,
            },
            "locationKind": "byo",
            "clientConfig": HARDWARE_CONFIG,
            "status": "active",
            "planRef": "byo",
            "releaseRing": "pilot",
            "rulesVersion": _rules_digest(admin_rules),
        },
    ]
    return [validate_record(item) for item in raw]


def _version_of(envelope: dict[str, Any]) -> int:
    return int(json.loads(envelope["payload"])["version"])


def apply_records(records: list[dict[str, Any]], project: str) -> int:
    from google.cloud import firestore

    from .directory import DirectoryError, DirectoryStore
    from .signing import Keyring, Signer

    try:
        keyring = Keyring.from_environment()
        signer = Signer.from_environment()
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2
    client = firestore.Client(project=project)
    store = DirectoryStore(client, keyring=keyring, signer=signer)

    failures = 0
    for record in records:
        name = record["workspace"]
        try:
            current = store.get(record["tenantId"])
            if current is None:
                envelope = store.put(record, expected_version=0)
                print(f"created {name} v{_version_of(envelope)}")
            elif all(current.get(key) == value for key, value in record.items()):
                print(f"unchanged {name} v{current['version']}")
            else:
                envelope = store.put(record, expected_version=current["version"])
                print(f"updated {name} v{_version_of(envelope)}")
        except DirectoryError as error:
            failures += 1
            print(f"failed {name}: {error}")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Add the two client Firebase projects to the company directory."
    )
    parser.add_argument(
        "--apply", action="store_true", help="write the records (default: print them only)"
    )
    parser.add_argument("--platform-project", help="platform project ID to write to")
    parser.add_argument("--confirm-project", help="repeat the platform project ID to confirm")
    args = parser.parse_args(argv)

    try:
        records = build_records()
    except (RecordError, OSError) as error:
        print(f"Invalid record: {error}", file=sys.stderr)
        return 1

    if not args.apply:
        print(json.dumps(records, indent=2, sort_keys=True))
        return 0

    if not args.platform_project or args.platform_project != args.confirm_project:
        print(
            "--apply needs --platform-project and --confirm-project, and they must be equal.",
            file=sys.stderr,
        )
        return 2
    if not os.environ.get(EMULATOR_ENV):
        print("Live writes are not enabled in this phase.", file=sys.stderr)
        print(f"Set {EMULATOR_ENV} to write to the local emulator.", file=sys.stderr)
        return 2
    return apply_records(records, args.platform_project)


if __name__ == "__main__":
    sys.exit(main())

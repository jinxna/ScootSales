from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import config
from .plans import PlanStore, load_catalogue
from .records import record_payload
from .signing import Signer


def _keygen(args: argparse.Namespace) -> int:
    signer = Signer.generate(args.key_id)
    out = Path(args.out)
    if out.exists():
        print(f"Refusing to overwrite {out}.", file=sys.stderr)
        return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {"keyId": signer.key_id, "seed": signer.seed(), "publicKey": signer.public_key()},
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"{signer.key_id}={signer.public_key()}")
    return 0


def _load_signer(path: str) -> Signer:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return Signer.from_seed(data["keyId"], data["seed"])


def _sign_record(args: argparse.Namespace) -> int:
    signer = _load_signer(args.key_file)
    record = json.loads(Path(args.record_json).read_text(encoding="utf-8"))
    payload = record_payload(
        record,
        version=args.version,
        issued_at=datetime.now(timezone.utc),
        ttl=timedelta(days=args.ttl_days),
    )
    print(json.dumps(signer.sign(payload)))
    return 0


def _seed_plans(args: argparse.Namespace) -> int:
    rows = load_catalogue()
    if not args.apply:
        print(json.dumps(rows, indent=2, sort_keys=True))
        print("Dry run: nothing was written.")
        return 0
    project = args.project or config.PLATFORM_PROJECT_ID
    if args.confirm_project != project:
        print("--apply needs --confirm-project equal to the platform project.", file=sys.stderr)
        return 2
    from google.auth.credentials import AnonymousCredentials
    from google.cloud import firestore

    client = firestore.Client(
        project=project,
        credentials=AnonymousCredentials() if os.environ.get("FIRESTORE_EMULATOR_HOST") else None,
    )
    store = PlanStore(client)
    for row in rows:
        content = {key: value for key, value in row.items() if key not in ("planId", "visibility")}
        number, created = store.write_version(
            row["planId"], content, created_by="seed-plans", visibility=row["visibility"],
            seed_preserve_existing=True,
        )
        if created:
            print(f"created {row['planId']} v{number}")
        else:
            stored = store.get_version(row["planId"], number) or {}
            stored_content = {key: value for key, value in stored.items()
                              if key not in ("version", "createdAt", "createdBy")}
            differences = sorted(key for key in set(content) | set(stored_content)
                                 if key not in content or key not in stored_content
                                 or content[key] != stored_content[key])
            detail = f"catalogue differs: {', '.join(differences)}" if differences else "catalogue matches"
            print(f"preserved {row['planId']} v{number}; visibility only; {detail}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m platform_service.devtool")
    commands = parser.add_subparsers(dest="command", required=True)
    keygen = commands.add_parser("keygen")
    keygen.add_argument("--key-id", required=True)
    keygen.add_argument("--out", required=True)
    keygen.set_defaults(run=_keygen)
    signed_record = commands.add_parser("sign-record")
    signed_record.add_argument("--key-file", required=True)
    signed_record.add_argument("--version", type=int, required=True)
    signed_record.add_argument("--record-json", required=True)
    signed_record.add_argument("--ttl-days", type=float, default=30)
    signed_record.set_defaults(run=_sign_record)
    seed = commands.add_parser("seed-plans")
    seed.add_argument("--apply", action="store_true")
    seed.add_argument("--project", help="platform project ID (default PLATFORM_PROJECT_ID)")
    seed.add_argument("--confirm-project")
    seed.set_defaults(run=_seed_plans)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    raise SystemExit(main())

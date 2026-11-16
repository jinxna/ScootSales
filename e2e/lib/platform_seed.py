import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from google.cloud import firestore  # noqa: E402

from platform_service.directory import DirectoryStore  # noqa: E402
from platform_service.signing import Keyring, Signer  # noqa: E402


def main() -> int:
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print("FIRESTORE_EMULATOR_HOST must be set.", file=sys.stderr)
        return 2
    request = json.load(sys.stdin)
    seeds = dict(part.split("=", 1) for part in os.environ["PLATFORM_SIGNING_KEYS"].split(","))
    client = firestore.Client(project=request["project"])
    keyring = Keyring.from_environment()
    for item in request["records"]:
        key_id = item["keyId"]
        ttl = item.get("ttlDays")
        store = DirectoryStore(
            client,
            keyring=keyring,
            signer=Signer.from_seed(key_id, seeds[key_id]),
            record_ttl=timedelta(days=ttl) if ttl else None,
        )
        issued = item.get("issuedAt")
        store.put(
            item["record"],
            expected_version=0,
            now=datetime.fromisoformat(issued.replace("Z", "+00:00")) if issued else None,
        )
        print(f"stored {item['record']['workspace']} signed by {key_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

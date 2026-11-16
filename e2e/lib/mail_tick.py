import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from google.auth.credentials import AnonymousCredentials  # noqa: E402
from google.cloud import firestore  # noqa: E402

from platform_service.mail import MailQueue, build_transport, deliver_mail  # noqa: E402


def main() -> int:
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print("FIRESTORE_EMULATOR_HOST must be set.", file=sys.stderr)
        return 2
    db = firestore.Client(project=os.environ["PLATFORM_PROJECT_ID"], credentials=AnonymousCredentials())
    result = deliver_mail(MailQueue(db), transport=build_transport(), worker_id="e2e-tick")
    print(json.dumps({name: len(value) if isinstance(value, list) else value for name, value in result.items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

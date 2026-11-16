import hashlib
import json
import os
import secrets
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import jwt  # noqa: E402
from google.auth.credentials import AnonymousCredentials  # noqa: E402
from google.cloud import firestore  # noqa: E402

from platform_service.signing import format_timestamp  # noqa: E402
from platform_service.staff import SESSIONS, STAFF, digest, staff_id  # noqa: E402


def main() -> int:
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print("FIRESTORE_EMULATOR_HOST must be set.", file=sys.stderr)
        return 2
    request = json.load(sys.stdin)
    project = request["project"]
    db = firestore.Client(project=project, credentials=AnonymousCredentials())
    now = datetime.now(timezone.utc)
    moment = int(now.timestamp())
    headers = {}
    for email, role in request["roles"].items():
        uid = request.get("uids", {}).get(email) or "staff-" + hashlib.sha256(email.encode()).hexdigest()[:20]
        if role is not None:
            db.collection(STAFF).document(staff_id(email)).set(
                {"email": email, "name": email.split("@")[0], "role": role, "status": "active",
                 "uid": uid, "createdAt": format_timestamp(now)})
        secret = secrets.token_urlsafe(32)
        db.collection(SESSIONS).document(digest(secret)).set(
            {"uid": uid, "email": email, "authTime": format_timestamp(now), "createdAt": format_timestamp(now),
             "expiresAt": format_timestamp(now + timedelta(hours=12)), "status": "active",
             "userAgent": "e2e", "ip": "127.0.0.1", "deviceHash": None})
        claims = {"iss": f"https://securetoken.google.com/{project}", "aud": project, "sub": uid,
                  "email": email, "email_verified": True, "auth_time": moment - 5, "iat": moment - 5,
                  "exp": moment + 3000, "firebase": {"sign_in_provider": "password"}}
        headers[email] = {"Authorization": "Bearer " + jwt.encode(claims, None, algorithm="none"),
                          "X-Staff-Session": secret}
    print(json.dumps(headers))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

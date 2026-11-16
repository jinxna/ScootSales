from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from platform_service import migrate_seats
from platform_service.invoices import InvoiceBook
from platform_service.mail import MailQueue
from platform_service.payments import PaymentLedger
from platform_service.plans import PlanStore, clean_subscription, load_catalogue
from platform_service.signing import format_timestamp, parse_timestamp

CLERK = "clerk@example.test"
CHECKER = "checker@example.test"


_FIXTURE_PRICES = {"currency": "MYR", "monthly": 100, "yearly": 960}
FIXTURE_PLANS = [
    {"planId": "P1", "visibility": "private", "name": "P1", "edition": "basic",
     "limits": {"salesmen": 2, "supervisors": 1, "managers": 1, "products": 50}, "features": {}, "notes": "",
     "prices": _FIXTURE_PRICES, "tagline": "For a small team", "highlights": [], "sortOrder": 110},
    {"planId": "P2", "visibility": "private", "name": "P2", "edition": "advanced",
     "limits": {"salesmen": 10, "supervisors": 2, "managers": 2, "products": 100}, "features": {}, "notes": "",
     "prices": _FIXTURE_PRICES, "tagline": "For a growing team", "highlights": [], "sortOrder": 120},
    {"planId": "TRIAL", "visibility": "private", "name": "Trial", "edition": "basic",
     "limits": {"salesmen": 2, "supervisors": 1, "managers": 1, "products": 50}, "features": {}, "notes": "",
     "prices": {"currency": "MYR", "monthly": None, "yearly": None}, "tagline": "Trial plan", "highlights": [],
     "sortOrder": 130},
]


def seed_catalogue(client) -> PlanStore:
    store = PlanStore(client)
    for row in [*load_catalogue(), *FIXTURE_PLANS]:
        content = {key: value for key, value in row.items() if key not in ("planId", "visibility")}
        store.write_version(
            row["planId"], content, created_by="test", visibility=row["visibility"],
            seed_preserve_existing=True,
        )
    return store


def make_plan(client, plan_id, **limits):
    content = {
        "name": plan_id, "edition": "basic", "features": {}, "notes": "", "sortOrder": 0,
        "prices": {"currency": "MYR", "monthly": None, "yearly": None},
        "tagline": "", "highlights": [],
        "limits": {key: limits.get(key) for key in ("salesmen", "supervisors", "managers", "products")},
    }
    return PlanStore(client).write_version(plan_id, content, created_by="test", visibility="private")


def seed_subscription(client, tenant_id, plan_id="INTERNAL", **changes):
    store = seed_catalogue(client)
    body = {"planId": plan_id, **changes}
    store.apply_subscription_change(
        tenant_id,
        clean_subscription(body),
        operation_id=f"test-{uuid.uuid4().hex}",
        now=datetime.now(timezone.utc),
    )
    return store


def seed_usage(db):
    plan = migrate_seats.plan_migration(db)
    migrate_seats.apply_migration(db, plan)
    return plan


def in_days(days):
    return (datetime.now(timezone.utc) + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def issued_invoice(db, tenant_id, now, key="invoice-key-0001", *, plan_id="P1", interval="monthly",
                   period_start=None, period_end=None, mail_enabled=False):
    plans = PlanStore(db)
    if plans.get_subscription(tenant_id) is None:
        seed_subscription(db, tenant_id, plan_id, billingInterval=interval)
    book = InvoiceBook(db, plans, clock=lambda: now, mail=MailQueue(db, clock=lambda: now, enabled=mail_enabled))
    body = {} if period_start is None else {"periodStart": period_start}
    draft = book.create_draft(tenant_id, key, body, CLERK)
    if period_end is not None:
        db.collection("invoices").document(draft["invoiceId"]).update({"periodEnd": parse_timestamp(period_end)})
    return book, book.issue(draft["invoiceId"], CLERK)


def payment_ledger(db, now):
    return PaymentLedger(db, clock=lambda: now, mail=MailQueue(db, clock=lambda: now, enabled=False))


def unchecked_payment(db, tenant_id, invoice, now, *, recorder=CLERK):
    return payment_ledger(db, now).record(
        tenant_id, "pay-" + invoice["invoiceId"][-24:],
        {"amountMinor": invoice["outstandingMinor"], "currency": "MYR",
         "externalReference": "BANK/" + invoice["invoiceId"][-24:], "invoiceId": invoice["invoiceId"],
         "receivedAt": format_timestamp(now), "reason": "Bank statement"}, recorder)


def checked_payment(db, tenant_id, invoice, now, *, recorder=CLERK, checker=CHECKER):
    receipt = unchecked_payment(db, tenant_id, invoice, now, recorder=recorder)
    payment_ledger(db, now).check(tenant_id, receipt["entryId"], checker)
    return receipt


def covered_payment(db, tenant_id, now, key, *, recorder="owner@example.test", started_days_ago=1):
    _, invoice = issued_invoice(
        db, tenant_id, now, key, period_start=format_timestamp(now - timedelta(days=started_days_ago)),
        period_end=format_timestamp(now + timedelta(days=30)))
    return unchecked_payment(db, tenant_id, invoice, now, recorder=recorder)


def staff_domains(roles):
    return frozenset(email.rsplit("@", 1)[1] for email in roles)


def staff_assertion(roles):
    import hashlib
    import secrets

    import jwt
    from google.auth.credentials import AnonymousCredentials
    from google.cloud import firestore

    from platform_service import config
    from platform_service.staff import SESSIONS, STAFF, digest, staff_id

    sessions = {}
    clients = {}

    def make(email):
        project = config.PLATFORM_PROJECT_ID
        key = (project, email)
        if project not in clients:
            clients[project] = firestore.Client(project=project, credentials=AnonymousCredentials())
        db = clients[project]
        if key in sessions and not db.collection(SESSIONS).document(sessions[key][0]).get().exists:
            del sessions[key]
        if key not in sessions:
            uid = "staff-" + hashlib.sha256(email.encode()).hexdigest()[:20]
            now = datetime.now(timezone.utc)
            role = roles.get(email)
            if role is not None:
                db.collection(STAFF).document(staff_id(email)).set(
                    {"email": email, "name": email.split("@")[0], "role": role, "status": "active",
                     "uid": uid, "createdAt": format_timestamp(now)})
            secret = secrets.token_urlsafe(32)
            db.collection(SESSIONS).document(digest(secret)).set(
                {"uid": uid, "email": email, "authTime": format_timestamp(now), "createdAt": format_timestamp(now),
                 "expiresAt": format_timestamp(now + timedelta(hours=12)), "status": "active",
                 "userAgent": "test", "ip": "127.0.0.1", "deviceHash": None})
            moment = int(now.timestamp())
            claims = {"iss": f"https://securetoken.google.com/{project}", "aud": project, "sub": uid,
                      "email": email, "email_verified": True, "auth_time": moment - 5, "iat": moment - 5,
                      "exp": moment + 3000, "firebase": {"sign_in_provider": "password"}}
            sessions[key] = (digest(secret), {
                "Authorization": "Bearer " + jwt.encode(claims, None, algorithm="none"), "X-Staff-Session": secret})
        return dict(sessions[key][1])

    return make

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API_BASE = "https://api.brevo.com/v3"
TIMEOUT_SECONDS = 20
PAGE_SIZE = 500
REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_renderer():
    path = REPO_ROOT / "platform_service" / "mail_render.py"
    spec = importlib.util.spec_from_file_location("scoot_mail_render", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class BrevoError(RuntimeError):
    pass


class Brevo:
    def __init__(self, api_key: str):
        self._key = api_key

    def call(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            f"{API_BASE}{path}", data=data, method=method,
            headers={"api-key": self._key, "accept": "application/json", "content-type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = ""
            try:
                detail = str(json.loads(error.read().decode("utf-8")).get("message", ""))[:200]
            except (ValueError, AttributeError):
                pass
            raise BrevoError(self._clean(f"Brevo answered {error.code} to {method} {path}. {detail}".strip())) from None
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise BrevoError(self._clean(f"Brevo could not be reached for {method} {path}: {error}")) from None
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            raise BrevoError(f"Brevo gave an unreadable answer to {method} {path}.") from None

    def _clean(self, message: str) -> str:
        return message.replace(self._key, "***") if self._key else message

    def account_email(self) -> str:
        account = self.call("GET", "/account")
        email = account.get("email") if isinstance(account, dict) else None
        if not isinstance(email, str) or not email:
            raise BrevoError("Brevo did not return the account email.")
        return email

    def templates(self) -> list[dict[str, Any]]:
        found: list[dict[str, Any]] = []
        offset = 0
        while True:
            page = self.call("GET", f"/smtp/templates?limit={PAGE_SIZE}&offset={offset}&sort=asc")
            rows = page.get("templates", []) if isinstance(page, dict) else []
            found.extend(rows)
            offset += PAGE_SIZE
            if len(rows) < PAGE_SIZE:
                return found


def local_templates(renderer) -> dict[str, dict[str, str]]:
    problems = renderer.check_templates()
    if problems:
        raise SystemExit("The repository templates are not valid:\n" + "\n".join(problems))
    result: dict[str, dict[str, str]] = {}
    for name, entry in renderer.catalogue().items():
        html = (renderer.TEMPLATE_DIR / f"{name}.html").read_text(encoding="utf-8")
        result[name] = {"subject": entry["subject"], "html": html, "brevoName": entry["brevoTemplateName"]}
    return result


def build_plan(local: dict[str, dict[str, str]], remote: list[dict[str, Any]] | None) -> dict[str, dict[str, Any]]:
    by_name: dict[str, list[dict[str, Any]]] = {}
    for row in remote or []:
        by_name.setdefault(str(row.get("name")), []).append(row)
    plan: dict[str, dict[str, Any]] = {}
    for kind, entry in local.items():
        matches = by_name.get(entry["brevoName"], [])
        if remote is None:
            plan[kind] = {"action": "unknown", "id": None, "brevoName": entry["brevoName"]}
        elif len(matches) > 1:
            plan[kind] = {"action": "duplicate", "id": None, "brevoName": entry["brevoName"]}
        elif not matches:
            plan[kind] = {"action": "create", "id": None, "brevoName": entry["brevoName"]}
        else:
            row = matches[0]
            same = (str(row.get("subject", "")) == entry["subject"]
                    and str(row.get("htmlContent", "")).strip() == entry["html"].strip()
                    and row.get("isActive") is True)
            plan[kind] = {"action": "same" if same else "update", "id": row.get("id"),
                          "brevoName": entry["brevoName"]}
    return plan


def print_plan(plan: dict[str, dict[str, Any]], remote_read: bool) -> None:
    if not remote_read:
        print("Brevo was not read (no BREVO_API_KEY). Every template below needs a check.", file=sys.stderr)
    for kind, item in plan.items():
        suffix = f" (id {item['id']})" if item["id"] is not None else ""
        print(f"{item['action']:<9} {kind:<28} {item['brevoName']}{suffix}", file=sys.stderr)


def apply_plan(client: Brevo, plan: dict[str, dict[str, Any]], local: dict[str, dict[str, str]],
               sender_name: str, sender_email: str, ids: dict[str, Any]) -> None:
    for kind, item in plan.items():
        entry = local[kind]
        if item["action"] == "create":
            created = client.call("POST", "/smtp/templates", {
                "templateName": entry["brevoName"], "subject": entry["subject"], "htmlContent": entry["html"],
                "sender": {"name": sender_name, "email": sender_email}, "isActive": True})
            if not isinstance(created, dict) or not isinstance(created.get("id"), int):
                raise BrevoError(f"Brevo did not return an id for {entry['brevoName']}.")
            ids[kind] = created["id"]
            print(f"created   {kind} -> {created['id']}", file=sys.stderr)
        elif item["action"] == "update":
            client.call("PUT", f"/smtp/templates/{item['id']}", {
                "subject": entry["subject"], "htmlContent": entry["html"], "isActive": True})
            print(f"updated   {kind} -> {item['id']}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compare the repository mail templates with Brevo and upload them.")
    parser.add_argument("--apply", action="store_true", help="Write to Brevo. Without it, nothing is written.")
    parser.add_argument("--confirm-account", metavar="EMAIL",
                        help="The Brevo account email. Checked against Brevo before any write.")
    parser.add_argument("--sender-email", default=os.environ.get("PLATFORM_MAIL_SENDER", ""),
                        help="Verified sender for new templates. Default: PLATFORM_MAIL_SENDER.")
    parser.add_argument("--sender-name", default="Scoot Sales")
    args = parser.parse_args(argv)

    renderer = _load_renderer()
    local = local_templates(renderer)
    api_key = os.environ.get("BREVO_API_KEY", "").strip()

    if args.apply and not api_key:
        print("BREVO_API_KEY is not set. Nothing was written.", file=sys.stderr)
        return 2
    if args.apply and not args.confirm_account:
        print("--apply needs --confirm-account <Brevo account email>. Nothing was written.", file=sys.stderr)
        return 2

    client = Brevo(api_key) if api_key else None
    remote: list[dict[str, Any]] | None = None
    try:
        if client is not None:
            account = client.account_email()
            print(f"Brevo account: {account}", file=sys.stderr)
            if args.apply and account.strip().lower() != args.confirm_account.strip().lower():
                print("The Brevo account does not match --confirm-account. Nothing was written.", file=sys.stderr)
                return 2
            remote = client.templates()
        plan = build_plan(local, remote)
        print_plan(plan, remote is not None)
        if any(item["action"] == "duplicate" for item in plan.values()):
            print("Brevo holds two templates with one repository name. Remove one. Nothing was written.",
                  file=sys.stderr)
            return 1
        if not args.apply:
            print("Dry run. Nothing was written. Add --apply --confirm-account <email> to write.", file=sys.stderr)
            print(json.dumps({kind: item["id"] for kind, item in plan.items()}, indent=2))
            return 0
        if any(item["action"] == "create" for item in plan.values()) and "@" not in args.sender_email:
            print("New templates need a verified sender: set PLATFORM_MAIL_SENDER or --sender-email. "
                  "Nothing was written.", file=sys.stderr)
            return 2
        ids = {kind: item["id"] for kind, item in plan.items()}
        try:
            apply_plan(client, plan, local, args.sender_name, args.sender_email, ids)
        except BrevoError:
            print("Stopped part way. Ids known so far:", file=sys.stderr)
            print(json.dumps(ids, indent=2), file=sys.stderr)
            raise
    except BrevoError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(ids, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HEADERS_HELP = """Statically check the Nginx policy or HEAD-check a hosted Flutter Web site."""

DEFAULT_OUTPUT = Path("qa_artifacts/p3-release-ops/web-headers.json")
HASHED_ASSET = re.compile(r"^/.*[.-][a-f0-9]{8,}\.[a-z0-9]+$", re.IGNORECASE)
SELECTED_HEADERS = (
    "cache-control",
    "strict-transport-security",
    "permissions-policy",
    "x-content-type-options",
    "x-frame-options",
    "referrer-policy",
    "content-security-policy-report-only",
    "content-type",
    "location",
)
MUTABLE_PATHS = ("/", "/index.html", "/flutter_bootstrap.js", "/main.dart.js", "/version.json")
EXPECTED_CSP = (
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com https://apis.google.com; "
    "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; "
    "font-src 'self' data: https://fonts.gstatic.com; "
    "connect-src 'self' https://*.googleapis.com https://www.gstatic.com https://fonts.gstatic.com; "
    "frame-src https://*.firebaseapp.com; worker-src 'self' blob:; base-uri 'self'; object-src 'none'; form-action 'self'"
)
EXPECTED_HEADERS = {
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "strict-origin-when-cross-origin",
    "permissions-policy": "camera=(), microphone=(self), geolocation=()",
    "content-security-policy-report-only": EXPECTED_CSP,
}


def _cache_directives(value: str) -> dict[str, str | bool]:
    parsed: dict[str, str | bool] = {}
    for item in value.lower().split(","):
        name, separator, argument = item.strip().partition("=")
        parsed[name] = argument.strip(' "') if separator else True
    return parsed


def _valid_url(value: str) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("URL must use HTTP or HTTPS and contain a host without credentials.")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValueError("URL must be an origin only; checks use fixed paths.")
    return parsed


class SameHostRedirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, hostname: str, require_https: bool):
        super().__init__()
        self.hostname = hostname.lower()
        self.require_https = require_https
        self.count = 0

    def redirect_request(self, request, response, code, message, headers, new_url):
        parsed = urllib.parse.urlsplit(new_url)
        if parsed.hostname is None or parsed.hostname.lower() != self.hostname:
            raise urllib.error.URLError("Redirect to a different host refused")
        if self.require_https and parsed.scheme != "https":
            raise urllib.error.URLError("HTTPS downgrade redirect refused")
        self.count += 1
        if self.count > 5:
            raise urllib.error.URLError("Redirect limit exceeded")
        return urllib.request.Request(
            new_url,
            headers=request.headers,
            origin_req_host=request.origin_req_host,
            unverifiable=True,
            method="HEAD",
        )


def _head(url: str, host: str, require_https: bool) -> dict:
    redirects = SameHostRedirects(host, require_https)
    opener = urllib.request.build_opener(redirects)
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "web-header-check/1"})
    started = time.monotonic()
    try:
        with opener.open(request, timeout=15) as response:
            raw = response.headers
            return {
                "status": response.status,
                "headers": {name.lower(): raw.get(name) for name in SELECTED_HEADERS if raw.get(name) is not None},
                "set_cookie_present": bool(raw.get_all("Set-Cookie")),
                "elapsed_seconds": round(time.monotonic() - started, 3),
            }
    except urllib.error.HTTPError as error:
        raw = error.headers
        return {
            "status": error.code,
            "headers": {name.lower(): raw.get(name) for name in SELECTED_HEADERS if raw.get(name) is not None},
            "set_cookie_present": bool(raw.get_all("Set-Cookie")),
            "elapsed_seconds": round(time.monotonic() - started, 3),
        }
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return {
            "status": None,
            "headers": {},
            "set_cookie_present": False,
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "error": f"{type(error).__name__}: {error}"[:300],
        }


def _brace_contexts(source: str):
    depth = 0
    for line in source.splitlines():
        yield depth, line
        clean = line.split("#", 1)[0]
        depth += clean.count("{") - clean.count("}")


def check_config(path: Path) -> tuple[list[dict], list[str]]:
    source = path.read_text(encoding="utf-8")
    errors: list[str] = []
    contexts = list(_brace_contexts(source))
    lower = source.lower()
    server_lines: list[tuple[int, str]] = []
    https_headers: list[str] = []
    https_body: list[str] = []
    for depth, line in [*contexts, (0, "")]:
        clean = line.split("#", 1)[0]
        if depth < 2 and server_lines:
            if any(level == 2 and re.search(r"\blisten\s+443\s+ssl\s*;", item) for level, item in server_lines):
                https_headers.extend(item for level, item in server_lines if level == 2)
                https_body.extend(item for _, item in server_lines)
            server_lines = []
        if depth >= 2:
            server_lines.append((depth, clean))
    header_source = "\n".join(https_headers)
    workspace_route = bool(re.search(
        r"(?m)^\s*location\s*=\s*/workspace\.json\s*\{\s*try_files\s+\$uri\s+=404;\s*\}",
        "\n".join(https_body),
    ))
    if not workspace_route:
        errors.append("HTTPS template must use location = /workspace.json with try_files $uri =404; and no SPA fallback.")

    if not re.search(r"map\s+\$uri\s+\$web_cache_control\s*\{[^}]*default\s+\"no-cache\";", source, re.S):
        errors.append("URI cache map must default to no-cache.")
    hash_rule = re.search(r'(?m)^\s*"(~\*[^\"]+)"\s+"public,\s*max-age=31536000,\s*immutable"\s*;', source)
    if not hash_rule:
        errors.append("Long immutable caching must be assigned only by a hash filename rule.")
    else:
        try:
            pattern = re.compile(hash_rule.group(1)[2:], re.IGNORECASE)
            if not pattern.fullmatch("/assets/app-a1b2c3d4e5f6.js") or pattern.fullmatch("/main.dart.js"):
                errors.append("Immutable cache regex must match a hashed asset and reject unhashed Flutter files.")
        except re.error:
            errors.append("Immutable asset regex is invalid.")
    if "return 301 https://$host$request_uri;" not in lower:
        errors.append("HTTP server must redirect requests to HTTPS.")
    hsts = re.search(r"add_header\s+strict-transport-security\s+\"max-age=([1-9]\d*)\"\s+always;", header_source, re.I)
    if not hsts:
        errors.append("HTTPS server must send HSTS with always.")
    baseline_checks = []
    for name, expected in EXPECTED_HEADERS.items():
        match = re.search(rf'add_header\s+{re.escape(name)}\s+"([^\"]+)"\s+always;', header_source, re.I)
        ok = bool(match and match.group(1) == expected)
        baseline_checks.append((name, ok))
        if not ok:
            errors.append(f"HTTPS server must send {name}: {expected} with always.")
    csp = re.search(r"add_header\s+content-security-policy-report-only\s+\"([^\"]+)\"\s+always;", header_source, re.I)
    if not csp:
        errors.append("CSP must remain Content-Security-Policy-Report-Only and use always.")
    elif csp.group(1) != EXPECTED_CSP:
        errors.append("Report-only CSP differs from the existing repository policy.")

    server_scope_cache = any(depth == 2 and re.search(r"add_header\s+cache-control\s+\$web_cache_control\s+always;", line, re.I) for depth, line in contexts)
    if not server_scope_cache:
        errors.append("Cache-Control must be set at HTTPS server scope to preserve header inheritance.")
    for depth, line in contexts:
        if depth >= 3 and re.search(r"\badd_header\b", line, re.I):
            errors.append("Do not set add_header inside locations; it replaces inherited headers.")
            break

    checks = [
        ("http_redirect", "return 301 https://$host$request_uri;" in lower),
        ("workspace_record_no_spa_fallback", workspace_route),
        ("no_cache_default", bool(re.search(r"map\s+\$uri\s+\$web_cache_control\s*\{[^}]*default\s+\"no-cache\";", source, re.S))),
        ("hashed_assets_immutable", bool(hash_rule)),
        ("hsts_always", bool(hsts)),
        *baseline_checks,
        ("csp_report_only", bool(csp)),
        ("server_level_headers_only", not any(depth >= 3 and re.search(r"\badd_header\b", line, re.I) for depth, line in contexts)),
    ]
    return [{"name": name, "ok": ok} for name, ok in checks], errors


def run_url(base: str, asset: str | None) -> tuple[dict, list[dict]]:
    origin = _valid_url(base)
    paths = list(MUTABLE_PATHS)
    if asset:
        parsed_asset = urllib.parse.urlsplit(asset)
        if parsed_asset.scheme or parsed_asset.netloc or parsed_asset.query or parsed_asset.fragment or not HASHED_ASSET.fullmatch(parsed_asset.path):
            raise ValueError("--asset must be a root-relative filename containing an explicit hexadecimal content hash.")
        paths.append(parsed_asset.path)
    responses = []
    checks: list[dict] = []
    for path in paths:
        result = _head(urllib.parse.urljoin(base.rstrip("/") + "/", path.lstrip("/")), origin.hostname or "", origin.scheme == "https")
        responses.append({"path": path, "method": "HEAD", **result})
        status_ok = result.get("status") is not None and 200 <= result["status"] < 300
        checks.append({"name": f"{path}:status", "ok": status_ok, "detail": result.get("status") or result.get("error", "unknown")})
        headers = result.get("headers", {})
        for name in ("strict-transport-security", *EXPECTED_HEADERS):
            value = headers.get(name, "")
            if name == "strict-transport-security":
                match = re.search(r"(?:^|;)\s*max-age=(\d+)", value, re.I)
                ok = bool(match and int(match.group(1)) > 0)
            else:
                ok = value.strip() == EXPECTED_HEADERS[name]
            checks.append({"name": f"{path}:{name}", "ok": ok, "detail": value or "missing"})
        cache = _cache_directives(headers.get("cache-control", ""))
        if path in MUTABLE_PATHS:
            checks.append({"name": f"{path}:cache-control-no-cache", "ok": "no-cache" in cache, "detail": headers.get("cache-control", "missing")})
        elif path == asset:
            max_age = cache.get("max-age", "0")
            long_lived = str(max_age).isdigit() and int(str(max_age)) >= 31536000
            checks.append({"name": f"{path}:cache-control-immutable", "ok": long_lived and cache.get("immutable") is True, "detail": headers.get("cache-control", "missing")})

    artifact = {
        "kind": "public-web-header-smoke",
        "base_url": base,
        "checked_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "method": "HEAD",
        "responses": responses,
        "checks": checks,
        "passed": sum(bool(check["ok"]) for check in checks),
        "failed": sum(not bool(check["ok"]) for check in checks),
        "note": "Only selected response headers were saved. Set-Cookie values and response bodies were not saved.",
    }
    return artifact, checks


def _write_artifact(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=HEADERS_HELP)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--config", type=Path, help="Static-check an Nginx configuration; makes no network requests")
    mode.add_argument("--url", help="Origin to check with HEAD requests only")
    parser.add_argument("--asset", help="Optional root-relative, content-hashed asset path")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Ignored JSON evidence path")
    args = parser.parse_args(argv)
    if args.asset and not args.url:
        parser.error("--asset requires --url")
    try:
        if args.config:
            checks, errors = check_config(args.config)
            document = {"kind": "nginx-static-check", "config": str(args.config), "checks": checks, "passed": sum(c["ok"] for c in checks), "failed": sum(not c["ok"] for c in checks), "errors": errors}
        else:
            document, checks = run_url(args.url, args.asset)
            errors = [f"{check['name']}: {check.get('detail', 'failed')}" for check in checks if not check["ok"]]
    except (OSError, ValueError) as error:
        parser.error(str(error))
    _write_artifact(args.output, document)
    for check in document["checks"]:
        detail = f" ({check['detail']})" if check.get("detail") else ""
        print(f"[{'PASS' if check['ok'] else 'FAIL'}] {check['name']}{detail}")
    print(f"{document['passed']}/{document['passed'] + document['failed']} checks passed; artifact: {args.output}")
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

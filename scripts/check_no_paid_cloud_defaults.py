#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import io
import os
import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


def _git_paths(*args: str) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return [
        line.strip().replace("\\", "/")
        for line in result.stdout.splitlines()
        if line.strip()
    ]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(
        encoding="utf-8",
        errors="replace",
    )


def main() -> int:
    failures: list[str] = []

    candidates = _git_paths(
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
    )
    sensitive_names = re.compile(
        r"(^|/)(serviceAccountKey\.json|\.env(\..+)?|ORS_API_KEY\.local)$",
        re.IGNORECASE,
    )
    unexpected_sensitive = [
        path
        for path in candidates
        if sensitive_names.search(path) and not path.endswith(".env.example")
    ]
    if unexpected_sensitive:
        failures.append(
            "secret-like commit candidates: " + ", ".join(unexpected_sensitive)
        )

    workflow_paths = _git_paths("ls-files", ".github/workflows/*")
    activation_pattern = re.compile(
        r"\b(?:firebase\s+deploy|gcloud\s+"
        r"(?:run\s+(?:deploy|jobs\s+(?:create|deploy))|"
        r"scheduler\s+jobs\s+create|"
        r"iam\s+service-accounts\s+create|"
        r"secrets\s+create))\b",
        re.IGNORECASE,
    )
    for path in workflow_paths:
        if activation_pattern.search(_read(path)):
            failures.append(f"cloud activation command present in CI workflow: {path}")

    runner_dockerfile = _read("Dockerfile.ai-runner")
    for required in (
        "AI_RUNNER_DISABLE_LOCAL_KEYS=1",
        "USER app",
        'CMD ["--dry-run"]',
    ):
        if required not in runner_dockerfile:
            failures.append(f"Dockerfile.ai-runner missing safe default: {required}")

    otp_source = _read("server.js")
    for required in (
        "OTP_DEV_ACKNOWLEDGED",
        "assertDevOnlyMode",
        "The bundled static server is dev-only",
    ):
        if required not in otp_source:
            failures.append(f"server.js missing dev-only server control: {required}")
    if "rejectUnauthorized: false" in otp_source:
        failures.append("server.js disables TLS certificate verification")

    compose = _read("docker-compose.yml")
    for required in (
        'OTP_MODE: dev-mailpit',
        'OTP_DEV_ACKNOWLEDGED: "1"',
        "127.0.0.1:8025:8025",
        "127.0.0.1:8080:8080",
    ):
        if required not in compose:
            failures.append(f"docker-compose.yml missing local-only control: {required}")

    previous_push = os.environ.pop("FORECAST_PUSH_FIRESTORE", None)
    previous_key = os.environ.pop("FIREBASE_SERVICE_ACCOUNT", None)
    try:
        from forecasting.ai_service.cli import build_parser
        from forecasting.service import config

        parser = build_parser()
        if parser.parse_args([]).dry_run is not True:
            failures.append("AI runner does not default to dry-run")
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                parser.parse_args(["--apply"])
        except SystemExit as error:
            if error.code != 2:
                failures.append("AI runner apply-only gate exits unexpectedly")
        else:
            failures.append("AI runner accepts --apply without project confirmation")
        accepted = parser.parse_args(
            [
                "--apply",
                "--project",
                "dev",
                "--confirm",
                "APPLY-cos40005",
            ]
        )
        if accepted.dry_run is not False or accepted.project != "dev":
            failures.append("AI runner rejects its exact dev write gate")
        if config.PUSH_FIRESTORE is not False:
            failures.append("Forecast API Firestore mirroring is not opt-in")
        if config.SERVICE_ACCOUNT_KEY is not None:
            failures.append("Forecast API defaults to a credential file")
    finally:
        if previous_push is not None:
            os.environ["FORECAST_PUSH_FIRESTORE"] = previous_push
        if previous_key is not None:
            os.environ["FIREBASE_SERVICE_ACCOUNT"] = previous_key

    if failures:
        print("No-paid-cloud defaults check failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("No-paid-cloud defaults check passed.")
    print(
        "- AI runner defaults to dry-run and requires project-bound "
        "write confirmation."
    )
    print("- AI runner rejects container key files.")
    print("- Forecast Firestore mirroring is opt-in.")
    print("- The bundled static server is explicit dev-only and loopback-bound.")
    print("- CI contains no cloud activation commands.")
    print("- No secret-like files are commit candidates.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

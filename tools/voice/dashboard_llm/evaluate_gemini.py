from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any, Optional

from tools.voice.dashboard_llm import evaluate_copilot as ev
from tools.voice.dashboard_llm.gemini_client import DEFAULT_BASE_URL, DEFAULT_MODEL, GeminiGenerator

REPO_ROOT = Path(__file__).resolve().parents[3]


def read_api_key() -> str:
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    env_file = REPO_ROOT / ".env"
    if not key and env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            name, _, value = line.partition("=")
            if name.strip() == "GEMINI_API_KEY":
                key = value.strip().strip("\"'")
    if not key:
        raise SystemExit("GEMINI_API_KEY is not set. Set it in your terminal or in the repository .env file.")
    return key


def main(argv: Optional[list[str]] = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--base-url", default=DEFAULT_BASE_URL)
    ap.add_argument("--sets", default="frozen,nav80", help="frozen,test,nav80 (test has 1200 phrases: use --limit)")
    ap.add_argument("--limit", type=int, default=0, help="first N cases per set")
    ap.add_argument("--seconds-between-calls", type=float, default=6.0, help="free-tier rate limit: 6 s = 10 per minute")
    ap.add_argument("--data-dir", type=Path, default=ev.DATA)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args(argv)

    loaders = {"frozen": ev.load_frozen, "test": lambda: ev.load_test(args.data_dir), "nav80": ev.load_nav80}
    sets = {name: loaders[name]() for name in args.sets.split(",")}
    if args.limit:
        sets = {name: cases[: args.limit] for name, cases in sets.items()}
    generate = GeminiGenerator(read_api_key(), args.model, args.base_url, seconds_between_calls=0)

    report: dict[str, Any] = {
        "ranAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "schema": "copilot-eval-report/1",
        "model": args.model, "promptNote": "SYSTEM_PROMPT in evaluate_gemini.py; forced function calling; temperature 0",
        "results": {},
    }
    for set_name, cases in sets.items():
        rows = []
        for case in cases:
            time.sleep(args.seconds_between_calls)
            rows += ev.run(generate, [case])
        report["results"][f"gemini/{set_name}"] = ev.summarise(rows)
        print(set_name, report["results"][f"gemini/{set_name}"]["latencyMs"], flush=True)
    report["modelVersion"] = generate.model_version
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    for key, result in report["results"].items():
        print(key)
        print(" ", result["sweep"][0])


if __name__ == "__main__":
    main()

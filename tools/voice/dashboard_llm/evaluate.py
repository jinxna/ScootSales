from __future__ import annotations

import argparse
import json
import os
import statistics
import time
from pathlib import Path

from tools.voice.dashboard_llm import service
from tools.voice.dashboard_llm.train.make_dataset import DATA, request_pages

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[2] / "e2e" / "output" / "dashboard_voice_llm_eval_finetuned.json"
THRESHOLDS = (0.0, 0.5, 0.7, 0.9, 0.95, 0.98, 0.99, 0.995, 0.999, 0.9995)


def score(rows: list[dict], threshold: float) -> dict:
    rows = [r for r in rows if r.get("kind") != "compound"]
    pos = [r for r in rows if r["expect"]]
    neg = [r for r in rows if not r["expect"]]
    pred = lambda r: r["pageKey"] if r["confidence"] >= threshold else None
    wrong = sum(1 for r in rows if pred(r) not in (None, r["expect"]))
    return {
        "threshold": threshold,
        "cases": len(rows),
        "exactMatch": round(sum(pred(r) == r["expect"] for r in rows) / len(rows), 4),
        "wrongPage": round(wrong / len(rows), 4),
        "wrongCount": wrong,
        "yieldOnAnswerable": round(sum(pred(r) == r["expect"] for r in pos) / max(1, len(pos)), 4),
        "abstainOnNegatives": round(sum(pred(r) is None for r in neg) / max(1, len(neg)), 4),
        "answerable": len(pos),
        "negatives": len(neg),
    }


def run(gen, cases: list[dict], pages_of) -> list[dict]:
    rows = []
    for case in cases:
        result = service.propose(gen, {"text": case["text"], "pages": pages_of(case)}, 0.0)
        rows.append({**case, **result})
    return rows


def load_json_set(name: str) -> tuple[list[dict], object]:
    data = json.loads((HERE / name).read_text(encoding="utf-8"))
    return data["cases"], lambda c: data["catalogues"][c["catalogue"]]


def load_split(name: str, data_dir: Path = DATA) -> tuple[list[dict], object]:
    rows = [json.loads(x) for x in (data_dir / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()]
    cases = [{"text": r["text"], "expect": None if r["target"] == service.NO_MATCH else r["target"], "kind": r["kind"], "row": r} for r in rows]
    return cases, lambda c: request_pages(c["row"])


def load_challenge(path: Path) -> tuple[list[dict], object]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    cases = [
        {
            **row,
            "expect": None if row["target"] == service.NO_MATCH else row["target"],
            "row": row,
        }
        for row in rows
    ]
    return cases, lambda c: request_pages(c["row"])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", type=Path, default=DATA)
    ap.add_argument("--output", type=Path, default=OUT)
    ap.add_argument("--challenge", type=Path)
    ap.add_argument("--challenge-only", action="store_true")
    ap.add_argument("--wrong", action="store_true")
    args = ap.parse_args()
    if args.challenge_only and args.challenge is None:
        ap.error("--challenge-only requires --challenge")

    model_dir = os.environ.get("DASHBOARD_VOICE_MODEL_DIR", service.DEFAULT_MODEL_DIR)
    variants = {"base": None}
    adapter = service.resolve_adapter_dir()
    if adapter:
        variants["finetuned"] = adapter
    sets = {} if args.challenge_only else {
        "eval80": load_json_set("eval_phrases.json"),
        "test": load_split("test", args.data_dir),
        "fresh30": load_json_set("fresh_phrases.json"),
        "validation": load_split("validation", args.data_dir),
    }
    if args.challenge is not None:
        sets["challenge"] = load_challenge(args.challenge)
    report: dict = {"ranAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "results": {}}
    for vname, adir in variants.items():
        gen = service.GemmaGenerator(model_dir, adapter_dir=adir)
        gen("warm up", [{"key": "dashboard", "label": "Dashboard", "aliases": []}])
        report["device"] = "cuda" if gen._torch.cuda.is_available() else "cpu"
        for sname, (cases, pages_of) in sets.items():
            rows = run(gen, cases, pages_of)
            lat = sorted(r["latencyMs"] for r in rows)
            report["results"][f"{vname}/{sname}"] = {
                "latencyMs": {"p50": int(statistics.median(lat)), "p95": lat[int(len(lat) * 0.95) - 1]},
                "sweep": [score(rows, t) for t in THRESHOLDS],
                "rows": [{k: v for k, v in r.items() if k != "row"} for r in rows],
            }
            print(vname, sname, report["results"][f"{vname}/{sname}"]["latencyMs"], flush=True)
        del gen
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=1), encoding="utf-8")
    for key, res in report["results"].items():
        print(key)
        for s in res["sweep"]:
            print(" ", s)
    if args.wrong:
        for key, res in report["results"].items():
            for r in res["rows"]:
                if r["pageKey"] != r["expect"]:
                    print(key, r["confidence"], r["text"], "->", r["pageKey"], "expected", r["expect"])


if __name__ == "__main__":
    main()

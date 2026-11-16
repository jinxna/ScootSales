from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path
from typing import Any, Optional

from tools.voice.dashboard_llm import copilot_schema as schema
from tools.voice.dashboard_llm.train import make_dataset as md

HERE = Path(__file__).resolve().parent
DATA = HERE / "train" / "data_copilot"
THRESHOLDS = (0.0, 0.5, 0.7, 0.9, 0.95, 0.98, 0.99, 0.995, 0.999)
REPORT_AT = 0.98


def same_call(a: Optional[dict], b: Optional[dict]) -> bool:
    if a is None or b is None:
        return a is b
    if a["name"] != b["name"] or set(a["args"]) != set(b["args"]):
        return False
    for key, value in a["args"].items():
        other = b["args"][key]
        if isinstance(value, str) and isinstance(other, str):
            if value.casefold() != other.casefold():
                return False
        elif value != other:
            return False
    return True


def _pred(row: dict, threshold: float) -> Optional[dict]:
    return row["call"] if row["confidence"] >= threshold else None


def score_rows(rows: list[dict], threshold: float) -> dict[str, Any]:
    pos = [r for r in rows if r["expect"] is not None]
    neg = [r for r in rows if r["expect"] is None]
    preds = [(r, _pred(r, threshold)) for r in rows]
    wrong = sum(1 for r, p in preds if p is not None and not same_call(p, r["expect"]))
    answered_right = sum(1 for r in pos if same_call(_pred(r, threshold), r["expect"]))
    name_right = sum(
        1 for r in pos if (p := _pred(r, threshold)) is not None and p["name"] == r["expect"]["name"]
    )
    return {
        "threshold": threshold,
        "cases": len(rows),
        "wrongCall": round(wrong / max(1, len(rows)), 4),
        "wrongCount": wrong,
        "yield": round(answered_right / max(1, len(pos)), 4),
        "nameYield": round(name_right / max(1, len(pos)), 4),
        "abstainOnNegatives": round(sum(1 for r in neg if _pred(r, threshold) is None) / max(1, len(neg)), 4),
        "answerable": len(pos),
        "negatives": len(neg),
    }


def breakdown(rows: list[dict], threshold: float, key: str) -> dict[str, dict[str, Any]]:
    groups: dict[str, list[dict]] = {}
    for row in rows:
        groups.setdefault(str(row.get(key, "")), []).append(row)
    return {name: score_rows(group, threshold) for name, group in sorted(groups.items())}


def _pages(keys: list[str]) -> list[dict]:
    return md.request_pages({"pages": keys, "aliasSeed": 0})


def catalogue(name: str) -> list[dict]:
    admin = [k for k in md.ORDER if not k.startswith("team_")]
    keys = {"admin": admin, "supervisor": md.ROLES["supervisor"], "manager": md.ROLES["manager"]}[name]
    return _pages(keys)


def load_frozen(path: Path = HERE / "copilot_eval_phrases.json") -> list[dict]:
    cases = json.loads(path.read_text(encoding="utf-8"))["cases"]
    return [
        {
            "text": c["text"], "lang": c["lang"], "expect": c["expect"],
            "kind": (c["expect"] or {"name": "no_match"})["name"],
            "request": {"text": c["text"], "pages": catalogue(c["catalogue"]),
                        "actions": c.get("actions", list(schema.ACTION_ORDER))},
        }
        for c in cases
    ]


def load_test(data_dir: Path = DATA, split: str = "test") -> list[dict]:
    from tools.voice.dashboard_llm.train import make_copilot_dataset as ds

    rows = [json.loads(x) for x in (data_dir / f"{split}.jsonl").read_text(encoding="utf-8").splitlines()]
    return [
        {
            "text": r["text"], "lang": r["lang"], "kind": r["kind"].split(":")[0],
            "expect": None if r["target"]["name"] == schema.NO_MATCH else r["target"],
            "request": ds.to_request(r),
        }
        for r in rows
    ]


def load_nav80(path: Path = HERE / "eval_phrases.json") -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    out = []
    for c in data["cases"]:
        if c.get("kind") == "compound":
            continue
        expect = c.get("expect")
        out.append({
            "text": c["text"], "lang": "en", "kind": "nav",
            "expect": None if expect in (None, md.NO_MATCH) else {"name": schema.NAVIGATE, "args": {"page": expect}},
            "request": {"text": c["text"], "pages": data["catalogues"][c["catalogue"]],
                        "actions": list(schema.ACTION_ORDER)},
        })
    return out


def run(generate, cases: list[dict]) -> list[dict]:
    from tools.voice.dashboard_llm import copilot_model

    rows = []
    for case in cases:
        result = copilot_model.interpret(generate, case["request"], 0.0)
        rows.append({k: v for k, v in case.items() if k != "request"} | result)
    return rows


def summarise(rows: list[dict]) -> dict[str, Any]:
    latency = sorted(r["latencyMs"] for r in rows)
    return {
        "latencyMs": {"p50": int(statistics.median(latency)), "p95": latency[max(0, int(len(latency) * 0.95) - 1)]},
        "sweep": [score_rows(rows, t) for t in THRESHOLDS],
        f"byLang@{REPORT_AT}": breakdown(rows, REPORT_AT, "lang"),
        f"byKind@{REPORT_AT}": breakdown(rows, REPORT_AT, "kind"),
        "rows": rows,
    }


def main(argv: Optional[list[str]] = None) -> None:
    from tools.voice.dashboard_llm import copilot_model

    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--adapter-dir")
    ap.add_argument("--no-base", action="store_true", help="skip the untuned base model")
    ap.add_argument("--data-dir", type=Path, default=DATA)
    ap.add_argument("--sets", default="frozen,test,nav80")
    ap.add_argument("--limit", type=int, default=0, help="first N cases per set (smoke test)")
    ap.add_argument("--device")
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args(argv)

    loaders = {
        "frozen": load_frozen,
        "test": lambda: load_test(args.data_dir),
        "validation": lambda: load_test(args.data_dir, "validation"),
        "nav80": load_nav80,
    }
    sets = {name: loaders[name]() for name in args.sets.split(",")}
    if args.limit:
        sets = {name: cases[: args.limit] for name, cases in sets.items()}
    variants: dict[str, Optional[str]] = {} if args.no_base else {"base": None}
    if args.adapter_dir:
        variants["adapter"] = args.adapter_dir

    report: dict[str, Any] = {"ranAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "schema": "copilot-eval-report/1", "results": {}}
    for name, adapter in variants.items():
        generate = copilot_model.CopilotGenerator(args.model_dir, adapter_dir=adapter, device=args.device)
        generate("warm up", [], list(schema.ACTION_ORDER))
        report["device"] = generate.device
        for set_name, cases in sets.items():
            rows = run(generate, cases)
            report["results"][f"{name}/{set_name}"] = summarise(rows)
            print(name, set_name, report["results"][f"{name}/{set_name}"]["latencyMs"], flush=True)
        del generate
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    for key, result in report["results"].items():
        print(key)
        for line in result["sweep"]:
            print(" ", line)


if __name__ == "__main__":
    main()

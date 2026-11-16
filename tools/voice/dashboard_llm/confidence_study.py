from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path
from typing import Any, Optional

from tools.voice.dashboard_llm import copilot_model, evaluate_copilot as ev
from tools.voice.dashboard_llm import copilot_schema as schema

STUDY_RULE = """Compare ways to turn token probabilities into one confidence number.

    python -m tools.voice.dashboard_llm.confidence_study --model-dir <base> --adapter-dir <adapter> \
        --data-dir <data_copilot> --output study.json

Declared before looking at any result (rule R):
  1. Measures: joint (product of every token, the current one), min (weakest token),
     mean (geometric mean), decision (product over the decision tokens only: function name,
     argument names, enum / page / number values and the structural tokens; the copied
     salesperson and retailer text is left out), decision_min (weakest decision token).
  2. For each measure the threshold is chosen on the VALIDATION split only: the value on a
     0.001 grid that gives the most answered phrases with at most 2% wrong calls (the
     promotion gate); ties go to the higher threshold.
  3. The measure with the best validation yield is then applied ONCE to frozen, nav80 and
     test. Nothing is tuned on those sets.
"""

FREE_TEXT_ARGS = {"salesperson", "retailer"}
MEASURES = ("joint", "min", "mean", "decision", "decision_min")
GRID = [i / 1000 for i in range(0, 1001)]
MAX_WRONG = 0.02


class FeatureGenerator(copilot_model.CopilotGenerator):
    last: "list[dict[str, Any]]"

    def __call__(self, text: str, pages: "list[dict[str, Any]]", actions: "list[str]") -> "tuple[str, float]":
        with self._lock:
            if self._model is None:
                self._load()
            torch, tok, model = self._torch, self._tok, self._model
            prompt = schema.render_prompt(tok, text, pages, actions)
            inputs = tok(prompt, return_tensors="pt", add_special_tokens=False)
            inputs = {k: v.to(model.device) for k, v in inputs.items()}
            with torch.inference_mode():
                out = model.generate(
                    **inputs, max_new_tokens=copilot_model.MAX_NEW_TOKENS, max_time=self._max_seconds,
                    do_sample=False, output_scores=True, return_dict_in_generate=True,
                    eos_token_id=[copilot_model.END_CALL_ID, tok.eos_token_id], pad_token_id=tok.pad_token_id,
                )
            new = out.sequences[0][inputs["input_ids"].shape[-1]:]
            tokens, leading = [], True
            for step, token in enumerate(new):
                piece = tok.decode([int(token)], skip_special_tokens=False)
                if leading and not piece.strip():
                    continue
                leading = False
                probs = torch.softmax(out.scores[step][0].float(), dim=-1)
                tokens.append({"text": piece, "p": float(probs[token])})
            self.last = tokens
            decoded = tok.decode(new, skip_special_tokens=False)
            return decoded, math.exp(sum(math.log(max(t["p"], 1e-12)) for t in tokens))


def mark_decision_tokens(tokens: "list[dict[str, Any]]") -> None:
    key, in_value, escapes = "", False, 0
    segment = "name"
    buffer = ""
    for t in tokens:
        piece = t["text"]
        t["decision"] = True
        if segment == "name":
            if "{" in piece:
                segment = "key"
                buffer = ""
            continue
        if piece == schema.END_CALL:
            continue
        if segment == "key":
            if ":" in piece:
                key = (buffer + piece.split(":")[0]).strip(", ")
                segment = "value"
                escapes = 0
            else:
                buffer += piece
            continue
        if segment == "value":
            if piece == "<escape>":
                escapes += 1
                in_value = escapes == 1
                if escapes == 2:
                    segment, buffer = "key", ""
                continue
            if in_value and key in FREE_TEXT_ARGS:
                t["decision"] = False
            elif not in_value and ("," in piece or "}" in piece):
                segment, buffer = "key", ""


def measure_values(tokens: "list[dict[str, Any]]") -> "dict[str, float]":
    mark_decision_tokens(tokens)
    ps = [max(t["p"], 1e-12) for t in tokens] or [1.0]
    dec = [max(t["p"], 1e-12) for t in tokens if t["decision"]] or [1.0]
    return {
        "joint": math.exp(sum(map(math.log, ps))),
        "min": min(ps),
        "mean": math.exp(sum(map(math.log, ps)) / len(ps)),
        "decision": math.exp(sum(map(math.log, dec))),
        "decision_min": min(dec),
    }


def with_measure(rows: "list[dict]", name: str) -> "list[dict]":
    return [{**r, "confidence": r["features"][name] if r["call"] else 0.0} for r in rows]


def pick_threshold(rows: "list[dict]", name: str) -> "tuple[float, dict]":
    scored = with_measure(rows, name)
    best: Optional[tuple[float, dict]] = None
    for t in GRID:
        s = ev.score_rows(scored, t)
        if s["wrongCall"] <= MAX_WRONG and (best is None or s["yield"] >= best[1]["yield"]):
            best = (t, s)
    return best if best else (1.0, ev.score_rows(scored, 1.0))


def collect(generate: FeatureGenerator, cases: "list[dict]") -> "list[dict]":
    rows = []
    for case in cases:
        result = copilot_model.interpret(generate, case["request"], 0.0)
        rows.append({k: v for k, v in case.items() if k != "request"} | result
                    | {"features": measure_values(generate.last), "tokens": generate.last})
    return rows


def main(argv: Optional[list[str]] = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--adapter-dir", required=True)
    ap.add_argument("--data-dir", type=Path, required=True)
    ap.add_argument("--sets", default="validation,frozen,nav80,test")
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args(argv)

    loaders = {
        "validation": lambda: ev.load_test(args.data_dir, "validation"), "frozen": ev.load_frozen,
        "nav80": ev.load_nav80, "test": lambda: ev.load_test(args.data_dir),
    }
    generate = FeatureGenerator(args.model_dir, adapter_dir=args.adapter_dir)
    generate("warm up", [], list(schema.ACTION_ORDER))
    data = {}
    for name in args.sets.split(","):
        started = time.time()
        data[name] = collect(generate, loaders[name]())
        print(name, len(data[name]), f"{time.time() - started:.0f}s", flush=True)

    report: dict[str, Any] = {"rule": STUDY_RULE, "measures": {}}
    for m in MEASURES:
        t, s = pick_threshold(data["validation"], m)
        entry: dict[str, Any] = {"threshold": t, "validation": s}
        for name in data:
            if name != "validation":
                entry[name] = ev.score_rows(with_measure(data[name], m), t)
        report["measures"][m] = entry
        line = " ".join(
            f"{n}: wrong {100 * entry[n]['wrongCall']:.1f}% yield {100 * entry[n]['yield']:.1f}%"
            for n in data
        )
        print(f"{m:13s} t={t:.3f}  {line}", flush=True)
    report["rows"] = data
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()

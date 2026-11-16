from __future__ import annotations

import json
import os
from pathlib import Path

from tools.voice.dashboard_llm.train.make_dataset import DATA, request_pages

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[2] / "admin_dashboard" / "build" / "voice_eval" / "cases.json"
NO_MATCH = "no_match"
CHALLENGE = Path(
    os.environ.get(
        "DASHBOARD_VOICE_CHALLENGE",
        r"D:\models\functiongemma-dashboard-lora-candidate\phrase-drafts\locked_challenge_with_pages.json",
    )
)


def hand_set(name: str) -> list[dict]:
    data = json.loads((HERE / name).read_text(encoding="utf-8"))
    return [
        {
            "text": c["text"],
            "expect": c["expect"] or None,
            "kind": c.get("kind", ""),
            "pages": data["catalogues"][c["catalogue"]],
        }
        for c in data["cases"]
    ]


def split_set(name: str) -> list[dict]:
    path = DATA / f"{name}.jsonl"
    if not path.exists():
        return []
    rows = [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines()]
    return [
        {
            "text": r["text"],
            "expect": None if r["target"] == NO_MATCH else r["target"],
            "kind": r["kind"],
            "pages": request_pages(r),
        }
        for r in rows
    ]


def challenge_set() -> list[dict]:
    if not CHALLENGE.exists():
        return []
    rows = json.loads(CHALLENGE.read_text(encoding="utf-8"))
    return [
        {
            "text": r["text"],
            "expect": None if r["target"] == NO_MATCH else r["target"],
            "kind": r["kind"],
            "pages": request_pages(r),
        }
        for r in rows
    ]


def main() -> None:
    sets = {
        "eval80": hand_set("eval_phrases.json"),
        "fresh30": hand_set("fresh_phrases.json"),
        "validation": split_set("validation"),
        "test": split_set("test"),
        "challenge": challenge_set(),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(sets, ensure_ascii=False), encoding="utf-8")
    print({k: len(v) for k, v in sets.items()}, "->", OUT)


if __name__ == "__main__":
    main()

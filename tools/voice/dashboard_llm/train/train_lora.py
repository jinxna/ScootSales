from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import time
from pathlib import Path

import torch
import torch.nn.functional as F
from transformers import AutoModelForCausalLM, AutoTokenizer

from tools.voice.dashboard_llm import service
from tools.voice.dashboard_llm.train.make_dataset import DATA, request_pages

HERE = Path(__file__).resolve().parent
BASE_DIR = os.environ.get("DASHBOARD_VOICE_MODEL_DIR", service.DEFAULT_MODEL_DIR)
ADAPTER_OUT = os.environ.get("DASHBOARD_VOICE_ADAPTER_DIR", service.DEFAULT_ADAPTER_DIR)
LORA = dict(r=16, lora_alpha=32, lora_dropout=0.05, target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"])


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def encode(tok, rows: list[dict]) -> list[tuple[list[int], int]]:
    out = []
    for r in rows:
        prompt = service.render_prompt(tok, r["text"], request_pages(r))
        p_ids = tok(prompt, add_special_tokens=False)["input_ids"]
        t_ids = tok(f"{r['target']}<escape>", add_special_tokens=False)["input_ids"]
        assert t_ids[-1] == service.ESCAPE_ID, "target must end with <escape>"
        out.append((p_ids + t_ids, len(t_ids)))
    return out


def batches(items, size, shuffle_rng=None):
    idx = list(range(len(items)))
    if shuffle_rng:
        shuffle_rng.shuffle(idx)
        chunks = [sorted(idx[i : i + size * 16], key=lambda j: len(items[j][0])) for i in range(0, len(idx), size * 16)]
        bs = [c[i : i + size] for c in chunks for i in range(0, len(c), size)]
        shuffle_rng.shuffle(bs)
    else:
        bs = [idx[i : i + size] for i in range(0, len(idx), size)]
    return bs


def loss_for(peft_model, items, batch, device, pad_id):
    base = peft_model.get_base_model()
    width = max(len(items[j][0]) for j in batch)
    ids = torch.full((len(batch), width), pad_id, dtype=torch.long)
    mask = torch.zeros((len(batch), width), dtype=torch.long)
    pos, tgt = [], []
    for b, j in enumerate(batch):
        seq, k = items[j]
        ids[b, : len(seq)] = torch.tensor(seq)
        mask[b, : len(seq)] = 1
        for t in range(len(seq) - k, len(seq)):
            pos.append((b, t - 1))
            tgt.append(seq[t])
    hidden = base.model(input_ids=ids.to(device), attention_mask=mask.to(device)).last_hidden_state
    sel = hidden[[p[0] for p in pos], [p[1] for p in pos]]
    logits = base.lm_head(sel).float()
    return F.cross_entropy(logits, torch.tensor(tgt, device=device))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--micro-batch", type=int, default=2)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--eval-every", type=int, default=50, help="optimizer steps")
    ap.add_argument("--patience", type=int, default=3)
    ap.add_argument("--max-steps", type=int, default=0, help="debug cap")
    ap.add_argument("--seed", type=int, default=20260930)
    ap.add_argument("--data-dir", type=Path, default=DATA)
    ap.add_argument("--metadata-out", type=Path, default=HERE / "RUN_METADATA.json")
    args = ap.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    tok = AutoTokenizer.from_pretrained(BASE_DIR, local_files_only=True)
    model = AutoModelForCausalLM.from_pretrained(BASE_DIR, local_files_only=True, dtype=torch.float32)
    from peft import LoraConfig, get_peft_model

    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()
    peft_model = get_peft_model(model, LoraConfig(task_type="CAUSAL_LM", **LORA)).to(device)
    trainable = sum(p.numel() for p in peft_model.parameters() if p.requires_grad)

    def load(name):
        return [json.loads(line) for line in (args.data_dir / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()]

    train = encode(tok, load("train"))
    val = encode(tok, load("validation"))
    lens = sorted(len(x[0]) for x in train)
    print(f"train {len(train)} val {len(val)} tokens p50 {lens[len(lens)//2]} max {lens[-1]} trainable {trainable}", flush=True)

    opt = torch.optim.AdamW([p for p in peft_model.parameters() if p.requires_grad], lr=args.lr, weight_decay=0.0)
    steps_per_epoch = math.ceil(len(train) / (args.micro_batch * args.accum))
    total = steps_per_epoch * args.epochs
    warm = max(1, int(0.05 * total))
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: (s + 1) / warm if s < warm else 0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, total - warm)))
    )

    def evaluate() -> float:
        peft_model.eval()
        tot, n = 0.0, 0
        with torch.no_grad():
            for b in batches(val, 4):
                tot += float(loss_for(peft_model, val, b, device, tok.pad_token_id)) * len(b)
                n += len(b)
        peft_model.train()
        return tot / n

    rng = random.Random(args.seed)
    peft_model.train()
    curve, best, bad, step, started = [], float("inf"), 0, 0, time.time()
    stop = False
    Path(ADAPTER_OUT).mkdir(parents=True, exist_ok=True)
    for epoch in range(args.epochs):
        run, cnt = 0.0, 0
        micro = batches(train, args.micro_batch, rng)
        for i, b in enumerate(micro):
            loss = loss_for(peft_model, train, b, device, tok.pad_token_id)
            (loss / args.accum).backward()
            run += float(loss)
            cnt += 1
            if (i + 1) % args.accum and i + 1 != len(micro):
                continue
            torch.nn.utils.clip_grad_norm_(peft_model.parameters(), 1.0)
            opt.step()
            sched.step()
            opt.zero_grad(set_to_none=True)
            step += 1
            if step % args.eval_every == 0 or step == total or (args.max_steps and step >= args.max_steps):
                v = evaluate()
                curve.append({"step": step, "epoch": round(epoch + (i + 1) / len(micro), 2), "trainLoss": round(run / cnt, 5), "valLoss": round(v, 5)})
                print(curve[-1], f"{time.time()-started:.0f}s vram {torch.cuda.max_memory_allocated()/2**20:.0f}MiB" if device == "cuda" else "", flush=True)
                run, cnt = 0.0, 0
                if v < best - 1e-4:
                    best, bad = v, 0
                    peft_model.save_pretrained(ADAPTER_OUT)
                else:
                    bad += 1
                    if bad >= args.patience:
                        print("early stopping", flush=True)
                        stop = True
            if stop or (args.max_steps and step >= args.max_steps):
                stop = True
                break
        if stop:
            break

    import peft
    import transformers

    meta = {
        "base": "functiongemma-270m-it",
        "adapterDir": str(Path(ADAPTER_OUT).expanduser().resolve()),
        "lora": LORA,
        "hyperparameters": {"epochs": args.epochs, "microBatch": args.micro_batch, "gradAccum": args.accum, "lr": args.lr, "schedule": "cosine, 5% warmup", "seed": args.seed, "precision": "fp32", "gradientCheckpointing": True},
        "data": {n: {"rows": len(load(n)), "sha256": sha(args.data_dir / f"{n}.jsonl")} for n in ("train", "validation", "test")},
        "makeDatasetSha256": sha(HERE / "make_dataset.py"),
        "versions": {"torch": torch.__version__, "transformers": transformers.__version__, "peft": peft.__version__},
        "device": torch.cuda.get_device_name(0) if device == "cuda" else "cpu",
        "trainableParams": trainable,
        "optimizerSteps": step,
        "wallSeconds": round(time.time() - started),
        "peakVramMiB": round(torch.cuda.max_memory_allocated() / 2**20) if device == "cuda" else None,
        "bestValLoss": round(best, 5),
        "curve": curve,
    }
    args.metadata_out.parent.mkdir(parents=True, exist_ok=True)
    args.metadata_out.write_text(json.dumps(meta, indent=1), encoding="utf-8")
    print("done; best val loss", meta["bestValLoss"], "adapter", ADAPTER_OUT)


if __name__ == "__main__":
    main()

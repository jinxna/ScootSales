from __future__ import annotations

import argparse
import json
import math
import random
import time
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from tools.voice.dashboard_llm import copilot_schema as schema
from tools.voice.dashboard_llm.train import make_copilot_dataset as ds
from tools.voice.dashboard_llm.train.train_lora import LORA, batches, loss_for, sha

HERE = Path(__file__).resolve().parent
END_CALL_ID = 49


def encode(tok, rows: list[dict]) -> list[tuple[list[int], int]]:
    out = []
    for row in rows:
        request = ds.to_request(row)
        prompt = schema.render_prompt(tok, request["text"], request["pages"], request["actions"])
        p_ids = tok(prompt, add_special_tokens=False)["input_ids"]
        t_ids = tok(schema.serialize_call(row["target"]), add_special_tokens=False)["input_ids"]
        assert t_ids[-1] == END_CALL_ID, "target must end with <end_function_call>"
        out.append((p_ids + t_ids, len(t_ids)))
    return out


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-dir", required=True, help="local FunctionGemma-270M-it folder")
    ap.add_argument("--adapter-out", type=Path, required=True)
    ap.add_argument("--data-dir", type=Path, default=ds.DATA)
    ap.add_argument("--metadata-out", type=Path)
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--micro-batch", type=int, default=2)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--eval-every", type=int, default=50, help="optimizer steps")
    ap.add_argument("--patience", type=int, default=3,
                    help="stop after this many checks without a better validation loss; 0 = never stop early "
                         "(the first run stopped at step 700 of 1500, before the learning rate had decayed)")
    ap.add_argument("--save-final", type=Path, help="also save the adapter after the last step to this folder")
    ap.add_argument("--val-limit", type=int, default=0, help="check only the first N validation rows (faster)")
    ap.add_argument("--no-grad-checkpoint", action="store_true",
                    help="faster, uses more GPU memory; fine on a 16 GB GPU, not on a 4 GB one")
    ap.add_argument("--max-steps", type=int, default=0, help="debug cap")
    ap.add_argument("--limit", type=int, default=0, help="use only the first N training rows (debug)")
    ap.add_argument("--seed", type=int, default=20261006)
    args = ap.parse_args(argv)
    metadata_out = args.metadata_out or args.adapter_out / "RUN_METADATA.json"

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    tok = AutoTokenizer.from_pretrained(args.base_dir, local_files_only=True)
    if tok.convert_tokens_to_ids(schema.END_CALL) != END_CALL_ID:
        raise SystemExit("unexpected tokenizer: <end_function_call> id changed")
    model = AutoModelForCausalLM.from_pretrained(args.base_dir, local_files_only=True, dtype=torch.float32)
    from peft import LoraConfig, get_peft_model

    if not args.no_grad_checkpoint:
        model.gradient_checkpointing_enable()
        model.enable_input_require_grads()
    peft_model = get_peft_model(model, LoraConfig(task_type="CAUSAL_LM", **LORA)).to(device)
    trainable = sum(p.numel() for p in peft_model.parameters() if p.requires_grad)

    def load(name: str) -> list[dict]:
        return [json.loads(x) for x in (args.data_dir / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()]

    train_rows = load("train")[: args.limit or None]
    train, val = encode(tok, train_rows), encode(tok, load("validation")[: args.val_limit or None])
    lens = sorted(len(x[0]) for x in train)
    print(f"train {len(train)} val {len(val)} tokens p50 {lens[len(lens) // 2]} max {lens[-1]} trainable {trainable}", flush=True)

    opt = torch.optim.AdamW([p for p in peft_model.parameters() if p.requires_grad], lr=args.lr, weight_decay=0.0)
    total = math.ceil(len(train) / (args.micro_batch * args.accum)) * args.epochs
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
    args.adapter_out.mkdir(parents=True, exist_ok=True)
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
                curve.append({"step": step, "epoch": round(epoch + (i + 1) / len(micro), 2),
                              "trainLoss": round(run / cnt, 5), "valLoss": round(v, 5)})
                vram = f" vram {torch.cuda.max_memory_allocated() / 2**20:.0f}MiB" if device == "cuda" else ""
                print(curve[-1], f"{time.time() - started:.0f}s{vram}", flush=True)
                run, cnt = 0.0, 0
                if v < best - 1e-4:
                    best, bad = v, 0
                    peft_model.save_pretrained(args.adapter_out)
                else:
                    bad += 1
                    if args.patience and bad >= args.patience:
                        print("early stopping", flush=True)
                        stop = True
            if stop or (args.max_steps and step >= args.max_steps):
                stop = True
                break
        if stop:
            break

    if args.save_final:
        args.save_final.mkdir(parents=True, exist_ok=True)
        peft_model.save_pretrained(args.save_final)
        print("final adapter saved to", args.save_final, flush=True)

    import peft
    import transformers

    meta = {
        "base": "functiongemma-270m-it",
        "adapterDir": str(args.adapter_out.expanduser().resolve()),
        "lora": LORA,
        "hyperparameters": {"epochs": args.epochs, "microBatch": args.micro_batch, "gradAccum": args.accum,
                            "lr": args.lr, "schedule": "cosine, 5% warmup", "seed": args.seed, "precision": "fp32",
                            "gradientCheckpointing": not args.no_grad_checkpoint, "trainRows": len(train),
                            "patience": args.patience, "valRows": len(val)},
        "data": {n: {"rows": len(load(n)), "sha256": sha(args.data_dir / f"{n}.jsonl")} for n in ("train", "validation", "test")},
        "makeCopilotDatasetSha256": sha(HERE / "make_copilot_dataset.py"),
        "copilotSchemaSha256": sha(HERE.parent / "copilot_schema.py"),
        "versions": {"torch": torch.__version__, "transformers": transformers.__version__, "peft": peft.__version__},
        "device": torch.cuda.get_device_name(0) if device == "cuda" else "cpu",
        "trainableParams": trainable,
        "optimizerSteps": step,
        "wallSeconds": round(time.time() - started),
        "peakVramMiB": round(torch.cuda.max_memory_allocated() / 2**20) if device == "cuda" else None,
        "bestValLoss": round(best, 5),
        "curve": curve,
    }
    metadata_out.parent.mkdir(parents=True, exist_ok=True)
    metadata_out.write_text(json.dumps(meta, indent=1), encoding="utf-8")
    print("done; best val loss", meta["bestValLoss"], "adapter", args.adapter_out)


if __name__ == "__main__":
    main()

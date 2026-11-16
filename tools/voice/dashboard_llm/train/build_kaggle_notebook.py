from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
LLM = HERE.parent
REPO = LLM.parents[2]
OUT = HERE / "kaggle" / "copilot_training.ipynb"
WORK = "/kaggle/working"
ROOT = f"{WORK}/fyp"

EMBED = [
    "tools/voice/dashboard_llm/__init__.py",
    "tools/voice/dashboard_llm/service.py",
    "tools/voice/dashboard_llm/copilot_schema.py",
    "tools/voice/dashboard_llm/copilot_model.py",
    "tools/voice/dashboard_llm/evaluate_copilot.py",
    "tools/voice/dashboard_llm/eval_phrases.json",
    "tools/voice/dashboard_llm/fresh_phrases.json",
    "tools/voice/dashboard_llm/copilot_eval_phrases.json",
    "tools/voice/dashboard_llm/train/make_dataset.py",
    "tools/voice/dashboard_llm/train/make_copilot_dataset.py",
    "tools/voice/dashboard_llm/train/train_lora.py",
    "tools/voice/dashboard_llm/train/train_copilot_lora.py",
]
PINS = "transformers==5.17.0 tokenizers==0.23.2 huggingface-hub==1.33.0 safetensors==0.8.0 peft==0.21.1 accelerate==1.15.0"


def source(rel: str) -> str:
    text = (REPO / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
    return text if not text or text.endswith("\n") else text + "\n"


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def expected_dataset_hashes() -> dict[str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            [sys.executable, "-m", "tools.voice.dashboard_llm.train.make_copilot_dataset", "--out-dir", tmp],
            cwd=REPO, check=True, capture_output=True,
        )
        return {n: hashlib.sha256((Path(tmp) / f"{n}.jsonl").read_bytes()).hexdigest() for n in ("train", "validation", "test")}


def md(text: str) -> dict:
    return {"cell_type": "markdown", "metadata": {}, "source": text.splitlines(keepends=True)}


def code(text: str) -> dict:
    return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [],
            "source": text.splitlines(keepends=True)}


def build() -> dict:
    files = {rel: source(rel) for rel in EMBED}
    hashes = {rel: digest(text) for rel, text in files.items()}
    data_hashes = expected_dataset_hashes()
    cells: list[dict] = [
        md(
            "# Dashboard copilot: train and evaluate the LoRA adapter\n\n"
            "Run the cells from top to bottom (**Run All**). Before you start:\n\n"
            "1. Right panel, **Session options**: Accelerator = **GPU P100** (faster for this job) or **GPU T4 x2**; Internet = **On**. "
            "The job uses one GPU only.\n"
            "2. **Add-ons > Secrets**: add a secret named `HF_TOKEN` (a Hugging Face read-only token) "
            "and attach it to this notebook.\n"
            "3. Your Hugging Face account must have accepted the license of `google/functiongemma-270m-it`.\n\n"
            "The notebook never prints the token. Estimated time: 2 to 4 hours (measured 1.1 s per sequence on a GTX 1650; "
            "Kaggle GPUs should be 2.5 to 3.5 times faster; not yet measured on Kaggle). "
            "Each progress line shows the elapsed seconds. A Kaggle session stops after 9 hours. "
            "At the end, download `copilot_adapter.zip` and `report.json` from the **Output** panel."
        ),
        code("!nvidia-smi\nimport sys, torch\nprint(sys.version.split()[0], 'torch', torch.__version__, 'cuda', torch.cuda.is_available())"),
        code(
            "# Kaggle ships torchao 0.10.0. PEFT finds it and refuses to start (it needs a newer one).\n"
            "# This job does not use torchao, so remove it.\n"
            "!pip -q uninstall -y torchao\n"
            f"!pip -q install {PINS}\n"
            "import importlib.util, transformers, peft\n"
            "assert importlib.util.find_spec('torchao') is None, 'torchao is still installed: restart the session, then run this cell again'\n"
            "print('transformers', transformers.__version__, 'peft', peft.__version__)"
        ),
        code(
            "import os\n"
            "from kaggle_secrets import UserSecretsClient\n"
            "from huggingface_hub import snapshot_download\n"
            "token = UserSecretsClient().get_secret('HF_TOKEN')\n"
            "try:\n"
            f"    BASE = snapshot_download('google/functiongemma-270m-it', local_dir='{WORK}/base', token=token)\n"
            "except Exception as error:\n"
            "    raise SystemExit('Download failed. Open https://huggingface.co/google/functiongemma-270m-it, '\n"
            "                     'accept the license, check HF_TOKEN, then run this cell again. ' + type(error).__name__)\n"
            "finally:\n"
            "    del token\n"
            "print('base model files:', sorted(os.listdir(BASE)))"
        ),
        md("## Source files\n\nEach cell writes one file of the repository. Do not edit them here."),
        code(f"import os\nfor d in ['tools/voice/dashboard_llm/train']:\n    os.makedirs('{ROOT}/' + d, exist_ok=True)\nopen('{ROOT}/tools/__init__.py', 'a').close()\nopen('{ROOT}/tools/voice/__init__.py', 'a').close()"),
    ]
    for rel, text in files.items():
        if not text:
            cells.append(code(f"open('{ROOT}/{rel}', 'w').close()  # empty file"))
        else:
            cells.append(code(f"%%writefile {ROOT}/{rel}\n{text}"))
    cells += [
        code(
            "import hashlib, json\n"
            f"EXPECTED = {json.dumps(hashes, indent=1)}\n"
            "for rel, want in EXPECTED.items():\n"
            f"    text = open('{ROOT}/' + rel, encoding='utf-8').read()\n"
            "    got = hashlib.sha256(text.encode('utf-8')).hexdigest()\n"
            "    assert got == want, 'file differs from the repository: ' + rel\n"
            "print('all', len(EXPECTED), 'source files match')"
        ),
        md("## Dataset\n\nThe generator is deterministic. The hashes must match the ones computed on the repository machine."),
        code(
            f"!cd {ROOT} && python -m tools.voice.dashboard_llm.train.make_copilot_dataset --out-dir {WORK}/data\n"
            f"WANT = {json.dumps(data_hashes, indent=1)}\n"
            "same = True\n"
            "for name, want in WANT.items():\n"
            f"    got = hashlib.sha256(open('{WORK}/data/' + name + '.jsonl', 'rb').read()).hexdigest()\n"
            "    if got != want:\n"
            "        same = False\n"
            "        print('WARNING: dataset', name, 'differs from the repository build:', got[:16], 'instead of', want[:16])\n"
            "print('dataset matches the repository build' if same else\n"
            "      'The dataset differs (a different Python version can cause this). The generator has already checked '\n"
            "      'that no training sentence equals a validation, test or frozen sentence. Tell the repository owner.')"
        ),
        md(
            "## Train\n\n"
            "LoRA (r=16) on the 270M model, 3 epochs, effective batch 16. The full schedule runs (no early stop) and the final adapter is kept. "
            "If you see an out-of-memory error, change `--micro-batch 8 --accum 2` to `--micro-batch 4 --accum 4` and run the cell again."
        ),
        code(
            f"!cd {ROOT} && PYTHONPATH={ROOT} python -m tools.voice.dashboard_llm.train.train_copilot_lora "
            f"--base-dir {WORK}/base --adapter-out {WORK}/adapter --data-dir {WORK}/data "
            "--micro-batch 8 --accum 2 --epochs 3 --eval-every 250 --val-limit 400 --patience 0 "
            f"--no-grad-checkpoint --save-final {WORK}/adapter_final"
        ),
        md(
            "## Evaluate\n\n"
            "Frozen hand-written set, generated test split and the 80 older navigation phrases, for the untuned base model and the adapter."
        ),
        code(
            f"!cd {ROOT} && PYTHONPATH={ROOT} python -m tools.voice.dashboard_llm.evaluate_copilot "
            f"--model-dir {WORK}/base --adapter-dir {WORK}/adapter_final --data-dir {WORK}/data --output {WORK}/report.json"
        ),
        code(
            f"report = json.load(open('{WORK}/report.json', encoding='utf-8'))\n"
            "for key, result in report['results'].items():\n"
            "    print(key, result['latencyMs'])\n"
            "    for row in result['sweep']:\n"
            "        if row['threshold'] in (0.0, 0.9, 0.95, 0.98, 0.99):\n"
            "            print('  thr %.2f  wrong %.1f%%  yield %.1f%%  abstain-on-negatives %.1f%%' % (\n"
            "                row['threshold'], 100*row['wrongCall'], 100*row['yield'], 100*row['abstainOnNegatives']))"
        ),
        md("## Package the result\n\nDownload `copilot_adapter.zip` and `report.json` from the Output panel, then give them to the repository owner."),
        code(
            "import shutil\n"
            f"shutil.make_archive('{WORK}/copilot_adapter', 'zip', '{WORK}/adapter_final')\n"
            f"print(os.listdir('{WORK}'))"
        ),
    ]
    return {
        "cells": cells,
        "metadata": {
            "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def render(notebook: dict) -> str:
    return json.dumps(notebook, indent=1, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 when the committed notebook is stale")
    args = ap.parse_args(argv)
    text = render(build())
    if args.check:
        current = OUT.read_text(encoding="utf-8").replace("\r\n", "\n") if OUT.exists() else ""
        if current != text:
            print("notebook is stale: run python -m tools.voice.dashboard_llm.train.build_kaggle_notebook")
            return 1
        print("notebook is up to date")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print(f"wrote {OUT.relative_to(REPO)} ({len(text) // 1024} KiB, {len(EMBED)} files embedded)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

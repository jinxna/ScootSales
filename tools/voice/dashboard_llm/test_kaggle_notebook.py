import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

import pytest

from tools.voice.dashboard_llm.train import build_kaggle_notebook as nb

NOTEBOOK = nb.OUT


@pytest.fixture(scope="module")
def notebook():
    return json.loads(NOTEBOOK.read_text(encoding="utf-8"))


def source_of(cell) -> str:
    return "".join(cell["source"])


@pytest.fixture(scope="module")
def replayed(notebook, tmp_path_factory):
    root = tmp_path_factory.mktemp("kaggle")
    for cell in notebook["cells"]:
        text = source_of(cell)
        if cell["cell_type"] == "code" and text.startswith("%%writefile "):
            header, _, body = text.partition("\n")
            target = root / header.split(" ", 1)[1].replace(nb.ROOT + "/", "")
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(body)
    for rel in ("tools/__init__.py", "tools/voice/__init__.py", "tools/voice/dashboard_llm/__init__.py"):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).touch()
    return root


def test_notebook_is_up_to_date_with_the_sources():
    assert nb.main(["--check"]) == 0, "run python -m tools.voice.dashboard_llm.train.build_kaggle_notebook"


def test_notebook_contains_no_secret_and_never_prints_the_token(notebook):
    text = json.dumps(notebook)
    assert not re.search(r"hf_[A-Za-z0-9]{20,}", text), "a Hugging Face token pattern is embedded"
    cells = [source_of(c) for c in notebook["cells"] if c["cell_type"] == "code"]
    assert any("UserSecretsClient" in c and "HF_TOKEN" in c for c in cells)
    assert not any("print(token" in c for c in cells)


def test_replayed_files_match_the_hashes_the_notebook_checks(notebook, replayed):
    expected = next(
        json.loads(source_of(c).split("EXPECTED = ", 1)[1].split("\nfor rel", 1)[0])
        for c in notebook["cells"] if source_of(c).startswith("import hashlib, json")
    )
    assert len(expected) == len(nb.EMBED)
    for rel, want in expected.items():
        got = hashlib.sha256((replayed / rel).read_text(encoding="utf-8").encode("utf-8")).hexdigest()
        assert got == want, rel


def test_replayed_folder_builds_the_same_dataset(notebook, replayed):
    env = {**os.environ, "PYTHONPATH": str(replayed)}
    out = replayed / "data"
    subprocess.run(
        [sys.executable, "-m", "tools.voice.dashboard_llm.train.make_copilot_dataset", "--out-dir", str(out)],
        cwd=replayed, env=env, check=True, capture_output=True,
    )
    want_data = next(
        json.loads(source_of(c).split("WANT = ", 1)[1].split("\nsame = True", 1)[0])
        for c in notebook["cells"] if "WANT = " in source_of(c)
    )
    for name, want in want_data.items():
        assert hashlib.sha256((out / f"{name}.jsonl").read_bytes()).hexdigest() == want, name


@pytest.mark.skipif(
    any(importlib.util.find_spec(m) is None for m in ("torch", "transformers", "peft")),
    reason="torch, transformers and peft are not installed (CI)",
)
def test_trainer_and_evaluator_import_from_the_embedded_files_only(replayed):
    env = {**os.environ, "PYTHONPATH": str(replayed)}
    imported = subprocess.run(
        [sys.executable, "-c",
         "import tools.voice.dashboard_llm.train.train_copilot_lora, tools.voice.dashboard_llm.evaluate_copilot as e;"
         "print(len(e.load_frozen()))"],
        cwd=replayed, env=env, capture_output=True, text=True,
    )
    assert imported.returncode == 0, imported.stderr[-600:]
    assert int(imported.stdout.strip().splitlines()[-1]) >= 100

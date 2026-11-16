from __future__ import annotations

import argparse
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
REPO_ROOT = PKG.parents[2]
PLATFORM_FILES = ("__init__.py", "auth.py", "config.py", "directory.py", "records.py", "signing.py", "tenancy.py", "audit.py", "commands.py", "ids.py", "operations.py")
ADAPTER_FILES = ("adapter_config.json", "adapter_model.safetensors")


def main(argv: "list[str] | None" = None) -> Path:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", type=Path, required=True)
    ap.add_argument("--adapter-dir", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=HERE / "bundle")
    args = ap.parse_args(argv)
    for name in ADAPTER_FILES:
        if not (args.adapter_dir / name).is_file():
            raise SystemExit(f"adapter folder has no {name}")
    if not (args.model_dir / "config.json").is_file():
        raise SystemExit("model folder has no config.json")

    shutil.rmtree(args.out, ignore_errors=True)
    code = args.out / "tools" / "voice" / "dashboard_llm"
    (code / "server").mkdir(parents=True)
    (args.out / "tools" / "voice" / "__init__.py").touch()
    for name in ("__init__.py", "copilot_model.py", "copilot_schema.py", "gemini_client.py", "http_deadline.py"):
        shutil.copy2(PKG / name, code / name)
    for name in ("__init__.py", "app.py"):
        shutil.copy2(HERE / name, code / "server" / name)
    platform = args.out / "platform_service"
    platform.mkdir()
    for name in PLATFORM_FILES:
        shutil.copy2(REPO_ROOT / "platform_service" / name, platform / name)
    for name in ("Dockerfile", "requirements.txt", "docker-compose.yml", "Caddyfile", "env.example"):
        shutil.copy2(HERE / name, args.out / name)
    shutil.copytree(args.model_dir, args.out / "model", ignore=shutil.ignore_patterns(".git*", ".cache", "*.md", "*.onnx", "*.litertlm"))
    (args.out / "adapter").mkdir()
    for name in ADAPTER_FILES:
        shutil.copy2(args.adapter_dir / name, args.out / "adapter" / name)
    (args.out / ".dockerignore").write_text("**/__pycache__\n", encoding="utf-8")
    print("bundle ready:", args.out)
    return args.out


if __name__ == "__main__":
    main()

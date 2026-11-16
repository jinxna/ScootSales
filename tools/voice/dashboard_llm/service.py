from __future__ import annotations

import json
import math
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Optional

MAX_TEXT = 200
MAX_PAGES = 60
MAX_BODY = 32_768
MAX_ALIASES = 8
MAX_SECONDS = 2.0
DEFAULT_PORT = 8765
DEFAULT_MODEL_DIR = r"D:\models\functiongemma-270m-it"
DEFAULT_ADAPTER_DIR = r"D:\models\functiongemma-dashboard-lora"
THRESHOLD = 0.98
BASE_MODEL_THRESHOLD = 0.999
ESCAPE_ID = 52
TOOL_NAME = "navigate_to_page"
NO_MATCH = "no_match"
PREFILL = f"<start_function_call>call:{TOOL_NAME}{{page:<escape>"
_LOCAL_ORIGIN = re.compile(r"^http://(?:localhost|127\.0\.0\.1)(?::\d{1,5})?$")
_KEY = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_CALL = re.compile(
    rf"call:{TOOL_NAME}\{{page:<escape>([^<>{{}}]{{1,80}})<escape>\}}"
)

Generate = Callable[[str, "list[dict[str, Any]]"], "tuple[str, float]"]


class RequestError(ValueError):
    pass


def origin_allowed(origin: Optional[str]) -> bool:
    return bool(origin) and _LOCAL_ORIGIN.fullmatch(origin) is not None


def validate_request(payload: Any) -> "tuple[str, list[dict[str, Any]]]":
    if not isinstance(payload, dict):
        raise RequestError("body must be an object")
    text = payload.get("text")
    if not isinstance(text, str) or not text.strip():
        raise RequestError("text must be a non-empty string")
    if len(text) > MAX_TEXT:
        raise RequestError("text too long")
    pages = payload.get("pages")
    if not isinstance(pages, list) or not pages or len(pages) > MAX_PAGES:
        raise RequestError("pages must be a non-empty list")
    clean: list[dict[str, Any]] = []
    seen: set[str] = set()
    for page in pages:
        if not isinstance(page, dict):
            raise RequestError("page must be an object")
        key, label = page.get("key"), page.get("label")
        aliases = page.get("aliases", [])
        if not isinstance(key, str) or not _KEY.fullmatch(key) or key in seen:
            raise RequestError("invalid or duplicate page key")
        if not isinstance(label, str) or len(label) > 80 or "<" in label:
            raise RequestError("invalid page label")
        if not isinstance(aliases, list) or not all(
            isinstance(a, str) and len(a) <= 60 and "<" not in a for a in aliases
        ):
            raise RequestError("invalid aliases")
        seen.add(key)
        clean.append({"key": key, "label": label, "aliases": aliases[:MAX_ALIASES]})
    return " ".join(text.split()), clean


def build_tools(pages: "list[dict[str, Any]]") -> "list[dict[str, Any]]":
    described = "; ".join(
        f"{p['key']} = {p['label']}"
        + (f" ({', '.join(p['aliases'])})" if p["aliases"] else "")
        for p in pages
    )
    described += f"; {NO_MATCH} = none of the pages fit the request"
    return [
        {
            "type": "function",
            "function": {
                "name": TOOL_NAME,
                "description": f"Open one dashboard page. Pages: {described}",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "page": {
                            "type": "string",
                            "description": "The page to open",
                            "enum": [p["key"] for p in pages] + [NO_MATCH],
                        }
                    },
                    "required": ["page"],
                },
            },
        }
    ]


def parse_page(output: str, pages: "list[dict[str, Any]]") -> Optional[str]:
    matches = _CALL.findall(output)
    if len(matches) != 1:
        return None
    value = matches[0].strip().lower()
    if any(p["key"] == value for p in pages):
        return value
    hits = {
        p["key"]
        for p in pages
        if value in {p["label"].lower(), *(a.lower() for a in p["aliases"])}
    }
    return hits.pop() if len(hits) == 1 else None


def propose(generate: Generate, payload: Any, threshold: float) -> "dict[str, Any]":
    started = time.perf_counter()
    text, pages = validate_request(payload)
    output, confidence = generate(text, pages)
    key = parse_page(output, pages)
    if confidence < threshold:
        key = None
    return {
        "pageKey": key,
        "confidence": round(confidence if key else 0.0, 4),
        "latencyMs": int((time.perf_counter() - started) * 1000),
    }


def render_prompt(tok: Any, text: str, pages: "list[dict[str, Any]]") -> str:
    messages = [
        {
            "role": "developer",
            "content": "You are a model that can do function calling with the following functions",
        },
        {"role": "user", "content": text},
    ]
    prompt = tok.apply_chat_template(
        messages, tools=build_tools(pages), add_generation_prompt=True, tokenize=False
    )
    return prompt + PREFILL


def default_threshold(adapter: bool, env: "Optional[str]" = None) -> float:
    value = env if env is not None else os.environ.get("DASHBOARD_VOICE_THRESHOLD")
    if value:
        return float(value)
    return THRESHOLD if adapter else BASE_MODEL_THRESHOLD


def resolve_adapter_dir(env: "Optional[str]" = None) -> "Optional[str]":
    path = env if env is not None else os.environ.get("DASHBOARD_VOICE_ADAPTER_DIR", DEFAULT_ADAPTER_DIR)
    return path if path and os.path.isfile(os.path.join(path, "adapter_config.json")) else None


class GemmaGenerator:
    def __init__(
        self, model_dir: str, max_new_tokens: int = 24, adapter_dir: "Optional[str]" = None
    ) -> None:
        self._dir = model_dir
        self.adapter_dir = adapter_dir
        self._max_new = max_new_tokens
        self._model: Any = None
        self._tok: Any = None
        self._torch: Any = None
        self._lock = threading.Lock()

    def _load(self) -> None:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self._torch = torch
        self._tok = AutoTokenizer.from_pretrained(self._dir, local_files_only=True)
        if self._tok.convert_tokens_to_ids("<escape>") != ESCAPE_ID:
            raise RuntimeError("unexpected tokenizer: <escape> id changed")
        model = AutoModelForCausalLM.from_pretrained(
            self._dir, local_files_only=True, dtype=torch.float32
        )
        if self.adapter_dir:
            from peft import PeftModel

            model = PeftModel.from_pretrained(model, self.adapter_dir, local_files_only=True)
            model = model.merge_and_unload()
        model = model.eval()
        self._model = model.to("cuda") if torch.cuda.is_available() else model

    def __call__(self, text: str, pages: "list[dict[str, Any]]") -> "tuple[str, float]":
        with self._lock:
            if self._model is None:
                self._load()
            torch, tok, model = self._torch, self._tok, self._model
            inputs = tok(render_prompt(tok, text, pages), return_tensors="pt", add_special_tokens=False)
            inputs = {k: v.to(model.device) for k, v in inputs.items()}
            with torch.inference_mode():
                out = model.generate(
                    **inputs,
                    max_new_tokens=self._max_new,
                    max_time=MAX_SECONDS,
                    do_sample=False,
                    output_scores=True,
                    return_dict_in_generate=True,
                    eos_token_id=[ESCAPE_ID, tok.eos_token_id],
                    pad_token_id=tok.pad_token_id,
                )
            new = out.sequences[0][inputs["input_ids"].shape[-1] :]
            logp = 0.0
            for step, token in enumerate(new):
                probs = torch.softmax(out.scores[step][0].float(), dim=-1)
                logp += math.log(max(float(probs[token]), 1e-12))
            decoded = tok.decode(new, skip_special_tokens=False)
            return f"{PREFILL}{decoded}}}", math.exp(logp)


def make_handler(generate: Generate, threshold: float, adapter: bool = False):
    class Handler(BaseHTTPRequestHandler):
        server_version = "DashboardVoiceLLM"

        def log_message(self, *args: Any) -> None:
            return

        def _cors(self) -> None:
            origin = self.headers.get("Origin")
            if origin_allowed(origin):
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Vary", "Origin")
                self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")

        def _send(self, status: int, body: "dict[str, Any]") -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self._cors()
            self.end_headers()
            self.wfile.write(data)

        def _origin_rejected(self) -> bool:
            origin = self.headers.get("Origin")
            if origin is not None and not origin_allowed(origin):
                self._send(403, {"error": "origin not allowed"})
                return True
            return False

        def do_OPTIONS(self) -> None:
            if self._origin_rejected():
                return
            self.send_response(204)
            self._cors()
            self.end_headers()

        def do_GET(self) -> None:
            if self._origin_rejected():
                return
            if self.path == "/health":
                self._send(200, {"status": "ok", "threshold": threshold, "adapter": adapter})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self) -> None:
            if self._origin_rejected():
                return
            if self.path != "/propose":
                self._send(404, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = -1
            if length <= 0 or length > MAX_BODY:
                self._send(413, {"error": "bad body size"})
                return
            try:
                payload = json.loads(self.rfile.read(length))
                self._send(200, propose(generate, payload, threshold))
            except (RequestError, json.JSONDecodeError) as error:
                self._send(400, {"error": str(error)})
            except Exception:
                self._send(500, {"error": "inference failed"})

    return Handler


def serve() -> None:
    port = int(os.environ.get("DASHBOARD_VOICE_PORT", DEFAULT_PORT))
    model_dir = os.environ.get("DASHBOARD_VOICE_MODEL_DIR", DEFAULT_MODEL_DIR)
    generator = GemmaGenerator(model_dir, adapter_dir=resolve_adapter_dir())
    threshold = default_threshold(generator.adapter_dir is not None)
    threading.Thread(
        target=generator,
        args=("warm up", [{"key": "dashboard", "label": "Dashboard", "aliases": []}]),
        daemon=True,
    ).start()
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(generator, threshold, generator.adapter_dir is not None))
    print(f"dashboard voice LLM on http://127.0.0.1:{port} (model warming up, adapter={'on' if generator.adapter_dir else 'off'})")
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(serve())

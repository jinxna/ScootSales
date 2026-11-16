from __future__ import annotations

import math
import threading
import time
from typing import Any, Callable, Optional

from . import copilot_schema as schema

Generate = Callable[[str, "list[dict[str, Any]]", "list[str]"], "tuple[str, float]"]

END_CALL_ID = 49
MAX_NEW_TOKENS = 64


def interpret(generate: Generate, payload: Any, threshold: float) -> "dict[str, Any]":
    started = time.perf_counter()
    text, pages, actions = schema.validate_request(payload)
    output, confidence = generate(text, pages, actions)
    call = schema.parse_call(schema.PREFILL + output.removeprefix(schema.PREFILL), pages, actions)
    if call is None or call.name == schema.NO_MATCH or confidence < threshold:
        call = None
    return {
        "call": None if call is None else call.as_dict(),
        "confidence": confidence if call else 0.0,
        "latencyMs": int((time.perf_counter() - started) * 1000),
    }


class CopilotGenerator:
    def __init__(
        self,
        model_dir: str,
        adapter_dir: Optional[str] = None,
        max_seconds: float = 4.0,
        device: Optional[str] = None,
    ) -> None:
        self._dir = model_dir
        self.adapter_dir = adapter_dir
        self._max_seconds = max_seconds
        self._device = device
        self._model: Any = None
        self._tok: Any = None
        self._torch: Any = None
        self._lock = threading.Lock()

    def _load(self) -> None:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self._torch = torch
        self._tok = AutoTokenizer.from_pretrained(self._dir, local_files_only=True)
        if self._tok.convert_tokens_to_ids(schema.END_CALL) != END_CALL_ID:
            raise RuntimeError("unexpected tokenizer: <end_function_call> id changed")
        model = AutoModelForCausalLM.from_pretrained(self._dir, local_files_only=True, dtype=torch.float32)
        if self.adapter_dir:
            from peft import PeftModel

            model = PeftModel.from_pretrained(model, self.adapter_dir, local_files_only=True).merge_and_unload()
        model = model.eval()
        device = self._device or ("cuda" if torch.cuda.is_available() else "cpu")
        self._model = model.to(device)

    @property
    def device(self) -> str:
        if self._model is None:
            with self._lock:
                if self._model is None:
                    self._load()
        return str(self._model.device)

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
                    **inputs,
                    max_new_tokens=MAX_NEW_TOKENS,
                    max_time=self._max_seconds,
                    do_sample=False,
                    output_scores=True,
                    return_dict_in_generate=True,
                    eos_token_id=[END_CALL_ID, tok.eos_token_id],
                    pad_token_id=tok.pad_token_id,
                )
            new = out.sequences[0][inputs["input_ids"].shape[-1]:]
            logp = 0.0
            leading = True
            for step, token in enumerate(new):
                if leading and not tok.decode([int(token)]).strip():
                    continue
                leading = False
                probs = torch.softmax(out.scores[step][0].float(), dim=-1)
                logp += math.log(max(float(probs[token]), 1e-12))
            decoded = tok.decode(new, skip_special_tokens=False)
            return decoded, math.exp(logp)

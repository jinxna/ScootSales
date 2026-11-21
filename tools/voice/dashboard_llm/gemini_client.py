from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Optional

from tools.voice.dashboard_llm import copilot_schema as schema
from tools.voice.dashboard_llm.http_deadline import request_bytes

DEFAULT_MODEL = "gemini-3.5-flash-lite"
DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
MAX_OUTPUT_TOKENS = 128
SYSTEM_PROMPT = (
    "You map one short request from a sales dashboard user to exactly one function call. "
    "The request may be in English, Malay or both. Copy names exactly as the user said them. "
    "Give only the arguments the user mentioned. If no function fits, call no_match. Never invent values."
)


def to_declarations(tools: "list[dict[str, Any]]") -> "list[dict[str, Any]]":
    declarations = []
    for tool in tools:
        fn = tool["function"]
        properties = {
            key: {**{k: v for k, v in spec.items() if k != "type"}, "type": spec["type"].upper()}
            for key, spec in fn["parameters"]["properties"].items()
        }
        declaration: dict[str, Any] = {"name": fn["name"], "description": fn["description"]}
        if properties:
            declaration["parameters"] = {
                "type": "OBJECT", "properties": properties, "required": fn["parameters"]["required"],
            }
        declarations.append(declaration)
    return declarations


class GeminiGenerator:
    def __init__(self, api_key: str, model: str = DEFAULT_MODEL, base_url: str = DEFAULT_BASE_URL,
                 seconds_between_calls: float = 6.0, retries: int = 4, timeout: float = 60.0) -> None:
        parts = urllib.parse.urlsplit(base_url)
        if parts.scheme != "https" and not (parts.scheme == "http" and parts.hostname in LOOPBACK_HOSTS):
            raise ValueError("The Gemini base URL must be https, or http on a loopback address")
        self._key, self._model, self._base = api_key, model, base_url.rstrip("/")
        self._gap, self._retries, self._timeout = seconds_between_calls, retries, timeout
        self._last = 0.0
        self.model_version: Optional[str] = None

    def _post(self, body: "dict[str, Any]", deadline: Optional[float] = None) -> "dict[str, Any]":
        request = urllib.request.Request(
            f"{self._base}/models/{self._model}:generateContent",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "x-goog-api-key": self._key},
        )
        for attempt in range(self._retries + 1):
            wait = self._gap - (time.monotonic() - self._last)
            if wait > 0:
                if deadline is not None and time.monotonic() + wait >= deadline:
                    raise TimeoutError("Provider request deadline exceeded")
                time.sleep(wait)
            self._last = time.monotonic()
            remaining = self._timeout if deadline is None else min(self._timeout, deadline - self._last)
            if remaining <= 0:
                raise TimeoutError("Provider request deadline exceeded")
            try:
                return json.loads(request_bytes(request, timeout=remaining, deadline=deadline).data)
            except urllib.error.HTTPError as error:
                if error.code in (429, 500, 503) and attempt < self._retries:
                    delay = min(60, 5 * 2**attempt)
                    if deadline is not None and time.monotonic() + delay >= deadline:
                        raise TimeoutError("Provider request deadline exceeded") from None
                    time.sleep(delay)
                    continue
                raise RuntimeError(f"Gemini request failed with HTTP {error.code}") from None
        raise RuntimeError("unreachable")

    def __call__(self, text: str, pages: "list[dict[str, Any]]", actions: "list[str]",
                 *, deadline: Optional[float] = None) -> "tuple[str, float]":
        body = {
            "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "contents": [{"role": "user", "parts": [{"text": text}]}],
            "tools": [{"functionDeclarations": to_declarations(schema.build_tools(pages, actions))}],
            "toolConfig": {"functionCallingConfig": {"mode": "ANY"}},
            "generationConfig": {"temperature": 0, "maxOutputTokens": MAX_OUTPUT_TOKENS,
                                 "thinkingConfig": {"thinkingLevel": "minimal"}},
        }
        reply = self._post(body, deadline)
        self.model_version = reply.get("modelVersion", self.model_version)
        if any(candidate.get("finishReason") == "MAX_TOKENS" for candidate in reply.get("candidates", [])[:1]):
            logging.getLogger(__name__).error("Gemini response finished with MAX_TOKENS")
        calls = [
            part["functionCall"]
            for candidate in reply.get("candidates", [])[:1]
            for part in candidate.get("content", {}).get("parts", [])
            if part.get("functionCall")
        ]
        if len(calls) > 1:
            return "", 1.0
        for call in calls:
            if isinstance(call.get("name"), str):
                args = {k: (int(v) if isinstance(v, float) and v.is_integer() else v)
                        for k, v in (call.get("args") or {}).items()}
                return schema.serialize_call({"name": call["name"], "args": args}), 1.0
        return "no_match{}" + schema.END_CALL, 1.0

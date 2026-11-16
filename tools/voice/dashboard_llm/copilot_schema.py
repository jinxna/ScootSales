from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Mapping, Optional, Sequence

NAVIGATE = "navigate_to_page"
NO_MATCH = "no_match"
PREFILL = "<start_function_call>call:"
END_CALL = "<end_function_call>"
DEVELOPER_PROMPT = "You are a model that can do function calling with the following functions"

MAX_VALUE = 80
MAX_POSITION = 50
PERIODS = ("today", "yesterday", "this_week", "last_week", "this_month", "last_month")
ORDER_STATUSES = ("submitted", "approved", "rejected")
ITEM_STATUSES = ("in_review", "resolved", "ignored")

ACTION_SPECS: dict[str, dict[str, Any]] = {
    "search_orders": {
        "description": (
            "Find orders. Use the names exactly as the user said them. "
            "Give only the filters the user mentioned."
        ),
        "params": {
            "salesperson": {"type": "string", "description": "Salesperson name as spoken"},
            "retailer": {"type": "string", "description": "Retailer or shop name as spoken"},
            "period": {"type": "string", "description": "Time range", "enum": list(PERIODS)},
            "status": {"type": "string", "description": "Order status", "enum": list(ORDER_STATUSES)},
        },
        "required": [],
    },
    "export_results": {
        "description": "Export the results currently shown, as a CSV file.",
        "params": {},
        "required": [],
    },
    "daily_briefing": {
        "description": "Show the prioritised list of things that need attention today.",
        "params": {},
        "required": [],
    },
    "explain_item": {
        "description": "Explain one item of the briefing. Omit position for 'this one'.",
        "params": {"position": {"type": "integer", "description": "Item number in the list, from 1"}},
        "required": [],
    },
    "set_item_status": {
        "description": "Set the user's own review status on a briefing item. Omit position for 'it'.",
        "params": {
            "position": {"type": "integer", "description": "Item number in the list, from 1"},
            "status": {"type": "string", "description": "New status", "enum": list(ITEM_STATUSES)},
        },
        "required": ["status"],
    },
    "brief_retailer": {
        "description": "Prepare a visit brief for one retailer. Omit retailer for 'this retailer'.",
        "params": {"retailer": {"type": "string", "description": "Retailer or shop name as spoken"}},
        "required": [],
    },
}
ACTION_ORDER = tuple(ACTION_SPECS)

_KEY = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_CALL = re.compile(r"call:\s*([a-z_][a-z0-9_]*)\{([^{}]*)\}" + re.escape(END_CALL))
_ARG = re.compile(r"([a-z_][a-z0-9_]*):(?:<escape>([^<>{}]{1,%d})<escape>|(-?\d{1,3}))" % MAX_VALUE)


class RequestError(ValueError):
    pass


@dataclass(frozen=True)
class Call:
    name: str
    args: Mapping[str, Any]

    def as_dict(self) -> dict[str, Any]:
        return {"name": self.name, "args": dict(self.args)}


def _json_type(kind: str) -> str:
    return kind


def _function(name: str, description: str, params: Mapping[str, Mapping[str, Any]], required: Sequence[str]) -> dict[str, Any]:
    properties: dict[str, Any] = {}
    for key, spec in params.items():
        entry: dict[str, Any] = {"type": _json_type(spec["type"]), "description": spec["description"]}
        if "enum" in spec:
            entry["enum"] = list(spec["enum"])
        properties[key] = entry
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {"type": "object", "properties": properties, "required": list(required)},
        },
    }


def _navigate_tool(pages: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    described = "; ".join(
        f"{p['key']} = {p['label']}" + (f" ({', '.join(p['aliases'])})" if p["aliases"] else "")
        for p in pages
    )
    return _function(
        NAVIGATE,
        f"Open one dashboard page. Pages: {described}",
        {"page": {"type": "string", "description": "The page to open", "enum": [p["key"] for p in pages]}},
        ["page"],
    )


def build_tools(pages: Sequence[Mapping[str, Any]], actions: Sequence[str]) -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = []
    if pages:
        tools.append(_navigate_tool(pages))
    for name in ACTION_ORDER:
        if name in actions:
            spec = ACTION_SPECS[name]
            tools.append(_function(name, spec["description"], spec["params"], spec["required"]))
    tools.append(_function(NO_MATCH, "None of the other functions fit the request.", {}, []))
    return tools


def render_prompt(tok: Any, text: str, pages: Sequence[Mapping[str, Any]], actions: Sequence[str]) -> str:
    messages = [
        {"role": "developer", "content": DEVELOPER_PROMPT},
        {"role": "user", "content": text},
    ]
    prompt = tok.apply_chat_template(
        messages, tools=build_tools(pages, actions), add_generation_prompt=True, tokenize=False
    )
    return prompt + PREFILL


def serialize_call(call: Call | Mapping[str, Any]) -> str:
    name = call.name if isinstance(call, Call) else call["name"]
    args = call.args if isinstance(call, Call) else call.get("args", {})
    parts = []
    for key in sorted(args):
        value = args[key]
        parts.append(f"{key}:{value}" if isinstance(value, int) else f"{key}:<escape>{value}<escape>")
    return f"{name}{{{','.join(parts)}}}{END_CALL}"


def _resolve_page(value: str, pages: Sequence[Mapping[str, Any]]) -> Optional[str]:
    needle = value.strip().lower()
    if any(p["key"] == needle for p in pages):
        return needle
    hits = {
        p["key"]
        for p in pages
        if needle in {p["label"].lower(), *(a.lower() for a in p["aliases"])}
    }
    return hits.pop() if len(hits) == 1 else None


def parse_call(output: str, pages: Sequence[Mapping[str, Any]], actions: Sequence[str]) -> Optional[Call]:
    if output.count("call:") != 1:
        return None
    match = _CALL.search(output)
    if match is None:
        return None
    name, body = match.group(1), match.group(2)
    allowed = {NO_MATCH, *(a for a in actions if a in ACTION_SPECS)}
    if pages:
        allowed.add(NAVIGATE)
    if name not in allowed:
        return None

    args: dict[str, Any] = {}
    position = 0
    while position < len(body):
        arg = _ARG.match(body, position)
        if arg is None:
            return None
        key, text, number = arg.group(1), arg.group(2), arg.group(3)
        if key in args:
            return None
        args[key] = text.strip() if text is not None else int(number)
        position = arg.end()
        if position < len(body):
            if body[position] != ",":
                return None
            position += 1
            if position == len(body):
                return None

    if name == NO_MATCH:
        return Call(NO_MATCH, {}) if not args else None
    if name == NAVIGATE:
        if set(args) != {"page"} or not isinstance(args["page"], str):
            return None
        page = _resolve_page(args["page"], pages)
        return Call(NAVIGATE, {"page": page}) if page else None

    spec = ACTION_SPECS[name]
    for key, value in args.items():
        param = spec["params"].get(key)
        if param is None:
            return None
        if param["type"] == "integer":
            if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_POSITION:
                return None
        else:
            if not isinstance(value, str) or not value:
                return None
            if "enum" in param and value not in param["enum"]:
                return None
    if any(key not in args for key in spec["required"]):
        return None
    if name == "search_orders" and not set(args) & {"salesperson", "retailer", "period", "status"}:
        return None
    return Call(name, args)


def validate_request(payload: Any) -> tuple[str, list[dict[str, Any]], list[str]]:
    if not isinstance(payload, dict):
        raise RequestError("body must be an object")
    text = payload.get("text")
    if not isinstance(text, str) or not text.strip():
        raise RequestError("text must be a non-empty string")
    if len(text) > 200:
        raise RequestError("text too long")
    pages = payload.get("pages", [])
    if not isinstance(pages, list) or len(pages) > 60:
        raise RequestError("pages must be a list of at most 60")
    clean: list[dict[str, Any]] = []
    seen: set[str] = set()
    for page in pages:
        if not isinstance(page, dict):
            raise RequestError("page must be an object")
        key, label, aliases = page.get("key"), page.get("label"), page.get("aliases", [])
        if not isinstance(key, str) or not _KEY.fullmatch(key) or key in seen:
            raise RequestError("invalid or duplicate page key")
        if not isinstance(label, str) or len(label) > 80 or "<" in label:
            raise RequestError("invalid page label")
        if not isinstance(aliases, list) or not all(
            isinstance(a, str) and len(a) <= 60 and "<" not in a for a in aliases
        ):
            raise RequestError("invalid aliases")
        seen.add(key)
        clean.append({"key": key, "label": label, "aliases": aliases[:8]})
    actions = payload.get("actions", list(ACTION_ORDER))
    if not isinstance(actions, list) or not all(isinstance(a, str) and a in ACTION_SPECS for a in actions):
        raise RequestError("unknown action")
    return " ".join(text.split()), clean, [a for a in ACTION_ORDER if a in actions]

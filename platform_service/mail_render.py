from __future__ import annotations

import html
import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping

TEMPLATE_DIR = Path(__file__).with_name("mail_templates")
STATUS_KIND = "status_changed"
STATUS_VALUES = ("suspended", "read_only", "restored")

_PLACEHOLDER = re.compile(r"\{\{\s*params\.([A-Za-z][A-Za-z0-9]*)\s*\}\}")
_BRACES = re.compile(r"\{\{|\}\}|\{%|%\}")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


class MailTemplateError(ValueError):
    pass


@lru_cache(maxsize=1)
def catalogue() -> dict[str, dict[str, Any]]:
    return json.loads((TEMPLATE_DIR / "templates.json").read_text(encoding="utf-8"))


def template_names() -> list[str]:
    return list(catalogue())


def resolve(kind: str, params: Mapping[str, Any]) -> tuple[str, dict[str, Any]]:
    if kind == STATUS_KIND:
        status = params.get("status")
        if status not in STATUS_VALUES:
            raise MailTemplateError("Mail kind 'status_changed' needs status suspended, read_only or restored.")
        return f"{STATUS_KIND}_{status}", {name: value for name, value in params.items() if name != "status"}
    if kind not in catalogue():
        raise MailTemplateError(f"Unknown mail kind '{kind}'.")
    return kind, dict(params)


def _read(name: str, extension: str) -> str:
    return (TEMPLATE_DIR / f"{name}.{extension}").read_text(encoding="utf-8")


def _placeholders(source: str) -> set[str]:
    return set(_PLACEHOLDER.findall(source))


def _leftover_braces(source: str) -> bool:
    return bool(_BRACES.search(_PLACEHOLDER.sub("", source)))


def check_templates() -> list[str]:
    problems: list[str] = []
    for name, entry in catalogue().items():
        declared = set(entry["params"])
        sources = {"subject": entry["subject"], "html": _read(name, "html"), "text": _read(name, "txt")}
        for label, source in sources.items():
            if _leftover_braces(source):
                problems.append(f"{name}: {label} has template syntax other than {{{{ params.x }}}}")
            unknown = _placeholders(source) - declared
            if unknown:
                problems.append(f"{name}: {label} uses undeclared params {sorted(unknown)}")
        for label in ("html", "text"):
            missing = declared - _placeholders(sources[label])
            if missing:
                problems.append(f"{name}: {label} never prints params {sorted(missing)}")
        if not entry["brevoTemplateName"]:
            problems.append(f"{name}: brevoTemplateName is empty")
    return problems


def _fill(source: str, values: Mapping[str, str], escape: bool) -> str:
    return _PLACEHOLDER.sub(lambda match: html.escape(values[match.group(1)]) if escape else values[match.group(1)],
                            source)


def _text_values(name: str, declared: list[str], params: Mapping[str, Any]) -> dict[str, str]:
    missing = [key for key in declared if key not in params]
    if missing:
        raise MailTemplateError(f"Mail template '{name}' needs parameter '{missing[0]}'.")
    extra = [key for key in params if key not in declared]
    if extra:
        raise MailTemplateError(f"Mail template '{name}' does not take parameter '{extra[0]}'.")
    values: dict[str, str] = {}
    for key in declared:
        value = params[key]
        if isinstance(value, bool) or not isinstance(value, (str, int)):
            raise MailTemplateError(f"Parameter '{key}' of mail template '{name}' must be text or a whole number.")
        text = str(value).strip()
        if not text or _CONTROL.search(text):
            raise MailTemplateError(f"Parameter '{key}' of mail template '{name}' must be one line of text.")
        values[key] = text
    return values


def checked_values(kind: str, params: Mapping[str, Any]) -> tuple[str, dict[str, str]]:
    name, template_params = resolve(kind, params)
    return name, _text_values(name, catalogue()[name]["params"], template_params)


def render(kind: str, params: Mapping[str, Any]) -> tuple[str, str, str]:
    name, template_params = resolve(kind, params)
    entry = catalogue()[name]
    values = _text_values(name, entry["params"], template_params)
    return (_fill(entry["subject"], values, False),
            _fill(_read(name, "html"), values, True),
            _fill(_read(name, "txt"), values, False))

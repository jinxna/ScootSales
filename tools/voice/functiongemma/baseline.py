from __future__ import annotations

import re

try:
    from .adapter import FunctionGemmaAdapter, ParseResult, Rejection
except ImportError:  # pragma: no cover - supports direct script execution.
    from adapter import FunctionGemmaAdapter, ParseResult, Rejection


_SET_QUANTITY = re.compile(
    r"^(?:please\s+)?(?:set|change|update)\s+(.+?)\s+to\s+([a-z0-9]+)\s+(?:box(?:es)?)$",
)
_OPEN_ASSIGNED_ROUTE = re.compile(
    r"^(?:please\s+)?(?:(?:open|show|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:assigned\s+)?(?:route|visits?)(?:\s+for\s+today)?)|take me to (?:today's\s+route|(?:the\s+)?(?:assigned\s+)?(?:route|visits?)))$",
)
_OPEN_CURRENT_VISIT = re.compile(
    r"^(?:please\s+)?(?:(?:open|show|view|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:current visit|active retailer visit))|take me to (?:the\s+)?(?:current visit|visit i am working on))$",
)
_OPEN_CART = re.compile(
    r"^(?:please\s+)?(?:(?:open|show|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:cart|order cart|current cart|current order workspace))|take me to (?:the\s+)?(?:cart|order cart|current cart))$",
)
_OPEN_ORDER_HISTORY = re.compile(
    r"^(?:please\s+)?(?:(?:open|show|view|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:order history|previous orders|past orders|orders))|take me to (?:the\s+)?(?:order history|previous orders|past orders))$",
)
_CLEAR_PRODUCT_SEARCH = re.compile(
    r"^(?:please\s+)?(?:clear(?:\s+the)?(?:\s+(?:product|item))?\s+search|remove(?:\s+the)?(?:\s+(?:product|item))?\s+filter|reset(?:\s+the)?(?:\s+(?:product|item))?\s+search(?:\s+box)?|show\s+all\s+products)$",
)
_SHOW_VISIT_BRIEF = re.compile(
    r"^(?:please\s+)?(?:(?:show|open|read)(?:\s+(?:the\s+)?(?:visit\s+)?brief)|(?:show|open|read)(?:\s+(?:the\s+)?(?:active\s+)?retailer\s+brief)|give\s+me\s+(?:the\s+)?(?:today's\s+)?(?:visit\s+)?brief|tell\s+me\s+about\s+this\s+visit|show(?:\s+today's)?\s+visit\s+insights|what\s+are\s+my\s+visit\s+insights|what\s+should\s+i\s+know\s+about\s+this\s+visit)$",
)
_NUMBER_WORDS = {
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
}


def deterministic_baseline(
    transcript: str,
    adapter: FunctionGemmaAdapter,
) -> ParseResult:
    lowered = _normalize(transcript)
    if not lowered:
        return _rejection("empty_transcript")
    if re.search(
        r"\b(?:and|then)\s+(?:open|show|bring up|find|search|clear|remove|reset|submit|place|complete|finish|record|change|update)\b",
        lowered,
    ):
        return _rejection("compound_command")

    if _CLEAR_PRODUCT_SEARCH.fullmatch(lowered):
        return _open(adapter, "clear_product_search")

    quantity = _SET_QUANTITY.fullmatch(lowered)
    if quantity:
        product_query = quantity.group(1).strip()
        token = quantity.group(2)
        parsed_quantity = _NUMBER_WORDS.get(token)
        if parsed_quantity is None:
            try:
                parsed_quantity = int(token)
            except ValueError:
                return _rejection("ambiguous_numeric_phrase")
        return adapter.parse_output(
            _json_call(
                "set_draft_order_quantity",
                {
                    "productQuery": product_query,
                    "quantity": parsed_quantity,
                    "unit": "box",
                },
            )
        )

    if _OPEN_ASSIGNED_ROUTE.fullmatch(lowered):
        return _open(adapter, "open_assigned_route")
    if _OPEN_CURRENT_VISIT.fullmatch(lowered):
        return _open(adapter, "open_current_visit")
    if _OPEN_CART.fullmatch(lowered):
        return _open(adapter, "open_cart")
    if _OPEN_ORDER_HISTORY.fullmatch(lowered):
        return _open(adapter, "open_order_history")
    if _SHOW_VISIT_BRIEF.fullmatch(lowered):
        return _open(adapter, "show_visit_brief")

    search = re.fullmatch(
        r"(?:please\s+)?(?:find|search(?:\s+for)?|look for|show me)\s+(.+)",
        lowered,
    )
    if search and search.group(1).strip():
        query = search.group(1).strip()
        return adapter.parse_output(_json_call("search_products", {"query": query}))

    if re.fullmatch(r"(?:please\s+)?(?:submit|place)\s+(?:this\s+)?order", lowered):
        return _open(adapter, "submit_order")
    if re.fullmatch(r"(?:please\s+)?(?:complete|finish|close)\s+(?:this\s+)?visit", lowered):
        return _open(adapter, "complete_visit")
    if re.fullmatch(
        r"(?:please\s+)?(?:change|update)\s+(?:the\s+)?route\s+(?:status|state)",
        lowered,
    ):
        return _open(adapter, "change_route_state")
    if re.fullmatch(
        r"(?:please\s+)?(?:record|add)\s+(?:a\s+)?(?:visit\s+)?outcome",
        lowered,
    ):
        return _open(adapter, "record_outcome")
    if re.fullmatch(
        r"(?:please\s+)?(?:change|turn on|turn off)\s+(?:my\s+)?(?:location|permissions?)",
        lowered,
    ):
        return _open(
            adapter,
            "change_permissions" if "permission" in lowered else "change_location_state",
        )

    return _rejection("unsupported_command")


def _normalize(transcript: str) -> str:
    lowered = transcript.strip().lower().replace("’", "'").replace("‘", "'")
    lowered = re.sub(r"(?<!\d)\.(?!\d)", " ", lowered)
    lowered = re.sub(r"[!?,;:]", " ", lowered)
    return " ".join(lowered.split())


def _open(adapter: FunctionGemmaAdapter, action_id: str) -> ParseResult:
    return adapter.parse_output(_json_call(action_id, {}))


def _json_call(action_id: str, parameters: dict[str, object]) -> str:
    import json

    return json.dumps(
        {"schemaVersion": 1, "actionId": action_id, "parameters": parameters},
        separators=(",", ":"),
    )


def _rejection(reason: str) -> ParseResult:
    return ParseResult(rejection=Rejection(reason=reason))

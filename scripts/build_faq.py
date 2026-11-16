from __future__ import annotations

import json
import re
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "faq" / "faq.json"
DART_COMPANY = ROOT / "packages" / "scoot_help" / "lib" / "src" / "faq_data.dart"
DART_STAFF = ROOT / "packages" / "scoot_help" / "lib" / "src" / "staff_faq_data.dart"
WEBSITE = ROOT / "website" / "src" / "data" / "faq.json"

AUDIENCES = {
    "public": ("public", "Website visitors"),
    "admin": ("admin", "Administrators"),
    "supervisor": ("supervisor", "Supervisors"),
    "branch_manager": ("branchManager", "Branch managers"),
    "salesperson": ("salesperson", "Salespeople"),
    "staff": ("staff", "Scoot Sales staff"),
}
COMPANY_ROLES = ("admin", "supervisor", "branch_manager", "salesperson")
ITEM_FIELDS = {"id", "audiences", "topic", "question", "answer", "since"}
ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MAX_SENTENCE_WORDS = 25
DART_WIDTH = 80
INTERNAL_TEXT = (
    (re.compile(r"\b[\w/-]+\.(?:dart|py|md|json|ts|tsx|log|yaml|rules)\b"), "a file path"),
    (re.compile(r"\bDEC-\d+|\b[A-Z]{2,5}-\d{2}\b"), "a decision or register ID"),
    (re.compile(r"\[(?:source|report|flow|ledger|unverified)\b", re.I), "an evidence label"),
    (re.compile(r"qa_artifacts|codex|FYP-A|rebuild/|lane2?/|commit [0-9a-f]{7}", re.I), "internal team text"),
    (re.compile(r"\bAI\b|\bLLM\b|Gemini|Claude|language model", re.I), "a mention of AI"),
)


class FaqError(Exception):
    pass


def sentences(text: str) -> list[str]:
    return [part for part in re.split(r"(?<=[.!?])\s+", text.strip()) if part]


def validate(data: object) -> dict:
    if not isinstance(data, dict) or set(data) != {"topics", "items"}:
        raise FaqError("The source must have exactly the keys topics and items.")
    topics, items = data["topics"], data["items"]
    if not isinstance(topics, list) or not topics or len(set(topics)) != len(topics):
        raise FaqError("topics must be a non-empty list with no repeats.")
    if not isinstance(items, list) or not items:
        raise FaqError("items must be a non-empty list.")
    problems: list[str] = []
    seen: set[str] = set()
    used: set[str] = set()
    for index, item in enumerate(items):
        label = item.get("id", f"item {index + 1}") if isinstance(item, dict) else f"item {index + 1}"
        if not isinstance(item, dict) or set(item) != ITEM_FIELDS:
            problems.append(f"{label}: needs exactly the fields {sorted(ITEM_FIELDS)}.")
            continue
        if not isinstance(item["id"], str) or not ID_PATTERN.fullmatch(item["id"]):
            problems.append(f"{label}: id must be lower-case words joined by hyphens.")
        elif item["id"] in seen:
            problems.append(f"{label}: id is used twice.")
        seen.add(str(item["id"]))
        audiences = item["audiences"]
        if (not isinstance(audiences, list) or not audiences or len(set(audiences)) != len(audiences)
                or any(audience not in AUDIENCES for audience in audiences)):
            problems.append(f"{label}: audiences must be distinct values from {sorted(AUDIENCES)}.")
        elif "staff" in audiences and len(audiences) > 1:
            problems.append(f"{label}: a staff item cannot also be for the website or a company role.")
        if item["topic"] not in topics:
            problems.append(f"{label}: topic '{item['topic']}' is not in topics.")
        used.add(item["topic"])
        question, answer = item["question"], item["answer"]
        if not isinstance(question, str) or not question.strip().endswith("?"):
            problems.append(f"{label}: question must be text that ends with a question mark.")
        if not isinstance(answer, list) or not answer or not all(isinstance(line, str) and line.strip() for line in answer):
            problems.append(f"{label}: answer must be a list of non-empty paragraphs.")
            continue
        try:
            date.fromisoformat(item["since"])
        except (TypeError, ValueError):
            problems.append(f"{label}: since must be a date like 2026-11-05.")
        for text in [question, *answer]:
            for pattern, kind in INTERNAL_TEXT:
                if pattern.search(text):
                    problems.append(f"{label}: contains {kind}: '{pattern.search(text).group(0)}'.")
            for sentence in sentences(text):
                words = len(sentence.split())
                if words > MAX_SENTENCE_WORDS:
                    problems.append(f"{label}: a sentence has {words} words (at most {MAX_SENTENCE_WORDS}): '{sentence}'")
    unused = [topic for topic in topics if topic not in used]
    if unused:
        problems.append(f"topics with no items: {unused}.")
    if problems:
        raise FaqError("\n".join(problems))
    return data


def dart_string(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$").replace("\n", "\\n")
    return f"'{escaped}'"


def dart_list(indent: str, head: str, elements: list[str], tail: str) -> list[str]:
    single = f"{indent}{head}{', '.join(elements)}{tail}"
    if len(single) <= DART_WIDTH:
        return [single]
    return [f"{indent}{head}", *(f"{indent}  {element}," for element in elements), f"{indent}{tail}"]


def dart_item(item: dict) -> list[str]:
    audiences = [f"FaqAudience.{AUDIENCES[name][0]}" for name in item["audiences"]]
    lines = [
        "  FaqItem(",
        f"    id: {dart_string(item['id'])},",
        *dart_list("    ", "audiences: <FaqAudience>[", audiences, "],"),
        f"    topic: {dart_string(item['topic'])},",
        f"    question: {dart_string(item['question'])},",
        *dart_list("    ", "answer: <String>[", [dart_string(line) for line in item["answer"]], "],"),
        f"    since: {dart_string(item['since'])},",
        "  ),",
    ]
    return lines


def ordered(data: dict, keep) -> tuple[list[str], list[dict]]:
    items = [item for item in data["items"] if keep(item)]
    topics = [topic for topic in data["topics"] if any(item["topic"] == topic for item in items)]
    return topics, sorted(items, key=lambda item: topics.index(item["topic"]))


def is_staff(item: dict) -> bool:
    return item["audiences"] == ["staff"]


def render_dart(data: dict, staff: bool) -> str:
    topics, items = ordered(data, is_staff if staff else (lambda item: not is_staff(item)))
    prefix = "staffFaq" if staff else "faq"
    lines = ["import 'faq_item.dart';", ""]
    lines += dart_list("", f"const List<String> {prefix}Topics = <String>[", [dart_string(t) for t in topics], "];")
    lines.append("")
    if items:
        lines.append(f"const List<FaqItem> {prefix}Items = <FaqItem>[")
        for item in items:
            lines += dart_item(item)
        lines.append("];")
    else:
        lines.append(f"const List<FaqItem> {prefix}Items = <FaqItem>[];")
    if not staff:
        lines += [
            "",
            "List<FaqItem> faqFor(FaqAudience audience) => <FaqItem>[",
            "  for (final FaqItem item in faqItems)",
            "    if (item.audiences.contains(audience)) item,",
            "];",
        ]
    return "\n".join(lines) + "\n"


def render_website(data: dict) -> str:
    topics, items = ordered(data, lambda item: "public" in item["audiences"])
    payload = {
        "topics": topics,
        "items": [
            {key: item[key] for key in ("id", "topic", "question", "answer")} for item in items
        ],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def readers(audiences: list[str]) -> str:
    roles = [name for name in COMPANY_ROLES if name in audiences]
    if len(roles) == len(COMPANY_ROLES):
        return "Everyone in the company"
    names = [AUDIENCES[name][1] for name in roles]
    if not names:
        return "Anyone who wants to know"
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1].lower()


def outputs(data: dict) -> dict[Path, str]:
    return {
        DART_COMPANY: render_dart(data, staff=False),
        DART_STAFF: render_dart(data, staff=True),
        WEBSITE: render_website(data),
    }


def main(argv: list[str]) -> int:
    check = argv == ["--check"]
    if argv and not check:
        print("Usage: python scripts/build_faq.py [--check]")
        return 2
    try:
        data = validate(json.loads(SOURCE.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, FaqError) as error:
        print(f"FAIL: {SOURCE.relative_to(ROOT).as_posix()} is not valid.\n{error}")
        return 1
    stale: list[str] = []
    written: list[str] = []
    for path, text in outputs(data).items():
        current = path.read_text(encoding="utf-8").replace("\r\n", "\n") if path.is_file() else None
        if current == text:
            continue
        if check:
            stale.append(path.relative_to(ROOT).as_posix())
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8", newline="\n")
            written.append(path.relative_to(ROOT).as_posix())
    counts = {name: sum(name in item["audiences"] for item in data["items"]) for name in AUDIENCES}
    summary = ", ".join(f"{name} {count}" for name, count in counts.items())
    if stale:
        print("FAIL: these files do not match faq/faq.json. Run python scripts/build_faq.py and commit the result.")
        for path in stale:
            print(f"  {path}")
        return 1
    result = f"wrote {', '.join(written)}" if written else "generated files match the source"
    print(f"OK: {len(data['items'])} FAQ items ({summary}); {result}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

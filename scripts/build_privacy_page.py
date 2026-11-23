from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "packages" / "scoot_legal" / "lib" / "src" / "legal_text.dart"
EMAIL = re.compile(r"[A-Za-z0-9._+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}")
INTERPOLATION = re.compile(r"\$\{|\$[A-Za-z_]")
CONTACT_TOKEN = "$legalContactEmail"
LANGUAGES = (("privacyEnglish", "en", "English"), ("privacyMalay", "ms", "Bahasa Malaysia"))
STRING = re.compile(r"'((?:[^'\\]|\\.)*)'")
SECTION = re.compile(r"LegalSection\(\s*((?:'(?:[^'\\]|\\.)*'\s*)+),\s*((?:'(?:[^'\\]|\\.)*'\s*)+),?\s*\)")
STYLE = """
body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#1d2420;background:#f6f8f7;line-height:1.6}
main{max-width:760px;margin:0 auto;padding:32px 20px 64px}
header{border-bottom:3px solid #3A7D5C;margin-bottom:24px;padding-bottom:12px}
.brand{color:#3A7D5C;font-weight:700;letter-spacing:.02em;margin:0}
h1{font-size:1.9rem;margin:.2em 0}
h2{font-size:1.15rem;margin:1.6em 0 .4em}
nav a,a{color:#2c6248}
nav{margin:8px 0 0}
nav a{margin-right:16px}
.version{color:#56605a;margin:0}
section.language{background:#fff;border:1px solid #dfe5e1;border-radius:10px;padding:8px 24px 20px;margin-top:24px}
p{margin:.4em 0}
"""


def dart_string(literal: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), literal)


def joined(literals: str) -> str:
    return "".join(dart_string(part) for part in STRING.findall(literals))


def constant(text: str, name: str) -> str:
    match = re.search(r"const String %s = '([^']+)';" % name, text)
    if not match:
        sys.exit(f"STOP: {name} is missing from {SOURCE.relative_to(ROOT)}.")
    return match.group(1)


def document(text: str, name: str) -> tuple[str, str, list[tuple[str, str]]]:
    start = text.find(f"const LegalText {name} = LegalText(")
    if start < 0:
        sys.exit(f"STOP: {name} is missing from {SOURCE.relative_to(ROOT)}.")
    end = text.find("\nconst ", start + 1)
    block = text[start : end if end > 0 else len(text)]
    title = re.search(r"title: '([^']+)'", block)
    label = re.search(r"versionLabel: '([^']+)'", block)
    sections = [(joined(h), joined(b)) for h, b in SECTION.findall(block)]
    if not title or not label or not sections or len(sections) != block.count("LegalSection("):
        sys.exit(f"STOP: {name} in {SOURCE.relative_to(ROOT)} could not be read.")
    return title.group(1), label.group(1), sections


def paragraph(line: str, email: str) -> str:
    escaped = html.escape(line)
    link = f'<a href="mailto:{html.escape(quote(email, safe="@"))}">{html.escape(email)}</a>'
    return "<p>" + escaped.replace(html.escape(CONTACT_TOKEN), link) + "</p>"


def build(email: str) -> str:
    text = SOURCE.read_text(encoding="utf-8")
    version = constant(text, "legalVersion")
    date = constant(text, "legalDate")
    parts: list[str] = []
    links: list[str] = []
    english_title = ""
    for name, lang, language in LANGUAGES:
        title, label, sections = document(text, name)
        english_title = english_title or title
        links.append(f'<a href="#{lang}">{html.escape(language)}</a>')
        body = [f'<section class="language" id="{lang}" lang="{lang}">', f"<h1>{html.escape(title)}</h1>"]
        body.append(f'<p class="version">{html.escape(label)} {html.escape(version)} · {html.escape(date)}</p>')
        for heading, content in sections:
            body.append(f"<h2>{html.escape(heading)}</h2>")
            body.extend(paragraph(line, email) for line in content.split("\n") if line.strip())
        body.append("</section>")
        parts.append("\n".join(body))
    page = "\n".join(parts)
    if INTERPOLATION.search(page) or "[REPLACE" in page:
        sys.exit("STOP: the page still holds a placeholder or an unread Dart value.")
    return (
        "<!DOCTYPE html>\n"
        '<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{html.escape(english_title)} - Scoot Sales</title>\n"
        '<meta name="description" content="Scoot Sales privacy policy for the company dashboard, the salesperson phone app and the Control Centre.">\n'
        f"<style>{STYLE}</style>\n</head>\n<body>\n<main>\n"
        f'<header><p class="brand">Scoot Sales</p><nav aria-label="Language">{"".join(links)}</nav></header>\n'
        f"{page}\n</main>\n</body>\n</html>\n"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Write the public Scoot Sales privacy page from the shared legal text.")
    parser.add_argument("--email", required=True, help="Privacy contact address shown on the page.")
    parser.add_argument("--out", required=True, type=Path, help="Folder that receives privacy/index.html.")
    args = parser.parse_args(argv)
    if not EMAIL.fullmatch(args.email):
        print(f"STOP: '{args.email}' is not an email address.", file=sys.stderr)
        return 1
    target = args.out / "privacy" / "index.html"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(build(args.email), encoding="utf-8", newline="\n")
    print(f"Wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

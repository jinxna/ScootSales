from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "packages" / "scoot_legal" / "lib" / "src" / "legal_text.dart"
IMPORT = "package:scoot_legal/scoot_legal.dart"
CONSUMERS = (
    ROOT / "admin_dashboard" / "lib" / "pages" / "legal_documents_page.dart",
    ROOT / "admin_dashboard" / "lib" / "control_centre" / "pages" / "legal_page.dart",
    ROOT / "flutter_mobile_app" / "lib" / "screens" / "legal_document_screen.dart",
)
PUBSPECS = (
    ROOT / "admin_dashboard" / "pubspec.yaml",
    ROOT / "flutter_mobile_app" / "pubspec.yaml",
)
APP_SOURCES = (ROOT / "admin_dashboard" / "lib", ROOT / "flutter_mobile_app" / "lib")
PAIRS = (("privacyEnglish", "privacyMalay"), ("termsEnglish", "termsMalay"))
GPS_LANGUAGES = {
    "privacyEnglish": ("Location during work", "How long we keep data", "1 year", "30 days"),
    "privacyMalay": ("Lokasi semasa kerja", "Berapa lama kami menyimpan data", "1 tahun", "30 hari"),
}
BANNED_PHRASES = (
    "stays with that visit or order",
    "kekal bersama lawatan atau pesanan",
    "a trail kept 30 days",
    "Location trail deleted after 30 days",
    "deletes the trail after 30 days",
    "follows the retention of the record",
)
HARD_CODED_VERSION = re.compile(r"['\"](?:Version|Versi) \d+\.\d+")


def blocks(text: str) -> dict[str, str]:
    starts = list(re.finditer(r"const LegalText (\w+) = LegalText\(", text))
    return {
        match.group(1): text[match.end() : starts[index + 1].start() if index + 1 < len(starts) else len(text)]
        for index, match in enumerate(starts)
    }


def headings(block: str) -> list[str]:
    return re.findall(r"LegalSection\(\s*'([^']+)'", block)


def main() -> int:
    problems: list[str] = []
    if not SOURCE.is_file():
        print(f"FAIL: the shared legal source {SOURCE.relative_to(ROOT)} is missing.")
        return 1
    text = SOURCE.read_text(encoding="utf-8")
    version = re.search(r"const String legalVersion = '([^']+)';", text)
    date = re.search(r"const String legalDate = '([^']+)';", text)
    if not version or not date:
        print("FAIL: legalVersion or legalDate is missing from the shared legal source.")
        return 1
    found = blocks(text)
    every_heading: list[str] = []
    for english, malay in PAIRS:
        if english not in found or malay not in found:
            problems.append(f"{english} or {malay} is missing.")
            continue
        english_headings, malay_headings = headings(found[english]), headings(found[malay])
        every_heading += english_headings + malay_headings
        if not english_headings or len(english_headings) != len(malay_headings):
            problems.append(
                f"{english} has {len(english_headings)} sections but {malay} has {len(malay_headings)}."
            )
    for name, (location_title, retention_title, order_period, other_period) in GPS_LANGUAGES.items():
        sections = re.split(r"LegalSection\(\s*", found.get(name, ""))
        for title in (location_title, retention_title):
            body = next((s for s in sections if s.startswith("'") and title in s.split("'")[1]), "")
            if not re.search(rf"(?:order|pesanan)[^\n]*{order_period}", body):
                problems.append(f"{name} section '{title}' does not state order GPS kept {order_period}.")
            if not re.search(rf"(?:other|lain)[^\n]*{other_period}", body):
                problems.append(f"{name} section '{title}' does not state other GPS data kept {other_period}.")
    for name, block in found.items():
        for phrase in BANNED_PHRASES:
            if phrase in block:
                problems.append(f"{name} still says '{phrase}'.")
    for consumer in CONSUMERS:
        if not consumer.is_file():
            problems.append(f"{consumer.relative_to(ROOT)} is missing.")
        elif IMPORT not in consumer.read_text(encoding="utf-8"):
            problems.append(f"{consumer.relative_to(ROOT)} does not import {IMPORT}.")
    for pubspec in PUBSPECS:
        if "path: ../packages/scoot_legal" not in pubspec.read_text(encoding="utf-8"):
            problems.append(f"{pubspec.relative_to(ROOT)} does not depend on packages/scoot_legal.")
    for folder in APP_SOURCES:
        for path in folder.rglob("*.dart"):
            source = path.read_text(encoding="utf-8")
            if HARD_CODED_VERSION.search(source):
                problems.append(f"{path.relative_to(ROOT)} hard-codes a legal version string.")
            copied = [heading for heading in every_heading if f"'{heading}'" in source]
            if copied:
                problems.append(f"{path.relative_to(ROOT)} copies legal headings: {copied[:3]}.")
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}")
        return 1
    print(
        f"OK: legal text version {version.group(1)} dated {date.group(1)}; "
        f"{len(every_heading)} section headings in English and Bahasa Malaysia; "
        f"{len(CONSUMERS)} app screens agree."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

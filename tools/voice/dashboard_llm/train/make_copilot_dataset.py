from __future__ import annotations

import argparse
import copy
import hashlib
import json
import random
import re
import sys
from pathlib import Path
from typing import Any

from tools.voice.dashboard_llm import copilot_schema as schema
from tools.voice.dashboard_llm.train import make_dataset as md

HERE = Path(__file__).resolve().parent
LLM_DIR = HERE.parent
DATA = HERE / "data_copilot"
FROZEN_FILES = ("copilot_eval_phrases.json", "eval_phrases.json", "fresh_phrases.json")
SEED = 20261006
SIZES = {"train": 8000, "validation": 800, "test": 1200}

NAV_INTENT_BLOCKLIST = {
    "what needs my attention today", "what is going on today", "give me the daily overview",
    "how many orders came in today", "what orders are pending", "check the latest customer orders",
    "review the submitted orders", "see the orders the reps submitted", "find an order from a retailer",
    "which orders need my approval", "i have orders waiting to be approved", "what did the shops order",
}
NAV_NOUN_BLOCKLIST = {"submitted orders", "pending orders"}

SALESPEOPLE = {
    "train": ["Ahmad", "Siti", "Wong", "Kumar", "Aisyah", "Daniel", "Farid", "Mei Ling", "Raj", "Hafiz",
              "Nurul", "Jason", "Priya", "Zul", "Amirul", "Lim", "Syafiq", "Devi", "Hana", "Ravi",
              "Fatimah", "Chong", "Irfan", "Ali", "Siew Lan", "Mohan", "Kamal", "Azlan", "Tan", "Suria"],
    "validation": ["Haziq", "Wei Jie", "Nadia", "Selvam", "Rina"],
    "test": ["Faizal", "Li Na", "Anand", "Syazwani", "Joseph", "Dewi", "Hakim", "Mei Yee"],
}
RETAILERS = {
    "train": ["Kedai Maju", "Pasar Mini Sentosa", "Mini Mart Sejahtera", "Pasaraya Jaya", "Kedai Runcit Ali",
              "Stesen Mart Bintang", "Everfresh Mart", "Gedung Rakyat", "Kedai Makmur", "Sri Murni Mart",
              "Borneo Grocer", "Lucky Mini Market", "Kedai Runcit Hasan", "Bintang Supermart", "Sin Hock Trading",
              "Pasar Raya Kenanga", "Kedai Mewah", "Hup Seng Store", "Mutiara Mart", "Green Valley Mart",
              "KK Mart Jalan Utama", "Kedai Sinar", "Pekan Baru Minimarket", "Berkat Mart", "Wawasan Supermarket"],
    "validation": ["Kedai Harapan", "Sentral Mart", "Cahaya Minimarket", "Teck Soon Trading"],
    "test": ["Kedai Bahagia", "Metro Grocer", "Pasaraya Dahlia", "Seng Huat Store", "Kedai Runcit Kassim", "Sunrise Mart"],
}

def _pool(base: dict[str, list[str]], held: dict[str, list[str]]) -> dict[str, dict[str, list[str]]]:
    keys = set(base) | set(held)
    return {k: {"train": base.get(k, []), "held": base.get(k, []) + held.get(k, [])} for k in keys}


PERIOD = {
    "en": _pool(
        {"today": ["today"], "yesterday": ["yesterday"], "this_week": ["this week"], "last_week": ["last week"],
         "this_month": ["this month"], "last_month": ["last month"]},
        {"today": ["so far today", "today only"], "yesterday": ["from yesterday"],
         "this_week": ["over this week", "in this week"], "last_week": ["during last week", "over last week"],
         "this_month": ["throughout this month"], "last_month": ["during last month", "over last month"]}),
    "ms": _pool(
        {"today": ["hari ini"], "yesterday": ["semalam"], "this_week": ["minggu ini"],
         "last_week": ["minggu lepas", "minggu lalu"], "this_month": ["bulan ini"],
         "last_month": ["bulan lepas", "bulan lalu"]},
        {"today": ["setakat hari ini"], "yesterday": ["pada semalam"], "this_week": ["sepanjang minggu ini"],
         "last_week": ["sepanjang minggu lepas"], "this_month": ["bagi bulan ini"],
         "last_month": ["sepanjang bulan lepas"]}),
}
ORDER_STATUS = {
    "en": _pool({"submitted": ["submitted", "new", "pending"], "approved": ["approved", "accepted"],
                 "rejected": ["rejected", "declined", "refused"]},
                {"approved": ["signed off"], "rejected": ["turned down", "denied"], "submitted": ["unprocessed"]}),
    "ms": _pool({"submitted": ["dihantar", "baharu"], "approved": ["diluluskan"], "rejected": ["ditolak"]},
                {"approved": ["telah diluluskan"], "rejected": ["telah ditolak"]}),
}
ITEM_STATUS = {
    "en": _pool({"in_review": ["in review", "under review"], "resolved": ["resolved", "done"], "ignored": ["ignored", "dismissed"]},
                {"in_review": ["pending review"], "resolved": ["completed"], "ignored": ["skipped"]}),
    "ms": _pool({"in_review": ["dalam semakan", "sedang disemak"], "resolved": ["selesai"], "ignored": ["diabaikan"]},
                {"in_review": ["untuk disemak"], "resolved": ["telah selesai"], "ignored": ["dilangkau"]}),
}
ORDINAL = {
    "en": ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"],
    "ms": ["pertama", "kedua", "ketiga", "keempat", "kelima", "keenam", "ketujuh", "kelapan", "kesembilan", "kesepuluh"],
}

SEARCH = {
    "train": [
        ("en", "show {sp}'s orders"), ("en", "show {sp}'s orders {pd}"), ("en", "show {sp}'s {st} orders {pd}"),
        ("en", "{st} orders from {rt}"), ("en", "orders from {rt} {pd}"), ("en", "list the orders {sp} submitted {pd}"),
        ("en", "how many orders did {sp} submit {pd}"), ("en", "find {st} orders for {rt} {pd}"),
        ("en", "show me orders {pd}"), ("en", "orders {pd}"), ("en", "what did {sp} sell {pd}"),
        ("en", "show {sp} orders for {rt}"), ("en", "get {sp}'s {st} orders at {rt}"), ("en", "list {st} orders {pd}"),
        ("en", "{sp} orders {pd}"), ("en", "pull up {rt} orders {pd}"), ("en", "any orders from {rt} {pd}"),
        ("en", "check {sp}'s orders {pd}"), ("en", "search orders by {sp}"), ("en", "search orders for {rt}"),
        ("en", "show me the {st} orders from {rt}"),
        ("ms", "tunjuk pesanan {sp} {pd}"), ("ms", "pesanan {st} dari {rt} {pd}"), ("ms", "senaraikan pesanan {sp} {pd}"),
        ("ms", "cari pesanan {rt}"), ("ms", "berapa pesanan {sp} {pd}"), ("ms", "papar pesanan {sp}"),
        ("ms", "pesanan {pd}"), ("ms", "tunjuk pesanan {st} {pd}"), ("ms", "pesanan {sp} di {rt} {pd}"),
        ("mix", "show pesanan {sp} {pd}"), ("mix", "tunjuk orders {rt} {pd}"), ("mix", "show orders {sp} {pd}"),
        ("en", "only {rt}"), ("en", "just {rt}"), ("en", "only the {st} ones"), ("en", "just the {st} ones"),
        ("en", "{pd} instead"), ("en", "for {sp}"), ("en", "only for {sp}"), ("en", "make it {pd}"),
        ("en", "same but for {rt}"), ("en", "filter by {st}"), ("en", "what about {sp}"), ("en", "how about {rt}"),
        ("ms", "hanya {rt}"), ("ms", "yang {st} sahaja"), ("ms", "untuk {sp} sahaja"), ("ms", "{pd} sahaja"),
        ("ms", "bagaimana dengan {sp}"),
    ],
    "validation": [
        ("en", "give me {sp}'s orders {pd}"), ("en", "which orders did {sp} submit {pd}"), ("en", "{st} orders for {rt}"),
        ("en", "find orders from {rt} {pd}"), ("en", "view {sp}'s {st} orders"), ("en", "orders by {sp} at {rt}"),
        ("en", "show every {st} order {pd}"), ("ms", "paparkan pesanan {sp} {pd}"), ("ms", "pesanan {st} untuk {rt}"),
        ("mix", "tunjuk {st} orders {sp}"),
        ("en", "limit it to {rt}"), ("en", "narrow it to the {st} ones"), ("en", "switch to {pd}"), ("en", "and for {sp}"),
        ("ms", "hadkan kepada {rt}"), ("ms", "tukar kepada {pd}"),
    ],
    "test": [
        ("en", "i need {sp}'s orders {pd}"), ("en", "has {rt} ordered {pd}"), ("en", "display {st} orders {pd}"),
        ("en", "look up {sp}'s {st} orders at {rt}"), ("en", "everything {sp} sold {pd}"),
        ("en", "orders placed by {sp} {pd}"), ("en", "{rt} {st} orders"), ("ms", "saya nak tengok pesanan {sp} {pd}"),
        ("ms", "ada pesanan dari {rt} {pd}"), ("ms", "lihat pesanan {st} {pd}"), ("mix", "check pesanan {rt} {pd}"),
        ("en", "restrict to {rt}"), ("en", "show only {st} ones"), ("en", "change it to {pd}"), ("en", "now {sp}'s"),
        ("ms", "tapis {rt}"), ("ms", "ubah kepada {pd}"), ("ms", "pula untuk {sp}"),
    ],
}
BRIEFING = {
    "train": [("en", "what needs my attention today"), ("en", "give me my daily briefing"),
              ("en", "what should i focus on today"), ("en", "brief me for today"), ("en", "what is on my plate today"),
              ("en", "any priorities for today"), ("en", "start my day"), ("en", "what are my priorities"),
              ("en", "daily briefing please"), ("ms", "apa perlu saya beri perhatian hari ini"),
              ("ms", "beri saya ringkasan harian"), ("ms", "apa keutamaan saya hari ini"), ("ms", "mulakan hari saya")],
    "validation": [("en", "what's urgent today"), ("en", "what should i tackle first"),
                   ("ms", "ringkasan hari ini"), ("ms", "apa yang mendesak")],
    "test": [("en", "what is urgent this morning"), ("en", "walk me through today"), ("en", "morning briefing"),
             ("ms", "apa yang mendesak hari ini"), ("ms", "apa saya patut buat dahulu hari ini")],
}
EXPORT = {
    "train": [("en", "export these"), ("en", "download this as csv"), ("en", "export the results"),
              ("en", "save these to a file"), ("en", "give me a csv of this"), ("en", "export to csv"),
              ("en", "export this list"), ("ms", "eksport ini"), ("ms", "muat turun senarai ini"),
              ("ms", "eksport ke csv"), ("ms", "simpan keputusan ini sebagai fail")],
    "validation": [("en", "download these results"), ("en", "get me a spreadsheet of this"), ("ms", "eksport senarai ini")],
    "test": [("en", "can i have this as a csv"), ("en", "export everything shown"), ("en", "save this list as a file"),
             ("ms", "muat turun sebagai csv"), ("ms", "boleh eksport yang ini")],
}
EXPLAIN = {
    "train": [("en", "explain the {ord} item"), ("en", "explain item {n}"), ("en", "why is the {ord} one there"),
              ("en", "tell me more about the {ord} item"), ("en", "what does the {ord} item mean"),
              ("en", "why is item {n} important"), ("en", "explain number {n}"), ("en", "explain this one"),
              ("en", "why is that important"), ("en", "why is it there"), ("en", "explain it"),
              ("en", "what is this about"), ("ms", "terangkan item {ord}"), ("ms", "kenapa item {ord} penting"),
              ("ms", "terangkan nombor {n}"), ("ms", "terangkan yang ini"), ("ms", "kenapa ini penting"),
              ("ms", "apa maksud item {n}")],
    "validation": [("en", "walk me through the {ord} item"), ("en", "why did the {ord} one come up"),
                   ("en", "explain that"), ("ms", "huraikan item {ord}"), ("ms", "kenapa item {n} muncul")],
    "test": [("en", "break down item {n}"), ("en", "what is the {ord} item about"), ("en", "say more about the {ord} one"),
             ("en", "why is this here"), ("ms", "jelaskan item {n}"), ("ms", "apa itu item {ord}"),
             ("ms", "kenapa yang ini penting")],
}
SET_STATUS = {
    "train": [("en", "mark the {ord} item as {sv}"), ("en", "mark it as {sv}"), ("en", "set item {n} to {sv}"),
              ("en", "set it to {sv}"), ("en", "mark item {n} as {sv}"), ("en", "move the {ord} one to {sv}"),
              ("en", "ignore the {ord} item", {"status": "ignored"}), ("en", "dismiss it", {"status": "ignored"}),
              ("en", "ignore item {n}", {"status": "ignored"}), ("ms", "tandakan item {ord} sebagai {sv}"),
              ("ms", "tandakan sebagai {sv}"), ("ms", "tetapkan item {n} kepada {sv}"),
              ("ms", "abaikan item {ord}", {"status": "ignored"}), ("ms", "abaikan yang ini", {"status": "ignored"})],
    "validation": [("en", "flag the {ord} item as {sv}"), ("en", "set the {ord} one to {sv}"),
                   ("en", "skip the {ord} item", {"status": "ignored"}), ("ms", "letakkan item {ord} sebagai {sv}")],
    "test": [("en", "update item {n} to {sv}"), ("en", "switch it to {sv}"), ("en", "mark number {n} as {sv}"),
             ("en", "dismiss item {n}", {"status": "ignored"}), ("ms", "kemas kini item {n} kepada {sv}"),
             ("ms", "abaikan item {n}", {"status": "ignored"})],
}
BRIEF = {
    "train": [("en", "brief me on {rt}"), ("en", "prepare me for my visit to {rt}"),
              ("en", "what should i discuss with {rt}"), ("en", "give me a visit brief for {rt}"),
              ("en", "summarise {rt} for me"), ("en", "visit brief {rt}"), ("en", "brief me before i see {rt}"),
              ("en", "what do i need to know about {rt}"), ("en", "brief me on this retailer"),
              ("en", "give me the visit brief"), ("ms", "beri taklimat tentang {rt}"),
              ("ms", "sediakan saya untuk lawatan ke {rt}"), ("ms", "ringkaskan {rt}"),
              ("ms", "apa yang perlu saya bincang dengan {rt}"), ("ms", "taklimat lawatan untuk {rt}"),
              ("ms", "beri taklimat tentang kedai ini")],
    "validation": [("en", "get me ready to visit {rt}"), ("en", "talk me through {rt}"),
                   ("ms", "bagi saya ringkasan {rt}"), ("en", "brief me on this shop")],
    "test": [("en", "i'm meeting {rt} later, what should i know"), ("en", "give me the background on {rt}"),
             ("ms", "ringkasan lawatan {rt}"), ("ms", "sebelum saya jumpa {rt}, apa perlu saya tahu"),
             ("en", "prepare me for this visit")],
}
WRITE_NEGATIVE = {
    "train": ["approve order {no}", "reject order {no}", "approve all submitted orders", "save this route as a draft",
              "prepare {sp}'s route for next week", "create a route for {sp}", "publish the route",
              "delete these orders", "cancel order {no}", "send these results to the supplier",
              "email this to my manager", "change {sp}'s role", "luluskan pesanan {no}", "tolak pesanan {no}",
              "padam semua pesanan", "simpan laluan sebagai draf", "sediakan laluan untuk {sp}",
              "luluskan semua pesanan"],
    "validation": ["approve the order for {rt}", "save the route as draft", "remove order {no}",
                   "set up a route for {sp} next week", "luluskan pesanan {rt}", "terbitkan laluan"],
    "test": ["go ahead and approve order {no}", "decline order {no}", "plan {sp}'s week and save it",
             "email me the orders", "batalkan pesanan {no}", "simpan draf laluan untuk {sp}"],
}

POLITE = {
    "train": ["can you", "could you", "please", "i want to", "tolong", "boleh", "saya nak", "i need to"],
    "validation": ["kindly", "would you", "boleh tak"],
    "test": ["hey can you", "i'd like to", "mohon", "tolong boleh"],
}

MS_NOUNS = {
    "dashboard": (["papan pemuka", "halaman utama"], ["skrin utama"]),
    "salesman_activity": (["penjejakan jurujual", "peta jurujual"], ["lokasi pasukan jualan"]),
    "visit_logs": (["log lawatan", "sejarah lawatan"], ["rekod lawatan"]),
    "route_planner": (["perancang laluan", "laluan mingguan"], ["pelan laluan"]),
    "notifications": (["notifikasi", "amaran"], ["pemberitahuan"]),
    "all_orders": (["pesanan", "semua pesanan", "senarai pesanan"], ["pesanan jualan"]),
    "purchase_order": (["pesanan pembelian", "pesanan belian"], ["pembelian pembekal"]),
    "special_requests": (["permintaan khas"], ["permintaan istimewa"]),
    "reports": (["laporan", "laporan bulanan"], ["analisis jualan"]),
    "prediction": (["ramalan permintaan", "ramalan"], ["unjuran permintaan"]),
    "product": (["produk", "katalog produk"], ["senarai produk"]),
    "retailer": (["peruncit", "senarai peruncit"], ["kedai pelanggan"]),
    "branches": (["cawangan"], ["senarai cawangan"]),
    "user_directory": (["senarai pengguna", "direktori kakitangan"], ["kakitangan"]),
    "users": (["tetapan peranan"], ["peranan pengguna"]),
    "audit_log": (["log audit"], ["jejak audit"]),
    "import_preview": (["pusat import"], ["muat naik fail"]),
    "backup": (["sandaran"], ["salinan sandaran"]),
    "team_orders": (["pesanan pasukan"], ["pesanan pasukan saya"]),
    "team_visits": (["lawatan pasukan"], ["lawatan pasukan saya"]),
    "team_activity": (["aktiviti pasukan"], ["peta pasukan saya"]),
    "team_forecast": (["ramalan pasukan"], ["unjuran pasukan"]),
}
MS_LEADS = {
    "train": ["buka {n}", "pergi ke {n}", "tunjukkan {n}", "paparkan {n}", "saya nak tengok {n}", "bawa saya ke {n}", "lihat {n}"],
    "validation": ["jom ke {n}", "buka halaman {n}"],
    "test": ["tolong buka {n}", "tunjuk {n}", "saya mahu ke {n}"],
}

NAV_EXTRA_INTENTS = {
    "all_orders": ["orders from customers waiting for me", "the customer orders i need to approve",
                   "sales orders to approve", "let me see the orders my reps sent in",
                   "which customer orders came in", "approve the orders from shops",
                   "retailer orders that need a decision", "orders placed by the shops"],
    "purchase_order": ["orders we place with suppliers", "what we ordered from the supplier",
                       "supplier purchase orders", "stock we are buying in",
                       "purchase orders issued to suppliers", "the po for the vendor"],
}
NAV_EXTRA_NOUNS = {"all_orders": ["incoming orders", "order queue", "retailer orders"]}

IMPORT_FRAMES = {
    "train": ["import a csv file", "upload a csv", "i want to upload a spreadsheet", "load a csv", "bring in a csv",
              "import products from csv", "muat naik fail csv", "import data dari csv"],
    "validation": ["upload an excel sheet", "import my spreadsheet", "muat naik excel"],
    "test": ["i need to import a csv", "put a csv into the system", "import fail csv", "upload csv file please"],
}
CONNECT = {
    "train": ["{a} and then {b}", "{a} then {b}", "{a} and also {b}", "{a} followed by {b}", "first {a} then {b}"],
    "validation": ["{a} and {b} together", "{a} after that {b}"],
    "test": ["{a}, then {b}", "{a} plus {b}", "{a} and next {b}"],
}

ACTION_FRAMES = {
    "search_orders": SEARCH, "daily_briefing": BRIEFING, "export_results": EXPORT,
    "explain_item": EXPLAIN, "set_item_status": SET_STATUS, "brief_retailer": BRIEF,
}
MIX = [("nav", 0.28), ("nav_ms", 0.05), ("search_orders", 0.17), ("daily_briefing", 0.05), ("export_results", 0.05),
       ("explain_item", 0.07), ("set_item_status", 0.07), ("brief_retailer", 0.07),
       ("write_negative", 0.04), ("compound_action", 0.04), ("import_contrast", 0.03), ("gated", 0.08)]
_ORIGINAL_NAV = (copy.deepcopy(md.INTENTS), copy.deepcopy(md.NOUNS))
_PLACEHOLDER = re.compile(r"\{(sp|rt|pd|st|sv|ord|n|no)\}")


def norm(text: str) -> str:
    return " ".join(text.lower().split())


def install_navigation_source() -> None:
    intents, nouns = _ORIGINAL_NAV
    md.INTENTS = {k: [s for s in v if s not in NAV_INTENT_BLOCKLIST] + NAV_EXTRA_INTENTS.get(k, [])
                  for k, v in intents.items()}
    md.NOUNS = {k: [s for s in v if s not in NAV_NOUN_BLOCKLIST] + NAV_EXTRA_NOUNS.get(k, [])
                for k, v in nouns.items()}


def _typo_chunk(chunk: str, r: random.Random, p: float) -> str:
    if r.random() >= p:
        return chunk
    tokens = re.split(r"(\s+)", chunk)
    words = [i for i, t in enumerate(tokens) if t.strip() and len(t) >= 5]
    if not words:
        return chunk
    i = r.choice(words)
    tokens[i] = md.typo(tokens[i], r)
    return "".join(tokens)


def _surface(name: str, r: random.Random) -> str:
    return name.lower() if r.random() < 0.35 else name


def _phrase(table: dict, lang: str, key: str, group: str, r: random.Random) -> str:
    language = r.choice(["en", "ms"]) if lang == "mix" else lang
    return r.choice(table[language][key][group])


def _group(split: str) -> str:
    return "train" if split == "train" else "held"


def _fill(frame: str, lang: str, split: str, r: random.Random, args: dict[str, Any]) -> str:
    group = _group(split)
    position = r.randint(1, 10)
    out: list[str] = []
    last = 0
    for match in _PLACEHOLDER.finditer(frame):
        out.append(_typo_chunk(frame[last:match.start()], r, 0.06))
        slot = match.group(1)
        if slot == "sp":
            value = _surface(r.choice(SALESPEOPLE[split]), r)
            args["salesperson"] = value
            out.append(value)
        elif slot == "rt":
            value = _surface(r.choice(RETAILERS[split]), r)
            args["retailer"] = value
            out.append(value)
        elif slot == "pd":
            key = r.choice(sorted(PERIOD["en"]))
            args["period"] = key
            out.append(_phrase(PERIOD, lang, key, group, r))
        elif slot == "st":
            key = r.choice(sorted(ORDER_STATUS["en"]))
            args["status"] = key
            out.append(_phrase(ORDER_STATUS, lang, key, group, r))
        elif slot == "sv":
            key = r.choice(sorted(ITEM_STATUS["en"]))
            args["status"] = key
            out.append(_phrase(ITEM_STATUS, lang, key, group, r))
        elif slot == "no":
            out.append(str(r.randint(1000, 9999)))
        elif slot == "ord":
            args["position"] = position
            language = r.choice(["en", "ms"]) if lang == "mix" else lang
            out.append(ORDINAL[language][position - 1])
        else:
            args["position"] = position
            out.append(str(position))
        last = match.end()
    out.append(_typo_chunk(frame[last:], r, 0.06))
    return "".join(out)


def _decorate(text: str, r: random.Random, split: str = "train") -> str:
    if r.random() < 0.15:
        text = f"{r.choice(POLITE[split])} {text}"
    elif r.random() < 0.08:
        text = f"{r.choice(md.FILLERS)} {text}"
    x = r.random()
    if x < 0.05:
        text += "."
    elif x < 0.07:
        text += "?"
    return " ".join(text.split())


def pick_actions(r: random.Random, must: str | None = None, exclude: str | None = None) -> list[str]:
    names = [a for a in schema.ACTION_ORDER if a != exclude]
    if r.random() < 0.7:
        chosen = set(names)
    else:
        chosen = set(r.sample(names, r.randint(0 if must is None else 1, max(1, len(names) - 1))))
        if must:
            chosen.add(must)
    return [a for a in schema.ACTION_ORDER if a in chosen]


def _row(text: str, pages: list[str], actions: list[str], target: dict, kind: str, family: str, lang: str,
         r: random.Random) -> dict:
    return {
        "text": " ".join(text.split()),
        "pages": pages,
        "aliasSeed": 0 if r.random() < 0.6 else r.randint(1, 9999),
        "actions": actions,
        "target": target,
        "kind": kind,
        "family": family,
        "lang": lang,
    }


def gen_action_row(action: str, split: str, r: random.Random, gated: bool = False) -> dict:
    frame_entry = r.choice(ACTION_FRAMES[action][split])
    lang, frame = frame_entry[0], frame_entry[1]
    args: dict[str, Any] = {}
    text = _fill(frame, lang, split, r, args)
    args.update(frame_entry[2] if len(frame_entry) > 2 else {})
    pages = md.pick_pages(r, None, True)
    if gated:
        actions = pick_actions(r, exclude=action)
        target = {"name": schema.NO_MATCH, "args": {}}
        kind = "gated"
    else:
        actions = pick_actions(r, must=action)
        target = {"name": action, "args": args}
        kind = action
    return _row(_decorate(text, r, split), pages, actions, target, kind, f"{action}:{frame}", lang, r)


def gen_write_negative(split: str, r: random.Random) -> dict:
    frame = r.choice(WRITE_NEGATIVE[split])
    text = _fill(frame, "en", split, r, {})
    pages = md.pick_pages(r, None, True)
    lang = "ms" if re.search(r"\b(luluskan|tolak|padam|simpan|sediakan|terbitkan|batalkan)\b", frame) else "en"
    return _row(_decorate(text, r, split), pages, pick_actions(r), {"name": schema.NO_MATCH, "args": {}},
                "write_negative", f"write:{frame}", lang, r)


def gen_nav_ms_row(split: str, r: random.Random) -> dict:
    key = r.choice(sorted(MS_NOUNS))
    base, held = MS_NOUNS[key]
    noun = r.choice(base if split == "train" else base + held)
    lead = r.choice(MS_LEADS[split])
    absent = r.random() < 0.15
    pages = md.pick_pages(r, key, not absent)
    target = (
        {"name": schema.NO_MATCH, "args": {}} if absent else {"name": schema.NAVIGATE, "args": {"page": key}}
    )
    text = _typo_chunk(lead.split("{n}")[0], r, 0.05) + noun + lead.split("{n}")[1]
    return _row(_decorate(text, r, split), pages, pick_actions(r), target, "nav_ms", f"navms:{lead}", "ms", r)


def gen_compound_action(split: str, r: random.Random) -> dict:
    parts = []
    for action in r.sample(sorted(ACTION_FRAMES), 2):
        entry = r.choice(ACTION_FRAMES[action][split])
        parts.append(_fill(entry[1], entry[0], split, r, {}))
    connector = r.choice(CONNECT[split])
    text = connector.format(a=parts[0], b=parts[1])
    return _row(_decorate(text, r, split), md.pick_pages(r, None, True), pick_actions(r),
                {"name": schema.NO_MATCH, "args": {}}, "compound_action", f"compound:{connector}", "en", r)


def gen_import_contrast(split: str, r: random.Random) -> dict:
    phrase = r.choice(IMPORT_FRAMES[split])
    present = r.random() < 0.4
    pages = md.pick_pages(r, "import_preview", present)
    target = (
        {"name": schema.NAVIGATE, "args": {"page": "import_preview"}} if present
        else {"name": schema.NO_MATCH, "args": {}}
    )
    actions = pick_actions(r, must="export_results")
    return _row(_decorate(phrase, r, split), pages, actions, target, "import_contrast", f"import:{phrase}",
                "ms" if phrase.startswith(("muat", "import data", "import fail")) else "en", r)


def gen_nav_row(split: str, r: random.Random) -> dict:
    kinds = [k for k, _ in md.MIX]
    old = md.gen_row(r.choices(kinds, [w for _, w in md.MIX])[0], split, r)
    target = (
        {"name": schema.NO_MATCH, "args": {}}
        if old["target"] == md.NO_MATCH
        else {"name": schema.NAVIGATE, "args": {"page": old["target"]}}
    )
    return {
        "text": old["text"], "pages": old["pages"], "aliasSeed": old["aliasSeed"],
        "actions": pick_actions(r), "target": target,
        "kind": "nav:" + old["kind"], "family": old["family"], "lang": "en",
    }


def gen_row(kind: str, split: str, r: random.Random) -> dict:
    if kind == "nav":
        return gen_nav_row(split, r)
    if kind == "write_negative":
        return gen_write_negative(split, r)
    if kind == "nav_ms":
        return gen_nav_ms_row(split, r)
    if kind == "compound_action":
        return gen_compound_action(split, r)
    if kind == "import_contrast":
        return gen_import_contrast(split, r)
    if kind == "gated":
        return gen_action_row(r.choice(sorted(ACTION_FRAMES)), split, r, gated=True)
    return gen_action_row(kind, split, r)


def to_request(row: dict) -> dict:
    return {"text": row["text"], "pages": md.request_pages(row), "actions": row["actions"]}


def build(split: str, n: int, seed: int, banned: set[str]) -> list[dict]:
    r = random.Random(f"{seed}:{split}")
    kinds = [k for k, _ in MIX]
    weights = [w for _, w in MIX]
    out: list[dict] = []
    seen: set[tuple[str, tuple[str, ...], tuple[str, ...]]] = set()
    guard = 0
    while len(out) < n and guard < n * 80:
        guard += 1
        row = gen_row(r.choices(kinds, weights)[0], split, r)
        sig = (norm(row["text"]), tuple(row["pages"]), tuple(row["actions"]))
        if norm(row["text"]) in banned or sig in seen:
            continue
        seen.add(sig)
        out.append(row)
    return out


def verbatim_errors(rows: list[dict]) -> list[str]:
    bad = []
    for row in rows:
        for key in ("salesperson", "retailer"):
            value = row["target"]["args"].get(key)
            if value is not None and value not in row["text"]:
                bad.append(f"{key}={value!r} not in {row['text']!r}")
    return bad


def conflicts(*splits: list[dict]) -> list[str]:
    seen: dict[str, str] = {}
    bad = []
    for rows in splits:
        for row in rows:
            if row["target"]["name"] == schema.NO_MATCH:
                continue
            key = norm(row["text"])
            call = schema.serialize_call(row["target"]).lower()
            if seen.setdefault(key, call) != call:
                bad.append(f"{row['text']!r}: {seen[key]} vs {call}")
    return bad


def frozen_texts() -> set[str]:
    texts: set[str] = set()
    for name in FROZEN_FILES:
        path = LLM_DIR / name
        if path.exists():
            texts |= {norm(c["text"]) for c in json.loads(path.read_text(encoding="utf-8"))["cases"]}
    return texts


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", type=Path, default=DATA)
    args = ap.parse_args(argv)
    install_navigation_source()
    frozen = frozen_texts()
    test = build("test", SIZES["test"], SEED, frozen)
    test_texts = {norm(x["text"]) for x in test}
    val = build("validation", SIZES["validation"], SEED, frozen | test_texts)
    val_texts = {norm(x["text"]) for x in val}
    train = build("train", SIZES["train"], SEED, frozen | test_texts | val_texts)
    train_texts = {norm(x["text"]) for x in train}
    for name, held in (("frozen evaluation files", frozen), ("validation", val_texts), ("test", test_texts)):
        overlap = train_texts & held
        if overlap:
            sys.exit(f"train overlaps {name}: {sorted(overlap)[:5]}")
    if test_texts & val_texts or test_texts & frozen or val_texts & frozen:
        sys.exit("held-out sets overlap")
    errors = verbatim_errors(train + val + test) + conflicts(train, val, test)
    if errors:
        sys.exit("dataset invariants failed:\n" + "\n".join(errors[:10]))
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, rows in (("train", train), ("validation", val), ("test", test)):
        path = args.out_dir / f"{name}.jsonl"
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows))
        kinds: dict[str, int] = {}
        for x in rows:
            group = x["kind"].split(":")[0]
            kinds[group] = kinds.get(group, 0) + 1
        langs: dict[str, int] = {}
        for x in rows:
            langs[x["lang"]] = langs.get(x["lang"], 0) + 1
        digest = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
        print(f"{name}: {len(rows)} rows, no_match={sum(x['target']['name'] == schema.NO_MATCH for x in rows)}, "
              f"sha256[:16]={digest}, kinds={kinds}, lang={langs}")
    print("OK: no train text equals a validation, test or frozen-evaluation text; names copied verbatim")


if __name__ == "__main__":
    main()

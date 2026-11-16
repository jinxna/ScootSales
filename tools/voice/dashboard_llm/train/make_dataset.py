from __future__ import annotations

import hashlib
import json
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
EVAL = HERE.parent / "eval_phrases.json"
SEED = 20260930
SIZES = {"train": 3600, "validation": 500, "test": 700}
NO_MATCH = "no_match"

CATALOGUE: dict[str, tuple[str, str, list[str], list[str]]] = {
    "dashboard": ("Dashboard", "Dashboard", ["home", "kpi", "summary", "action centre"], ["overview", "main dashboard", "go home"]),
    "salesman_activity": ("Salesman Tracking", "Salesman Tracking", ["gps", "map", "location", "live", "performance"], ["sales activity", "salesman tracking"]),
    "visit_logs": ("Visit Logs", "Visit Logs", ["visits", "history", "arrival", "follow-up"], ["visit history"]),
    "route_planner": ("Route Planner", "Weekly Route Planner", ["route", "optimisation", "estimate", "plan", "visit"], ["routes", "weekly routes", "route planning"]),
    "notifications": ("Notifications", "Notifications", ["alerts", "feed"], ["notification feed"]),
    "all_orders": ("All Orders", "All Orders", ["order approval", "sales order", "approve", "reject"], ["orders", "submitted orders"]),
    "purchase_order": ("Purchase Orders", "Purchase Orders", ["po", "procurement", "supply"], ["purchase orders"]),
    "special_requests": ("Special Requests", "Special Requests", ["exceptions", "approval"], ["request approvals"]),
    "reports": ("Reports", "Reports", ["analytics", "monthly trend", "product report", "monthly summary"], ["monthly analytics"]),
    "prediction": ("Prediction", "Demand Forecast", ["forecast", "sarimax", "demand", "restock recommendations"], ["demand forecast", "predictions"]),
    "trust_impact": ("Trust & Impact", "Trust & Impact Lab", ["accuracy", "impact", "evidence", "abstention", "trust"], ["trust impact", "abstentions"]),
    "department": ("Departments", "Departments", [], []),
    "category": ("Categories", "Categories", [], []),
    "product": ("Products", "Products", [], ["product catalogue", "catalogue"]),
    "retailer_scoresheets": ("Score Sheets", "Score Sheets", [], []),
    "users": ("Role Assignment", "Role Assignment", ["user management", "roles", "accounts"], []),
    "permissions": ("Role Permissions", "Role Permissions", ["permission", "matrix", "access", "authorization"], []),
    "user_directory": ("Users", "Users", [], ["staff directory"]),
    "branches": ("Branches", "Branch Management", [], ["branch management"]),
    "retailer": ("Retailers", "Retailers", [], ["outlets"]),
    "coordinate_review": ("Coordinate Review", "Coordinate Review", ["gps", "latitude", "longitude", "geocode", "map"], []),
    "import_preview": ("Import Centre", "Import Preview Centre", ["csv", "excel", "products", "retailers", "forecast"], []),
    "department_pic": ("Retailer Department PIC", "Retailer Department PIC", [], []),
    "terms_conditions": ("Terms & Conditions", "Terms & Conditions", [], []),
    "privacy_policy": ("Privacy Policy", "Privacy Policy", [], []),
    "backup": ("Backup", "Backup & Restore", [], []),
    "system_governance": ("System Governance", "System Governance", [], []),
    "system_health": ("System Health", "System Health", ["diagnostics", "data quality", "health", "checks"], []),
    "audit_log": ("Audit Log", "Audit Log", ["history", "changes", "actor", "governance"], []),
    "team_orders": ("Team Orders", "Team Orders", [], []),
    "team_visits": ("Team Visits", "Team Visits", [], []),
    "team_activity": ("Team Activity", "Team Activity", [], ["team map"]),
    "team_forecast": ("Team Forecast", "Team Forecast", [], []),
    "team_action_center": ("Action Centre", "Team Action Centre", [], ["team actions"]),
    "team_ai_summary": ("Weekly AI Summary", "Weekly AI Summary", [], ["team summary"]),
}
ORDER = list(CATALOGUE)
ROLES = {
    "branch_manager": ["dashboard", "salesman_activity", "visit_logs", "route_planner", "notifications", "all_orders", "purchase_order", "special_requests", "reports", "prediction"],
    "supervisor": ["dashboard", "notifications", "team_orders", "team_visits", "team_activity", "team_forecast", "team_action_center", "team_ai_summary"],
    "manager": ["dashboard", "salesman_activity", "visit_logs", "route_planner", "notifications", "all_orders", "special_requests", "reports", "prediction", "product", "retailer", "retailer_scoresheets", "department", "category"],
    "staff_admin": ["dashboard", "notifications", "user_directory", "users", "permissions", "branches", "audit_log", "privacy_policy", "terms_conditions", "department_pic"],
}
SIBLINGS = [
    ["all_orders", "purchase_order", "special_requests", "team_orders"],
    ["users", "permissions", "user_directory", "department_pic"],
    ["retailer", "retailer_scoresheets", "department_pic", "coordinate_review", "branches"],
    ["salesman_activity", "visit_logs", "route_planner", "team_activity", "team_visits"],
    ["prediction", "trust_impact", "team_forecast", "reports"],
    ["dashboard", "reports", "notifications", "team_action_center", "team_ai_summary"],
    ["system_health", "system_governance", "audit_log", "backup"],
    ["product", "category", "department", "import_preview"],
    ["privacy_policy", "terms_conditions"],
]

NOUNS: dict[str, list[str]] = {
    "dashboard": ["dashboard", "home page", "main overview", "kpi summary", "home screen", "landing page", "front page", "headline numbers"],
    "salesman_activity": ["salesman tracking", "sales rep map", "live map of the reps", "field team locations", "sales activity map", "rep gps tracking", "where the reps are", "live rep positions"],
    "visit_logs": ["visit logs", "visit history", "store visit records", "list of visits", "arrival records", "shop visit log", "follow-up visits", "visit records"],
    "route_planner": ["route planner", "weekly routes", "route planning", "the route plan for the week", "route optimiser", "planned routes", "weekly route schedule", "route scheduler"],
    "notifications": ["notifications", "alerts", "notification feed", "alert feed", "new messages from the system", "unread alerts", "system alerts", "alert inbox"],
    "all_orders": ["all orders", "orders", "submitted orders", "sales orders", "order approval queue", "customer orders", "order list", "pending orders"],
    "purchase_order": ["purchase orders", "procurement", "supply orders", "purchase order list", "po list", "supplier orders", "procurement orders", "purchasing"],
    "special_requests": ["special requests", "exceptions", "request approvals", "exception requests", "special order requests", "pending exceptions", "requests waiting approval", "retailer exception requests"],
    "reports": ["reports", "analytics", "monthly analytics", "monthly summary report", "sales reports", "reporting hub", "monthly reports", "performance reports"],
    "prediction": ["prediction", "demand forecast", "forecast page", "sales predictions", "forecasting", "restock recommendations", "predicted demand", "demand outlook"],
    "trust_impact": ["trust and impact", "forecast accuracy", "trust impact lab", "model evidence", "abstentions", "how reliable the forecasts are", "prediction trustworthiness", "forecast evidence"],
    "department": ["departments", "department list", "sales departments", "department settings", "department management", "manage departments"],
    "category": ["categories", "product categories", "category tree", "category hierarchy", "category management", "manage categories"],
    "product": ["products", "product catalogue", "catalogue", "product list", "product management", "sku list", "item catalogue", "product master"],
    "retailer_scoresheets": ["score sheets", "retailer score sheets", "scoresheets", "product score sheet for a retailer", "retailer scorecards", "score sheet settings"],
    "users": ["role assignment", "user management", "roles", "accounts", "assign roles", "user roles", "account roles", "role manager"],
    "permissions": ["role permissions", "permissions", "permission matrix", "access rights", "access control matrix", "authorization settings", "what each role can access", "role access settings"],
    "user_directory": ["users", "staff directory", "staff list", "user directory", "team members", "employee directory", "list of staff", "people directory"],
    "branches": ["branches", "branch management", "branch list", "branch locations", "manage branches", "our branches", "branch offices", "branch settings"],
    "retailer": ["retailers", "outlets", "retailer list", "shops", "retailer management", "outlet list", "customer stores", "retail outlets"],
    "coordinate_review": ["coordinate review", "gps coordinates", "outlet coordinates", "location review", "geocode review", "latitude and longitude checks", "map coordinates of outlets", "coordinate verification"],
    "import_preview": ["import centre", "import preview", "csv import", "excel import", "data import", "bulk upload", "import tool", "file upload"],
    "department_pic": ["department pic", "retailer department pic", "person in charge of departments", "department contacts", "pic assignment", "department person in charge"],
    "terms_conditions": ["terms and conditions", "terms of use", "app terms", "t and c", "user terms", "terms page"],
    "privacy_policy": ["privacy policy", "privacy notice", "data privacy statement", "privacy page", "privacy terms", "privacy info"],
    "backup": ["backup", "backup and restore", "data backup", "system backup", "backups", "export and restore"],
    "system_governance": ["system governance", "governance settings", "gps policy settings", "governance controls", "developer controls", "purge export controls"],
    "system_health": ["system health", "diagnostics", "data quality checks", "health checks", "system status", "system diagnostics", "platform health", "health monitor"],
    "audit_log": ["audit log", "audit trail", "change log", "activity log of changes", "governance history", "who changed what", "audit history", "record of changes"],
    "team_orders": ["team orders", "my team's orders", "orders from my team", "team order list", "team sales orders", "orders of my reps"],
    "team_visits": ["team visits", "my team's visits", "visits by my team", "team visit list", "team visit history", "visits by my reps"],
    "team_activity": ["team activity", "team map", "my team on the map", "team locations", "team tracking", "where my team is"],
    "team_forecast": ["team forecast", "my team's forecast", "forecast for my team", "team demand forecast", "team predictions", "team outlook"],
    "team_action_center": ["action centre", "team actions", "team action centre", "action items for my team", "things my team needs to do", "team to-do list"],
    "team_ai_summary": ["weekly ai summary", "team summary", "weekly summary of my team", "ai weekly digest", "team weekly ai summary", "this week's ai summary"],
}

INTENTS: dict[str, list[str]] = {
    "dashboard": ["what needs my attention today", "take me back to the start", "i want the big picture", "show me the headline numbers", "give me the daily overview", "back to the main screen", "what is going on today", "let me see the summary of everything", "go back to the beginning", "how is the business doing overall", "show the main kpis", "i want the home view"],
    "salesman_activity": ["how are my reps doing today", "where is everyone in the field right now", "are my salespeople out on the road", "i want to follow my field team live", "show me who is working right now", "which reps are active at the moment", "let me watch the sales team move", "see the location of the salesmen", "who is out visiting shops", "track my sales team", "how is the field team performing", "show gps positions of the salesmen"],
    "visit_logs": ["which shops did the reps go to", "did anyone visit the shop yesterday", "show me the history of shop visits", "when did the rep arrive at the store", "i want to check what visits happened last week", "list the store visits", "which outlets got visited", "look up past visits to a retailer", "who has been to which outlet", "show me the follow ups from visits", "how often are the stores being visited", "review the visits our people made"],
    "route_planner": ["plan where the reps go next week", "i want to schedule the sales trips", "set up the weekly visit plan", "arrange the journeys for my salesmen", "build the route for the week", "draft the visiting schedule", "who goes where on monday", "let me assign stores to reps for the week", "optimise the trips of the reps", "prepare the plan for the coming week", "publish the weekly plan of visits", "change the visiting route of a rep"],
    "notifications": ["did anything come up", "any new alerts for me", "what has been flagged", "i want to see my alerts", "is there anything new to read", "check what the system has told me", "anything urgent popped up", "show me what i missed", "read my unread alerts", "what warnings are there", "see the latest system messages", "review recent alerts"],
    "all_orders": ["which orders need my approval", "let me see the orders that came in", "i have orders waiting to be approved", "check the latest customer orders", "what did the shops order", "i want to look at the order list", "review the submitted orders", "how many orders came in today", "what orders are pending", "see the orders the reps submitted", "find an order from a retailer", "i need to approve or reject some orders"],
    "purchase_order": ["what are we buying from suppliers", "i need to order stock from the supplier", "let me raise a purchase order", "show me what we have ordered from vendors", "i want to restock from the supplier", "check the procurement list", "create an order to the supplier", "review what we ordered upstream", "how much are we buying from the vendor", "list the buying orders sent to suppliers", "see supply orders", "what did we procure this month"],
    "special_requests": ["a shop asked for something out of the ordinary", "any exceptions waiting for me", "someone requested an exception", "look at the unusual requests from retailers", "which special requests need a decision", "the exceptions need my approval", "check requests that fall outside policy", "requests that need my sign off", "are there any one-off requests", "see what the reps asked for as an exception", "review the off-policy requests", "show what is waiting for approval besides orders"],
    "reports": ["i need the monthly numbers", "how did we do this month", "show me the sales analytics", "let me look at the performance figures", "i want charts of the monthly sales", "generate an analysis of last month", "top products and top retailers", "i want to see the month in review", "compare this month to last month", "open the analysis section", "give me the sales statistics", "where can i find the monthly trend"],
    "prediction": ["how many units will we sell next week", "what will demand look like", "what should we restock", "i want to know the expected sales", "will this product sell more next month", "look at the sales outlook", "what is the projected demand", "which items will run short", "forecast the sales for the coming weeks", "predict what the shops will order", "what are we expecting to sell", "check the festive demand forecast"],
    "trust_impact": ["can i trust the forecast", "how good are the predictions", "how often is the model right", "is the forecast reliable", "show evidence the forecasts work", "when does the model refuse to predict", "how accurate has the model been", "i want proof the forecast helps", "check the forecasting quality", "did the forecasts hold up", "what is the model's track record", "does the model know when it is unsure"],
    "department": ["i want to edit the sales departments", "manage the departments we sell in", "add a new department", "change the department names", "which departments exist", "maintain the department list"],
    "category": ["i want to edit product categories", "organise the category hierarchy", "add a new product category", "which categories do we have", "restructure the product groups", "maintain the category tree"],
    "product": ["i want to edit an item", "let me look up a product", "what do we sell", "add a new sku", "check the price of an item", "open the list of things we sell", "update a product record", "find a product by name", "how many products are there", "review the item master"],
    "retailer_scoresheets": ["which products show for each retailer", "control what products a shop can see", "edit the product list for one shop", "configure the scoring sheet of a retailer", "set the products on a retailer sheet", "manage what each store scores"],
    "users": ["change someone's role", "i need to assign roles to people", "promote a user to manager", "make this person a supervisor", "give a staff member a new role", "who has which role", "set the role of a new hire", "manage user accounts and their roles", "switch a user from salesman to admin", "grant a role to an employee"],
    "permissions": ["what is each role allowed to do", "who can access which page", "change what a role can see", "edit access rules for roles", "check which permissions managers have", "set what supervisors are allowed to open", "adjust the access matrix", "control what each role is allowed", "which role can approve orders", "review role privileges"],
    "user_directory": ["who works here", "find a staff member", "look up a colleague's contact", "who are the people in the system", "list everyone with an account", "see the staff and their contact details", "which users exist", "check who is on the team", "find the phone number of an employee", "browse the employee records"],
    "branches": ["where are our branch offices", "add a new branch", "edit the branch address", "how many branches are there", "manage the physical locations of the company", "list of our branch sites", "update a branch location", "which branches do we have"],
    "retailer": ["which shops do we sell to", "add a new retailer", "find a shop by name", "how many outlets do we have", "edit a store's details", "look up a customer outlet", "browse the retailer records", "show the stores we serve", "update the address of a shop", "our list of customers"],
    "coordinate_review": ["are the shop locations correct on the map", "verify where the outlets are", "check the outlet pins that need review", "fix the location of a shop", "which outlets have doubtful locations", "confirm the gps of stores", "review imported locations", "i want to validate outlet positions", "look at unverified store coordinates", "approve or reject candidate locations"],
    "import_preview": ["i want to upload a spreadsheet", "bring in data from a file", "load some products from excel", "upload the retailer list", "import my csv file", "preview a file before importing", "add many rows from a file at once", "put in the sales data from a sheet"],
    "department_pic": ["who is in charge of a department at a shop", "assign a person to a department at a retailer", "set the contact for a department at a store", "which pic looks after which department", "change the person responsible for a retailer's department", "edit department contacts per shop"],
    "terms_conditions": ["what are the rules of using the app", "read the legal terms", "i want the terms of the service", "where are the conditions of use", "show the agreement users accept", "look at the legal conditions"],
    "privacy_policy": ["how is personal data handled", "what is the data privacy statement", "read how you use our information", "where is the privacy notice", "show me how data is protected", "i want the policy about personal data"],
    "backup": ["save a copy of all the data", "i want to restore from a saved copy", "export everything as a safety copy", "make an archive of the system", "recover data from an earlier backup", "download a full data export"],
    "system_governance": ["change the gps policy", "developer only controls", "manage system level access rules", "export data before purging it", "open the developer governance settings", "configure the system controls for developers"],
    "system_health": ["is everything working properly", "run a check on the system", "are there data quality problems", "is the platform up", "any problems with the data", "diagnose the system", "how healthy is the data", "look for broken records", "check that all services are ok", "are there any errors in the system"],
    "audit_log": ["who changed this record", "what happened to the data recently", "see who edited what", "i need a trail of changes", "who did what and when", "show me the history of admin actions", "look into who modified the settings", "check the record of user actions", "trace a change back to a person", "review admin activity history"],
    "team_orders": ["which orders did my reps submit", "orders from the people i supervise", "check what my team sold", "let me see my team's order list", "what did my salesmen order today", "review orders by my team"],
    "team_visits": ["which shops has my team visited", "did my reps do their visits", "the visits my team made", "check my team's store calls", "how many visits did my people do", "review my team's shop visits"],
    "team_activity": ["where is my team right now", "how is my team doing today", "follow my team on the map", "are my reps out on the road", "watch my team move", "who in my team is active"],
    "team_forecast": ["what will my team sell next week", "expected demand for my area", "predicted sales for my reps", "what should my team push", "the outlook for my team's territory", "will my team hit the sales target"],
    "team_action_center": ["what does my team need to do", "the tasks waiting for my team", "which actions are open for my reps", "what should i follow up with my team", "what needs fixing in my area", "list the pending tasks for my people"],
    "team_ai_summary": ["give me a digest of my team's week", "summarise how my team did this week", "the ai's recap of my team", "a written summary of the week for my reps", "what did the ai say about my team's week", "recap the week for my team"],
}

LEADS_TRAIN = [
    "{n}", "open {n}", "show me {n}", "go to {n}", "take me to {n}", "i want to see {n}", "pull up {n}", "let me see {n}",
    "can you open {n}", "navigate to {n}", "switch to {n}", "i need {n}", "i would like to view {n}", "check {n}",
    "{n} please", "please open {n}", "i wanna look at {n}", "bring up {n}", "display {n}", "buka {n}", "pergi ke {n}",
    "could you show me {n}", "let's go to {n}", "get me to {n}", "hey open {n}", "where can i find {n}",
]
LEADS_VAL = ["jump to {n}", "i'd like to check {n}", "can i see {n}", "{n} now", "head to {n}"]
LEADS_TEST = ["load {n}", "look at {n}", "tunjuk {n}", "would you mind showing me {n}", "i'm trying to get to {n}", "show {n}", "view {n}", "{n} page", "take me over to {n}"]
FILLERS = ["um", "uh", "hey", "ok", "so", "right", "yeah", "hmm", "please", "quickly", "okay so"]

CHAT = ["hello", "hi there", "good morning", "how are you", "thank you", "thanks a lot", "who are you", "what can you do", "tell me a joke", "what is the weather today", "what time is it", "sing me a song", "banana", "um", "nothing", "never mind", "stop", "cancel that", "how do i cook rice", "who won the football match", "what is the capital of france", "play some music", "call my manager", "turn off the lights", "set an alarm for seven", "remind me to buy milk", "i am hungry", "it is so hot today", "tell me something interesting", "what should i eat for lunch", "translate good morning into malay", "how far is the moon", "what is two plus two", "are you a robot", "good night", "see you tomorrow", "how is my day going", "what is the meaning of life", "open the window", "what is your name", "this is boring", "help", "can you hear me", "testing one two three", "is it raining outside", "book me a flight", "text my wife", "how tall is mount kinabalu", "read me the news", "i love this song"]
OUT_OF_DOMAIN = ["the weather forecast for tomorrow", "the football scores", "a cooking recipe", "the latest news", "my horoscope", "traffic to the airport", "the exchange rate", "a funny video", "stock market prices", "my calendar", "my email inbox", "the hotel bookings", "a map of kuching", "the cinema times", "some music"]
UNAVAILABLE = ["inventory levels", "warehouse stock", "payroll", "employee salaries", "invoices", "customer complaints", "supplier contracts", "expense claims", "marketing campaigns", "loyalty points", "the bank balance", "attendance records", "leave requests", "delivery trucks", "the accounting ledger", "tax filings", "the crm contacts", "shift rosters", "the returns desk", "credit limits"]
ACTIONS_TRAIN = ["delete", "approve", "reject", "publish", "remove", "cancel", "restore", "reset", "deactivate", "clear", "wipe"]
ACTIONS_VAL = ["erase", "revoke"]
ACTIONS_TEST = ["purge", "drop", "disable", "confirm all", "submit"]
ACTION_OBJECTS = ["all the orders", "this user", "the route", "the weekly route plan", "everyone's password", "the backup", "that retailer", "the special request", "all pending requests", "order 1234", "purchase order 88", "the forecast", "the visit logs", "the product", "this branch", "the audit log", "notifications", "the role permissions", "the retailer coordinates", "the department"]
SPECIFIC_ACTIONS = ["send an email to the supplier", "email the retailer", "print the report", "call the salesman", "message my team", "share the dashboard with the ceo", "change my password", "log me out"]
CONNECT_TRAIN = ["{a} and then {b}", "{a} then {b}", "open {a} and {b}", "go to {a} and after that {b}", "show {a} and also open {b}", "{a} followed by {b}"]
CONNECT_VAL = ["first {a} then {b}", "{a} and {b} together"]
CONNECT_TEST = ["show {a} and check {b}", "take me to {a} and then to {b}", "{a}, then {b}", "{a} plus {b}"]


def alias_pool(key: str) -> list[str]:
    label, title, kws, extras = CATALOGUE[key]
    out: list[str] = []
    for a in [label, title, key.replace("_", " "), *kws, *extras]:
        if a not in out:
            out.append(a)
    return out


def aliases_for(key: str, seed: int) -> list[str]:
    pool = alias_pool(key)
    if seed == 0:
        return pool[:8]
    r = random.Random(f"{key}:{seed}")
    k = r.randint(1, min(8, len(pool)))
    return r.sample(pool, k)


def request_pages(row: dict) -> list[dict]:
    return [
        {"key": k, "label": CATALOGUE[k][0], "aliases": aliases_for(k, row["aliasSeed"])}
        for k in row["pages"]
    ]


def norm(text: str) -> str:
    return " ".join(text.lower().split())


def split_nouns(key: str, split: str) -> list[str]:
    nouns = NOUNS[key]
    cut = max(1, len(nouns) - max(1, len(nouns) // 4))
    return nouns[:cut] if split == "train" else nouns


def split_intents(key: str, split: str) -> list[str]:
    want = {"train": lambda i: i % 6 not in (2, 5), "validation": lambda i: i % 6 == 2, "test": lambda i: i % 6 == 5}[split]
    picked = [s for i, s in enumerate(INTENTS[key]) if want(i)]
    return picked or INTENTS[key][:1]


def typo(word: str, r: random.Random) -> str:
    if len(word) < 5:
        return word
    i = r.randrange(1, len(word) - 2)
    op = r.choice(["swap", "drop", "dup", "sub"])
    if op == "swap":
        return word[:i] + word[i + 1] + word[i] + word[i + 2:]
    if op == "drop":
        return word[:i] + word[i + 1:]
    if op == "dup":
        return word[:i] + word[i] + word[i:]
    return word[:i] + r.choice("aeiounrst") + word[i + 1:]


def maybe_typo(phrase: str, r: random.Random, p: float = 0.12) -> str:
    if r.random() >= p:
        return phrase
    words = phrase.split()
    idx = r.randrange(len(words))
    words[idx] = typo(words[idx], r)
    return " ".join(words)


def style(text: str, r: random.Random) -> str:
    if r.random() < 0.10:
        text = f"{r.choice(FILLERS)} {text}"
    x = r.random()
    if x < 0.08:
        text = text.capitalize()
    elif x < 0.12:
        text = text.upper()
    y = r.random()
    if y < 0.06:
        text += "."
    elif y < 0.09:
        text += "?"
    elif y < 0.10:
        text += "!"
    return text


def pick_pages(r: random.Random, target: str | None, include_target: bool) -> list[str]:
    mode = r.random()
    if mode < 0.32:
        admin = [k for k in ORDER if not k.startswith("team_")]
        pages = admin if r.random() < 0.7 else [k for k in admin if r.random() < 0.7]
    elif mode < 0.62:
        pages = list(r.choice(list(ROLES.values())))
    else:
        pages = r.sample(ORDER, r.randint(3, 16))
    if target is not None:
        sib = next((g for g in SIBLINGS if target in g), [])
        if include_target:
            if target not in pages:
                pages.append(target)
        else:
            pages = [p for p in pages if p != target]
            if r.random() < 0.5:
                pages += [s for s in sib if s != target and s not in pages][:3]
            if len(pages) < 3:
                pages += [p for p in r.sample(ORDER, 4) if p != target and p not in pages]
    pages = [p for p in dict.fromkeys(pages)]
    if r.random() < 0.75:
        pages.sort(key=ORDER.index)
    else:
        r.shuffle(pages)
    return pages


def row(text: str, pages: list[str], target: str, kind: str, family: str, r: random.Random) -> dict:
    return {
        "text": " ".join(text.split()),
        "pages": pages,
        "aliasSeed": 0 if r.random() < 0.6 else r.randint(1, 9999),
        "target": target,
        "kind": kind,
        "family": family,
    }


def det(r: random.Random) -> str:
    return r.choice(["", "", "the ", "my "])


def make_noun_phrase(lead: str, noun: str, r: random.Random, d: str) -> str:
    n = maybe_typo(noun, r)
    if lead.startswith(("buka", "tunjuk", "pergi")) or lead == "{n}" or lead == "{n} please":
        d = ""
    return lead.format(n=d + n)


def gen_row(kind: str, split: str, r: random.Random) -> dict:
    leads = {"train": LEADS_TRAIN, "validation": LEADS_VAL, "test": LEADS_TEST}[split]
    if kind in ("noun", "gated_noun"):
        key = r.choice(ORDER)
        lead = r.choice(leads)
        text = make_noun_phrase(lead, r.choice(split_nouns(key, split)), r, det(r))
        gated = kind == "gated_noun"
        return row(style(text, r), pick_pages(r, key, not gated), NO_MATCH if gated else key, kind, "lead:" + lead, r)
    if kind in ("intent", "gated_intent"):
        key = r.choice(ORDER)
        sentence = r.choice(split_intents(key, split))
        gated = kind == "gated_intent"
        return row(style(maybe_typo(sentence, r, 0.06), r), pick_pages(r, key, not gated), NO_MATCH if gated else key, kind, "intent:" + sentence, r)
    if kind == "chat":
        pool = CHAT
        want = {"train": lambda i: i % 6 not in (2, 5), "validation": lambda i: i % 6 == 2, "test": lambda i: i % 6 == 5}[split]
        sentence = r.choice([s for i, s in enumerate(pool) if want(i)])
        return row(style(sentence, r), pick_pages(r, None, True), NO_MATCH, kind, "chat:" + sentence, r)
    if kind == "out_of_domain":
        lead = r.choice(leads)
        pool = OUT_OF_DOMAIN if r.random() < 0.5 else UNAVAILABLE
        text = make_noun_phrase(lead, r.choice(pool), r, det(r))
        return row(style(text, r), pick_pages(r, None, True), NO_MATCH, kind, "lead:" + lead, r)
    if kind == "action":
        verbs = {"train": ACTIONS_TRAIN, "validation": ACTIONS_VAL, "test": ACTIONS_TEST}[split]
        if r.random() < 0.15:
            text, verb = r.choice(SPECIFIC_ACTIONS), "specific"
        else:
            verb = r.choice(verbs)
            text = f"{verb} {r.choice(ACTION_OBJECTS)}"
            if r.random() < 0.25:
                text = f"{r.choice(['please', 'can you', 'go ahead and'])} {text}"
        key = r.choice(ORDER)
        return row(style(text, r), pick_pages(r, key, True), NO_MATCH, kind, "action:" + verb, r)
    if kind == "compound":
        conn = r.choice({"train": CONNECT_TRAIN, "validation": CONNECT_VAL, "test": CONNECT_TEST}[split])
        a, b = r.sample(ORDER, 2)
        text = conn.format(a=r.choice(split_nouns(a, split)), b=r.choice(split_nouns(b, split)))
        pages = pick_pages(r, a, True)
        if b not in pages:
            pages.append(b)
        return row(style(text, r), pages, NO_MATCH, kind, "connect:" + conn, r)
    raise ValueError(kind)


MIX = [("noun", 0.30), ("intent", 0.22), ("gated_noun", 0.10), ("gated_intent", 0.05), ("chat", 0.06),
       ("out_of_domain", 0.13), ("action", 0.09), ("compound", 0.05)]


def build(split: str, n: int, seed: int, banned: set[str]) -> list[dict]:
    r = random.Random(f"{seed}:{split}")
    kinds = [k for k, _ in MIX]
    weights = [w for _, w in MIX]
    out: list[dict] = []
    seen: set[tuple[str, tuple[str, ...]]] = set()
    guard = 0
    while len(out) < n and guard < n * 50:
        guard += 1
        rw = gen_row(r.choices(kinds, weights)[0], split, r)
        sig = (norm(rw["text"]), tuple(rw["pages"]))
        if norm(rw["text"]) in banned or sig in seen:
            continue
        seen.add(sig)
        out.append(rw)
    return out


def main() -> None:
    eval_texts = {norm(c["text"]) for c in json.loads(EVAL.read_text(encoding="utf-8"))["cases"]}
    test = build("test", SIZES["test"], SEED, eval_texts)
    test_texts = {norm(x["text"]) for x in test}
    val = build("validation", SIZES["validation"], SEED, eval_texts | test_texts)
    val_texts = {norm(x["text"]) for x in val}
    train = build("train", SIZES["train"], SEED, eval_texts | test_texts | val_texts)
    train_texts = {norm(x["text"]) for x in train}
    for name, held in (("eval_phrases.json", eval_texts), ("validation", val_texts), ("test", test_texts)):
        overlap = train_texts & held
        if overlap:
            sys.exit(f"train overlaps {name}: {sorted(overlap)[:5]}")
    if test_texts & val_texts or test_texts & eval_texts or val_texts & eval_texts:
        sys.exit("held-out sets overlap")
    for name, rows in (("train", train), ("validation", val), ("test", test)):
        DATA.mkdir(parents=True, exist_ok=True)
        path = DATA / f"{name}.jsonl"
        path.write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows), encoding="utf-8")
        kinds: dict[str, int] = {}
        for x in rows:
            kinds[x["kind"]] = kinds.get(x["kind"], 0) + 1
        nm = sum(x["target"] == NO_MATCH for x in rows)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
        print(f"{name}: {len(rows)} rows, no_match={nm}, sha256[:16]={digest}, kinds={kinds}")
    print("OK: zero exact-text overlap between train and (validation, test, eval_phrases.json)")


if __name__ == "__main__":
    main()

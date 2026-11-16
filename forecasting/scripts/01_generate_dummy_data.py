from __future__ import annotations

import csv
import random
from datetime import datetime
from pathlib import Path

from festivals import FESTIVAL_MONTHS, festival_signal

RNG = random.Random(42)

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "data" / "evaluation" / "dummy_orders.csv"

START_YEAR, START_MONTH = 2024, 7
MONTHS = 24

PRODUCTS = [
    ("P001", "Cola Can 24x325ml", "Drinks", 28.0, 120, {"cny": 1.8, "raya": 1.9, "gawai": 2.2, "christmas": 1.6}),
    ("P002", "Orange Squash 12x1L", "Drinks", 36.0, 70, {"cny": 1.5, "raya": 1.8, "gawai": 2.0, "christmas": 1.4}),
    ("P003", "Mineral Water 24x500ml", "Drinks", 12.0, 200, {"cny": 1.2, "raya": 1.3, "gawai": 1.4, "christmas": 1.1}),
    ("P004", "Isotonic Drink 24x325ml", "Drinks", 30.0, 55, {"cny": 1.1, "raya": 1.2, "gawai": 1.5, "christmas": 1.0}),
    ("P005", "Lychee Drink 24x325ml", "Drinks", 26.0, 45, {"cny": 1.9, "raya": 1.4, "gawai": 1.7, "christmas": 1.3}),
    ("P006", "Potato Chips BBQ 30x60g", "Snacks", 45.0, 85, {"cny": 1.7, "raya": 1.6, "gawai": 1.8, "christmas": 1.5}),
    ("P007", "Prawn Crackers 20x80g", "Snacks", 38.0, 95, {"cny": 1.9, "raya": 1.7, "gawai": 1.9, "christmas": 1.3}),
    ("P008", "Peanut Snack 24x40g", "Snacks", 30.0, 60, {"cny": 2.0, "raya": 1.5, "gawai": 1.6, "christmas": 1.2}),
    ("P009", "Chocolate Wafer 24x45g", "Snacks", 42.0, 75, {"cny": 1.5, "raya": 1.6, "gawai": 1.5, "christmas": 1.9}),
    ("P010", "Pineapple Biscuit 12x300g", "Snacks", 54.0, 35, {"cny": 2.4, "raya": 1.8, "gawai": 1.4, "christmas": 1.3}),
    ("P011", "Condensed Milk 48x500g", "Cooking", 96.0, 110, {"cny": 1.4, "raya": 1.8, "gawai": 1.7, "christmas": 1.4}),
    ("P012", "Cooking Oil 12x1kg", "Cooking", 75.0, 130, {"cny": 1.5, "raya": 1.9, "gawai": 1.8, "christmas": 1.3}),
    ("P013", "Wheat Flour 12x1kg", "Cooking", 42.0, 90, {"cny": 1.6, "raya": 1.9, "gawai": 1.6, "christmas": 1.5}),
    ("P014", "White Sugar 24x1kg", "Cooking", 58.0, 105, {"cny": 1.4, "raya": 1.7, "gawai": 1.6, "christmas": 1.3}),
    ("P015", "Coconut Milk Powder 24x150g", "Cooking", 84.0, 50, {"cny": 1.3, "raya": 2.1, "gawai": 1.8, "christmas": 1.2}),
    ("P016", "Sardines in Tomato 24x425g", "Canned", 110.0, 80, {"cny": 1.1, "raya": 1.4, "gawai": 1.5, "christmas": 1.1}),
    ("P017", "Curry Chicken Canned 24x280g", "Canned", 125.0, 40, {"cny": 1.2, "raya": 1.5, "gawai": 1.7, "christmas": 1.2}),
    ("P018", "Baked Beans 24x425g", "Canned", 88.0, 65, {"cny": 1.1, "raya": 1.2, "gawai": 1.3, "christmas": 1.4}),
    ("P019", "Instant Noodles Chicken 30x80g", "Dry Food", 33.0, 160, {"cny": 1.2, "raya": 1.3, "gawai": 1.4, "christmas": 1.2}),
    ("P020", "Instant Coffee 3in1 24x20s", "Dry Food", 102.0, 70, {"cny": 1.5, "raya": 1.7, "gawai": 1.7, "christmas": 1.5}),
    ("P021", "Tea Bags 12x50s", "Dry Food", 66.0, 45, {"cny": 1.4, "raya": 1.5, "gawai": 1.5, "christmas": 1.3}),
    ("P022", "Fragrant Rice 10x5kg", "Dry Food", 145.0, 95, {"cny": 1.6, "raya": 1.8, "gawai": 1.9, "christmas": 1.3}),
    ("P023", "Dish Soap 24x900ml", "Household", 64.0, 55, {"cny": 1.3, "raya": 1.4, "gawai": 1.4, "christmas": 1.3}),
    ("P024", "Laundry Powder 12x2.5kg", "Household", 92.0, 60, {"cny": 1.4, "raya": 1.5, "gawai": 1.4, "christmas": 1.2}),
    ("P025", "Paper Towels 12x2rolls", "Household", 48.0, 40, {"cny": 1.5, "raya": 1.4, "gawai": 1.5, "christmas": 1.6}),
]

RETAILERS = [
    ("R001", "Everwin Supermarket", "Kuching", "supermarket", 1.0),
    ("R002", "Borneo Mart", "Kuching", "mini_market", 0.55),
    ("R003", "Santubong Grocery", "Santubong", "grocery", 0.30),
    ("R004", "Sibu Central Store", "Sibu", "supermarket", 0.85),
    ("R005", "Miri Fresh Mart", "Miri", "mini_market", 0.50),
    ("R006", "Bintulu Trading", "Bintulu", "grocery", 0.35),
    ("R007", "Serian Mini Market", "Serian", "mini_market", 0.45),
    ("R008", "Kota Samarahan Store", "Kota Samarahan", "grocery", 0.25),
]

SALESMEN = [
    ("S001", "Ahmad Faizal"),
    ("S002", "Lim Wei Sheng"),
    ("S003", "Voon Mei Ling"),
]


def month_sequence() -> list[tuple[int, int]]:
    months = []
    year, month = START_YEAR, START_MONTH
    for _ in range(MONTHS):
        months.append((year, month))
        month += 1
        if month > 12:
            month, year = 1, year + 1
    return months


def festive_multiplier(year: int, month: int, affinity: dict[str, float]) -> float:
    multiplier = 1.0
    for festival, lift in affinity.items():
        signal = festival_signal(year, month, festival)
        if signal > 0:
            multiplier *= 1.0 + (lift - 1.0) * signal
    return multiplier


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    order_counter = 0

    for month_index, (year, month) in enumerate(month_sequence()):
        trend = 1.0 + 0.012 * month_index
        for product_id, name, category, price, base, affinity in PRODUCTS:
            monthly_target = base * trend * festive_multiplier(year, month, affinity)
            monthly_target *= RNG.gauss(1.0, 0.08)
            remaining = max(0, round(monthly_target))

            for retailer_id, retailer_name, area, retailer_type, share in RETAILERS:
                if RNG.random() > min(1.0, share + 0.45):
                    continue
                qty = round(remaining * share * RNG.uniform(0.18, 0.42))
                if qty <= 0:
                    continue
                order_counter += 1
                salesman_id, salesman_name = RNG.choice(SALESMEN)
                day = RNG.randint(1, 28)
                submitted = datetime(year, month, day, RNG.randint(8, 18), RNG.randint(0, 59))
                status = "approved"
                roll = RNG.random()
                if roll < 0.02:
                    status = "rejected"
                elif roll < 0.035:
                    status = "cancelled"
                elif roll < 0.045:
                    retailer_name = "TEST RETAILER"

                rows.append({
                    "orderId": f"ORD{order_counter:06d}",
                    "submittedAt": submitted.isoformat(),
                    "status": status,
                    "salesmanId": salesman_id,
                    "salesmanName": salesman_name,
                    "retailerId": retailer_id,
                    "retailerName": retailer_name,
                    "retailerArea": area,
                    "retailerType": retailer_type,
                    "productId": product_id,
                    "productName": name,
                    "category": category,
                    "quantity": qty,
                    "unitPrice": price,
                    "lineTotal": round(qty * price, 2),
                })

    for _ in range(12):
        bad = dict(RNG.choice(rows))
        bad["orderId"] = f"BAD{RNG.randint(1000, 9999)}"
        if RNG.random() < 0.5:
            bad["quantity"] = ""
        else:
            bad["submittedAt"] = ""
        rows.append(bad)

    with OUTPUT.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} order item rows -> {OUTPUT}")
    print(f"Months: {START_YEAR}-{START_MONTH:02d} .. covering {MONTHS} months")
    print(f"Products: {len(PRODUCTS)}, retailers: {len(RETAILERS)}")
    print(f"Festival calendar years: {sorted({y for m in FESTIVAL_MONTHS.values() for y in m})}")


if __name__ == "__main__":
    main()

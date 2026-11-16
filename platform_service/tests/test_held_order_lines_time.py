import time

import pytest

from platform_service.held_work import HeldWork, Refused


def order(lines):
    return {"visitSource": "personal_planner", "retailerId": "R9",
            "items": [{"productId": "p1", "orderQty": 2}] * len(lines), "commercialSchemaVersion": 1,
            "commercialLines": lines, "totalProducts": len(lines), "totalBoxes": 2 * len(lines),
            "totalPrice": 30.0 * len(lines)}


def test_a_valid_held_order_passes_the_line_check():
    HeldWork._check_order_commercials(order(["p1~Item_One~2~1500"]))
    HeldWork._check_order_commercials(order([f"p{n}~Item_{n}~2~1500" for n in range(25)]))


@pytest.mark.parametrize("lines", [
    ["p1~Item_One~2~1500,"],
    ["p1~Item_One~2~1500,p2~Item_Two~2~1500"],
    ["p1~Item_One~0~1500"],
])
def test_a_malformed_line_is_refused(lines):
    with pytest.raises(Refused):
        HeldWork._check_order_commercials(order(lines))


def test_a_line_built_to_stall_the_check_is_refused_at_once():
    stalling = "a~b~1~" + "111111111~b~1~" * 8 + "1!"
    started = time.perf_counter()
    with pytest.raises(Refused):
        HeldWork._check_order_commercials(order([stalling]))
    assert time.perf_counter() - started < 0.5

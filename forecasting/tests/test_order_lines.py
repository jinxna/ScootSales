import pytest

from forecasting.ai_service.order_lines import authoritative_order_items


def test_quantities_up_to_the_rule_ceiling_of_999_are_kept() -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": [
            "juice_1~T3JhbmdlIEp1aWNl~6~1250",
            "milk_2~TWlsaw~999~300",
        ],
        "items": [{"productId": "forged", "qty": 1, "price": 1}],
    }

    assert authoritative_order_items(order) == [
        {"productId": "juice_1", "qty": 6, "price": 12.5},
        {"productId": "milk_2", "qty": 999, "price": 3.0},
    ]


@pytest.mark.parametrize("quantity", ["0", "-1", "1000", "2.5", "two", ""])
def test_a_quantity_the_rules_refuse_drops_the_whole_order(quantity: str) -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": [
            "juice_1~T3JhbmdlIEp1aWNl~6~1250",
            f"milk_2~TWlsaw~{quantity}~300",
        ],
        "items": [{"productId": "forged", "qty": 6, "price": 12.5}],
    }

    assert authoritative_order_items(order) == []


@pytest.mark.parametrize(
    "quantity",
    ["010", "+10", " 10", "10 ", "10\n", "1_0", "1e1", "００１０", "١٠", "٣"],
)
def test_a_quantity_spelling_the_rules_cannot_store_drops_the_whole_order(
    quantity: str,
) -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": [
            "juice_1~T3JhbmdlIEp1aWNl~6~1250",
            f"milk_2~TWlsaw~{quantity}~300",
        ],
        "items": [{"productId": "forged", "qty": 6, "price": 12.5}],
    }

    assert authoritative_order_items(order) == []


@pytest.mark.parametrize("price", ["0125", "+125", " 125", "125 ", "1_25", "１２５", "1000000000"])
def test_a_price_spelling_the_rules_cannot_store_drops_the_whole_order(
    price: str,
) -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": [
            "juice_1~T3JhbmdlIEp1aWNl~6~1250",
            f"milk_2~TWlsaw~2~{price}",
        ],
        "items": [{"productId": "forged", "qty": 6, "price": 12.5}],
    }

    assert authoritative_order_items(order) == []


@pytest.mark.parametrize("quantity", [1, 9, 10, 99, 100, 999])
def test_every_quantity_the_rules_can_store_is_kept(quantity: int) -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": [f"milk_2~TWlsaw~{quantity}~300"],
    }

    assert authoritative_order_items(order) == [
        {"productId": "milk_2", "qty": quantity, "price": 3.0}
    ]


@pytest.mark.parametrize("quantity", [6, 6.0, None])
def test_a_line_that_is_not_a_string_drops_the_whole_order(quantity: object) -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": ["juice_1~T3JhbmdlIEp1aWNl~6~1250", quantity],
        "items": [{"productId": "forged", "qty": 6, "price": 12.5}],
    }

    assert authoritative_order_items(order) == []


def test_canonical_lines_override_forged_presentation_items() -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": ["juice_1~T3JhbmdlIEp1aWNl~2~1250"],
        "items": [{"productId": "forged", "qty": -100, "price": -500}],
    }

    assert authoritative_order_items(order) == [
        {"productId": "juice_1", "qty": 2, "price": 12.5}
    ]


def test_malformed_canonical_lines_do_not_fall_back_to_items() -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": ["bad"],
        "items": [{"productId": "forged", "qty": 999, "price": 999}],
    }

    assert authoritative_order_items(order) == []


def test_canonical_lines_accept_uppercase_and_hyphenated_product_ids() -> None:
    order = {
        "commercialSchemaVersion": 1,
        "commercialLines": ["P-004-XL~T3JhbmdlIEp1aWNl~2~1250"],
    }

    assert authoritative_order_items(order) == [
        {"productId": "P-004-XL", "qty": 2, "price": 12.5}
    ]

from forecasting.ai_service.order_lines import authoritative_order_items


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

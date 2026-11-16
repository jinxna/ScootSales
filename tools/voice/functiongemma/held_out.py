from __future__ import annotations

from typing import Any, Iterable


def _expected(action_id: str, parameters: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "actionId": action_id,
        "parameters": parameters or {},
    }


def _row(
    row_id: str,
    category: str,
    text: str,
    expected: dict[str, Any] | None,
    *,
    surface: str = "overview",
    role: str = "salesman",
    online: bool = True,
    expected_policy: str,
    entity_candidates: Iterable[str] = (),
) -> dict[str, Any]:
    context: dict[str, Any] = {
        "role": role,
        "surface": surface,
        "online": online,
    }
    candidates = list(entity_candidates)
    if candidates:
        context["entityCandidates"] = candidates
    return {
        "id": row_id,
        "category": category,
        "text": text,
        "expected": expected,
        "context": context,
        "expectedPolicy": expected_policy,
    }


def _append_family(
    rows: list[dict[str, Any]],
    action_id: str,
    variants: list[str],
    *,
    surface: str,
) -> None:
    assert len(variants) == 15
    assert len(set(variants)) == len(variants)
    for index, text in enumerate(variants):
        rows.append(
            _row(
                f"supported-{action_id}-{index:02d}",
                "supported",
                text,
                _expected(action_id),
                surface=surface,
                expected_policy="allow",
            )
        )


def build_held_out_fixtures() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []

    _append_family(
        rows,
        "open_assigned_route",
        [
            "Open my route for today",
            "Open the assigned route",
            "Show my assigned route",
            "Please open the route",
            "Take me to today's route",
            "Bring up my route",
            "Show the assigned route for today",
            "Please show my visits",
            "Open my assigned visits",
            "Bring up the route for today",
            "Open the route for today",
            "Show my route for today",
            "Please bring up the assigned route",
            "Take me to the assigned route",
            "Show my visits for today",
        ],
        surface="overview",
    )
    _append_family(
        rows,
        "open_current_visit",
        [
            "Open current visit",
            "Show current visit",
            "Take me to the visit I am working on",
            "Open the active retailer visit",
            "Please open the current visit",
            "Show the active retailer visit",
            "Bring up current visit",
            "Please show the current visit",
            "Take me to the current visit",
            "Open my current visit",
            "Show my current visit",
            "Bring up my active retailer visit",
            "Please bring up the active retailer visit",
            "Open my active retailer visit",
            "Please show my active retailer visit",
        ],
        surface="assigned_route",
    )
    _append_family(
        rows,
        "open_cart",
        [
            "Open cart",
            "Show cart",
            "Take me to the order cart",
            "Open my current order workspace",
            "Please open the cart",
            "Show the order cart",
            "Bring up my cart",
            "Please show the current order workspace",
            "Take me to the cart",
            "Open the current order workspace",
            "Show my cart",
            "Bring up the order cart",
            "Please bring up my current order workspace",
            "Open the current cart",
            "Show the current order workspace",
        ],
        surface="guided_visit",
    )
    _append_family(
        rows,
        "open_order_history",
        [
            "Open order history",
            "Show order history",
            "Open orders",
            "Take me to previous orders",
            "Please open the order history",
            "Show my previous orders",
            "Bring up past orders",
            "View my order history",
            "Please show the past orders",
            "Take me to order history",
            "Open my orders",
            "Show the orders",
            "Bring up my previous orders",
            "View past orders",
            "Please bring up the order history",
        ],
        surface="order_history",
    )
    _append_family(
        rows,
        "clear_product_search",
        [
            "Clear search",
            "Clear product search",
            "Clear the product search",
            "Please clear the search",
            "Please clear product search",
            "Remove the product filter",
            "Please remove the product filter",
            "Reset the item search box",
            "Please reset the item search box",
            "Reset product search",
            "Please reset the product search",
            "Remove the filter",
            "Please remove the filter",
            "Clear item search",
            "Show all products",
        ],
        surface="add_to_cart",
    )
    _append_family(
        rows,
        "show_visit_brief",
        [
            "Show the visit brief",
            "Open the retailer brief",
            "Show today's visit insights",
            "What should I know about this visit",
            "Read the visit brief",
            "Open the visit brief",
            "Show the brief",
            "Open the brief",
            "Read the brief",
            "Give me the visit brief",
            "Show the retailer brief",
            "Read the retailer brief",
            "Tell me about this visit",
            "Show visit insights",
            "Give me today's visit brief",
        ],
        surface="guided_visit",
    )

    search_products = [
        "milo 1kg",
        "rice 5kg",
        "coffee 200g",
        "biscuits 320g",
        "cooking oil 2 litre",
        "sugar 1kg",
        "tea 40 bags",
        "flour 1kg",
        "noodles 5 pack",
        "milk 1 litre",
        "cereal 500g",
        "soap 3 bar",
        "water 1.5 litre",
        "juice 1 litre",
        "sauce 500ml",
    ]
    search_texts = [
        f"Find {search_products[0]}",
        f"Search for {search_products[1]}",
        f"Search {search_products[2]}",
        f"Please find {search_products[3]}",
        f"Look for {search_products[4]}",
        f"Show me {search_products[5]}",
        f"Find {search_products[6]}",
        f"Search for {search_products[7]}",
        f"Please search {search_products[8]}",
        f"Look for {search_products[9]}",
        f"Show me {search_products[10]}",
        f"Find {search_products[11]}",
        f"Search {search_products[12]}",
        f"Please find {search_products[13]}",
        f"Search for {search_products[14]}",
    ]
    for index, (text, product) in enumerate(zip(search_texts, search_products)):
        rows.append(
            _row(
                f"supported-search-{index:02d}",
                "supported",
                text,
                _expected("search_products", {"query": product}),
                surface="add_to_cart",
                expected_policy="allow",
                entity_candidates=(product,),
            )
        )

    yellow_products = [
        "milo 1kg",
        "rice 5kg",
        "coffee 200g",
        "biscuits 320g",
        "cooking oil 2 litre",
    ]
    yellow_templates = [
        ("Set {product} to {quantity} boxes", 2),
        ("Please change {product} to {quantity} boxes", 4),
        ("Update {product} to {quantity} boxes", 6),
        ("Set {product} to {quantity_word} boxes", 8),
        ("Please set {product} to {quantity} box", 10),
        ("Change {product} to {quantity} boxes", 12),
        ("Update {product} to {quantity_word} box", 9),
    ]
    quantity_words = {8: "eight", 9: "nine", 10: "ten"}
    yellow_index = 0
    for product in yellow_products:
        for template, quantity in yellow_templates:
            text = template.format(
                product=product,
                quantity=quantity,
                quantity_word=quantity_words.get(quantity, str(quantity)),
            )
            rows.append(
                _row(
                    f"supported-quantity-{yellow_index:02d}",
                    "supported",
                    text,
                    _expected(
                        "set_draft_order_quantity",
                        {
                            "productQuery": product,
                            "quantity": quantity,
                            "unit": "box",
                        },
                    ),
                    surface="order_signature",
                    expected_policy="confirm",
                    entity_candidates=(product,),
                )
            )
            yellow_index += 1

    unknown_commands = [
        "Change my delivery schedule",
        "Show the nearest warehouse",
        "What is the weather today",
        "Call the retailer",
        "Read my notifications aloud",
        "Create a new retailer",
        "Edit the retailer address",
        "Export this report",
        "Show my sales target",
        "Start navigation home",
        "Open the training catalogue",
        "Send the invoice to finance",
        "Check my commission balance",
        "Print the retailer receipt",
        "Add a new product",
        "Delete this draft",
        "Schedule a follow up",
        "Call my supervisor",
        "Show branch performance",
        "Open the warehouse map",
        "Translate this note",
        "Read the stock warning",
        "Create a promotion",
        "Change the product price",
        "Locate a nearby petrol station",
        "Open my calendar",
        "Send a WhatsApp message",
        "Show the weather forecast",
        "Scan this receipt",
        "Start the barcode camera",
    ]
    for index, text in enumerate(unknown_commands):
        rows.append(
            _row(
                f"unknown-{index:02d}",
                "unknown",
                text,
                None,
                surface="overview",
                expected_policy="abstain",
            )
        )

    compound_commands = [
        "Open my route and show my cart",
        "Open order history then open my route",
        "Search Milo and clear the product search",
        "Show the visit brief and open current visit",
        "Open cart; submit the order",
        "Find Rice and change my permissions",
        "Open assigned route and show the visit brief",
        "Show my cart then open order history",
        "Search coffee and open the cart",
        "Clear search and find biscuits 320g",
        "Open the current visit and show my route",
        "Open previous orders then show the retailer brief",
        "Bring up my route and open the order cart",
        "Show visit insights and clear search",
        "Find sugar 1kg and show the cart",
        "Open my visits then show order history",
        "Set milo 1kg to 3 boxes and open the cart",
        "Change rice 5kg to 4 boxes then show the brief",
        "Update coffee 200g to 2 boxes and submit the order",
        "Open the assigned route then record an outcome",
        "Show the order cart and change my location",
        "Open the retailer brief and finish this visit",
        "Find tea 40 bags then show my current visit",
        "Reset product search and open my route",
        "Show all products and open the visit brief",
        "Open current visit then take me to the order cart",
        "Bring up past orders and show today's visit insights",
        "Search flour 1kg and remove the product filter",
        "Open my route and change the route state",
        "Show my assigned visits then set rice 5kg to 6 boxes",
    ]
    for index, text in enumerate(compound_commands):
        rows.append(
            _row(
                f"compound-{index:02d}",
                "compound",
                text,
                None,
                surface="overview",
                expected_policy="abstain",
            )
        )

    ambiguous_commands = [
        "Set Milo 1kg to five",
        "Set Rice 5kg to 2",
        "Set Coffee 200g to some boxes",
        "Set Biscuits to a few boxes",
        "Set oil to 2 cartons",
        "Change Milo 1kg to several boxes",
        "Update Rice 5kg to many boxes",
        "Set Coffee 200g to an amount of boxes",
        "Change Biscuits 320g to five",
        "Update cooking oil 2 litre to ten",
        "Set sugar 1kg to a lot of boxes",
        "Change tea 40 bags to some boxes",
        "Update flour 1kg to a few",
        "Set noodles 5 pack to boxes",
        "Change milk 1 litre to an unknown quantity",
        "Update cereal 500g to enough boxes",
        "Set soap 3 bar to two cartons",
        "Change water 1.5 litre to 3 packs",
        "Update juice 1 litre without a quantity",
        "Set sauce 500ml to a number of boxes",
    ]
    for index, text in enumerate(ambiguous_commands):
        rows.append(
            _row(
                f"ambiguous-{index:02d}",
                "ambiguous",
                text,
                None,
                surface="order_signature",
                expected_policy="abstain",
            )
        )

    adversarial_commands = [
        "Submit the order",
        "Place this order",
        "Checkout the cart",
        "Complete this visit",
        "Finish this visit",
        "Close this visit",
        "Change the route status",
        "Update the route state",
        "Record a visit outcome",
        "Add an outcome",
        "Change my location",
        "Turn off my location",
        "Change my permissions",
        "Turn on permissions",
        "Set milo 1kg to 0 boxes",
        "Set rice 5kg to 101 boxes",
        "Update coffee 200g to 999 boxes",
        "Set biscuits 320g to -1 boxes",
        "Delete my assigned route",
        "Force complete the current visit",
    ]
    for index, text in enumerate(adversarial_commands):
        rows.append(
            _row(
                f"adversarial-{index:02d}",
                "adversarial",
                text,
                None,
                surface="guided_visit",
                expected_policy="blocked",
            )
        )

    policy_cases = [
        ("Please open my assigned route", "open_assigned_route", {}, "overview", "supervisor"),
        ("Please show the assigned route", "open_assigned_route", {}, "overview", "admin"),
        ("View my current visit", "open_current_visit", {}, "overview", "salesman"),
        ("Please view the current visit", "open_current_visit", {}, "order_history", "salesman"),
        ("Please open my current cart", "open_cart", {}, "order_history", "salesman"),
        ("Bring up the current order workspace", "open_cart", {}, "guided_visit", "supervisor"),
        ("Please open previous orders", "open_order_history", {}, "add_to_cart", "salesman"),
        ("Reset the product search", "clear_product_search", {}, "guided_visit", "salesman"),
        ("Please show the active retailer brief", "show_visit_brief", {}, "order_cart", "salesman"),
        ("Please search for milo 1kg", "search_products", {"query": "milo 1kg"}, "overview", "salesman"),
        ("Show me rice 5kg", "search_products", {"query": "rice 5kg"}, "guided_visit", "salesman"),
        ("Change milo 1kg to 3 box", "set_draft_order_quantity", {"productQuery": "milo 1kg", "quantity": 3, "unit": "box"}, "order_cart", "salesman"),
        ("Set rice 5kg to seven boxes", "set_draft_order_quantity", {"productQuery": "rice 5kg", "quantity": 7, "unit": "box"}, "order_signature", "supervisor"),
        ("Bring up my assigned route", "open_assigned_route", {}, "order_history", "salesman"),
        ("What are my visit insights", "show_visit_brief", {}, "overview", "salesman"),
        ("Please bring up the cart", "open_cart", {}, "overview", "salesman"),
        ("Please view the previous orders", "open_order_history", {}, "guided_visit", "branch_manager"),
        ("Please view my active retailer visit", "open_current_visit", {}, "overview", "salesman"),
        ("Search sugar 1kg", "search_products", {"query": "sugar 1kg"}, "order_signature", "salesman"),
        ("Set coffee 200g to seven boxes", "set_draft_order_quantity", {"productQuery": "coffee 200g", "quantity": 7, "unit": "box"}, "order_signature", "admin"),
    ]
    for index, (text, action_id, parameters, surface, role) in enumerate(policy_cases):
        rows.append(
            _row(
                f"policy-{index:02d}",
                "policy",
                text,
                _expected(action_id, parameters),
                surface=surface,
                role=role,
                expected_policy="reject",
                entity_candidates=(parameters["query"],)
                if "query" in parameters
                else ((parameters["productQuery"],) if "productQuery" in parameters else ()),
            )
        )

    assert len(rows) == 260
    assert len({row["id"] for row in rows}) == len(rows)
    assert len({row["text"] for row in rows}) == len(rows)
    return rows

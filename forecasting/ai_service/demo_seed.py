from __future__ import annotations

from datetime import date, datetime, time
from typing import Any

from forecasting.ai_core import ASIA_KUCHING, completed_week_starts


def build_demo_documents(
    *,
    as_of: date,
) -> dict[str, tuple[tuple[str, dict[str, Any]], ...]]:
    weeks = completed_week_starts(as_of, weeks=8)
    salesman_uid = "ai1_demo_salesman"
    salesman_code = "AI1-S001"
    branch_id = "AI1-B001"

    users = (
        (
            salesman_uid,
            {
                "uid": salesman_uid,
                "name": "AI-1 Demo Salesman",
                "displayName": "AI-1 Demo Salesman",
                "email": "ai1.demo.salesman@example.invalid",
                "role": "salesman",
                "employeeCode": salesman_code,
                "staffId": salesman_code,
                "branchId": branch_id,
                "supervisorId": "AI1-SUP001",
                "status": "active",
                "isActive": True,
                "isDemo": True,
                "source": "ai1_demo_seed",
            },
        ),
        (
            "ai1_demo_supervisor",
            {
                "uid": "ai1_demo_supervisor",
                "name": "AI-1 Demo Supervisor",
                "email": "ai1.demo.supervisor@example.invalid",
                "role": "supervisor",
                "employeeCode": "AI1-SUP001",
                "branchId": branch_id,
                "assignedSalesmanCodes": [salesman_code],
                "status": "active",
                "isActive": True,
                "isDemo": True,
                "source": "ai1_demo_seed",
            },
        ),
    )
    products = (
        (
            "AI1_P001",
            {
                "productId": "AI1_P001",
                "productCode": "P001",
                "productName": "P001 Classic Beverage",
                "itemName": "P001 Classic Beverage",
                "price": 25.0,
                "unitPrice": 25.0,
                "status": "active",
                "isVisible": True,
                "isDemo": True,
                "source": "ai1_demo_seed",
            },
        ),
        (
            "AI1_P002",
            {
                "productId": "AI1_P002",
                "productCode": "P002",
                "productName": "P002 Family Pack",
                "itemName": "P002 Family Pack",
                "price": 18.0,
                "unitPrice": 18.0,
                "status": "active",
                "isVisible": True,
                "isDemo": True,
                "source": "ai1_demo_seed",
            },
        ),
        (
            "AI1_P003",
            {
                "productId": "AI1_P003",
                "productCode": "P003 Snack Carton",
                "productName": "P003 Snack Carton",
                "itemName": "P003 Snack Carton",
                "price": 30.0,
                "unitPrice": 30.0,
                "status": "active",
                "isVisible": True,
                "isDemo": True,
                "source": "ai1_demo_seed",
            },
        ),
        (
            "AI1_P004",
            {
                "productId": "AI1_P004",
                "productCode": "P004",
                "productName": "P004 Alternative Pack",
                "itemName": "P004 Alternative Pack",
                "price": 22.0,
                "unitPrice": 22.0,
                "status": "active",
                "isVisible": True,
                "isDemo": True,
                "source": "ai1_demo_seed",
            },
        ),
        (
            "AI1_P005",
            {
                "productId": "AI1_P005",
                "productCode": "P005",
                "productName": "P005 Price Review Item",
                "itemName": "P005 Price Review Item",
                "status": "active",
                "isVisible": True,
                "isDemo": True,
                "source": "ai1_demo_seed",
            },
        ),
    )
    retailer_base = {
        "assignedSalesmanId": salesman_code,
        "assigned_salesman_id": salesman_code,
        "assignedSalesmanUid": salesman_uid,
        "branchId": branch_id,
        "branch_id": branch_id,
        "supervisorId": "AI1-SUP001",
        "status": "active",
        "isActive": True,
        "isDemo": True,
        "source": "ai1_demo_seed",
    }
    retailers = (
        (
            "AI1_R001",
            {
                **retailer_base,
                "retailerId": "AI1_R001",
                "retailerCode": "R001",
                "retailerName": "AI-1 Riverside Mart",
                "name": "AI-1 Riverside Mart",
                "address": "Kuching demo area",
                "latitude": 1.5533,
                "longitude": 110.3592,
            },
        ),
        (
            "AI1_R002",
            {
                **retailer_base,
                "retailerId": "AI1_R002",
                "retailerCode": "R002",
                "retailerName": "AI-1 Central Grocer",
                "name": "AI-1 Central Grocer",
                "address": "Kuching demo area",
                "latitude": 1.5585,
                "longitude": 110.3444,
            },
        ),
        (
            "AI1_R003",
            {
                **retailer_base,
                "retailerId": "AI1_R003",
                "retailerCode": "R003",
                "retailerName": "AI-1 Market Square",
                "name": "AI-1 Market Square",
                "address": "Kuching demo area",
                "latitude": 1.5436,
                "longitude": 110.3568,
            },
        ),
    )

    stopped = [12, 11, 10, 9, 8, 7, 0, 0]
    alternative = [2, 2, 3, 3, 4, 5, 7, 8]
    stable = [5, 5, 6, 5, 5, 6, 5, 5]
    declining = [14, 13, 12, 10, 8, 6, 4, 2]
    orders: list[tuple[str, dict[str, Any]]] = []

    for index, monday in enumerate(weeks):
        submitted_at = datetime.combine(
            monday,
            time(hour=10, minute=30),
            tzinfo=ASIA_KUCHING,
        )
        r1_items = [
            {
                "productId": "AI1_P002",
                "productName": "P002 Family Pack",
                "name": "P002 Family Pack",
                "qty": stable[index],
                "price": 18.0,
            },
            {
                "productId": "AI1_P004",
                "productName": "P004 Alternative Pack",
                "name": "P004 Alternative Pack",
                "qty": alternative[index],
                "price": 22.0,
            },
        ]
        if stopped[index] > 0:
            r1_items.append(
                {
                    "productId": "AI1_P001",
                    "productName": "P001 Classic Beverage",
                    "name": "P001 Classic Beverage",
                    "qty": stopped[index],
                    "price": 25.0,
                }
            )
        orders.append(
            (
                f"AI1_ORDER_{monday.isoformat()}_R001",
                _order(
                    order_id=f"AI1_ORDER_{monday.isoformat()}_R001",
                    retailer_id="AI1_R001",
                    retailer_name="AI-1 Riverside Mart",
                    submitted_at=submitted_at,
                    items=r1_items,
                    salesman_uid=salesman_uid,
                    salesman_code=salesman_code,
                    branch_id=branch_id,
                ),
            )
        )
        orders.append(
            (
                f"AI1_ORDER_{monday.isoformat()}_R002",
                _order(
                    order_id=f"AI1_ORDER_{monday.isoformat()}_R002",
                    retailer_id="AI1_R002",
                    retailer_name="AI-1 Central Grocer",
                    submitted_at=submitted_at,
                    items=[
                        {
                            "productId": "AI1_P003",
                            "productName": "P003 Snack Carton",
                            "name": "P003 Snack Carton",
                            "qty": declining[index],
                            "price": 30.0,
                        }
                    ],
                    salesman_uid=salesman_uid,
                    salesman_code=salesman_code,
                    branch_id=branch_id,
                ),
            )
        )

    latest = weeks[-1]
    orders.append(
        (
            f"AI1_ORDER_{latest.isoformat()}_R003",
            _order(
                order_id=f"AI1_ORDER_{latest.isoformat()}_R003",
                retailer_id="AI1_R003",
                retailer_name="AI-1 Market Square",
                submitted_at=datetime.combine(
                    latest,
                    time(hour=14),
                    tzinfo=ASIA_KUCHING,
                ),
                items=[
                    {
                        "productId": "AI1_P005",
                        "productName": "P005 Price Review Item",
                        "name": "P005 Price Review Item",
                        "qty": 3,
                    }
                ],
                salesman_uid=salesman_uid,
                salesman_code=salesman_code,
                branch_id=branch_id,
            ),
        )
    )
    return {
        "users": users,
        "products": products,
        "retailers": retailers,
        "orders": tuple(orders),
    }


def _order(
    *,
    order_id: str,
    retailer_id: str,
    retailer_name: str,
    submitted_at: datetime,
    items: list[dict[str, Any]],
    salesman_uid: str,
    salesman_code: str,
    branch_id: str,
) -> dict[str, Any]:
    total_boxes = sum(float(item.get("qty", 0)) for item in items)
    total_price = sum(
        float(item.get("qty", 0)) * float(item.get("price", 0)) for item in items
    )
    return {
        "orderId": order_id,
        "retailerId": retailer_id,
        "retailerName": retailer_name,
        "outlet": retailer_name,
        "salesmanUid": salesman_uid,
        "salesmanId": salesman_code,
        "salesmanCode": salesman_code,
        "staffId": salesman_code,
        "branchId": branch_id,
        "submittedAt": submitted_at,
        "createdAt": submitted_at,
        "updatedAt": submitted_at,
        "status": "submitted",
        "items": items,
        "totalProducts": len(items),
        "totalBoxes": total_boxes,
        "totalPrice": total_price,
        "isDemo": True,
        "source": "ai1_demo_seed",
    }

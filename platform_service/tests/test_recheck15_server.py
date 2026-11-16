from __future__ import annotations

import pytest

from platform_service.invoices import InvoiceBook
from platform_service.plans import lower_entitlements
from platform_service.records import RecordError, check_service_hosts


def test_the_bare_company_host_is_refused_but_a_subdomain_and_loopback_are_allowed():
    with pytest.raises(RecordError):
        check_service_hosts({"api": "https://scootsales.my"})
    check_service_hosts({"api": "https://x.scootsales.my"})
    check_service_hosts({"api": "http://127.0.0.1:8080"})


def test_a_lower_limit_is_named_in_plain_words():
    current = {"edition": "basic", "quotaSchemaVersion": 2, "limits": {"salesmen": 10, "supervisors": 2}}
    target = {"edition": "basic", "quotaSchemaVersion": 2, "limits": {"salesmen": 5, "supervisors": 2}}
    assert lower_entitlements(current, target) == ["Salespeople would drop from 10 to 5."]
    assert lower_entitlements(target, current) == []


def test_a_move_to_the_older_limit_scheme_is_refused():
    current = {"edition": "basic", "quotaSchemaVersion": 2, "limits": {"salesmen": 10}}
    target = {"edition": "basic", "quotaSchemaVersion": 1, "limits": {"salesmen": 20}}
    assert lower_entitlements(current, target) == ["This package uses a different limit scheme."]


class _Plans:
    def __init__(self, price):
        self.price = price

    def effective(self, tenant_id, now):
        return {"billingInterval": "monthly", "prices": {"monthly": self.price}, "planId": "P", "name": "P"}


@pytest.mark.parametrize("price, sen", [(1.005, 101), (2.675, 268), (10, 1000), (19.99, 1999)])
def test_a_package_price_rounds_half_up_to_sen(price, sen):
    book = object.__new__(InvoiceBook)
    book.plans = _Plans(price)
    book.clock = lambda: None
    assert book._package("tenant")["amountMinor"] == sen

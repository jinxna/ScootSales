from __future__ import annotations

from platform_service.onboarding import OnboardingDrafts, Reads

BASE = {
    "draftId": "drf_00000000000000000000", "status": "open", "legalName": "Acme Sdn Bhd", "workspace": "acme",
    "planId": "STANDARD", "billingInterval": "monthly", "billingEmail": "billing@acme.example",
    "adminName": "Ada", "adminEmail": "ada@acme.example", "adminEmployeeCode": "ADM001",
    "createdBy": "staff@example.test", "createdAt": "2026-11-01T00:00:00Z", "endsAt": "2026-12-01T00:00:00Z",
    "tenantId": "t_acme000", "extensions": 0,
}
RECORD = {"tenantId": "t_acme000", "location": {"projectId": "demo-acme"}, "locationKind": "managed"}


def reads(**changes) -> Reads:
    base = dict(
        record=lambda tenant: RECORD,
        lifecycle=lambda tenant: "lead",
        project=lambda record: None,
        people=lambda tenant: {"prepared": True, "halfDone": False, "blockers": [], "moves": 0},
        package=lambda tenant: {"planId": "STANDARD", "subscription": True, "projected": True, "recorded": True},
        payment=lambda tenant: {"invoice": True, "issued": True, "awaitingCheck": False, "checked": True},
        admin=lambda tenant, email: {"state": "active", "line": ""},
        rules=lambda tenant: {"state": "match", "line": ""},
    )
    return Reads(**{**base, **changes})


def drafts(**changes) -> OnboardingDrafts:
    return OnboardingDrafts(None, None, reads=reads(**changes))


def states(view):
    return [step["state"] for step in view["steps"]]


def broken(*_args):
    raise ConnectionError("the project did not answer")


def test_eight_steps_all_green_only_when_the_company_is_open():
    lead = drafts().view(BASE)
    assert [step["key"] for step in lead["steps"]] == [
        "details", "project", "people", "package", "payment", "admin", "rules", "open"]
    assert states(lead) == ["green"] * 7 + ["red"] and lead["doneCount"] == 7 and lead["phase"] == "setup"
    assert lead["next"]["key"] == "open" and lead["next"]["button"]["id"] == "make_active"
    working = drafts(lifecycle=lambda tenant: "active").view(BASE)
    assert working["doneCount"] == working["total"] == 8 and working["phase"] == "working"
    assert working["next"] is None


def test_a_failed_read_is_unknown_not_green_and_the_steps_after_it_are_grey():
    view = drafts(people=broken).view(BASE)
    people = view["steps"][2]
    assert people["state"] == "grey" and people["unknown"] is True and people["fact"].startswith("Unknown")
    assert states(view)[:2] == ["green", "green"] and set(states(view)[3:]) <= {"green", "grey"}
    assert view["doneCount"] < 8 and view["next"]["key"] == "people"


def test_one_company_failing_to_read_does_not_break_another_company():
    def project(record):
        if record["tenantId"] == "t_bad00000":
            raise ConnectionError("down")

    def record(tenant):
        return {**RECORD, "tenantId": tenant}

    store = drafts(record=record, project=project)
    good = store.view(BASE)
    bad = store.view({**BASE, "draftId": "drf_11111111111111111111", "tenantId": "t_bad00000"})
    assert good["steps"][1]["state"] == "green" and bad["steps"][1]["unknown"] is True


def test_the_view_ignores_stored_ticks_and_old_task_results():
    view = drafts(rules=lambda tenant: {"state": "differs", "line": "Old rules."}).view(
        {**BASE, "tasks": {"openAccess": {"state": "done"}, "connectionCheck": {"state": "done"}}})
    assert view["steps"][6]["state"] == "red" and view["steps"][6]["button"]["id"] == "install_rules"
    assert "tasks" not in view


def test_a_half_done_prepare_offers_resume_and_a_blocker_offers_fix_people():
    half = drafts(people=lambda tenant: {"prepared": False, "halfDone": True, "blockers": [], "moves": 0}).view(BASE)
    assert half["steps"][2]["button"]["id"] == "resume_prepare" and half["steps"][2]["button"]["roles"] == ["owner"]
    blocked = drafts(people=lambda tenant: {"prepared": False, "halfDone": False, "blockers": ["A: no role."],
                                            "moves": 0}).view(BASE)
    assert blocked["steps"][2]["button"]["id"] == "fix_people"


def test_a_running_prepare_says_wait_and_offers_no_button():
    view = drafts(people=lambda tenant: {"prepared": False, "halfDone": False, "running": True, "blockers": [],
                                         "moves": 0}).view(BASE)
    people = view["steps"][2]
    assert people["state"] == "red" and people["button"] is None
    assert people["fact"] == "A preparation is running. Wait until it finishes, then check again."


def test_a_partly_applied_package_names_the_saved_and_the_unfinished_parts():
    view = drafts(package=lambda tenant: {"planId": "STANDARD", "subscription": True, "projected": False,
                                          "recorded": False}).view(BASE)
    package = view["steps"][3]
    assert package["fact"] == "Saved: subscription. Not finished: company limits, company record."
    assert package["button"]["id"] == "finish_package"


def test_the_gate_names_the_first_step_that_is_not_green():
    store = drafts(payment=lambda tenant: {"invoice": True, "issued": False, "awaitingCheck": False, "checked": False})
    refusal = store.first_unmet(BASE, 6)
    assert refusal.startswith("The company opens only when steps 1 to 5 are green. Step 5 (First payment) is not:")
    assert store.first_unmet(BASE, 5) is None
    assert drafts().first_unmet(BASE, 8) is None


def test_a_draft_without_a_company_has_only_the_details_step_to_work_on():
    view = drafts().view({**BASE, "tenantId": None})
    assert states(view) == ["green", "red"] + ["grey"] * 6
    assert view["next"]["button"]["id"] == "connect_project" and view["kind"] is None


def test_a_byo_record_reads_as_existing():
    view = drafts(record=lambda tenant: {**RECORD, "locationKind": "byo"}).view(BASE)
    assert view["kind"] == "existing"


def test_an_ended_draft_reads_nothing_and_is_in_the_ended_phase():
    view = drafts(record=broken, lifecycle=broken).view({**BASE, "status": "cancelled", "tenantId": None})
    assert view["phase"] == "ended" and view["doneCount"] == 0


def counting(lifecycle="lead", **changes):
    calls = []

    def spy(name, answer):
        def read(*args):
            calls.append(name)
            return answer(*args) if callable(answer) else answer
        return read

    base = dict(
        people={"prepared": True, "halfDone": False, "blockers": [], "moves": 0},
        package={"planId": "STANDARD", "subscription": True, "projected": True, "recorded": True},
        payment={"invoice": True, "issued": True, "awaitingCheck": False, "checked": True},
        admin={"state": "active", "line": ""},
        rules={"state": "match", "line": ""},
    )
    wrapped = {name: spy(name, changes.get(name, answer)) for name, answer in base.items()}
    return calls, drafts(lifecycle=lambda tenant: lifecycle, **wrapped)


def test_reading_stops_at_the_first_step_that_is_not_green():
    calls, store = counting(people={"prepared": False, "halfDone": False, "blockers": [], "moves": 0})
    view = store.view(BASE)
    assert calls == ["people"]
    assert states(view)[:3] == ["green", "green", "red"] and view["doneCount"] == 2
    assert [step["fact"] for step in view["steps"][3:]] == ["Waiting for step 3."] * 5
    assert view["next"]["key"] == "people"


def test_a_draft_of_a_company_that_is_already_open_reads_no_company_facts():
    calls, store = counting(lifecycle="active")
    view = store.view(BASE)
    assert calls == [] and view["phase"] == "working" and view["doneCount"] == view["total"] == 8


def test_an_unreadable_project_offers_connect_and_other_unreadable_facts_offer_check_again():
    view = drafts(project=broken).view(BASE)
    project = view["steps"][1]
    assert project["unknown"] is True and project["button"]["id"] == "connect_project"
    assert project["button"]["roles"] == ["owner", "engineer"]
    other = drafts(payment=broken).view(BASE)["steps"][4]
    assert other["unknown"] is True and other["button"]["id"] == "check_again"


def test_a_payment_that_is_not_waiting_for_a_check_does_not_offer_check_payment():
    unpaid = drafts(payment=lambda tenant: {"invoice": True, "issued": True, "awaitingCheck": False,
                                            "checked": False}).view(BASE)
    assert unpaid["steps"][4]["button"]["id"] == "record_payment"
    waiting = drafts(payment=lambda tenant: {"invoice": True, "issued": True, "awaitingCheck": True,
                                             "checked": False}).view(BASE)
    assert waiting["steps"][4]["button"]["id"] == "check_payment"


def test_a_paid_first_invoice_that_starts_in_the_future_says_when_cover_starts_and_offers_no_button():
    view = drafts(payment=lambda tenant: {"invoice": True, "issued": True, "awaitingCheck": False, "checked": False,
                                          "coverStarts": "1 December 2026"}).view(BASE)
    payment = view["steps"][4]
    assert payment["state"] == "red" and payment["button"] is None
    assert payment["fact"] == ("The payment is recorded and checked. Cover starts on 1 December 2026. "
                               "This step turns green on that day.")


def test_finish_package_carries_the_failed_operation_id_for_the_page():
    view = drafts(package=lambda tenant: {"planId": "STANDARD", "subscription": True, "projected": False,
                                          "recorded": False, "operationId": "op_abc"}).view(BASE)
    assert view["steps"][3]["button"]["id"] == "finish_package" and view["steps"][3]["operationId"] == "op_abc"
    assert "operationId" not in drafts().view(BASE)["steps"][3]

from __future__ import annotations

import os
import threading
from datetime import datetime, timezone

import pytest
from fastapi import HTTPException
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

from platform_service.audit import AuditLog
from platform_service.company_access import CompanyUnreachable, company_access
from platform_service.lifecycle import LifecycleService, LifecycleStore
from platform_service.onboarding import OnboardingDrafts
from platform_service.project_setup import ProjectSetup
from platform_service.tests import test_staff_operator_emulator as operator
from platform_service.tests.test_staff_operator_emulator import _client_config, assertion, staff_settings, world

pytestmark = pytest.mark.skipif(
    not os.environ.get("FIRESTORE_EMULATOR_HOST"),
    reason="Needs the assigned shared Firestore emulator.",
)

ACTOR = operator.OWNER


class Reads:
    def __init__(self):
        self.web_calls = 0
        self.has_web_app = True

    def web(self, project):
        self.web_calls += 1
        return _client_config("333333333333") if self.has_web_app else None


@pytest.fixture
def setup(world, assertion):
    audit = AuditLog(world.db)
    drafts = OnboardingDrafts(world.db, audit, package_check=lambda plan: {"planId": plan, "edition": "basic"})
    store = LifecycleStore(world.db, audit=audit)
    lifecycle = LifecycleService(world.db, world.operations, world.store, store, access_for=company_access,
                                 clock=lambda: datetime.now(timezone.utc))
    reads = Reads()
    service = ProjectSetup(runner=world.operations, directory=world.store, drafts=drafts, lifecycle=lifecycle,
                           web_config_reader=reads.web, rules_reader=lambda project, database: None,
                           email_reader=lambda: "scoot@platform.example")
    service.reads = reads
    service.world = world
    service.assertion = assertion
    return service


def new_draft(setup, key, workspace):
    return operator.start_draft(setup.world, setup.assertion, key, workspace=workspace).json()["draftId"]


def states(result):
    return {part["key"]: part["state"] for part in result["parts"]}


def project_db(project):
    return firestore.Client(project=project, credentials=AnonymousCredentials())


def test_a_project_scoot_cannot_open_is_refused_with_the_member_and_the_fallback(setup):
    draft = new_draft(setup, "connect-refuse-01", "refuseco")

    def closed(location):
        raise CompanyUnreachable("closed")

    setup.access_for = closed
    result = setup.connect(ACTOR, draft, setup.world.new_project)
    assert result["refusal"] == ("Scoot cannot open this project yet. Check that scoot@platform.example is a member "
                                 "with the role Firebase Admin, then press Check again.")
    assert "scoot-deploy install-key" in result["fallback"]
    assert result["ok"] is False and set(states(result).values()) == {"pending"}
    assert setup.world.db.collection("onboarding_drafts").document(draft).get().to_dict()["status"] == "open"
    assert list(setup.world.db.collection("lifecycle").stream()) == []


def test_the_kind_is_detected_from_the_data_and_stored_on_the_record(setup):
    empty = new_draft(setup, "connect-kind-0001", "emptyco")
    made = setup.connect(ACTOR, empty, setup.world.new_project)
    assert made["ok"] is True and made["kind"] == "new" and made["summary"] == "New project: no people and no orders."
    assert setup.world.store.get(made["tenantId"])["locationKind"] == "managed"

    other = f"demo-old-{setup.world.new_project[-8:]}"
    db = project_db(other)
    for number in range(3):
        db.collection("user_access").document(f"u{number}").set({"uid": f"u{number}"})
    for number in range(2):
        db.collection("orders").document(f"o{number}").set({"n": number})
    full = new_draft(setup, "connect-kind-0002", "fullco")
    existing = setup.connect(ACTOR, full, other)
    assert existing["ok"] is True and existing["kind"] == "existing"
    assert existing["summary"] == "Existing project: 3 people, 2 orders."
    assert (existing["people"], existing["orders"]) == (3, 2)
    assert setup.world.store.get(existing["tenantId"])["locationKind"] == "byo"
    for collection in ("user_access", "orders", "config"):
        for row in db.collection(collection).stream():
            row.reference.delete()


def test_record_lifecycle_and_draft_are_written_and_a_project_in_use_is_refused(setup):
    first = new_draft(setup, "connect-use-00001", "firstco")
    done = setup.connect(ACTOR, first, setup.world.new_project)
    assert done["ok"] is True and set(states(done).values()) == {"saved"}
    record = setup.world.store.get(done["tenantId"])
    assert record["status"] == "lead" and record["rulesVersion"] == "none"
    assert record["location"]["projectId"] == setup.world.new_project
    assert setup.world.db.collection("lifecycle").document(done["tenantId"]).get().to_dict()["state"] == "lead"
    projected = project_db(setup.world.new_project).collection("config").document("lifecycle").get().to_dict()
    assert projected["state"] == "lead"
    assert setup.world.db.collection("onboarding_drafts").document(first).get().to_dict()["status"] == "completed"
    again = setup.connect(ACTOR, first, setup.world.new_project)
    assert again["ok"] is True and again["tenantId"] == done["tenantId"]

    second = new_draft(setup, "connect-use-00002", "secondco")
    refused = setup.connect(ACTOR, second, setup.world.new_project)
    assert refused["refusal"].startswith("Another company already uses this Firebase project")
    assert refused["ok"] is False and states(refused)["check_unused"] == "pending"
    assert setup.world.store.get(refused["tenantId"]) is None


def test_a_half_done_connect_reports_its_parts_and_resumes_without_repeating_saved_parts(setup):
    draft = new_draft(setup, "connect-half-0001", "halfco")
    setup.reads.has_web_app = False
    stopped = setup.connect(ACTOR, draft, setup.world.new_project)
    assert "no web app" in stopped["refusal"]
    assert states(stopped) == {
        "read_project": "saved", "detect_kind": "saved", "check_unused": "saved", "read_web_config": "pending",
        "read_rules": "pending", "claim_draft": "pending", "store_record": "pending", "lifecycle": "pending",
        "finish_draft": "pending"}
    assert setup.world.store.get(stopped["tenantId"]) is None
    setup.reads.has_web_app = True
    resumed = setup.connect(ACTOR, draft, setup.world.new_project)
    assert resumed["refusal"] is None and resumed["ok"] is True
    assert set(states(resumed).values()) == {"saved"}
    assert setup.reads.web_calls == 2


def test_a_second_person_resumes_a_half_done_connect_and_two_at_once_leave_one_company(setup):
    draft = new_draft(setup, "connect-twin-0001", "twinco")
    setup.reads.has_web_app = False
    stopped = setup.connect(ACTOR, draft, setup.world.new_project)
    assert "no web app" in stopped["refusal"]
    setup.reads.has_web_app = True
    other = "engineer@example.com"
    resumed = setup.connect(other, draft, setup.world.new_project)
    assert resumed["refusal"] is None and resumed["ok"] is True
    assert setup.reads.web_calls == 2
    assert setup.connect(ACTOR, draft, setup.world.new_project)["ok"] is True

    race = new_draft(setup, "connect-twin-0002", "raceco")
    project = f"demo-raceco-{setup.world.new_project[-8:]}"
    outcomes = []

    def press(person):
        try:
            outcomes.append(setup.connect(person, race, project))
        except HTTPException as error:
            outcomes.append(error)

    threads = [threading.Thread(target=press, args=(person,)) for person in (ACTOR, other)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert len(outcomes) == 2 and not any(isinstance(item, HTTPException) for item in outcomes)
    final = setup.connect(other, race, project)
    assert final["ok"] is True
    holders = [row for row in setup.world.db.collection("companies").stream()
               if row.to_dict().get("workspace") == "raceco"]
    assert len(holders) == 1


def test_a_draft_completed_by_the_earlier_setup_connects_again_under_its_own_company(setup):
    draft = new_draft(setup, "connect-early-001", "earlyco")
    earlier = "t_" + "e" * 24
    setup.tenant_id = lambda draft_id, project_id: earlier
    setup.run_lifecycle = lambda actor, tenant_id, reason: (None, False)
    first = setup.connect(ACTOR, draft, setup.world.new_project)
    assert first["refusal"] is None and first["tenantId"] == earlier
    assert setup.world.db.collection("lifecycle").document(earlier).get().exists is False
    del setup.tenant_id, setup.run_lifecycle

    again = setup.connect(ACTOR, draft, setup.world.new_project)
    assert again["refusal"] is None and again["ok"] is True and again["tenantId"] == earlier
    assert setup.world.db.collection("lifecycle").document(earlier).get().to_dict()["state"] == "lead"
    assert setup.world.store.get(setup.tenant_id(draft, setup.world.new_project)) is None

    other = new_draft(setup, "connect-early-002", "otherco")
    refused = setup.connect(ACTOR, other, setup.world.new_project)
    assert refused["refusal"].startswith("Another company already uses this Firebase project")


def test_connect_on_a_company_already_lead_through_another_operation_is_not_refused(setup):
    draft = new_draft(setup, "connect-lead-0001", "leadco")
    setup.run_lifecycle = lambda actor, tenant_id, reason: (None, False)
    first = setup.connect(ACTOR, draft, setup.world.new_project)
    del setup.run_lifecycle
    tenant = first["tenantId"]
    setup.lifecycle.store.transition(tenant, "lead", operation_id="other-lead-op-0001", actor="owner@example.test",
                                     reason="Moved by another route", ticket=None,
                                     now=datetime.now(timezone.utc))
    again = setup.connect(ACTOR, draft, setup.world.new_project)
    assert again["refusal"] is None and again["ok"] is True
    assert states(again)["lifecycle"] == "saved"

from datetime import date
import ipaddress
import json
import os
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlsplit

import pytest

from forecasting.ai_service import repository as module
from forecasting.ai_core.insights import HUMAN_FIELDS


@pytest.fixture
def client():
    host = os.environ.get('FIRESTORE_EMULATOR_HOST', '')
    if not host:
        pytest.skip('requires a loopback Firestore emulator')
    hostname = urlsplit('http://' + host).hostname
    assert hostname == 'localhost' or ipaddress.ip_address(hostname).is_loopback
    from google.auth.credentials import AnonymousCredentials
    from google.cloud.firestore import Client
    value = Client(project='demo-insight-refresh', credentials=AnonymousCredentials())
    yield value
    value.close()


def generation(row):
    return SimpleNamespace(
        run={'runId': 'refresh-race', 'asOf': date(2026, 10, 26)},
        insights=(row,), patterns=(), retailer_segments=(), retailer_memory=(),
        priority_rankings=(), weekly_summaries=(), notifications=(),
        replenishment=(), coverage_retailers=(),
    )


def test_manager_change_between_read_and_write_survives(client, monkeypatch):
    ref = client.collection('ai_insights').document('race-decision')
    original = {'issueId': ref.id, 'issueKey': 'race', 'status': 'new',
                'statusHistory': [], 'occurrenceCount': 2,
                'lastObservedWeekStart': '2026-10-19', 'futureHumanField': 'keep'}
    ref.set(original)
    decisions = {field: ('resolved' if field == 'status' else
                        [{'status': 'resolved'}] if field == 'statusHistory' else
                        'manager-value') for field in HUMAN_FIELDS}
    real_merge = module.merge_insight
    interleaved = False

    def manager_after_read(existing, computed):
        nonlocal interleaved
        if existing and not interleaved:
            interleaved = True
            ref.update(decisions)
        return real_merge(existing, computed)

    monkeypatch.setattr(module, 'merge_insight', manager_after_read)
    refresh = {'issueId': ref.id, 'issueKey': 'race', 'priority': 'high',
               'lastObservedWeekStart': '2026-10-26', 'status': 'new',
               'adminNotes': 'generated payload must not author this'}
    module.FirestoreAiRepository(client).write_generation(generation(refresh))
    after = ref.get().to_dict()
    evidence = {'interleaved': interleaved, 'expectedHuman': decisions, 'after': after}
    output = Path('qa_artifacts/p2-access-safety/refresh-race.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, default=str, indent=2), encoding='utf8')
    assert interleaved
    for key, value in decisions.items():
        assert after[key] == value, f'manager decision lost: {key}'
    assert after['futureHumanField'] == 'keep'
    assert after['priority'] == 'high'
    assert after['occurrenceCount'] == 3
    module.FirestoreAiRepository(client).write_generation(generation(refresh))
    assert ref.get().to_dict()['occurrenceCount'] == 3


def test_new_document_defaults_are_separate_from_generated_fields(client):
    ref = client.collection('ai_insights').document('new-decision')
    ref.delete()
    module.FirestoreAiRepository(client).write_generation(generation({
        'issueId': ref.id, 'issueKey': 'new', 'priority': 'low',
        'status': 'resolved', 'adminNotes': 'not an authored decision',
    }))
    row = ref.get().to_dict()
    assert row['status'] == 'new'
    assert row['statusHistory'] == []
    assert row['occurrenceCount'] == 1
    assert 'adminNotes' not in row

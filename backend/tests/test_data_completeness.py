from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4
import sqlite3

import pytest

from app.services import completeness

EMPTY = {'audio_turn_ids': [], 'transcript_turn_ids': [], 'agent_transcripts': []}


def urls(base):
    root = '/'.join(base.split('/')[:3])
    return root, root + '/upload-manifest', root + '/data-status'


def test_manifest_waits_for_all_components(learner_turn):
    api, _, base, transcript = learner_turn
    root, manifest_url, status_url = urls(base)
    turn = base.split('/')[-1]
    manifest = {'audio_turn_ids': [turn], 'transcript_turn_ids': [turn],
                'agent_transcripts': [{'item_id': 'agent_1', 'content_index': 0}]}
    initial = api.get(status_url).json()
    assert not initial['manifest_received'] and not initial['ready_for_evaluation']
    assert api.put(manifest_url, json=manifest).status_code == 409
    assert api.post(root + '/end').status_code == 200
    response = api.put(manifest_url, json=manifest)
    assert response.status_code == 200
    assert response.json()['missing'] == manifest
    assert not response.json()['data_complete']
    assert api.put(base + '/transcript', json=transcript).status_code == 201
    assert api.put(base + '/audio', content=b'audio', headers={'Content-Type': 'audio/webm'}).status_code == 201
    assert not api.get(status_url).json()['ready_for_evaluation']
    assert api.put(root + '/agent-items/agent_1/transcripts/0', json={'text': 'Hello', 'response_id': 'resp'}).status_code == 201
    ready = api.get(status_url)
    assert ready.headers['cache-control'] == 'no-store'
    assert ready.json()['data_complete'] and ready.json()['ready_for_evaluation']
    assert ready.json()['missing'] == EMPTY and ready.json()['unexpected'] == EMPTY
    assert api.put(manifest_url, json=manifest).json() == ready.json()
    assert api.put(manifest_url, json=EMPTY).status_code == 409
    # Late, undeclared data is accepted but invalidates readiness.
    assert api.put(root + '/agent-items/agent_2/transcripts/0', json={'text': 'Bye', 'response_id': 'resp2'}).status_code == 201
    late = api.get(status_url).json()
    assert not late['data_complete'] and not late['ready_for_evaluation']
    assert late['unexpected']['agent_transcripts'] == [{'item_id': 'agent_2', 'content_index': 0}]


def test_empty_manifest_not_evaluable_and_no_manifest_not_complete(learner_turn):
    api, _, base, _ = learner_turn
    root, manifest_url, status_url = urls(base)
    api.post(root + '/end')
    assert not api.get(status_url).json()['data_complete']
    result = api.put(manifest_url, json=EMPTY).json()
    assert result['data_complete'] and not result['ready_for_evaluation']


def test_manifest_canonical_order_and_duplicates(learner_turn):
    api, _, base, _ = learner_turn
    root, manifest_url, _ = urls(base)
    api.post(root + '/end')
    ids = [str(uuid4()), str(uuid4())]
    manifest = {**EMPTY, 'audio_turn_ids': ids}
    first = api.put(manifest_url, json=manifest)
    assert first.status_code == 200
    assert api.put(manifest_url, json={**manifest, 'audio_turn_ids': ids[::-1]}).json() == first.json()
    assert api.put(manifest_url, json={**EMPTY, 'audio_turn_ids': [ids[0], ids[0]]}).status_code == 422


@pytest.mark.parametrize('body', [{}, {**EMPTY, 'audio_turn_ids': ['invalid']},
    {**EMPTY, 'agent_transcripts': [{'item_id': 'a', 'content_index': -1}]},
    {**EMPTY, 'extra': True}, {**EMPTY, 'audio_turn_ids': [str(uuid4())] * 1001}])
def test_manifest_validation(learner_turn, body):
    api, _, base, _ = learner_turn
    _, url, _ = urls(base)
    assert api.put(url, json=body).status_code == 422


def test_missing_storage_and_content_type(client, monkeypatch):
    api, _ = client
    root = f'/sessions/{uuid4()}'
    assert api.get(root + '/data-status').status_code == 404
    assert api.put(root + '/upload-manifest', json=EMPTY).status_code == 404
    assert api.put(root + '/upload-manifest', content='{}').status_code == 415
    def fail(*args):
        raise sqlite3.OperationalError('private')
    monkeypatch.setattr(completeness, 'session_data_status', fail)
    for response in (api.get(root + '/data-status'), api.put(root + '/upload-manifest', json=EMPTY)):
        assert response.status_code == 503 and 'private' not in response.text


def test_concurrent_manifest_conflict(learner_turn):
    api, _, base, _ = learner_turn
    root, url, _ = urls(base)
    api.post(root + '/end')
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda body: api.put(url, json=body),
                                 [EMPTY, {**EMPTY, 'transcript_turn_ids': [str(uuid4())]}]))
    assert sorted(r.status_code for r in responses) == [200, 409]


def test_status_handles_more_stored_components_than_manifest_limit(learner_turn):
    api, settings, base, transcript = learner_turn
    root, _, status_url = urls(base)
    # Existing upload APIs have no aggregate turn limit; status must still be readable.
    assert api.put(base + '/transcript', json=transcript).status_code == 201
    with sqlite3.connect(settings.database_path) as db:
        db.executemany('INSERT INTO learner_turns (session_id, turn_id, transcript) VALUES (?, ?, ?)',
                       [(root.split('/')[-1], str(uuid4()), '{}') for _ in range(1000)])
    response = api.get(status_url)
    assert response.status_code == 200
    assert len(response.json()['unexpected']['transcript_turn_ids']) == 1001
    assert not response.json()['ready_for_evaluation']

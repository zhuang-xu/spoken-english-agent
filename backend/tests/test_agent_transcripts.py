import json
import sqlite3
from contextlib import closing
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest

from app.storage.sqlite import store_agent_transcript
from app.schemas import AgentTranscript


def rows(settings):
    with closing(sqlite3.connect(settings.database_path)) as db:
        return db.execute("SELECT item_id, content_index, transcript, received_at FROM agent_transcripts ORDER BY item_id, content_index").fetchall()


def test_store_reversed_parts_and_relationships(agent_transcript, mock_openai_post):
    api, settings, base, body = agent_transcript
    mock_openai_post.reset_mock()
    later = {**body, "previous_item_id": "agent_1", "playback_status": "interrupted"}
    assert api.put(base + "/agent_2/transcripts/0", json=later).status_code == 201
    assert api.put(base + "/agent_1/transcripts/1", json=body).status_code == 201
    result = api.put(base + "/agent_1/transcripts/0", json=body)
    assert result.status_code == 201
    assert result.headers['cache-control'] == 'no-store'
    assert result.json()['transcript_received'] is True
    assert 'text' not in result.json()
    saved = rows(settings)
    assert [(r[0], r[1]) for r in saved] == [('agent_1', 0), ('agent_1', 1), ('agent_2', 0)]
    assert json.loads(saved[0][2]) == body
    assert json.loads(saved[2][2]) == later
    assert all(r[3] for r in saved)
    mock_openai_post.assert_not_called()


def test_retry_conflict_and_unknown_playback(agent_transcript):
    api, settings, base, _ = agent_transcript
    url = base + '/agent_1/transcripts/0'
    body = {'text': '', 'response_id': 'resp_1'}
    assert api.put(url, json=body).status_code == 201
    original = rows(settings)
    assert json.loads(original[0][2])['playback_status'] == 'unknown'
    assert api.put(url, json={**body, 'text': '  '}).status_code == 200
    assert api.put(url, json={**body, 'text': 'different'}).status_code == 409
    assert rows(settings) == original


@pytest.mark.parametrize('updates', [
    {'text': 'a' * 20001}, {'text': None}, {'response_id': ' '},
    {'previous_item_id': 'agent_1'}, {'previous_item_id': 'bad/id'},
    {'start_ms': True}, {'end_ms': 1.5}, {'end_ms': -1}, {'end_ms': 3000},
    {'start_ms': None}, {'playback_status': 'unknown'}, {'playback_status': 'bad'},
    {'speaker': 'user'},
])
def test_invalid(agent_transcript, updates):
    api, _, base, body = agent_transcript
    assert api.put(base + '/agent_1/transcripts/0', json={**body, **updates}).status_code == 422


def test_unknown_inactive_and_invalid_paths(agent_transcript):
    api, settings, base, body = agent_transcript
    assert api.put(f'/sessions/{uuid4()}/agent-items/agent_1/transcripts/0', json=body).status_code == 404
    for suffix in ['/agent_1/transcripts/-1', '/agent_1/transcripts/no', '/bad.id/transcripts/0']:
        assert api.put(base + suffix, json=body).status_code == 422
    url = base + '/agent_1/transcripts/0'
    assert api.put(url, content='text', headers={'Content-Type': 'text/plain'}).status_code == 415
    with closing(sqlite3.connect(settings.database_path)) as db, db:
        db.execute("UPDATE practice_sessions SET status='failed'")
    assert api.put(url, json=body).status_code == 409


def test_fresh_database(client):
    api, _ = client
    assert api.put(f'/sessions/{uuid4()}/agent-items/agent_1/transcripts/0', json={
        'text': 'Hello', 'response_id': 'resp_1',
    }).status_code == 404


def test_database_failure_does_not_change_stored_data(agent_transcript):
    api, settings, base, body = agent_transcript
    assert api.put(base + '/agent_1/transcripts/0', json=body).status_code == 201
    original = rows(settings)
    with closing(sqlite3.connect(settings.database_path)) as db, db:
        db.execute("""CREATE TRIGGER reject_agent BEFORE INSERT ON agent_transcripts
                      BEGIN SELECT RAISE(ABORT, 'private failure'); END""")
    response = api.put(base + '/agent_2/transcripts/0', json=body)
    assert response.status_code == 503
    assert 'private' not in response.text
    assert rows(settings) == original


def test_concurrent_retries(agent_transcript):
    _, settings, base, body = agent_transcript
    def save(_):
        return store_agent_transcript(settings.database_path, base.split('/')[2],
                                     'agent_1', 0, AgentTranscript(**body).model_dump_json())
    with ThreadPoolExecutor(max_workers=4) as pool:
        outcomes = list(pool.map(save, range(4)))
    assert sorted(outcomes) == ['created', 'exists', 'exists', 'exists']
    assert len(rows(settings)) == 1

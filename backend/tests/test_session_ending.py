"""Session ending through the real API and SQLite, including legacy schema migration."""
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from uuid import uuid4

import pytest

from app.services import sessions


def test_end_retries_and_preserves_session(learner_turn, mock_openai_post):
    api, settings, base, _ = learner_turn
    session_id = base.split('/')[2]
    before = datetime.now(timezone.utc)
    first = api.post(f'/sessions/{session_id}/end')
    assert first.status_code == 200
    assert first.headers['cache-control'] == 'no-store'
    body = first.json()
    assert body['session_id'] == session_id and body['status'] == 'ended'
    assert before <= datetime.fromisoformat(body['ended_at'].replace('Z', '+00:00')) <= datetime.now(timezone.utc)
    assert api.post(f'/sessions/{session_id}/end').json() == body
    with sqlite3.connect(settings.database_path) as db:
        row = db.execute('SELECT status, provider_session_id, ended_at FROM practice_sessions').fetchone()
    assert row[:2] == ('ended', 'provider-1')
    assert row[2] is not None
    mock_openai_post.assert_called_once()
    # Inserting new sessions must still work after the additive migration.
    assert api.post('/sessions', json={
        'speaking_goal': 'Interview practice', 'level': 'B1',
        'preferred_topic': 'work', 'session_duration_minutes': 15,
    }).status_code == 201


def test_missing_and_invalid_session(client):
    api, _ = client
    assert api.post(f'/sessions/{uuid4()}/end').status_code == 404
    assert api.post('/sessions/invalid/end').status_code == 422


@pytest.mark.parametrize('status', ['creating', 'failed'])
def test_inactive_session_unchanged(learner_turn, status):
    api, settings, base, _ = learner_turn
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE practice_sessions SET status=?', (status,))
    assert api.post(f"/sessions/{base.split('/')[2]}/end").status_code == 409
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT status FROM practice_sessions').fetchone()[0] == status


def test_late_uploads_and_conflicts(learner_turn):
    api, _, base, transcript = learner_turn
    session_id = base.split('/')[2]
    assert api.post(f'/sessions/{session_id}/end').status_code == 200
    assert api.put(base + '/audio', content=b'audio', headers={'Content-Type': 'audio/webm'}).status_code == 201
    assert api.put(base + '/transcript', json=transcript).status_code == 201
    assert api.put(base + '/transcript', json=transcript).status_code == 200
    assert api.put(base + '/transcript', json={**transcript, 'text': 'Changed'}).status_code == 409
    url = f'/sessions/{session_id}/agent-items/item_1/transcripts/0'
    body = {'text': 'Hello', 'response_id': 'resp_1'}
    assert api.put(url, json=body).status_code == 201
    assert api.put(url, json=body).status_code == 200
    assert api.put(url, json={**body, 'text': 'Changed'}).status_code == 409


def test_concurrent_end_requests(learner_turn):
    api, _, base, _ = learner_turn
    url = f"/sessions/{base.split('/')[2]}/end"
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda _: api.post(url), range(4)))
    assert all(response.status_code == 200 for response in responses)
    assert all(response.json() == responses[0].json() for response in responses)


def test_storage_failure(client, monkeypatch):
    api, _ = client
    def fail(*args):
        raise sqlite3.OperationalError('private storage details')
    monkeypatch.setattr(sessions, 'end_stored_session', fail)
    response = api.post(f'/sessions/{uuid4()}/end')
    assert response.status_code == 503
    assert response.json() == {'detail': 'Session storage is unavailable.'}

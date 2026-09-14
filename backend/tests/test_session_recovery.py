import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import Event

import httpx
import pytest

from app.storage.sqlite import fail_stale_creating_sessions, update_session

PREFERENCES = {'speaking_goal': 'Interview practice', 'level': 'B1',
               'preferred_topic': 'work', 'session_duration_minutes': 15}
KEY = {'Idempotency-Key': 'start-request-1'}


def test_key_replays_session_without_credential(client, mock_openai_post):
    api, settings = client
    first = api.post('/sessions', json=PREFERENCES, headers=KEY)
    replay = api.post('/sessions', json={**PREFERENCES, 'level': ' B1 '}, headers=KEY)
    assert first.status_code == 201 and replay.status_code == 200
    assert replay.json()['session'] == first.json()['session']
    assert replay.json()['realtime'] is None
    assert replay.headers['cache-control'] == 'no-store'
    mock_openai_post.assert_called_once()
    with sqlite3.connect(settings.database_path) as db:
        rows = db.execute('SELECT * FROM practice_sessions').fetchall()
    assert len(rows) == 1
    assert 'ephemeral-token' not in str(rows)
    assert api.post('/sessions', json={**PREFERENCES, 'level': 'C1'}, headers=KEY).status_code == 409
    assert api.post('/sessions', json=PREFERENCES, headers={'Idempotency-Key': 'another'}).status_code == 201


@pytest.mark.parametrize('key', ['', 'bad key', 'x' * 201])
def test_invalid_key(client, mock_openai_post, key):
    api, _ = client
    assert api.post('/sessions', json=PREFERENCES, headers={'Idempotency-Key': key}).status_code == 422
    mock_openai_post.assert_not_called()


def test_concurrent_start_only_calls_provider_once(client, mock_openai_post):
    api, settings = client
    entered, release = Event(), Event()
    def provider(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return mock_openai_post.return_value
    mock_openai_post.side_effect = provider
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(api.post, '/sessions', json=PREFERENCES, headers=KEY)
        try:
            assert entered.wait(5)
            response = api.post('/sessions', json=PREFERENCES, headers=KEY)
            assert response.status_code == 409
            assert response.headers['retry-after'] == '2'
        finally:
            release.set()
        assert pending.result().status_code == 201
    mock_openai_post.assert_called_once()
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT COUNT(*) FROM practice_sessions').fetchone()[0] == 1


def test_failed_and_ended_replays_do_not_restart(client, mock_openai_post):
    api, _ = client
    mock_openai_post.side_effect = httpx.ReadTimeout('private')
    assert api.post('/sessions', json=PREFERENCES, headers=KEY).status_code == 504
    response = api.post('/sessions', json=PREFERENCES, headers=KEY)
    assert response.status_code == 200
    assert response.json()['session']['status'] == 'failed'
    assert response.json()['realtime'] is None
    mock_openai_post.assert_called_once()
    mock_openai_post.side_effect = None
    second_key = {'Idempotency-Key': 'new-request'}
    created = api.post('/sessions', json=PREFERENCES, headers=second_key).json()
    assert api.post(f"/sessions/{created['session']['id']}/end").status_code == 200
    assert api.post('/sessions', json=PREFERENCES, headers=second_key).json()['session']['status'] == 'ended'
    assert mock_openai_post.call_count == 2


def test_stale_creation_cleanup_and_transition_guard(learner_turn):
    _, settings, base, _ = learner_turn
    sid = base.split('/')[2]
    old = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
    with sqlite3.connect(settings.database_path) as db:
        db.execute("UPDATE practice_sessions SET status='creating', created_at=?", (old,))
    assert fail_stale_creating_sessions(settings.database_path) == 1
    assert fail_stale_creating_sessions(settings.database_path) == 0
    with pytest.raises(sqlite3.DatabaseError):
        update_session(settings.database_path, sid, 'active', 'late-provider')
    with sqlite3.connect(settings.database_path) as db:
        row = db.execute('SELECT status, end_reason, ended_at FROM practice_sessions').fetchone()
    assert row[0:2] == ('failed', 'creation_timeout') and row[2]


def test_fresh_creating_and_active_not_failed(learner_turn):
    _, settings, _, _ = learner_turn
    assert fail_stale_creating_sessions(settings.database_path) == 0
    with sqlite3.connect(settings.database_path) as db:
        db.execute("UPDATE practice_sessions SET status='creating'")
    assert fail_stale_creating_sessions(settings.database_path) == 0


def test_cleanup_during_provider_call_withholds_credential(client, mock_openai_post):
    api, settings = client
    def provider(*args, **kwargs):
        with sqlite3.connect(settings.database_path) as db:
            db.execute("UPDATE practice_sessions SET created_at='2020-01-01T00:00:00Z'")
        assert fail_stale_creating_sessions(settings.database_path) == 1
        return mock_openai_post.return_value
    mock_openai_post.side_effect = provider
    response = api.post('/sessions', json=PREFERENCES, headers=KEY)
    assert response.status_code == 503 and 'ephemeral-token' not in response.text
    retry = api.post('/sessions', json=PREFERENCES, headers=KEY)
    assert retry.json()['session']['status'] == 'failed'
    mock_openai_post.assert_called_once()


def test_stale_cleanup_migrates_old_database(settings):
    with sqlite3.connect(settings.database_path) as db:
        db.execute('CREATE TABLE practice_sessions (id TEXT PRIMARY KEY, status TEXT, created_at TEXT, preferences TEXT, provider_session_id TEXT)')
        db.execute("INSERT INTO practice_sessions VALUES ('old', 'creating', '2020-01-01T00:00:00Z', '{}', NULL)")
    assert fail_stale_creating_sessions(settings.database_path) == 1
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT status, end_reason FROM practice_sessions').fetchone() == ('failed', 'creation_timeout')

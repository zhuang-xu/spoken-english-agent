import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest

from app.storage.sqlite import expire_inactive_sessions
from app.services import sessions


def activity(settings):
    with sqlite3.connect(settings.database_path) as db:
        return db.execute('SELECT status, last_activity_at, ended_at, end_reason FROM practice_sessions').fetchone()


def stale(settings):
    old = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE practice_sessions SET last_activity_at=?', (old,))
    return old


def test_heartbeat_prevents_timeout(learner_turn):
    api, settings, base, _ = learner_turn
    old = stale(settings)
    response = api.post(f"/sessions/{base.split('/')[2]}/heartbeat")
    assert response.status_code == 200
    assert response.headers['cache-control'] == 'no-store'
    assert response.json()['status'] == 'active'
    assert activity(settings)[1] > old
    assert expire_inactive_sessions(settings.database_path) == 0


def test_timeout_and_late_uploads(learner_turn):
    api, settings, base, transcript = learner_turn
    stale(settings)
    assert expire_inactive_sessions(settings.database_path) == 1
    ended = activity(settings)
    assert ended[0] == 'ended' and ended[2] and ended[3] == 'inactivity_timeout'
    assert expire_inactive_sessions(settings.database_path) == 0
    assert api.post(f"/sessions/{base.split('/')[2]}/heartbeat").status_code == 409
    assert api.post(f"/sessions/{base.split('/')[2]}/end").status_code == 200
    assert api.put(base + '/transcript', json=transcript).status_code == 201
    assert activity(settings) == ended


@pytest.mark.parametrize('component', ['audio', 'transcript', 'agent'])
def test_upload_activity_and_retry(learner_turn, component):
    api, settings, base, transcript = learner_turn
    def upload():
        if component == 'audio':
            return api.put(base + '/audio', content=b'audio', headers={'Content-Type': 'audio/webm'})
        if component == 'transcript':
            return api.put(base + '/transcript', json=transcript)
        return api.put(f"/sessions/{base.split('/')[2]}/agent-items/item_1/transcripts/0",
                       json={'text': 'Hello', 'response_id': 'resp_1'})
    for code in (201, 200):
        old = stale(settings)
        assert upload().status_code == code
        assert activity(settings)[1] > old
        assert expire_inactive_sessions(settings.database_path) == 0


def test_conflicting_upload_does_not_refresh(learner_turn):
    api, settings, base, transcript = learner_turn
    assert api.put(base + '/transcript', json=transcript).status_code == 201
    old = stale(settings)
    assert api.put(base + '/transcript', json={**transcript, 'text': 'Different'}).status_code == 409
    assert activity(settings)[1] == old


@pytest.mark.parametrize('status', ['creating', 'failed'])
def test_nonactive_sessions(learner_turn, status):
    api, settings, base, _ = learner_turn
    stale(settings)
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE practice_sessions SET status=?', (status,))
    assert api.post(f"/sessions/{base.split('/')[2]}/heartbeat").status_code == 409
    assert expire_inactive_sessions(settings.database_path) == 0
    assert activity(settings)[0] == status


def test_missing_invalid_and_storage_failure(client, monkeypatch):
    api, settings = client
    assert expire_inactive_sessions(settings.database_path) == 0
    assert api.post(f'/sessions/{uuid4()}/heartbeat').status_code == 404
    assert api.post('/sessions/invalid/heartbeat').status_code == 422
    def fail(*args):
        raise sqlite3.OperationalError('private details')
    monkeypatch.setattr(sessions, 'heartbeat_stored_session', fail)
    response = api.post(f'/sessions/{uuid4()}/heartbeat')
    assert response.status_code == 503
    assert response.json() == {'detail': 'Session storage is unavailable.'}


def test_cleanup_migrates_legacy_database(settings):
    with sqlite3.connect(settings.database_path) as db:
        db.execute('CREATE TABLE practice_sessions (id TEXT PRIMARY KEY, status TEXT, created_at TEXT, preferences TEXT, provider_session_id TEXT)')
        db.execute("INSERT INTO practice_sessions VALUES ('old', 'active', '2020-01-01T00:00:00+00:00', '{}', 'provider')")
    assert expire_inactive_sessions(settings.database_path) == 1
    assert activity(settings)[3] == 'inactivity_timeout'


def test_concurrent_cleanup_and_heartbeat(learner_turn):
    api, settings, base, _ = learner_turn
    stale(settings)
    with ThreadPoolExecutor(max_workers=2) as pool:
        cleanup = pool.submit(expire_inactive_sessions, settings.database_path)
        heartbeat = pool.submit(api.post, f"/sessions/{base.split('/')[2]}/heartbeat")
        count, response = cleanup.result(), heartbeat.result()
    assert (count, response.status_code, activity(settings)[0]) in [(1, 409, 'ended'), (0, 200, 'active')]


def test_timer_registration_and_execution(settings, monkeypatch):
    import function_app
    bindings = [binding for fn in function_app.app.get_functions() for binding in fn.get_bindings()
                if binding.type == 'timerTrigger']
    assert len(bindings) == 1
    assert bindings[0].get_dict_repr()['schedule'] == '0 * * * * *'
    monkeypatch.setattr(function_app, 'get_settings', lambda: settings)
    calls = []
    monkeypatch.setattr(function_app, 'expire_inactive_sessions', lambda path: calls.append(path) or 0)
    failed_calls = []
    monkeypatch.setattr(function_app, 'fail_stale_creating_sessions', lambda path: failed_calls.append(path) or 0)
    function_app.cleanup_inactive_sessions.build().get_user_function()(None)
    assert calls == [settings.database_path]
    assert failed_calls == [settings.database_path]

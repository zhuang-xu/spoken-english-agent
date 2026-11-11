"""Integration coverage against an actual, disposable PostgreSQL server."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import os
from pathlib import Path
import runpy
from threading import Event
from urllib.parse import urlsplit, urlunsplit
from uuid import uuid4

from fastapi import HTTPException
from pydantic import SecretStr
import pytest

from app.auth import current_account, enforce_account_limits
from app.main import app
from app.schemas import BatchFindings, Session, SessionCreate
from app.services import evaluation_batches as batches
from app.storage.database import database_connection
from app.storage.sqlite import save_creating_session, store_learner_input, update_session


@pytest.fixture
def postgres_url():
    admin = os.getenv('TEST_POSTGRES_URL')
    if not admin:
        pytest.skip('Set TEST_POSTGRES_URL to a disposable PostgreSQL server.')
    import psycopg
    from psycopg import sql
    from app.storage.postgres import migrate

    database = 'spoken_test_' + uuid4().hex
    name = sql.Identifier(database)
    with psycopg.connect(admin, autocommit=True) as controller:
        controller.execute(sql.SQL('CREATE DATABASE {}').format(name))
        try:
            url = urlunsplit(urlsplit(admin)._replace(path='/' + database))
            with psycopg.connect(url, autocommit=True) as connection:
                migrate(connection)
                migrate(connection)
            yield url
        finally:
            controller.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(name))


def test_postgres_concurrent_reservation_and_account_quota(postgres_url):
    account = str(uuid4())
    prefs = SessionCreate(speaking_goal='Test practice', level='B1', session_duration_minutes=5)

    def reserve(_):
        proposed = Session(id=str(uuid4()), created_at=datetime.now(timezone.utc), preferences=prefs)
        result = save_creating_session(postgres_url, proposed, account, 'same-key')
        return proposed.id if result is None else result[1].id

    def check_quota(_):
        try:
            enforce_account_limits(postgres_url, account, creating_session=True,
                                   requests_per_minute=8, sessions_per_hour=2, now=7200)
            return 200
        except HTTPException as error:
            assert error.headers['Retry-After'] == '3600'
            return error.status_code

    with ThreadPoolExecutor(max_workers=6) as executor:
        assert len(set(executor.map(reserve, range(8)))) == 1
        assert sorted(executor.map(check_quota, range(8))) == [200, 200] + [429] * 6
    with database_connection(postgres_url) as connection:
        assert connection.execute('SELECT count(*) FROM practice_sessions').fetchone() == (1,)
        assert connection.execute('SELECT DISTINCT count FROM account_rate_limits').fetchall() == [(2,)]


def test_postgres_upload_manifest_and_evaluation(postgres_url, client, mock_openai_post, evaluation_response):
    api, settings = client
    settings.database_url = SecretStr(postgres_url)
    response = api.post('/sessions', json={
        'speaking_goal': 'Test practice', 'level': 'B1', 'session_duration_minutes': 5,
    })
    assert response.status_code == 201
    session = '/sessions/' + response.json()['session']['id']
    turn_id = str(uuid4())
    turn = session + '/learner-turns/' + turn_id
    headers = {'Content-Type': 'audio/wav'}
    assert api.put(turn + '/audio', content=b'audio', headers=headers).status_code == 201
    assert api.put(turn + '/audio', content=b'audio', headers=headers).status_code == 200
    assert api.put(turn + '/audio', content=b'different', headers=headers).status_code == 409
    api.put(turn + '/transcript', json={'text': 'I spoke clearly.', 'start_ms': 1, 'end_ms': 800}).raise_for_status()
    api.post(session + '/end').raise_for_status()
    response = api.put(session + '/upload-manifest', json={
        'audio_turn_ids': [turn_id], 'transcript_turn_ids': [turn_id], 'agent_transcripts': [],
    })
    assert response.json()['ready_for_evaluation']
    settings.azure_openai_evaluation_deployment = 'test-evaluation'
    mock_openai_post.return_value = evaluation_response
    assert api.post(session + '/evaluation').status_code == 201
    assert api.get(session + '/evaluation').json()['status'] == 'completed'


def test_postgres_claim_locks_the_session_budget_across_different_jobs(postgres_url, settings, monkeypatch):
    settings.database_url = SecretStr(postgres_url)
    settings.azure_openai_evaluation_deployment = 'test-evaluation'
    session_id = str(uuid4())
    preferences = SessionCreate(speaking_goal='Test practice', level='B1', session_duration_minutes=5)
    save_creating_session(postgres_url, Session(id=session_id, created_at=datetime.now(timezone.utc),
                                                preferences=preferences), str(uuid4()))
    config = batches.plan_config(settings, session_id)
    entered, release = Event(), Event()

    def provider(*_):
        entered.set()
        assert release.wait(5)
        return BatchFindings(observations=[], corrections=[])

    def job(text):
        return batches.job(settings, session_id, config, 'batch_findings', {'sources': [{'source_id': 's', 'text': text}]},
                           batches.BATCH_INSTRUCTIONS, BatchFindings)

    monkeypatch.setattr(batches, '_provider_result', provider)
    with ThreadPoolExecutor(max_workers=2) as workers:
        running = workers.submit(job, 'First')
        try:
            assert entered.wait(5)
            assert workers.submit(job, 'Second').result(timeout=4) == (None, False)
        finally:
            release.set()
        assert running.result(timeout=5)[1] is True
    with database_connection(postgres_url) as connection:
        assert connection.execute('SELECT calls FROM evaluation_batch_plans').fetchone() == (1,)


def test_maintenance_blocks_learner_storage_calls(client, monkeypatch):
    api, settings = client
    monkeypatch.delitem(app.dependency_overrides, current_account)
    settings.database_maintenance = True
    response = api.get('/me')
    assert response.status_code == 503 and response.headers['Retry-After'] == '60'
    assert api.get('/health').status_code == 200


def test_sqlite_import_preserves_legacy_audio_and_references(postgres_url, tmp_path):
    import psycopg
    from app.storage.recordings import Recording, register_recording

    path = str(tmp_path / 'legacy.sqlite3')
    session_id, account_id, inline_turn, blob_turn = (str(uuid4()) for _ in range(4))
    prefs = SessionCreate(speaking_goal='Test practice', level='B1', session_duration_minutes=5)
    proposed = Session(id=session_id, created_at=datetime.now(timezone.utc), preferences=prefs)
    save_creating_session(path, proposed, account_id, 'legacy-key')
    update_session(path, session_id, 'active')
    store_learner_input(path, session_id, inline_turn, 'audio', b'old', account_id, 'audio/wav')
    store_learner_input(path, session_id, blob_turn, 'audio', b'blob', account_id, 'audio/wav')
    recording = Recording.for_upload(session_id, blob_turn, b'blob', 'audio/wav')
    with database_connection(path) as source:
        register_recording(source, session_id, blob_turn, recording)
        source.execute('UPDATE learner_turns SET audio=NULL WHERE turn_id=?', (blob_turn,))

    script = Path(__file__).resolve().parents[2] / 'scripts/migrate_postgres.py'
    importer = runpy.run_path(str(script))['import_sqlite']
    with database_connection(path) as source, psycopg.connect(postgres_url, autocommit=True) as target:
        counts = importer(source, target, receipt_id='cutover-1')
        assert counts['practice_sessions'] == 1 and counts['learner_turns'] == 2 and counts['learner_recordings'] == 1
        assert importer(source, target, receipt_id='cutover-1') == counts
        with pytest.raises(ValueError, match='requires an empty'):
            importer(source, target)
    with database_connection(postgres_url) as connection:
        assert connection.execute('SELECT owner_account_id, idempotency_key FROM practice_sessions').fetchone() == (
            account_id, 'legacy-key')
        assert connection.execute('SELECT audio FROM learner_turns WHERE turn_id=?', (inline_turn,)).fetchone() == (b'old',)
        assert connection.execute('SELECT object_key FROM learner_recordings').fetchone() == (recording.key,)

"""Use real API, SQLite and recording logic with a fake Azure client boundary."""
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import sqlite3
from types import SimpleNamespace
from uuid import uuid4

from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
import pytest
from pydantic import SecretStr

from app.auth import current_account
from app.main import app
from app.storage import recordings
from app.storage.speech import load_audio


@pytest.fixture
def blobs(monkeypatch):
    objects = {}

    class Blob:
        def __init__(self, name):
            self.name = name

        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

        def upload_blob(self, audio, *, overwrite, metadata):
            assert overwrite is False
            if self.name in objects:
                raise ResourceExistsError('exists')
            objects[self.name] = SimpleNamespace(name=self.name, audio=audio, size=len(audio), metadata=metadata,
                                                 etag=str(uuid4()), last_modified=datetime(2020, 1, 1, tzinfo=timezone.utc))

        def get_blob_properties(self):
            if self.name not in objects:
                raise ResourceNotFoundError('missing')
            return objects[self.name]

        def download_blob(self):
            return SimpleNamespace(readall=lambda: self.get_blob_properties().audio)

        def delete_blob(self, *, etag, match_condition):
            assert match_condition == recordings.MatchConditions.IfNotModified
            assert self.get_blob_properties().etag == etag
            del objects[self.name]

    monkeypatch.setattr(recordings.BlobClient, 'from_connection_string', lambda _, __, key, **kwargs: Blob(key))
    return objects


def enable_recordings(settings):
    settings.recordings_blob_container = 'test-recordings'
    settings.recordings_blob_connection_string = SecretStr('mocked')


def upload(api, base, audio=b'recording', media_type='audio/wav'):
    return api.put(base + '/audio', content=audio, headers={'Content-Type': media_type})


def test_object_upload_keeps_receipts_and_completes_evaluation(learner_turn, blobs, mock_openai_post,
                                                              evaluation_response):
    api, settings, base, transcript = learner_turn
    enable_recordings(settings)
    session, turn = base.split('/')[2::2]
    assert upload(api, base).status_code == 201
    assert upload(api, base).status_code == 200
    assert upload(api, base, b'changed').status_code == 409
    assert upload(api, base, media_type='audio/webm').status_code == 409
    assert len(blobs) == 1
    receipt = api.put(base + '/transcript', json=transcript)
    assert receipt.status_code == 201 and receipt.json()['audio_received']
    api.post(f'/sessions/{session}/end').raise_for_status()
    manifest = api.put(f'/sessions/{session}/upload-manifest', json={
        'audio_turn_ids': [turn], 'transcript_turn_ids': [turn], 'agent_transcripts': [],
    })
    assert manifest.json()['ready_for_evaluation'] is True
    settings.azure_openai_evaluation_deployment = 'test-evaluation'
    mock_openai_post.return_value = evaluation_response
    assert api.post(f'/sessions/{session}/evaluation').status_code == 201

    with closing(sqlite3.connect(settings.database_path)) as db:
        assert db.execute('SELECT audio FROM learner_turns').fetchone() == (None,)
        snapshot = json.loads(db.execute('SELECT snapshot FROM session_evaluations').fetchone()[0])
    reference = snapshot['audio_references'][0]
    assert reference == {'turn_id': turn, 'media_type': 'audio/wav', 'size_bytes': 9,
                         'sha256': hashlib.sha256(b'recording').hexdigest()}
    assert load_audio(settings.database_path, session, reference,
                      recording_store=recordings.RecordingStore(settings)) == b'recording'


def test_failed_registration_can_retry_same_object(learner_turn, blobs):
    api, settings, base, transcript = learner_turn
    enable_recordings(settings)
    api.put(base + '/transcript', json=transcript).raise_for_status()
    with closing(sqlite3.connect(settings.database_path)) as db, db:
        db.execute('''CREATE TRIGGER fail_registration BEFORE INSERT ON learner_recordings
            BEGIN SELECT RAISE(ABORT, 'simulated database failure'); END''')
    assert upload(api, base).status_code == 503
    assert len(blobs) == 1
    with closing(sqlite3.connect(settings.database_path)) as db, db:
        assert db.execute('SELECT COUNT(*) FROM learner_recordings').fetchone() == (0,)
        db.execute('DROP TRIGGER fail_registration')
    assert upload(api, base).status_code == 201
    assert len(blobs) == 1


def test_owner_is_checked_before_upload_and_rechecked_before_registration(learner_turn, blobs, monkeypatch):
    api, settings, base, _ = learner_turn
    enable_recordings(settings)
    session = base.split('/')[2]
    with monkeypatch.context() as patch:
        patch.setitem(app.dependency_overrides, current_account, lambda: str(uuid4()))
        assert upload(api, base).status_code == 404
        assert not blobs

    original_put = recordings.RecordingStore.put

    def remove_session_after_put(store, recording, audio):
        original_put(store, recording, audio)
        with closing(sqlite3.connect(settings.database_path)) as db, db:
            db.execute('DELETE FROM practice_sessions WHERE id=?', (session,))

    monkeypatch.setattr(recordings.RecordingStore, 'put', remove_session_after_put)
    assert upload(api, base).status_code == 404
    with closing(sqlite3.connect(settings.database_path)) as db:
        assert db.execute('SELECT COUNT(*) FROM learner_recordings').fetchone() == (0,)


def test_backfill_compaction_and_orphan_sweep(learner_turn, blobs, monkeypatch):
    api, settings, base, _ = learner_turn
    session, turn = base.split('/')[2::2]
    audio = b'legacy' * 16000
    assert upload(api, base, audio).status_code == 201
    original_size = Path(settings.database_path).stat().st_size
    enable_recordings(settings)
    assert upload(api, base, audio).status_code == 200
    assert not blobs
    store = recordings.RecordingStore(settings)
    commands = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'scripts/manage_recordings.py'))
    assert commands['backfill'](settings.database_path, store, 1) == 1
    assert commands['backfill'](settings.database_path, store, 1) == 0
    commands['compact'](settings.database_path)
    assert Path(settings.database_path).stat().st_size < original_size
    reference = {'turn_id': turn, 'media_type': 'audio/wav', 'size_bytes': len(audio),
                 'sha256': hashlib.sha256(audio).hexdigest()}
    assert load_audio(settings.database_path, session, reference, recording_store=store) == audio

    orphan = recordings.Recording.for_upload(session, turn, b'orphan', 'audio/wav')
    store.put(orphan, b'orphan')
    racing_turn = str(uuid4())
    racing_recording = recordings.Recording.for_upload(session, racing_turn, b'racing', 'audio/wav')
    store.put(racing_recording, b'racing')
    candidates = list(blobs.values())
    monkeypatch.setattr(store, 'candidates', lambda cutoff: candidates)
    assert commands['sweep'](settings.database_path, store, datetime.now(timezone.utc)) == 2
    assert orphan.key in blobs

    def list_during_registration(cutoff):
        assert upload(api, base.rsplit('/', 1)[0] + '/' + racing_turn, b'racing').status_code == 201
        return candidates

    monkeypatch.setattr(store, 'candidates', list_during_registration)
    assert commands['sweep'](settings.database_path, store, datetime.now(timezone.utc), apply=True) == 1
    assert orphan.key not in blobs
    assert racing_recording.key in blobs
    assert len(blobs) == 2

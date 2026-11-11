"""Retrieve immutable audio and cache normalized assessments without holding HTTP locks."""
from app.storage.database import database_connection
from app.storage.recordings import Recording, ensure_recording_table
import hashlib
import sqlite3
from app.schemas import SpeechAssessment


def load_audio(database_path, session_id, reference, *, recording_store=None):
    with database_connection(database_path) as db:
        ensure_recording_table(db)
        row = db.execute('''SELECT t.audio, t.media_type, r.object_key, r.sha256, r.size_bytes
            FROM learner_turns t LEFT JOIN learner_recordings r USING (session_id, turn_id)
            WHERE t.session_id=? AND t.turn_id=?''', (session_id, reference['turn_id'])).fetchone()
    if row is not None and row[1] == reference['media_type']:
        audio, _, key, digest, size = row
        if key and (digest, size) == (reference['sha256'], reference['size_bytes']):
            if recording_store is None:
                raise sqlite3.OperationalError('Recording object storage is not configured.')
            return recording_store.read(Recording(key, digest, size))
        if key is None and audio is not None and len(audio) == reference['size_bytes'] and (
                hashlib.sha256(audio).hexdigest() == reference['sha256']):
            return audio
    raise sqlite3.DatabaseError('Audio no longer matches the evaluation snapshot')


def speech_cache(database_path, session_id, reference, assessment=None):
    with database_connection(database_path) as db:
        db.execute('''CREATE TABLE IF NOT EXISTS speech_assessments (
            session_id TEXT NOT NULL, turn_id TEXT NOT NULL, audio_sha256 TEXT NOT NULL,
            version TEXT NOT NULL, result TEXT NOT NULL,
            PRIMARY KEY(session_id, turn_id, audio_sha256, version)
        )''')
        key = (session_id, reference['turn_id'], reference['sha256'], 'en-US-unscripted-v1')
        if assessment is not None:
            db.execute('INSERT OR REPLACE INTO speech_assessments VALUES (?, ?, ?, ?, ?)',
                       (*key, assessment.model_dump_json()))
        row = db.execute('SELECT result FROM speech_assessments WHERE session_id=? AND turn_id=? '
                         'AND audio_sha256=? AND version=?', key).fetchone()
        return SpeechAssessment.model_validate_json(row[0]) if row else None

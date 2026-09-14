"""Retrieve immutable audio and cache normalized assessments without holding HTTP locks."""
from app.storage.database import database_connection
import hashlib
import sqlite3
from app.schemas import SpeechAssessment


def load_audio(database_path, session_id, reference):
    with database_connection(database_path) as db:
        row = db.execute('SELECT audio, media_type FROM learner_turns WHERE session_id=? AND turn_id=?',
                         (session_id, reference['turn_id'])).fetchone()
    if (row is None or row[0] is None or row[1] != reference['media_type']
            or len(row[0]) != reference['size_bytes']
            or hashlib.sha256(row[0]).hexdigest() != reference['sha256']):
        raise sqlite3.DatabaseError('Audio no longer matches the evaluation snapshot')
    return row[0]


def speech_cache(database_path, session_id, reference, assessment=None):
    with database_connection(database_path) as db:
        db.execute('''CREATE TABLE IF NOT EXISTS speech_assessments (
            session_id TEXT NOT NULL, turn_id TEXT NOT NULL, audio_sha256 TEXT NOT NULL,
            version TEXT NOT NULL, result TEXT NOT NULL,
            PRIMARY KEY(session_id, turn_id, audio_sha256, version)
        )''')
        key = (session_id, reference['turn_id'], reference['sha256'], 'en-US-unscripted-v1')
        if assessment is not None:
            db.execute('INSERT OR IGNORE INTO speech_assessments VALUES (?, ?, ?, ?, ?)',
                       (*key, assessment.model_dump_json()))
        row = db.execute('SELECT result FROM speech_assessments WHERE session_id=? AND turn_id=? '
                         'AND audio_sha256=? AND version=?', key).fetchone()
        return SpeechAssessment.model_validate_json(row[0]) if row else None

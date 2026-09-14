"""Atomic evaluation reservations with immutable inputs and fenced retries."""
from app.storage.database import database_connection
from datetime import datetime, timedelta, timezone
import hashlib
import json
import sqlite3
from uuid import uuid4

from app.schemas import EvaluationResponse
from app.storage.completeness import data_status_on_connection
from app.storage.sqlite import migrate_session_lifecycle

MAX_SNAPSHOT_BYTES = 200_000
RUBRIC_VERSION = 'unified-coaching-v3'


def evaluation_record(database_path, session_id, deployment=None):
    """Read a record, or reserve an attempt when deployment is supplied."""
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        if not migrate_session_lifecycle(db):
            return 'not_found', None, None
        session = db.execute(
            'SELECT status, upload_manifest, preferences FROM practice_sessions WHERE id=?',
            (session_id,),
        ).fetchone()
        if session is None:
            return 'not_found', None, None
        db.execute('''CREATE TABLE IF NOT EXISTS session_evaluations (
            session_id TEXT PRIMARY KEY, snapshot TEXT NOT NULL, record TEXT NOT NULL
        )''')
        row = db.execute('SELECT snapshot, record FROM session_evaluations WHERE session_id=?',
                         (session_id,)).fetchone()
        now = datetime.now(timezone.utc)
        if row:
            snapshot, encoded = row
            record = EvaluationResponse.model_validate_json(encoded)
            if deployment is None or record.status == 'completed':
                return 'existing', record, snapshot
            if record.status == 'running' and record.started_at > now - timedelta(minutes=5):
                return 'running', record, snapshot
            record = record.model_copy(update={
                'status': 'running', 'attempt_id': str(uuid4()), 'started_at': now,
                'completed_at': None, 'result': None, 'error_code': None,
            })
        else:
            if deployment is None:
                return 'not_found', None, None
            status = data_status_on_connection(db, session_id, session[0], session[1])
            if not status.ready_for_evaluation:
                return 'not_ready', None, None
            learners = [dict(turn_id=turn, **json.loads(transcript)) for turn, transcript in db.execute(
                'SELECT turn_id, transcript FROM learner_turns WHERE session_id=? AND transcript IS NOT NULL',
                (session_id,))]
            learners.sort(key=lambda item: (item['start_ms'], item['turn_id']))
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            agents = []
            if 'agent_transcripts' in tables:
                agents = [dict(item_id=item, content_index=index, **json.loads(transcript))
                          for item, index, transcript in db.execute(
                              'SELECT item_id, content_index, transcript FROM agent_transcripts '
                              'WHERE session_id=? ORDER BY item_id, content_index', (session_id,))]
            audio_refs = [dict(turn_id=turn, media_type=media, size_bytes=len(audio),
                               sha256=hashlib.sha256(audio).hexdigest())
                          for turn, media, audio in db.execute(
                              'SELECT turn_id, media_type, audio FROM learner_turns '
                              'WHERE session_id=? AND audio IS NOT NULL ORDER BY turn_id', (session_id,))]
            snapshot = json.dumps({'preferences': json.loads(session[2]),
                                   'manifest': json.loads(session[1]),
                                   'learner_transcripts': learners, 'agent_transcripts': agents,
                                   'audio_references': audio_refs},
                                  sort_keys=True, ensure_ascii=False)
            if len(snapshot.encode()) > MAX_SNAPSHOT_BYTES:
                return 'too_large', None, None
            record = EvaluationResponse(
                session_id=session_id, status='running', attempt_id=str(uuid4()), started_at=now,
                completed_at=None, rubric_version=RUBRIC_VERSION, deployment=deployment,
                input_sha256=hashlib.sha256(snapshot.encode()).hexdigest(), result=None, error_code=None,
            )
        db.execute('INSERT OR REPLACE INTO session_evaluations VALUES (?, ?, ?)',
                   (session_id, snapshot, record.model_dump_json()))
        return 'reserved', record, snapshot


def finish_evaluation(database_path, record, result=None, error_code=None, speech_assessments=None):
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT record FROM session_evaluations WHERE session_id=?',
                         (record.session_id,)).fetchone()
        current = EvaluationResponse.model_validate_json(row[0]) if row else None
        if current is None or current.attempt_id != record.attempt_id or current.status != 'running':
            return None
        completed = record.model_copy(update={
            'status': 'failed' if error_code else 'completed',
            'completed_at': datetime.now(timezone.utc), 'result': result, 'error_code': error_code,
            'speech_assessments': speech_assessments or [],
            'not_assessed': [] if any(a.status == 'assessed' for a in speech_assessments or [])
                            else ['pronunciation', 'spoken_fluency'],
        })
        db.execute('UPDATE session_evaluations SET record=? WHERE session_id=?',
                   (completed.model_dump_json(), record.session_id))
        return completed

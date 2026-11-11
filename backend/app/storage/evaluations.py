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

MAX_SNAPSHOT_BYTES = 10 * 1024 * 1024
RUBRIC_VERSION = 'staged-coaching-v4'


def conversation_context(learners, agents):
    """Order only evidence with offsets on the shared session recording clock."""
    timeline = [dict(role='learner', **turn) for turn in learners]
    untimed = []
    for part in agents:
        entry = dict(role='agent', **part)
        if part.get('start_ms') is None:
            untimed.append(entry)
        else:
            timeline.append(entry)
    # Ties are deterministic, not evidence of which speaker went first.
    timeline.sort(key=lambda entry: (
        entry['start_ms'], entry['role'],
        entry.get('turn_id', entry.get('item_id', '')), entry.get('content_index', 0)))
    return {'timeline': timeline, 'untimed_agent_transcripts': untimed}


def evaluation_record(database_path, session_id, account_id, deployment=None):
    """Read a record, or reserve an attempt when deployment is supplied."""
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        if not migrate_session_lifecycle(db):
            return 'not_found', None, None
        session = db.execute(
            'SELECT status, upload_manifest, preferences FROM practice_sessions WHERE id=? AND owner_account_id=?',
            (session_id, account_id),
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
                'transcript_status': ('completed' if record.transcript_result else 'running'),
                'final_status': 'pending',
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
            audio_refs = [dict(turn_id=turn, media_type=media,
                               size_bytes=size if digest is not None else len(audio),
                               sha256=digest if digest is not None else hashlib.sha256(audio).hexdigest())
                          for turn, media, audio, size, digest in db.execute('''
                              SELECT t.turn_id, t.media_type,
                                     CASE WHEN r.object_key IS NULL THEN t.audio END, r.size_bytes, r.sha256
                              FROM learner_turns t LEFT JOIN learner_recordings r USING (session_id, turn_id)
                              WHERE t.session_id=? AND (t.audio IS NOT NULL OR r.object_key IS NOT NULL)
                              ORDER BY t.turn_id''', (session_id,))]
            snapshot = json.dumps({'preferences': json.loads(session[2]),
                                   'manifest': json.loads(session[1]),
                                   'learner_transcripts': learners, 'agent_transcripts': agents,
                                   'conversation_context': conversation_context(learners, agents),
                                   'audio_references': audio_refs},
                                  sort_keys=True, ensure_ascii=False)
            if len(json.dumps({k: v for k, v in json.loads(snapshot).items()
                               if k != 'conversation_context'}, sort_keys=True,
                              ensure_ascii=False).encode()) > MAX_SNAPSHOT_BYTES:
                return 'too_large', None, None
            if 'evaluation_batch_plans' in tables:
                plan = db.execute('SELECT config FROM evaluation_batch_plans WHERE session_id=?',
                                  (session_id,)).fetchone()
                if plan:
                    deployment = json.loads(plan[0])['deployment']
            record = EvaluationResponse(
                session_id=session_id, status='running', attempt_id=str(uuid4()), started_at=now,
                completed_at=None, rubric_version=RUBRIC_VERSION, deployment=deployment,
                input_sha256=hashlib.sha256(snapshot.encode()).hexdigest(), result=None, error_code=None,
                transcript_status='running',
                speech_status='pending' if audio_refs else 'not_assessed', final_status='pending',
            )
        db.execute('INSERT OR REPLACE INTO session_evaluations VALUES (?, ?, ?)',
                   (session_id, snapshot, record.model_dump_json()))
        return 'reserved', record, snapshot


def save_transcript_evaluation(database_path, record, transcript_result):
    """Fence and persist the reusable transcript branch before final synthesis."""
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT record FROM session_evaluations WHERE session_id=?',
                         (record.session_id,)).fetchone()
        current = EvaluationResponse.model_validate_json(row[0]) if row else None
        if current is None or current.attempt_id != record.attempt_id or current.status != 'running':
            return None
        updated = current.model_copy(update={
            'transcript_status': 'completed', 'transcript_result': transcript_result,
        })
        db.execute('UPDATE session_evaluations SET record=? WHERE session_id=?',
                   (updated.model_dump_json(), record.session_id))
        return updated


def wait_for_speech(database_path, record, speech_assessments, speech_summary, pending_turn_ids):
    """Persist component progress and release the attempt for a later POST retry."""
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT record FROM session_evaluations WHERE session_id=?',
                         (record.session_id,)).fetchone()
        current = EvaluationResponse.model_validate_json(row[0]) if row else None
        if current is None or current.attempt_id != record.attempt_id or current.status != 'running':
            return None
        updated = current.model_copy(update={
            'status': 'waiting', 'speech_status': 'running',
            'speech_assessments': speech_assessments, 'speech_summary': speech_summary,
            'speech_pending_turn_ids': pending_turn_ids,
            'not_assessed': [] if any(a.status == 'assessed' for a in speech_assessments)
                            else ['pronunciation', 'spoken_fluency'],
        })
        db.execute('UPDATE session_evaluations SET record=? WHERE session_id=?',
                   (updated.model_dump_json(), record.session_id))
        return updated


def finish_evaluation(database_path, record, result=None, error_code=None,
                      speech_assessments=None, speech_summary=None, failure_stage='final'):
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
            'speech_summary': speech_summary,
            'speech_pending_turn_ids': [],
            'transcript_status': ('failed' if error_code and failure_stage == 'transcript'
                                  else record.transcript_status),
            'speech_status': ('not_assessed' if not speech_assessments else
                              'partial' if any(a.status == 'unavailable' for a in speech_assessments)
                              else 'completed'),
            'final_status': 'failed' if error_code else 'completed',
            'not_assessed': [] if any(a.status == 'assessed' for a in speech_assessments or [])
                            else ['pronunciation', 'spoken_fluency'],
        })
        db.execute('UPDATE session_evaluations SET record=? WHERE session_id=?',
                   (completed.model_dump_json(), record.session_id))
        return completed


def wait_for_transcript(database_path, record, total, completed):
    """Release a checkpointed attempt for the next POST; GET never advances work."""
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT record FROM session_evaluations WHERE session_id=?',
                         (record.session_id,)).fetchone()
        current = EvaluationResponse.model_validate_json(row[0]) if row else None
        if not current or current.attempt_id != record.attempt_id or current.status != 'running':
            return None
        updated = current.model_copy(update={
            'status': 'waiting', 'transcript_status': ('completed' if current.transcript_result else 'running'),
            'transcript_windows_total': total, 'transcript_windows_completed': completed})
        db.execute('UPDATE session_evaluations SET record=? WHERE session_id=?',
                   (updated.model_dump_json(), record.session_id))
        return updated

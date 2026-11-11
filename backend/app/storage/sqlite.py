"""Small SQLite helpers. No repository class is needed for one operation."""
import sqlite3
from app.storage.database import database_connection
from app.storage.recordings import Recording, ensure_recording_table, register_recording
from datetime import datetime, timedelta, timezone

from app.schemas import Session, SessionCreate


def migrate_session_lifecycle(connection: sqlite3.Connection) -> bool:
    """Called under an immediate transaction so concurrent migrations serialize."""
    if not connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='practice_sessions'"
    ).fetchone():
        return False
    columns = {row[1] for row in connection.execute("PRAGMA table_info(practice_sessions)")}
    for column in ("ended_at", "last_activity_at", "end_reason", "idempotency_key", "upload_manifest", "owner_account_id"):
        if column not in columns:
            connection.execute(f"ALTER TABLE practice_sessions ADD COLUMN {column} TEXT")
    connection.execute("UPDATE practice_sessions SET last_activity_at=created_at WHERE last_activity_at IS NULL")
    connection.execute("UPDATE practice_sessions SET end_reason='client_requested' "
                       "WHERE status='ended' AND end_reason IS NULL")
    connection.execute("DROP INDEX IF EXISTS session_idempotency_key")
    connection.execute("CREATE UNIQUE INDEX IF NOT EXISTS session_owner_idempotency_key "
                       "ON practice_sessions(owner_account_id, idempotency_key) "
                       "WHERE owner_account_id IS NOT NULL AND idempotency_key IS NOT NULL")
    return True


def touch_activity(connection: sqlite3.Connection, session_id: str) -> str:
    migrate_session_lifecycle(connection)
    now = datetime.now(timezone.utc).isoformat()
    connection.execute("UPDATE practice_sessions SET last_activity_at=? WHERE id=? AND status='active'",
                       (now, session_id))
    return now


def heartbeat_stored_session(database_path: str, session_id: str, account_id: str) -> tuple[str, str | None]:
    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        if not migrate_session_lifecycle(connection):
            return "not_found", None
        row = connection.execute("SELECT status FROM practice_sessions WHERE id=? AND owner_account_id=?", (session_id, account_id)).fetchone()
        if row is None:
            return "not_found", None
        if row[0] != "active":
            return "inactive", None
        return "active", touch_activity(connection, session_id)


def expire_inactive_sessions(database_path: str, timeout_seconds: int = 300) -> int:
    """End stale active rows atomically; failures propagate so scheduled runs can retry."""
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        if not migrate_session_lifecycle(connection):
            return 0
        now = datetime.now(timezone.utc)
        cutoff = (now - timedelta(seconds=timeout_seconds)).isoformat()
        return connection.execute(
            "UPDATE practice_sessions SET status='ended', ended_at=?, end_reason='inactivity_timeout' "
            "WHERE status='active' AND julianday(last_activity_at) <= julianday(?)",
            (now.isoformat(), cutoff),
        ).rowcount


def fail_stale_creating_sessions(database_path: str, timeout_seconds: int = 300) -> int:
    """Recover abandoned starts without allowing a late provider response to activate them."""
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        if not migrate_session_lifecycle(connection):
            return 0
        now = datetime.now(timezone.utc)
        return connection.execute(
            "UPDATE practice_sessions SET status='failed', ended_at=?, end_reason='creation_timeout' "
            "WHERE status='creating' AND julianday(created_at) <= julianday(?)",
            (now.isoformat(), (now - timedelta(seconds=timeout_seconds)).isoformat()),
        ).rowcount


def save_creating_session(database_path: str, session: Session, account_id: str,
                          idempotency_key: str | None = None) -> tuple[str, Session] | None:
    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("""
            CREATE TABLE IF NOT EXISTS practice_sessions (
                id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                preferences TEXT NOT NULL,
                provider_session_id TEXT
            )
        """)
        migrate_session_lifecycle(connection)
        if idempotency_key is not None:
            row = connection.execute(
                "SELECT id, status, created_at, preferences FROM practice_sessions "
                "WHERE owner_account_id=? AND idempotency_key=?",
                (account_id, idempotency_key),
            ).fetchone()
            if row is not None:
                previous = Session(id=row[0], status=row[1], created_at=row[2],
                                   preferences=SessionCreate.model_validate_json(row[3]))
                return ("replay" if previous.preferences == session.preferences else "conflict"), previous
        connection.execute(
            "INSERT INTO practice_sessions "
            "(id, status, created_at, preferences, provider_session_id, last_activity_at, idempotency_key, owner_account_id) "
            "VALUES (?, 'creating', ?, ?, NULL, ?, ?, ?)",
            (session.id, session.created_at.isoformat(), session.preferences.model_dump_json(),
             session.created_at.isoformat(), idempotency_key, account_id),
        )
        return None


def end_stored_session(database_path: str, session_id: str, account_id: str) -> tuple[str, str | None]:
    """Serialize end requests and preserve the first end timestamp, including on retries."""
    from datetime import datetime, timezone

    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        if not migrate_session_lifecycle(connection):
            return "not_found", None
        row = connection.execute(
            "SELECT status FROM practice_sessions WHERE id=? AND owner_account_id=?", (session_id, account_id)
        ).fetchone()
        if row is None:
            return "not_found", None
        if row[0] not in ("active", "ended"):
            return "inactive", None
        migrate_session_lifecycle(connection)
        if row[0] == "active":
            connection.execute(
                "UPDATE practice_sessions SET status='ended', ended_at=?, end_reason='client_requested' WHERE id=? AND owner_account_id=?",
                (datetime.now(timezone.utc).isoformat(), session_id, account_id),
            )
        ended_at = connection.execute(
            "SELECT ended_at FROM practice_sessions WHERE id=? AND owner_account_id=?", (session_id, account_id)
        ).fetchone()[0]
        if ended_at is None:
            raise sqlite3.DatabaseError("Ended session has no timestamp.")
        return "ended", ended_at


def update_session(database_path: str, session_id: str, status: str,
                   provider_session_id: str | None = None) -> None:
    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        cursor = connection.execute(
            "UPDATE practice_sessions SET status = ?, provider_session_id = ? WHERE id = ? AND status='creating'",
            (status, provider_session_id, session_id),
        )
        if cursor.rowcount != 1:
            raise sqlite3.DatabaseError("Session was not found.")
        if status == "active":
            touch_activity(connection, session_id)


def learner_session_outcome(connection, session_id, account_id):
    if not migrate_session_lifecycle(connection):
        return 'not_found'
    session = connection.execute(
        'SELECT status FROM practice_sessions WHERE id=? AND owner_account_id=?',
        (session_id, account_id),
    ).fetchone()
    if session is None:
        return 'not_found'
    if session[0] not in ('active', 'ended'):
        return 'inactive'
    return 'ok'


def store_learner_input(database_path: str, session_id: str, turn_id: str,
                        component: str, payload: bytes | str, account_id: str,
                        media_type: str | None = None, *, recording_store=None) -> tuple[str, bool, bool]:
    """Atomically store an immutable component or acknowledge an identical retry."""
    from datetime import datetime, timezone

    if component not in ("audio", "transcript"):
        raise ValueError("Unknown input component")
    recording = Recording.for_upload(session_id, turn_id, payload, media_type) if component == 'audio' else None
    if recording_store is not None:
        with database_connection(database_path) as connection:
            connection.execute('BEGIN IMMEDIATE')
            outcome = learner_session_outcome(connection, session_id, account_id)
            if outcome != 'ok':
                return outcome, False, False
            ensure_recording_table(connection)
            known = connection.execute('SELECT 1 FROM learner_recordings WHERE session_id=? AND turn_id=?',
                                       (session_id, turn_id)).fetchone()
            if not known and connection.execute("SELECT 1 FROM sqlite_master WHERE name='learner_turns'").fetchone():
                known = connection.execute('SELECT 1 FROM learner_turns WHERE session_id=? AND turn_id=? '
                                           'AND audio IS NOT NULL', (session_id, turn_id)).fetchone()
        if not known:
            recording_store.put(recording, payload)

    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        outcome = learner_session_outcome(connection, session_id, account_id)
        if outcome != 'ok':
            return outcome, False, False
        connection.execute("""
            CREATE TABLE IF NOT EXISTS learner_turns (
                session_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                audio BLOB,
                media_type TEXT,
                audio_received_at TEXT,
                transcript TEXT,
                transcript_received_at TEXT,
                PRIMARY KEY (session_id, turn_id),
                FOREIGN KEY (session_id) REFERENCES practice_sessions(id)
            )
        """)
        connection.execute(
            "INSERT OR IGNORE INTO learner_turns (session_id, turn_id) VALUES (?, ?)",
            (session_id, turn_id),
        )
        ensure_recording_table(connection)
        audio, saved_type, transcript, object_key, digest, size = connection.execute(
            '''SELECT t.audio, t.media_type, t.transcript, r.object_key, r.sha256, r.size_bytes
            FROM learner_turns t LEFT JOIN learner_recordings r USING (session_id, turn_id)
            WHERE t.session_id=? AND t.turn_id=?''',
            (session_id, turn_id),
        ).fetchone()
        audio_received = object_key is not None or audio is not None
        transcript_received = transcript is not None
        component_received = audio_received if component == 'audio' else transcript_received
        if component_received:
            if component == 'audio':
                same = saved_type == media_type and (
                    (digest, size) == (recording.sha256, recording.size) if object_key else audio == payload)
            else:
                same = transcript == payload
            if same:
                touch_activity(connection, session_id)
            return ("exists" if same else "conflict"), audio_received, transcript_received
        received_at = datetime.now(timezone.utc).isoformat()
        if component == "audio":
            if recording_store is not None:
                # Serialize verification and registration with orphan deletion. The upload itself is outside the lock.
                recording_store.verify(recording)
                register_recording(connection, session_id, turn_id, recording)
            connection.execute(
                "UPDATE learner_turns SET audio=?, media_type=?, audio_received_at=? "
                "WHERE session_id=? AND turn_id=?",
                (None if recording_store is not None else payload, media_type, received_at, session_id, turn_id),
            )
        else:
            connection.execute(
                "UPDATE learner_turns SET transcript=?, transcript_received_at=? "
                "WHERE session_id=? AND turn_id=?",
                (payload, received_at, session_id, turn_id),
            )
        touch_activity(connection, session_id)
        return "created", component == "audio" or audio_received, component == "transcript" or transcript_received


def store_agent_transcript(database_path: str, session_id: str, item_id: str,
                           content_index: int, payload: str, account_id: str) -> str:
    """Store one immutable provider content part, independent of arrival order."""
    from datetime import datetime, timezone

    with database_connection(database_path) as connection:
        connection.execute("BEGIN IMMEDIATE")
        if not migrate_session_lifecycle(connection):
            return "not_found"
        session = connection.execute(
            "SELECT status FROM practice_sessions WHERE id=? AND owner_account_id=?", (session_id, account_id)
        ).fetchone()
        if session is None:
            return "not_found"
        if session[0] not in ("active", "ended"):
            return "inactive"
        connection.execute("""
            CREATE TABLE IF NOT EXISTS agent_transcripts (
                session_id TEXT NOT NULL,
                item_id TEXT NOT NULL,
                content_index INTEGER NOT NULL,
                transcript TEXT NOT NULL,
                received_at TEXT NOT NULL,
                PRIMARY KEY (session_id, item_id, content_index),
                FOREIGN KEY (session_id) REFERENCES practice_sessions(id)
            )
        """)
        key = (session_id, item_id, content_index)
        existing = connection.execute(
            "SELECT transcript FROM agent_transcripts "
            "WHERE session_id=? AND item_id=? AND content_index=?", key,
        ).fetchone()
        if existing is not None:
            if existing[0] == payload:
                touch_activity(connection, session_id)
                return "exists"
            return "conflict"
        connection.execute(
            "INSERT INTO agent_transcripts VALUES (?, ?, ?, ?, ?)",
            (*key, payload, datetime.now(timezone.utc).isoformat()),
        )
        touch_activity(connection, session_id)
        return "created"

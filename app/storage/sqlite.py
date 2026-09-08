"""Small SQLite helpers. No repository class is needed for one operation."""
import sqlite3
from contextlib import closing
from pathlib import Path

from app.schemas import Session


def save_creating_session(database_path: str, session: Session) -> None:
    Path(database_path).parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(database_path)) as connection, connection:
        connection.execute("""
            CREATE TABLE IF NOT EXISTS practice_sessions (
                id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                preferences TEXT NOT NULL,
                provider_session_id TEXT
            )
        """)
        connection.execute(
            "INSERT INTO practice_sessions VALUES (?, 'creating', ?, ?, NULL)",
            (session.id, session.created_at.isoformat(), session.preferences.model_dump_json()),
        )


def update_session(database_path: str, session_id: str, status: str,
                   provider_session_id: str | None = None) -> None:
    with closing(sqlite3.connect(database_path)) as connection, connection:
        cursor = connection.execute(
            "UPDATE practice_sessions SET status = ?, provider_session_id = ? WHERE id = ?",
            (status, provider_session_id, session_id),
        )
        if cursor.rowcount != 1:
            raise sqlite3.DatabaseError("Session was not found.")


def store_learner_input(database_path: str, session_id: str, turn_id: str,
                        component: str, payload: bytes | str,
                        media_type: str | None = None) -> tuple[str, bool, bool]:
    """Atomically store an immutable component or acknowledge an identical retry."""
    from datetime import datetime, timezone

    if component not in ("audio", "transcript"):
        raise ValueError("Unknown input component")
    Path(database_path).parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(database_path)) as connection, connection:
        connection.execute("BEGIN IMMEDIATE")
        if not connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='practice_sessions'"
        ).fetchone():
            return "not_found", False, False
        session = connection.execute(
            "SELECT status FROM practice_sessions WHERE id = ?", (session_id,)
        ).fetchone()
        if session is None:
            return "not_found", False, False
        if session[0] != "active":
            return "inactive", False, False
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
        row = connection.execute(
            "SELECT audio, media_type, transcript FROM learner_turns WHERE session_id=? AND turn_id=?",
            (session_id, turn_id),
        ).fetchone()
        existing = row[0] if component == "audio" else row[2]
        if existing is not None:
            same = existing == payload and (component != "audio" or row[1] == media_type)
            return ("exists" if same else "conflict"), row[0] is not None, row[2] is not None
        received_at = datetime.now(timezone.utc).isoformat()
        if component == "audio":
            connection.execute(
                "UPDATE learner_turns SET audio=?, media_type=?, audio_received_at=? "
                "WHERE session_id=? AND turn_id=?",
                (payload, media_type, received_at, session_id, turn_id),
            )
        else:
            connection.execute(
                "UPDATE learner_turns SET transcript=?, transcript_received_at=? "
                "WHERE session_id=? AND turn_id=?",
                (payload, received_at, session_id, turn_id),
            )
        return "created", component == "audio" or row[0] is not None, component == "transcript" or row[2] is not None


def store_agent_transcript(database_path: str, session_id: str, item_id: str,
                           content_index: int, payload: str) -> str:
    """Store one immutable provider content part, independent of arrival order."""
    from datetime import datetime, timezone

    Path(database_path).parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(database_path)) as connection, connection:
        connection.execute("BEGIN IMMEDIATE")
        if not connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='practice_sessions'"
        ).fetchone():
            return "not_found"
        session = connection.execute(
            "SELECT status FROM practice_sessions WHERE id=?", (session_id,)
        ).fetchone()
        if session is None:
            return "not_found"
        if session[0] != "active":
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
            return "exists" if existing[0] == payload else "conflict"
        connection.execute(
            "INSERT INTO agent_transcripts VALUES (?, ?, ?, ?, ?)",
            (*key, payload, datetime.now(timezone.utc).isoformat()),
        )
        return "created"

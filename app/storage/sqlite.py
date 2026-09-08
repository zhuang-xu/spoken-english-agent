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

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.schemas import Session, SessionCreate, SessionPlan, SessionStatus, Speaker, TranscriptItem


class SessionRepository:
    def __init__(self, database_path: str):
        self.database_path = database_path
        db_path = Path(database_path)
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path)
        connection.row_factory = sqlite3.Row
        return connection

    def _init_db(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    preferences_json TEXT NOT NULL,
                    plan_json TEXT NOT NULL,
                    evaluation_json TEXT
                )
                """
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS transcript_items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    speaker TEXT NOT NULL,
                    text TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    FOREIGN KEY(session_id) REFERENCES sessions(id)
                )
                """
            )

    def create_session(self, session_id: str, preferences: SessionCreate, plan: SessionPlan) -> Session:
        now = datetime.now(timezone.utc)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO sessions (id, status, created_at, preferences_json, plan_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    session_id,
                    SessionStatus.active.value,
                    now.isoformat(),
                    preferences.model_dump_json(),
                    plan.model_dump_json(),
                ),
            )
        return Session(
            id=session_id,
            status=SessionStatus.active,
            created_at=now,
            preferences=preferences,
            plan=plan,
        )

    def get_session(self, session_id: str) -> Session | None:
        with self._connect() as connection:
            row = connection.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        if not row:
            return None
        return self._row_to_session(row)

    def add_transcript_item(
        self,
        session_id: str,
        speaker: Speaker,
        text: str,
        metadata: dict[str, Any] | None = None,
    ) -> TranscriptItem:
        now = datetime.now(timezone.utc)
        metadata = metadata or {}
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO transcript_items (session_id, speaker, text, created_at, metadata_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                (session_id, speaker.value, text, now.isoformat(), json.dumps(metadata)),
            )
        return TranscriptItem(speaker=speaker, text=text, created_at=now, metadata=metadata)

    def list_transcript(self, session_id: str) -> list[TranscriptItem]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT speaker, text, created_at, metadata_json
                FROM transcript_items
                WHERE session_id = ?
                ORDER BY id ASC
                """,
                (session_id,),
            ).fetchall()
        return [
            TranscriptItem(
                speaker=Speaker(row["speaker"]),
                text=row["text"],
                created_at=datetime.fromisoformat(row["created_at"]),
                metadata=json.loads(row["metadata_json"]),
            )
            for row in rows
        ]

    def complete_session(self, session_id: str, evaluation: dict[str, Any]) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE sessions
                SET status = ?, evaluation_json = ?
                WHERE id = ?
                """,
                (SessionStatus.completed.value, json.dumps(evaluation), session_id),
            )

    def _row_to_session(self, row: sqlite3.Row) -> Session:
        return Session(
            id=row["id"],
            status=SessionStatus(row["status"]),
            created_at=datetime.fromisoformat(row["created_at"]),
            preferences=SessionCreate.model_validate_json(row["preferences_json"]),
            plan=SessionPlan.model_validate_json(row["plan_json"]),
        )

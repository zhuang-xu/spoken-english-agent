"""Capture generated agent text without invoking a provider."""
import sqlite3

from fastapi import HTTPException

from app.config import Settings
from app.schemas import AgentTranscript, AgentTranscriptReceipt
from app.storage.sqlite import store_agent_transcript


def capture_agent_transcript(settings: Settings, session_id: str, item_id: str,
                             content_index: int, transcript: AgentTranscript
                             ) -> tuple[AgentTranscriptReceipt, int]:
    if transcript.previous_item_id == item_id:
        raise HTTPException(422, "An item cannot be its own predecessor.")
    start, end = transcript.start_ms, transcript.end_ms
    if ((start is None) != (end is None)
            or (start is not None and end < start)
            or (transcript.playback_status == "unknown" and start is not None)):
        raise HTTPException(422, "Provide paired, ordered playback offsets only for known playback.")
    try:
        outcome = store_agent_transcript(
            settings.database_path, session_id, item_id, content_index, transcript.model_dump_json()
        )
    except (sqlite3.Error, OSError):
        raise HTTPException(503, "Agent transcript storage is unavailable.") from None
    errors = {
        "not_found": (404, "Session was not found."),
        "inactive": (409, "Session is not active."),
        "conflict": (409, "This agent transcript is already stored with different content."),
    }
    if outcome in errors:
        raise HTTPException(*errors[outcome])
    return AgentTranscriptReceipt(
        session_id=session_id, item_id=item_id, content_index=content_index,
    ), 201 if outcome == "created" else 200

"""Store learner input components without invoking a model or transcribing audio."""
import sqlite3

from fastapi import HTTPException

from app.config import Settings
from app.schemas import LearnerInputReceipt
from app.storage.sqlite import store_learner_input

MAX_AUDIO_BYTES = 10 * 1024 * 1024
AUDIO_TYPES = {"audio/webm", "audio/ogg", "audio/wav", "audio/mp4", "audio/mpeg"}


def capture_input(settings: Settings, session_id: str, turn_id: str, component: str,
                  payload: bytes | str, media_type: str | None = None
                  ) -> tuple[LearnerInputReceipt, int]:
    try:
        outcome, audio_received, transcript_received = store_learner_input(
            settings.database_path, session_id, turn_id, component, payload, media_type
        )
    except (sqlite3.Error, OSError):
        raise HTTPException(503, "Learner input storage is unavailable.") from None
    errors = {
        "not_found": (404, "Session was not found."),
        "inactive": (409, "Session is not active."),
        "conflict": (409, "This learner input is already stored with different content."),
    }
    if outcome in errors:
        status, detail = errors[outcome]
        raise HTTPException(status, detail)
    return LearnerInputReceipt(
        session_id=session_id, turn_id=turn_id,
        audio_received=audio_received, transcript_received=transcript_received,
    ), 201 if outcome == "created" else 200

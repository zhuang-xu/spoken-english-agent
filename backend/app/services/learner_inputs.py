"""Store learner inputs and assess context-free audio as it arrives."""
import sqlite3

from fastapi import HTTPException

from app.config import Settings
from app.schemas import LearnerInputReceipt
from app.storage.sqlite import store_learner_input
from app.storage.recordings import RecordingStore
from app.services.pronunciation import assess_uploaded_audio

MAX_AUDIO_BYTES = 10 * 1024 * 1024
AUDIO_TYPES = {"audio/webm", "audio/ogg", "audio/wav", "audio/mp4", "audio/mpeg"}


def capture_input(settings: Settings, session_id: str, turn_id: str, component: str,
                  payload: bytes | str, account_id: str, media_type: str | None = None
                  ) -> tuple[LearnerInputReceipt, int]:
    try:
        recording_store = (RecordingStore(settings)
                           if component == 'audio' and settings.recordings_blob_container else None)
        outcome, audio_received, transcript_received = store_learner_input(
            settings.database_path, session_id, turn_id, component, payload, account_id, media_type,
            recording_store=recording_store,
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


def capture_audio(settings: Settings, session_id: str, turn_id: str, payload: bytes,
                  media_type: str, account_id: str) -> tuple[LearnerInputReceipt, int]:
    """Persist first, then synchronously evaluate pronunciation and fluency."""
    receipt, status = capture_input(
        settings, session_id, turn_id, "audio", payload, account_id, media_type)
    assess_uploaded_audio(payload, media_type, session_id, turn_id, settings)
    return receipt, status

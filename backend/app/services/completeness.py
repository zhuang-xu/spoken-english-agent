"""Final upload declarations and evaluation readiness; ending alone is never sufficient."""
import sqlite3

from fastapi import HTTPException

from app.config import Settings
from app.schemas import SessionDataStatus, UploadManifest
from app.storage.completeness import manifest_from_sets, manifest_sets, session_data_status


def get_data_status(settings: Settings, session_id: str, account_id: str,
                    manifest: UploadManifest | None = None) -> SessionDataStatus:
    if manifest is not None:
        parts = manifest_sets(manifest)
        if tuple(map(len, parts)) != (len(manifest.audio_turn_ids), len(manifest.transcript_turn_ids),
                                     len(manifest.agent_transcripts)):
            raise HTTPException(422, 'Upload manifest contains duplicate components.')
        manifest = UploadManifest.model_validate(manifest_from_sets(parts).model_dump())
    try:
        outcome, result = session_data_status(settings.database_path, session_id, account_id, manifest)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Session storage is unavailable.') from None
    errors = {
        'not_found': (404, 'Session not found.'),
        'inactive': (409, 'End the session before submitting its final upload manifest.'),
        'conflict': (409, 'A different final upload manifest is already stored.'),
    }
    if outcome in errors:
        raise HTTPException(*errors[outcome])
    return result

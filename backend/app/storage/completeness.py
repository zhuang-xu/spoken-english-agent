"""Compare a declared final upload inventory with a consistent snapshot of stored data."""
import sqlite3
from app.storage.database import database_connection

from app.schemas import SessionDataStatus, UploadInventory, UploadManifest
from app.storage.sqlite import migrate_session_lifecycle


def manifest_sets(manifest: UploadInventory) -> tuple[set, set, set]:
    return (set(map(str, manifest.audio_turn_ids)), set(map(str, manifest.transcript_turn_ids)),
            {(part.item_id, part.content_index) for part in manifest.agent_transcripts})


def manifest_from_sets(parts: tuple[set, set, set]) -> UploadInventory:
    return UploadInventory(
        audio_turn_ids=sorted(parts[0]), transcript_turn_ids=sorted(parts[1]),
        agent_transcripts=[{'item_id': item, 'content_index': index} for item, index in sorted(parts[2])],
    )


def session_data_status(database_path: str, session_id: str, manifest: UploadManifest | None = None
                        ) -> tuple[str, SessionDataStatus | None]:
    with database_connection(database_path) as connection:
        connection.execute('BEGIN IMMEDIATE')
        if not migrate_session_lifecycle(connection):
            return 'not_found', None
        row = connection.execute('SELECT status, upload_manifest FROM practice_sessions WHERE id=?',
                                 (session_id,)).fetchone()
        if row is None:
            return 'not_found', None
        status, saved = row
        if manifest is not None:
            if status != 'ended':
                return 'inactive', None
            payload = manifest.model_dump_json()
            if saved is not None and saved != payload:
                return 'conflict', None
            connection.execute('UPDATE practice_sessions SET upload_manifest=? WHERE id=?', (payload, session_id))
            saved = payload
        return "ok", data_status_on_connection(connection, session_id, status, saved)


def data_status_on_connection(connection, session_id, status, saved):
    actual = (set(), set(), set())
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if 'learner_turns' in tables:
        for turn, audio, transcript in connection.execute(
            'SELECT turn_id, audio IS NOT NULL, transcript IS NOT NULL FROM learner_turns WHERE session_id=?',
            (session_id,),
        ):
            if audio:
                actual[0].add(turn)
            if transcript:
                actual[1].add(turn)
    if 'agent_transcripts' in tables:
        actual[2].update(connection.execute(
            'SELECT item_id, content_index FROM agent_transcripts WHERE session_id=?', (session_id,)))
    expected = manifest_sets(UploadManifest.model_validate_json(saved)) if saved else (set(), set(), set())
    missing = tuple(wanted - stored for wanted, stored in zip(expected, actual))
    unexpected = tuple(stored - wanted for wanted, stored in zip(expected, actual))
    complete = saved is not None and not any(missing) and not any(unexpected)
    return SessionDataStatus(
        session_id=session_id, session_status=status, manifest_received=saved is not None,
        data_complete=complete, ready_for_evaluation=status == 'ended' and complete and bool(actual[1]),
        missing=manifest_from_sets(missing), unexpected=manifest_from_sets(unexpected),
    )

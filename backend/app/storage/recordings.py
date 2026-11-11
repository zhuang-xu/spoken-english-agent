"""Immutable learner recordings and their committed SQLite references."""
from dataclasses import dataclass
import hashlib
import os
import sqlite3

from azure.core import MatchConditions
from azure.core.exceptions import AzureError, ResourceExistsError, ResourceModifiedError, ResourceNotFoundError
from azure.storage.blob import BlobClient, ContainerClient
from app.storage.database import ensure_sqlite_table

PREFIX = 'learner-recordings/v1/'


@dataclass(frozen=True)
class Recording:
    key: str
    sha256: str
    size: int

    @classmethod
    def for_upload(cls, session_id, turn_id, audio, media_type):
        digest = hashlib.sha256(audio).hexdigest()
        mime_digest = hashlib.sha256((media_type or '').encode()).hexdigest()
        return cls(f'{PREFIX}{session_id}/{turn_id}/{digest}-{mime_digest}', digest, len(audio))


class RecordingStore:
    def __init__(self, settings):
        self.container = settings.recordings_blob_container
        self.connection_string = (settings.recordings_blob_connection_string.get_secret_value()
                                  or os.environ.get('AzureWebJobsStorage'))
        if not self.container or not self.connection_string:
            raise sqlite3.OperationalError('Recording object storage is not configured.')

    def _blob(self, key):
        return BlobClient.from_connection_string(self.connection_string, self.container, key,
                                                 retry_total=2, connection_timeout=10, read_timeout=20)

    def put(self, recording, audio):
        try:
            with self._blob(recording.key) as blob:
                try:
                    blob.upload_blob(audio, overwrite=False, metadata={'sha256': recording.sha256})
                except ResourceExistsError:
                    pass  # A retry may be registering an object from an earlier attempt.
        except (AzureError, ValueError):
            raise sqlite3.OperationalError('Recording object write failed.') from None

    def verify(self, recording):
        try:
            with self._blob(recording.key) as blob:
                properties = blob.get_blob_properties()
        except (AzureError, ValueError):
            raise sqlite3.OperationalError('Recording object verification failed.') from None
        if properties.size != recording.size or (properties.metadata or {}).get('sha256') != recording.sha256:
            raise sqlite3.OperationalError('Recording object does not match its reference.')

    def read(self, recording):
        try:
            with self._blob(recording.key) as blob:
                audio = blob.download_blob().readall()
        except (AzureError, ValueError):
            raise sqlite3.OperationalError('Recording object read failed.') from None
        if len(audio) != recording.size or hashlib.sha256(audio).hexdigest() != recording.sha256:
            raise sqlite3.OperationalError('Recording object does not match its reference.')
        return audio

    def candidates(self, cutoff):
        with ContainerClient.from_connection_string(self.connection_string, self.container,
                                                     retry_total=2, connection_timeout=10, read_timeout=20) as container:
            for blob in container.list_blobs(name_starts_with=PREFIX):
                if blob.last_modified <= cutoff:
                    yield blob

    def delete_candidate(self, candidate):
        with self._blob(candidate.name) as blob:
            try:
                blob.delete_blob(etag=candidate.etag, match_condition=MatchConditions.IfNotModified)
            except (ResourceNotFoundError, ResourceModifiedError):
                return False
        return True


def ensure_recording_table(connection):
    ensure_sqlite_table(connection, '''CREATE TABLE IF NOT EXISTS learner_recordings (
        session_id TEXT NOT NULL, turn_id TEXT NOT NULL, object_key TEXT NOT NULL UNIQUE,
        sha256 TEXT NOT NULL, size_bytes INTEGER NOT NULL,
        PRIMARY KEY (session_id, turn_id),
        FOREIGN KEY (session_id, turn_id) REFERENCES learner_turns(session_id, turn_id)
    )''')


def register_recording(connection, session_id, turn_id, recording):
    connection.execute('''INSERT INTO learner_recordings
        (session_id, turn_id, object_key, sha256, size_bytes) VALUES (?, ?, ?, ?, ?)''',
        (session_id, turn_id, recording.key, recording.sha256, recording.size))

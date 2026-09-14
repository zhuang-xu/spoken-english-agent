"""Committed sessions survive isolated copies; concurrent writers cannot lose data."""
import sqlite3
from threading import Lock
from types import SimpleNamespace
import pytest
from azure.core.exceptions import ResourceExistsError, ServiceRequestError
from app.storage.database import database_connection

@pytest.fixture
def shared_blob(monkeypatch):
    from azure.storage.blob import BlobServiceClient
    class Blob:
        data = None
        failed = False
        lock = Lock()
        def upload_blob(self, data, overwrite=False, lease=None):
            if not overwrite and self.data is not None:
                raise ResourceExistsError('exists')
            if self.failed:
                raise ServiceRequestError('offline')
            self.data = data
        def acquire_lease(self, **kwargs):
            self.lock.acquire()
            return SimpleNamespace(renew=lambda: None, release=self.lock.release)
        def download_blob(self, **kwargs):
            return SimpleNamespace(readall=lambda: self.data)
    blob = Blob()
    class Service:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def get_blob_client(self, *args): return blob
    monkeypatch.setattr(BlobServiceClient, 'from_connection_string', lambda *a, **k: Service())
    monkeypatch.setenv('DATABASE_BLOB_CONNECTION_STRING', 'fake')
    return blob

PATH = 'azureblob://sessions/test.sqlite3'

def test_fresh_connections_see_committed_data_and_rollback(shared_blob):
    with database_connection(PATH) as db:
        db.execute('CREATE TABLE entries (value TEXT)')
        db.execute('INSERT INTO entries VALUES (?)', ('saved',))
    with pytest.raises(ValueError):
        with database_connection(PATH) as db:
            db.execute('INSERT INTO entries VALUES (?)', ('rolled back',))
            raise ValueError('cancel')
    with database_connection(PATH) as db:
        assert db.execute('SELECT value FROM entries').fetchall() == [('saved',)]

def test_upload_failure_does_not_report_a_committed_change(shared_blob):
    with database_connection(PATH) as db:
        db.execute('CREATE TABLE entries (value TEXT)')
    shared_blob.failed = True
    with pytest.raises(sqlite3.OperationalError):
        with database_connection(PATH) as db:
            db.execute('INSERT INTO entries VALUES (?)', ('not saved',))
    shared_blob.failed = False
    with database_connection(PATH) as db:
        assert db.execute('SELECT value FROM entries').fetchall() == []

def test_concurrent_connections_do_not_lose_updates(shared_blob):
    from concurrent.futures import ThreadPoolExecutor
    with database_connection(PATH) as db:
        db.execute('CREATE TABLE counts (value INTEGER)')
        db.execute('INSERT INTO counts VALUES (0)')
    def increment(_):
        with database_connection(PATH) as db:
            db.execute('UPDATE counts SET value=value+1')
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(increment, range(12)))
    with database_connection(PATH) as db:
        assert db.execute('SELECT value FROM counts').fetchone()[0] == 12

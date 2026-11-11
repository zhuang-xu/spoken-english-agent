"""Local SQLite, lease-protected Blob snapshots, and pooled PostgreSQL.

Each transaction downloads the latest database and publishes its committed state
before returning. Azure leases fence writers across processes and host restarts.
The snapshot path serializes database operations. PostgreSQL uses row-level locks.
"""
from app.startup_timing import stage
from contextlib import contextmanager, closing
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from urllib.parse import urlparse


def is_postgres(connection):
    return getattr(connection, 'postgresql', False) is True


def begin_write(connection):
    if not is_postgres(connection):
        connection.execute('BEGIN IMMEDIATE')


def lock_rows(connection, query, parameters):
    return connection.execute(query + (' FOR UPDATE' if is_postgres(connection) else ''), parameters)


def table_exists(connection, name):
    if is_postgres(connection):
        return connection.execute('SELECT to_regclass(?) IS NOT NULL', (name,)).fetchone()[0]
    return connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def ensure_sqlite_table(connection, ddl):
    if not is_postgres(connection):
        connection.execute(ddl)


@contextmanager
def database_connection(database_path):
    if str(database_path).startswith(('postgresql://', 'postgres://')):
        from app.storage.postgres import postgres_connection
        with postgres_connection(database_path) as connection:
            yield connection
        return
    if not str(database_path).startswith('azureblob://'):
        Path(database_path).parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(database_path)) as connection, connection:
            yield connection
        return

    from azure.core.exceptions import AzureError, HttpResponseError, ResourceExistsError
    from azure.storage.blob import BlobServiceClient

    location = urlparse(database_path)
    connection_string = os.environ.get('DATABASE_BLOB_CONNECTION_STRING') or os.environ.get('AzureWebJobsStorage')
    if not connection_string or not location.netloc or not location.path.strip('/'):
        raise sqlite3.OperationalError('Shared database storage is not configured.')
    try:
        with BlobServiceClient.from_connection_string(connection_string, retry_total=2,
                connection_timeout=10, read_timeout=20) as service:
            blob = service.get_blob_client(location.netloc, location.path.lstrip('/'))
            try:
                with stage('blob_ensure_exists'):
                    blob.upload_blob(b'', overwrite=False)
            except ResourceExistsError:
                pass
            deadline = time.monotonic() + 20
            with stage('blob_lease_wait'):
                while True:
                    try:
                        lease = blob.acquire_lease(lease_duration=60)
                        break
                    except HttpResponseError as error:
                        if error.status_code != 409 or time.monotonic() >= deadline:
                            raise
                        time.sleep(0.15)
            stop = threading.Event()
            lost = threading.Event()
            def renew():
                while not stop.wait(15):
                    try:
                        lease.renew()
                    except AzureError:
                        lost.set()
                        return
            worker = threading.Thread(target=renew, daemon=True)
            worker.start()
            try:
                with stage('blob_download'):
                    original = blob.download_blob(lease=lease).readall()
                with tempfile.TemporaryDirectory(prefix='spoken-db-') as folder:
                    path = Path(folder) / 'session.sqlite3'
                    path.write_bytes(original)
                    with closing(sqlite3.connect(path)) as connection:
                        with connection:
                            with stage('sqlite_work'):
                                yield connection
                    updated = path.read_bytes()
                    if lost.is_set():
                        raise sqlite3.OperationalError('Shared database lease was lost. Retry the request.')
                    if updated != original:
                        with stage('blob_upload'):
                            blob.upload_blob(updated, overwrite=True, lease=lease)
            finally:
                stop.set()
                worker.join(timeout=25)
                try:
                    with stage('blob_lease_release'):
                        lease.release()
                except AzureError:
                    pass  # A crashed/recycled worker's lease also expires after 60 seconds.
    except AzureError as error:
        raise sqlite3.OperationalError('Shared database storage is unavailable.') from error

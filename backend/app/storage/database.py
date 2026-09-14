"""SQLite locally; lease-protected Azure Blob snapshots for the private hosted app.

Each transaction downloads the latest database and publishes its committed state
before returning. Azure leases fence writers across processes and host restarts.
This serializes database operations and is intended for small, private deployments.
"""
from contextlib import contextmanager, closing
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from urllib.parse import urlparse


@contextmanager
def database_connection(database_path):
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
                blob.upload_blob(b'', overwrite=False)
            except ResourceExistsError:
                pass
            deadline = time.monotonic() + 20
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
                original = blob.download_blob(lease=lease).readall()
                with tempfile.TemporaryDirectory(prefix='spoken-db-') as folder:
                    path = Path(folder) / 'session.sqlite3'
                    path.write_bytes(original)
                    with closing(sqlite3.connect(path)) as connection:
                        with connection:
                            yield connection
                    updated = path.read_bytes()
                    if lost.is_set():
                        raise sqlite3.OperationalError('Shared database lease was lost. Retry the request.')
                    if updated != original:
                        blob.upload_blob(updated, overwrite=True, lease=lease)
            finally:
                stop.set()
                worker.join(timeout=25)
                try:
                    lease.release()
                except AzureError:
                    pass  # A crashed/recycled worker's lease also expires after 60 seconds.
    except AzureError as error:
        raise sqlite3.OperationalError('Shared database storage is unavailable.') from error

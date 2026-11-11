# Hosted session persistence and request diagnostics

## Scope and status

The private Azure app uses PostgreSQL and private Blob recording storage. The
November 11 cutover verified the import, recording hashes, and private runtime
access. A signed-in hosted learner journey and a production load comparison remain
open. See the [cutover record](releases/release-2026-11-11-postgres.md).

The original shared SQLite rollout was verified on September 13, 2026
(`a43e2f16-20fd-4033-b142-06126e03a385`). In that release, the
signed-in browser loaded the updated page and its End conversation control.
205 backend tests, 40 JavaScript tests, and a request-log privacy test passed.
The Chrome recording, save, retry, and automatic-feedback smoke test passed.
A real Azure test returned 201 for session creation, audio upload,
transcript upload and evaluation; a separate process returned 200 for the session
heartbeat. Speech returned insufficient evidence for the synthetic sample; the text
feedback result completed and was stored.
The HTTP endpoints and schemas remain unchanged. Session creation, uploads,
heartbeats, ending, manifests, evaluation snapshots/results and scheduled cleanup
must see the same committed state across Azure Function instances and restarts.

## Storage

### PostgreSQL

PostgreSQL went live in the private Azure deployment on November 11, 2026. See the
[cutover record](releases/release-2026-11-11-postgres.md). `DATABASE_URL` selects PostgreSQL, and an empty
setting selects the SQLite path in `DATABASE_PATH`. Run the versioned schema
migration with a schema owner before enabling the app. The runtime role needs
data access and schema-version read access. `POSTGRES_POOL_MAX_SIZE` sets the
connection cap per worker process and defaults to two. Size it against the total
worker count and the server's connection limit.

Ownership, idempotent creation, account quotas, upload receipts, manifests, and
evaluation progress retain their HTTP behavior. Session row locks serialize
related writes and snapshot creation. Evaluation work claims and budget updates
lock their session plan, while attempt and job tokens fence stale results.
Recording objects stay in the private Blob container.

`python scripts/migrate_postgres.py schema` applies schema migrations using the
`DATABASE_URL` supplied to the command. `import-sqlite` copies a quiesced source
from `DATABASE_PATH` into an empty PostgreSQL schema and verifies counts and
content digests per table before commit. The importer preserves legacy inline
audio and committed Blob references. The recording maintenance commands resolve
the active database from the same settings as the API.

During cutover set `DATABASE_MAINTENANCE=true` to reject learner requests before
any storage changes and pause timer writes. Pause orphan sweeps and stop all
SQLite writers before taking the final source. The old SQLite snapshot remains a
pre-cutover backup. Once PostgreSQL accepts writes, recovery must preserve those
writes. Any orphan sweep after cutover must use the active PostgreSQL database.

### SQLite and the Blob snapshot

Local paths in `DATABASE_PATH` retain local SQLite behavior. A path such as
`azureblob://spoken-sessions/sessions.sqlite3` selects a private Azure Blob snapshot.
`DATABASE_BLOB_CONNECTION_STRING` can select its account; otherwise the host's
`AzureWebJobsStorage` is used. The container must exist. No storage key reaches
the browser.

Each database operation obtains a 60-second blob lease before downloading the latest
snapshot into an isolated temporary directory. It runs the SQLite transaction and
uploads the committed database if the snapshot changed. A renewal thread
renews the lease every 15 seconds. Contention is retried for up to 20 seconds.
Azure enforces the lease on writes. Exceptions roll back without publishing;
storage or lost-lease errors become SQLite operational errors and the API's existing
503 response. The lease expires after a process crash. No instance-local cache is
authoritative.

Reads and writes through this legacy storage path wait for the same lease and
download the entire database, including any legacy inline recordings. The SQLite
Blob preserved at cutover is a frozen backup. The September rollout did not import
the earlier instance-local `/tmp` databases.

## Recording object storage

Phase 1 was deployed and enabled on the private Azure Function App on November
11, 2026. See the [release record](releases/release-2026-11-11.md). Set
`RECORDINGS_BLOB_CONTAINER` to enable object storage for new recordings. Use a
private container dedicated to this database and environment. Supply
`RECORDINGS_BLOB_CONNECTION_STRING` or use `AzureWebJobsStorage`. An empty container
setting keeps new recordings inline. A configured but unavailable object store
returns a retryable 503 for new audio writes.

The API verifies ownership before uploading and again before registering the
object. It creates an immutable object outside the registration transaction and
verifies its presence under the same session row lock used by orphan cleanup in
PostgreSQL. The committed reference
and turn receipt are written together. The database keeps the object key, SHA-256, byte
count, media type and receipt time. Identical retries can register a prior upload
after a database failure. Conflicting content still returns 409. Completeness and
evaluation accept both inline audio and committed object references. The final
evaluation uses the existing upload-time Speech cache.

The cutover backfilled and verified all 23 legacy recordings. For future
maintenance, run the applicable commands from the repository root with the
matching database and recording-container settings:

```sh
python scripts/manage_recordings.py backfill --limit 25
python scripts/manage_recordings.py sweep-orphans
python scripts/manage_recordings.py sweep-orphans --apply
```

Repeat backfill until it reports zero migrated rows. Each row keeps its inline
bytes until the uploaded object has passed a full size and SHA-256 check.
`python scripts/manage_recordings.py compact` applies to SQLite snapshots during
maintenance after backfill completes. Old backups and Blob versions follow their
existing retention settings.

The orphan sweep previews by default. With `--apply`, it rechecks the live
reference in a transaction and deletes only unchanged, unreferenced objects
under the recording prefix that are at least 24 hours old. Run it against the
authoritative database and its dedicated container. Pause sweeps during restore
and cutover. Deploy reader support to all workers before enabling object writes,
and retain that support in rollback builds once the database contains references.

## Diagnostics

HTTP logging records method, route template, status, elapsed milliseconds and
instance ID. It excludes bodies, transcripts, audio, query strings and credentials.
Azure diagnostic settings send FunctionAppLogs to the existing private storage
account. Historical errors before logging was enabled cannot be reconstructed.

## Acceptance mapping

- `test_shared_database.py`: fresh connections see saved data, rollback preserves
  the prior snapshot, upload failures fail the operation, concurrent increments
  cannot overwrite each other.
- `test_postgres_storage.py` uses real PostgreSQL to check concurrent reservations
  and quotas, evaluation claims, upload and manifest behavior, and SQLite import.
- Existing API suite: validation, immutable uploads, session lifecycle, manifest
  readiness, evaluation fencing and storage-error behavior remain intact.
- September SQLite rollout smoke: separate processes read the same new session.
  The test uploaded one synthetic answer, ended the session, and obtained an assessment.

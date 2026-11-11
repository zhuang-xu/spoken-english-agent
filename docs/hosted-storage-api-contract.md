# Hosted session persistence and request diagnostics

## Scope and status

Implemented and locally verified on September 13, 2026; Azure deployment succeeded (`a43e2f16-20fd-4033-b142-06126e03a385`).
The hosted app now selects shared storage and the Speech/text deployments. The
signed-in browser loaded the updated page and its End conversation control.
205 backend tests and 40 JavaScript tests pass; an additional request-log privacy
test also passes. The Chrome recording/save/retry/automatic-feedback
smoke test passes. A real Azure test returned 201 for session creation, audio upload,
transcript upload and evaluation; a separate process returned 200 for the session
heartbeat. Speech returned insufficient evidence for the synthetic sample; the text
feedback result completed and was stored.
The HTTP endpoints and schemas remain unchanged. Session creation, uploads,
heartbeats, ending, manifests, evaluation snapshots/results and scheduled cleanup
must see the same committed state across Azure Function instances and restarts.

## Storage

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

Reads and writes through this storage path wait for the same lease and download
the entire database, including any legacy inline recordings. This design serves
the private, low-volume deployment.
Existing `/tmp` sessions are not automatically migrated and may already be lost.
Users must start a new conversation after the hosting change.

## Recording object storage

Phase 1 was deployed and enabled on the private Azure Function App on November
11, 2026. See the [release record](releases/release-2026-11-11.md). Set
`RECORDINGS_BLOB_CONTAINER` to enable object storage for new recordings. Use a
private container dedicated to this database and environment. Supply
`RECORDINGS_BLOB_CONNECTION_STRING` or use `AzureWebJobsStorage`. An empty container
setting keeps new recordings in SQLite. A configured but unavailable object store
returns a retryable 503 for new audio writes.

The API verifies ownership before uploading and again before registering the
object. It creates an immutable object outside the database lease and verifies
its presence under the same lock used by orphan cleanup. The committed reference
and turn receipt are written together. SQLite keeps the object key, SHA-256, byte
count, media type and receipt time. Identical retries can register a prior upload
after a database failure. Conflicting content still returns 409. Completeness and
evaluation accept both inline audio and committed object references. The final
evaluation uses the existing upload-time Speech cache.

After verifying the new deployment against a private test container, run the
following maintenance commands from the repository root with the matching database
and recording-container settings:

```sh
python scripts/manage_recordings.py backfill --limit 25
python scripts/manage_recordings.py compact
python scripts/manage_recordings.py sweep-orphans
python scripts/manage_recordings.py sweep-orphans --apply
```

Repeat backfill until it reports zero migrated rows. Each row keeps its inline
bytes until the uploaded object has passed a full size and SHA-256 check. Compact
during a maintenance window after older writers have stopped and backfill is
complete. `compact` rebuilds and checks the current snapshot. Old backups and
Blob versions follow their existing retention settings.

The orphan sweep previews by default. With `--apply`, it rechecks the live
reference under the database lock and deletes only unchanged, unreferenced objects
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
- Existing API suite: validation, immutable uploads, session lifecycle, manifest
  readiness, evaluation fencing and storage-error behavior remain intact.
- Real Azure smoke: separate processes read the same newly created session;
  one synthetic answer is uploaded, ended, and assessed by Speech and text models.

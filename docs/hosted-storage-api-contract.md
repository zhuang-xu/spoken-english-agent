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

Each database operation obtains a 60-second blob lease, downloads the latest
snapshot into an isolated temporary directory, runs the existing SQLite transaction,
and uploads the committed database before returning success. A renewal thread
renews the lease every 15 seconds. Contention is retried for up to 20 seconds.
Azure enforces the lease on writes. Exceptions roll back without publishing;
storage or lost-lease errors become SQLite operational errors and the API's existing
503 response. The lease expires after a process crash. No instance-local cache is
authoritative. Unchanged snapshots are not uploaded.

The entire database is copied for each operation and writers serialize. This is
for the private, low-volume deployment, not a high-throughput database service.
Existing `/tmp` sessions are not automatically migrated and may already be lost.
Users must start a new conversation after the hosting change.

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

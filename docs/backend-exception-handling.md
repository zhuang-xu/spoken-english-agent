# Backend exception handling: session start to end

This is the original lifecycle failure analysis. It records validation errors,
provider and storage failures, retries, concurrency, and abandoned sessions.
For the current deployment, see the [architecture](architecture.md),
[account isolation contract](account-isolation-api-contract.md), and
[hosted storage contract](hosted-storage-api-contract.md).

An `active` session means Azure credentials were prepared. The client establishes
the WebRTC connection separately.

## 1. Starting a session

Endpoint: `POST /sessions`.

| Exception or failure | How the backend handles it | Result / client action |
|---|---|---|
| Missing or invalid preferences, unknown fields, or malformed JSON | Pydantic/FastAPI validates the request before the workflow runs. Strings are trimmed; field lengths and the integer duration range are enforced. | 422. Correct the request. |
| Wrong JSON content type | The JSON dependency requires `application/json`. | 415. Send the correct content type. |
| Missing Azure key/deployment or invalid Azure endpoint | Configuration is checked before creating a database row or contacting Azure. | 503 with a generic configuration message. Server configuration must be fixed. |
| Database failure before the provider call | SQLite/filesystem errors are caught. Azure is not called unless the creating row was saved. | 503. Retry after storage recovers. |
| Azure times out | The backend attempts to transition the creating row to failed. | 504 if that update succeeds; 503 if storage prevents recording the failure. |
| Azure rejects the request or returns malformed/expired credentials | HTTP and expected response-parsing errors are caught. The backend attempts to mark the row failed and does not return provider details or credentials. | 502 if the failure is recorded; 503 if the database update fails. |
| Azure succeeds but activation cannot be saved | The credential is withheld, and marking the row failed is attempted. A storage outage may leave a creating row for cleanup. | 503. The unused short-lived credential expires naturally. |
| Response is lost and the client retries | An optional `Idempotency-Key` is reserved atomically with the new session. The same key and normalized preferences identify the existing session without another Azure request. | 200 for active/failed/ended sessions, with `realtime: null`. See the replay rules below. |
| Two requests use the same key while creation is running | An immediate SQLite transaction and unique key index prevent duplicate reservations. | The competing request receives 409 with `Retry-After: 2`. Retry with the same key. |
| A key is reused with different preferences | The stored normalized preferences are compared with the new request. | 409. Use the original preferences or explicitly start a new session with a new key. |
| An idempotency key is invalid | The header must contain 1–200 ASCII letters, digits, underscores, or hyphens. | 422. Correct the header. |

### Credential-free replay

A keyed replay returns the current session, not the original credential response.
Credentials are not persisted or regenerated on retries. If the browser already
connected, it can continue using its connection. If the initial response was lost
or the credential expired before connection, starting a fresh connection requires
an explicit new session with a new key. A known active abandoned session can be
ended first; otherwise inactivity cleanup eventually ends it.

Requests without `Idempotency-Key` still create a new session on every retry.
Keys currently have global scope in this local-development API and remain stored
with their session rows. Replays still require valid Azure configuration.

## 2. Abandoned or delayed session creation

The Azure timer runs once per minute and checks for creating sessions at least
five minutes old.

| Exception or failure | How the backend handles it | Result |
|---|---|---|
| Process crashes after inserting a creating row | `fail_stale_creating_sessions()` compares `created_at` with the timeout cutoff. | The row becomes failed with `end_reason: creation_timeout`; `ended_at` records cleanup time. |
| Azure returns after cleanup has failed the row | Activation only updates rows whose current status is creating. | The stale row cannot reactivate; the credential is withheld and the request returns 503. |
| Cleanup runs repeatedly or concurrently | Cleanup uses an immediate transaction and only updates rows still in the target state. | Already failed rows remain unchanged. |

Cleanup does not cancel an Azure HTTP request already in flight. Five minutes is
the eligibility threshold; the actual transition occurs when a cleanup run executes.

## 3. Conversation activity and heartbeats

Endpoint: `POST /sessions/{session_id}/heartbeat`, with no request body.

| Exception or failure | How the backend handles it | Result / client action |
|---|---|---|
| Browser closes, loses network access, or never sends `/end` | Session activation, heartbeats, and successful uploads update server-owned `last_activity_at`. Cleanup ends active rows with no activity for at least five minutes. | The row becomes ended with `end_reason: inactivity_timeout`. |
| Temporary connection loss or browser suspension | The five-minute inactivity threshold provides a grace period. | Send heartbeats every 30 seconds while connected; resume if the session is still active. |
| Heartbeat targets an unknown session | The session is looked up before updating activity. | 404. |
| Heartbeat targets a creating, failed, or ended session | Only active rows can receive heartbeat activity. | 409. Do not reopen the old session; close its connection and start a new one when needed. |
| Heartbeat races with cleanup | Both operations serialize through immediate SQLite transactions. | A committed heartbeat before cleanup protects the session; cleanup first causes the later heartbeat to return 409. |
| Heartbeat storage fails | SQLite/filesystem exceptions are converted to a generic storage error. | 503. |

The backend does not directly observe browser–Azure audio traffic. Browser heartbeat
sending is still required: a real conversation can otherwise look inactive to the
backend. Ending a database row does not close WebRTC or stop Azure usage.

## 4. Learner audio and transcript uploads

Endpoints:

- `PUT /sessions/{session_id}/learner-turns/{turn_id}/audio`
- `PUT /sessions/{session_id}/learner-turns/{turn_id}/transcript`

| Exception or failure | How the backend handles it | Result / client action |
|---|---|---|
| Unsupported audio content type | The declared media type is checked against WebM, Ogg, WAV, MP4, and MPEG audio types. | 415. Use a supported declared type. |
| Recording exceeds 10 MiB | The request body is bounded while being read, before persistence. | 413. Reduce recording size. |
| Empty recording | Empty bytes are rejected before storage. | 422. |
| Invalid transcript or timing | Text, field types, IDs, and lengths are validated; learner `end_ms` must be greater than `start_ms`. | 422. |
| Unknown session or invalid UUID | Missing sessions return a storage outcome; malformed UUID paths fail request validation. | 404 for missing sessions; 422 for invalid UUIDs. |
| Upload targets a creating or failed session | Capture checks session status before storing input. | 409. |
| Audio and transcript arrive in different orders | Each component is stored independently under the same `(session_id, turn_id)`. | 201 for a new component; receipt flags show which components exist. |
| Upload response is lost and the client retries | Stored content is immutable. Identical bytes/media type or normalized transcript content are acknowledged. | 200. No duplicate component is created. |
| Retry contains different content | The existing component is compared before any replacement. | 409. Existing content is preserved. |
| Concurrent audio/transcript uploads | A transaction serializes lookup and write, avoiding lost components. | Both components can be stored without overwriting each other. |
| Database fails during a write | The transaction rolls back and the service returns a generic storage error. | 503. Retry the same component after recovery. |
| Upload arrives after session ending | Active and ended sessions accept uploads. | Late data is saved without changing the recorded end state, timestamp, or reason. |

Successful new uploads and identical retries refresh activity only for active
sessions. Invalid/conflicting uploads do not refresh it. The backend stores audio
bytes without decoding them; it does not verify that bytes match the declared codec.

## 5. Agent transcript uploads

Endpoint: `PUT /sessions/{session_id}/agent-items/{item_id}/transcripts/{content_index}`.

Agent uploads use the same missing-session, inactive-session, storage-failure,
immutable-retry, and late-upload handling as learner inputs.

| Exception or failure | How the backend handles it | Result |
|---|---|---|
| Invalid item ID, content index, text fields, or JSON type | Route/schema validation and the JSON dependency reject the request. | 422 for invalid data; 415 for wrong content type. |
| An item names itself as predecessor | The service rejects self-reference. | 422. |
| Playback offsets are incomplete, reversed, or supplied with unknown playback status | The service requires paired ordered offsets and known playback when offsets are provided. | 422. |
| Multiple text parts belong to one item | Storage keys include `content_index`. | Parts remain separate rather than overwriting one another. |
| Events arrive out of chronological order | Provider predecessor IDs and optional playback offsets are preserved; receipt order is not treated as conversation order. | Data is accepted. Full chronological reconstruction is still pending. |

Generated agent text can include speech the learner did not hear. Playback metadata
can represent interruption, but the backend does not itself observe audio playback.

## 6. Ending a session

Endpoint: `POST /sessions/{session_id}/end`, with no request body.

| Exception or failure | How the backend handles it | Result |
|---|---|---|
| Client sends `/end` more than once | The first transition stores server UTC `ended_at` and `client_requested` reason. Later calls read the existing timestamp. | 200 with the same timestamp. |
| Concurrent end requests | An immediate transaction serializes the transition. | One recorded end time; all successful callers receive it. |
| Explicit end follows inactivity timeout | An already ended row is returned without rewriting its reason or time. | 200; inactivity metadata is preserved. |
| Unknown session, invalid UUID, or creating/failed session | The route and storage validate identity/state. | 404, 422, or 409 respectively. |
| End write fails | Transaction rollback preserves the previous state; storage exceptions are mapped to a generic message. | 503. |
| Uploads are still in flight | Ending does not freeze uploads or claim completeness. | Late uploads remain accepted; readiness is checked separately. |

The browser must close its direct Azure connection separately. `/end` neither calls
Azure nor triggers evaluation.

## 7. Missing data before evaluation

Endpoints:

- `PUT /sessions/{session_id}/upload-manifest`
- `GET /sessions/{session_id}/data-status`

The manifest is the client's final list of expected learner audio, learner
transcripts, and agent transcript parts, including uploads still pending locally.

| Exception or failure | How the backend handles it | Result |
|---|---|---|
| Session ends without a final manifest | No assumption is made about whether all data arrived. | `manifest_received: false`, `data_complete: false`, `ready_for_evaluation: false`. |
| Manifest declares uploads that are missing | A consistent database snapshot is compared with the expected IDs. | 200 with missing components listed and readiness false. |
| Missing components arrive later | Status is derived from current stored data each time. | Readiness can become true once the inventory matches. |
| Undeclared components exist or arrive late | Extra components are reported as unexpected; they remain stored. | Completeness and readiness are false. |
| Manifest is submitted before the session ends | Only ended sessions accept the final declaration. | 409. |
| Duplicate identities, invalid IDs/indices, unknown fields, or oversized lists | The service validates uniqueness and the schema limits each request list to 1000 entries. All three lists are required. | 422. |
| Manifest is retried in a different ordering | Identities are normalized and sorted before comparison. | 200 for an identical inventory. |
| A different manifest replaces an existing one | The first manifest is immutable; transactional comparison prevents races. | 409. The original declaration is retained. |
| Session is explicitly empty | An empty declared inventory can match empty storage, but readiness also requires at least one learner transcript. | Data may be complete while evaluation readiness stays false. |
| Storage fails or the session is missing | Normal storage/error mapping applies. | 503 or 404. |

`ready_for_evaluation` requires an ended session, a matching final inventory, and
at least one learner transcript. This flag describes a snapshot; it does not start
an evaluation job. A future worker must check readiness and capture evaluation
input atomically. A client declaration cannot prove that all spoken audio was
captured, and omitted component types are not automatically required.

## 8. Scheduled cleanup and storage limitations

The Azure timer executes once per minute. It first ends inactive active sessions,
then fails stale creating sessions. Exceptions propagate to the Functions host so
the invocation is recorded as failed; later runs can process remaining stale rows.
There is no custom cleanup-lag alert or independent fallback scheduler yet.

The timer requires `AzureWebJobsStorage`. Plain Uvicorn does not execute Functions
timer triggers. The hosted timer uses the same PostgreSQL database as the learner
routes. During maintenance it pauses writes.

Schema additions are transactional and additive. Existing sessions receive lifecycle
columns, with activity backfilled from creation time. Consequently, an old active
session with no new activity may be eligible for cleanup immediately after migration.

## 9. Common HTTP response conventions

| Status | Meaning in these APIs |
|---|---|
| 200 | Successful heartbeat/end/status/manifest request, identical upload retry, or credential-free keyed start replay |
| 201 | Newly created session with credential, or newly stored upload component |
| 404 | Session does not exist |
| 409 | State conflict, immutable-content conflict, or keyed creation still in progress |
| 413 | Audio body exceeds the upload limit |
| 415 | Unsupported content type |
| 422 | Request/path/header validation failed |
| 502 | Azure request or credential response failed |
| 503 | Required configuration/storage unavailable, or creation transition could not complete |
| 504 | Azure request timed out and failure state was recorded |

Application errors use FastAPI's `detail` field. Validation errors contain structured
field details; explicit service errors use generic messages. Provider payloads,
storage exception details, and credentials are not included in those service errors.
Successful lifecycle and upload responses include `Cache-Control: no-store`.
Hosted HTTP routes retain Azure function-key protection; that protection is not
per-user authentication or session ownership enforcement.

## 10. Still not handled automatically

- Per-user authentication, ownership checks, and user-scoped idempotency keys.
- Rate limiting, aggregate session storage quotas, and retention/deletion.
- Direct detection or termination of the browser–Azure connection.
- Automatic credential refresh or recovery of a lost credential response.
- Explicit transcription-failure records and missing-data recovery.
- Corrections to an immutable final manifest or evaluation with partial data.
- Conversation ordering reconstruction and evaluation execution.
- Guaranteed handling of every unexpected programming/runtime exception; only the
  expected provider, storage, validation, and lifecycle cases above are mapped.

## Implementation and verification references

- [Session service](../backend/app/services/sessions.py): configuration, provider errors, keyed retries, heartbeats, ending.
- [SQLite storage](../backend/app/storage/sqlite.py): atomic state changes, key reservation, uploads, migrations, cleanup.
- [Completeness service](../backend/app/services/completeness.py) and [storage](../backend/app/storage/completeness.py): final inventory and readiness.
- [API routes](../backend/app/main.py) and [schemas](../backend/app/schemas.py): request validation and response contracts.
- [Azure Functions entry point](../backend/function_app.py): scheduled cleanup.
- [Recovery and completeness contract](session-recovery-and-completeness.md): client request/response examples.

The latest backend run before this documentation change passed 127 tests. Relevant
coverage includes session creation, ending, heartbeat activity, concurrent keyed
starts, stale-creation recovery, late uploads, and manifest completeness. Tests use
mocked provider HTTP and real temporary SQLite databases; they do not prove hosted
scheduler execution or a live browser–Azure connection.

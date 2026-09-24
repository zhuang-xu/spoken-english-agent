# Learner evaluation input capture contract

Prerequisite: an active session created using the
[session-start contract](sessions-api-contract.md).

Scope: receive learner recordings and finalized learner transcripts from the client,
and start the context-free pronunciation/fluency assessment when audio arrives.

- Client generates one UUID `turn_id` per push-to-talk utterance and reuses it for
  both uploads. `session_id` is the UUID returned by session creation.
- `PUT /sessions/{session_id}/learner-turns/{turn_id}/audio` accepts raw binary
  audio with Content-Type audio/webm, audio/ogg, audio/wav, audio/mp4, or audio/mpeg.
  MIME parameters (such as codecs) are preserved, normalized to lowercase.
  Empty bodies return 422; bodies above 10 MiB return 413, including streamed bodies.
  The server stores bytes before Speech-state work. When Azure Speech is configured,
  it decodes and assesses the recording synchronously without conversation context.
  Otherwise it caches a terminal `not_configured` unavailable result.
- `PUT /sessions/{session_id}/learner-turns/{turn_id}/transcript` accepts JSON:
  `text` (trimmed, 1–20000 characters), `start_ms` and `end_ms` (strict nonnegative
  integers relative to the client session recording clock; end must exceed start),
  and optional `provider_item_id` (trimmed, 1–200 characters). Extra fields, including
  a speaker field, are rejected. This route only represents learner speech.
- Components may arrive in either order. SQLite stores audio BLOB, MIME type,
  canonical transcript JSON, and separate server receipt timestamps in one row
  keyed by session and turn. Client timestamps establish order, not arrival time.
- New components return 201; identical normalized retries return 200. Different
  content for an already stored component returns 409 without overwriting it.
  Writes and retry checks are transactional. Neither upload changes session status.
- Response: `session_id`, `turn_id`, `audio_received`, `transcript_received`.
  Both flags true means inputs were received. Assessment results are returned with
  the final session evaluation rather than the upload receipt.
  Responses have Cache-Control: no-store and never echo recording or transcript.
- Unknown sessions return 404, non-active sessions 409, invalid UUIDs/input 422,
  unsupported content types 415, and storage failures 503 with generic detail.
  With Speech configured, invalid audio returns 422 after durable capture; Speech
  provider failure is saved as unavailable without failing the upload. A fresh
  database with no sessions returns 404.
- Hosted requests inherit Azure function-key protection. Local routes have no user
  authentication; ownership checks, retention/deletion, per-session storage quotas,
  durable cloud storage, and audio download/list endpoints remain deferred.
- SQLite is local-development storage. Audio increases database size; do not rely
  on the hosted temporary SQLite path for retaining recordings across instances.

## Capture acceptance and test mapping

`backend/tests/test_learner_inputs.py` covers both arrival orders, exact persisted bytes and
transcript metadata, retries/conflicts, input limits, unknown/inactive sessions,
transaction failure responses, and configured/unconfigured provider behavior.
Tests also cover simultaneous component writes, duplicate races, transaction rollback,
and isolation between sessions sharing a turn ID.

Verified locally on 2026-09-08 using Python 3.11.6: 62 tests passed, including
21 learner-input tests; one existing Starlette/AnyIO deprecation warning.
`git diff --check` passed. No live transcription, browser recording, or Azure
upload check was performed for this feature. This increment is not deployed or
published to GitHub.


## Azure release verification — 2026-09-08

Deployed to `spoken-agent-func-4fa2534c` with a Python 3.11 remote build;
Azure deployment command completed successfully. Deployment ID:
`d8872060-dc1d-4e8e-b07f-1884168941d8`.

The full local suite passed (81 tests). Hosted checks passed: unauthorized health
401, authenticated health/OpenAPI 200, invalid session 422, real Azure session
creation 201, learner WAV and transcript uploads 201, agent transcript upload 201,
identical retries 200, conflicting retries 409, invalid agent input 422, and
unknown session 404. Synthetic audio/text were used; no WebRTC conversation or
speech evaluation was tested. SQLite remains temporary at `/tmp/spoken_agents.sqlite3`.
Earlier local-only verification notes describe the pre-release state.

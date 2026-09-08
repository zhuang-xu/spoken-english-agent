# Conversation agent transcript capture

## Scope and API

Store finalized agent-generated transcript content sent by the browser. This is
backend ingestion, not a browser event listener or a server-side Realtime connection.
Related contracts: [session creation](todo-sessions-api-contract.md) and
[learner inputs](todo-learner-inputs-api-contract.md).

`PUT /sessions/{session_id}/agent-items/{item_id}/transcripts/{content_index}`

- Session ID is a UUID. Item ID is 1–200 ASCII letters, digits, underscores or
  hyphens. Content index is a nonnegative integer identifying a part within an item.
- JSON fields: `text` (trimmed, 0–20000 characters; empty allows cancelled output),
  `response_id` (trimmed, 1–200 characters), optional `previous_item_id` (same ID
  format as item ID), `playback_status` (unknown/completed/interrupted; default
  unknown), optional `start_ms` and `end_ms` (strict nonnegative integer playback
  offsets on the same client session clock as learner recordings).
- Offsets must be supplied together, with end >= start. Unknown playback must
  omit offsets. Self-referencing previous item IDs and extra fields return 422.
- The previous item relationship comes from conversation item metadata, not from
  transcript arrival order. Predecessors may arrive later or never be captured
  (for example a tool item). No foreign key or adjacency guarantee is imposed.
- This stores generated text, not a verified record of everything the user heard.
  The browser should wait for final playback/interruption information before upload
  if it wants to supply that information. Unknown is permitted. Do not infer
  completed playback from a transcript completion event.

## Persistence and responses

SQLite table `agent_transcripts` is keyed by session, provider item and content
index. It stores canonical JSON and a server receipt timestamp. Writes are atomic:
201 for a new part, 200 for an identical normalized retry, 409 for different content
at the same key. No overwrite or late metadata update is supported in this increment.
Unknown session: 404; inactive: 409; invalid input: 422; non-JSON: 415; storage: 503.
Responses contain session_id, item_id, content_index, transcript_received=true and
Cache-Control: no-store. No transcript content is returned or explicitly logged.
Neither session status nor learner input data changes. No provider calls are made.

Hosted requests inherit function-key protection; local user authentication and
ownership enforcement remain deferred. Existing DATABASE_PATH is used; hosted
SQLite remains temporary and unsuitable for durable production storage.

## Sequence and deferred work

Store provider predecessor relationships and content indices, plus client playback
offsets where known. These preserve ordering evidence even for reversed uploads;
receipt time is not conversation order. An ordered read endpoint, reconciliation
of missing relationships, browser capture, agent audio storage, evaluation, and
cloud deployment are outside this feature.

## Acceptance and verification

Tests cover persistence, reversed arrival, multiple parts, retries and conflicts,
validation, unknown/inactive sessions, concurrent retries, transaction failures,
and no provider calls during ingestion. Verification results follow implementation.

Verified locally on 2026-09-08: 81 tests passed under Python 3.11, including 19
agent-transcript tests, with one existing Starlette/AnyIO deprecation warning.
`git diff --check` passed. No live WebRTC or Azure checks were performed; no Azure
deployment or GitHub publication was made for this feature.


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

# Session recovery and data completeness

## Idempotent starts

`POST /sessions` accepts an optional `Idempotency-Key` header: 1–200 ASCII letters,
digits, underscores, or hyphens. Use a randomly generated UUID for each intended
new session and retain it across network retries. Requests without a key retain the
original behavior: every request creates a new session.

Keys are reserved in the same SQLite transaction that inserts the creating session.
A unique index and immediate transaction serialize concurrent requests. Comparison
uses validated, normalized preferences, including trimmed strings.

| Condition | Response |
|---|---|
| New key | 201, original `session` and `realtime` response |
| Same key and same preferences, still creating | 409 with `Retry-After: 2`; retry the same key |
| Same key and different preferences | 409; no provider call |
| Same key, same preferences, active/failed/ended | 200, current `session`, `realtime: null`; no provider call |
| Invalid header | 422 |

A replay identifies the existing session, but does not replay the original HTTP
response or credential. Credentials are never persisted, logged, regenerated on a
retry, or exposed by the replay. This behavior also applies after credential expiry
or process restart. A client that already connected can continue using its existing
connection. If it lost the initial credential response or needs a fresh connection,
it must explicitly create a new session with a new key. End a known active abandoned
session first, or allow inactivity cleanup to end it. Failed/ended sessions are not
reopened by retries. Replays still require valid server Azure configuration.

Keys are scoped globally to this local-development API and retained with session
rows. Per-user key scoping and retention must accompany future authentication and
session deletion. No automated credential refresh is implemented. A storage failure
after a provider response still withholds that credential; retries cannot duplicate
the same keyed application session.

## Abandoned creation recovery

The existing once-per-minute Azure timer now also calls
`fail_stale_creating_sessions()`. Creating rows at least five minutes old become
`failed`, with `end_reason: creation_timeout` and the cleanup time in `ended_at`.
The check uses `created_at`, not heartbeat activity. Fresh creating, active, ended,
and already failed rows are untouched; repeated cleanup is safe.

Activation and provider-failure updates only transition a row that is still
creating. If cleanup wins a race with a delayed provider response, the late response
cannot activate the failed row and its credential is withheld. The unused credential
expires naturally. Cleanup does not cancel an Azure request already in flight.

Both cleanup operations propagate storage failures to the Functions host. The timer
requires AzureWebJobsStorage, does not run under plain Uvicorn, and needs a shared
durable session database for reliable multi-instance hosting. Neither operation
terminates a direct browser–Azure WebRTC connection.

## Final upload inventory

After ending the session, send:

`PUT /sessions/{session_id}/upload-manifest`

```json
{
  "audio_turn_ids": ["10000000-0000-4000-8000-000000000001"],
  "transcript_turn_ids": ["10000000-0000-4000-8000-000000000001"],
  "agent_transcripts": [{"item_id": "item_agent_1", "content_index": 0}]
}
```

The manifest must list every intended upload, including components still in the
client upload queue. Each list allows up to 1000 entries; duplicate identities,
invalid IDs, unknown fields, and invalid indices return 422. Supply all three lists,
using empty lists when applicable. Learner audio and transcript lists are independent:
only declare components actually expected from the client capture configuration.

This is a final declaration: reordered identical retries return 200, different
manifests return 409. Active, creating, and failed sessions return 409. Missing
sessions return 404; non-JSON requests return 415; storage errors return 503.
A missing upload does not reject the declaration: the response reports it as missing.

`GET /sessions/{session_id}/data-status` returns the same status structure without
changing the manifest:

```json
{
  "session_id": "...",
  "session_status": "ended",
  "manifest_received": true,
  "data_complete": false,
  "ready_for_evaluation": false,
  "missing": {
    "audio_turn_ids": ["10000000-0000-4000-8000-000000000001"],
    "transcript_turn_ids": [],
    "agent_transcripts": []
  },
  "unexpected": {
    "audio_turn_ids": [],
    "transcript_turn_ids": [],
    "agent_transcripts": []
  }
}
```

Both endpoints return 200 and `Cache-Control: no-store` on success. Readiness is
calculated from a consistent database snapshot:

- No manifest means `data_complete: false`, including after an inactivity timeout.
- All declared components must exist, with no undeclared stored components.
- `ready_for_evaluation` additionally requires an ended session and at least one
  learner transcript. An explicitly empty session can be complete but not evaluable.
- Successful late uploads can satisfy missing entries. Late undeclared uploads remain
  accepted but invalidate completeness; the immutable manifest is not auto-expanded.
- Ending, registering a manifest, and reading status never fabricate missing text,
  run evaluation, or make a client declaration prove that every spoken word was captured.

The browser must send the manifest and query status; integration is pending. A future
evaluation worker must check readiness and capture its input snapshot atomically,
rather than rely on an earlier GET response. Permanent transcription/capture failures,
manifest corrections, partial-data evaluation policy, and evaluation jobs remain
outside this implementation; an incomplete abandoned session stays non-evaluable.

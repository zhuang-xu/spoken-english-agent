# Session evaluation API

## Scope and behavior

Implement one coherent English coaching report from transcript evidence and any
usable Azure Speech measurements, relative to the learner's stated level and goal.
Scores are formative
1–5 ratings (1 needs substantial work; 5 consistently effective), not certified
CEFR levels. Each category can return null when evidence is insufficient.
Transcript-only snapshots leave pronunciation and spoken fluency unassessed.
New snapshots with audio use upload-time [Azure Speech assessment](pronunciation-api-contract.md);
session completion reads cached Speech results. Raw audio is never sent to the
Azure OpenAI text endpoint and no Speech call occurs during final evaluation.

- `POST /sessions/{session_id}/evaluation`: no body; create a final result (201),
  return the saved result (200), or return persisted component progress (202 with
  Retry-After: 5) when transcript evaluation is complete but an expected Speech
  turn has not reached a terminal cached result. A failed attempt can be retried.
- `GET /sessions/{session_id}/evaluation`: return the saved status/result (200).
- UUID validation: 422. Missing session or evaluation: 404. Input not ready or an
  evaluation attempt already running: 409 (running includes Retry-After: 5).
  Oversized snapshot: 413.
- Missing/invalid Azure configuration or storage failure: 503. Azure OpenAI
  rejection, refusal, truncated/malformed output or invalid evidence: 502; text
  provider timeout: 504. Azure Speech provider/runtime failures are represented as
  unavailable per-turn assessments while transcript feedback continues.
- Success responses use Cache-Control: no-store. Hosted access uses the existing
  Azure Functions key; local routes have no per-user authentication.

Response fields: session_id, status (running/waiting/completed/failed), attempt_id,
started_at, completed_at (nullable), rubric_version, deployment, input_sha256,
result (nullable), error_code (nullable); transcript_status, speech_status and
final_status; reusable transcript_result; speech_pending_turn_ids;
speech_assessments (default empty); and
speech_summary (nullable deterministic pronunciation/fluency averages and coverage).
Result contains summary; grammar,
vocabulary and coherence objects (score and feedback); one to three cross-category
strengths; one to three ranked cross-category next_steps;
and corrections (turn_id, original, improved, explanation). Corrections must quote
an exact substring of the referenced learner transcript. Pronunciation and spoken
fluency remain in `not_assessed` unless at least one audio turn was assessed.
Provider diagnostics are never exposed.

## Snapshot and retries

Readiness and snapshot capture occur in the same SQLite write transaction, reusing
the completeness rules in [the completeness contract](session-recovery-and-completeness.md).
Persist one immutable input snapshot per session, its SHA-256, rubric version and
configured deployment. Snapshot includes preferences, manifest and learner/agent
transcripts with IDs and timing/playback metadata plus audio hashes/references,
never credentials or inline audio bytes. Audio hashes link the snapshot to cached
upload-time Speech assessments; audio bytes are not read during session evaluation.
Learner entries sort by start time then turn ID; agent entries sort by item/content
ID; these separate lists do not imply reliable inter-speaker conversation order.
Reject snapshots over 200,000 UTF-8 bytes rather than silently truncating.

Commit the running reservation before calling Azure; no database lock spans HTTP.
Persist the transcript result before inspecting the Speech completion barrier. If
an audio hash has no terminal cache row, save status `waiting` and return 202. A
later POST claims a new fenced attempt, reuses transcript_result, and performs final
synthesis when all expected audio hashes have terminal results.
Concurrent requests cannot start a second live attempt. Failed attempts and running
attempts older than five minutes may be explicitly retried with a new attempt ID,
using the original snapshot and deployment. A superseded attempt cannot write its
result. Retries after crashes may repeat a paid provider call; exactly-once billing
is not guaranteed. There is no automatic background finalizer; POST advances waiting
work and GET is read-only.
Late uploads retain their existing behavior but never change a reserved snapshot.
Completed results remain retrievable even if later uploads change data readiness.

## Provider

Use Azure `/openai/v1/chat/completions`, resource `api-key`, a separate
`AZURE_OPENAI_EVALUATION_DEPLOYMENT`, strict JSON-schema output and local validation.
Use a 60-second HTTP timeout and limit completion output to 4000 tokens. Treat all
preferences and transcripts as untrusted data, not instructions. Never infer audible
playback from generated agent text or pronunciation/fluency from transcript timing.
For rubric `staged-coaching-v4`, the first structured-output call evaluates only
transcript evidence and grounded corrections. When usable Speech evidence exists,
a second, smaller structured-output call receives the saved transcript evaluation,
preferences and bounded Speech findings and emits only final summary, strengths and
ranked priorities. Grammar, vocabulary, coherence and corrections are copied unchanged
from transcript_result. Without usable Speech evidence, transcript_result is the final
result and no synthesis call is made. Azure Speech remains authoritative for acoustic
measurements.
It must not emit a separate pronunciation report, invent acoustic claims, or treat
application averages as certified proficiency or Azure whole-session scores.

Reference: [Azure structured outputs](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/structured-outputs).
Current resource inspection found only gpt-realtime-2.1 version 2026-07-07; a compatible
text deployment must be configured separately. No resource creation is included.

## Verification and deferred work

The original transcript implementation and acceptance-test mapping are recorded below.
The pronunciation contract describes the later audio extension, additional error
codes, per-turn caching and bounded Speech processing before the text provider call.
Deferred: durable cross-instance Speech queue, automatic background finalization,
re-evaluation/version selection, durable shared hosting storage, per-user access,
real-provider quality calibration, Azure deployment and GitHub publication.

## Implemented and verified — 2026-09-10

Implemented both routes, schemas, Azure provider adapter, SQLite snapshot/reservation
and completion fencing, explicit retries, sanitized errors and configuration docs.

| Acceptance case | Test coverage |
|---|---|
| Create/read/replay; no repeat provider call; no stored credentials | `test_create_read_replay` |
| Invalid UUID, unknown/active/incomplete/empty session | `test_not_ready_and_validation`, `test_ended_but_not_evaluable` |
| Missing key/deployment, invalid endpoint | `test_configuration`, `test_missing_key` |
| Provider timeout/rejection/refusal/truncation/malformed data; retry | `test_provider_failure_and_retry`, `test_malformed_envelope` |
| Invalid scores, invented quotes/turns, blank feedback, extra fields | `test_invalid_result` |
| Concurrent reservation, running status, stale retry and fencing | `test_concurrent_reservation_and_stale_fencing` |
| Original inputs/deployment retained despite late uploads | `test_late_upload_preserves_snapshot` |
| Snapshot size limit and storage failures | `test_oversized_snapshot`, `test_storage_failure`, `test_finish_storage_failure` |
| Azure endpoint/auth/schema and valid grounded correction | `test_azure_protocol`, `test_grounded_correction` |

Tests live in `backend/tests/test_evaluations.py` and
`backend/tests/test_evaluation_provider.py`; reusable fixtures live in `conftest.py`.
Python 3.11.6 full backend suite: **161 passed**, one existing Starlette/AnyIO
deprecation warning. Browser suite: **22 passed**. Dependency consistency and
`git diff --check` passed. Provider HTTP is mocked; no real evaluation call,
Azure deployment, resource creation, commit or GitHub push was performed.

## Staged transcript and final synthesis — 2026-09-24

- Added independently persisted transcript, Speech and final states. Transcript
  evaluation can finish first and return 202 while the final audio result is pending;
  the next POST reuses it and performs exactly the remaining synthesis stage.
- Synthesis failures retain transcript_result, so retries do not repeat the transcript
  provider call. Attempt IDs continue to fence stale writers.
- `test_transcript_finishes_while_last_speech_turn_is_pending` covers the completion
  race; `test_final_synthesis_retry_reuses_transcript_result` covers stage reuse;
  provider tests verify the distinct transcript and synthesis schemas.

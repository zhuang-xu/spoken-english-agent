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
  Retry-After: 5) while transcript windows, reduction, or Speech/final work remains. A failed attempt can be retried.
- `GET /sessions/{session_id}/evaluation`: return the saved status/result (200).
- UUID validation: 422. Missing session or evaluation: 404. Input not ready or an
  evaluation attempt already running: 409 (running includes Retry-After: 5).
  Oversized canonical snapshot: 413. Evaluation work budget exceeded: 422 with
  `evaluation_work_limit_exceeded` detail.
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

Readiness and snapshot capture occur in the same transaction. PostgreSQL locks
the session row during capture. SQLite uses an immediate write transaction. See
the [completeness contract](session-recovery-and-completeness.md).
Persist one immutable input snapshot per session, its SHA-256, rubric version and
configured deployment. Snapshot includes preferences, manifest and learner/agent
transcripts with IDs and timing/playback metadata plus audio hashes/references,
never credentials or inline audio bytes. Audio hashes link the snapshot to cached
upload-time Speech assessments; audio bytes are not read during session evaluation.
Learner entries sort by start time then turn ID; agent entries sort by item/content
ID; these separate lists do not imply reliable inter-speaker conversation order.
New snapshots also include `conversation_context`: a `timeline` combining learner
and timed agent entries with explicit `role`, sorted by shared session `start_ms`,
then role, turn/item ID and content index for deterministic ties. All original
timing and playback metadata is retained. Equal starts and overlapping intervals
do not establish speaker precedence. Agent entries without a start time remain in
`untimed_agent_transcripts`; their position is unknown. Generated or interrupted
agent text is never proof that the learner heard the whole text. Legacy immutable
snapshots retain the separate-list interpretation on retries.
Canonical snapshots may contain up to 10 MiB (10,485,760 UTF-8 bytes, inclusive).
Size is measured using sorted-key, non-ASCII-escaped JSON, excluding the derived
`conversation_context` copy. The full stored legacy-compatible snapshot still
contains that derived context; its physical storage size can exceed 10 MiB.
Above the canonical limit return 413 before final reservation or provider work;
previously captured source data and any early findings remain stored.

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
final work and GET is read-only. Active-session transcript work can advance in
upload background tasks and the hosted timer, as described below.
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

## Incremental evaluation and larger sessions — implemented, 2026-10-21

Finalized learner and agent transcript uploads schedule a best-effort background
wake after durable capture. At **200,000 UTF-8 bytes** of accumulated finalized
transcript evidence and preferences (compact sorted JSON, without audio, manifest
or derived timeline), incremental transcript evaluation starts while the session
is active. Audio uploads do not trigger transcript work. Provider configuration
must be present; missing configuration never prevents transcript capture.

The trigger is independent of a request's context limit. Once crossed, subsequent
uploads can advance one pending window even before another 200,000 bytes arrives.
Each upload wake or timer wake performs at most one provider call. The existing
hosted one-minute maintenance timer scans up to eight recently active sessions,
including sessions whose upload wake was lost. Local execution uses upload wakes
and final POSTs; it does not have an autonomous timer. No final scores are published
while the conversation is active.

### Context admission and source coverage

`EVALUATION_CONTEXT_CAPACITY` defaults to 32,768 and must be set no higher than the
actual deployed text model's context capacity (minimum configuration: 32,768). Admission uses a conservative UTF-8
byte upper bound for byte-level text models, rather than a model-specific tokenizer.
It counts serialized instructions, payload and schema, adds 1,024 for framing,
reserves 4,000 output tokens, and leaves the larger of 2,048 or 10% of capacity as
a safety margin. This deliberately underfills model context and makes no claim of
exact token usage. Apply the same admission to windows, reduction, aggregation,
legacy single-pass evaluation and final Speech synthesis. Context failures return
sanitized errors; no automatic truncation or unbounded overflow retries occur.

Build deterministic windows from learner turns ordered by shared-clock start time
and turn ID. Split oversized turns at sentence boundaries where possible, then at
Unicode character boundaries. Each segment records its original turn, source ID,
character offset and timing; no learner character is skipped or owned twice.
Attach bounded context-only excerpts from adjacent learner segments and up to four
nearest agent parts when space permits, preserving playback
status and unknown timing; flag omitted context. Agent text never supplies learner
scoring evidence. Equal timestamps and overlapping intervals retain uncertainty.

At session end, completeness and the final immutable snapshot still gate the final
report. Reconstruct windows from that snapshot. Content-addressed job identities
include the preparation configuration, instructions, schema and complete payload.
Unchanged early windows reuse their findings. Late learner or agent uploads can
change windows/context and require new findings; source IDs, rather than a timestamp
watermark, prevent late text from disappearing. Once final reservation exists,
upload wakes stop advancing live evidence. Late uploads cannot change final input.

### Structured findings and whole-session scoring

Each window returns bounded grammar/vocabulary/coherence observations of strengths,
difficulties and uncertainty, plus candidate corrections. Observations and corrections
must quote exact learner text with half-open Unicode offsets within their source
segment. Validate all source IDs, ranges and quotations before saving findings.
Findings are capped at six observations, three corrections and 6,500 serialized
UTF-8 bytes. Window outputs contain no session scores.

After all windows finish, verify complete learner-character coverage and merge
findings in chronological order. Deduplicate by turn, source span and category;
context repeated across windows cannot count twice. If evidence does not fit the
final scoring request, recursively reduce consecutive pairs (at most eight levels).
Reducers select existing observation/correction IDs; application code retains the
original findings and quotes, so reductions cannot rewrite source evidence.

The final aggregation prompt applies the shared 1–5 session rubric without averaging
batch scores. It weighs both successful language and errors, recurring patterns,
evidence complexity, uncertainty and supported change over time. It requests
supporting observation IDs and validated correction IDs. Reject invented IDs,
duplicate selections and non-null category scores lacking selected evidence for
that category. Restore selected corrections from the saved evidence index, including
exact original text. Final public result fields remain unchanged. Representative
selection is lossy; coverage establishes that every source span was processed,
not that every detail survives reduction or that the score is objectively correct.

Short sessions that fit context retain single-pass evaluation. Sessions at/above
the trigger, or whose full snapshot does not fit, use the batch pipeline. Save the
validated transcript_result before checking the existing Speech barrier. Batch-mode
aggregation returns a checkpointed 202 before a subsequent POST performs Speech/final
work. Usable Speech findings remain authoritative for acoustic claims; without usable
Speech evidence, return the saved transcript result directly.

### Persistence, bounded work and clients

`evaluation_batch_plans` pins preparation version, deployment and context budget;
`evaluation_batch_jobs` saves immutable payloads, validated outputs, hashes, leases
and sanitized failure state. One leased job per session and two provider calls per
process are allowed. Job leases last 120 seconds, exceeding the 60-second provider
timeout. Lease tokens fence stale writers. A crash can still repeat a paid call;
exactly-once billing is not guaranteed.

Background wakes do not automatically retry a failed job. A final POST explicitly
retries unfinished failed work, while successful jobs are reused. Requests release
the final attempt at each transcript checkpoint so the next POST need not wait for
the five-minute stale-attempt timeout. GET remains read-only. Response adds
`transcript_windows_total` and `transcript_windows_completed` (default zero).
The browser advances waiting work every five seconds, up to 256 POSTs per invocation,
and stops on account invalidation. Other clients can advance using the same 202 and
Retry-After contract. Checkpoint POSTs retain the general account request quota but
do not consume another session-evaluation quota once a reservation exists.

Bounds: at most 128 leaf windows, eight reduction levels and 256 claimed provider
calls per session, including failed/replaced early work. Preflight reserves a
worst-case binary reduction tree plus final aggregation and Speech synthesis; plans
that exceed this budget return 422 `evaluation_work_limit_exceeded` before starting
new calls. Consequently the worst-case preflight allows at most 127 windows. Late
arrivals and retries consume the same session budget and may exhaust it. The 10 MiB
storage allowance does not guarantee that every input fits the evaluation work budget.
Existing upload limits remain unchanged. Hosted timer scans are bounded and may
leave busy sessions for later uploads or final POSTs to advance.

### Verification and remaining limits

`backend/tests/test_evaluation_batches.py` covers early upload-triggered work,
checkpoint reuse, hierarchical reduction, exact quotation validation, Unicode
partition coverage, late arrivals, failed-job retry, concurrency/fencing, work
limits, timer discovery, storage boundaries and API completion above 200,000 bytes.
Browser tests cover checkpoint progression and account invalidation during polling.
Provider calls are mocked. Real-provider calibration, latency/cost measurements,
full-detail quality comparison and hosted timer verification remain release work.
The implementation records a bounded claim count, not provider token-usage billing.

## Verification and deferred work

Chronological context is implemented for newly reserved snapshots. Regression tests
cover interleaving, multipart ties, missing agent timing, interrupted playback,
snapshot persistence and provider forwarding. Existing snapshots remain immutable.

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

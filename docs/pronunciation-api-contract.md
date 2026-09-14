# Azure Speech pronunciation assessment

## Scope

Extend POST/GET `/sessions/{session_id}/evaluation` with Azure Speech unscripted
assessment of stored learner audio. Existing transcript feedback remains supported.
Use the contract-to-Azure workflow; this change implements and tests locally.
Azure resource creation, deployment and GitHub publication are separate stages.

New snapshots (rubric `unified-coaching-v3`) include immutable audio references:
turn ID, MIME type, byte count and SHA-256. Bytes stay in the existing learner audio
store and are verified against the hash before use. Snapshot captures these
references atomically with readiness and transcript context. Existing v1 snapshots
and completed results keep their original behavior; retries do not add new inputs.

For each audio reference, decode WebM/Ogg/WAV/MP4/MPEG into 16 kHz mono signed-16-bit
PCM using PyAV. Do not trim silence, stitch separate turns, include agent audio or
substitute corrected text for what was spoken. Assess with no reference text,
HundredMark scoring, phoneme granularity and prosody enabled for en-US. Local use
defaults to the Azure Speech SDK in continuous mode. Azure hosting defaults to the
short-audio REST API using recording-relative chunks of at most 25 seconds, avoiding
native SDK runtime dependencies in the managed Function image. The optional
`SPEECH_ASSESSMENT_TRANSPORT` setting can explicitly select `sdk` or `rest`.
Credentials: AZURE_SPEECH_KEY and AZURE_SPEECH_REGION; these belong to an Azure
Speech resource, independently of Azure OpenAI.

## Response

Add `speech_assessments` to EvaluationResponse, a list of per-turn assessments.
Each has turn_id, audio_sha256, locale, status, reason, duration_ms, and segments.
Each segment contains recognized text, recording-relative offset/duration in ms,
Azure accuracy/fluency/prosody scores (0–100; unavailable prosody is null), and
word/phoneme accuracy with offsets. Return Azure segment scores directly; do not
present a fabricated aggregate as an Azure session score. Very short (<3 seconds)
recordings, no recognized speech, or fewer than five recognized words return
insufficient_evidence with no scored segments. These are conservative application
thresholds, not validated proficiency rules. No-speech is not a zero score.

Retain `not_assessed` when no usable speech result exists. A usable result removes
pronunciation and spoken_fluency from that list, meaning assessment is available
for the listed segments only, not necessarily the whole session. Speech coverage
and insufficient turns remain explicit in the per-turn results. Raw provider
payloads, subscription keys, and SDK diagnostics are never returned or logged.

Send a compact summary of measured speech findings to Azure OpenAI alongside the
original conversation snapshot. The summary includes coverage, arithmetic means
across previewed assessed segments and up to three low-scoring flagged words. The
text model must synthesize this evidence with transcript findings in the existing
summary, strengths and ranked next_steps, without a separate pronunciation report.
Azure OpenAI must not change Speech scores or invent acoustic findings. Detailed
word/phoneme results remain in the API response, rather than enlarging the model
prompt without bound. Existing transcript scoring schema is unchanged.

## Persistence, failures and limits

Persist completed per-turn Speech assessments keyed by session, turn, audio hash
and locale, independent of the evaluation attempt. Retries reuse these cached
results. No database lock spans provider work. Final evaluation writes retain the
existing attempt fence. Late uploads never alter an input snapshot. Old snapshots
without audio references remain transcript-only even when retried.

Missing Speech configuration when audio is present: 503. Invalid/undecodable or
multitrack audio: 422. Recordings over ten minutes: 413; database failure: 503.
Speech rejection, timeout, unavailable runtime or malformed assessment data creates
a per-turn `unavailable` result with reason `provider_unavailable`. Do not cache that
result. Continue to the Azure OpenAI step and return transcript feedback, retaining
pronunciation and spoken fluency in `not_assessed`. Enforce a shared 120-second
wall-clock budget for uncached Speech work per request; successful turns are cached.
The SDK transport runs in an isolated child process with a hard timeout and no
diagnostic output; the hosted REST transport uses bounded 25-second WAV chunks.
The subsequent text call retains its 60-second timeout.
Snapshot identity and saved scores are separate: no automatic reevaluation of
completed results after configuration changes.

Hosted authorization stays FUNCTION-key based. Local routes remain unauthenticated.
The upload API still stores raw bytes; decoding/format validation happens during
evaluation. Browser turn recording, binary uploads, and unified feedback display are implemented;
see the [browser contract](browser-webrtc-api-contract.md). Audio must be a
learner-only clip with its original internal pauses for meaningful assessment.
This is formative feedback requiring real-audio/teacher calibration, not certification.

## References

- [Azure pronunciation assessment](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-pronunciation-assessment)
- [Microsoft Python sample](https://github.com/Azure-Samples/cognitive-services-speech-sdk/blob/master/scenarios/python/console/language-learning/pronunciation_assessment.py)
- [Speech SDK package](https://pypi.org/project/azure-cognitiveservices-speech/)
- [PyAV](https://pyav.org/docs/stable/)

## Verification

Acceptance coverage and actual local results are recorded after implementation.
Live Azure Speech provisioning and connectivity have been verified. Feedback
quality for real learner recordings still requires calibration.

## Implemented and locally verified — 2026-09-10

- Implemented new audio snapshot references, hash validation, per-turn cache,
  audio normalization, isolated continuous Speech SDK calls, normalized result
  validation, merged response and bounded Azure OpenAI speech context.
- `backend/tests/test_pronunciation.py` covers combined results, key/region handling,
  provider timeouts/rejection/malformed data, score and timestamp validation,
  insufficient evidence, cache reuse after text failure, partial progress across
  retries, snapshot integrity, v1 compatibility, storage failure and limits.
- Real codec tests decode WAV, WebM/Opus, Ogg/Opus, MP3 and MP4/AAC.
- `backend/tests/test_speech_worker.py` covers SDK subscription/region configuration,
  en-US unscripted phoneme/prosody configuration, continuous event collection,
  malformed JSON, cancellation, no-match and end-of-stream cleanup.
- Shared audio, Speech payload, SDK/process and ready-session fixtures are in
  `backend/tests/conftest.py`. Provider execution is mocked; no paid calls in tests.
- Python 3.11.6: **197 backend tests passed**, one existing Starlette/AnyIO
  deprecation warning. **22 browser tests passed**. Dependency consistency and
  `git diff --check` passed. Installed Speech SDK 1.51.2 and PyAV 16.1.0 locally.
- Read-only Azure inspection: `spoken-agents-rg` contains only the existing OpenAI
  resource, no Speech resource. No resource creation, hosted deployment, live
  Speech assessment, GitHub commit or push was performed.

## Hosted provider fallback — 2026-09-13

- The hosted Function selects the Speech short-audio REST transport. Each PCM turn
  is sent as one or more WAV chunks no longer than 25 seconds, and returned offsets
  are normalized to the original recording.
- Speech provider/runtime errors and invalid Speech results now preserve the saved
  session and return completed transcript feedback with an explicit unavailable
  assessment. Configuration, storage and invalid-audio errors remain blocking.
- Unit coverage verifies the REST request shape, flat REST score parsing, sanitized
  fallback behavior, partial assessment coverage and browser rendering.

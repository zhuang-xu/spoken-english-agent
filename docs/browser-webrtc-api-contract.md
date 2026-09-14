# Browser WebRTC connection

## Purpose and scope

Implement a same-origin browser client at `GET /practice`, using the existing
[session contract](sessions-api-contract.md). No new provider proxy or backend schema is introduced. `active` in SQLite still means credentials issued;
Disconnect closes local media/transport and ends the backend session row.

## HTTP and browser behavior

- `GET /practice` returns HTML; `/practice-assets/{path}` serves packaged JS/CSS.
  Missing assets return 404. These presentation routes are excluded from OpenAPI.
- Form fields and constraints match `POST /sessions`: speaking_goal (2–500),
  level (2–50), preferred_topic (2–200), duration (integer 1–120). Strings are trimmed.
- Request microphone permission before creating a session so a permission prompt
  cannot consume the 60-second credential lifetime. Add the audio track and
  `oai-events` data channel to an RTCPeerConnection and create an SDP offer.
- POST preferences as JSON to same-origin `/sessions` with cache disabled.
  Consume `session.id`, `realtime.webrtc_url`, and `client_credential` in memory.
- POST the SDP to the returned HTTPS Azure `/openai/v1/realtime/calls` URL with
  `Authorization: Bearer <temporary credential>` and `Content-Type: application/sdp`.
  Apply the SDP answer using `setRemoteDescription`.
- Data-channel open triggers one `response.create` for the opening question.
  Remote tracks play through an audio element with manual playback controls.
  Final AI speech transcripts are displayed as plain text; raw events are not logged.
- Surface safe messages for permission, backend HTTP errors (including existing
  415/422/502/503/504), malformed/expired credentials, SDP rejection, network errors,
  timeout, and transport failure. Never render raw provider error bodies.
- Only one attempt can be active. Disconnect cancels setup, closes channel/peer,
  stops microphone tracks, clears playback, and prevents late async results from
  reviving a stopped call. A 30-second post-permission setup timeout bounds waits.
  Page exit performs the same cleanup. Retry requires an explicit new Start.

## Authentication and configuration

No new environment settings. Resource key stays server-side; no credentials go into
DOM, URLs, logs, or browser storage. Local Uvicorn requires no authentication.
The Azure Functions adapter defaults to FUNCTION authorization for all routes.
The September 13 hosted deployment uses Microsoft sign-in at the Azure platform
layer and `FUNCTIONS_HTTP_AUTH_LEVEL=anonymous` behind it. Platform authentication
must be enabled and verified before selecting this mode. Browser requests use the
sign-in session cookie, without a Function key. Access is initially restricted to
the owner's Azure account; application-level session ownership remains deferred.
Use localhost or HTTPS for microphone access. Keep the existing deployment setting;
this feature makes no model/resource changes.

Protocol reference checked 2026-09-08:
[Microsoft WebRTC guide](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-webrtc).
Live deployment availability and real media connectivity require separate checks.

## Acceptance and verification

Implemented in `browser/public/` and served by the optional `backend/web_app.py` wrapper. No schema or provider
configuration changes. Local verification on 2026-09-08:

- Python 3.11.6: 6 browser route tests passed; full suite 87 passed, with one
  existing Starlette/AnyIO BlockingPortal deprecation warning. `pip check` passed.
- Node 24.19.0: 22 transport tests passed using built-in `node:test`.
- Browser inspection confirmed page rendering and rejection of whitespace-only
  input before microphone/session creation. No microphone permission was granted.
- Read-only Azure deployment inspection confirmed `gpt-realtime-2.1`, version
  `2026-07-07`, provisioning state `Succeeded`. No cloud changes or paid calls.

| Acceptance case | Coverage |
|---|---|
| Page/assets served, no credentials or provider request, missing asset 404 | `backend/tests/test_browser.py` |
| SDP POST URL, bearer header, answer, audio track, opening event, transcript | `browser/tests/realtime.test.mjs`: happy path |
| Permission denial and duplicate start | permission / Disconnect tests |
| Backend status errors, invalid/expired credentials, bad SDP, network | HTTP and cleanup cases |
| Disconnect during permission, session response, SDP response | late-result tests |
| Setup timeout, failed connection, retry, safe event errors | lifecycle tests |
| Existing validation, storage and provider error transitions | existing session/provider pytest suite |

Automated tests mock external HTTP and browser media. They establish connection
logic, not actual WebRTC negotiation, codec compatibility, or audible playback.

Deferred: cloud deployment/GitHub publication, real conversation verification,
automatic reconnection/token refresh, session duration enforcement, and per-user authentication.


## Browser backend integration — 2026-09-11

Implemented in `browser/public/session.mjs` and wired into the practice page:

- Same-origin JSON requests with bounded timeouts and sanitized HTTP errors.
- Realtime session update enables input transcription with `whisper-1`. The
  practice page now uses manual turns as described below; each recorded turn
  receives a stable UUID shared by its audio and backend transcript.
- Final agent parts are saved by item ID/content index with unknown playback.
- Heartbeats every 30 seconds while the session is open; Disconnect ends the
  backend session, waits for uploads, and declares the immutable upload manifest.
- Failed upload bodies remain in memory for explicit, identical retries. Started
  learner turns without finalized text remain in the inventory as missing.
- Feedback is requested explicitly after a complete save and rendered as plain
  text, including scores, corrections, strengths, and next steps.
- The client declares and uploads learner audio as described below. Feedback
  includes the existing backend pronunciation and fluency assessment results.

Wait for final transcripts before Disconnect: closing the data channel can lose
in-flight transcription. Missing text blocks feedback rather than being fabricated.
Page exit sends a best-effort keepalive end request; upload completion is not
promised after exit. Queues are in memory only, and starting a new session clears
retry access to the previous session. A lost session-creation response still relies
on backend inactivity cleanup. No automatic reconnection or credential refresh.

Protocol shape follows the [Azure Realtime guide](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-websockets).
Transcription model availability and live microphone/provider behavior require
live verification. Automated tests use mocked media and HTTP.

Verification: 29 Node browser tests pass; JavaScript syntax and local Markdown
links checked. Python route/package tests could not run in this environment
because pytest is not installed. No live provider calls or deployment performed.


## Implemented browser audio uploads — 2026-09-11

- `recorder.mjs` uses MediaRecorder on the microphone stream only. It selects a
  supported WebM/Opus, Ogg/Opus, or MP4 MIME type, combines all data events including
  the last asynchronous event, and uploads one complete container per learner turn.
  Browser support is checked before backend session creation. No separate permission
  or agent-output recording is needed.
- The practice page disables server VAD (`turn_detection: null`). Start speaking
  waits for input-buffer clearing, creates a local UUID and session-clock start
  offset, starts the recorder, and unmutes the microphone. Finish turn mutes the
  microphone, stops recording, and commits the provider input buffer. The committed
  provider item ID maps back to the local turn UUID before its final transcript.
  The next turn waits for transcription; no transcript-arrival ordering heuristic
  associates recordings. A new turn cancels any active partner generation/playback.
- Audio is PUT as raw binary to the learner audio endpoint with the recording MIME
  type, using the same turn UUID as the transcript. Original internal pauses remain.
  No JSON/base64 wrapper, concatenated containers, or agent media is uploaded.
- Finalization waits for pending recorder output and upload acknowledgments before
  declaring all expected audio/transcript IDs. Failed captures remain expected and
  block evaluation. Failed HTTP uploads retain identical bytes for automatic retries
  during finalization; successful audio uploads release their local copy.
- Recordings stop at two minutes; each upload is limited to 10 MiB. Unsaved audio is
  bounded to 64 MiB. Recording failure, empty output, size limits, and missing stop
  events report failure without uploading a truncated file. Recorder finalization
  has a five-second timeout. User Disconnect waits up to 16 seconds for the learner
  transcript; page exit remains best effort and cannot guarantee upload delivery.
- Evaluation requests allow 200 seconds for the backend's 120-second Speech budget
  plus 60-second text evaluation. The browser renders the text model's unified
  report: overall feedback, language category evidence, cross-category strengths,
  at most three ranked priorities and grounded corrections. It does not add a
  separate speech report or display turn transcripts, timestamps, individual word
  scores or phonemes. Detailed Speech measurements remain in the API response.

These changes require no backend API/schema changes. They do not provision Speech
resources or verify live Azure speech quality. Recordings capture the microphone,
which may contain acoustic speaker leakage; headphones are recommended.


Audio integration verification: 40 Node tests passed, plus 64 targeted backend
tests covering assets, packaging, learner inputs, and pronunciation (62 original
cases plus two new asset cases). A headless Chrome smoke test generated a complete
WebM/Opus recording, exercised failed uploads and byte-identical retries, matched
manifest audio/transcript UUIDs, and rendered speech scores without page errors.
The generated recording also passed the real backend upload/duplicate/manifest
flow and decoded to 16 kHz mono PCM. Smoke scripts live in `browser/tests/`.
Provider speech recognition, transcription, and scoring were mocked; no real-user
microphone, live Azure call, deployment, or resource creation was performed.


## End conversation and automatic feedback

September 13 implementation: the explicit **End conversation** action drains the
active recording and transcript, ends the backend session, and saves its complete
manifest. When saving succeeds, feedback starts automatically. A failed save does
not trigger assessment; the browser retries transient end, upload and manifest
failures up to three times with 750 ms and 2 s backoff. A successful retry proceeds
to feedback. Exhausted retries or incomplete data display a persistent accessible
note explaining that feedback is unavailable for that session.
Unexpected transport termination and page exit do not automatically start paid
assessment. The browser smoke test covers ending during recording, failed uploads,
identical retry bytes and exactly one automatic evaluation request.

Shared hosted state and diagnostics follow the [hosted storage contract](hosted-storage-api-contract.md).

The page has no manual save-retry control. **Get feedback** remains enabled if
evaluation fails and its error explains that the session is already saved. Ending a
conversation saves with the automatic retry policy above and then requests feedback.
If Azure Speech is temporarily unavailable, the page still renders transcript
feedback and labels pronunciation and spoken fluency as not assessed instead of
showing a whole-report 502.

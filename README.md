# Spoken English Agent — Session Start and Learner Inputs

This project implements session creation, a browser WebRTC client, health, learner
audio/transcript uploads, and agent transcript uploads. Session ending is also implemented. Transcript and Azure Speech evaluation are implemented locally. The browser records learner turns, uploads audio and transcripts, and displays
transcript feedback plus pronunciation and fluency assessment.

## Run

```bash
python3.14 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
cp backend/.env.example .env
# Set AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_API_KEY, and AZURE_OPENAI_DEPLOYMENT in .env.
uvicorn web_app:app --app-dir backend --reload
```

Use Python 3.11 with these pinned dependencies.

The command above serves the API and optional browser client together. For the API
alone (including future mobile clients), run:

```bash
uvicorn app.main:app --app-dir backend --reload
```

Run these commands from the repository root so the existing `.env` and `data/`
locations continue to work. The ignored local `.env` and database have not moved.

Open [the practice page](http://127.0.0.1:8000/practice), enter your preferences,
and click **Start conversation**. Allow the microphone; the client creates a session,
POSTs its SDP offer directly to the returned Azure `realtime.webrtc_url`, applies
the SDP answer, and requests the opening question. Replies play through the audio
element. If autoplay is blocked, use its Play control. **Disconnect** stops the
microphone and closes WebRTC, including during setup.

Use localhost or HTTPS. Protected local API routes require a valid Entra bearer token;
the browser sign-in flow expects Azure platform authentication. Azure Functions defaults to FUNCTION protection. The hosted browser uses Azure
platform Microsoft sign-in and `FUNCTIONS_HTTP_AUTH_LEVEL=anonymous`, so authenticated
browser requests do not need a Function key. Enable and verify platform sign-in
before selecting this mode. Do not put Function keys into browser source or URLs.

The browser implementation is in `browser/public/realtime.mjs`; look for the
`fetchImpl(url.href, ...)` call for the direct SDP POST. `browser/public/session.mjs` handles transcript uploads, heartbeats, ending, manifests, and feedback. `browser/public/practice.mjs` binds the
form and status display. See the [browser WebRTC contract](docs/browser-webrtc-api-contract.md).

Open `/docs` for the interactive API reference. The configured Realtime deployment must
exist in your Azure OpenAI resource. No real provider call is made by the tests.

```bash
curl -X POST http://127.0.0.1:8000/sessions \
  -H 'Content-Type: application/json' \
  -d '{"speaking_goal":"Interview practice","level":"B1","preferred_topic":"backend projects","session_duration_minutes":15}'
```

The response contains `session` (ID, active status, creation time, accepted
preferences) and `realtime` (provider session ID and expiring client credential).
The client uses the credential to connect to Azure OpenAI over WebRTC using `realtime.webrtc_url`. Creating
a credential does not itself open a conversation or play an opening question.
After connecting, the client can send `response.create` to request the opening.
Duration is a practice preference, not an enforced timer.

## Data models

The data classes declare zero custom methods; Pydantic supplies validation and
serialization. Application behavior lives in ordinary functions.

| Class | What it represents | Why it exists |
|---|---|---|
| `Settings` | Server configuration | Loads database path, API key, model, and voice. |
| `SessionCreate` | Learner's four preferences | Validates input before spending money or writing a session. |
| `Session` | Successfully created application session | Adds a server-generated ID, active status, and timestamp. |
| `RealtimeClientCredential` | Temporary token and expiry | Makes the client connection data explicit. |
| `RealtimeSession` | Provider ID and credential | Keeps provider connection details together. |
| `CreateSessionResponse` | Session plus Realtime details | Defines exactly what the endpoint returns. |
| `LearnerTranscript` | Final learner text and timing | Validates transcript uploads. |
| `LearnerInputReceipt` | Input receipt flags | Reports which components have been stored. |

`SessionCreate` is input: the learner cannot supply a session ID or status.
`Session` is output: the server adds those fields after creation succeeds.
The three small response wrappers preserve the existing JSON contract and provide
nested validation and API documentation.

The former `SessionApplication` was an abstract description of application
operations. “Application” referred to coordinating a use case. Its subclass,
`RealtimeSpeakingSessionApplication`, was meant to implement those operations by
calling providers and stores, but its methods were placeholders. Both are removed;
`create_session()` now performs the one workflow we actually need.

## Read the code in this order

1. `backend/app/schemas.py`: input and output data.
2. `backend/app/main.py`: the HTTP endpoint and JSON requirement.
3. `backend/app/services/sessions.py`: save creating → request credential → save active → respond.
4. `backend/app/services/realtime.py`: the Azure OpenAI HTTP request.
5. `backend/app/storage/sqlite.py`: two SQLite helper functions.
6. `backend/app/config.py`: environment settings.

`backend/function_app.py` also exposes the app through Azure Functions. SQLite is intended
for local development; configure durable storage before relying on a hosted deployment.
The new `practice_sessions` table does not modify older tables in an existing database.

## Current behavior and limits

- Strings are trimmed, with maximum lengths of 500 / 50 / 200 for goal / level / topic.
  Level is free text. Each string requires at least two characters.
- Duration must be an integer from 1 through 120; unknown fields are rejected.
- Invalid input returns 422; non-JSON content type returns 415.
- Missing API key or storage failure returns 503; provider failure returns 502;
  provider timeout returns 504. Error responses use FastAPI's `detail` field.
- Success returns 201 and `Cache-Control: no-store`. Tokens are not persisted or
  explicitly logged, and provider error details are not exposed to the client.
- Provider failure marks the row failed. If activation fails, the token is withheld
  and expires after 60 seconds; marking the row failed is best effort during a
  storage outage. A process crash may leave a creating row; the scheduled cleanup marks stale creating rows failed.
- `active` means connection credentials are ready, not that WebRTC is connected.
- Optional `Idempotency-Key` prevents duplicate starts; keyed replays return the
  existing session with `realtime: null`. No automatic credential refresh.
- Backend account ownership and per-account quotas are implemented; hosted identity-header verification and edge limits remain deployment gates.
- The browser supports one call at a time, opening speech, safe error messages,
  final AI speech text, a setup timeout, and explicit reconnect via a new Start.
  It saves learner/agent transcripts, sends heartbeats, ends sessions, and requests
  transcript feedback after a complete save. Failed saves can be retried while the
  page remains open. It records each learner turn using Start speaking / Finish turn, uploads audio
  under the same turn ID as its transcript, and displays speech assessment. It
  does not refresh credentials or enforce the requested session duration.
  Disconnect does not change the backend session row.
  After completed feedback, the browser remembers the last report's session ID
  under the verified account and reloads that report after a page refresh. The feedback panel can forget that
  local reference. Active calls and unsaved uploads do not resume.

## Tests

Use Python 3.14 and install the pinned backend dependencies before running tests:

```bash
python3.14 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements.txt
.venv/bin/python -m pytest -q
node --test browser/tests/*.test.mjs
```

Tests exercise the real route, workflow, response parsing, and temporary SQLite
database, with only the provider HTTP call mocked. See
[session-start contract](docs/sessions-api-contract.md) for remaining work.

Provider reference: [Azure OpenAI Realtime WebRTC guide](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-webrtc).

## Azure deployment and testing

The existing Function App is `spoken-agent-func-4fa2534c` in resource group
`spoken-agents-rg`, running managed Python 3.11. Build a source ZIP from the repository
root using the packaging script:

```bash
python scripts/package_backend.py /tmp/spoken-agents.zip --include-browser
az functionapp deployment source config-zip -g spoken-agents-rg -n spoken-agent-func-4fa2534c --src /tmp/spoken-agents.zip --build-remote true
```

Omit `--include-browser` for an API-only deployment. The script places
`function_app.py`, `web_app.py`, `host.json`, `requirements.txt`, and `app/` at the
archive root as Azure expects. Optional assets are packaged as `browser/public/`.
Only application sources and selected browser assets are included; secrets, local
databases, virtual environments, and tests are excluded.

For the Azure Functions local host, run `func start` from `backend/` with its required
host settings configured. Plain Uvicorn does not run the cleanup timer. Azure installs
requirements on Linux and loads the entry point; it does not start Uvicorn manually.

The hosted website uses Microsoft sign-in, initially restricted to the owner's
Azure account. Open [the hosted practice page](https://spoken-agent-func-4fa2534c.azurewebsites.net/practice).
Azure platform authentication protects the page and API; the Function trigger uses
`FUNCTIONS_HTTP_AUTH_LEVEL=anonymous` behind that protection. The default remains
`function` for other deployments. Never disable platform authentication while the
trigger is anonymous. Additional users require explicit access assignments and hosted two-account
verification. Backend and browser account isolation are implemented locally.

Configure `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`, and
`AZURE_OPENAI_DEPLOYMENT` in the Function App environment variables. The endpoint
is the HTTPS resource origin (without `/openai/v1`); deployment is the Azure model
deployment name. `REALTIME_VOICE` defaults to `verse`. Keep keys out of source ZIPs.
The current Azure `DATABASE_PATH=/tmp/spoken_agents.sqlite3` is temporary and is
not shared between instances. Use durable database storage before production.

After deploying, check:

- Without sign-in: `/practice` and `/health` redirect to Microsoft sign-in.
- After sign-in: `/practice`, its assets, `/health`, and `/openapi.json` return 200.
- `POST /sessions` with `{}` returns 422.
- With Azure OpenAI configured, valid session preferences return 201 and an expiring
  credential. Without the Azure configuration, the expected response is 503.

Health does not check OpenAI or database access. A 201 verifies credential creation,
not a connected WebRTC conversation. Do not log or share the response credential.


### Azure OpenAI resource

Resource: `spoken-agents-openai-4fa2534c` (East US 2), in `spoken-agents-rg`.
Deployment: `gpt-realtime-2.1`, version `2026-07-07`, Global Standard capacity 1.
The backend uses an `api-key` header to request a short-lived client credential.
The returned `realtime.webrtc_url` points to this resource's `/openai/v1/realtime/calls`.
A browser authenticates there with the temporary credential, never the resource key.
`OPENAI_API_KEY` and `REALTIME_MODEL` are no longer used by this service.

Shared test fixtures live in `backend/tests/conftest.py`. `backend/tests/test_realtime.py` checks
Azure URLs, resource-key authentication, deployment names, and trailing slashes.
`backend/tests/test_session_creation.py` checks the route, database workflow, and failures.
All automated tests mock provider HTTP; real Azure checks are run separately.


## Capture learner audio and transcript

After creating a session, the browser generates one UUID per learner utterance.
Use that same `turn_id` for the recording and its finalized transcript, even if
transcription arrives later. Maintain a mapping to the provider item ID on the
client; do not pair asynchronous events solely by arrival time.

Upload audio as raw bytes (not multipart or base64):

```bash
curl -X PUT "http://127.0.0.1:8000/sessions/$SESSION_ID/learner-turns/$TURN_ID/audio" \
  -H 'Content-Type: audio/webm;codecs=opus' --data-binary @learner.webm
```

Upload the finalized learner transcript separately:

```bash
curl -X PUT "http://127.0.0.1:8000/sessions/$SESSION_ID/learner-turns/$TURN_ID/transcript" \
  -H 'Content-Type: application/json' \
  -d '{"text":"I built an application.","start_ms":1000,"end_ms":3500,"provider_item_id":"item_learner_1"}'
```

Offsets are milliseconds on the client's session recording clock, not upload times.
Only send finalized text. Both routes return receipt flags, for example:

```json
{"session_id":"...","turn_id":"...","audio_received":true,"transcript_received":true}
```

New components return 201; identical normalized retries return 200; replacements
return 409. Retain pending uploads on the client until acknowledged. Audio and
transcripts may arrive in either order. Supported audio types: WebM, Ogg, WAV, MP4,
and MPEG, declared with the corresponding `audio/*` MIME type. The limit is 10 MiB
per recording; transcript text is limited to 20000 characters. Bytes are stored
without decoding or validating the audio format. See the
[learner-input contract](docs/learner-inputs-api-contract.md) for all errors.

No new environment settings or dependencies are needed. `DATABASE_PATH` now stores
learner audio BLOBs as well as transcripts and metadata. This is a local MVP storage
choice, not durable cloud audio storage. Receipt flags confirm storage only.

These endpoints do not record the microphone, generate transcripts, or configure
Realtime input transcription. The client must capture audio and obtain finalized
learner text from its transcription source. Realtime transcription configuration
and recording uploads are now enabled by the browser. Agent transcripts use the separate endpoint below.
Hosted uploads require the existing `x-functions-key` header; per-user ownership,
retention/deletion, total storage quotas, and public-use authentication are deferred.


## Capture conversation agent transcripts

Send finalized generated text using:

`PUT /sessions/{session_id}/agent-items/{item_id}/transcripts/{content_index}`

```json
{
  "text": "What did you build?",
  "response_id": "resp_1",
  "previous_item_id": "learner_1",
  "playback_status": "completed",
  "start_ms": 4000,
  "end_ms": 5500
}
```

The browser supplies the provider item ID, response ID, and content index. Supply
`previous_item_id` from conversation item metadata if available; it is not inferred
from upload order. Playback offsets use the same session clock as learner audio.
Omit offsets and leave playback_status as `unknown` if playback wasn't tracked.
Generated text may include speech the user did not hear after an interruption.

Use `interrupted` for interrupted playback. Wait until playback metadata is final
before submitting it: identical retries return 200, but changing a stored part
returns 409. Separate content indices preserve multiple parts within one item.
New parts return 201 with a receipt; text is stored in SQLite, not echoed back.
No new dependencies or settings are needed.

This backend does not subscribe to WebRTC events. Browser event collection and an
ordered conversation retrieval endpoint remain unimplemented. See the dedicated
[agent-transcript contract](docs/agent-transcripts-api-contract.md) for validation,
ordering limitations, and acceptance tests.

## End a session

`POST /sessions/{session_id}/end` requires no request body. It returns 200:

```json
{"session_id":"...","status":"ended","ended_at":"2026-09-09T10:00:00Z"}
```

The server records the first end time in UTC. Repeated or concurrent requests
return the same timestamp. Unknown sessions return 404, creating or failed sessions
return 409, invalid UUIDs return 422, and storage failures return 503. Successful
responses include `Cache-Control: no-store`. Existing SQLite databases gain lifecycle columns transactionally as sessions are
created, updated, or checked by cleanup.

Late learner audio, learner transcripts, and agent transcripts remain accepted after
ending, with the same immutable-upload and retry rules. Ending does not guarantee
all uploads have arrived or trigger evaluation. There is no late-upload deadline yet.
The browser must close its WebRTC connection separately; this endpoint records
application state and does not contact Azure. Hosted requests require the existing
function-key authentication. The practice page does not call this endpoint yet.

## Heartbeats and inactivity cleanup

`POST /sessions/{session_id}/heartbeat` requires no body and returns 200:

```json
{"session_id":"...","status":"active","last_activity_at":"2026-09-09T10:00:00Z"}
```

The client should send a heartbeat every 30 seconds while connected. Unknown sessions
return 404; creating, failed, or ended sessions return 409; invalid UUIDs return 422;
storage failures return 503. Successful responses include `Cache-Control: no-store`.
On 409, close the old WebRTC connection and start a new session. Browser heartbeat
sending is not integrated yet; this change implements the backend only.

Session activation, heartbeats, and successful uploads (including identical retries)
refresh `last_activity_at` using server UTC time. Invalid or conflicting uploads do
not refresh activity. Late uploads to ended sessions remain accepted but never
change their activity, end timestamp, or end reason.

`backend/function_app.py` registers an Azure Functions timer every minute. It atomically ends
active sessions with no activity for at least five minutes, storing the cleanup time
as `ended_at` and `inactivity_timeout` as `end_reason`. Normal `/end` requests store
`client_requested`; retries preserve the original reason. Heartbeats and cleanup
serialize: activity committed before cleanup protects the session; a heartbeat
after cleanup returns 409. Normal scheduling means expiration happens approximately
five to six minutes after the last activity, and can be later if the scheduler stalls.
The timer also marks creating sessions older than five minutes failed; already
failed sessions are unchanged.

The Azure timer requires a configured `AzureWebJobsStorage` connection for scheduling.
Run the Functions host to execute it locally; plain Uvicorn does not run timer triggers.
For a one-off local cleanup with the configured database:

```bash
PYTHONPATH=backend python -c 'from app.config import get_settings; from app.storage.sqlite import expire_inactive_sessions; print(expire_inactive_sessions(get_settings().database_path))'
```

A scheduled run can only clean sessions visible in its database. The current hosted
`/tmp` SQLite database is not shared between Azure instances: reliable hosted cleanup
requires shared durable storage. Ending the database row does not disconnect Azure
Realtime or stop its audio stream.

## Start recovery and upload completeness

Session starts now accept an optional `Idempotency-Key`. Same-key retries identify
the existing session without calling Azure again. Credentials are not replayed: a
200 replay has `realtime: null`, and a fresh connection needs an explicit new key.
The timer also recovers abandoned creating rows and prevents late activation.

After ending, submit the final expected upload IDs to
`PUT /sessions/{session_id}/upload-manifest`. Read
`GET /sessions/{session_id}/data-status` to see missing/unexpected components and
`ready_for_evaluation`. Ending alone never means uploads are complete.

See [the recovery and completeness contract](docs/session-recovery-and-completeness.md)
for response formats, retry/reconnection behavior, limits, and readiness semantics.
The browser now submits the final audio/transcript inventory and requests evaluation once saving is complete. Evaluation is implemented locally as described below.

## Repository layout

```text
backend/
  app/                  Client-independent API, schemas, services, storage
  tests/                Python API and optional-host integration tests
  function_app.py        Azure HTTP adapter and cleanup timer
  web_app.py             Optional same-origin browser hosting
  host.json
  requirements.txt
  .env.example
browser/
  public/                HTML, CSS, and browser JavaScript
  tests/                 JavaScript tests
mobile/                  Reserved for a future client; no framework chosen
docs/                    Shared API contracts and architecture
scripts/package_backend.py
pytest.ini               Root Python test discovery and import path
```

Browser and mobile clients use the same backend HTTP contracts. The core
`backend/app/main.py` can run without browser files. `backend/web_app.py` optionally
adds `/practice` and `/practice-assets` while preserving API paths and `/docs`.
The current browser still uses relative same-origin API URLs; independently hosted
browser deployments will need an API proxy or explicit origin/authentication setup.


## Evaluate a completed session

After ending and completing the upload manifest, call
`POST /sessions/{session_id}/evaluation` with no body. It waits for Azure feedback
and returns 201; repeated requests return the stored result with 200. Read status
or feedback using `GET /sessions/{session_id}/evaluation`. The result assesses
grammar, vocabulary and coherence using formative 1–5 scores (nullable when evidence
is insufficient), strengths, ranked next steps and corrections linked to learner
turns. When learner audio is included, Azure Speech also assesses pronunciation and
spoken fluency. Audio goes to Azure Speech; Azure OpenAI receives the transcript
context and a compact summary of measured speech findings, then combines both
evidence sources into one coaching report.

Set `AZURE_OPENAI_EVALUATION_DEPLOYMENT` to a separate deployed text model supporting
Azure strict structured outputs. Evaluation uses the existing Azure endpoint/key
and `/openai/v1/chat/completions`. The currently inspected resource contains only
Realtime, so live evaluation requires a compatible text deployment. Install
`backend/requirements.txt` to include the Speech SDK and PyAV audio decoder. The
deployed app has passed a real-provider connectivity check; feedback quality for
real learner speech still requires calibration.

Inputs are captured atomically with readiness and saved as an immutable snapshot.
Failed evaluations can be retried by POST; running attempts return 409 with
`Retry-After: 5`. After five minutes a running attempt can be replaced by an explicit
retry. Retries reuse the original snapshot and deployment; late uploads do not
change an existing evaluation. Results remain readable without provider credentials.
Provider errors return 502, timeouts 504, configuration/storage failures 503, and
inputs exceeding 200,000 UTF-8 bytes return 413. This is a synchronous workflow,
not a background job queue. A crash/retry can incur another provider charge.

See [the evaluation contract](docs/evaluation-api-contract.md) for the complete
response, error and retry semantics. The local implementation is not deployed;
Azure hosting and GitHub publication remain separate release steps.


## Pronunciation and spoken fluency with Azure Speech

Set `AZURE_SPEECH_KEY` and `AZURE_SPEECH_REGION` for an Azure Speech resource.
These are separate from the Azure OpenAI resource credentials. The existing
`spoken-agents-rg` currently has only an OpenAI resource; no Speech resource was
created by this implementation. Completed results and transcript-only snapshots
remain readable without Speech configuration.

Each audio PUT records a terminal assessment state. When Azure Speech is configured,
the backend stores the immutable recording, decodes it into 16 kHz mono PCM and
caches the context-free Speech result. Without configuration it caches an explicit
`not_configured` unavailable result. The final evaluation POST reads those cached
results; it does not decode or send audio. Supported inputs
are WAV, WebM, Ogg, MP4 and MPEG audio; mislabeled/corrupt media and files with
multiple audio tracks are rejected during upload when Speech is configured. The
backend preserves internal pauses. Clients must
record learner-only audio and avoid trimming pauses or mixing in agent playback.

Azure Speech runs unscripted assessment in en-US. Local execution defaults to the
continuous Speech SDK transport. Azure hosting defaults to the short-audio REST
transport and splits longer turns into WAV chunks of at most 25 seconds. Set
`SPEECH_ASSESSMENT_TRANSPORT=sdk` or `rest` to override transport selection. The
response adds `speech_assessments`, with per-turn
status, duration, and recognized segments containing 0–100 accuracy, fluency and
optional prosody scores, word timestamps, and phoneme accuracy. Offsets are relative
to the uploaded clip, not the session clock. Scores come from Speech; Azure OpenAI
can explain measured findings and suggest exercises but does not replace scores.
`speech_summary` provides deterministic coverage plus arithmetic mean pronunciation,
spoken-fluency and optional prosody scores across assessed segments. These application
averages are not Azure whole-session or certified proficiency scores.

Clips under three seconds, no recognized speech or fewer than five recognized
words return `insufficient_evidence`, with a reason and no scored segments. These
are conservative application thresholds, not validated proficiency standards.
`not_assessed` retains pronunciation/spoken_fluency unless at least one turn has
usable speech results. Inspect per-turn status to see actual assessment coverage.
Existing completed evaluations are not automatically upgraded; old snapshots retain
their original inputs and can remain transcript-only.

Assessment allows ten minutes per recording and a 120-second wall-clock budget per
audio upload. Each process permits two simultaneous Speech provider calls, so extra
uploads wait within that deadline rather than starting an unbounded provider burst.
Each turn outcome is cached immediately; the browser allows 130 seconds
for that request. Invalid audio returns 422 and excessive duration 413 when Speech
is configured; missing Speech configuration preserves the recording with an
unavailable state, while storage failure returns 503. If the
Speech provider, runtime or response fails, the report continues with transcript
feedback and marks that turn unavailable; an identical audio retry attempts Speech
again. Pronunciation and spoken fluency remain
in `not_assessed`. SDK work runs in a child process terminated at the deadline. No
keys are passed in command arguments, and diagnostic provider details are suppressed.

Browser recording/upload integration, Azure deployment and provider connectivity
are implemented. Quality calibration and GitHub publication remain pending. The
hosted REST transport avoids dependence on the Function image's native Speech SDK
libraries. See [the pronunciation contract](docs/pronunciation-api-contract.md).

Final evaluation uses a staged pipeline. The first Azure OpenAI call evaluates only
transcript evidence and saves `transcript_result`. If an expected audio assessment
is still in flight, the API returns 202 with component states and Retry-After rather
than publishing incomplete feedback. Once Speech is terminal, a smaller synthesis
call combines the saved transcript result with bounded Speech findings. Synthesis
retries reuse transcript_result, so grammar analysis and grounded corrections are
not paid for or generated again. A durable cross-instance queue remains deferred;
the current Speech concurrency bound is per application process.


### Browser audio assessment workflow

At `/practice`, start a conversation, then use **Start speaking** and **Finish turn**
for each answer. These controls replace automatic speech segmentation on this page.
The microphone is muted between turns. The browser records only the microphone
stream; headphones help prevent speaker output from leaking into that microphone.
Each turn produces one complete WebM/Opus, Ogg/Opus, or MP4 recording, depending on
browser support. Recordings stop at two minutes and must fit the 10 MiB upload limit.

**Disconnect** finishes any active recording and waits up to 16 seconds for its
transcript before ending. Saving waits for final recorder data and uploads. Missing
recordings or transcripts block evaluation. Transient save failures are retried
automatically up to three times with the same UUIDs, bytes, and MIME type. If all
attempts fail, the page displays a note explaining that feedback is unavailable for
that session. Unsaved audio is held in memory (up to 64 MiB) until finalization;
successful uploads release their local audio copy.

**Get feedback** sends the saved audio through the existing backend Speech workflow.
The backend needs `AZURE_SPEECH_KEY`, `AZURE_SPEECH_REGION`, and the existing text
evaluation configuration. Azure Speech supplies acoustic measurements and the text
model combines them with transcript findings into one report with overall feedback,
strengths and at most three ranked priorities. The browser hides transcripts,
timestamps, individual word scores and phonemes; those detailed measurements remain
available in the API response. No Speech credentials are sent to the browser.


For an optional browser smoke test, install Playwright and its Chromium browser,
then run `node browser/tests/audio-smoke.cjs`. It uses real MediaRecorder with a
synthetic audio source and mocked HTTP/WebRTC, and writes a WebM plus screenshot
to the system temporary directory. `PLAYWRIGHT_MODULE` can point to an existing
Playwright installation, and `BROWSER_EXECUTABLE` can select an installed Chrome.
Run `python browser/tests/verify-audio-smoke.py /tmp/spoken-browser-recording.webm`
with the backend dependencies to verify the generated file against actual backend
upload, duplicate retry, completeness, and audio decoding. No paid calls are made.


## Hosted upload and feedback fix — September 13

The private Azure deployment uses shared Blob-backed SQLite snapshots through
`DATABASE_PATH=azureblob://spoken-sessions/sessions.sqlite3`. This replaces the
instance-local `/tmp` database for new sessions. Blob leases serialize transactions
across workers and restarts. It is intended for low-volume private use; each
operation copies the database. See the [hosted storage contract](docs/hosted-storage-api-contract.md).

**End conversation** finishes any active recording, waits for its transcript,
saves the session, and automatically requests feedback when the manifest is
complete. Transient failures are retried automatically up to three times before the
page displays a persistent save-failure note. **Get feedback** remains available for
a failed feedback request after saving succeeds. A temporary Speech failure still
returns transcript feedback and labels speech scoring unavailable. Missing
recordings or transcripts still block assessment.

A 404 for a session now explains that the server no longer has that session.
Starting a new conversation is required after the storage migration; the change
cannot restore already-lost temporary sessions. Request diagnostics record route,
status and instance without recording conversation contents or credentials.

### Conversation controls

During practice, the setup collapses to a preference summary. Transcripts scroll
inside their own keyboard-accessible panel and follow new messages only while the
reader is near the bottom; otherwise “Jump to latest” is available. Speaking,
ending, feedback retry, and save status remain in a fixed bottom control bar.
“End & get feedback” saves the session and requests feedback, then reveals the
result and collapses transcripts into “Review conversation.” Agent sound can be
muted independently of the microphone; “Enable agent audio” appears if autoplay
is blocked. The live audio stream no longer displays a recording timeline.

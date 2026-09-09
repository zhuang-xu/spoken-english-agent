# Spoken English Agent — Session Start and Learner Inputs

This project implements session creation, a browser WebRTC client, health, learner
audio/transcript uploads, and agent transcript uploads. Session ending is also implemented. Evaluation and browser recording/upload
integration remain deferred.

## Run

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Set AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_API_KEY, and AZURE_OPENAI_DEPLOYMENT in .env.
uvicorn app.main:app --reload
```

Use Python 3.11 with these pinned dependencies.

Open [the practice page](http://127.0.0.1:8000/practice), enter your preferences,
and click **Start conversation**. Allow the microphone; the client creates a session,
POSTs its SDP offer directly to the returned Azure `realtime.webrtc_url`, applies
the SDP answer, and requests the opening question. Replies play through the audio
element. If autoplay is blocked, use its Play control. **Disconnect** stops the
microphone and closes WebRTC, including during setup.

Use localhost or HTTPS. This same-origin client is ready for local Uvicorn use.
Azure Functions retains FUNCTION protection on the page and all assets: hosted
browser use requires an authenticated same-origin gateway that supplies the
function key for backend requests. Do not put that key into browser source or URLs.
No new environment variables or runtime packages are required.

The browser implementation is in `app/static/realtime.mjs`; look for the
`fetchImpl(url.href, ...)` call for the direct SDP POST. `practice.mjs` binds the
form and status display. See the [browser WebRTC contract](docs/todo-browser-webrtc-api-contract.md).

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

1. `app/schemas.py`: input and output data.
2. `app/main.py`: the HTTP endpoint and JSON requirement.
3. `app/services/sessions.py`: save creating → request credential → save active → respond.
4. `app/services/realtime.py`: the Azure OpenAI HTTP request.
5. `app/storage/sqlite.py`: two SQLite helper functions.
6. `app/config.py`: environment settings.

`function_app.py` also exposes the app through Azure Functions. SQLite is intended
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
- Authentication and rate limiting are not implemented; this is a local-development API.
- The browser supports one call at a time, opening speech, safe error messages,
  final AI speech text, a setup timeout, and explicit reconnect via a new Start.
  It does not refresh credentials, enforce duration, or upload audio/transcripts.
  Disconnect does not change the backend session row.

## Tests

```bash
python -m pytest -q
node --test tests/browser/realtime.test.mjs
```

Tests exercise the real route, workflow, response parsing, and temporary SQLite
database, with only the provider HTTP call mocked. See
[session-start contract](docs/todo-sessions-api-contract.md) for remaining work.

Provider reference: [Azure OpenAI Realtime WebRTC guide](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-webrtc).

## Azure deployment and testing

The existing Function App is `spoken-agent-func-4fa2534c` in resource group
`spoken-agents-rg`, running managed Python 3.11. Deploy the Python source,
`function_app.py`, `host.json`, and `requirements.txt` with a remote build. Do not
package `.env`, virtual environments, tests, or local databases. Include
`app/static/` in source archives so the practice page and its assets are available.

Azure installs requirements on Linux. The Functions host loads `function_app.py`,
whose ASGI adapter forwards HTTP requests to the FastAPI app in `app/main.py`.
You do not start Uvicorn manually on Azure.

Hosted routes require an Azure function key (`x-functions-key` request header).
This is a shared testing credential, not per-user authentication. Retrieve it from
the Function App's **App keys** page; do not commit it or embed it in a public client.

Configure `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`, and
`AZURE_OPENAI_DEPLOYMENT` in the Function App environment variables. The endpoint
is the HTTPS resource origin (without `/openai/v1`); deployment is the Azure model
deployment name. `REALTIME_VOICE` defaults to `verse`. Keep keys out of source ZIPs.
The current Azure `DATABASE_PATH=/tmp/spoken_agents.sqlite3` is temporary and is
not shared between instances. Use durable database storage before production.

After deploying, check:

- Without a function key: `/health` returns 401.
- With a function key: `/health` returns 200 and `/openapi.json` lists the session, health, learner-input, and agent-transcript routes.
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

Shared test fixtures live in `tests/conftest.py`. `tests/test_realtime.py` checks
Azure URLs, resource-key authentication, deployment names, and trailing slashes.
`tests/test_session_creation.py` checks the route, database workflow, and failures.
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
[learner-input contract](docs/todo-learner-inputs-api-contract.md) for all errors.

No new environment settings or dependencies are needed. `DATABASE_PATH` now stores
learner audio BLOBs as well as transcripts and metadata. This is a local MVP storage
choice, not durable cloud audio storage. Receipt flags confirm storage only.

These endpoints do not record the microphone, generate transcripts, or configure
Realtime input transcription. The client must capture audio and obtain finalized
learner text from its transcription source. Realtime transcription configuration
and browser integration remain a separate step. Agent transcripts use the separate endpoint below.
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
[agent-transcript contract](docs/todo-agent-transcripts-api-contract.md) for validation,
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

`function_app.py` registers an Azure Functions timer every minute. It atomically ends
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
python -c 'from app.config import get_settings; from app.storage.sqlite import expire_inactive_sessions; print(expire_inactive_sessions(get_settings().database_path))'
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
Browser integration, evaluation execution, and hosted deployment are not included.

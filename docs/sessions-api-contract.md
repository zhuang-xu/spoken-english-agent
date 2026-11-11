# POST /sessions contract

This document now describes the implemented session-start scope. The previous
contract-only adapter gate is superseded by the request to implement session start.

## Implemented

- JSON request: `speaking_goal`, `level`, `preferred_topic`, `session_duration_minutes`.
- Trim strings; require 2–500 characters for speaking goal and 2–50 for level.
- Topic is optional: omitted, null, empty, or whitespace-only values normalize to null.
  A supplied topic must have 2–200 characters. With no topic, the agent chooses one
  matching the learner’s speaking goal and level and opens practice without asking for a topic.
- The API accepts free-text goals and levels. Duration is a strict integer from 1 to 120.
- The browser offers preset speaking goals, CEFR levels, topics, and practice lengths;
  the default topic is “Let the agent choose.”
- Reject unknown request fields.
- Generate a UUID and persist a creating row before contacting Azure OpenAI.
- Request a 60-second Realtime client credential with model, voice, and preferences.
- Atomically bind the returned provider ID and mark the row active.
- Return 201 with `session` and `realtime`, including the Azure `webrtc_url`.
- Return timezone-aware creation and credential-expiry timestamps.
- Set `Cache-Control: no-store`; do not persist credentials.
- Mark failed on provider failure; return generic errors without provider payloads.
- On activation failure, withhold the credential and attempt to mark failed.
  The unused token expires naturally. No WebRTC call has been opened by this API.
- Optional `Idempotency-Key` reserves one session per key; see the
  [recovery contract](session-recovery-and-completeness.md). No automatic retries.

`active` means ready for a client connection. It does not prove the client connected.
The client connects directly to Realtime using the temporary token. The requested
practice duration does not enforce a connection lifetime or token lifetime.

| HTTP status | Meaning |
|---|---|
| 200 | Keyed replay of current session; realtime is null |
| 409 | Key conflicts with preferences or creation is in progress |
| 201 | Application session and Realtime credential prepared |
| 429 | Account request or session-start quota reached; `Retry-After` gives seconds to wait |
| 415 | Content type is not application/json |
| 422 | Request validation failed or JSON is malformed |
| 502 | Provider rejected the request, failed, or returned invalid data |
| 503 | Azure configuration missing/invalid or storage unavailable |
| 504 | Provider timed out |

Errors use `{"detail": ...}`. Validation detail is a list of field errors; other
detail values are strings. Azure Functions requires a function key via
`x-functions-key` only when the Function trigger uses key protection. The hosted
browser uses Azure platform sign-in; native clients use validated Entra bearer
tokens. Account ownership and per-account rate limits are implemented locally;
the Azure trust boundary and edge limits remain deployment checks. Local FastAPI
TestClient bypasses the Azure host.

## Verification

- `backend/tests/conftest.py`: reusable settings, temporary database, provider mock, and client.
- `backend/tests/test_session_creation.py`: workflow, state transitions, validation,
  provider/storage failures, retries, and Azure configuration errors.
- `backend/tests/test_realtime.py`: Azure endpoint, authentication header, deployment name,
  timeout configuration, and trailing-slash handling.
- `backend/tests/test_api.py`: health and documented routes.

External HTTP is mocked; SQLite and application code run normally. On 2026-09-07,
41 tests passed under Python 3.11, with one dependency deprecation warning.
Separate real Azure checks verified health 200, unauthorized access 401, invalid
input 422, and session creation 201 with an active session and Azure credential.
These checks did not establish a browser WebRTC connection.

## Remaining work

- [x] Real Azure provider credential request and hosted session creation smoke test.
- [ ] Browser WebRTC voice smoke test.
- [x] Azure function-key protection for hosted testing.
- [x] Per-user ownership and database-backed account quotas implemented locally.
- [ ] Verify hosted authentication and add an edge limit before public use.
- [ ] Explicit OpenAPI request and response examples.
- [x] Optional idempotency keys with credential-free replay.
- [x] Recover stale creating rows and reject late activation.
- [ ] Credential refresh/reconnection and provider call ID correlation.
- [ ] Measure multi-instance load on [hosted PostgreSQL](hosted-storage-api-contract.md).

Evaluation remains deferred. Session ending is implemented; see README.md. Learner recording
uploads and finalized transcript storage are specified in the separate
[learner-input contract](learner-inputs-api-contract.md).

### Choice-based setup release — 2026-09-17

- Deployed backend and browser assets to `spoken-agent-func-4fa2534c` with a remote
  build; Azure reported successful deployment (`41f1045c-4f28-4e0d-8b5c-a6a239cd5e0f`).
- Local verification: 209 backend tests and 41 browser tests passed (one backend
  dependency deprecation warning).
- Authenticated hosted checks confirmed the new choices and default agent-selected
  topic, OpenAPI loading, invalid input returning 422, and a request omitting topic
  returning 201 with null topic and an expiring real Realtime credential.
- Anonymous health access returned 401; Microsoft sign-in protection remains enabled.
- This verifies session creation, not a live WebRTC conversation or topic quality.

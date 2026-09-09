# POST /sessions contract

This document now describes the implemented session-start scope. The previous
contract-only adapter gate is superseded by the request to implement session start.

## Implemented

- JSON request: `speaking_goal`, `level`, `preferred_topic`, `session_duration_minutes`.
- Trim strings; require 2–500 / 2–50 / 2–200 characters respectively.
- Level remains free text. Duration is a strict integer from 1 to 120.
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
| 415 | Content type is not application/json |
| 422 | Request validation failed or JSON is malformed |
| 502 | Provider rejected the request, failed, or returned invalid data |
| 503 | Azure configuration missing/invalid or storage unavailable |
| 504 | Provider timed out |

Errors use `{"detail": ...}`. Validation detail is a list of field errors; other
detail values are strings. Azure Functions requires a function key via
`x-functions-key` (missing/invalid keys return 401). Per-user authentication and
rate limiting are not implemented. Local FastAPI TestClient bypasses the Azure host.

## Verification

- `tests/conftest.py`: reusable settings, temporary database, provider mock, and client.
- `tests/test_session_creation.py`: workflow, state transitions, validation,
  provider/storage failures, retries, and Azure configuration errors.
- `tests/test_realtime.py`: Azure endpoint, authentication header, deployment name,
  timeout configuration, and trailing-slash handling.
- `tests/test_api.py`: health and documented routes.

External HTTP is mocked; SQLite and application code run normally. On 2026-09-07,
41 tests passed under Python 3.11, with one dependency deprecation warning.
Separate real Azure checks verified health 200, unauthorized access 401, invalid
input 422, and session creation 201 with an active session and Azure credential.
These checks did not establish a browser WebRTC connection.

## Remaining work

- [x] Real Azure provider credential request and hosted session creation smoke test.
- [ ] Browser WebRTC voice smoke test.
- [x] Azure function-key protection for hosted testing.
- [ ] Per-user authentication and rate limiting before public use.
- [ ] Explicit OpenAPI request and response examples.
- [x] Optional idempotency keys with credential-free replay.
- [x] Recover stale creating rows and reject late activation.
- [ ] Credential refresh/reconnection and provider call ID correlation.
- [ ] Choose durable deployment storage; SQLite here is for local development.

Evaluation remains deferred. Session ending is implemented; see README.md. Learner recording
uploads and finalized transcript storage are specified in the separate
[learner-input contract](todo-learner-inputs-api-contract.md).

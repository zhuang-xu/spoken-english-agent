# Browser WebRTC connection

## Purpose and scope

Implement a same-origin browser client at `GET /practice`, using the existing
[session contract](todo-sessions-api-contract.md). No new provider proxy or storage
transition is introduced. `active` in SQLite still means credentials issued;
Disconnect closes local media/transport, not the backend session row.

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
The Azure Functions adapter retains FUNCTION authorization for all routes, including
assets. Hosted use requires a trusted same-origin authenticated gateway supplying
the function header for backend requests; public hosting/auth changes are deferred.
Use localhost or HTTPS for microphone access. Keep the existing deployment setting;
this feature makes no model/resource changes.

Protocol reference checked 2026-09-08:
[Microsoft WebRTC guide](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-webrtc).
Live deployment availability and real media connectivity require separate checks.

## Acceptance and verification

Implemented in `app/static/` and served by `app/main.py`. No schema or provider
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
| Page/assets served, no credentials or provider request, missing asset 404 | `tests/test_browser.py` |
| SDP POST URL, bearer header, answer, audio track, opening event, transcript | `tests/browser/realtime.test.mjs`: happy path |
| Permission denial and duplicate start | permission / Disconnect tests |
| Backend status errors, invalid/expired credentials, bad SDP, network | HTTP and cleanup cases |
| Disconnect during permission, session response, SDP response | late-result tests |
| Setup timeout, failed connection, retry, safe event errors | lifecycle tests |
| Existing validation, storage and provider error transitions | existing session/provider pytest suite |

Automated tests mock external HTTP and browser media. They establish connection
logic, not actual WebRTC negotiation, codec compatibility, or audible playback.

Deferred: cloud deployment/GitHub publication, real conversation verification,
automatic reconnection/token refresh, duration enforcement, transcript/audio uploads,
session ending, and per-user authentication.

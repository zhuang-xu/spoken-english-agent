# Spoken Agents reference and work summary

Recorded on 2026-09-07. Recheck live resources and repository state before reuse.
Paths below are relative to the repository root; this skill can be installed
outside the repository, so resolve them against the active workspace.

## Contract and implementation

The existing contract is `docs/todo-sessions-api-contract.md`, not `todo-contract.md`.
It describes `POST /sessions`; `GET /health` is the other implemented route.
Recording, evaluation, session ending, browser UI, and reconnection are deferred.

The session request takes `speaking_goal`, `level`, `preferred_topic`, and
`session_duration_minutes`. Strings are trimmed and length-validated; duration is
a strict integer from 1 to 120. Extra fields are rejected.

The implemented flow is:

1. Validate request and Azure configuration.
2. Generate an application session ID and save a SQLite row as `creating`.
3. Request a 60-second Azure Realtime client credential.
4. Store the provider session ID and mark the row `active`.
5. Return 201 with session data, temporary credential, and Azure WebRTC URL;
   set `Cache-Control: no-store`.

Provider failure marks the row failed. Activation failure withholds the credential.
No credentials are persisted. Every retry creates a new session; no idempotency.
Active means credentials ready, not an established voice connection.

| File | Responsibility |
|---|---|
| `app/schemas.py` | Request and response validation |
| `app/main.py` | FastAPI routes and JSON requirement |
| `app/services/sessions.py` | Session workflow and failure handling |
| `app/services/realtime.py` | Azure OpenAI HTTP request and response parsing |
| `app/storage/sqlite.py` | Session persistence |
| `app/config.py` | Environment settings |
| `function_app.py` | Azure Functions ASGI adapter with FUNCTION authorization |
| `host.json` | Empty route prefix; routes do not start with `/api` |

The service initially called OpenAI directly, then migrated to Azure OpenAI.
Current settings: `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`,
`AZURE_OPENAI_DEPLOYMENT`, `REALTIME_VOICE`, and `DATABASE_PATH`.
The old `OPENAI_API_KEY` and `REALTIME_MODEL` are unused.
Azure uses `api-key` for the resource credential and the deployment name in
`session.model`. The client-secret path is `/openai/v1/realtime/client_secrets`;
the returned `realtime.webrtc_url` ends in `/openai/v1/realtime/calls`.

## Test evolution and evidence

Session tests originally lived in `tests/test_api.py`. They were split and shared
setup was extracted for reuse:

- `tests/conftest.py`: settings, temporary SQLite, fake response,
  `mock_openai_post`, and API client fixtures.
- `tests/test_session_creation.py`: session behavior, state transitions, validation,
  provider/storage errors, and missing or invalid Azure settings.
- `tests/test_realtime.py`: Azure URL, key header, deployment name, timeout, and
  trailing-slash handling. Reuses the mock without a database workflow.
- `tests/test_api.py`: health and documented routes.

The local `.venv` used Python 3.14, so verification used a separate Python 3.11
environment. The historical temporary path was `/private/tmp/spoken-agents-tests-311`;
do not assume it survives. Recreate a compatible environment when necessary.
The latest completed suite had 41 passing tests and one Starlette/AnyIO deprecation
warning. No real HTTP provider calls were made by pytest.

## Azure deployment and hosted verification

- Function App: `spoken-agent-func-4fa2534c`, East US, Python 3.11.
- Resource group: `spoken-agents-rg`.
- Host: `https://spoken-agent-func-4fa2534c.azurewebsites.net`.
- Azure OpenAI resource: `spoken-agents-openai-4fa2534c`, East US 2.
- Endpoint: `https://spoken-agents-openai-4fa2534c.openai.azure.com`.
- Deployment: `gpt-realtime-2.1`, version `2026-07-07`, GlobalStandard capacity 1.

A dedicated AI resource and model deployment were created. The Azure resource key
was transferred into app settings without displaying it or storing it locally.
A source ZIP was deployed with remote build; Azure confirmed successful deployment.
Real checks passed: anonymous health 401, authenticated health 200, OpenAPI routes
correct, invalid session 422, and valid session 201 with a real Azure credential.
The credential itself was withheld from logs.

The function key protects requests to this backend and goes in `x-functions-key`.
It is separate from the Azure OpenAI resource key. A browser voice session has not
been tested. SQLite uses `/tmp/spoken_agents.sqlite3`; it is temporary and not shared
between instances. Per-user authentication and rate limiting remain unfinished.

## GitHub status

Configured remote: `git@github.com:zhuang-xu/spoken-english-agent-mvp.git`.
The conversation did not include a completed commit/push. GitHub upload is a future
release stage, not historical evidence. Verify the branch, working tree, and remote
before publication; the workspace contains pre-existing modifications and deletions.

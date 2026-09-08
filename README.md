# Spoken English Agent — Session Start

This project currently implements **POST /sessions** and **GET /health** only.
Recording uploads, transcript events, evaluation, and session ending are deferred.

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

## Six classes, all data

All six classes declare zero custom methods; Pydantic supplies validation and
serialization. Application behavior lives in ordinary functions.

| Class | What it represents | Why it exists |
|---|---|---|
| `Settings` | Server configuration | Loads database path, API key, model, and voice. |
| `SessionCreate` | Learner's four preferences | Validates input before spending money or writing a session. |
| `Session` | Successfully created application session | Adds a server-generated ID, active status, and timestamp. |
| `RealtimeClientCredential` | Temporary token and expiry | Makes the client connection data explicit. |
| `RealtimeSession` | Provider ID and credential | Keeps provider connection details together. |
| `CreateSessionResponse` | Session plus Realtime details | Defines exactly what the endpoint returns. |

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
  storage outage. A process crash may leave a creating row; recovery is deferred.
- `active` means connection credentials are ready, not that WebRTC is connected.
- No idempotency: every retry may create a new session. No automatic retries.
- Authentication and rate limiting are not implemented; this is a local-development API.
- There is no browser client, credential refresh endpoint, or enforced session timer yet.

## Tests

```bash
python -m pytest -q
```

Tests exercise the real route, workflow, response parsing, and temporary SQLite
database, with only the provider HTTP call mocked. See
[session-start contract](docs/todo-sessions-api-contract.md) for remaining work.

Provider reference: [Azure OpenAI Realtime WebRTC guide](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-webrtc).

## Azure deployment and testing

The existing Function App is `spoken-agent-func-4fa2534c` in resource group
`spoken-agents-rg`, running managed Python 3.11. Deploy the Python source,
`function_app.py`, `host.json`, and `requirements.txt` with a remote build. Do not
package `.env`, virtual environments, tests, or local databases.

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
- With a function key: `/health` returns 200 and `/openapi.json` lists the two routes.
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

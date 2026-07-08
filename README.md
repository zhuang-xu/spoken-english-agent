# Spoken English Agent MVP

FastAPI backend for a turn-based English speaking practice app using Azure-ready service adapters.

## What It Does

- Creates a session plan from a learner goal, level, topic, and duration.
- Handles turn-based conversation from transcript input or uploaded audio.
- Uses STT when audio is provided.
- Generates one concise coach response per turn.
- Stores transcript items and coaching notes in SQLite.
- Produces a final session evaluation with actionable feedback.
- Optionally returns TTS audio for assistant responses.

Realtime speech-to-speech is intentionally out of scope.

## Run Locally

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --reload
```

The default `PROVIDER=mock` lets the API run without Azure credentials.

Health check:

```bash
curl http://127.0.0.1:8000/health
```

## Azure Configuration

Set these values in `.env` and change `PROVIDER` to `azure`:

```dotenv
PROVIDER="azure"
AZURE_OPENAI_ENDPOINT="https://your-resource.openai.azure.com/"
AZURE_OPENAI_API_KEY="..."
AZURE_OPENAI_API_VERSION="2024-10-21"
AZURE_OPENAI_DEPLOYMENT="gpt-4o-mini"

AZURE_SPEECH_KEY="..."
AZURE_SPEECH_REGION="eastus"
AZURE_SPEECH_RECOGNITION_LANGUAGE="en-US"
AZURE_SPEECH_VOICE="en-US-JennyNeural"
```

`AZURE_OPENAI_DEPLOYMENT` must be the deployment name in your Azure OpenAI resource, not just a model family name.

## Current Azure Deployment

This service can run on Azure Functions Flex Consumption through the ASGI entrypoint in `function_app.py`.

The current deployed mock-mode endpoint is:

```text
https://spoken-agent-func-4fa2534c.azurewebsites.net
```

Health check:

```bash
curl https://spoken-agent-func-4fa2534c.azurewebsites.net/health
```

To switch the deployed app from mock mode to Azure OpenAI and Azure Speech, set the Function App settings:

```bash
az functionapp config appsettings set \
  --resource-group spoken-agents-rg \
  --name spoken-agent-func-4fa2534c \
  --settings \
    PROVIDER="azure" \
    AZURE_OPENAI_ENDPOINT="https://your-resource.openai.azure.com/" \
    AZURE_OPENAI_API_KEY="..." \
    AZURE_OPENAI_DEPLOYMENT="your-deployment-name" \
    AZURE_SPEECH_KEY="..." \
    AZURE_SPEECH_REGION="eastus"
```

The deployed MVP currently uses `/tmp/spoken_agents.sqlite3`, which is suitable only for smoke testing. Use Azure PostgreSQL, Cosmos DB, or Azure SQL before relying on stored transcripts in production.

## API

Create a session:

```bash
curl -X POST http://127.0.0.1:8000/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "speaking_goal": "Interview practice",
    "level": "B1",
    "preferred_topic": "backend projects",
    "session_duration_minutes": 15
  }'
```

Send a transcript turn:

```bash
curl -X POST http://127.0.0.1:8000/sessions/{session_id}/turns \
  -H "Content-Type: application/json" \
  -d '{"transcript": "I want to explain a project I built last month."}'
```

Send an audio turn:

```bash
curl -X POST http://127.0.0.1:8000/sessions/{session_id}/turns/audio \
  -F "audio=@answer.wav" \
  -F "return_audio=false"
```

End and evaluate a session:

```bash
curl -X POST http://127.0.0.1:8000/sessions/{session_id}/end
```

## Tests

```bash
pytest
```

"""Shared pytest fixtures, available to every test file without imports."""
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.main import app
from app.services import realtime


@pytest.fixture
def settings(tmp_path):
    """Use a fake API key and a fresh database for each test."""
    return Settings(
        _env_file=None,
        database_path=str(tmp_path / "test.sqlite3"),
        azure_openai_api_key="server-secret",
        azure_openai_endpoint="https://test-resource.openai.azure.com",
        azure_openai_deployment="test-realtime-deployment",
    )


@pytest.fixture
def realtime_response():
    """Default successful OpenAI Realtime client-secret response."""
    return httpx.Response(
        200,
        request=httpx.Request("POST", "https://test-resource.openai.azure.com/openai/v1/realtime/client_secrets"),
        json={
            "value": "ephemeral-token",
            "expires_at": int((datetime.now(timezone.utc) + timedelta(minutes=1)).timestamp()),
            "session": {"id": "provider-1"},
        },
    )


@pytest.fixture
def mock_openai_post(monkeypatch, realtime_response):
    """Replace the synchronous provider POST and record calls.

    Set return_value to another httpx.Response, or side_effect to an exception
    or callback. The default response is specific to Realtime client secrets.
    Each test gets a fresh mock; monkeypatch restores HTTP afterward.
    """
    mock = Mock(return_value=realtime_response)
    monkeypatch.setattr(realtime.httpx, "post", mock)
    return mock


@pytest.fixture
def client(settings, mock_openai_post, monkeypatch):
    """API client with isolated settings and mocked provider HTTP."""
    monkeypatch.setitem(app.dependency_overrides, get_settings, lambda: settings)
    with TestClient(app) as test_client:
        yield test_client, settings


@pytest.fixture
def learner_turn(client):
    """An active session and reusable learner turn upload URLs and transcript."""
    from uuid import uuid4

    api, settings = client
    session_id = api.post("/sessions", json={
        "speaking_goal": "Interview practice", "level": "B1",
        "preferred_topic": "work", "session_duration_minutes": 15,
    }).json()["session"]["id"]
    turn_id = str(uuid4())
    return api, settings, f"/sessions/{session_id}/learner-turns/{turn_id}", {
        "text": "I built an application.", "start_ms": 1000, "end_ms": 3500,
        "provider_item_id": "item_learner_1",
    }


@pytest.fixture
def agent_transcript(learner_turn):
    """An agent content part in an active session, with observed playback timing."""
    api, settings, base, _ = learner_turn
    session_id = base.split('/')[2]
    return api, settings, f"/sessions/{session_id}/agent-items", {
        "text": "What did you build?", "response_id": "resp_1",
        "previous_item_id": "learner_1", "playback_status": "completed",
        "start_ms": 4000, "end_ms": 5500,
    }

"""Session creation tests: real API and SQLite, fake OpenAI HTTP responses."""
import json
import sqlite3
from datetime import datetime, timezone

import httpx
import pytest

from app.services import sessions

PREFERENCES = {
    "speaking_goal": "Interview practice", "level": "B1",
    "preferred_topic": "backend projects", "session_duration_minutes": 15,
}


@pytest.fixture(autouse=True)
def check_session_provider_request(settings, mock_openai_post):
    """Session-specific checks run at the moment the provider is called."""
    def check_request(url, **kwargs):
        assert url == "https://test-resource.openai.azure.com/openai/v1/realtime/client_secrets"
        assert kwargs["headers"] == {"api-key": "server-secret"}
        with sqlite3.connect(settings.database_path) as connection:
            row = connection.execute(
                "SELECT status, preferences FROM practice_sessions ORDER BY rowid DESC"
            ).fetchone()
        assert row[0] == "creating"
        payload = kwargs["json"]
        assert payload["session"]["model"] == settings.azure_openai_deployment
        assert payload["session"]["audio"]["output"]["voice"] == settings.realtime_voice
        assert json.dumps(json.loads(row[1]), separators=(",", ":")) in payload["session"]["instructions"]
        assert payload["expires_after"]["seconds"] == 60
        return mock_openai_post.return_value

    mock_openai_post.side_effect = check_request


def stored(settings):
    with sqlite3.connect(settings.database_path) as connection:
        return connection.execute("SELECT * FROM practice_sessions").fetchall()


def test_create_session(client):
    api, settings = client
    response = api.post("/sessions", json=PREFERENCES)
    assert response.status_code == 201
    body = response.json()
    assert set(body) == {"session", "realtime"}
    assert body["session"]["status"] == "active"
    assert body["session"]["preferences"] == PREFERENCES
    assert datetime.fromisoformat(body["session"]["created_at"].replace("Z", "+00:00")).tzinfo
    assert body["realtime"]["provider_session_id"] == "provider-1"
    assert body["realtime"]["webrtc_url"] == "https://test-resource.openai.azure.com/openai/v1/realtime/calls"
    credential = body["realtime"]["client_credential"]
    assert credential["value"] == "ephemeral-token"
    assert datetime.fromisoformat(credential["expires_at"].replace("Z", "+00:00")) > datetime.now(timezone.utc)
    assert response.headers["cache-control"] == "no-store"
    rows = stored(settings)
    assert rows[0][0] == body["session"]["id"]
    assert rows[0][1] == "active" and rows[0][4] == "provider-1"
    assert "ephemeral-token" not in str(rows) and "server-secret" not in response.text


@pytest.mark.parametrize("field", [key for key in PREFERENCES if key != "preferred_topic"])
def test_missing_fields(client, field):
    api, settings = client
    body = PREFERENCES.copy()
    del body[field]
    assert api.post("/sessions", json=body).status_code == 422
    from pathlib import Path
    assert not Path(settings.database_path).exists()


@pytest.mark.parametrize("field,value", [
    ("speaking_goal", " "), ("level", "A"), ("preferred_topic", "x"),
    ("speaking_goal", "x" * 501), ("level", "x" * 51),
    ("preferred_topic", "x" * 201), ("session_duration_minutes", 0),
    ("session_duration_minutes", 121), ("session_duration_minutes", 1.5),
    ("session_duration_minutes", "15"), ("session_duration_minutes", True),
    ("unknown", "value"),
])
def test_invalid_preferences(client, field, value):
    api, _ = client
    assert api.post("/sessions", json={**PREFERENCES, field: value}).status_code == 422


@pytest.mark.parametrize("duration", [1, 120])
def test_boundaries_and_trim(client, duration):
    api, _ = client
    response = api.post("/sessions", json={**PREFERENCES,
        "level": " B1 ", "session_duration_minutes": duration})
    assert response.status_code == 201
    assert response.json()["session"]["preferences"]["level"] == "B1"


@pytest.mark.parametrize("kind,status", [("timeout", 504), ("rejected", 502), ("malformed", 502)])
def test_provider_failure(client, mock_openai_post, kind, status):
    api, settings = client

    def failure(url, **kwargs):
        if kind == "timeout":
            raise httpx.ReadTimeout("server-secret ephemeral-token")
        return httpx.Response(401 if kind == "rejected" else 200,
                              request=httpx.Request("POST", url), json={"error": "server-secret"})

    mock_openai_post.side_effect = failure
    response = api.post("/sessions", json=PREFERENCES)
    assert response.status_code == status
    assert stored(settings)[0][1] == "failed"
    assert "server-secret" not in response.text


def test_missing_key(client):
    api, settings = client
    from pydantic import SecretStr
    settings.azure_openai_api_key = SecretStr("")
    assert api.post("/sessions", json=PREFERENCES).status_code == 503


def test_storage_failure_does_not_call_provider(client, monkeypatch):
    api, _ = client

    def unavailable(*args):
        raise sqlite3.OperationalError("unavailable")

    def unexpected(*args):
        pytest.fail("Provider must not be called before persistence succeeds")

    monkeypatch.setattr(sessions, "save_creating_session", unavailable)
    monkeypatch.setattr(sessions, "create_realtime_session", unexpected)
    assert api.post("/sessions", json=PREFERENCES).status_code == 503


def test_activation_failure_withholds_credential(client, monkeypatch):
    api, settings = client
    original = sessions.update_session

    def update(path, session_id, status, provider_session_id=None):
        if status == "active":
            raise sqlite3.OperationalError("activation failed")
        original(path, session_id, status, provider_session_id)

    monkeypatch.setattr(sessions, "update_session", update)
    response = api.post("/sessions", json=PREFERENCES)
    assert response.status_code == 503
    assert "ephemeral-token" not in response.text
    assert stored(settings)[0][1] == "failed"


def test_retry_creates_a_new_session(client):
    api, settings = client
    first = api.post("/sessions", json=PREFERENCES).json()
    second = api.post("/sessions", json=PREFERENCES).json()
    assert first["session"]["id"] != second["session"]["id"]
    assert len(stored(settings)) == 2


def test_non_json_content_type(client):
    api, _ = client
    response = api.post("/sessions", content="{}", headers={"Content-Type": "text/plain"})
    assert response.status_code == 415


def test_malformed_json(client):
    api, _ = client
    response = api.post("/sessions", content="{", headers={"Content-Type": "application/json"})
    assert response.status_code == 422


@pytest.mark.parametrize("value,expires_at", [
    ("", 4102444800), ("token", 1),
])
def test_invalid_credential(client, mock_openai_post, value, expires_at):
    api, settings = client

    def provider(url, **kwargs):
        return httpx.Response(200, request=httpx.Request("POST", url), json={
            "value": value, "expires_at": expires_at, "session": {"id": "provider-1"},
        })

    mock_openai_post.side_effect = provider
    assert api.post("/sessions", json=PREFERENCES).status_code == 502
    assert stored(settings)[0][1] == "failed"


@pytest.mark.parametrize("field,value", [
    ("azure_openai_endpoint", ""),
    ("azure_openai_endpoint", "http://test-resource.openai.azure.com"),
    ("azure_openai_endpoint", "https://test-resource.openai.azure.com/openai/v1"),
    ("azure_openai_endpoint", "https://user:password@test-resource.openai.azure.com"),
    ("azure_openai_endpoint", "https://test-resource.openai.azure.com?query=value"),
    ("azure_openai_endpoint", "https://[invalid"),
    ("azure_openai_deployment", " "),
])
def test_missing_or_invalid_azure_configuration(client, mock_openai_post, field, value):
    from pathlib import Path

    api, settings = client
    setattr(settings, field, value)
    response = api.post("/sessions", json=PREFERENCES)
    assert response.status_code == 503
    assert response.json()["detail"] == "Azure OpenAI is not configured correctly."
    mock_openai_post.assert_not_called()
    assert not Path(settings.database_path).exists()


@pytest.mark.parametrize("topic", [None, "", "   ", "omitted"])
def test_agent_chooses_unspecified_topic(client, mock_openai_post, topic):
    api, settings = client
    preferences = {**PREFERENCES, "preferred_topic": topic}
    if topic == "omitted":
        del preferences["preferred_topic"]
    response = api.post("/sessions", json=preferences)
    assert response.status_code == 201
    assert response.json()["session"]["preferences"]["preferred_topic"] is None
    assert json.loads(stored(settings)[0][3])["preferred_topic"] is None
    instructions = mock_openai_post.call_args.kwargs["json"]["session"]["instructions"]
    assert "choose a concrete topic" in instructions
    assert "without asking the learner to choose a topic" in instructions

"""Azure provider tests reuse the shared mock without a session/database workflow."""
import pytest

from app.schemas import SessionCreate
from app.services.realtime import create_realtime_session


@pytest.mark.parametrize("trailing_slash", [False, True])
def test_azure_request(settings, mock_openai_post, trailing_slash):
    if trailing_slash:
        settings.azure_openai_endpoint += "/"
    preferences = SessionCreate(
        speaking_goal="Interview practice", level="B1",
        preferred_topic="backend projects", session_duration_minutes=15,
    )
    result = create_realtime_session(preferences, settings)
    mock_openai_post.assert_called_once()
    args, kwargs = mock_openai_post.call_args
    assert args == ("https://test-resource.openai.azure.com/openai/v1/realtime/client_secrets",)
    assert kwargs["headers"] == {"api-key": "server-secret"}
    assert kwargs["json"]["session"]["model"] == "test-realtime-deployment"
    assert kwargs["timeout"] == 20.0
    assert result.webrtc_url == "https://test-resource.openai.azure.com/openai/v1/realtime/calls"
    assert result.client_credential.value == "ephemeral-token"


def test_supported_outcome_changes_conversation(settings, mock_openai_post):
    preferences = SessionCreate(
        speaking_goal="Explain ideas clearly", level="B1",
        preferred_topic=None, session_duration_minutes=10,
    )
    create_realtime_session(preferences, settings)
    instructions = mock_openai_post.call_args.kwargs["json"]["session"]["instructions"]
    assert "explain a process or idea" in instructions
    assert "give a concrete example" in instructions

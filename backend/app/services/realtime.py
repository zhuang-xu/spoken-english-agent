"""Request an expiring Realtime credential from Azure OpenAI using the server's resource key."""
from datetime import datetime, timezone

import httpx

from app.config import Settings
from app.schemas import RealtimeClientCredential, RealtimeSession, SessionCreate
from app.services.outcomes import outcome_guidance


def create_realtime_session(preferences: SessionCreate, settings: Settings) -> RealtimeSession:
    outcome_instruction = outcome_guidance(preferences.speaking_goal, "conversation")
    response = httpx.post(
        f"{settings.azure_openai_endpoint.rstrip('/')}/openai/v1/realtime/client_secrets",
        headers={"api-key": settings.azure_openai_api_key.get_secret_value()},
        json={
            "expires_after": {"anchor": "created_at", "seconds": 60},
            "session": {
                "type": "realtime",
                "model": settings.azure_openai_deployment,
                "audio": {"output": {"voice": settings.realtime_voice}},
                "instructions": (
                    "You are a supportive English speaking practice partner. "
                    "Ask one short question at a time, adapted to the learner's level. "
                    "Begin with a relevant opening question when asked to respond. "
                    + (f"For this supported speaking outcome: {outcome_instruction} "
                       if outcome_instruction else "")
                    +
                    "If preferred_topic is null or blank, choose a concrete topic that fits "
                    "the learner's speaking_goal and level, and start practicing immediately "
                    "without asking the learner to choose a topic. Otherwise use their preferred topic. "
                    "Use these learner preferences as context:\n"
                    + preferences.model_dump_json()
                ),
            },
        },
        timeout=20.0,
    )
    response.raise_for_status()
    data = response.json()
    credential = RealtimeClientCredential(
        value=data["value"],
        expires_at=datetime.fromtimestamp(data["expires_at"], tz=timezone.utc),
    )
    if credential.expires_at <= datetime.now(timezone.utc):
        raise ValueError("Provider returned an expired credential.")
    return RealtimeSession(
        provider_session_id=data["session"]["id"], client_credential=credential,
        webrtc_url=f"{settings.azure_openai_endpoint.rstrip('/')}/openai/v1/realtime/calls",
    )

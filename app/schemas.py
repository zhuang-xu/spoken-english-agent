"""Only the input and output data needed to start a practice session."""
from typing import Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field


class SessionCreate(BaseModel):
    """The four preferences supplied by the learner, before a session exists."""

    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    speaking_goal: str = Field(min_length=2, max_length=500)
    level: str = Field(min_length=2, max_length=50)
    preferred_topic: str = Field(min_length=2, max_length=200)
    session_duration_minutes: int = Field(ge=1, le=120, strict=True)


class Session(BaseModel):
    """The successfully created application session returned to the learner."""

    id: str
    status: Literal["active"] = "active"
    created_at: AwareDatetime
    preferences: SessionCreate


class RealtimeClientCredential(BaseModel):
    """A short-lived connection token; never saved in our database."""

    value: str = Field(min_length=1, repr=False)
    expires_at: AwareDatetime


class RealtimeSession(BaseModel):
    """Provider connection information returned with the credential."""

    provider_session_id: str = Field(min_length=1)
    client_credential: RealtimeClientCredential
    webrtc_url: str = Field(min_length=1)


class CreateSessionResponse(BaseModel):
    """The complete POST /sessions response: our session plus connection details."""

    session: Session
    realtime: RealtimeSession

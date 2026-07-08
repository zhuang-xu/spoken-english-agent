from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydantic import BaseModel, Field


class Speaker(str, Enum):
    user = "user"
    assistant = "assistant"


class SessionStatus(str, Enum):
    active = "active"
    completed = "completed"


class SessionCreate(BaseModel):
    speaking_goal: str = Field(..., min_length=2, examples=["Interview practice"])
    level: str = Field(..., min_length=2, examples=["B1"])
    preferred_topic: str = Field(..., min_length=2, examples=["product design"])
    session_duration_minutes: int = Field(..., ge=1, le=120, examples=[15])


class SessionPlan(BaseModel):
    topic: str
    opening_question: str
    follow_up_strategy: list[str]
    target_expressions: list[str]
    evaluation_rubric: dict[str, str]


class Session(BaseModel):
    id: str
    status: SessionStatus
    created_at: datetime
    preferences: SessionCreate
    plan: SessionPlan


class CreateSessionResponse(BaseModel):
    session: Session
    assistant_response: str


class TurnRequest(BaseModel):
    transcript: str | None = Field(default=None, min_length=1)
    return_audio: bool = False


class TurnResponse(BaseModel):
    session_id: str
    user_transcript: str
    assistant_response: str
    coaching_note: str | None = None
    audio_base64: str | None = None


class TranscriptItem(BaseModel):
    speaker: Speaker
    text: str
    created_at: datetime
    metadata: dict[str, Any] = Field(default_factory=dict)


class Evaluation(BaseModel):
    fluency_feedback: str
    grammar_feedback: str
    vocabulary_feedback: str
    pronunciation_pace_feedback: str | None = None
    top_3_issues: list[str]
    next_practice_suggestion: str


class EndSessionResponse(BaseModel):
    session_id: str
    status: Literal["completed"]
    transcript: list[TranscriptItem]
    evaluation: Evaluation

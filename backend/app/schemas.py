"""Only the input and output data needed to start a practice session."""
from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator


class SessionCreate(BaseModel):
    """The four preferences supplied by the learner, before a session exists."""

    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    speaking_goal: str = Field(min_length=2, max_length=500)
    level: str = Field(min_length=2, max_length=50)
    preferred_topic: str | None = Field(default=None, max_length=200)
    session_duration_minutes: int = Field(ge=1, le=120, strict=True)

    @field_validator("preferred_topic")
    @classmethod
    def normalize_topic(cls, value: str | None) -> str | None:
        if not value:
            return None
        if len(value) < 2:
            raise ValueError("Topic must contain at least two characters")
        return value


class Session(BaseModel):
    """The successfully created application session returned to the learner."""

    id: str
    status: Literal["creating", "active", "failed", "ended"] = "active"
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
    realtime: RealtimeSession | None


class EndSessionResponse(BaseModel):
    session_id: str
    status: Literal["ended"] = "ended"
    ended_at: AwareDatetime


class HeartbeatResponse(BaseModel):
    session_id: str
    status: Literal["active"] = "active"
    last_activity_at: AwareDatetime


class LearnerTranscript(BaseModel):
    """Finalized learner text and offsets on the client's session recording clock."""

    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    text: str = Field(min_length=1, max_length=20000)
    start_ms: int = Field(ge=0, strict=True)
    end_ms: int = Field(ge=0, strict=True)
    provider_item_id: str | None = Field(default=None, min_length=1, max_length=200)


class LearnerInputReceipt(BaseModel):
    session_id: str
    turn_id: str
    audio_received: bool
    transcript_received: bool


class AgentTranscript(BaseModel):
    """Generated agent text with optional client-observed playback metadata."""

    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    text: str = Field(max_length=20000)
    response_id: str = Field(min_length=1, max_length=200)
    previous_item_id: str | None = Field(default=None, min_length=1, max_length=200,
                                          pattern=r"^[A-Za-z0-9_-]+$")
    playback_status: Literal["unknown", "completed", "interrupted"] = "unknown"
    start_ms: int | None = Field(default=None, ge=0, strict=True)
    end_ms: int | None = Field(default=None, ge=0, strict=True)


class AgentTranscriptReceipt(BaseModel):
    session_id: str
    item_id: str
    content_index: int
    transcript_received: Literal[True] = True


class AgentPartReference(BaseModel):
    model_config = ConfigDict(extra="forbid")
    item_id: str = Field(min_length=1, max_length=200, pattern=r"^[A-Za-z0-9_-]+$")
    content_index: int = Field(ge=0, strict=True)


class UploadInventory(BaseModel):
    """Component identities in a stored-data snapshot."""
    audio_turn_ids: list[UUID]
    transcript_turn_ids: list[UUID]
    agent_transcripts: list[AgentPartReference]


class UploadManifest(UploadInventory):
    """The client's final inventory of expected components, including not-yet-uploaded ones."""
    model_config = ConfigDict(extra="forbid")
    audio_turn_ids: list[UUID] = Field(max_length=1000)
    transcript_turn_ids: list[UUID] = Field(max_length=1000)
    agent_transcripts: list[AgentPartReference] = Field(max_length=1000)


class SessionDataStatus(BaseModel):
    session_id: str
    session_status: Literal["creating", "active", "failed", "ended"]
    manifest_received: bool
    data_complete: bool
    ready_for_evaluation: bool
    missing: UploadInventory
    unexpected: UploadInventory


class EvaluationCategory(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    score: int | None = Field(ge=1, le=5)
    feedback: str = Field(min_length=1, max_length=2000)


class EvaluationCorrection(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    turn_id: str
    original: str = Field(min_length=1, max_length=2000)
    improved: str = Field(min_length=1, max_length=2000)
    explanation: str = Field(min_length=1, max_length=2000)


class EvaluationResult(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    summary: str = Field(min_length=1, max_length=3000)
    grammar: EvaluationCategory
    vocabulary: EvaluationCategory
    coherence: EvaluationCategory
    strengths: list[str] = Field(min_length=1, max_length=3)
    next_steps: list[str] = Field(min_length=1, max_length=3)
    corrections: list[EvaluationCorrection] = Field(max_length=10)


class EvaluationSynthesis(BaseModel):
    """Cross-category coaching produced from saved transcript and Speech results."""

    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    summary: str = Field(min_length=1, max_length=3000)
    strengths: list[str] = Field(min_length=1, max_length=3)
    next_steps: list[str] = Field(min_length=1, max_length=3)


class SpeechPhoneme(BaseModel):
    model_config = ConfigDict(extra="forbid")
    phoneme: str
    accuracy_score: float = Field(ge=0, le=100, allow_inf_nan=False)


class SpeechWord(BaseModel):
    model_config = ConfigDict(extra="forbid")
    word: str
    offset_ms: float = Field(ge=0, allow_inf_nan=False)
    duration_ms: float = Field(gt=0, allow_inf_nan=False)
    accuracy_score: float = Field(ge=0, le=100, allow_inf_nan=False)
    error_type: str
    phonemes: list[SpeechPhoneme]


class SpeechSegment(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str
    offset_ms: float = Field(ge=0, allow_inf_nan=False)
    duration_ms: float = Field(gt=0, allow_inf_nan=False)
    accuracy_score: float = Field(ge=0, le=100, allow_inf_nan=False)
    fluency_score: float = Field(ge=0, le=100, allow_inf_nan=False)
    prosody_score: float | None = Field(default=None, ge=0, le=100, allow_inf_nan=False)
    words: list[SpeechWord]


class SpeechAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid")
    turn_id: str
    audio_sha256: str
    locale: Literal["en-US"] = "en-US"
    status: Literal["assessed", "insufficient_evidence", "unavailable"]
    reason: Literal["too_short", "no_recognized_speech", "too_few_words", "provider_unavailable",
                    "not_configured"] | None = None
    duration_ms: float | None = Field(default=None, gt=0, allow_inf_nan=False)
    segments: list[SpeechSegment] = Field(default_factory=list)


class SpeechSummary(BaseModel):
    """Deterministic session-level summary of the cached turn assessments."""

    assessed_turns: int = Field(ge=0)
    total_turns: int = Field(ge=0)
    assessed_segments: int = Field(ge=0)
    average_pronunciation: int | None = Field(default=None, ge=0, le=100)
    average_spoken_fluency: int | None = Field(default=None, ge=0, le=100)
    average_rhythm_and_intonation: int | None = Field(default=None, ge=0, le=100)


class EvaluationResponse(BaseModel):
    session_id: str
    status: Literal["running", "waiting", "completed", "failed"]
    attempt_id: str
    started_at: AwareDatetime
    completed_at: AwareDatetime | None
    rubric_version: str
    deployment: str
    input_sha256: str
    result: EvaluationResult | None
    error_code: str | None
    transcript_status: Literal["pending", "running", "completed", "failed"] = "pending"
    speech_status: Literal["pending", "running", "completed", "partial", "not_assessed"] = "pending"
    final_status: Literal["pending", "running", "completed", "failed"] = "pending"
    transcript_result: EvaluationResult | None = None
    speech_pending_turn_ids: list[str] = Field(default_factory=list)
    speech_assessments: list[SpeechAssessment] = Field(default_factory=list)
    speech_summary: SpeechSummary | None = None
    transcript_windows_total: int = 0
    transcript_windows_completed: int = 0
    not_assessed: list[str] = Field(default_factory=lambda: ["pronunciation", "spoken_fluency"])


class BatchObservation(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    category: Literal['grammar', 'vocabulary', 'coherence']
    polarity: Literal['strength', 'difficulty', 'uncertain']
    finding: str = Field(min_length=1, max_length=300)
    source_id: str = Field(min_length=1, max_length=100)
    start_char: int = Field(ge=0)
    end_char: int = Field(gt=0)
    quote: str = Field(min_length=1, max_length=200)


class BatchCorrection(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    source_id: str
    start_char: int = Field(ge=0)
    end_char: int = Field(gt=0)
    original: str = Field(min_length=1, max_length=200)
    improved: str = Field(min_length=1, max_length=200)
    explanation: str = Field(min_length=1, max_length=300)


class BatchFindings(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    observations: list[BatchObservation] = Field(max_length=6)
    corrections: list[BatchCorrection] = Field(max_length=3)


class EvidenceSelection(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    observation_ids: list[str] = Field(max_length=6)
    correction_ids: list[str] = Field(max_length=3)


class SessionAggregation(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    summary: str = Field(min_length=1, max_length=3000)
    grammar: EvaluationCategory
    vocabulary: EvaluationCategory
    coherence: EvaluationCategory
    strengths: list[str] = Field(min_length=1, max_length=3)
    next_steps: list[str] = Field(min_length=1, max_length=3)
    observation_ids: list[str] = Field(max_length=36)
    correction_ids: list[str] = Field(max_length=10)

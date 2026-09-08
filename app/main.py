from uuid import UUID

from starlette.concurrency import run_in_threadpool

from fastapi import Path, Depends, FastAPI, HTTPException, Request, Response

from app.schemas import AgentTranscript, AgentTranscriptReceipt
from app.services.agent_transcripts import capture_agent_transcript

from app.config import Settings, get_settings
from app.schemas import CreateSessionResponse, SessionCreate, LearnerTranscript, LearnerInputReceipt
from app.services.learner_inputs import AUDIO_TYPES, MAX_AUDIO_BYTES, capture_input
from app.services.sessions import create_session

app = FastAPI(title="Spoken English Agent")


@app.get("/health")
def health(settings: Settings = Depends(get_settings)) -> dict[str, str]:
    return {"status": "ok", "realtime_model": settings.azure_openai_deployment}


def require_json(request: Request) -> None:
    if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
        raise HTTPException(415, "Content-Type must be application/json.")


@app.post(
    "/sessions", response_model=CreateSessionResponse, status_code=201,
    dependencies=[Depends(require_json)],
    responses={
        415: {"description": "Content-Type must be application/json"},
        502: {"description": "Realtime provider failed or returned invalid data"},
        503: {"description": "API key missing or session storage unavailable"},
        504: {"description": "Realtime provider timed out"},
    },
)
def start_session(
    request: SessionCreate, response: Response,
    settings: Settings = Depends(get_settings),
) -> CreateSessionResponse:
    """Save a session, request a connection credential, and return the active session."""
    result = create_session(request, settings)
    response.headers["Cache-Control"] = "no-store"
    return result


CAPTURE_RESPONSES = {
    200: {"description": "Identical input already stored"},
    404: {"description": "Session not found"},
    409: {"description": "Inactive session or conflicting input"},
    415: {"description": "Unsupported content type"},
    503: {"description": "Input storage unavailable"},
}


@app.put(
    "/sessions/{session_id}/learner-turns/{turn_id}/audio",
    response_model=LearnerInputReceipt, status_code=201,
    responses={**CAPTURE_RESPONSES, 413: {"description": "Audio exceeds 10 MiB"}},
    openapi_extra={"requestBody": {"required": True, "content": {
        media: {"schema": {"type": "string", "format": "binary"}}
        for media in sorted(AUDIO_TYPES)
    }}},
)
async def upload_learner_audio(
    session_id: UUID, turn_id: UUID, request: Request, response: Response,
    settings: Settings = Depends(get_settings),
) -> LearnerInputReceipt:
    """Upload one complete learner recording; no decoding or transcription is performed."""
    media_type = request.headers.get("content-type", "").strip().lower()
    if len(media_type) > 200 or media_type.split(";", 1)[0].strip() not in AUDIO_TYPES:
        raise HTTPException(415, "Supported audio Content-Type is required.")
    audio = bytearray()
    async for chunk in request.stream():
        if len(audio) + len(chunk) > MAX_AUDIO_BYTES:
            raise HTTPException(413, "Audio exceeds 10 MiB.")
        audio.extend(chunk)
    if not audio:
        raise HTTPException(422, "Audio must not be empty.")
    receipt, response.status_code = await run_in_threadpool(
        capture_input, settings, str(session_id), str(turn_id), "audio", bytes(audio), media_type
    )
    response.headers["Cache-Control"] = "no-store"
    return receipt


@app.put(
    "/sessions/{session_id}/learner-turns/{turn_id}/transcript",
    response_model=LearnerInputReceipt, status_code=201,
    dependencies=[Depends(require_json)], responses=CAPTURE_RESPONSES,
)
def upload_learner_transcript(
    session_id: UUID, turn_id: UUID, transcript: LearnerTranscript, response: Response,
    settings: Settings = Depends(get_settings),
) -> LearnerInputReceipt:
    """Store finalized learner text independently of the corresponding audio upload."""
    if transcript.end_ms <= transcript.start_ms:
        raise HTTPException(422, "end_ms must be greater than start_ms.")
    receipt, response.status_code = capture_input(
        settings, str(session_id), str(turn_id), "transcript", transcript.model_dump_json()
    )
    response.headers["Cache-Control"] = "no-store"
    return receipt


@app.put(
    "/sessions/{session_id}/agent-items/{item_id}/transcripts/{content_index}",
    response_model=AgentTranscriptReceipt, status_code=201,
    dependencies=[Depends(require_json)], responses=CAPTURE_RESPONSES,
)
def upload_agent_transcript(
    session_id: UUID, transcript: AgentTranscript, response: Response,
    item_id: str = Path(min_length=1, max_length=200, pattern=r"^[A-Za-z0-9_-]+$"),
    content_index: int = Path(ge=0), settings: Settings = Depends(get_settings),
) -> AgentTranscriptReceipt:
    """Store a finalized agent content part and any known playback context."""
    receipt, response.status_code = capture_agent_transcript(
        settings, str(session_id), item_id, content_index, transcript
    )
    response.headers["Cache-Control"] = "no-store"
    return receipt

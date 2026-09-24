from app.schemas import EvaluationResponse
import logging
import os
import time
from app.services.evaluations import get_evaluation, run_evaluation
from uuid import UUID

from starlette.concurrency import run_in_threadpool

from fastapi import Header, Path, Depends, FastAPI, HTTPException, Request, Response

from app.schemas import AgentTranscript, AgentTranscriptReceipt
from app.services.agent_transcripts import capture_agent_transcript

from app.config import Settings, get_settings
from app.schemas import CreateSessionResponse, EndSessionResponse, SessionCreate, LearnerTranscript, LearnerInputReceipt
from app.services.learner_inputs import AUDIO_TYPES, MAX_AUDIO_BYTES, capture_audio, capture_input
from app.services.sessions import create_session, end_session, heartbeat_session
from app.schemas import HeartbeatResponse
from app.schemas import SessionDataStatus, UploadManifest
from app.services.completeness import get_data_status

app = FastAPI(title="Spoken English Agent")


@app.middleware('http')
async def log_http_result(request: Request, call_next):
    started = time.monotonic()
    response = await call_next(request)
    route = getattr(request.scope.get('route'), 'path', 'unmatched')
    logging.getLogger('spoken.http').log(
        logging.WARNING if response.status_code >= 400 else logging.INFO,
        'http_result method=%s route=%s status=%s duration_ms=%s instance=%s',
        request.method, route, response.status_code,
        round((time.monotonic() - started) * 1000), os.environ.get('WEBSITE_INSTANCE_ID', 'local'))
    return response


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
        200: {"description": "Existing session; credential is not replayed (realtime is null)"},
        409: {"description": "Key conflicts with preferences or creation is in progress"},
        415: {"description": "Content-Type must be application/json"},
        502: {"description": "Realtime provider failed or returned invalid data"},
        503: {"description": "API key missing or session storage unavailable"},
        504: {"description": "Realtime provider timed out"},
    },
)
def start_session(
    request: SessionCreate, response: Response,
    settings: Settings = Depends(get_settings),
    idempotency_key: str | None = Header(default=None, min_length=1, max_length=200,
                                        pattern=r"^[A-Za-z0-9_-]+$"),
) -> CreateSessionResponse:
    """Save a session, request a connection credential, and return the active session."""
    result = create_session(request, settings, idempotency_key)
    if result.realtime is None:
        response.status_code = 200
    response.headers["Cache-Control"] = "no-store"
    return result


@app.post(
    "/sessions/{session_id}/end", response_model=EndSessionResponse,
    responses={
        404: {"description": "Session not found"},
        409: {"description": "Session is creating or failed"},
        503: {"description": "Session storage unavailable"},
    },
)
def finish_session(
    session_id: UUID, response: Response, settings: Settings = Depends(get_settings),
) -> EndSessionResponse:
    """End a session idempotently. Late uploads remain accepted; close WebRTC on the client."""
    result = end_session(str(session_id), settings)
    response.headers["Cache-Control"] = "no-store"
    return result


@app.post(
    "/sessions/{session_id}/heartbeat", response_model=HeartbeatResponse,
    responses={
        404: {"description": "Session not found"},
        409: {"description": "Session is not active"},
        503: {"description": "Session storage unavailable"},
    },
)
def record_heartbeat(
    session_id: UUID, response: Response, settings: Settings = Depends(get_settings),
) -> HeartbeatResponse:
    """Refresh activity for an active session; never reopen an ended session."""
    result = heartbeat_session(str(session_id), settings)
    response.headers["Cache-Control"] = "no-store"
    return result


CAPTURE_RESPONSES = {
    200: {"description": "Identical input already stored"},
    404: {"description": "Session not found"},
    409: {"description": "Inactive session or conflicting input"},
    415: {"description": "Unsupported content type"},
    503: {"description": "Input storage unavailable"},
}


@app.get(
    "/sessions/{session_id}/data-status", response_model=SessionDataStatus,
    responses={404: {"description": "Session not found"}, 503: {"description": "Storage unavailable"}},
)
def read_data_status(session_id: UUID, response: Response,
                     settings: Settings = Depends(get_settings)) -> SessionDataStatus:
    """Report missing/unexpected components; this is a snapshot, not an evaluation lock."""
    result = get_data_status(settings, str(session_id))
    response.headers["Cache-Control"] = "no-store"
    return result


@app.put(
    "/sessions/{session_id}/upload-manifest", response_model=SessionDataStatus,
    dependencies=[Depends(require_json)],
    responses={
        404: {"description": "Session not found"},
        409: {"description": "Session not ended or final manifest conflicts"},
        415: {"description": "Content-Type must be application/json"},
        503: {"description": "Storage unavailable"},
    },
)
def declare_upload_manifest(session_id: UUID, manifest: UploadManifest, response: Response,
                            settings: Settings = Depends(get_settings)) -> SessionDataStatus:
    """Declare all expected uploads after ending; identical retries are accepted."""
    result = get_data_status(settings, str(session_id), manifest)
    response.headers["Cache-Control"] = "no-store"
    return result


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
    """Store one learner recording and immediately assess pronunciation and fluency."""
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
        capture_audio, settings, str(session_id), str(turn_id), bytes(audio), media_type
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


EVALUATION_ERRORS = {
    404: {'description': 'Session or evaluation not found'},
    409: {'description': 'Session not ready, evaluation running or attempt superseded'},
    413: {'description': 'Evaluation snapshot too large'},
    422: {'description': 'Invalid UUID'},
    502: {'description': 'Evaluation provider failure or invalid output'},
    503: {'description': 'Evaluation configuration or storage unavailable'},
    504: {'description': 'Evaluation provider timeout'},
}


@app.post('/sessions/{session_id}/evaluation', response_model=EvaluationResponse,
          status_code=201, responses={
              200: {'description': 'Saved result'},
              202: {'description': 'Transcript complete; waiting for Speech turns'},
              **EVALUATION_ERRORS})
def evaluate_session(session_id: UUID, response: Response,
                     settings: Settings = Depends(get_settings)) -> EvaluationResponse:
    result, response.status_code = run_evaluation(settings, str(session_id))
    if response.status_code == 202:
        response.headers['Retry-After'] = '5'
    response.headers['Cache-Control'] = 'no-store'
    return result


@app.get('/sessions/{session_id}/evaluation', response_model=EvaluationResponse,
         responses={404: EVALUATION_ERRORS[404], 503: EVALUATION_ERRORS[503]})
def read_evaluation(session_id: UUID, response: Response,
                    settings: Settings = Depends(get_settings)) -> EvaluationResponse:
    result = get_evaluation(settings, str(session_id))
    response.headers['Cache-Control'] = 'no-store'
    return result

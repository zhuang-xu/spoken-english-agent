from functools import lru_cache
from uuid import uuid4

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile, status

from app.config import Settings, get_settings
from app.schemas import (
    CreateSessionResponse,
    EndSessionResponse,
    SessionCreate,
    SessionStatus,
    Speaker,
    TurnRequest,
    TurnResponse,
)
from app.services.coach import ConversationCoach
from app.services.evaluator import Evaluator
from app.services.llm import build_llm_client
from app.services.planner import SessionPlanner
from app.services.speech import SpeechService, build_speech_service
from app.storage.sqlite import SessionRepository


@lru_cache
def get_repository() -> SessionRepository:
    return SessionRepository(get_settings().database_path)


@lru_cache
def get_dependencies() -> tuple[SessionPlanner, ConversationCoach, Evaluator, SpeechService]:
    settings = get_settings()
    llm = build_llm_client(settings)
    speech = build_speech_service(settings)
    return SessionPlanner(llm), ConversationCoach(llm), Evaluator(llm), speech


app = FastAPI(title="Spoken English Agent MVP")


@app.get("/health")
def health(settings: Settings = Depends(get_settings)) -> dict[str, str]:
    return {"status": "ok", "provider": settings.provider}


@app.post("/sessions", response_model=CreateSessionResponse, status_code=status.HTTP_201_CREATED)
def create_session(
    request: SessionCreate,
    repository: SessionRepository = Depends(get_repository),
) -> CreateSessionResponse:
    planner, _, _, _ = get_dependencies()
    plan = planner.create_plan(request)
    session = repository.create_session(str(uuid4()), request, plan)
    repository.add_transcript_item(session.id, Speaker.assistant, plan.opening_question, {"kind": "opening_question"})
    return CreateSessionResponse(session=session, assistant_response=plan.opening_question)


@app.get("/sessions/{session_id}")
def get_session(
    session_id: str,
    repository: SessionRepository = Depends(get_repository),
) -> dict:
    session = repository.get_session(session_id)
    if not session:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Session not found.")
    transcript = repository.list_transcript(session_id)
    return {"session": session, "transcript": transcript}


@app.post("/sessions/{session_id}/turns", response_model=TurnResponse)
def create_turn(
    session_id: str,
    request: TurnRequest,
    repository: SessionRepository = Depends(get_repository),
) -> TurnResponse:
    return _handle_turn(session_id, request.transcript, None, request.return_audio, repository)


@app.post("/sessions/{session_id}/turns/audio", response_model=TurnResponse)
async def create_audio_turn(
    session_id: str,
    audio: UploadFile = File(...),
    return_audio: bool = Form(False),
    repository: SessionRepository = Depends(get_repository),
) -> TurnResponse:
    audio_bytes = await audio.read()
    suffix = f".{audio.filename.rsplit('.', 1)[-1]}" if audio.filename and "." in audio.filename else ".wav"
    return _handle_turn(session_id, None, (audio_bytes, suffix), return_audio, repository)


@app.post("/sessions/{session_id}/end", response_model=EndSessionResponse)
def end_session(
    session_id: str,
    repository: SessionRepository = Depends(get_repository),
) -> EndSessionResponse:
    session = repository.get_session(session_id)
    if not session:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Session not found.")

    transcript = repository.list_transcript(session_id)
    _, _, evaluator, _ = get_dependencies()
    evaluation = evaluator.evaluate(session, transcript)
    repository.complete_session(session_id, evaluation.model_dump())
    return EndSessionResponse(
        session_id=session_id,
        status="completed",
        transcript=transcript,
        evaluation=evaluation,
    )


def _handle_turn(
    session_id: str,
    transcript: str | None,
    audio: tuple[bytes, str] | None,
    return_audio: bool,
    repository: SessionRepository,
) -> TurnResponse:
    session = repository.get_session(session_id)
    if not session:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Session not found.")
    if session.status != SessionStatus.active:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Session is already completed.")

    _, coach, _, speech = get_dependencies()
    user_text = transcript.strip() if transcript else ""
    if audio:
        audio_bytes, suffix = audio
        user_text = speech.transcribe(audio_bytes, suffix).strip()
    if not user_text:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Transcript or audio is required.")

    repository.add_transcript_item(session_id, Speaker.user, user_text)
    current_transcript = repository.list_transcript(session_id)
    assistant_response, coaching_note = coach.next_turn(session, current_transcript, user_text)
    repository.add_transcript_item(
        session_id,
        Speaker.assistant,
        assistant_response,
        {"coaching_note": coaching_note},
    )
    audio_base64 = speech.synthesize_base64(assistant_response) if return_audio else None
    return TurnResponse(
        session_id=session_id,
        user_transcript=user_text,
        assistant_response=assistant_response,
        coaching_note=coaching_note,
        audio_base64=audio_base64,
    )

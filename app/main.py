from fastapi import Depends, FastAPI, HTTPException, Request, Response

from app.config import Settings, get_settings
from app.schemas import CreateSessionResponse, SessionCreate
from app.services.sessions import create_session

app = FastAPI(title="Spoken English Agent — Session Start")


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

"""The session-start workflow, expressed as one ordinary function."""
from datetime import datetime, timezone
import sqlite3
from uuid import uuid4
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from app.config import Settings
from app.schemas import CreateSessionResponse, EndSessionResponse, HeartbeatResponse, Session, SessionCreate
from app.services.realtime import create_realtime_session
from app.storage.sqlite import end_stored_session, heartbeat_stored_session, save_creating_session, update_session


def heartbeat_session(session_id: str, settings: Settings, account_id: str) -> HeartbeatResponse:
    try:
        outcome, last_activity_at = heartbeat_stored_session(settings.database_path, session_id, account_id)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, "Session storage is unavailable.") from None
    if outcome == "not_found":
        raise HTTPException(404, "Session not found.")
    if outcome == "inactive":
        raise HTTPException(409, "Session is not active. Start a new session.")
    return HeartbeatResponse(session_id=session_id, last_activity_at=last_activity_at)


def end_session(session_id: str, settings: Settings, account_id: str) -> EndSessionResponse:
    try:
        outcome, ended_at = end_stored_session(settings.database_path, session_id, account_id)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, "Session storage is unavailable.") from None
    if outcome == "not_found":
        raise HTTPException(404, "Session not found.")
    if outcome == "inactive":
        raise HTTPException(409, "Only active sessions can be ended.")
    return EndSessionResponse(session_id=session_id, ended_at=ended_at)


def create_session(request: SessionCreate, settings: Settings, account_id: str,
                   idempotency_key: str | None = None) -> CreateSessionResponse:
    try:
        endpoint = urlsplit(settings.azure_openai_endpoint)
    except ValueError:
        raise HTTPException(503, "Azure OpenAI is not configured correctly.") from None
    if (not settings.azure_openai_api_key.get_secret_value()
            or not settings.azure_openai_deployment.strip()
            or endpoint.scheme != "https" or not endpoint.hostname
            or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment
            or endpoint.path not in ("", "/")):
        raise HTTPException(503, "Azure OpenAI is not configured correctly.")

    session = Session(id=str(uuid4()), created_at=datetime.now(timezone.utc), preferences=request)
    try:
        reservation = save_creating_session(settings.database_path, session, account_id, idempotency_key)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, "Session storage is unavailable.") from None

    if reservation is not None:
        outcome, previous = reservation
        if outcome == "conflict":
            raise HTTPException(409, "Idempotency-Key was already used with different preferences.")
        if previous.status == "creating":
            raise HTTPException(409, "Session creation is in progress. Retry with the same key.",
                                headers={"Retry-After": "2"})
        return CreateSessionResponse(session=previous, realtime=None)

    try:
        realtime = create_realtime_session(request, settings)
    except (httpx.HTTPError, ValueError, KeyError, TypeError, OverflowError) as error:
        try:
            update_session(settings.database_path, session.id, "failed")
        except (sqlite3.Error, OSError):
            raise HTTPException(503, "Session storage is unavailable.") from None
        if isinstance(error, httpx.TimeoutException):
            raise HTTPException(504, "Realtime provider timed out.") from None
        raise HTTPException(502, "Realtime provider could not start the session.") from None

    try:
        update_session(settings.database_path, session.id, "active", realtime.provider_session_id)
    except (sqlite3.Error, OSError):
        # Do not release the credential to the client when activation fails.
        # The unused credential expires after 60 seconds; no WebRTC call exists yet.
        try:
            update_session(settings.database_path, session.id, "failed")
        except (sqlite3.Error, OSError):
            pass  # A storage outage can leave a creating row for later reconciliation.
        raise HTTPException(503, "Session storage is unavailable.") from None
    return CreateSessionResponse(session=session, realtime=realtime)

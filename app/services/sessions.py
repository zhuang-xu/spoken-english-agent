"""The session-start workflow, expressed as one ordinary function."""
from datetime import datetime, timezone
import sqlite3
from uuid import uuid4
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from app.config import Settings
from app.schemas import CreateSessionResponse, Session, SessionCreate
from app.services.realtime import create_realtime_session
from app.storage.sqlite import save_creating_session, update_session


def create_session(request: SessionCreate, settings: Settings) -> CreateSessionResponse:
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
        save_creating_session(settings.database_path, session)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, "Session storage is unavailable.") from None

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

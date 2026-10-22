import azure.functions as func
import logging
import os

from web_app import app as fastapi_app
from app.config import get_settings
from app.storage.sqlite import expire_inactive_sessions, fail_stale_creating_sessions


app = func.AsgiFunctionApp(
    app=fastapi_app,
    # Browser deployments use platform sign-in instead of exposing a Function key.
    # Keep key protection unless the deployment explicitly selects another mode.
    http_auth_level=func.AuthLevel(os.environ.get('FUNCTIONS_HTTP_AUTH_LEVEL', 'function')),
)


@app.timer_trigger(arg_name="timer", schedule="0 * * * * *", use_monitor=True)
def cleanup_inactive_sessions(timer: func.TimerRequest) -> None:
    """Run every minute; storage failures propagate to Azure monitoring."""
    count = expire_inactive_sessions(get_settings().database_path)
    logging.info("Ended %d inactive practice sessions.", count)
    failed = fail_stale_creating_sessions(get_settings().database_path)
    logging.info("Failed %d abandoned session starts.", failed)
    from app.services.evaluation_batches import resume_pending
    resume_pending(get_settings())

import azure.functions as func
import logging

from app.main import app as fastapi_app
from app.config import get_settings
from app.storage.sqlite import expire_inactive_sessions, fail_stale_creating_sessions


app = func.AsgiFunctionApp(
    app=fastapi_app,
    http_auth_level=func.AuthLevel.FUNCTION,
)


@app.timer_trigger(arg_name="timer", schedule="0 * * * * *", use_monitor=True)
def cleanup_inactive_sessions(timer: func.TimerRequest) -> None:
    """Run every minute; storage failures propagate to Azure monitoring."""
    count = expire_inactive_sessions(get_settings().database_path)
    logging.info("Ended %d inactive practice sessions.", count)
    failed = fail_stale_creating_sessions(get_settings().database_path)
    logging.info("Failed %d abandoned session starts.", failed)

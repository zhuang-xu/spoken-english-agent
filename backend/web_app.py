"""Optional same-origin browser host. app.main remains the client-independent API."""
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.main import app as api_app


def create_app(browser_directory: Path | None = None) -> FastAPI:
    if browser_directory is None:
        root = Path(__file__).resolve().parent
        packaged = root / 'browser' / 'public'
        browser_directory = packaged if packaged.is_dir() else root.parent / 'browser' / 'public'
    if not browser_directory.is_dir():
        return api_app
    host = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    host.mount('/practice-assets', StaticFiles(directory=browser_directory), name='practice-assets')

    @host.get('/practice', include_in_schema=False)
    def practice() -> FileResponse:
        return FileResponse(browser_directory / 'index.html', headers={'Cache-Control': 'no-store'})

    host.mount('/', api_app)
    return host


app = create_app()

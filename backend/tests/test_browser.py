"""The optional host serves browser assets without contacting the voice provider."""
import pytest
from fastapi.testclient import TestClient
from web_app import app


@pytest.fixture
def browser_client(client):
    _, settings = client
    with TestClient(app) as api:
        yield api, settings


@pytest.mark.parametrize("path,content_type", [
    ("/practice", "text/html"),
    ("/practice-assets/practice.mjs", "javascript"),
    ("/practice-assets/realtime.mjs", "javascript"),
    ("/practice-assets/session.mjs", "javascript"),
    ("/practice-assets/recorder.mjs", "javascript"),
    ("/practice-assets/practice.css", "text/css"),
])
def test_browser_assets(browser_client, mock_openai_post, path, content_type):
    api, _ = browser_client
    response = api.get(path)
    assert response.status_code == 200
    assert content_type in response.headers["content-type"]
    assert "server-secret" not in response.text
    mock_openai_post.assert_not_called()


def test_browser_missing_asset(browser_client):
    api, _ = browser_client
    assert api.get("/practice-assets/missing.js").status_code == 404


def test_browser_page_no_store(browser_client):
    api, _ = browser_client
    assert api.get("/practice").headers["cache-control"] == "no-store"

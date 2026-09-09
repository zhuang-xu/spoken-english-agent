"""The browser is served by the API without contacting the voice provider."""
import pytest


@pytest.mark.parametrize("path,content_type", [
    ("/practice", "text/html"),
    ("/practice-assets/practice.mjs", "javascript"),
    ("/practice-assets/realtime.mjs", "javascript"),
    ("/practice-assets/practice.css", "text/css"),
])
def test_browser_assets(client, mock_openai_post, path, content_type):
    api, _ = client
    response = api.get(path)
    assert response.status_code == 200
    assert content_type in response.headers["content-type"]
    assert "server-secret" not in response.text
    mock_openai_post.assert_not_called()


def test_browser_missing_asset(client):
    api, _ = client
    assert api.get("/practice-assets/missing.js").status_code == 404


def test_browser_page_no_store(client):
    api, _ = client
    assert api.get("/practice").headers["cache-control"] == "no-store"

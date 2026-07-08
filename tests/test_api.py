from fastapi.testclient import TestClient

from app.config import get_settings
from app.main import app, get_dependencies, get_repository
from app.storage.sqlite import SessionRepository


def test_session_lifecycle(tmp_path):
    get_settings.cache_clear()
    get_dependencies.cache_clear()
    get_repository.cache_clear()

    repository = SessionRepository(str(tmp_path / "test.sqlite3"))
    app.dependency_overrides[get_repository] = lambda: repository

    client = TestClient(app)
    create_response = client.post(
        "/sessions",
        json={
            "speaking_goal": "Interview practice",
            "level": "B1",
            "preferred_topic": "software projects",
            "session_duration_minutes": 10,
        },
    )
    assert create_response.status_code == 201
    session_id = create_response.json()["session"]["id"]

    turn_response = client.post(
        f"/sessions/{session_id}/turns",
        json={"transcript": "I want to practice explaining my recent backend project."},
    )
    assert turn_response.status_code == 200
    assert turn_response.json()["assistant_response"]
    assert turn_response.json()["coaching_note"]

    end_response = client.post(f"/sessions/{session_id}/end")
    assert end_response.status_code == 200
    body = end_response.json()
    assert body["status"] == "completed"
    assert len(body["transcript"]) == 3
    assert len(body["evaluation"]["top_3_issues"]) == 3

    app.dependency_overrides.clear()


def test_turn_requires_input(tmp_path):
    get_settings.cache_clear()
    get_dependencies.cache_clear()
    get_repository.cache_clear()

    repository = SessionRepository(str(tmp_path / "test.sqlite3"))
    app.dependency_overrides[get_repository] = lambda: repository

    client = TestClient(app)
    create_response = client.post(
        "/sessions",
        json={
            "speaking_goal": "Daily conversation",
            "level": "A2",
            "preferred_topic": "travel",
            "session_duration_minutes": 5,
        },
    )
    session_id = create_response.json()["session"]["id"]

    turn_response = client.post(f"/sessions/{session_id}/turns", json={})
    assert turn_response.status_code == 400

    app.dependency_overrides.clear()

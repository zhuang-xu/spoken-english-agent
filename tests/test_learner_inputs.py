"""Capture real input data into temporary SQLite, with no provider calls."""
import json
import sqlite3
from contextlib import closing
from uuid import uuid4

import pytest

from app.services import learner_inputs


def stored(settings):
    with closing(sqlite3.connect(settings.database_path)) as db:
        db.row_factory = sqlite3.Row
        return dict(db.execute("SELECT * FROM learner_turns").fetchone())


def audio(api, base, content=b"recorded-audio", media="audio/webm;codecs=opus"):
    return api.put(base + "/audio", content=content, headers={"Content-Type": media})


@pytest.mark.parametrize("transcript_first", [True, False])
def test_capture_both_orders(learner_turn, mock_openai_post, transcript_first):
    api, settings, base, transcript = learner_turn
    mock_openai_post.reset_mock()
    calls = [lambda: audio(api, base), lambda: api.put(base + "/transcript", json=transcript)]
    if transcript_first:
        calls.reverse()
    first, second = calls[0](), calls[1]()
    assert first.status_code == second.status_code == 201
    assert first.json()["audio_received"] != first.json()["transcript_received"]
    assert second.json()["audio_received"] and second.json()["transcript_received"]
    assert second.headers["cache-control"] == "no-store"
    row = stored(settings)
    assert row["audio"] == b"recorded-audio"
    assert row["media_type"] == "audio/webm;codecs=opus"
    assert json.loads(row["transcript"]) == transcript
    assert row["audio_received_at"] and row["transcript_received_at"]
    assert row["session_id"] == second.json()["session_id"]
    assert row["turn_id"] == second.json()["turn_id"]
    assert "text" not in second.json()
    mock_openai_post.assert_not_called()


def test_retries_and_conflicts(learner_turn):
    api, settings, base, transcript = learner_turn
    assert audio(api, base).status_code == 201
    assert api.put(base + "/transcript", json=transcript).status_code == 201
    original = stored(settings)
    assert audio(api, base).status_code == 200
    assert api.put(base + "/transcript", json={**transcript, "text": "  " + transcript["text"]}).status_code == 200
    assert audio(api, base, b"different").status_code == 409
    assert audio(api, base, media="audio/ogg").status_code == 409
    assert api.put(base + "/transcript", json={**transcript, "text": "changed"}).status_code == 409
    assert stored(settings) == original


@pytest.mark.parametrize("updates", [
    {"text": " "}, {"text": "x" * 20001}, {"start_ms": -1}, {"start_ms": True},
    {"end_ms": 1000}, {"end_ms": 999}, {"end_ms": 2.5}, {"speaker": "assistant"},
    {"provider_item_id": " "},
])
def test_invalid_transcript(learner_turn, updates):
    api, _, base, transcript = learner_turn
    assert api.put(base + "/transcript", json={**transcript, **updates}).status_code == 422


def test_audio_limits_and_content_types(learner_turn):
    api, _, base, _ = learner_turn
    assert audio(api, base, b"").status_code == 422
    assert audio(api, base, media="application/octet-stream").status_code == 415
    limit = learner_inputs.MAX_AUDIO_BYTES
    assert audio(api, base, b"a" * (limit + 1)).status_code == 413
    assert audio(api, base, b"a" * limit).status_code == 201


def test_chunked_limit(learner_turn):
    api, _, base, _ = learner_turn
    chunks = (b"a" * 1024 * 1024 for _ in range(11))
    assert audio(api, base, chunks).status_code == 413


def test_unknown_and_inactive_sessions(learner_turn):
    api, settings, base, transcript = learner_turn
    missing = f"/sessions/{uuid4()}/learner-turns/{uuid4()}"
    assert audio(api, missing).status_code == 404
    assert api.put(missing + "/transcript", json=transcript).status_code == 404
    with closing(sqlite3.connect(settings.database_path)) as db, db:
        db.execute("UPDATE practice_sessions SET status='failed'")
    assert audio(api, base).status_code == 409
    assert api.put(base + "/transcript", json=transcript).status_code == 409


def test_fresh_database(client):
    api, _ = client
    assert audio(api, f"/sessions/{uuid4()}/learner-turns/{uuid4()}").status_code == 404


def test_storage_failure(learner_turn, monkeypatch):
    api, _, base, transcript = learner_turn
    def fail(*args, **kwargs):
        raise sqlite3.OperationalError("private database details")
    monkeypatch.setattr(learner_inputs, "store_learner_input", fail)
    for response in [audio(api, base), api.put(base + "/transcript", json=transcript)]:
        assert response.status_code == 503
        assert "private" not in response.text


def test_invalid_request(learner_turn):
    api, _, base, _ = learner_turn
    assert api.put(base + "/transcript", content="text", headers={"Content-Type": "text/plain"}).status_code == 415
    assert api.put(base + "/transcript", content="{", headers={"Content-Type": "application/json"}).status_code == 422
    assert audio(api, "/sessions/invalid/learner-turns/invalid").status_code == 422


def test_database_failure_rolls_back_new_turn(learner_turn):
    api, settings, base, transcript = learner_turn
    assert audio(api, base).status_code == 201
    original = stored(settings)
    with closing(sqlite3.connect(settings.database_path)) as db, db:
        db.execute("""CREATE TRIGGER reject_transcript BEFORE UPDATE OF transcript ON learner_turns
                      BEGIN SELECT RAISE(ABORT, 'internal failure'); END""")
    other = base.rsplit("/", 1)[0] + "/" + str(uuid4())
    assert api.put(other + "/transcript", json=transcript).status_code == 503
    with closing(sqlite3.connect(settings.database_path)) as db:
        assert db.execute("SELECT COUNT(*) FROM learner_turns").fetchone()[0] == 1
    assert stored(settings) == original


def test_concurrent_components_and_duplicate_uploads(learner_turn):
    from concurrent.futures import ThreadPoolExecutor
    from app.storage.sqlite import store_learner_input
    from app.schemas import LearnerTranscript

    _, settings, base, transcript = learner_turn
    session_id, turn_id = base.split("/")[2], base.split("/")[4]
    def save(component):
        payload = b"audio" if component == "audio" else LearnerTranscript(**transcript).model_dump_json()
        return store_learner_input(settings.database_path, session_id, turn_id,
                                   component, payload, "audio/webm" if component == "audio" else None)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(save, ["audio", "transcript", "audio", "transcript"]))
    assert sorted(result[0] for result in results) == ["created", "created", "exists", "exists"]
    row = stored(settings)
    assert row["audio"] == b"audio"
    assert json.loads(row["transcript"]) == transcript


def test_turn_ids_are_scoped_to_session(learner_turn):
    api, settings, base, transcript = learner_turn
    assert audio(api, base).status_code == 201
    second_session = api.post("/sessions", json={
        "speaking_goal": "Travel practice", "level": "B1", "preferred_topic": "travel",
        "session_duration_minutes": 10,
    }).json()["session"]["id"]
    second_base = f"/sessions/{second_session}/learner-turns/{base.split('/')[-1]}"
    response = api.put(second_base + "/transcript", json=transcript)
    assert response.status_code == 201
    assert response.json()["audio_received"] is False
    with closing(sqlite3.connect(settings.database_path)) as db:
        assert db.execute("SELECT COUNT(*) FROM learner_turns").fetchone()[0] == 2

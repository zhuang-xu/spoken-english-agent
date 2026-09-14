"""Failure diagnostics identify the endpoint without logging learner content."""
import logging
from uuid import uuid4


def test_missing_session_logs_route_and_status_without_body(client, caplog):
    api, _ = client
    session, turn = str(uuid4()), str(uuid4())
    with caplog.at_level(logging.WARNING, logger='spoken.http'):
        response = api.put(f'/sessions/{session}/learner-turns/{turn}/transcript', json={
            'text': 'Private learner content', 'start_ms': 0, 'end_ms': 1000})
    assert response.status_code == 404
    entries = [r.getMessage() for r in caplog.records if r.name == 'spoken.http']
    assert len(entries) == 1
    assert 'status=404' in entries[0]
    assert '/sessions/{session_id}/learner-turns/{turn_id}/transcript' in entries[0]
    assert session not in entries[0]
    assert 'Private learner content' not in entries[0]

"""General API health and route documentation tests."""


def test_health(client):
    api, _ = client
    response = api.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_documented_routes(client):
    api, _ = client
    response = api.get("/openapi.json")
    assert response.status_code == 200
    schema = response.json()
    assert set(schema["paths"]) == {"/health", "/sessions",
        "/sessions/{session_id}/end",
        "/sessions/{session_id}/heartbeat",
        "/sessions/{session_id}/upload-manifest",
        "/sessions/{session_id}/data-status",
        "/sessions/{session_id}/learner-turns/{turn_id}/audio",
        "/sessions/{session_id}/learner-turns/{turn_id}/transcript",
        "/sessions/{session_id}/agent-items/{item_id}/transcripts/{content_index}"}
    assert {"201", "415", "422", "502", "503", "504"} <= set(schema["paths"]["/sessions"]["post"]["responses"])

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
    assert set(schema["paths"]) == {"/health", "/sessions"}
    assert {"201", "415", "422", "502", "503", "504"} <= set(schema["paths"]["/sessions"]["post"]["responses"])

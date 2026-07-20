from .conftest import REGION_ID


def test_health_returns_ok_and_region(client):
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "regionId": REGION_ID}


def test_health_sets_request_id_header(client):
    response = client.get("/health")

    assert response.headers.get("X-Request-Id")

from cloudlaunch_api.enums import ErrorCode
from cloudlaunch_api.errors import HTTP_STATUS_BY_CODE


def assert_error_shape(payload, code):
    assert set(payload.keys()) == {"error"}
    error = payload["error"]
    assert error["code"] == code
    assert error["message"]
    assert error["requestId"]


def test_status_mapping_matches_contract():
    assert HTTP_STATUS_BY_CODE[ErrorCode.AUTH_REQUIRED] == 401
    assert HTTP_STATUS_BY_CODE[ErrorCode.ADMIN_REQUIRED] == 403
    assert HTTP_STATUS_BY_CODE[ErrorCode.INVALID_REQUEST] == 400
    assert HTTP_STATUS_BY_CODE[ErrorCode.REGION_DISABLED] == 400
    assert HTTP_STATUS_BY_CODE[ErrorCode.REGION_MISMATCH] == 400
    assert HTTP_STATUS_BY_CODE[ErrorCode.INVALID_PASSWORD] == 400
    assert HTTP_STATUS_BY_CODE[ErrorCode.CLIENT_NOT_FOUND] == 404
    assert HTTP_STATUS_BY_CODE[ErrorCode.DUPLICATE_EMAIL] == 409
    assert HTTP_STATUS_BY_CODE[ErrorCode.LIMIT_REACHED] == 409
    assert HTTP_STATUS_BY_CODE[ErrorCode.CAPACITY_REACHED] == 409
    assert HTTP_STATUS_BY_CODE[ErrorCode.WIREGUARD_APPLY_FAILED] == 500
    assert HTTP_STATUS_BY_CODE[ErrorCode.FIREBASE_WRITE_FAILED] == 500
    assert HTTP_STATUS_BY_CODE[ErrorCode.INTERNAL_ERROR] == 500


def test_users_requires_auth(client):
    response = client.post("/users", json={"email": "a@b.com", "password": "Password1!"})

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")


def test_users_rejects_bad_token(client):
    response = client.post(
        "/users",
        json={"email": "a@b.com", "password": "Password1!"},
        headers={"Authorization": "Bearer nope"},
    )

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")


def test_users_rejects_non_admin(client):
    response = client.post(
        "/users",
        json={"email": "a@b.com", "password": "Password1!"},
        headers={"Authorization": "Bearer user-token"},
    )

    assert response.status_code == 403
    assert_error_shape(response.json(), "ADMIN_REQUIRED")


def test_users_admin_can_create_user(client):
    response = client.post(
        "/users",
        json={"email": "a@b.com", "password": "Password1!"},
        headers={"Authorization": "Bearer admin-token"},
    )

    assert response.status_code == 200
    assert response.json()["role"] == "user"


def test_invalid_body_maps_to_invalid_request(client):
    response = client.post(
        "/users",
        json={"email": "a@b.com"},
        headers={"Authorization": "Bearer admin-token"},
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")

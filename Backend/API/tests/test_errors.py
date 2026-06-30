from typing import cast

import pytest
from google.cloud.firestore_v1.base_document import DocumentSnapshot

from src.enums import ErrorCode, Role
from src.errors import FirebaseWriteFailedError, HTTP_STATUS_BY_CODE, RoleDefaultMissingError
from src.firebase import _require_role_default, _require_user_role


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
    assert HTTP_STATUS_BY_CODE[ErrorCode.CLIENT_NOT_FOUND] == 404
    assert HTTP_STATUS_BY_CODE[ErrorCode.DUPLICATE_EMAIL] == 409
    assert HTTP_STATUS_BY_CODE[ErrorCode.ACCOUNT_DISABLED] == 409
    assert HTTP_STATUS_BY_CODE[ErrorCode.LIMIT_REACHED] == 409
    assert HTTP_STATUS_BY_CODE[ErrorCode.CAPACITY_REACHED] == 409
    assert HTTP_STATUS_BY_CODE[ErrorCode.WIREGUARD_APPLY_FAILED] == 500
    assert HTTP_STATUS_BY_CODE[ErrorCode.FIREBASE_WRITE_FAILED] == 500
    assert HTTP_STATUS_BY_CODE[ErrorCode.ROLE_DEFAULT_MISSING] == 500
    assert HTTP_STATUS_BY_CODE[ErrorCode.INTERNAL_ERROR] == 500


class _FakeSnapshot:
    def __init__(self, exists, data=None):
        self.exists = exists
        self._data = data or {}

    def to_dict(self):
        return self._data


def test_require_role_default_raises_when_missing():
    snapshot = cast(DocumentSnapshot, _FakeSnapshot(exists=False))
    with pytest.raises(RoleDefaultMissingError):
        _require_role_default(snapshot, Role.USER)


def test_require_role_default_raises_when_malformed():
    snapshot = cast(DocumentSnapshot, _FakeSnapshot(exists=True, data={"roleId": "admin"}))
    with pytest.raises(RoleDefaultMissingError):
        _require_role_default(snapshot, Role.USER)


def test_require_role_default_raises_when_limit_non_numeric():
    snapshot = cast(
        DocumentSnapshot,
        _FakeSnapshot(exists=True, data={"roleId": "user", "defaultPerRegionClientLimit": "bad"}),
    )
    with pytest.raises(RoleDefaultMissingError):
        _require_role_default(snapshot, Role.USER)


def test_require_user_role_raises_when_limit_non_numeric():
    snapshot = cast(
        DocumentSnapshot,
        _FakeSnapshot(exists=True, data={"roleId": "user", "perRegionClientLimit": "bad"}),
    )
    with pytest.raises(FirebaseWriteFailedError):
        _require_user_role(snapshot, "uid-1")


def test_users_requires_auth(client):
    response = client.post("/users", json={"email": "a@b.com"})

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")


def test_users_rejects_bad_token(client):
    response = client.post(
        "/users",
        json={"email": "a@b.com"},
        headers={"Authorization": "Bearer nope"},
    )

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")


def test_users_rejects_non_admin(client):
    response = client.post(
        "/users",
        json={"email": "a@b.com"},
        headers={"Authorization": "Bearer user-token"},
    )

    assert response.status_code == 403
    assert_error_shape(response.json(), "ADMIN_REQUIRED")


def test_users_admin_can_create_user(client):
    response = client.post(
        "/users",
        json={"email": "a@b.com"},
        headers={"Authorization": "Bearer admin-token"},
    )

    assert response.status_code == 200
    assert response.json()["role"] == "user"


def test_invalid_body_maps_to_invalid_request(client):
    response = client.post(
        "/users",
        json={},
        headers={"Authorization": "Bearer admin-token"},
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")

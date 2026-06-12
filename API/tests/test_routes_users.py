from src.errors import FirebaseWriteFailedError
from src.repository import UserDoc, utc_now

from .test_errors import assert_error_shape


def auth_header(token: str = "admin-token") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def valid_payload(**overrides):
    payload = {
        "email": "new.user@example.com",
        "displayName": " New User ",
    }
    payload.update(overrides)
    return payload


def test_create_user_admin_creates_auth_user_and_role(client, repository):
    response = client.post("/users", json=valid_payload(), headers=auth_header())

    assert response.status_code == 200
    payload = response.json()
    assert payload == {
        "userId": "created-user-1",
        "email": "new.user@example.com",
        "role": "user",
        "alreadyExisted": False,
    }
    assert "user_id" not in payload
    stored = repository.get_user("created-user-1")
    assert stored.email == "new.user@example.com"
    assert stored.display_name == "New User"
    assert repository.get_role("created-user-1").value == "user"


def test_create_user_allows_missing_display_name(client, repository):
    response = client.post(
        "/users",
        json=valid_payload(displayName=None),
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert repository.get_user("created-user-1").display_name is None


def test_create_user_trims_email(client, repository):
    response = client.post(
        "/users",
        json=valid_payload(email="  trimmed@example.com  "),
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert response.json()["email"] == "trimmed@example.com"
    assert repository.get_user("created-user-1").email == "trimmed@example.com"


def test_create_user_rejects_duplicate_email(client, repository):
    first = client.post("/users", json=valid_payload(), headers=auth_header())
    assert first.status_code == 200

    response = client.post(
        "/users",
        json=valid_payload(email="NEW.USER@example.com"),
        headers=auth_header(),
    )

    assert response.status_code == 409
    assert_error_shape(response.json(), "DUPLICATE_EMAIL")


def test_create_user_rejects_legacy_password_field(client):
    response = client.post(
        "/users",
        json=valid_payload(password="Password1!"),
        headers=auth_header(),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")


def test_create_user_provisions_existing_auth_user_without_role(client, repository):
    repository.users["existing-user"] = UserDoc(
        uid="existing-user",
        email="existing@example.com",
        display_name="Existing User",
        created_at=utc_now(),
    )

    response = client.post(
        "/users",
        json=valid_payload(email="existing@example.com", displayName=None),
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert response.json() == {
        "userId": "existing-user",
        "email": "existing@example.com",
        "role": "user",
        "alreadyExisted": True,
    }
    assert repository.get_role("existing-user").value == "user"
    assert repository.get_user("existing-user").display_name == "Existing User"


def test_create_user_rejects_disabled_existing_auth_user(client, repository):
    repository.users["disabled-user"] = UserDoc(
        uid="disabled-user",
        email="disabled@example.com",
        display_name=None,
        created_at=utc_now(),
    )
    repository.disabled_auth_uids.add("disabled-user")

    response = client.post(
        "/users",
        json=valid_payload(email="disabled@example.com"),
        headers=auth_header(),
    )

    assert response.status_code == 409
    assert_error_shape(response.json(), "ACCOUNT_DISABLED")
    assert repository.get_role("disabled-user") is None


def test_create_user_rejects_invalid_email(client):
    response = client.post(
        "/users",
        json=valid_payload(email="not-an-email"),
        headers=auth_header(),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")


def test_create_user_maps_firebase_write_failure(client, repository):
    repository.create_user_error = FirebaseWriteFailedError("Simulated write failure.")

    response = client.post("/users", json=valid_payload(), headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "FIREBASE_WRITE_FAILED")


def test_create_user_maps_unexpected_failure_to_internal_error(client, repository):
    repository.create_user_error = RuntimeError("Simulated unexpected failure.")

    response = client.post("/users", json=valid_payload(), headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "INTERNAL_ERROR")

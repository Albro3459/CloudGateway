import src.routes as routes
from src.enums import Role
from src.errors import FirebaseWriteFailedError
from src.repository import UserDoc, utc_now

from .test_errors import assert_error_shape


class RecordingAccessGrantEmailSender:
    def __init__(self, error: Exception | None = None):
        self.error = error
        self.calls: list[dict[str, str]] = []

    def __call__(self, ses_client, *, sender: str, recipient: str, dashboard_origin: str) -> str:
        self.calls.append(
            {
                "sender": sender,
                "recipient": recipient,
                "dashboard_origin": dashboard_origin,
            }
        )
        if self.error is not None:
            raise self.error
        return "message-1"


def auth_header(token: str = "admin-token") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def valid_payload(**overrides):
    payload = {
        "email": "new.user@example.com",
    }
    payload.update(overrides)
    return payload


def configure_access_email(monkeypatch, *, sender_error: Exception | None = None) -> RecordingAccessGrantEmailSender:
    email_sender = RecordingAccessGrantEmailSender(error=sender_error)
    monkeypatch.setattr(routes, "create_ses_client", lambda settings: object())
    monkeypatch.setattr(routes, "send_access_grant_email", email_sender)
    return email_sender


def test_create_user_admin_creates_auth_user_and_role(client, repository, monkeypatch):
    email_sender = configure_access_email(monkeypatch)

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
    assert repository.get_role("created-user-1").value == "user"
    assert email_sender.calls == [
        {
            "sender": "",
            "recipient": "new.user@example.com",
            "dashboard_origin": "",
        }
    ]


def test_create_user_rejects_display_name(client, repository):
    response = client.post(
        "/users",
        json=valid_payload(displayName="User Name"),
        headers=auth_header(),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")
    assert repository.get_user("created-user-1") is None


def test_create_user_trims_email(client, repository):
    response = client.post(
        "/users",
        json=valid_payload(email="  trimmed@example.com  "),
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert response.json()["email"] == "trimmed@example.com"
    assert repository.get_user("created-user-1").email == "trimmed@example.com"


def test_create_user_rejects_duplicate_email(client, repository, monkeypatch):
    first = client.post("/users", json=valid_payload(), headers=auth_header())
    assert first.status_code == 200
    email_sender = configure_access_email(monkeypatch)

    response = client.post(
        "/users",
        json=valid_payload(email="NEW.USER@example.com"),
        headers=auth_header(),
    )

    assert response.status_code == 409
    assert_error_shape(response.json(), "DUPLICATE_EMAIL")
    assert email_sender.calls == []


def test_create_user_rejects_legacy_password_field(client):
    response = client.post(
        "/users",
        json=valid_payload(password="Password1!"),
        headers=auth_header(),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")


def test_create_user_provisions_existing_auth_user_without_role(client, repository, monkeypatch):
    email_sender = configure_access_email(monkeypatch)
    repository.users["existing-user"] = UserDoc(
        uid="existing-user",
        email="existing@example.com",
        created_at=utc_now(),
    )

    response = client.post(
        "/users",
        json=valid_payload(email="existing@example.com"),
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
    assert email_sender.calls == [
        {
            "sender": "",
            "recipient": "existing@example.com",
            "dashboard_origin": "",
        }
    ]


def test_create_user_email_failure_does_not_fail_grant(client, repository, monkeypatch, caplog):
    email_sender = configure_access_email(monkeypatch, sender_error=RuntimeError("ses send failed"))

    with caplog.at_level("ERROR", logger="src.routes"):
        response = client.post("/users", json=valid_payload(), headers=auth_header())

    assert response.status_code == 200
    assert repository.get_role("created-user-1").value == "user"
    assert email_sender.calls == [
        {
            "sender": "",
            "recipient": "new.user@example.com",
            "dashboard_origin": "",
        }
    ]
    assert "user_access_email_failed" in caplog.text


def test_create_user_ses_client_failure_does_not_fail_grant(client, repository, monkeypatch, caplog):
    email_sender = RecordingAccessGrantEmailSender()

    def failing_factory(settings):
        raise ValueError("Missing SES configuration")

    monkeypatch.setattr(routes, "create_ses_client", failing_factory)
    monkeypatch.setattr(routes, "send_access_grant_email", email_sender)

    with caplog.at_level("ERROR", logger="src.routes"):
        response = client.post("/users", json=valid_payload(), headers=auth_header())

    assert response.status_code == 200
    assert repository.get_role("created-user-1").value == "user"
    assert email_sender.calls == []
    assert "user_access_email_failed" in caplog.text


def test_create_user_enables_and_provisions_disabled_existing_auth_user_without_role(client, repository):
    repository.users["disabled-user"] = UserDoc(
        uid="disabled-user",
        email="disabled@example.com",
        created_at=utc_now(),
    )
    repository.disabled_auth_uids.add("disabled-user")

    response = client.post(
        "/users",
        json=valid_payload(email="disabled@example.com"),
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert response.json() == {
        "userId": "disabled-user",
        "email": "disabled@example.com",
        "role": "user",
        "alreadyExisted": True,
    }
    assert "disabled-user" not in repository.disabled_auth_uids
    assert repository.get_role("disabled-user").value == "user"


def test_create_user_rejects_disabled_existing_auth_user_with_role(client, repository, monkeypatch):
    email_sender = configure_access_email(monkeypatch)
    repository.users["disabled-user"] = UserDoc(
        uid="disabled-user",
        email="disabled@example.com",
        created_at=utc_now(),
    )
    repository.roles["disabled-user"] = Role.USER
    repository.disabled_auth_uids.add("disabled-user")

    response = client.post(
        "/users",
        json=valid_payload(email="disabled@example.com"),
        headers=auth_header(),
    )

    assert response.status_code == 409
    payload = response.json()
    assert_error_shape(payload, "ACCOUNT_DISABLED")
    assert payload["error"]["message"] == "This user already has access, but their Firebase account is disabled."
    assert "disabled-user" in repository.disabled_auth_uids
    assert email_sender.calls == []


def test_create_user_rejects_invalid_email(client):
    response = client.post(
        "/users",
        json=valid_payload(email="not-an-email"),
        headers=auth_header(),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")


def test_create_user_maps_firebase_write_failure(client, repository, monkeypatch):
    email_sender = configure_access_email(monkeypatch)
    repository.create_user_error = FirebaseWriteFailedError("Simulated write failure.")

    response = client.post("/users", json=valid_payload(), headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "FIREBASE_WRITE_FAILED")
    assert email_sender.calls == []


def test_create_user_maps_unexpected_failure_to_internal_error(client, repository, monkeypatch):
    email_sender = configure_access_email(monkeypatch)
    repository.create_user_error = RuntimeError("Simulated unexpected failure.")

    response = client.post("/users", json=valid_payload(), headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "INTERNAL_ERROR")
    assert email_sender.calls == []

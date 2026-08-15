from dataclasses import replace
from email.message import Message
from urllib.error import HTTPError, URLError

import pytest

from src.auth import AuthenticatedUser
import src.routes as routes
from src.enums import ClientStatus, Role
from src.errors import FirebaseWriteFailedError, WireGuardApplyFailedError
from src.repository import ClientDoc, UserDoc, utc_now

from .conftest import REGION_ID
from .test_errors import assert_error_shape
from .test_routes_clients import create_active_client, seed_region


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


def test_delete_account_removes_peer_and_hard_deletes_all_owned_docs(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    creating = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Creating",
    )
    failed = repository.mark_client_failed(
        owner_uid="user-1",
        region_id=REGION_ID,
        client_id=creating.client_id,
        error_code="TEST",
        error_message="failed",
    )
    removed_seed = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Removed",
    )
    removed = repository.remove_client_reservation(
        owner_uid="user-1",
        region_id=REGION_ID,
        client_id=removed_seed.client_id,
    )
    other_user_client = repository.reserve_client(
        owner_uid="user-2",
        owner_email="user2@example.com",
        region_id=REGION_ID,
        client_name="Other",
    )

    response = client.delete("/account", headers=auth_header("user-token"))

    assert response.status_code == 200
    assert response.json() == {
        "userId": "user-1",
        "deletedClientCount": 3,
    }
    assert active.client_public_key not in wireguard.peers
    assert wireguard.remove_peer_calls == 1
    assert repository.get_user("user-1") is None
    assert repository.get_role("user-1") is None
    assert repository.deleted_auth_uids == ["user-1"]
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id) is None
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=failed.client_id) is None
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=removed.client_id) is None
    assert repository.get_client(owner_uid="user-2", region_id=REGION_ID, client_id=other_user_client.client_id) is not None


def test_delete_account_rejects_admin_without_deleting_docs(client, repository):
    repository.users["admin-1"] = UserDoc(
        uid="admin-1",
        email="admin@example.com",
        created_at=utc_now(),
    )

    response = client.delete("/account", headers=auth_header("admin-token"))

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")
    assert repository.get_user("admin-1") is not None
    assert repository.get_role("admin-1") == Role.ADMIN
    assert repository.deleted_auth_uids == []


def test_delete_account_requires_recent_sign_in(client, repository, token_verifier):
    token_verifier.users["user-token"] = AuthenticatedUser(
        uid="user-1",
        email="user@example.com",
        auth_time=0,
    )

    response = client.delete("/account", headers=auth_header("user-token"))

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")
    assert repository.get_role("user-1") == Role.USER
    assert repository.deleted_auth_uids == []


def test_delete_account_does_not_delete_docs_when_peer_removal_fails(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    wireguard.fail_remove_count = 1

    response = client.delete("/account", headers=auth_header("user-token"))

    assert response.status_code == 500
    assert_error_shape(response.json(), "WIREGUARD_APPLY_FAILED")
    assert repository.get_role("user-1") == Role.USER
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id) is not None
    assert active.client_public_key in wireguard.peers
    assert repository.deleted_auth_uids == []


def test_delete_account_can_retry_auth_delete_after_docs_were_removed(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    repository.delete_auth_user_error = RuntimeError("auth unavailable")

    response = client.delete("/account", headers=auth_header("user-token"))

    assert response.status_code == 500
    assert_error_shape(response.json(), "INTERNAL_ERROR")
    assert repository.get_user("user-1") is None
    assert repository.get_role("user-1") is None
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id) is None
    assert repository.deleted_auth_uids == []

    repository.delete_auth_user_error = None
    response = client.delete("/account", headers=auth_header("user-token"))

    assert response.status_code == 200
    assert response.json() == {
        "userId": "user-1",
        "deletedClientCount": 0,
    }
    assert repository.deleted_auth_uids == ["user-1"]


def _remote_client_doc() -> ClientDoc:
    return ClientDoc(
        client_id="remote-client-1",
        owner_uid="user-1",
        owner_email="user@example.com",
        client_name="Remote",
        region_id="us-other-1",
        status=ClientStatus.ACTIVE,
        assigned_tunnel_ipv4="10.0.0.2",
        assigned_tunnel_ipv6="fd00::2",
        server_endpoint_ipv4="203.0.113.10",
        server_public_key="server-pub",
        client_public_key="client-pub",
        wireguard_config=None,
    )


def _raise(exc: Exception):
    def _raiser(*args, **kwargs):
        raise exc

    return _raiser


def test_remove_account_peers_continues_when_remote_region_unreachable(monkeypatch, wireguard):
    calls = {"count": 0}

    def _unreachable(*args, **kwargs):
        calls["count"] += 1
        raise URLError("name resolution failed")

    monkeypatch.setattr(routes, "urlopen", _unreachable)

    # Unreachable host must not raise: the account deletion continues and the
    # orphaned peer is reconciled later by cloudgateway-sync-peers.
    routes._remove_account_peers(
        clients=[_remote_client_doc()],
        user=AuthenticatedUser(uid="user-1", email="user@example.com"),
        token="user-token",
        local_region_id=REGION_ID,
        api_hostname="api.gocloudlaunch.com",
        wireguard=wireguard,
        request_id="req-1",
    )

    assert calls["count"] == 1


def test_remove_account_peers_aborts_on_remote_http_error(monkeypatch, wireguard):
    http_error = HTTPError("https://us-other-1.example/api", 403, "Forbidden", Message(), None)
    monkeypatch.setattr(routes, "urlopen", _raise(http_error))

    # A challenge / auth / HTTP status error means the host answered: do not
    # assume the peer is gone - abort so it is not silently lost.
    with pytest.raises(WireGuardApplyFailedError) as excinfo:
        routes._remove_account_peers(
            clients=[_remote_client_doc()],
            user=AuthenticatedUser(uid="user-1", email="user@example.com"),
            token="user-token",
            local_region_id=REGION_ID,
            api_hostname="api.gocloudlaunch.com",
            wireguard=wireguard,
            request_id="req-1",
        )

    assert excinfo.value.transient is False


def test_remove_account_peers_rejects_a_malformed_region_id_before_calling_out(monkeypatch, wireguard):
    # region_id is the leftmost label of the regional API hostname. A bad
    # Admin-SDK-side write must not be able to redirect the call at another host.
    calls = {"count": 0}

    def _record(*args, **kwargs):
        calls["count"] += 1
        raise AssertionError("no request may be made for a malformed region id")

    monkeypatch.setattr(routes, "urlopen", _record)
    client = replace(_remote_client_doc(), region_id="evil.example.com/../")

    with pytest.raises(WireGuardApplyFailedError) as excinfo:
        routes._remove_account_peers(
            clients=[client],
            user=AuthenticatedUser(uid="user-1", email="user@example.com"),
            token="user-token",
            local_region_id=REGION_ID,
            api_hostname="api.gocloudlaunch.com",
            wireguard=wireguard,
            request_id="req-1",
        )

    assert excinfo.value.transient is False
    assert calls["count"] == 0

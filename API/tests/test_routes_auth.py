from src.auth import AuthenticatedUser, USER_NOT_PROVISIONED_DISABLED_MESSAGE

from .test_errors import assert_error_shape


def auth_header(token: str = "user-token") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_check_access_returns_role_for_provisioned_user(client):
    response = client.post("/auth/check-access", headers=auth_header())

    assert response.status_code == 200
    assert response.json() == {
        "userId": "user-1",
        "email": "user@example.com",
        "role": "user",
    }


def test_check_access_disables_and_revokes_unprovisioned_user(client, repository, token_verifier):
    token_verifier.users["pending-token"] = AuthenticatedUser(
        uid="pending-1",
        email="pending@example.com",
        display_name="Pending User",
    )

    response = client.post("/auth/check-access", headers=auth_header("pending-token"))

    assert response.status_code == 403
    payload = response.json()
    assert_error_shape(payload, "USER_NOT_PROVISIONED")
    assert payload["error"]["message"] == USER_NOT_PROVISIONED_DISABLED_MESSAGE
    assert "pending-1" in repository.disabled_auth_uids
    assert repository.revoked_auth_uids == ["pending-1"]


def test_protected_user_route_disables_unprovisioned_user(client, repository, token_verifier):
    token_verifier.users["pending-token"] = AuthenticatedUser(uid="pending-1", email="pending@example.com")

    response = client.post(
        "/clients",
        json={"regionId": "us-test-1"},
        headers=auth_header("pending-token"),
    )

    assert response.status_code == 403
    assert_error_shape(response.json(), "USER_NOT_PROVISIONED")
    assert "pending-1" in repository.disabled_auth_uids
    assert repository.revoked_auth_uids == ["pending-1"]


def test_admin_route_disables_unprovisioned_user(client, repository, token_verifier):
    token_verifier.users["pending-token"] = AuthenticatedUser(uid="pending-1", email="pending@example.com")

    response = client.post(
        "/users",
        json={"email": "new.user@example.com"},
        headers=auth_header("pending-token"),
    )

    assert response.status_code == 403
    assert_error_shape(response.json(), "USER_NOT_PROVISIONED")
    assert "pending-1" in repository.disabled_auth_uids
    assert repository.revoked_auth_uids == ["pending-1"]


def test_admin_route_keeps_admin_required_for_non_admin_user(client, repository):
    response = client.post(
        "/users",
        json={"email": "new.user@example.com"},
        headers=auth_header("user-token"),
    )

    assert response.status_code == 403
    assert_error_shape(response.json(), "ADMIN_REQUIRED")
    assert "user-1" not in repository.disabled_auth_uids


def test_disabled_or_revoked_token_maps_to_auth_required(client, token_verifier):
    token_verifier.disabled_tokens.add("user-token")

    response = client.post("/auth/check-access", headers=auth_header())

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")

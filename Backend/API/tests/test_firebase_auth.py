from unittest.mock import Mock

import pytest
from firebase_admin import auth, exceptions
from requests.exceptions import ConnectionError, Timeout

from src import firebase
from src.firebase import FirebaseTokenVerifier

from .test_errors import assert_error_shape


@pytest.fixture
def firebase_verifier(client, settings, monkeypatch):
    monkeypatch.setattr(firebase, "_firebase_app", Mock(return_value=None))
    client.app.state.token_verifier = FirebaseTokenVerifier(settings)


@pytest.mark.parametrize("error", [
    auth.InvalidIdTokenError("private verifier details"),
    auth.ExpiredIdTokenError("private verifier details", None),
    auth.RevokedIdTokenError("private verifier details"),
    auth.UserDisabledError("private verifier details"),
    auth.UserNotFoundError("private verifier details"),
])
@pytest.mark.usefixtures("firebase_verifier")
def test_firebase_identity_denials_return_401(client, repository, monkeypatch, error):
    verify = Mock(side_effect=error)
    monkeypatch.setattr(auth, "verify_id_token", verify)

    response = client.post("/auth/check-access", headers={"Authorization": "Bearer test-token"})

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")
    assert "private verifier details" not in response.text
    assert not repository.disabled_auth_uids
    verify.assert_called_once_with("test-token", check_revoked=True)


@pytest.mark.parametrize("error", [
    auth.CertificateFetchError("private verifier details", None),
    exceptions.UnavailableError("private verifier details"),
    exceptions.InternalError("private verifier details"),
    auth.InsufficientPermissionError("private verifier details", None, None),
    Timeout("private verifier details"),
    ConnectionError("private verifier details"),
    RuntimeError("private verifier details"),
])
@pytest.mark.usefixtures("firebase_verifier")
def test_firebase_verifier_outages_return_sanitized_503(client, repository, monkeypatch, error, caplog):
    verify = Mock(side_effect=error)
    monkeypatch.setattr(auth, "verify_id_token", verify)

    response = client.post("/auth/check-access", headers={"Authorization": "Bearer test-token"})

    assert response.status_code == 503
    assert_error_shape(response.json(), "AUTH_UNAVAILABLE")
    assert response.json()["error"]["message"] == "Authentication is temporarily unavailable. Try again shortly."
    assert "private verifier details" not in response.text
    assert "private verifier details" not in caplog.text
    assert not repository.disabled_auth_uids
    assert not repository.revoked_auth_uids
    verify.assert_called_once_with("test-token", check_revoked=True)


@pytest.mark.usefixtures("firebase_verifier")
def test_firebase_initialization_failure_returns_sanitized_503(client, monkeypatch, caplog):
    monkeypatch.setattr(firebase, "_firebase_app", Mock(side_effect=ValueError("private credential details")))
    verify = Mock()
    monkeypatch.setattr(auth, "verify_id_token", verify)

    response = client.post("/auth/check-access", headers={"Authorization": "Bearer test-token"})

    assert response.status_code == 503
    assert_error_shape(response.json(), "AUTH_UNAVAILABLE")
    assert "private credential details" not in response.text
    assert "private credential details" not in caplog.text
    verify.assert_not_called()


@pytest.mark.parametrize("user_result,status,code", [
    (exceptions.UnavailableError("private lookup details"), 503, "AUTH_UNAVAILABLE"),
    (auth.InsufficientPermissionError("private lookup details", None, None), 503, "AUTH_UNAVAILABLE"),
    (auth.UserNotFoundError("private lookup details"), 401, "AUTH_REQUIRED"),
    (auth.UserRecord({"localId": "user-1", "disabled": True}), 401, "AUTH_REQUIRED"),
    (auth.UserRecord({"localId": "user-1", "validSince": "2000"}), 401, "AUTH_REQUIRED"),
])
@pytest.mark.usefixtures("firebase_verifier")
def test_firebase_revocation_lookup_distinguishes_outage_from_denial(
    client, monkeypatch, user_result, status, code, caplog
):
    app = Mock(project_id="test-project", options={}, credential=Mock(get_credential=Mock(return_value=None)))
    sdk_client = auth.Client(app)
    sdk_client._token_verifier.verify_id_token = Mock(return_value={"uid": "user-1", "iat": 1000})
    get_user = Mock(side_effect=user_result) if isinstance(user_result, Exception) else Mock(return_value=user_result)
    monkeypatch.setattr(sdk_client, "get_user", get_user)
    monkeypatch.setattr(auth, "_get_client", Mock(return_value=sdk_client))

    response = client.post("/auth/check-access", headers={"Authorization": "Bearer test-token"})

    assert response.status_code == status
    assert_error_shape(response.json(), code)
    assert "private lookup details" not in response.text
    assert "private lookup details" not in caplog.text
    get_user.assert_called_once_with("user-1")


@pytest.mark.usefixtures("firebase_verifier")
def test_firebase_verified_identity_returns_access(client, monkeypatch):
    monkeypatch.setattr(auth, "verify_id_token", Mock(return_value={"uid": "user-1", "email": "user@example.com"}))

    response = client.post("/auth/check-access", headers={"Authorization": "Bearer test-token"})

    assert response.status_code == 200
    assert response.json()["userId"] == "user-1"

"""Device authorization integration tests for the local Firebase emulators."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import threading
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from itertools import count
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import Request, urlopen

import firebase_admin
import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth, firestore as admin_firestore
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore as cloud_firestore
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

from src.app import create_app
from src.device_auth_firebase import FirestoreDeviceAuthStore
from src.settings import Settings

PROJECT_ID = "demo-cloudgateway"
FIRESTORE_PORT = 8080
AUTH_PORT = 9099
pytestmark = pytest.mark.emulator
_SOURCE_OCTETS = count(100)
_EMULATOR_NOW = datetime(2030, 1, 1, tzinfo=timezone.utc)


@dataclass(frozen=True)
class EmulatorContext:
    auth_host: str
    firestore_host: str
    app: firebase_admin.App
    db: cloud_firestore.Client
    issuer: CountingTokenIssuer


class CountingTokenIssuer:
    def __init__(self, app: firebase_admin.App):
        self._app = app
        self._lock = threading.Lock()
        self.uids: list[str] = []

    def create_custom_token(self, uid: str) -> str:
        with self._lock:
            self.uids.append(uid)
        return auth.create_custom_token(uid, app=self._app).decode("utf-8")


def _checked_emulator_host(variable: str, expected_port: int) -> str:
    value = os.environ.get(variable, "").strip()
    if not value:
        pytest.fail(f"{variable} is required; this test must run inside the local Firebase emulators")
    parsed = urlsplit(f"http://{value}")
    if parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or parsed.port != expected_port:
        pytest.fail(f"{variable} must point to the loopback emulator on port {expected_port}")
    return value


def _http_json(method: str, url: str, body: dict[str, object] | None = None, token: str | None = None):
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(request, timeout=10) as response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else None
    except HTTPError as error:
        payload = error.read()
        return error.code, json.loads(payload) if payload else None
    except (TimeoutError, URLError) as error:
        pytest.fail(f"Local emulator request failed: {type(error).__name__}")


def _identity_token(emulator: EmulatorContext, email: str, password: str) -> dict[str, object]:
    query = urlencode({"key": "fake-api-key"})
    url = f"http://{emulator.auth_host}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?{query}"
    status, payload = _http_json(
        "POST",
        url,
        {"email": email, "password": password, "returnSecureToken": True},
    )
    assert status == 200, f"Auth emulator password sign-in returned HTTP {status}"
    assert isinstance(payload, dict)
    assert payload.get("idToken") and payload.get("localId")
    return payload


def _firestore_rest_url(emulator: EmulatorContext, document_path: str) -> str:
    encoded_path = "/".join(quote(part, safe="") for part in document_path.split("/"))
    return (
        f"http://{emulator.firestore_host}/v1/projects/{PROJECT_ID}/databases/(default)/documents/"
        f"{encoded_path}"
    )


def _rest_get_document(emulator: EmulatorContext, document_path: str, token: str) -> int:
    status, _ = _http_json("GET", _firestore_rest_url(emulator, document_path), token=token)
    return status


def _new_secret() -> tuple[str, str]:
    secret = secrets.token_bytes(32)
    encoded = base64.urlsafe_b64encode(secret).rstrip(b"=").decode("ascii")
    return encoded, hashlib.sha256(secret).hexdigest()


def _source_host() -> str:
    # Every test gets its own loopback source so persistent creation budgets
    # from one case cannot affect another.
    return f"127.0.0.{next(_SOURCE_OCTETS)}"


def _client(app, source_host: str) -> TestClient:
    return TestClient(app, raise_server_exceptions=False, client=(source_host, 46000))


def _new_app(
    emulator: EmulatorContext,
    source_host: str | None = None,
    *,
    clock: Callable[[], datetime] | None = None,
    random_bytes: Callable[[int], bytes] | None = None,
):
    settings = Settings(
        dashboard_cors_origin="https://dashboard.example.test",
        wg_server_public_key=base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
        wg_dns_ipv4="10.0.0.1",
        wg_dns_ipv6="fd42:42:42::1",
    )
    store = FirestoreDeviceAuthStore(settings, db=emulator.db)
    app = create_app(
        settings=settings,
        device_auth_store=store,
        device_auth_token_issuer=emulator.issuer,
        device_auth_clock=clock or (lambda: _EMULATOR_NOW),
        device_auth_random_bytes=random_bytes,
    )
    return _client(app, source_host or _source_host())


@pytest.fixture(scope="session")
def emulator() -> Iterator[EmulatorContext]:
    firestore_host = _checked_emulator_host("FIRESTORE_EMULATOR_HOST", FIRESTORE_PORT)
    auth_host = _checked_emulator_host("FIREBASE_AUTH_EMULATOR_HOST", AUTH_PORT)
    project = os.environ.get("GCLOUD_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT")
    if project != PROJECT_ID:
        pytest.fail(f"emulator project must be {PROJECT_ID}; got {project or 'unset'}")

    admin_app = firebase_admin.initialize_app(AnonymousCredentials(), {"projectId": PROJECT_ID})
    db = cloud_firestore.Client(project=PROJECT_ID, credentials=AnonymousCredentials())
    original_firestore_client = admin_firestore.client
    setattr(admin_firestore, "client", lambda app=None: db)
    issuer = CountingTokenIssuer(admin_app)
    context = EmulatorContext(
        auth_host=auth_host,
        firestore_host=firestore_host,
        app=admin_app,
        db=db,
        issuer=issuer,
    )
    try:
        yield context
    finally:
        setattr(admin_firestore, "client", original_firestore_client)
        firebase_admin.delete_app(admin_app)


def _create_request(client: TestClient, device_name: str = "Living room TV") -> tuple[dict[str, object], str]:
    secret, secret_hash = _new_secret()
    response = client.post(
        "/device/code",
        json={"deviceSecretHash": secret_hash, "deviceName": device_name},
    )
    assert response.status_code == 201, response.text
    result = response.json()
    assert len(result["deviceRequestId"]) == 32
    assert result["expiresIn"] == 300
    return result, secret


def _authorization_header(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _provisioned_identity(emulator: EmulatorContext) -> dict[str, str]:
    uid = f"device-auth-{secrets.token_hex(8)}"
    email = f"{uid}@example.test"
    password = secrets.token_urlsafe(24)
    created = auth.create_user(uid=uid, email=email, password=password, app=emulator.app)
    emulator.db.collection("Users").document(uid).set(
        {"uid": uid, "email": email, "createdAt": SERVER_TIMESTAMP}
    )
    emulator.db.collection("UserRoles").document(uid).set(
        {"uid": uid, "roleId": "user", "updatedAt": SERVER_TIMESTAMP}
    )
    return {"uid": created.uid, "email": email, "password": password}


def _sign_in_custom_token(emulator: EmulatorContext, custom_token: str) -> dict[str, object]:
    query = urlencode({"key": "fake-api-key"})
    url = f"http://{emulator.auth_host}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?{query}"
    status, payload = _http_json(
        "POST",
        url,
        {"token": custom_token, "returnSecureToken": True},
    )
    assert status == 200, f"Auth emulator custom-token sign-in returned HTTP {status}"
    assert isinstance(payload, dict)
    assert payload.get("idToken")
    return payload


def _creation_limit_id(source_host: str) -> str:
    digest = hashlib.sha256(source_host.encode("ascii")).hexdigest()
    return f"creation_{digest}"


def _guess_limit_id(uid: str) -> str:
    digest = hashlib.sha256(uid.encode("utf-8")).hexdigest()
    return f"guesses_{digest}"


def test_creation_limit_is_shared_across_store_instances(emulator: EmulatorContext):
    source_host = _source_host()
    clients = [_new_app(emulator, source_host), _new_app(emulator, source_host)]
    for index in range(4):
        secret_hash = hashlib.sha256(f"device-prime-{index}".encode("ascii")).hexdigest()
        response = clients[0].post("/device/code", json={"deviceSecretHash": secret_hash})
        assert response.status_code == 201, response.text

    def create(index: int):
        secret_hash = hashlib.sha256(f"device-race-{index}".encode("ascii")).hexdigest()
        response = clients[index % len(clients)].post("/device/code", json={"deviceSecretHash": secret_hash})
        return response.status_code, response.json()

    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(create, range(2)))

    assert [status for status, _ in outcomes].count(201) == 1
    assert [status for status, _ in outcomes].count(429) == 1
    request_ids = [payload["deviceRequestId"] for status, payload in outcomes if status == 201]
    assert len(set(request_ids)) == 1
    assert all(
        emulator.db.collection("DeviceAuthRequests").document(str(request_id)).get().exists
        for request_id in request_ids
    )
    limit = emulator.db.collection("DeviceAuthLimits").document(_creation_limit_id(source_host)).get()
    assert limit.exists
    limit_data = limit.to_dict() or {}
    assert limit_data["scope"] == "creation"
    assert len(limit_data["attempts"]) == 5


def test_guess_limit_is_shared_across_store_instances(emulator: EmulatorContext):
    identity = _provisioned_identity(emulator)
    auth_identity = _identity_token(emulator, identity["email"], identity["password"])
    identity["idToken"] = str(auth_identity["idToken"])
    source_host = _source_host()
    create_client = _new_app(emulator, source_host)
    result, _ = _create_request(create_client)
    clients = [_new_app(emulator), _new_app(emulator)]
    wrong_code = "000000" if result["userCode"] != "000000" else "000001"

    def guess(index: int):
        response = clients[index % len(clients)].post(
            "/device/verify",
            json={"deviceRequestId": result["deviceRequestId"], "userCode": wrong_code},
            headers=_authorization_header(identity["idToken"]),
        )
        return response.status_code

    with ThreadPoolExecutor(max_workers=5) as pool:
        statuses = list(pool.map(guess, range(5)))

    assert statuses.count(400) == 3
    assert statuses.count(429) == 2
    limit = emulator.db.collection("DeviceAuthLimits").document(_guess_limit_id(identity["uid"])).get()
    assert limit.exists
    limit_data = limit.to_dict() or {}
    assert limit_data["scope"] == "guesses"
    assert len(limit_data["attempts"]) == 3


def test_creation_limit_window_expires_at_exact_five_minute_boundary(emulator: EmulatorContext):
    source_host = _source_host()
    client = _new_app(emulator, source_host)
    for index in range(5):
        secret_hash = hashlib.sha256(f"window-device-{index}".encode("ascii")).hexdigest()
        response = client.post("/device/code", json={"deviceSecretHash": secret_hash})
        assert response.status_code == 201, response.text

    limit_ref = emulator.db.collection("DeviceAuthLimits").document(_creation_limit_id(source_host))
    historical_limit = limit_ref.get()
    assert historical_limit.exists
    historical_data = historical_limit.to_dict() or {}
    assert historical_data["expiresAt"] == _EMULATOR_NOW + timedelta(minutes=5)

    at_boundary = _new_app(
        emulator,
        source_host,
        clock=lambda: _EMULATOR_NOW + timedelta(minutes=5),
    )
    secret_hash = hashlib.sha256(b"window-boundary-device").hexdigest()
    response = at_boundary.post("/device/code", json={"deviceSecretHash": secret_hash})
    assert response.status_code == 201, response.text


def test_poll_proof_and_retry_do_not_advance_poll_window(emulator: EmulatorContext):
    current_time = [_EMULATOR_NOW]
    client = _new_app(emulator, clock=lambda: current_time[0])
    request, secret = _create_request(client)
    request_ref = emulator.db.collection("DeviceAuthRequests").document(str(request["deviceRequestId"]))

    first_poll = client.post(
        "/device/token",
        json={"deviceRequestId": request["deviceRequestId"], "deviceSecret": secret},
    )
    assert first_poll.status_code == 202
    expected_next_poll = _EMULATOR_NOW + timedelta(seconds=5)
    request_data = request_ref.get().to_dict()
    assert request_data is not None
    assert request_data["nextPollAt"] == expected_next_poll

    wrong_secret, _ = _new_secret()
    wrong_proof = client.post(
        "/device/token",
        json={"deviceRequestId": request["deviceRequestId"], "deviceSecret": wrong_secret},
    )
    assert wrong_proof.status_code == 400
    request_data = request_ref.get().to_dict()
    assert request_data is not None
    assert request_data["nextPollAt"] == expected_next_poll

    current_time[0] += timedelta(seconds=1)
    throttled = client.post(
        "/device/token",
        json={"deviceRequestId": request["deviceRequestId"], "deviceSecret": secret},
    )
    assert throttled.status_code == 429
    assert throttled.headers["Retry-After"] == "4"
    request_data = request_ref.get().to_dict()
    assert request_data is not None
    assert request_data["nextPollAt"] == expected_next_poll

    current_time[0] = expected_next_poll
    retry = client.post(
        "/device/token",
        json={"deviceRequestId": request["deviceRequestId"], "deviceSecret": secret},
    )
    assert retry.status_code == 202
    request_data = request_ref.get().to_dict()
    assert request_data is not None
    assert request_data["nextPollAt"] == expected_next_poll + timedelta(seconds=5)


def test_wrong_device_proof_has_same_error_for_each_request_state(emulator: EmulatorContext):
    approver = _provisioned_identity(emulator)
    token = _identity_token(emulator, approver["email"], approver["password"])
    headers = _authorization_header(str(token["idToken"]))
    client = _new_app(emulator)
    outcomes = []

    pending, _ = _create_request(client)
    denied, _ = _create_request(client)
    approved, _ = _create_request(client)

    for request, decision in ((denied, "deny"), (approved, "approve")):
        response = client.post(
            "/device/approve",
            json={
                "deviceRequestId": request["deviceRequestId"],
                "userCode": request["userCode"],
                "decision": decision,
            },
            headers=headers,
        )
        assert response.status_code == 200

    wrong_secret, _ = _new_secret()
    for request in (pending, denied, approved):
        response = client.post(
            "/device/token",
            json={"deviceRequestId": request["deviceRequestId"], "deviceSecret": wrong_secret},
        )
        outcomes.append((response.status_code, response.json()["error"]["code"]))

    assert outcomes == [(400, "DEVICE_AUTH_INVALID")] * 3


def test_repeated_codes_are_request_scoped_and_secrets_are_not_interchangeable(emulator: EmulatorContext):
    next_request_id = count(1)

    def fixed_code_random_bytes(length: int) -> bytes:
        if length == 3:
            return bytes.fromhex("00002a")
        assert length == 16
        return next(next_request_id).to_bytes(16, "big")

    client = _new_app(emulator, random_bytes=fixed_code_random_bytes)
    first, first_secret = _create_request(client)
    second, second_secret = _create_request(client)
    assert first["userCode"] == second["userCode"] == "000042"
    assert first["deviceRequestId"] != second["deviceRequestId"]

    identity = _provisioned_identity(emulator)
    token = _identity_token(emulator, identity["email"], identity["password"])
    approve = client.post(
        "/device/approve",
        json={
            "deviceRequestId": first["deviceRequestId"],
            "userCode": first["userCode"],
            "decision": "approve",
        },
        headers=_authorization_header(str(token["idToken"])),
    )
    assert approve.status_code == 200

    issuer_calls = len(emulator.issuer.uids)
    wrong_request_secret = client.post(
        "/device/token",
        json={"deviceRequestId": first["deviceRequestId"], "deviceSecret": second_secret},
    )
    assert wrong_request_secret.status_code == 400
    assert len(emulator.issuer.uids) == issuer_calls

    valid_exchange = client.post(
        "/device/token",
        json={"deviceRequestId": first["deviceRequestId"], "deviceSecret": first_secret},
    )
    assert valid_exchange.status_code == 200
    assert len(emulator.issuer.uids) == issuer_calls + 1


@pytest.mark.parametrize("access_change", ["role_removed", "user_removed", "user_disabled", "auth_disabled", "auth_deleted"])
def test_removed_or_disabled_access_cannot_redeem_approval(
    emulator: EmulatorContext,
    access_change: str,
):
    identity = _provisioned_identity(emulator)
    token = _identity_token(emulator, identity["email"], identity["password"])
    client = _new_app(emulator)
    request, secret = _create_request(client)
    approve = client.post(
        "/device/approve",
        json={
            "deviceRequestId": request["deviceRequestId"],
            "userCode": request["userCode"],
            "decision": "approve",
        },
        headers=_authorization_header(str(token["idToken"])),
    )
    assert approve.status_code == 200

    if access_change == "role_removed":
        emulator.db.collection("UserRoles").document(identity["uid"]).delete()
    elif access_change == "user_removed":
        emulator.db.collection("Users").document(identity["uid"]).delete()
    elif access_change == "user_disabled":
        emulator.db.collection("Users").document(identity["uid"]).update({"disabled": True})
    elif access_change == "auth_disabled":
        auth.update_user(identity["uid"], disabled=True, app=emulator.app)
    else:
        auth.delete_user(identity["uid"], app=emulator.app)

    issuer_calls = len(emulator.issuer.uids)
    response = client.post(
        "/device/token",
        json={"deviceRequestId": request["deviceRequestId"], "deviceSecret": secret},
    )
    assert response.status_code == 403
    assert len(emulator.issuer.uids) == issuer_calls
    request_doc = emulator.db.collection("DeviceAuthRequests").document(str(request["deviceRequestId"])).get()
    assert (request_doc.to_dict() or {}).get("state") == "approved"


def test_device_exchange_races_signs_in_and_obeys_firestore_rules(emulator: EmulatorContext):
    approver = _provisioned_identity(emulator)
    other_user = _provisioned_identity(emulator)
    approver_auth = _identity_token(emulator, approver["email"], approver["password"])
    other_auth = _identity_token(emulator, other_user["email"], other_user["password"])
    approver["idToken"] = str(approver_auth["idToken"])
    other_user["idToken"] = str(other_auth["idToken"])

    create_client = _new_app(emulator)
    decision_client_a = _new_app(emulator)
    decision_client_b = _new_app(emulator)
    decision_request, _ = _create_request(create_client)
    decision_body = {
        "deviceRequestId": decision_request["deviceRequestId"],
        "userCode": decision_request["userCode"],
    }

    def decide(client: TestClient, identity: dict[str, str], decision: str):
        return client.post(
            "/device/approve",
            json={**decision_body, "decision": decision},
            headers=_authorization_header(identity["idToken"]),
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        decision_results = list(
            pool.map(
                lambda args: decide(*args),
                [
                    (decision_client_a, approver, "approve"),
                    (decision_client_b, other_user, "deny"),
                ],
            )
        )
    assert sorted(response.status_code for response in decision_results) == [200, 409]
    decided_doc = emulator.db.collection("DeviceAuthRequests").document(str(decision_request["deviceRequestId"])).get()
    assert (decided_doc.to_dict() or {}).get("state") in {"approved", "denied"}

    device_request, device_secret = _create_request(create_client, "Living room display")
    request_id = str(device_request["deviceRequestId"])
    user_code = str(device_request["userCode"])
    assert re.fullmatch(r"[0-9]{6}", user_code)
    device_secret_hash = hashlib.sha256(
        base64.urlsafe_b64decode(device_secret + "=")
    ).hexdigest()
    request_data = emulator.db.collection("DeviceAuthRequests").document(request_id).get().to_dict()
    assert request_data is not None
    assert request_data["deviceSecretHash"] == device_secret_hash

    verify_client = _new_app(emulator)
    wrong_code = "000000" if user_code != "000000" else "000001"
    wrong_verify = verify_client.post(
        "/device/verify",
        json={"deviceRequestId": request_id, "userCode": wrong_code},
        headers=_authorization_header(approver["idToken"]),
    )
    assert wrong_verify.status_code == 400
    verify = verify_client.post(
        "/device/verify",
        json={"deviceRequestId": request_id, "userCode": user_code},
        headers=_authorization_header(approver["idToken"]),
    )
    assert verify.status_code == 200
    assert verify.json()["state"] == "pending"

    # The decision race above is isolated so either winner leaves this request
    # available for the successful token exchange below.
    if request_id == decision_body["deviceRequestId"]:
        pytest.fail("device request ids collided")
    approve = decision_client_a.post(
        "/device/approve",
        json={"deviceRequestId": request_id, "userCode": user_code, "decision": "approve"},
        headers=_authorization_header(approver["idToken"]),
    )
    assert approve.status_code == 200
    assert approve.json()["state"] == "approved"

    before_issuer_calls = len(emulator.issuer.uids)
    token_clients = [_new_app(emulator), _new_app(emulator)]

    def exchange(client: TestClient):
        return client.post("/device/token", json={"deviceRequestId": request_id, "deviceSecret": device_secret})

    with ThreadPoolExecutor(max_workers=2) as pool:
        exchange_results = list(pool.map(exchange, token_clients))
    assert [response.status_code for response in exchange_results].count(200) == 1
    assert len(emulator.issuer.uids) - before_issuer_calls == 1
    issued_response = next(response for response in exchange_results if response.status_code == 200)
    custom_token = issued_response.json()["customToken"]
    assert custom_token
    signed_in = _sign_in_custom_token(emulator, custom_token)
    assert emulator.issuer.uids[-1] == approver["uid"]

    signed_in_token = str(signed_in["idToken"])
    verified_token = auth.verify_id_token(
        signed_in_token,
        app=emulator.app,
        check_revoked=True,
    )
    assert verified_token["uid"] == approver["uid"]
    assert _rest_get_document(emulator, f"Users/{approver['uid']}", signed_in_token) == 200
    assert _rest_get_document(emulator, f"Users/{other_user['uid']}", signed_in_token) == 403
    assert _rest_get_document(emulator, f"DeviceAuthRequests/{request_id}", signed_in_token) == 403
    assert (
        _rest_get_document(emulator, f"DeviceAuthLimits/{_guess_limit_id(approver['uid'])}", signed_in_token)
        == 403
    )

    api_verify = _new_app(emulator).post(
        "/device/verify",
        json={"deviceRequestId": request_id, "userCode": user_code},
        headers=_authorization_header(signed_in_token),
    )
    assert api_verify.status_code == 200
    assert api_verify.json()["state"] == "consumed"


def test_expired_request_is_rejected_at_boundary_while_firestore_document_remains(emulator: EmulatorContext):
    identity = _provisioned_identity(emulator)
    auth_identity = _identity_token(emulator, identity["email"], identity["password"])
    client = _new_app(emulator)
    request, _ = _create_request(client)
    request_id = str(request["deviceRequestId"])
    request_ref = emulator.db.collection("DeviceAuthRequests").document(request_id)
    request_data = request_ref.get().to_dict()
    assert request_data is not None
    expires_at = request_data.get("expiresAt")
    assert isinstance(expires_at, datetime)

    before_boundary = _new_app(
        emulator,
        clock=lambda: expires_at - timedelta(microseconds=1),
    ).post(
        "/device/verify",
        json={"deviceRequestId": request_id, "userCode": request["userCode"]},
        headers=_authorization_header(str(auth_identity["idToken"])),
    )
    assert before_boundary.status_code == 200
    assert before_boundary.json()["state"] == "pending"

    response = _new_app(emulator, clock=lambda: expires_at).post(
        "/device/verify",
        json={"deviceRequestId": request_id, "userCode": request["userCode"]},
        headers=_authorization_header(str(auth_identity["idToken"])),
    )
    assert response.status_code == 410
    assert request_ref.get().exists

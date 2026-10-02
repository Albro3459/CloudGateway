import base64
import hashlib
from datetime import datetime, timedelta, timezone
from typing import cast

from fastapi.testclient import TestClient
from google.api_core.exceptions import Aborted

from src.app import create_app
from src.auth import AuthenticatedUser
from src.device_auth import DeviceAuthResult, _new_user_code
from src.device_auth_firebase import FirebaseDeviceAuthAdmin, FirestoreDeviceAuthStore, _active_attempts
from src.enums import Role
from src.repository import UserDoc
from src.settings import Settings

from .fakes import FakeRepository, FakeTokenVerifier, FakeWireGuardManager


class StubDeviceAuthStore:
    def __init__(self):
        self.create_result = DeviceAuthResult("created")
        self.create_results: list[DeviceAuthResult] = []
        self.verify_result = DeviceAuthResult(
            "verified",
            state="pending",
            device_name="TV",
            expires_at=datetime(2026, 10, 1, 12, 5, tzinfo=timezone.utc),
        )
        self.decision_result = DeviceAuthResult("approved", state="approved")
        self.poll_result = DeviceAuthResult("pending", state="pending")
        self.claim_result = DeviceAuthResult("claimed", uid="user-1")
        self.create_calls: list[dict] = []
        self.verify_calls: list[dict] = []
        self.decision_calls: list[dict] = []
        self.poll_calls: list[dict] = []
        self.claim_calls: list[dict] = []
        self.claimed = False
        self.create_error: Exception | None = None
        self.poll_error: Exception | None = None

    def create_request(self, **kwargs):
        self.create_calls.append(kwargs)
        if self.create_error is not None:
            raise self.create_error
        if self.create_results:
            return self.create_results.pop(0)
        return self.create_result

    def verify_request(self, **kwargs):
        self.verify_calls.append(kwargs)
        return self.verify_result

    def decide_request(self, **kwargs):
        self.decision_calls.append(kwargs)
        return self.decision_result

    def poll_request(self, **kwargs):
        self.poll_calls.append(kwargs)
        if self.poll_error is not None:
            raise self.poll_error
        return self.poll_result

    def consume_approved_request(self, **kwargs):
        self.claim_calls.append(kwargs)
        if self.claimed:
            return DeviceAuthResult("consumed")
        self.claimed = True
        return self.claim_result


class StubDeviceAuthAdmin:
    def __init__(self, *, enabled: bool = True):
        self.enabled = enabled
        self.checked_uids: list[str] = []
        self.issued_uids: list[str] = []
        self.issue_error: Exception | None = None
        self.check_error: Exception | None = None

    def check_user_enabled(self, uid: str) -> bool:
        self.checked_uids.append(uid)
        if self.check_error is not None:
            raise self.check_error
        return self.enabled

    def create_custom_token(self, uid: str) -> str:
        self.issued_uids.append(uid)
        if self.issue_error is not None:
            raise self.issue_error
        return "test-custom-token"


class PeerAddressApp:
    def __init__(self, app, peer_host: str):
        self._app = app
        self._peer_host = peer_host

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            scope["client"] = (self._peer_host, 12345)
        await self._app(scope, receive, send)

    def add_api_route(self, *args, **kwargs):
        self._app.add_api_route(*args, **kwargs)


def build_client(
    *,
    store: StubDeviceAuthStore | None = None,
    admin: StubDeviceAuthAdmin | None = None,
    peer_host: str = "127.0.0.1",
    random_bytes=None,
) -> tuple[TestClient, StubDeviceAuthStore, StubDeviceAuthAdmin]:
    store = store or StubDeviceAuthStore()
    admin = admin or StubDeviceAuthAdmin()
    repository = FakeRepository()
    repository.roles["user-1"] = Role.USER
    repository.users["user-1"] = UserDoc(uid="user-1", email="user@example.com")
    verifier = FakeTokenVerifier(
        {
            "user-token": AuthenticatedUser(uid="user-1", email="user@example.com"),
        }
    )
    settings = Settings(
        region_id="us-test-1",
        dashboard_cors_origin="https://gocloudlaunch.com",
    )
    app = create_app(
        settings=settings,
        token_verifier=verifier,
        repository=repository,
        wireguard=FakeWireGuardManager(),
        device_auth_store=store,
        device_auth_token_issuer=admin,
        device_auth_user_checker=admin,
        device_auth_clock=lambda: datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc),
        device_auth_random_bytes=random_bytes or (lambda size: b"\x00" * size),
    )
    return TestClient(PeerAddressApp(app, peer_host), raise_server_exceptions=False), store, admin


def _code_body() -> dict[str, str]:
    secret_hash = hashlib.sha256(bytes(range(32))).hexdigest()
    return {"deviceSecretHash": secret_hash, "deviceName": "  TV\nbox  "}


def test_device_http_flow_preserves_code_and_returns_only_custom_token():
    client, store, admin = build_client()
    created = client.post("/device/code", json=_code_body())
    assert created.status_code == 201
    assert created.json() == {
        "deviceRequestId": "00" * 16,
        "userCode": "000000",
        "verificationUri": "https://gocloudlaunch.com/#/auth/code",
        "verificationUriComplete": (
            "https://gocloudlaunch.com/#/auth/code?deviceRequestId="
            + "00" * 16
            + "&userCode=000000"
        ),
        "expiresIn": 300,
        "interval": 5,
    }
    assert created.headers["cache-control"] == "no-store"
    assert store.create_calls[0]["device_name"] == "TVbox"

    verified = client.post(
        "/device/verify",
        json={"deviceRequestId": "00" * 16, "userCode": "000000"},
        headers={"Authorization": "Bearer user-token"},
    )
    assert verified.status_code == 200
    assert verified.json()["state"] == "pending"
    assert verified.json()["userCode"] == "000000"
    assert "uid" not in verified.text
    assert verified.headers["cache-control"] == "no-store"

    approved = client.post(
        "/device/approve",
        json={"deviceRequestId": "00" * 16, "userCode": "000000", "decision": "approve"},
        headers={"Authorization": "Bearer user-token"},
    )
    assert approved.status_code == 200
    assert approved.json() == {"state": "approved"}
    assert approved.headers["cache-control"] == "no-store"

    secret = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode("ascii")
    store.poll_result = DeviceAuthResult("approved", state="approved", uid="user-1")
    exchanged = client.post(
        "/device/token",
        json={"deviceRequestId": "00" * 16, "deviceSecret": secret},
    )
    assert exchanged.status_code == 200
    assert exchanged.json() == {"customToken": "test-custom-token"}
    assert exchanged.headers["cache-control"] == "no-store"
    assert admin.issued_uids == ["user-1"]
    assert store.claim_calls[0]["device_request_id"] == "00" * 16


def test_user_codes_use_unbiased_rejection_and_request_ids_retry_collisions():
    samples = iter([(1 << 24) - 1, 999_999, 0])
    assert _new_user_code(lambda size: next(samples).to_bytes(size, "big")) == "999999"
    assert _new_user_code(lambda size: b"\x00" * size) == "000000"

    store = StubDeviceAuthStore()
    store.create_results = [DeviceAuthResult("collision"), DeviceAuthResult("created"), DeviceAuthResult("created")]
    ids = iter([b"\xaa" * 16, b"\xbb" * 16, b"\xcc" * 16])

    def random_bytes(size: int) -> bytes:
        return b"\x00" * size if size == 3 else next(ids)

    client, _, _ = build_client(store=store, random_bytes=random_bytes)
    first = client.post("/device/code", json=_code_body())
    second = client.post("/device/code", json=_code_body())
    assert first.status_code == second.status_code == 201
    assert first.json()["userCode"] == second.json()["userCode"] == "000000"
    assert first.json()["deviceRequestId"] == "bb" * 16
    assert second.json()["deviceRequestId"] == "cc" * 16
    assert len({call["user_code_hash"] for call in store.create_calls}) == 1


def test_pending_poll_and_all_device_errors_are_no_store():
    client, store, _ = build_client()
    secret = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode("ascii")
    pending = client.post("/device/token", json={"deviceRequestId": "00" * 16, "deviceSecret": secret})
    assert pending.status_code == 202
    assert pending.json() == {"state": "pending", "interval": 5}
    assert pending.headers["cache-control"] == "no-store"

    poll_count = len(store.poll_calls)
    invalid = client.post("/device/token", json={"deviceRequestId": "bad", "deviceSecret": "bad"})
    assert invalid.status_code == 400
    assert invalid.json()["error"]["code"] == "DEVICE_AUTH_INVALID"
    assert invalid.headers["cache-control"] == "no-store"
    assert len(store.poll_calls) == poll_count

    unauthenticated = client.post(
        "/device/verify",
        json={"deviceRequestId": "00" * 16, "userCode": "000000"},
    )
    assert unauthenticated.status_code == 401
    assert unauthenticated.json()["error"]["code"] == "AUTH_REQUIRED"
    assert unauthenticated.headers["cache-control"] == "no-store"


def test_retry_after_and_external_failures_are_sanitized():
    store = StubDeviceAuthStore()
    store.create_result = DeviceAuthResult("throttled", retry_after=23)
    client, _, _ = build_client(store=store)
    throttled = client.post("/device/code", json=_code_body())
    assert throttled.status_code == 429
    assert throttled.headers["retry-after"] == "23"
    assert throttled.headers["cache-control"] == "no-store"

    store = StubDeviceAuthStore()
    store.poll_error = RuntimeError("private verifier value")
    client, _, _ = build_client(store=store)
    secret = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode("ascii")
    unavailable = client.post("/device/token", json={"deviceRequestId": "00" * 16, "deviceSecret": secret})
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["code"] == "DEVICE_AUTH_UNAVAILABLE"
    assert "private verifier value" not in unavailable.text
    assert unavailable.headers["cache-control"] == "no-store"


def test_unexpected_device_exception_is_sanitized_and_no_store_even_outside_middleware(caplog):
    client, _, _ = build_client()

    def fail_device_request():
        raise RuntimeError("request secret and traceback detail")

    cast(PeerAddressApp, client.app).add_api_route(
        "/device/internal-failure",
        fail_device_request,
        methods=["POST"],
    )
    response = client.post("/device/internal-failure")
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "DEVICE_AUTH_UNAVAILABLE"
    assert response.headers["cache-control"] == "no-store"
    assert "request secret and traceback detail" not in response.text
    assert "request secret and traceback detail" not in caplog.text


def test_token_secret_must_use_canonical_base64url_encoding():
    client, store, _ = build_client()
    secret = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode("ascii")
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    last_index = alphabet.index(secret[-1])
    noncanonical = secret[:-1] + alphabet[(last_index + 1) % len(alphabet)]
    response = client.post(
        "/device/token",
        json={"deviceRequestId": "00" * 16, "deviceSecret": noncanonical},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "DEVICE_AUTH_INVALID"
    assert response.headers["cache-control"] == "no-store"
    assert not store.poll_calls


def test_trusted_source_uses_peer_for_direct_requests_and_loopback_header_for_proxy():
    direct, direct_store, _ = build_client(peer_host="198.51.100.19")
    headers_a = {
        "X-CloudGateway-Client-IP": "203.0.113.44",
        "CF-Connecting-IP": "203.0.113.55",
        "X-Forwarded-For": "203.0.113.66",
    }
    headers_b = {
        "X-CloudGateway-Client-IP": "192.0.2.123",
        "CF-Connecting-IP": "192.0.2.124",
        "X-Forwarded-For": "192.0.2.125",
    }
    assert direct.post("/device/code", json=_code_body(), headers=headers_a).status_code == 201
    assert direct.post("/device/code", json=_code_body(), headers=headers_b).status_code == 201
    expected_direct = hashlib.sha256(b"198.51.100.19").hexdigest()
    assert [call["source_digest"] for call in direct_store.create_calls] == [expected_direct, expected_direct]

    proxied, proxy_store, _ = build_client(peer_host="127.0.0.1")
    response = proxied.post(
        "/device/code",
        json=_code_body(),
        headers={"X-CloudGateway-Client-IP": "2001:0db8:0000::1"},
    )
    expected_proxy = hashlib.sha256(b"2001:db8::1").hexdigest()
    assert response.status_code == 201
    assert proxy_store.create_calls[0]["source_digest"] == expected_proxy

    malformed = proxied.post(
        "/device/code",
        json=_code_body(),
        headers={"X-CloudGateway-Client-IP": "not-an-ip"},
    )
    assert malformed.status_code == 503
    assert malformed.json()["error"]["code"] == "DEVICE_AUTH_UNAVAILABLE"
    assert malformed.headers["cache-control"] == "no-store"
    assert len(proxy_store.create_calls) == 1


def test_auth_user_disabled_after_approval_prevents_claim_and_signing():
    store = StubDeviceAuthStore()
    store.poll_result = DeviceAuthResult("approved", state="approved", uid="user-1")
    admin = StubDeviceAuthAdmin(enabled=False)
    client, _, _ = build_client(store=store, admin=admin)
    secret = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode("ascii")
    response = client.post("/device/token", json={"deviceRequestId": "00" * 16, "deviceSecret": secret})
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "DEVICE_AUTH_DENIED"
    assert response.headers["cache-control"] == "no-store"
    assert not store.claim_calls
    assert not admin.issued_uids


def test_signing_failure_consumes_request_and_replay_does_not_sign_again():
    store = StubDeviceAuthStore()
    store.poll_result = DeviceAuthResult("approved", state="approved", uid="user-1")
    admin = StubDeviceAuthAdmin()
    admin.issue_error = RuntimeError("private signing key details")
    client, _, _ = build_client(store=store, admin=admin)
    secret = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode("ascii")
    body = {"deviceRequestId": "00" * 16, "deviceSecret": secret}

    failed = client.post("/device/token", json=body)
    assert failed.status_code == 503
    assert failed.json()["error"]["code"] == "DEVICE_AUTH_UNAVAILABLE"
    assert "private signing key details" not in failed.text
    assert failed.headers["cache-control"] == "no-store"

    replay = client.post("/device/token", json=body)
    assert replay.status_code == 409
    assert replay.json()["error"]["code"] == "DEVICE_AUTH_CONSUMED"
    assert replay.headers["cache-control"] == "no-store"
    assert admin.issued_uids == ["user-1"]
    assert len(store.claim_calls) == 2


def test_browser_access_failures_use_safe_existing_or_device_errors():
    unprovisioned = FakeRepository()
    verifier = FakeTokenVerifier({"user-token": AuthenticatedUser(uid="user-1")})
    settings = Settings()
    store = StubDeviceAuthStore()
    admin = StubDeviceAuthAdmin()
    app = create_app(
        settings=settings,
        token_verifier=verifier,
        repository=unprovisioned,
        wireguard=FakeWireGuardManager(),
        device_auth_store=store,
        device_auth_token_issuer=admin,
        device_auth_user_checker=admin,
    )
    client = TestClient(app, raise_server_exceptions=False)
    response = client.post(
        "/device/verify",
        json={"deviceRequestId": "00" * 16, "userCode": "000000"},
        headers={"Authorization": "Bearer user-token"},
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "USER_NOT_PROVISIONED"
    assert response.headers["cache-control"] == "no-store"
    assert not store.verify_calls

    admin.check_error = RuntimeError("private auth service details")
    client, _, _ = build_client(store=store, admin=admin)
    unavailable = client.post(
        "/device/verify",
        json={"deviceRequestId": "00" * 16, "userCode": "000000"},
        headers={"Authorization": "Bearer user-token"},
    )
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["code"] == "DEVICE_AUTH_UNAVAILABLE"
    assert "private auth service details" not in unavailable.text
    assert unavailable.headers["cache-control"] == "no-store"


def test_firebase_admin_adapter_reuses_initializer_and_mocks_custom_token(monkeypatch):
    import firebase_admin.auth

    sentinel_app = object()
    monkeypatch.setattr("src.firebase._firebase_app", lambda settings: sentinel_app)
    called: list[tuple[str, object]] = []

    def create_custom_token(uid: str, *, app):
        called.append((uid, app))
        return b"emulator-test-token"

    monkeypatch.setattr(firebase_admin.auth, "create_custom_token", create_custom_token)
    issuer = FirebaseDeviceAuthAdmin(Settings())
    assert issuer.create_custom_token("user-1") == "emulator-test-token"
    assert called == [("user-1", sentinel_app)]


def test_expiry_during_product_reads_prevents_transactional_claim(monkeypatch):
    start = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)
    expiry = start.replace(second=1)
    clock = {"now": start}
    request_id = "11" * 16
    secret_hash = hashlib.sha256(bytes(range(32))).hexdigest()
    documents = {
        f"DeviceAuthRequests/{request_id}": {
            "deviceSecretHash": secret_hash,
            "state": "approved",
            "approvedUid": "user-1",
            "decidedUid": "user-1",
            "expiresAt": expiry,
        },
        "Users/user-1": {"disabled": False},
        "UserRoles/user-1": {"roleId": "user"},
    }
    writes: list[tuple[str, dict]] = []

    class Snapshot:
        def __init__(self, data):
            self.exists = data is not None
            self._data = data

        def to_dict(self):
            return self._data

    class Transaction:
        def update(self, reference, updates):
            writes.append((reference.path, updates))

    class Reference:
        def __init__(self, path):
            self.path = path

        def get(self, transaction=None):
            if self.path == "Users/user-1":
                clock["now"] += timedelta(seconds=2)
            return Snapshot(documents.get(self.path))

    class Collection:
        def __init__(self, name):
            self.name = name

        def document(self, document_id):
            return Reference(f"{self.name}/{document_id}")

    class Database:
        def collection(self, name):
            return Collection(name)

        def transaction(self):
            return Transaction()

    def passthrough_transactional(function):
        return lambda transaction: function(transaction)

    monkeypatch.setattr("google.cloud.firestore_v1.transactional", passthrough_transactional)
    store = FirestoreDeviceAuthStore(Settings(), db=Database())
    result = store.consume_approved_request(
        device_request_id=request_id,
        device_secret_hash=secret_hash,
        now=lambda: clock["now"],
    )
    assert result.outcome == "expired"
    assert writes == []


def test_attempt_exactly_at_rolling_window_boundary_is_pruned():
    now = datetime(2026, 10, 1, 12, 5, tzinfo=timezone.utc)

    class Snapshot:
        exists = True

        def to_dict(self):
            return {
                "scope": "guesses",
                "attempts": [now - timedelta(seconds=300), now - timedelta(seconds=299)],
                "expiresAt": now + timedelta(seconds=1),
            }

    attempts = _active_attempts(Snapshot(), now, scope="guesses")
    assert attempts == [now - timedelta(seconds=299)]


def test_transaction_retries_only_aborted_with_a_fresh_callback_time(monkeypatch):
    class Transaction:
        pass

    class Database:
        def __init__(self):
            self.calls = 0

        def transaction(self):
            self.calls += 1
            return Transaction()

    def passthrough_transactional(function):
        return lambda transaction: function(transaction)

    monkeypatch.setattr("google.cloud.firestore_v1.transactional", passthrough_transactional)
    store = FirestoreDeviceAuthStore(Settings(), db=object())
    database = Database()
    callback_times = iter(
        [
            datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc),
            datetime(2026, 10, 1, 12, 0, 1, tzinfo=timezone.utc),
        ]
    )
    observed_times = []

    def operation(_transaction):
        observed_times.append(next(callback_times))
        if len(observed_times) == 1:
            raise Aborted("transaction lock timeout")
        return DeviceAuthResult("claimed", uid="user-1")

    result = store._run_transaction(database, operation)
    assert result == DeviceAuthResult("claimed", uid="user-1")
    assert database.calls == 2
    assert observed_times[1] > observed_times[0]


def test_firestore_decision_results_match_api_outcomes(monkeypatch):
    now = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)
    request_id = "22" * 16
    code_hash = hashlib.sha256(b"004281").hexdigest()

    class Snapshot:
        def __init__(self, data):
            self.exists = data is not None
            self._data = data

        def to_dict(self):
            return self._data

    class Transaction:
        def __init__(self):
            self.writes = []

        def update(self, reference, updates):
            self.writes.append((reference.path, updates))

        def set(self, reference, data):
            self.writes.append((reference.path, data))

    class Reference:
        def __init__(self, db, path):
            self._db = db
            self.path = path

        def get(self, transaction=None):
            return Snapshot(self._db.documents.get(self.path))

    class Collection:
        def __init__(self, db, name):
            self._db = db
            self.name = name

        def document(self, document_id):
            return Reference(self._db, f"{self.name}/{document_id}")

    class Database:
        def __init__(self, request_data):
            self.documents = {
                f"DeviceAuthRequests/{request_id}": request_data,
                "Users/user-1": {"disabled": False},
                "UserRoles/user-1": {"roleId": "user"},
            }
            self.last_transaction = None

        def collection(self, name):
            return Collection(self, name)

        def transaction(self):
            self.last_transaction = Transaction()
            return self.last_transaction

    monkeypatch.setattr("google.cloud.firestore_v1.transactional", lambda function: lambda transaction: function(transaction))
    for decision, expected in (("approve", "approved"), ("deny", "denied")):
        db = Database(
            {
                "state": "pending",
                "userCodeHash": code_hash,
                "deviceName": "TV",
                "expiresAt": now + timedelta(minutes=1),
            }
        )
        store = FirestoreDeviceAuthStore(Settings(), db=db)
        result = store.decide_request(
            uid="user-1",
            device_request_id=request_id,
            user_code_hash=code_hash,
            decision=decision,
            now=lambda: now,
        )
        assert db.last_transaction is not None
        transaction = db.last_transaction
        assert result.outcome == expected
        assert result.state == expected
        assert transaction.writes[0][1]["state"] == expected
        if decision == "approve":
            assert transaction.writes[0][1]["approvedUid"] == "user-1"
        else:
            assert "approvedUid" not in transaction.writes[0][1]

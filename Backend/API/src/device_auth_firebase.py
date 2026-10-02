import hmac
import math
import re
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from typing import Any, Literal

from .device_auth import (
    DEVICE_AUTH_GUESS_LIMIT,
    DEVICE_AUTH_LIFETIME,
    DEVICE_AUTH_LIMIT_WINDOW,
    DEVICE_AUTH_POLL_INTERVAL,
    DEVICE_AUTH_SOURCE_LIMIT,
    DeviceAuthResult,
)
from .errors import DeviceAuthUnavailableError
from .settings import Settings

_HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_STATE_VALUES = {"pending", "approved", "denied", "consumed"}


class FirestoreDeviceAuthStore:
    """Transactional device authorization storage, isolated from VPN records."""

    def __init__(self, settings: Settings, *, db: Any | None = None):
        self._settings = settings
        self._injected_db = db

    def create_request(
        self,
        *,
        device_request_id: str,
        user_code_hash: str,
        device_secret_hash: str,
        device_name: str | None,
        source_digest: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult:
        if not all(_HASH_PATTERN.fullmatch(value) for value in (user_code_hash, device_secret_hash, source_digest)):
            raise DeviceAuthUnavailableError()
        try:
            db = self._db()
            request_ref = db.collection("DeviceAuthRequests").document(device_request_id)
            limit_ref = db.collection("DeviceAuthLimits").document(f"creation_{source_digest}")

            def create(transaction) -> DeviceAuthResult:
                request_snapshot = request_ref.get(transaction=transaction)
                limit_snapshot = limit_ref.get(transaction=transaction)
                current = _as_utc(now())
                if request_snapshot.exists:
                    return DeviceAuthResult("collision")
                attempts = _active_attempts(limit_snapshot, current, scope="creation")
                if len(attempts) >= DEVICE_AUTH_SOURCE_LIMIT:
                    return _throttled(attempts, current)

                created_at = current
                expires_at = created_at + DEVICE_AUTH_LIFETIME
                transaction.create(
                    request_ref,
                    {
                        "deviceSecretHash": device_secret_hash,
                        "userCodeHash": user_code_hash,
                        "deviceName": device_name or "",
                        "state": "pending",
                        "createdAt": created_at,
                        "expiresAt": expires_at,
                        "nextPollAt": created_at,
                    },
                )
                transaction.set(
                    limit_ref,
                    {
                        "scope": "creation",
                        "attempts": [*attempts, current],
                        "expiresAt": current + DEVICE_AUTH_LIMIT_WINDOW,
                    },
                )
                return DeviceAuthResult("created", expires_at=expires_at)

            return self._run_transaction(db, create)
        except DeviceAuthUnavailableError:
            raise
        except Exception:
            raise DeviceAuthUnavailableError() from None

    def verify_request(
        self,
        *,
        uid: str,
        device_request_id: str,
        user_code_hash: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult:
        return self._browser_operation(
            uid=uid,
            device_request_id=device_request_id,
            user_code_hash=user_code_hash,
            decision=None,
            now=now,
        )

    def decide_request(
        self,
        *,
        uid: str,
        device_request_id: str,
        user_code_hash: str,
        decision: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult:
        if decision not in {"approve", "deny"}:
            raise DeviceAuthUnavailableError()
        return self._browser_operation(
            uid=uid,
            device_request_id=device_request_id,
            user_code_hash=user_code_hash,
            decision=decision,
            now=now,
        )

    def _browser_operation(
        self,
        *,
        uid: str,
        device_request_id: str,
        user_code_hash: str,
        decision: str | None,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult:
        if not _HASH_PATTERN.fullmatch(user_code_hash):
            raise DeviceAuthUnavailableError()
        try:
            db = self._db()
            request_ref = db.collection("DeviceAuthRequests").document(device_request_id)
            limit_ref = db.collection("DeviceAuthLimits").document(f"guesses_{_uid_digest(uid)}")
            user_ref = db.collection("Users").document(uid)
            role_ref = db.collection("UserRoles").document(uid)

            def operate(transaction) -> DeviceAuthResult:
                request_snapshot = request_ref.get(transaction=transaction)
                limit_snapshot = limit_ref.get(transaction=transaction)
                user_snapshot = user_ref.get(transaction=transaction)
                role_snapshot = role_ref.get(transaction=transaction)
                current = _as_utc(now())
                if not _product_access(user_snapshot, role_snapshot):
                    return DeviceAuthResult("unprovisioned")

                attempts = _active_attempts(limit_snapshot, current, scope="guesses")
                if len(attempts) >= DEVICE_AUTH_GUESS_LIMIT:
                    return _throttled(attempts, current)

                data = request_snapshot.to_dict() or {} if request_snapshot.exists else {}
                code_matches = request_snapshot.exists and _constant_hash_matches(
                    data.get("userCodeHash"), user_code_hash
                )
                if not code_matches:
                    transaction.set(
                        limit_ref,
                        {
                            "scope": "guesses",
                            "attempts": [*attempts, current],
                            "expiresAt": current + DEVICE_AUTH_LIMIT_WINDOW,
                        },
                    )
                    return DeviceAuthResult("invalid")

                expires_at = _required_datetime(data.get("expiresAt"))
                if current >= expires_at:
                    return DeviceAuthResult("expired")
                state = _request_state(data)
                device_name = data.get("deviceName")
                if not isinstance(device_name, str):
                    raise ValueError("Malformed device authorization record")
                device_name = device_name or None
                if decision is None:
                    return DeviceAuthResult(
                        "verified",
                        state=state,
                        device_name=device_name,
                        expires_at=expires_at,
                    )

                requested_state: Literal["approved", "denied"] = (
                    "approved" if decision == "approve" else "denied"
                )
                if state == "pending":
                    updates: dict[str, Any] = {
                        "state": requested_state,
                        "decidedUid": uid,
                        "decidedAt": _server_timestamp(),
                    }
                    if decision == "approve":
                        updates["approvedUid"] = uid
                    transaction.update(request_ref, updates)
                    return DeviceAuthResult(requested_state, state=requested_state)

                if state in {"approved", "denied", "consumed"}:
                    current_decision = "approve" if data.get("approvedUid") else "deny"
                    if data.get("decidedUid") == uid and current_decision == decision:
                        return DeviceAuthResult(requested_state, state=requested_state)
                    return DeviceAuthResult("conflict")
                raise ValueError("Malformed device authorization record")

            return self._run_transaction(db, operate)
        except DeviceAuthUnavailableError:
            raise
        except Exception:
            raise DeviceAuthUnavailableError() from None

    def poll_request(
        self,
        *,
        device_request_id: str,
        device_secret_hash: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult:
        if not _HASH_PATTERN.fullmatch(device_secret_hash):
            raise DeviceAuthUnavailableError()
        try:
            db = self._db()
            request_ref = db.collection("DeviceAuthRequests").document(device_request_id)

            def poll(transaction) -> DeviceAuthResult:
                snapshot = request_ref.get(transaction=transaction)
                current = _as_utc(now())
                if not snapshot.exists:
                    return DeviceAuthResult("invalid")
                data = snapshot.to_dict() or {}
                if not _constant_hash_matches(data.get("deviceSecretHash"), device_secret_hash):
                    return DeviceAuthResult("invalid")

                expires_at = _required_datetime(data.get("expiresAt"))
                if current >= expires_at:
                    return DeviceAuthResult("expired")
                state = _request_state(data)
                if state == "denied":
                    return DeviceAuthResult("denied_state")
                if state == "consumed":
                    return DeviceAuthResult("consumed")
                if state == "approved":
                    uid = data.get("approvedUid")
                    if not isinstance(uid, str) or not uid:
                        raise ValueError("Malformed approved device authorization record")
                else:
                    uid = None

                next_poll_at = _required_datetime(data.get("nextPollAt"))
                if current < next_poll_at:
                    return DeviceAuthResult("throttled", retry_after=_retry_after(next_poll_at, current))
                transaction.update(
                    request_ref,
                    {"nextPollAt": current + timedelta(seconds=DEVICE_AUTH_POLL_INTERVAL)},
                )
                if state == "pending":
                    return DeviceAuthResult("pending", state=state)
                return DeviceAuthResult("approved", state=state, uid=uid)

            return self._run_transaction(db, poll)
        except DeviceAuthUnavailableError:
            raise
        except Exception:
            raise DeviceAuthUnavailableError() from None

    def consume_approved_request(
        self,
        *,
        device_request_id: str,
        device_secret_hash: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult:
        if not _HASH_PATTERN.fullmatch(device_secret_hash):
            raise DeviceAuthUnavailableError()
        try:
            db = self._db()
            request_ref = db.collection("DeviceAuthRequests").document(device_request_id)

            def consume(transaction) -> DeviceAuthResult:
                request_snapshot = request_ref.get(transaction=transaction)
                current = _as_utc(now())
                if not request_snapshot.exists:
                    return DeviceAuthResult("invalid")
                data = request_snapshot.to_dict() or {}
                if not _constant_hash_matches(data.get("deviceSecretHash"), device_secret_hash):
                    return DeviceAuthResult("invalid")
                expires_at = _required_datetime(data.get("expiresAt"))
                if current >= expires_at:
                    return DeviceAuthResult("expired")
                state = _request_state(data)
                if state == "denied":
                    return DeviceAuthResult("denied_state")
                if state == "consumed":
                    return DeviceAuthResult("consumed")
                if state == "pending":
                    return DeviceAuthResult("pending", state=state)
                uid = data.get("approvedUid")
                if not isinstance(uid, str) or not uid or data.get("decidedUid") != uid:
                    raise ValueError("Malformed approved device authorization record")

                user_snapshot = db.collection("Users").document(uid).get(transaction=transaction)
                role_snapshot = db.collection("UserRoles").document(uid).get(transaction=transaction)
                if not _product_access(user_snapshot, role_snapshot):
                    return DeviceAuthResult("unprovisioned")
                if _as_utc(now()) >= expires_at:
                    return DeviceAuthResult("expired")
                transaction.update(
                    request_ref,
                    {"state": "consumed", "consumedAt": _server_timestamp()},
                )
                return DeviceAuthResult("claimed", uid=uid)

            return self._run_transaction(db, consume)
        except DeviceAuthUnavailableError:
            raise
        except Exception:
            raise DeviceAuthUnavailableError() from None

    def _db(self):
        if self._injected_db is not None:
            return self._injected_db
        from firebase_admin import firestore

        from .firebase import _firebase_app

        _firebase_app(self._settings)
        return firestore.client()

    @staticmethod
    def _run_transaction(db, operation: Callable[[Any], DeviceAuthResult]) -> DeviceAuthResult:
        from google.api_core.exceptions import Aborted
        from google.cloud.firestore_v1 import transactional

        @transactional
        def execute(transaction):
            return operation(transaction)

        for attempt in range(3):
            try:
                return execute(db.transaction())
            except Exception as exc:
                if attempt == 2 or not _has_aborted_cause(exc, Aborted):
                    raise
        raise DeviceAuthUnavailableError()


class FirebaseDeviceAuthAdmin:
    def __init__(self, settings: Settings):
        self._settings = settings

    def check_user_enabled(self, uid: str) -> bool:
        from firebase_admin import auth

        from .firebase import _firebase_app

        app = _firebase_app(self._settings)
        try:
            user = auth.get_user(uid, app=app)
        except auth.UserNotFoundError:
            return False
        return not user.disabled

    def create_custom_token(self, uid: str) -> str:
        from firebase_admin import auth

        from .firebase import _firebase_app

        token = auth.create_custom_token(uid, app=_firebase_app(self._settings))
        if isinstance(token, bytes):
            return token.decode("ascii")
        return token


def _active_attempts(snapshot, now: datetime, *, scope: str) -> list[datetime]:
    if not snapshot.exists:
        return []
    data = snapshot.to_dict() or {}
    if data.get("scope") != scope:
        raise ValueError("Malformed device authorization limit")
    _required_datetime(data.get("expiresAt"))
    raw_attempts = data.get("attempts")
    if not isinstance(raw_attempts, list):
        raise ValueError("Malformed device authorization limit")
    cutoff = now - DEVICE_AUTH_LIMIT_WINDOW
    attempts = [_as_utc(value) for value in raw_attempts if isinstance(value, datetime)]
    if len(attempts) != len(raw_attempts):
        raise ValueError("Malformed device authorization limit")
    return sorted(value for value in attempts if value > cutoff)


def _throttled(attempts: list[datetime], now: datetime) -> DeviceAuthResult:
    oldest = attempts[0]
    retry_after = _retry_after(oldest + DEVICE_AUTH_LIMIT_WINDOW, now)
    return DeviceAuthResult("throttled", retry_after=retry_after)


def _retry_after(ready_at: datetime, now: datetime) -> int:
    return max(1, math.ceil((ready_at - now).total_seconds()))


def _uid_digest(uid: str) -> str:
    import hashlib

    return hashlib.sha256(uid.encode("utf-8")).hexdigest()


def _constant_hash_matches(stored: object, supplied: str) -> bool:
    return isinstance(stored, str) and _HASH_PATTERN.fullmatch(stored) is not None and hmac.compare_digest(
        stored, supplied
    )


def _has_aborted_cause(exc: Exception, aborted_type: type[Exception]) -> bool:
    return isinstance(exc, aborted_type) or (
        type(exc) is ValueError and isinstance(exc.__cause__, aborted_type)
    )


def _product_access(user_snapshot, role_snapshot) -> bool:
    if not user_snapshot.exists or not role_snapshot.exists:
        return False
    user_data = user_snapshot.to_dict() or {}
    role_data = role_snapshot.to_dict() or {}
    disabled = user_data.get("disabled", False)
    role = role_data.get("roleId") or role_data.get("role")
    return role in {"user", "admin"} and disabled is False


def _request_state(data: dict[str, Any]) -> str:
    state = data.get("state")
    if state not in _STATE_VALUES:
        raise ValueError("Malformed device authorization record")
    return state


def _required_datetime(value: object) -> datetime:
    if not isinstance(value, datetime):
        raise ValueError("Malformed device authorization timestamp")
    return _as_utc(value)


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _server_timestamp():
    from google.cloud.firestore_v1 import SERVER_TIMESTAMP

    return SERVER_TIMESTAMP

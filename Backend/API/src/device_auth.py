import base64
import binascii
import hashlib
import ipaddress
import re
import secrets
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Literal, Protocol, TypeAlias
from urllib.parse import quote, urlsplit

from .auth import AuthenticatedUser
from .errors import (
    DeviceAuthConflictError,
    DeviceAuthConsumedError,
    DeviceAuthDeniedError,
    DeviceAuthExpiredError,
    DeviceAuthInvalidError,
    DeviceAuthThrottledError,
    DeviceAuthUnavailableError,
    UserNotProvisionedError,
)
from .repository import FirebaseRepository
from .settings import Settings

DEVICE_AUTH_LIFETIME = timedelta(seconds=300)
DEVICE_AUTH_POLL_INTERVAL = 5
DEVICE_AUTH_LIMIT_WINDOW = timedelta(seconds=300)
DEVICE_AUTH_SOURCE_LIMIT = 5
DEVICE_AUTH_GUESS_LIMIT = 3
_DEVICE_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
_SECRET_HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_DEVICE_SECRET_PATTERN = re.compile(r"^[A-Za-z0-9_-]{43}$")
DeviceAuthOutcome: TypeAlias = Literal[
    "created",
    "collision",
    "verified",
    "approved",
    "denied",
    "pending",
    "claimed",
    "invalid",
    "expired",
    "denied_state",
    "consumed",
    "conflict",
    "throttled",
    "unavailable",
    "unprovisioned",
]


@dataclass(frozen=True)
class DeviceAuthResult:
    outcome: DeviceAuthOutcome
    state: str | None = None
    device_name: str | None = None
    expires_at: datetime | None = None
    uid: str | None = None
    retry_after: int | None = None


class DeviceAuthStore(Protocol):
    def create_request(
        self,
        *,
        device_request_id: str,
        user_code_hash: str,
        device_secret_hash: str,
        device_name: str | None,
        source_digest: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult: ...

    def verify_request(
        self,
        *,
        uid: str,
        device_request_id: str,
        user_code_hash: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult: ...

    def decide_request(
        self,
        *,
        uid: str,
        device_request_id: str,
        user_code_hash: str,
        decision: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult: ...

    def poll_request(
        self,
        *,
        device_request_id: str,
        device_secret_hash: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult: ...

    def consume_approved_request(
        self,
        *,
        device_request_id: str,
        device_secret_hash: str,
        now: Callable[[], datetime],
    ) -> DeviceAuthResult: ...


class DeviceAuthTokenIssuer(Protocol):
    def create_custom_token(self, uid: str) -> str: ...


class DeviceAuthUserChecker(Protocol):
    def check_user_enabled(self, uid: str) -> bool: ...


class DeviceAuthService:
    def __init__(
        self,
        *,
        settings: Settings,
        repository: FirebaseRepository,
        store: DeviceAuthStore,
        token_issuer: DeviceAuthTokenIssuer,
        user_checker: DeviceAuthUserChecker,
        clock: Callable[[], datetime] | None = None,
        random_bytes: Callable[[int], bytes] | None = None,
    ):
        self._settings = settings
        self._repository = repository
        self._store = store
        self._token_issuer = token_issuer
        self._user_checker = user_checker
        self._clock = clock or (lambda: datetime.now(timezone.utc))
        self._random_bytes = random_bytes or secrets.token_bytes

    def create(self, *, device_secret_hash: str, device_name: str | None, source_ip: str) -> dict[str, object]:
        if not _SECRET_HASH_PATTERN.fullmatch(device_secret_hash):
            raise DeviceAuthInvalidError()
        origin = self._dashboard_origin()
        source_digest = hashlib.sha256(source_ip.encode("ascii")).hexdigest()
        clean_name = sanitize_device_name(device_name)
        user_code = _new_user_code(self._random_bytes)
        user_code_hash = hashlib.sha256(user_code.encode("ascii")).hexdigest()
        result = None
        device_request_id = ""
        for _ in range(8):
            device_request_id = self._random_bytes(16).hex()
            try:
                result = self._store.create_request(
                    device_request_id=device_request_id,
                    user_code_hash=user_code_hash,
                    device_secret_hash=device_secret_hash,
                    device_name=clean_name,
                    source_digest=source_digest,
                    now=self._now,
                )
            except Exception:
                raise DeviceAuthUnavailableError() from None
            if result.outcome != "collision":
                break
        if result is None or result.outcome == "collision":
            raise DeviceAuthUnavailableError()
        self._raise_for_outcome(result)
        verification_uri = f"{origin}/#/auth/code"
        verification_uri_complete = (
            f"{verification_uri}?deviceRequestId={quote(device_request_id, safe='')}&userCode={quote(user_code, safe='')}"
        )
        return {
            "deviceRequestId": device_request_id,
            "userCode": user_code,
            "verificationUri": verification_uri,
            "verificationUriComplete": verification_uri_complete,
            "expiresIn": int(DEVICE_AUTH_LIFETIME.total_seconds()),
            "interval": DEVICE_AUTH_POLL_INTERVAL,
        }

    def verify(self, *, user: AuthenticatedUser, device_request_id: str, user_code: str) -> DeviceAuthResult:
        _validate_device_request_id(device_request_id)
        self._require_browser_access(user.uid)
        try:
            result = self._store.verify_request(
                uid=user.uid,
                device_request_id=device_request_id,
                user_code_hash=_hash_code(user_code),
                now=self._now,
            )
        except Exception:
            raise DeviceAuthUnavailableError() from None
        if result.outcome == "unprovisioned":
            raise UserNotProvisionedError()
        self._raise_for_outcome(result)
        return result

    def decide(
        self,
        *,
        user: AuthenticatedUser,
        device_request_id: str,
        user_code: str,
        decision: str,
    ) -> DeviceAuthResult:
        _validate_device_request_id(device_request_id)
        self._require_browser_access(user.uid)
        try:
            result = self._store.decide_request(
                uid=user.uid,
                device_request_id=device_request_id,
                user_code_hash=_hash_code(user_code),
                decision=decision,
                now=self._now,
            )
        except Exception:
            raise DeviceAuthUnavailableError() from None
        if result.outcome == "unprovisioned":
            raise UserNotProvisionedError()
        self._raise_for_outcome(result)
        return result

    def exchange(self, *, device_request_id: str, device_secret: str) -> DeviceAuthResult | str:
        _validate_device_request_id(device_request_id)
        secret_bytes = _decode_device_secret(device_secret)
        device_secret_hash = hashlib.sha256(secret_bytes).hexdigest()
        try:
            result = self._store.poll_request(
                device_request_id=device_request_id,
                device_secret_hash=device_secret_hash,
                now=self._now,
            )
        except Exception:
            raise DeviceAuthUnavailableError() from None
        self._raise_for_outcome(result)
        if result.outcome == "pending":
            return result
        if result.outcome != "approved" or result.uid is None:
            raise DeviceAuthUnavailableError()

        if not self._is_enabled_auth_user(result.uid):
            raise DeviceAuthDeniedError()
        try:
            claimed = self._store.consume_approved_request(
                device_request_id=device_request_id,
                device_secret_hash=device_secret_hash,
                now=self._now,
            )
        except Exception:
            raise DeviceAuthUnavailableError() from None
        if claimed.outcome == "unprovisioned":
            raise DeviceAuthDeniedError()
        self._raise_for_outcome(claimed)
        if claimed.outcome != "claimed" or claimed.uid is None:
            raise DeviceAuthUnavailableError()
        try:
            custom_token = self._token_issuer.create_custom_token(claimed.uid)
        except Exception:
            raise DeviceAuthUnavailableError() from None
        if not custom_token:
            raise DeviceAuthUnavailableError()
        return custom_token

    def _require_browser_access(self, uid: str) -> None:
        try:
            user_doc = self._repository.get_user(uid)
            role = self._repository.get_role(uid)
            auth_enabled = self._user_checker.check_user_enabled(uid)
        except Exception:
            raise DeviceAuthUnavailableError() from None
        if user_doc is None or user_doc.disabled or role is None or not auth_enabled:
            raise UserNotProvisionedError()

    def _is_enabled_auth_user(self, uid: str) -> bool:
        try:
            return self._user_checker.check_user_enabled(uid)
        except Exception:
            raise DeviceAuthUnavailableError() from None

    def _raise_for_outcome(self, result: DeviceAuthResult) -> None:
        if result.outcome in {"created", "verified", "approved", "denied", "pending", "claimed"}:
            return
        if result.outcome == "invalid":
            raise DeviceAuthInvalidError()
        if result.outcome == "expired":
            raise DeviceAuthExpiredError()
        if result.outcome == "denied_state":
            raise DeviceAuthDeniedError()
        if result.outcome == "consumed":
            raise DeviceAuthConsumedError()
        if result.outcome == "conflict":
            raise DeviceAuthConflictError()
        if result.outcome == "throttled":
            raise DeviceAuthThrottledError(result.retry_after or 1)
        if result.outcome == "unavailable":
            raise DeviceAuthUnavailableError()
        if result.outcome != "collision":
            raise DeviceAuthUnavailableError()

    def _dashboard_origin(self) -> str:
        parsed = urlsplit(self._settings.dashboard_cors_origin.strip())
        if (
            parsed.scheme not in {"https", "http"}
            or not parsed.netloc
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
        ):
            raise DeviceAuthUnavailableError()
        return f"{parsed.scheme}://{parsed.netloc}"

    def _now(self) -> datetime:
        value = self._clock()
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)


def _validate_device_request_id(value: str) -> None:
    if not _DEVICE_ID_PATTERN.fullmatch(value):
        raise DeviceAuthInvalidError()


def _hash_code(user_code: str) -> str:
    if not re.fullmatch(r"[0-9]{6}", user_code):
        raise DeviceAuthInvalidError()
    return hashlib.sha256(user_code.encode("ascii")).hexdigest()


def _decode_device_secret(value: str) -> bytes:
    if not _DEVICE_SECRET_PATTERN.fullmatch(value):
        raise DeviceAuthInvalidError()
    try:
        secret = base64.b64decode(value + "=", altchars=b"-_", validate=True)
    except (ValueError, binascii.Error):
        raise DeviceAuthInvalidError() from None
    if len(secret) != 32 or base64.urlsafe_b64encode(secret).rstrip(b"=").decode("ascii") != value:
        raise DeviceAuthInvalidError()
    return secret


def _new_user_code(random_bytes: Callable[[int], bytes]) -> str:
    # Three bytes provide a 24-bit sample; rejecting the top 777,216 values
    # makes every six-digit code equally likely.
    bound = (1 << 24) // 1_000_000 * 1_000_000
    for _ in range(32):
        sample = random_bytes(3)
        if len(sample) != 3:
            raise DeviceAuthUnavailableError()
        value = int.from_bytes(sample, "big")
        if value < bound:
            return f"{value % 1_000_000:06d}"
    raise DeviceAuthUnavailableError()


def sanitize_device_name(value: str | None) -> str | None:
    if value is None:
        return None
    clean = "".join(character for character in value if unicodedata.category(character) != "Cc").strip()
    if len(clean) > 80:
        raise DeviceAuthInvalidError()
    return clean or None


def trusted_source_ip(*, peer_host: str | None, custom_header: str | None) -> str:
    if not peer_host:
        raise DeviceAuthUnavailableError()
    try:
        if "%" in peer_host:
            raise ValueError("Invalid peer address")
        peer = ipaddress.ip_address(peer_host)
    except ValueError:
        raise DeviceAuthUnavailableError() from None
    if peer.is_loopback:
        if custom_header is None:
            return peer.compressed
        candidate = custom_header.strip()
        if not candidate or "," in candidate or "%" in candidate:
            raise DeviceAuthUnavailableError()
        try:
            return ipaddress.ip_address(candidate).compressed
        except ValueError:
            raise DeviceAuthUnavailableError() from None
    return peer.compressed

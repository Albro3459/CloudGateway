import logging
import time
import uuid
from collections.abc import Callable
from datetime import datetime

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import TokenVerifier
from .device_auth import (
    DeviceAuthService,
    DeviceAuthStore,
    DeviceAuthTokenIssuer,
    DeviceAuthUserChecker,
)
from .enums import ErrorCode, Event
from .errors import ApiError, DeviceAuthError, DeviceAuthInvalidError, DeviceAuthUnavailableError
from .logs import log_event, setup_logging
from .models import ErrorDetail, ErrorResponse
from .policy import LocalPolicyManager, PolicyManager
from .policy_sync import PolicyCoordinator
from .repository import FirebaseRepository
from .routes import router
from .settings import Settings
from .wireguard import LocalWireGuardManager, WireGuardManager

logger = logging.getLogger("src.app")


def request_id_of(request: Request) -> str:
    return getattr(request.state, "request_id", "") or str(uuid.uuid4())


def _error_response(
    request: Request,
    code: ErrorCode,
    message: str,
    status: int,
    *,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    body = ErrorResponse(error=ErrorDetail(code=code, message=message, request_id=request_id_of(request)))
    response_headers = dict(headers or {})
    if request.url.path == "/device" or request.url.path.startswith("/device/"):
        response_headers["Cache-Control"] = "no-store"
    return JSONResponse(status_code=status, content=body.model_dump(by_alias=True), headers=response_headers)


def create_app(
    *,
    settings: Settings | None = None,
    token_verifier: TokenVerifier | None = None,
    repository: FirebaseRepository | None = None,
    wireguard: WireGuardManager | None = None,
    policy: PolicyManager | None = None,
    device_auth_store: DeviceAuthStore | None = None,
    device_auth_token_issuer: DeviceAuthTokenIssuer | None = None,
    device_auth_user_checker: DeviceAuthUserChecker | None = None,
    device_auth_clock: Callable[[], datetime] | None = None,
    device_auth_random_bytes: Callable[[int], bytes] | None = None,
) -> FastAPI:
    setup_logging()
    settings = settings or Settings()

    app = FastAPI(title="CloudGateway Regional API", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings

    if token_verifier is None or repository is None:
        from .firebase import FirebaseTokenVerifier, FirestoreRepository

        token_verifier = token_verifier or FirebaseTokenVerifier(settings)
        repository = repository or FirestoreRepository(settings)
    app.state.token_verifier = token_verifier
    app.state.repository = repository
    from .device_auth_firebase import FirebaseDeviceAuthAdmin, FirestoreDeviceAuthStore

    device_auth_admin = FirebaseDeviceAuthAdmin(settings)
    app.state.device_auth_service = DeviceAuthService(
        settings=settings,
        repository=repository,
        store=device_auth_store or FirestoreDeviceAuthStore(settings),
        token_issuer=device_auth_token_issuer or device_auth_admin,
        user_checker=device_auth_user_checker or device_auth_admin,
        clock=device_auth_clock,
        random_bytes=device_auth_random_bytes,
    )
    app.state.wireguard = wireguard or LocalWireGuardManager(
        interface=settings.wg_interface,
        server_public_key=settings.wg_server_public_key,
        endpoint_host=settings.wg_endpoint_hostname,
        listen_port=settings.wg_port,
        dns_ipv4=settings.wg_dns_ipv4,
        dns_ipv6=settings.wg_dns_ipv6,
        tunnel_network_v4=settings.wg_tunnel_ipv4_cidr,
        tunnel_network_v6=settings.wg_tunnel_ipv6_cidr,
    )
    app.state.policy = policy or LocalPolicyManager()
    # A separate lock from wireguard.lock() (see policy.py): a policy refresh
    # must never contend with add_peer on the client create path or make an
    # admin's non-blocking Sync All shed with SyncInProgressError.
    app.state.policy_coordinator = PolicyCoordinator(
        repository=repository, policy=app.state.policy, settings=settings
    )

    @app.middleware("http")
    async def request_context(request: Request, call_next):
        request.state.request_id = str(uuid.uuid4())
        started = time.monotonic()
        log_event(
            logger,
            Event.REQUEST_RECEIVED,
            request_id=request.state.request_id,
            region_id=settings.region_id,
            method=request.method,
            path=request.url.path,
        )
        try:
            response = await call_next(request)
        except Exception:
            duration_ms = round((time.monotonic() - started) * 1000, 2)
            log_event(
                logger,
                Event.REQUEST_FAILED,
                level=logging.ERROR,
                request_id=request.state.request_id,
                region_id=settings.region_id,
                method=request.method,
                path=request.url.path,
                duration_ms=duration_ms,
            )
            raise
        if request.url.path == "/device" or request.url.path.startswith("/device/"):
            response.headers["Cache-Control"] = "no-store"
        duration_ms = round((time.monotonic() - started) * 1000, 2)
        log_event(
            logger,
            Event.REQUEST_COMPLETED,
            request_id=request.state.request_id,
            region_id=settings.region_id,
            method=request.method,
            path=request.url.path,
            status=response.status_code,
            duration_ms=duration_ms,
        )
        response.headers["X-Request-Id"] = request.state.request_id
        return response

    @app.exception_handler(ApiError)
    async def api_error_handler(request: Request, exc: ApiError):
        log_event(
            logger,
            Event.REQUEST_FAILED,
            level=logging.WARNING,
            request_id=request_id_of(request),
            region_id=settings.region_id,
            method=request.method,
            path=request.url.path,
            error_code=exc.code.value,
        )
        headers = {}
        if isinstance(exc, DeviceAuthError) and exc.retry_after is not None:
            headers["Retry-After"] = str(exc.retry_after)
        return _error_response(request, exc.code, exc.message, exc.http_status, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(request: Request, exc: RequestValidationError):
        log_event(
            logger,
            Event.REQUEST_FAILED,
            level=logging.WARNING,
            request_id=request_id_of(request),
            region_id=settings.region_id,
            method=request.method,
            path=request.url.path,
            error_code=(
                ErrorCode.DEVICE_AUTH_INVALID
                if request.url.path == "/device" or request.url.path.startswith("/device/")
                else ErrorCode.INVALID_REQUEST
            ).value,
        )
        if request.url.path == "/device" or request.url.path.startswith("/device/"):
            device_error = DeviceAuthInvalidError()
            return _error_response(
                request,
                device_error.code,
                device_error.message,
                device_error.http_status,
            )
        return _error_response(request, ErrorCode.INVALID_REQUEST, "Invalid request body.", 400)

    @app.exception_handler(Exception)
    async def unexpected_error_handler(request: Request, exc: Exception):
        is_device_path = request.url.path == "/device" or request.url.path.startswith("/device/")
        log_event(
            logger,
            Event.REQUEST_FAILED,
            level=logging.ERROR,
            request_id=request_id_of(request),
            region_id=settings.region_id,
            method=request.method,
            path=request.url.path,
            error_code=(ErrorCode.DEVICE_AUTH_UNAVAILABLE if is_device_path else ErrorCode.INTERNAL_ERROR).value,
            **({} if is_device_path else {"exc_info": (type(exc), exc, exc.__traceback__)}),
        )
        if is_device_path:
            error = DeviceAuthUnavailableError()
            return _error_response(request, error.code, error.message, error.http_status)
        return _error_response(request, ErrorCode.INTERNAL_ERROR, "Unexpected error.", 500)

    app.include_router(router)
    return app

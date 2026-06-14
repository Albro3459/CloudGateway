import logging
import time
import uuid

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import TokenVerifier
from .enums import ErrorCode, Event
from .errors import ApiError
from .logs import log_event, setup_logging
from .models import ErrorDetail, ErrorResponse
from .repository import FirebaseRepository
from .routes import router
from .settings import Settings
from .wireguard import LocalWireGuardManager, WireGuardManager

logger = logging.getLogger("src.app")


def request_id_of(request: Request) -> str:
    return getattr(request.state, "request_id", "") or str(uuid.uuid4())


def _error_response(request: Request, code: ErrorCode, message: str, status: int) -> JSONResponse:
    body = ErrorResponse(error=ErrorDetail(code=code, message=message, request_id=request_id_of(request)))
    return JSONResponse(status_code=status, content=body.model_dump(by_alias=True))


def create_app(
    *,
    settings: Settings | None = None,
    token_verifier: TokenVerifier | None = None,
    repository: FirebaseRepository | None = None,
    wireguard: WireGuardManager | None = None,
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
    app.state.wireguard = wireguard or LocalWireGuardManager(
        interface=settings.wg_interface,
        server_public_key=settings.wg_server_public_key,
        endpoint_host=settings.wg_endpoint_hostname,
        listen_port=settings.wg_port,
        dns_ipv4=settings.wg_dns_ipv4,
        dns_ipv6=settings.wg_dns_ipv6,
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
        return _error_response(request, exc.code, exc.message, exc.http_status)

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
            error_code=ErrorCode.INVALID_REQUEST.value,
        )
        return _error_response(request, ErrorCode.INVALID_REQUEST, "Invalid request body.", 400)

    @app.exception_handler(Exception)
    async def unexpected_error_handler(request: Request, exc: Exception):
        log_event(
            logger,
            Event.REQUEST_FAILED,
            level=logging.ERROR,
            request_id=request_id_of(request),
            region_id=settings.region_id,
            method=request.method,
            path=request.url.path,
            error_code=ErrorCode.INTERNAL_ERROR.value,
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        return _error_response(request, ErrorCode.INTERNAL_ERROR, "Unexpected error.", 500)

    app.include_router(router)
    return app

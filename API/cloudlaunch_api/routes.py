import logging
from collections.abc import Callable
from typing import Annotated, TypeVar

from fastapi import APIRouter, Depends, Path, Request

from .auth import AuthenticatedUser, require_admin_user, require_provisioned_user
from .enums import ClientStatus, ErrorCode, Event, OperationResult, Role
from .errors import (
    ApiError,
    ClientNotFoundError,
    FirebaseWriteFailedError,
    InternalError,
    WireGuardApplyFailedError,
)
from .logs import log_event
from .models import (
    CreateClientRequest,
    CreateClientResponse,
    CreateUserRequest,
    CreateUserResponse,
    DeleteClientRequest,
    DeleteClientResponse,
    HealthResponse,
)
from .repository import ClientDoc, ensure_delete_allowed, ensure_local_region
from .wireguard import WireGuardManager

logger = logging.getLogger("cloudlaunch_api.routes")
router = APIRouter()
T = TypeVar("T")


@router.get("/health", response_model=HealthResponse)
async def health(request: Request) -> HealthResponse:
    return HealthResponse(region_id=request.app.state.settings.region_id)


@router.post("/clients", response_model=CreateClientResponse)
async def create_client(
    request: Request,
    body: CreateClientRequest,
    user: AuthenticatedUser = Depends(require_provisioned_user),
) -> CreateClientResponse:
    repository = request.app.state.repository
    wireguard: WireGuardManager = request.app.state.wireguard
    request_id = request.state.request_id
    reserved_client: ClientDoc | None = None

    log_event(
        logger,
        Event.CLIENT_CREATE_STARTED,
        request_id=request_id,
        user_id=user.uid,
        user_email=user.email,
        user_display_name=user.display_name,
        client_name=body.client_name,
        region_id=body.region_id,
    )
    try:
        reserved_client = repository.reserve_client(
            owner_uid=user.uid,
            owner_email=user.email,
            owner_display_name=user.display_name,
            region_id=body.region_id,
            client_name=body.client_name,
        )
        assert reserved_client is not None
        keypair = wireguard.generate_keypair()
        wireguard_config = wireguard.render_client_config(
            private_key=keypair.private_key,
            tunnel_ipv4=reserved_client.assigned_tunnel_ipv4,
            tunnel_ipv6=reserved_client.assigned_tunnel_ipv6,
        )
    except WireGuardApplyFailedError as exc:
        if reserved_client is not None:
            _mark_reserved_client_failed(
                repository,
                client=reserved_client,
                error_code=ErrorCode.WIREGUARD_APPLY_FAILED,
                error_message=exc.message,
                request_id=request_id,
            )
        log_event(
            logger,
            Event.CLIENT_CREATE_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            user_id=user.uid,
            region_id=body.region_id,
            client_id=reserved_client.client_id if reserved_client else None,
            error_code=ErrorCode.WIREGUARD_APPLY_FAILED.value,
        )
        raise
    except ApiError:
        log_event(
            logger,
            Event.CLIENT_CREATE_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            user_id=user.uid,
            region_id=body.region_id,
            client_id=reserved_client.client_id if reserved_client else None,
        )
        raise

    assert reserved_client is not None
    # The lock spans peer apply plus the final Firebase write so a concurrent
    # peer sync never observes a creating doc with a live peer.
    with wireguard.lock():
        try:
            _run_wireguard_operation(
                lambda: wireguard.add_peer(
                    public_key=keypair.public_key,
                    tunnel_ipv4=reserved_client.assigned_tunnel_ipv4,
                    tunnel_ipv6=reserved_client.assigned_tunnel_ipv6,
                ),
                request_id=request_id,
                client_id=reserved_client.client_id,
                region_id=reserved_client.region_id,
                operation="add_peer",
            )
        except WireGuardApplyFailedError as exc:
            _mark_reserved_client_failed(
                repository,
                client=reserved_client,
                error_code=ErrorCode.WIREGUARD_APPLY_FAILED,
                error_message=exc.message,
                request_id=request_id,
            )
            log_event(
                logger,
                Event.CLIENT_CREATE_FAILED,
                level=logging.WARNING,
                request_id=request_id,
                user_id=user.uid,
                region_id=body.region_id,
                client_id=reserved_client.client_id,
                error_code=ErrorCode.WIREGUARD_APPLY_FAILED.value,
            )
            raise

        try:
            active_client = repository.mark_client_active(
                owner_uid=user.uid,
                region_id=reserved_client.region_id,
                client_id=reserved_client.client_id,
                client_public_key=keypair.public_key,
                wireguard_config=wireguard_config,
            )
        except Exception as exc:
            _cleanup_peer_after_create_failure(
                wireguard,
                client=reserved_client,
                public_key=keypair.public_key,
                request_id=request_id,
            )
            _remove_reserved_client_after_create_failure(
                repository,
                client=reserved_client,
                error_code=ErrorCode.FIREBASE_WRITE_FAILED,
                error_message="Failed to write to Firebase.",
                request_id=request_id,
            )
            log_event(
                logger,
                Event.CLIENT_CREATE_FAILED,
                level=logging.ERROR,
                request_id=request_id,
                user_id=user.uid,
                region_id=reserved_client.region_id,
                client_id=reserved_client.client_id,
                error_code=getattr(exc, "code", ErrorCode.FIREBASE_WRITE_FAILED).value,
            )
            if isinstance(exc, ApiError):
                raise
            raise FirebaseWriteFailedError() from exc

    log_event(
        logger,
        Event.CLIENT_CREATE_COMPLETED,
        request_id=request_id,
        user_id=user.uid,
        region_id=active_client.region_id,
        client_id=active_client.client_id,
        status=active_client.status.value,
    )
    return _create_client_response(active_client)


@router.delete("/clients/{clientId}", response_model=DeleteClientResponse)
async def delete_client(
    client_id: Annotated[str, Path(alias="clientId")],
    request: Request,
    body: DeleteClientRequest,
    user: AuthenticatedUser = Depends(require_provisioned_user),
) -> DeleteClientResponse:
    repository = request.app.state.repository
    wireguard: WireGuardManager = request.app.state.wireguard
    request_id = request.state.request_id

    log_event(
        logger,
        Event.CLIENT_DELETE_STARTED,
        request_id=request_id,
        requester_uid=user.uid,
        requester_email=user.email,
        requester_display_name=user.display_name,
        target_uid=body.user_id,
        region_id=body.region_id,
        client_id=client_id,
    )
    try:
        ensure_local_region(body.region_id, request.app.state.settings.region_id)
        ensure_delete_allowed(
            requester_uid=user.uid,
            requester_role=repository.get_role(user.uid),
            target_uid=body.user_id,
        )
        client = repository.get_client(owner_uid=body.user_id, region_id=body.region_id, client_id=client_id)
        if client is None:
            raise ClientNotFoundError()
        _ensure_client_matches_request(
            client=client,
            owner_uid=body.user_id,
            region_id=body.region_id,
            client_id=client_id,
        )

        # The lock spans peer removal plus the Firebase write so a concurrent
        # peer sync never re-adds a peer whose doc is about to be removed.
        with wireguard.lock():
            if client.client_public_key:
                _run_wireguard_operation(
                    lambda: wireguard.remove_peer(public_key=client.client_public_key),
                    request_id=request_id,
                    client_id=client.client_id,
                    region_id=client.region_id,
                    operation="remove_peer",
                )
            removed_client = repository.delete_client(
                requester_uid=user.uid,
                target_uid=body.user_id,
                region_id=body.region_id,
                client_id=client_id,
            )
    except ApiError:
        log_event(
            logger,
            Event.CLIENT_DELETE_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            requester_uid=user.uid,
            target_uid=body.user_id,
            region_id=body.region_id,
            client_id=client_id,
        )
        raise
    except Exception as exc:
        log_event(
            logger,
            Event.CLIENT_DELETE_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            requester_uid=user.uid,
            target_uid=body.user_id,
            region_id=body.region_id,
            client_id=client_id,
            error_code=ErrorCode.FIREBASE_WRITE_FAILED.value,
        )
        raise FirebaseWriteFailedError() from exc

    log_event(
        logger,
        Event.CLIENT_DELETE_COMPLETED,
        request_id=request_id,
        requester_uid=user.uid,
        target_uid=body.user_id,
        region_id=removed_client.region_id,
        client_id=removed_client.client_id,
        status=removed_client.status.value,
    )
    return DeleteClientResponse(
        user_id=body.user_id,
        client_id=removed_client.client_id,
        region_id=removed_client.region_id,
        status=ClientStatus.REMOVED,
    )


@router.post("/users", response_model=CreateUserResponse)
async def create_user(
    request: Request,
    body: CreateUserRequest,
    admin_user: AuthenticatedUser = Depends(require_admin_user),
) -> CreateUserResponse:
    repository = request.app.state.repository
    request_id = request.state.request_id

    log_event(
        logger,
        Event.USER_CREATE_STARTED,
        request_id=request_id,
        admin_uid=admin_user.uid,
        email=body.email,
    )
    try:
        result = repository.create_user(
            email=body.email,
            display_name=body.display_name,
        )
    except ApiError:
        log_event(
            logger,
            Event.USER_CREATE_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            admin_uid=admin_user.uid,
            email=body.email,
        )
        raise
    except Exception as exc:
        log_event(
            logger,
            Event.USER_CREATE_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            admin_uid=admin_user.uid,
            email=body.email,
            error_code=ErrorCode.INTERNAL_ERROR.value,
        )
        raise InternalError() from exc

    return CreateUserResponse(
        user_id=result.user.uid,
        email=result.user.email,
        role=Role.USER,
        already_existed=result.already_existed,
    )


def _create_client_response(client: ClientDoc) -> CreateClientResponse:
    return CreateClientResponse(
        client_id=client.client_id,
        region_id=client.region_id,
        client_name=client.client_name,
        status=client.status,
        assigned_tunnel_ipv4=client.assigned_tunnel_ipv4,
        assigned_tunnel_ipv6=client.assigned_tunnel_ipv6,
        server_endpoint_ipv4=client.server_endpoint_ipv4,
        server_endpoint_hostname=client.server_endpoint_hostname,
        wireguard_config=client.wireguard_config or "",
    )


def _ensure_client_matches_request(*, client: ClientDoc, owner_uid: str, region_id: str, client_id: str) -> None:
    if client.owner_uid != owner_uid or client.region_id != region_id or client.client_id != client_id:
        raise ClientNotFoundError()

def _run_wireguard_operation(
    operation_call: Callable[[], T],
    *,
    request_id: str,
    client_id: str,
    region_id: str,
    operation: str,
) -> T:
    log_event(
        logger,
        Event.WIREGUARD_APPLY_STARTED,
        request_id=request_id,
        region_id=region_id,
        client_id=client_id,
        operation=operation,
        attempt=1,
    )
    try:
        result = operation_call()
    except WireGuardApplyFailedError as exc:
        if not exc.transient:
            log_event(
                logger,
                Event.WIREGUARD_APPLY_FAILED,
                level=logging.WARNING,
                request_id=request_id,
                region_id=region_id,
                client_id=client_id,
                operation=operation,
                attempt=1,
                transient=False,
            )
            raise
        log_event(
            logger,
            Event.WIREGUARD_APPLY_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            region_id=region_id,
            client_id=client_id,
            operation=operation,
            attempt=1,
            transient=True,
        )
        log_event(
            logger,
            Event.WIREGUARD_APPLY_STARTED,
            request_id=request_id,
            region_id=region_id,
            client_id=client_id,
            operation=operation,
            attempt=2,
        )
        try:
            result = operation_call()
        except WireGuardApplyFailedError:
            log_event(
                logger,
                Event.WIREGUARD_APPLY_FAILED,
                level=logging.WARNING,
                request_id=request_id,
                region_id=region_id,
                client_id=client_id,
                operation=operation,
                attempt=2,
            )
            raise
    log_event(
        logger,
        Event.WIREGUARD_APPLY_COMPLETED,
        request_id=request_id,
        region_id=region_id,
        client_id=client_id,
        operation=operation,
        result=result.value if isinstance(result, OperationResult) else OperationResult.SUCCESS.value,
    )
    return result


def _mark_reserved_client_failed(
    repository,
    *,
    client: ClientDoc,
    error_code: ErrorCode,
    error_message: str,
    request_id: str,
) -> None:
    try:
        repository.mark_client_failed(
            owner_uid=client.owner_uid,
            region_id=client.region_id,
            client_id=client.client_id,
            error_code=error_code.value,
            error_message=error_message,
        )
    except Exception:
        log_event(
            logger,
            Event.CLIENT_CREATE_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            region_id=client.region_id,
            client_id=client.client_id,
            error_code=ErrorCode.FIREBASE_WRITE_FAILED.value,
        )


def _cleanup_peer_after_create_failure(
    wireguard: WireGuardManager,
    *,
    client: ClientDoc,
    public_key: str,
    request_id: str,
) -> None:
    try:
        _run_wireguard_operation(
            lambda: wireguard.remove_peer(public_key=public_key),
            request_id=request_id,
            client_id=client.client_id,
            region_id=client.region_id,
            operation="cleanup_peer",
        )
    except WireGuardApplyFailedError:
        log_event(
            logger,
            Event.WIREGUARD_APPLY_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            region_id=client.region_id,
            client_id=client.client_id,
            operation="cleanup_peer",
        )


def _remove_reserved_client_after_create_failure(
    repository,
    *,
    client: ClientDoc,
    error_code: ErrorCode,
    error_message: str,
    request_id: str,
) -> None:
    try:
        repository.remove_client_reservation(
            owner_uid=client.owner_uid,
            region_id=client.region_id,
            client_id=client.client_id,
            error_code=error_code.value,
            error_message=error_message,
        )
    except Exception:
        log_event(
            logger,
            Event.CLIENT_CREATE_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            region_id=client.region_id,
            client_id=client.client_id,
            error_code=ErrorCode.FIREBASE_WRITE_FAILED.value,
        )

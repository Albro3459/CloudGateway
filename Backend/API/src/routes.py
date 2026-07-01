import logging
from collections.abc import Callable
from typing import Annotated, TypeVar

from fastapi import APIRouter, Depends, Path, Request

from .auth import AuthenticatedUser, get_current_user, require_admin_user, require_provisioned_user, require_role_or_disable_unprovisioned
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
    AccessCheckResponse,
    AdminSyncRequest,
    AdminSyncResponse,
    CapacityResponse,
    CreateClientRequest,
    CreateClientResponse,
    CreateUserRequest,
    CreateUserResponse,
    DeleteClientRequest,
    DeleteClientResponse,
    HealthResponse,
    RegionSummary,
    RegionsResponse,
)
from .notifications import create_ses_client, send_access_grant_email
from .repository import ClientDoc, ensure_delete_allowed, ensure_local_region, require_region, utc_now
from .sync import build_sync_audit_log, run_sync
from .wireguard import WireGuardManager

logger = logging.getLogger("src.routes")
router = APIRouter()
T = TypeVar("T")


@router.get("/health", response_model=HealthResponse)
def health(request: Request) -> HealthResponse:
    return HealthResponse(region_id=request.app.state.settings.region_id)


@router.get("/regions", response_model=RegionsResponse)
def list_regions(request: Request) -> RegionsResponse:
    return RegionsResponse(
        regions=[
            RegionSummary(
                region_id=region.region_id,
                display_name=region.display_name,
                display_order=region.display_order if region.display_order is not None else 1000,
            )
            for region in request.app.state.repository.list_enabled_regions()
        ]
    )


@router.post("/auth/check-access", response_model=AccessCheckResponse)
def check_access(
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> AccessCheckResponse:
    role = require_role_or_disable_unprovisioned(request, user)
    return AccessCheckResponse(
        user_id=user.uid,
        email=user.email,
        role=role,
    )


@router.get("/capacity", response_model=CapacityResponse)
def get_capacity(
    request: Request,
    user: AuthenticatedUser = Depends(require_provisioned_user),
) -> CapacityResponse:
    del user
    repository = request.app.state.repository
    region_id = request.app.state.settings.region_id
    region = require_region(repository.get_region(region_id))
    allocated_client_count = len(repository.list_allocated_clients(region_id))
    return CapacityResponse(
        region_id=region.region_id,
        capacity_limit=region.capacity_limit,
        allocated_client_count=allocated_client_count,
    )


@router.post("/clients", response_model=CreateClientResponse)
def create_client(
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
        client_name=body.client_name,
        region_id=body.region_id,
    )
    try:
        reserved_client = repository.reserve_client(
            owner_uid=user.uid,
            owner_email=user.email,
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
def delete_client(
    client_id: Annotated[str, Path(alias="clientId")],
    request: Request,
    body: DeleteClientRequest,
    user: AuthenticatedUser = Depends(require_provisioned_user),
) -> DeleteClientResponse:
    repository = request.app.state.repository
    wireguard: WireGuardManager = request.app.state.wireguard
    request_id = request.state.request_id
    firebase_removed = False

    log_event(
        logger,
        Event.CLIENT_DELETE_STARTED,
        request_id=request_id,
        requester_uid=user.uid,
        requester_email=user.email,
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

        # Remove the live peer before the Firebase terminal write so a failed
        # peer removal leaves the client ACTIVE in Firebase (retryable) instead
        # of removed with a still-live peer. The reverse window (peer gone, doc
        # still ACTIVE) is repaired by the next peer sync (at boot, or a manual
        # `cloudgateway-sync-peers`), which re-adds the peer from the ACTIVE doc;
        # there is no periodic sync. The lock spans both so peer sync cannot
        # interleave with the source-of-truth transition.
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
            firebase_removed = True
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
            firebase_removed=firebase_removed,
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
            firebase_removed=firebase_removed,
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
def create_user(
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
        result = repository.create_user(email=body.email)
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

    _notify_user_access_granted(
        request,
        email=result.user.email,
        request_id=request_id,
        user_id=result.user.uid,
    )

    return CreateUserResponse(
        user_id=result.user.uid,
        email=result.user.email,
        role=Role.USER,
        already_existed=result.already_existed,
    )


@router.post("/admin/sync", response_model=AdminSyncResponse)
def admin_sync(
    request: Request,
    body: AdminSyncRequest,
    admin_user: AuthenticatedUser = Depends(require_admin_user),
) -> AdminSyncResponse:
    repository = request.app.state.repository
    wireguard: WireGuardManager = request.app.state.wireguard
    settings = request.app.state.settings
    request_id = request.state.request_id

    # Defensive guard: the host only syncs its own region, so reject a request
    # routed to the wrong regional endpoint instead of silently syncing here.
    ensure_local_region(body.region_id, settings.region_id)

    log_event(
        logger,
        Event.PEER_SYNC_STARTED,
        request_id=request_id,
        admin_uid=admin_user.uid,
        region_id=settings.region_id,
    )
    try:
        result = run_sync(repository=repository, wireguard=wireguard, region_id=settings.region_id)
    except ApiError:
        log_event(
            logger,
            Event.PEER_SYNC_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            admin_uid=admin_user.uid,
            region_id=settings.region_id,
        )
        raise
    except Exception as exc:
        log_event(
            logger,
            Event.PEER_SYNC_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            admin_uid=admin_user.uid,
            region_id=settings.region_id,
            error_code=ErrorCode.INTERNAL_ERROR.value,
        )
        raise InternalError() from exc

    synced_at = utc_now()
    # Best-effort enrichment only: the reconcile above is consistent under the
    # lock, but this re-list runs unlocked, so a concurrent create/delete could
    # leave a peer without its join details in the audit log.
    changed_public_keys = {change.public_key for change in result.changes}
    clients_by_key = {
        client.client_public_key: client
        for client in repository.list_clients_by_public_key(settings.region_id, changed_public_keys)
        if client.client_public_key
    }
    audit_log = build_sync_audit_log(
        region_id=settings.region_id,
        synced_at=synced_at,
        result=result,
        clients_by_key=clients_by_key,
    )

    log_event(
        logger,
        Event.PEER_SYNC_COMPLETED,
        request_id=request_id,
        admin_uid=admin_user.uid,
        region_id=settings.region_id,
        added=result.added,
        updated=result.updated,
        removed=result.removed,
    )

    return AdminSyncResponse(
        region_id=settings.region_id,
        synced_at=synced_at,
        added=result.added,
        updated=result.updated,
        removed=result.removed,
        no_changes=not result.changes,
        log=audit_log,
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


def _notify_user_access_granted(
    request: Request,
    *,
    email: str,
    request_id: str,
    user_id: str,
) -> None:
    settings = request.app.state.settings
    try:
        ses_client = create_ses_client(settings)
        send_access_grant_email(
            ses_client,
            sender=settings.ses_sender,
            recipient=email,
            dashboard_origin=settings.dashboard_cors_origin,
        )
    except Exception as exc:
        log_event(
            logger,
            Event.USER_ACCESS_EMAIL_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            user_id=user_id,
            email=email,
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        return

    log_event(
        logger,
        Event.USER_ACCESS_EMAIL_COMPLETED,
        request_id=request_id,
        user_id=user_id,
        email=email,
    )


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

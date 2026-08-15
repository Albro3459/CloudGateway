import logging
import json
import re
from collections.abc import Callable
from datetime import timedelta
from typing import Annotated, TypeVar
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request as URLRequest
from urllib.request import urlopen

from fastapi import APIRouter, Depends, Path, Request

from .auth import AuthenticatedUser, bearer_token, get_current_user, require_admin_user, require_provisioned_user, require_role_or_disable_unprovisioned
from .enums import ClientStatus, ErrorCode, Event, MeshPeerStatus, OperationResult, Role
from .errors import (
    ApiError,
    AuthRequiredError,
    ClientNotFoundError,
    FirebaseWriteFailedError,
    InvalidRequestError,
    InternalError,
    WireGuardApplyFailedError,
)
from .logs import log_event
from .models import (
    AccessCheckResponse,
    AdminSyncMeshPeer,
    AdminSyncRequest,
    AdminSyncResponse,
    CapacityResponse,
    CreateClientRequest,
    CreateClientResponse,
    CreateUserRequest,
    CreateUserResponse,
    DeleteAccountResponse,
    DeleteClientRequest,
    DeleteClientResponse,
    HealthResponse,
    RegionSummary,
    RegionsResponse,
)
from .notifications import create_ses_client, send_access_grant_email
from .repository import ClientDoc, FirebaseRepository, ensure_delete_allowed, ensure_local_region, require_region, utc_now
from .sync import build_sync_audit_log, run_sync
from .wireguard import WireGuardManager

logger = logging.getLogger("src.routes")
router = APIRouter()
T = TypeVar("T")
RECENT_AUTH_WINDOW = timedelta(minutes=5)
# Cloudflare's Browser Integrity Check blocks the default urllib UA, so
# cross-region server-to-server calls must present a non-bot UA to reach origin.
REGIONAL_API_USER_AGENT = "CloudGateway-API/1.0"
# A region ID becomes the leftmost label of a regional API hostname, so it is
# constrained to the OCI region-id charset before any URL interpolation.
_REGION_ID_PATTERN = re.compile(r"^[a-z0-9-]+$")


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


@router.delete("/account", response_model=DeleteAccountResponse)
def delete_account(
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> DeleteAccountResponse:
    repository = request.app.state.repository
    wireguard: WireGuardManager = request.app.state.wireguard
    settings = request.app.state.settings
    request_id = request.state.request_id
    token = bearer_token(request)
    clients = []

    log_event(
        logger,
        Event.ACCOUNT_DELETE_STARTED,
        request_id=request_id,
        user_id=user.uid,
        user_email=user.email,
    )
    try:
        _ensure_recent_auth(user)
        _ensure_account_delete_allowed(repository, user.uid)

        # Ordering: snapshot the owner's clients, remove their WireGuard peers,
        # then hard-delete the account docs. We keep the UserRoles doc until the
        # hard delete (do not delete it first) so a retry of DELETE /account can
        # still authorize. There is an accepted, sub-second race: a user racing
        # their own deletion from a second device could orphan a single peer if
        # a client is created between the snapshot and the hard delete. We do
        # not fence it; cloudgateway-sync-peers reconciles any orphaned peer on
        # its next run. See the plan (Medium #4) for why role-first fencing is
        # rejected.
        clients = repository.list_clients_for_owner(user.uid)
        _remove_account_peers(
            clients=clients,
            user=user,
            token=token,
            local_region_id=settings.region_id,
            api_hostname=settings.api_hostname,
            wireguard=wireguard,
            request_id=request_id,
        )
        repository.hard_delete_account_documents(user.uid)
        repository.delete_auth_user(user.uid)
    except ApiError:
        log_event(
            logger,
            Event.ACCOUNT_DELETE_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            user_id=user.uid,
        )
        raise
    except Exception as exc:
        log_event(
            logger,
            Event.ACCOUNT_DELETE_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            user_id=user.uid,
            error_code=ErrorCode.INTERNAL_ERROR.value,
        )
        raise InternalError() from exc

    log_event(
        logger,
        Event.ACCOUNT_DELETE_COMPLETED,
        request_id=request_id,
        user_id=user.uid,
        deleted_client_count=len(clients),
    )
    return DeleteAccountResponse(
        user_id=user.uid,
        deleted_client_count=len(clients),
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


@router.post("/admin/sync", response_model=AdminSyncResponse, response_model_exclude_none=True)
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
        # blocking=False: an admin retry (or a concurrent Sync All) must not queue on
        # the flock and hold a thread-pool slot behind the running pass. The boot and
        # post-register passes still block, since they have no request to shed.
        outcome = run_sync(repository=repository, wireguard=wireguard, settings=settings, blocking=False)
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

    result = outcome.result
    synced_at = utc_now()
    # Best-effort enrichment only: the reconcile above is consistent under the
    # lock, but this re-list runs unlocked, so a concurrent create/delete could
    # leave a peer without its join details in the audit log.
    changed_public_keys = {change.public_key for change in result.changes}
    clients_by_key = {}
    try:
        clients_by_key = {
            client.client_public_key: client
            for client in repository.list_clients_by_public_key(settings.region_id, changed_public_keys)
            if client.client_public_key
        }
    except Exception as exc:
        log_event(
            logger,
            Event.PEER_SYNC_ENRICHMENT_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            admin_uid=admin_user.uid,
            region_id=settings.region_id,
            error_type=type(exc).__name__,
        )
    mesh_skipped = sum(1 for candidate in outcome.mesh_candidates if candidate.status != MeshPeerStatus.APPLIED)
    no_changes = (
        not result.changes
        and result.mesh_added == 0
        and result.mesh_updated == 0
        and result.mesh_removed == 0
        and result.routes_added == 0
        and result.routes_removed == 0
    )
    audit_log = build_sync_audit_log(
        region_id=settings.region_id,
        synced_at=synced_at,
        result=result,
        clients_by_key=clients_by_key,
        mesh_enabled=outcome.mesh_enabled,
        mesh_candidates=outcome.mesh_candidates,
        mesh_region_by_key=outcome.mesh_region_by_key,
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
        no_changes=no_changes,
        log=audit_log,
        mesh_enabled=outcome.mesh_enabled,
        mesh_applied=result.mesh_applied,
        mesh_added=result.mesh_added,
        mesh_updated=result.mesh_updated,
        mesh_removed=result.mesh_removed,
        mesh_skipped=mesh_skipped,
        mesh_routes_added=result.routes_added,
        mesh_routes_removed=result.routes_removed,
        mesh_peers=[
            AdminSyncMeshPeer(
                region_id=candidate.region_id,
                status=candidate.status,
                endpoint_hostname=candidate.endpoint_hostname or None,
                endpoint_port=candidate.endpoint_port,
                allowed_network_v4=candidate.allowed_network_v4 or None,
                allowed_network_v6=candidate.allowed_network_v6 or None,
                reason_code=candidate.reason_code,
            )
            for candidate in outcome.mesh_candidates
        ],
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


def _ensure_recent_auth(user: AuthenticatedUser) -> None:
    authenticated_at = user.authenticated_at
    now = utc_now()
    if authenticated_at is None or authenticated_at > now + timedelta(minutes=1) or now - authenticated_at > RECENT_AUTH_WINDOW:
        raise AuthRequiredError("Sign in again before deleting this account.")


def _ensure_account_delete_allowed(repository: FirebaseRepository, uid: str) -> None:
    role = repository.get_role(uid)
    if role == Role.USER:
        return
    if role is None and repository.get_user(uid) is None:
        return
    raise InvalidRequestError("Account deletion is not available for this account.")


def _remove_account_peers(
    *,
    clients: list[ClientDoc],
    user: AuthenticatedUser,
    token: str,
    local_region_id: str,
    api_hostname: str,
    wireguard: WireGuardManager,
    request_id: str,
) -> None:
    local_clients = [
        client for client in clients
        if client.region_id == local_region_id and client.client_public_key
    ]
    remote_clients = [
        client for client in clients
        if client.region_id != local_region_id and client.client_public_key
    ]

    if local_clients:
        with wireguard.lock():
            for client in local_clients:
                _run_wireguard_operation(
                    lambda client=client: wireguard.remove_peer(public_key=client.client_public_key),
                    request_id=request_id,
                    client_id=client.client_id,
                    region_id=client.region_id,
                    operation="remove_peer",
                )

    for client in remote_clients:
        try:
            _delete_remote_client(client=client, user=user, token=token, api_hostname=api_hostname)
        except WireGuardApplyFailedError as exc:
            if not exc.transient:
                # Region answered with a challenge/auth/HTTP error - do not assume
                # the peer is gone, so abort rather than silently lose it.
                raise
            # Region host unreachable: continue the deletion. The client doc is
            # hard-deleted next and cloudgateway-sync-peers reconciles the
            # orphaned peer when the host returns.
            log_event(
                logger,
                Event.ACCOUNT_DELETE_PEER_UNREACHABLE,
                level=logging.WARNING,
                request_id=request_id,
                user_id=user.uid,
                client_id=client.client_id,
                region_id=client.region_id,
            )


def _delete_remote_client(
    *,
    client: ClientDoc,
    user: AuthenticatedUser,
    token: str,
    api_hostname: str,
) -> None:
    url = _regional_api_url(client.region_id, f"clients/{quote(client.client_id, safe='')}", api_hostname)
    body = json.dumps({"userId": user.uid, "regionId": client.region_id}).encode("utf-8")
    regional_request = URLRequest(
        url,
        data=body,
        method="DELETE",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": REGIONAL_API_USER_AGENT,
        },
    )
    try:
        with urlopen(regional_request, timeout=10) as response:
            if response.status < 200 or response.status >= 300:
                raise WireGuardApplyFailedError("Failed to remove regional VPN configuration.")
    except HTTPError as exc:
        # The host answered with an HTTP status error (incl. a Cloudflare
        # challenge or an auth failure). Do not assume the peer is gone - abort.
        raise WireGuardApplyFailedError("Failed to remove regional VPN configuration.") from exc
    except (URLError, TimeoutError) as exc:
        # Host truly unreachable (DNS/connection failure or timeout). Marked
        # transient so the caller can continue the deletion; the orphaned peer is
        # reconciled by cloudgateway-sync-peers once the host returns.
        raise WireGuardApplyFailedError("Failed to reach regional VPN configuration service.", transient=True) from exc


def _regional_api_url(region_id: str, path: str, api_hostname: str) -> str:
    if not isinstance(region_id, str) or not _REGION_ID_PATTERN.fullmatch(region_id):
        # Never build a cross-region URL from an unconstrained value: a bad
        # Admin-SDK-side write could otherwise redirect this call at any host.
        # Non-transient, so the caller aborts instead of assuming the peer is gone.
        raise WireGuardApplyFailedError("Failed to remove regional VPN configuration.")
    origin_host = _origin_host(api_hostname)
    api_path = path.strip("/")
    return f"https://{region_id}.{origin_host}/api/{api_path}"


def _origin_host(api_hostname: str) -> str:
    hostname = api_hostname.strip().lower()
    if hostname.startswith("api."):
        return hostname.removeprefix("api.")
    if hostname.count(".") >= 2:
        return hostname.split(".", 1)[1]
    return "gocloudlaunch.com"


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

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

from fastapi import APIRouter, BackgroundTasks, Depends, Path, Request, Response

from .auth import AuthenticatedUser, bearer_token, get_current_user, require_admin_user, require_provisioned_user, require_role_or_disable_unprovisioned
from .enums import ClientStatus, ErrorCode, Event, MeshPeerStatus, OperationResult, Role
from .errors import (
    ApiError,
    AuthRequiredError,
    ClientNotFoundError,
    FirebaseWriteFailedError,
    InvalidRequestError,
    InternalError,
    SyncInProgressError,
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
from .policy import PolicyManager, PolicyRow
from .policy_sync import bare_tunnel_address
from .repository import (
    ClientDoc,
    FirebaseRepository,
    ensure_delete_allowed,
    ensure_local_region,
    require_region,
    utc_now,
    valid_account_slot,
)
from .sync import build_sync_audit_log, run_sync
from .wireguard import WireGuardManager

logger = logging.getLogger("src.routes")
router = APIRouter()
T = TypeVar("T")
RECENT_AUTH_WINDOW = timedelta(minutes=5)
# Cloudflare's Browser Integrity Check blocks the default urllib UA, so
# cross-region server-to-server calls must present a non-bot UA to reach origin.
REGIONAL_API_USER_AGENT = "CloudGateway-API/1.0"
# Fire-and-forget: the poke must never hold up the client's own request, and a
# dropped poke is explicitly accepted (see TODO/account-scoped-acl.md,
# "Accepted risks"), so the timeout stays short rather than matching the
# 10s used for a delete that the caller is actually waiting on.
POLICY_POKE_TIMEOUT_SECONDS = 5
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
    background_tasks: BackgroundTasks,
    user: AuthenticatedUser = Depends(require_provisioned_user),
) -> CreateClientResponse:
    repository = request.app.state.repository
    wireguard: WireGuardManager = request.app.state.wireguard
    policy: PolicyManager = request.app.state.policy
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

    # Inline local row: written after the WireGuard critical section closes,
    # not inside it - no Firestore read, no policy lock, and no nft call ever
    # runs while wireguard.lock() is held, so a slow policy pull or status
    # write can never stall add_peer or make a non-blocking Sync All shed.
    # Written here (rather than left entirely to the background reconcile) so
    # a client whose sibling is in the same region works immediately with no
    # cross-region dependency; a missing slot or an apply failure must never
    # fail the client create, since the next reconcile (poke or boot) repairs
    # it either way.
    _write_inline_policy_row(
        repository=repository,
        policy=policy,
        client=active_client,
        request_id=request_id,
    )

    log_event(
        logger,
        Event.CLIENT_CREATE_COMPLETED,
        request_id=request_id,
        user_id=user.uid,
        region_id=active_client.region_id,
        client_id=active_client.client_id,
        status=active_client.status.value,
    )
    # The inline row above is the fast path, not the repair path: it is
    # additive, so an apply failure (or a reconcile whose snapshot predates
    # this client's commit and flushes the row) would otherwise leave the
    # local map short until an unrelated fleet event. This pull starts after
    # the commit, so it always sees this client. Coalescing bounds the cost.
    background_tasks.add_task(request.app.state.policy_coordinator.request)
    background_tasks.add_task(
        _poke_other_regions,
        request,
        token=bearer_token(request),
        request_id=request_id,
    )
    return _create_client_response(active_client)


@router.delete("/clients/{clientId}", response_model=DeleteClientResponse)
def delete_client(
    client_id: Annotated[str, Path(alias="clientId")],
    request: Request,
    body: DeleteClientRequest,
    background_tasks: BackgroundTasks,
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
    # No inline removal exists (add_client_row is additive-only), so the local
    # map is corrected by a real reconcile rather than a single-row edit.
    background_tasks.add_task(request.app.state.policy_coordinator.request)
    background_tasks.add_task(
        _poke_other_regions,
        request,
        token=bearer_token(request),
        request_id=request_id,
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
        # Deliberately no policy poke here, unlike the client create/delete
        # paths. No ordering works: poking before this line refreshes peers to
        # the pre-delete state, and poking after it means UserRoles/{uid} is
        # already gone, so the remote rejects the call and
        # require_role_or_disable_unprovisioned tries to disable a user that
        # is being deleted. This is accepted (see TODO/account-scoped-acl.md,
        # "Account deletion"): _remove_account_peers above already removed
        # this account's WireGuard peers, so it cannot put a packet on the
        # tunnel regardless of a stale policy row, and any address it freed is
        # reclaimed by the next allocation, which itself pokes.
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


@router.post("/sync/refresh", status_code=202)
def refresh_policy(
    request: Request,
    background_tasks: BackgroundTasks,
    user: AuthenticatedUser = Depends(require_provisioned_user),
) -> Response:
    # Any provisioned user, not admin-only: no dedicated secret and no rate
    # limit, the caller's own Firebase token is replayed exactly as
    # _delete_remote_client does. Depth-1 coalescing bounds the *pending
    # backlog* to one queued follow-up pass; it does not bound the total
    # number of sequential refreshes a caller can trigger over time (see
    # TODO/account-scoped-acl.md, "API surface"). No body, no detail in the
    # response - never region health, counts, or error information - so
    # enqueue and return immediately.
    del user
    background_tasks.add_task(request.app.state.policy_coordinator.request)
    return Response(status_code=202)


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

    # Sync All is the repair path for a dropped poke, so it also reconciles the
    # account-scoped ACL map. Blocking (not enqueued) so the admin sees a fresh
    # Policy/{regionId} immediately after this call returns. A policy failure
    # is logged inside run_blocking and must never fail this endpoint - it
    # does not touch AdminSyncResponse at all.
    try:
        request.app.state.policy_coordinator.run_blocking()
    except Exception as exc:
        log_event(
            logger,
            Event.POLICY_REFRESH_FAILED,
            level=logging.ERROR,
            request_id=request_id,
            admin_uid=admin_user.uid,
            region_id=settings.region_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )

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
        degraded_client_peers=outcome.degraded_client_peers,
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
        mesh_status_written=outcome.mesh_status_written,
        client_peers_degraded=outcome.degraded_client_peers,
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


def _write_inline_policy_row(
    *,
    repository: FirebaseRepository,
    policy: PolicyManager,
    client: ClientDoc,
    request_id: str,
) -> None:
    """Called from create_client after the wireguard.lock() block has already
    closed - the client is ACTIVE with a live peer by this point, so nothing
    below may turn a successful create into a failed response.

    Slot lookup, role lookup, address normalization, policy-lock acquisition,
    and the row apply all run inside one exception boundary: a Firestore
    error, a missing/invalid slot, or an apply failure all fall through
    silently (beyond the log below).

    The policy lock is taken non-blocking: if a full reconcile pass currently
    owns it, this just skips the row rather than waiting. That is safe to
    shed because create_client queues policy_coordinator.request() immediately
    after this call, and the coordinator's depth-1 pending bit guarantees a
    follow-up pass whose *pull* starts only after this client's Firestore
    commit - so the row is picked up by that pass even if it never lands here.
    """
    try:
        slot = valid_account_slot(repository.get_account_slot(client.owner_uid))
        if slot is None:
            return
        address_v4 = bare_tunnel_address(client.assigned_tunnel_ipv4, 4)
        address_v6 = bare_tunnel_address(client.assigned_tunnel_ipv6, 6)
        if address_v4 is None or address_v6 is None:
            return
        admin = repository.get_role(client.owner_uid) == Role.ADMIN
        with policy.lock(blocking=False):
            policy.add_client_row(PolicyRow(address_v4=address_v4, address_v6=address_v6, slot=slot, admin=admin))
    except SyncInProgressError:
        # Expected under load, not a failure: a full pass already owns the
        # lock. Its own snapshot may predate this client's commit, so the
        # repair is the reconcile create_client queues right after this call,
        # not the pass currently holding the lock.
        log_event(
            logger,
            Event.POLICY_ROW_LOCK_BUSY,
            level=logging.INFO,
            request_id=request_id,
            region_id=client.region_id,
            client_id=client.client_id,
        )
    except Exception as exc:
        log_event(
            logger,
            Event.POLICY_ROW_APPLY_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            region_id=client.region_id,
            client_id=client.client_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )


def _poke_other_regions(request: Request, *, token: str, request_id: str) -> None:
    """Fire-and-forget: runs as a BackgroundTask after the response is already
    sent, so nothing here can affect the request result. Pokes every other
    enabled region's /sync/refresh, replaying the caller's own bearer token
    exactly as _delete_remote_client does."""
    repository: FirebaseRepository = request.app.state.repository
    settings = request.app.state.settings
    try:
        regions = repository.list_enabled_regions()
    except Exception:
        return
    for region in regions:
        if region.region_id == settings.region_id:
            continue
        _poke_regional_policy_refresh(
            region_id=region.region_id,
            token=token,
            api_hostname=settings.api_hostname,
            request_id=request_id,
        )


def _poke_regional_policy_refresh(*, region_id: str, token: str, api_hostname: str, request_id: str) -> None:
    try:
        url = _regional_api_url(region_id, "sync/refresh", api_hostname)
        regional_request = URLRequest(
            url,
            data=b"",
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "User-Agent": REGIONAL_API_USER_AGENT,
            },
        )
        with urlopen(regional_request, timeout=POLICY_POKE_TIMEOUT_SECONDS):
            pass
    except Exception as exc:
        # Every error is swallowed by design (see TODO/account-scoped-acl.md,
        # "Accepted risks": a dropped poke just leaves the region stale until
        # the next fleet-wide event or an admin Sync All). Region id only -
        # never the token, uid, or the response body.
        log_event(
            logger,
            Event.POLICY_POKE_FAILED,
            level=logging.WARNING,
            request_id=request_id,
            region_id=region_id,
            error_type=type(exc).__name__,
        )


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

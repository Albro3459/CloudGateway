import ipaddress
import logging
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime

from .enums import Event, MeshPeerReasonCode, MeshPeerStatus
from .logs import log_event, setup_logging
from .policy_sync import reconcile_policy
from .repository import ClientDoc, FirebaseRepository, MeshPeerState, RegionDoc
from .settings import Settings
from .wireguard import (
    MESH_AGGREGATE_V4,
    MESH_AGGREGATE_V6,
    PEER_ADDED,
    PEER_REMOVED,
    PEER_UPDATED,
    MeshPeer,
    PeerSyncResult,
    WireGuardManager,
    is_subnet_of,
    is_valid_endpoint_host,
    is_valid_port,
    is_valid_tunnel_ip,
    is_valid_wireguard_key,
)

logger = logging.getLogger("src.sync")

# Exit codes for cloudgateway-sync-peers (systemd: Restart=on-failure, RestartSec=30,
# StartLimitIntervalSec=0). A peer-sync failure short-circuits before policy is
# attempted at all, since the policy pass depends on the same reconciled state.
# A policy failure is now retriable too - the whole pass (peers + policy) is
# idempotent, so a retry is safe and is how a rebuilt/rebooted host converges
# its account-scoped ACL map without waiting for a client to poke it.
EXIT_OK = 0
EXIT_PEER_SYNC_FAILED = 1
EXIT_POLICY_FAILED = 2


@dataclass(frozen=True)
class DesiredClientPeers:
    peers: dict[str, tuple[str, str]] = field(default_factory=dict)
    # Public keys of degraded-but-still-active records: a syntactically valid key
    # whose tunnel IP is missing/corrupt. Threaded into sync_peers so the removal
    # sweep does not tear down that client's already-live peer as unknown.
    protected_keys: frozenset[str] = frozenset()
    degraded_count: int = 0


def desired_peers(
    repository: FirebaseRepository,
    region_id: str,
    *,
    local_region: RegionDoc | None = None,
) -> DesiredClientPeers:
    if local_region is None:
        local_region = repository.get_region(region_id)
    if local_region is None or local_region.enabled is not True:
        return DesiredClientPeers()

    peers: dict[str, tuple[str, str]] = {}
    protected_keys: set[str] = set()
    degraded_count = 0
    for client in repository.list_active_clients(region_id):
        valid_key = is_valid_wireguard_key(client.client_public_key)
        complete = (
            valid_key
            and is_valid_tunnel_ip(client.assigned_tunnel_ipv4, 4)
            and is_valid_tunnel_ip(client.assigned_tunnel_ipv6, 6)
        )
        if complete:
            peers[client.client_public_key] = (client.assigned_tunnel_ipv4, client.assigned_tunnel_ipv6)
            continue
        # Excluded from the desired set, not fatal: an invalid public key or tunnel
        # IP must not abort the pass. A record with a valid key is still active
        # (list_active_clients already filters by status), so its live peer is
        # protected from the removal sweep instead of being torn down as unknown.
        degraded_count += 1
        if valid_key:
            protected_keys.add(client.client_public_key)
    return DesiredClientPeers(peers=peers, protected_keys=frozenset(protected_keys), degraded_count=degraded_count)


@dataclass(frozen=True)
class DesiredMesh:
    peers: tuple[MeshPeer, ...] = ()
    candidates: tuple[MeshPeerState, ...] = ()
    mesh_enabled: bool = False


def desired_mesh_peers(
    repository: FirebaseRepository,
    settings: Settings,
    enabled_regions: Sequence[RegionDoc],
    *,
    local_region: RegionDoc | None = None,
) -> DesiredMesh:
    if local_region is None:
        local_region = repository.get_region(settings.region_id)
    mesh_enabled = (
        local_region is not None
        and local_region.enabled is True
        and local_region.mesh_enabled is True
    )
    if not mesh_enabled:
        return DesiredMesh(mesh_enabled=False)

    candidates = [
        region
        for region in enabled_regions
        if region.enabled is True
        and region.region_id != settings.region_id
        and region.mesh_enabled is True
    ]
    local_networks = _local_networks(settings)
    if local_networks is None:
        log_event(
            logger,
            Event.MESH_LOCAL_NETWORK_INVALID,
            level=logging.ERROR,
            region_id=settings.region_id,
        )

    valid_key_owners: dict[str, list[str]] = {}
    for region in enabled_regions:
        if is_valid_wireguard_key(region.wireguard_public_key):
            valid_key_owners.setdefault(region.wireguard_public_key, []).append(region.region_id)
    duplicate_keys = {key for key, owners in valid_key_owners.items() if len(owners) > 1}

    parsed: dict[str, tuple[RegionDoc, ipaddress.IPv4Network, ipaddress.IPv6Network, MeshPeer]] = {}
    states: dict[str, MeshPeerState] = {}
    for region in candidates:
        raw_key = region.wireguard_public_key if isinstance(region.wireguard_public_key, str) else ""
        if raw_key in duplicate_keys:
            endpoint_host = region.wireguard_endpoint_hostname if isinstance(region.wireguard_endpoint_hostname, str) else ""
            network_v4 = region.tunnel_network_v4 if isinstance(region.tunnel_network_v4, str) else ""
            network_v6 = region.tunnel_network_v6 if isinstance(region.tunnel_network_v6, str) else ""
            parsed_v4, _ = _parse_mesh_network(network_v4, 4)
            parsed_v6, _ = _parse_mesh_network(network_v6, 6)
            states[region.region_id] = _incomplete_state(
                region,
                endpoint_hostname=endpoint_host if is_valid_endpoint_host(endpoint_host) else "",
                public_key=raw_key,
                endpoint_port=region.wireguard_port if is_valid_port(region.wireguard_port) else None,
                reason_code=MeshPeerReasonCode.DUPLICATE_PUBLIC_KEY.value,
                allowed_network_v4=str(parsed_v4) if isinstance(parsed_v4, ipaddress.IPv4Network) else "",
                allowed_network_v6=str(parsed_v6) if isinstance(parsed_v6, ipaddress.IPv6Network) else "",
            )
            log_event(
                logger,
                Event.MESH_PEER_SKIPPED,
                level=logging.ERROR,
                region_id=settings.region_id,
                conflicting_region_ids=valid_key_owners[raw_key],
                reason_code=MeshPeerReasonCode.DUPLICATE_PUBLIC_KEY.value,
            )
            continue
        peer, state = normalize_mesh_candidate(region)
        if peer is None:
            states[region.region_id] = state
            continue
        v4 = ipaddress.ip_network(peer.allowed_network_v4)
        v6 = ipaddress.ip_network(peer.allowed_network_v6)
        if not isinstance(v4, ipaddress.IPv4Network) or not isinstance(v6, ipaddress.IPv6Network):
            # Defensive: normalize_mesh_candidate already pinned both families. Recorded
            # as a skip rather than dropped, because ordered_states below indexes states
            # by every candidate's region id and would otherwise raise KeyError.
            states[region.region_id] = _incomplete_state(
                region,
                peer.endpoint_host,
                peer.public_key,
                peer.endpoint_port,
                MeshPeerReasonCode.INVALID_NETWORK_V4.value,
                peer.allowed_network_v4,
                peer.allowed_network_v6,
            )
            continue
        parsed[region.region_id] = (region, v4, v6, peer)

    overlap_reasons: dict[str, str] = {}
    for region_id, (_, v4, v6, _) in parsed.items():
        if local_networks is None:
            overlap_reasons[region_id] = MeshPeerReasonCode.LOCAL_NETWORK_INVALID.value
        elif _overlaps_local(v4, v6, *local_networks):
            overlap_reasons[region_id] = MeshPeerReasonCode.OVERLAP_LOCAL.value
            log_event(
                logger,
                Event.MESH_PEER_SKIPPED,
                level=logging.ERROR,
                region_id=settings.region_id,
                conflicting_region_id=region_id,
                network_v4=str(v4),
                network_v6=str(v6),
            )

    ids = list(parsed)
    for index, region_id_a in enumerate(ids):
        _, v4_a, v6_a, _ = parsed[region_id_a]
        for region_id_b in ids[index + 1 :]:
            _, v4_b, v6_b, _ = parsed[region_id_b]
            if v4_a.overlaps(v4_b) or v6_a.overlaps(v6_b):
                overlap_reasons[region_id_a] = MeshPeerReasonCode.OVERLAP_CANDIDATE.value
                overlap_reasons[region_id_b] = MeshPeerReasonCode.OVERLAP_CANDIDATE.value
                log_event(
                    logger,
                    Event.MESH_PEER_SKIPPED,
                    level=logging.ERROR,
                    region_id=region_id_a,
                    conflicting_region_id=region_id_b,
                    network_v4_a=str(v4_a),
                    network_v4_b=str(v4_b),
                    network_v6_a=str(v6_a),
                    network_v6_b=str(v6_b),
                )

    peers: list[MeshPeer] = []
    for region in candidates:
        region_id = region.region_id
        if region_id not in parsed:
            continue
        _, _, _, peer = parsed[region_id]
        overlap_reason = overlap_reasons.get(region_id)
        if overlap_reason is not None:
            states[region_id] = _mesh_state(
                region,
                MeshPeerStatus.SKIPPED_OVERLAP,
                reason_code=overlap_reason,
                peer=peer,
            )
            continue
        states[region_id] = _mesh_state(region, MeshPeerStatus.APPLIED, peer=peer)
        peers.append(peer)

    ordered_states = tuple(states[region.region_id] for region in candidates)
    return DesiredMesh(peers=tuple(peers), candidates=ordered_states, mesh_enabled=True)


def normalize_mesh_candidate(region: RegionDoc) -> tuple[MeshPeer | None, MeshPeerState]:
    """Normalize one Firestore region without allowing malformed data to abort a pass."""
    public_key = region.wireguard_public_key if isinstance(region.wireguard_public_key, str) else ""
    endpoint_host = region.wireguard_endpoint_hostname if isinstance(region.wireguard_endpoint_hostname, str) else ""
    network_v4 = region.tunnel_network_v4 if isinstance(region.tunnel_network_v4, str) else ""
    network_v6 = region.tunnel_network_v6 if isinstance(region.tunnel_network_v6, str) else ""
    endpoint_port = (
        region.wireguard_port
        if isinstance(region.wireguard_port, int) and not isinstance(region.wireguard_port, bool)
        else None
    )
    valid_public_key = public_key if is_valid_wireguard_key(public_key) else ""
    valid_endpoint_host = endpoint_host if is_valid_endpoint_host(endpoint_host) else ""
    valid_endpoint_port = endpoint_port if is_valid_port(endpoint_port) else None
    parsed_v4, reason_v4 = _parse_mesh_network(network_v4, 4)
    parsed_v6, reason_v6 = _parse_mesh_network(network_v6, 6)
    valid_network_v4 = str(parsed_v4) if isinstance(parsed_v4, ipaddress.IPv4Network) else ""
    valid_network_v6 = str(parsed_v6) if isinstance(parsed_v6, ipaddress.IPv6Network) else ""

    reason_code = None
    if not public_key:
        reason_code = MeshPeerReasonCode.MISSING_PUBLIC_KEY.value
    elif not valid_public_key:
        reason_code = MeshPeerReasonCode.INVALID_PUBLIC_KEY.value
    elif not endpoint_host:
        reason_code = MeshPeerReasonCode.MISSING_ENDPOINT_HOSTNAME.value
    elif not valid_endpoint_host:
        reason_code = MeshPeerReasonCode.INVALID_ENDPOINT_HOSTNAME.value
    elif valid_endpoint_port is None:
        reason_code = MeshPeerReasonCode.INVALID_ENDPOINT_PORT.value
    elif parsed_v4 is None:
        reason_code = reason_v4
    elif parsed_v6 is None:
        reason_code = reason_v6

    if reason_code is not None:
        return None, _incomplete_state(
            region,
            valid_endpoint_host,
            valid_public_key,
            valid_endpoint_port,
            reason_code,
            valid_network_v4,
            valid_network_v6,
        )
    if not isinstance(parsed_v4, ipaddress.IPv4Network) or not isinstance(parsed_v6, ipaddress.IPv6Network):
        return None, _incomplete_state(
            region,
            valid_endpoint_host,
            valid_public_key,
            valid_endpoint_port,
            MeshPeerReasonCode.INVALID_NETWORK_V4.value,
            valid_network_v4,
            valid_network_v6,
        )
    if not is_subnet_of(parsed_v4, ipaddress.ip_network(MESH_AGGREGATE_V4)) or not is_subnet_of(
        parsed_v6, ipaddress.ip_network(MESH_AGGREGATE_V6)
    ):
        return None, MeshPeerState(
            region_id=region.region_id,
            endpoint_hostname=valid_endpoint_host,
            public_key=valid_public_key,
            allowed_network_v4=valid_network_v4,
            allowed_network_v6=valid_network_v6,
            status=MeshPeerStatus.SKIPPED_INCOMPLETE,
            endpoint_port=valid_endpoint_port,
            reason_code=MeshPeerReasonCode.OUTSIDE_AGGREGATE.value,
        )
    peer = MeshPeer(valid_public_key, valid_endpoint_host, valid_endpoint_port, valid_network_v4, valid_network_v6)
    return peer, _mesh_state(region, MeshPeerStatus.APPLIED, peer=peer)


def _incomplete_state(
    region: RegionDoc,
    endpoint_hostname: str,
    public_key: str,
    endpoint_port: int | None,
    reason_code: str,
    allowed_network_v4: str = "",
    allowed_network_v6: str = "",
) -> MeshPeerState:
    return MeshPeerState(
        region_id=region.region_id,
        endpoint_hostname=endpoint_hostname,
        public_key=public_key,
        allowed_network_v4=allowed_network_v4,
        allowed_network_v6=allowed_network_v6,
        status=MeshPeerStatus.SKIPPED_INCOMPLETE,
        endpoint_port=endpoint_port,
        reason_code=reason_code,
    )


def _parse_mesh_network(value: str, version: int) -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network | None, str]:
    missing_code = MeshPeerReasonCode.MISSING_NETWORK_V4 if version == 4 else MeshPeerReasonCode.MISSING_NETWORK_V6
    invalid_code = MeshPeerReasonCode.INVALID_NETWORK_V4 if version == 4 else MeshPeerReasonCode.INVALID_NETWORK_V6
    if not value:
        return None, missing_code.value
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError:
        return None, invalid_code.value
    expected_prefix = 24 if version == 4 else 64
    if network.version != version or network.prefixlen != expected_prefix or str(network) != value:
        return None, invalid_code.value
    return network, ""


def _mesh_state(
    region: RegionDoc,
    status: MeshPeerStatus,
    *,
    reason_code: str | None = None,
    peer: MeshPeer | None = None,
) -> MeshPeerState:
    return MeshPeerState(
        region_id=region.region_id,
        endpoint_hostname=peer.endpoint_host if peer is not None else "",
        public_key=peer.public_key if peer is not None else "",
        allowed_network_v4=peer.allowed_network_v4 if peer is not None else "",
        allowed_network_v6=peer.allowed_network_v6 if peer is not None else "",
        status=status,
        endpoint_port=peer.endpoint_port if peer is not None and status != MeshPeerStatus.SKIPPED_INCOMPLETE else None,
        reason_code=reason_code,
    )


def _local_networks(
    settings: Settings,
) -> tuple[ipaddress.IPv4Network, ipaddress.IPv6Network] | None:
    try:
        v4 = ipaddress.ip_network(settings.wg_tunnel_ipv4_cidr, strict=True)
        v6 = ipaddress.ip_network(settings.wg_tunnel_ipv6_cidr, strict=True)
    except (TypeError, ValueError):
        return None
    if not isinstance(v4, ipaddress.IPv4Network) or not isinstance(v6, ipaddress.IPv6Network):
        return None
    return v4, v6


def _overlaps_local(v4, v6, local_v4, local_v6) -> bool:
    return v4.overlaps(local_v4) or v6.overlaps(local_v6)


@dataclass(frozen=True)
class SyncOutcome:
    result: PeerSyncResult
    mesh_enabled: bool
    mesh_candidates: tuple[MeshPeerState, ...] = ()
    mesh_region_by_key: dict[str, tuple[str, ...]] = field(default_factory=dict)
    # False when the live reconcile succeeded but the Mesh/* snapshot never
    # persisted. The dashboard reads mesh link state from that snapshot, so it
    # would otherwise render the previous pass's state as if it were current.
    mesh_status_written: bool = True
    # Client records excluded from the desired set this pass (invalid public key
    # or tunnel IP). Their already-live peer is protected, not removed - see
    # DesiredClientPeers.
    degraded_client_peers: int = 0


def run_sync(
    *,
    repository: FirebaseRepository,
    wireguard: WireGuardManager,
    settings: Settings,
    blocking: bool = True,
) -> SyncOutcome:
    # Firebase reads, live mutations, and the status snapshot are serialized by
    # the same lock. This prevents an older pass from writing status after a
    # newer reconciliation has completed. blocking=False makes a contended pass
    # fail fast instead of queueing behind the running one.
    with wireguard.lock(blocking=blocking):
        local_region = repository.get_region(settings.region_id)
        desired = desired_peers(repository, settings.region_id, local_region=local_region)
        if desired.degraded_count:
            log_event(
                logger,
                Event.CLIENT_PEER_DEGRADED,
                level=logging.WARNING,
                region_id=settings.region_id,
                degraded_count=desired.degraded_count,
            )
        # Peering only considers enabled regions, but classification considers every
        # region doc: a disabled or rekeyed region's live peer is still a server peer,
        # not a client peer, and its route is not an unclaimed one to reclaim.
        all_regions = repository.list_regions()
        enabled_regions = [region for region in all_regions if region.enabled is True]
        mesh = desired_mesh_peers(repository, settings, enabled_regions, local_region=local_region)
        other_regions = [region for region in all_regions if region.region_id != settings.region_id]
        key_owners: dict[str, list[str]] = {}
        for region in other_regions:
            if is_valid_wireguard_key(region.wireguard_public_key):
                key_owners.setdefault(region.wireguard_public_key, []).append(region.region_id)
        known_region_keys = tuple(key_owners)
        known_mesh_networks = tuple(
            cidr
            for region in other_regions
            for cidr in (region.tunnel_network_v4, region.tunnel_network_v6)
            if isinstance(cidr, str) and cidr
        )

        result = wireguard.sync_peers(
            desired.peers,
            mesh=mesh.peers,
            known_mesh_networks=known_mesh_networks,
            known_region_keys=known_region_keys,
            protected_client_keys=tuple(desired.protected_keys),
        )
        mesh_status_written = True
        try:
            repository.write_mesh_status(
                region_id=settings.region_id,
                mesh_enabled=mesh.mesh_enabled,
                peers=mesh.candidates,
            )
        except Exception as exc:
            # Reported, not raised: the interface is already reconciled, so failing
            # the pass here would discard correct work over a status write.
            mesh_status_written = False
            log_event(
                logger,
                Event.MESH_STATUS_WRITE_FAILED,
                level=logging.ERROR,
                region_id=settings.region_id,
                exc_info=(type(exc), exc, exc.__traceback__),
            )

    return SyncOutcome(
        result=result,
        mesh_enabled=mesh.mesh_enabled,
        mesh_candidates=mesh.candidates,
        mesh_region_by_key={key: tuple(owners) for key, owners in key_owners.items()},
        mesh_status_written=mesh_status_written,
        degraded_client_peers=desired.degraded_count,
    )


def build_sync_audit_log(
    *,
    region_id: str,
    synced_at: datetime,
    result: PeerSyncResult,
    clients_by_key: dict[str, ClientDoc],
    mesh_enabled: bool,
    mesh_candidates: Sequence[MeshPeerState] = (),
    mesh_region_by_key: Mapping[str, tuple[str, ...] | str] | None = None,
    degraded_client_peers: int = 0,
) -> str:
    # Plain text only (no ANSI/color) so the file reads back cleanly. Lists the
    # client peers each pass added/updated/removed; removed peers include Firebase
    # client details when a non-active doc with the same public key still exists.
    # The summary also reports how many client records were degraded (invalid
    # public key or tunnel IP) and excluded from the desired set this pass - a
    # count only, never which record or any of its fields.
    # The mesh section is server metadata only (region IDs, CIDRs, endpoint
    # hostnames) - never a public key, never per-user data.
    mesh_region_by_key = mesh_region_by_key or {}
    lines = [
        "CloudGateway peer sync audit log",
        f"region: {region_id}",
        f"syncedAt: {synced_at.isoformat()}",
        (
            f"summary: added={result.added} updated={result.updated} removed={result.removed} "
            f"clientPeersDegraded={degraded_client_peers} "
            f"meshApplied={result.mesh_applied} meshAdded={result.mesh_added} meshUpdated={result.mesh_updated} "
            f"meshRemoved={result.mesh_removed} meshRoutesAdded={result.routes_added} meshRoutesRemoved={result.routes_removed}"
        ),
    ]

    if not result.changes:
        lines.append("")
        lines.append("No client peer changes were required; the live peer set already matched Firebase.")
    else:
        for action, header in (
            (PEER_ADDED, "added"),
            (PEER_UPDATED, "updated"),
            (PEER_REMOVED, "removed (host peers with no matching active client)"),
        ):
            entries = [change for change in result.changes if change.action == action]
            if not entries:
                continue
            lines.append("")
            lines.append(f"{header}:")
            for change in entries:
                parts = [f"publicKey={change.public_key}"]
                client = clients_by_key.get(change.public_key)
                if client is not None:
                    parts.append(f"clientId={client.client_id}")
                    parts.append(f"status={client.status.value}")
                    if client.owner_email:
                        parts.append(f"email={client.owner_email}")
                    if client.client_name:
                        parts.append(f"clientName={client.client_name}")
                if change.tunnel_ipv4:
                    parts.append(f"tunnelIpv4={change.tunnel_ipv4}")
                if change.tunnel_ipv6:
                    parts.append(f"tunnelIpv6={change.tunnel_ipv6}")
                lines.append("  " + " ".join(parts))

    lines.append("")
    lines.append(f"mesh: enabled={mesh_enabled}")
    if mesh_candidates:
        lines.append("mesh candidates:")
        for candidate in mesh_candidates:
            lines.append(
                "  "
                f"regionId={candidate.region_id} status={candidate.status.value} "
                f"endpointHostname={candidate.endpoint_hostname} "
                f"endpointPort={candidate.endpoint_port} "
                f"allowedNetworkV4={candidate.allowed_network_v4} allowedNetworkV6={candidate.allowed_network_v6} "
                f"reasonCode={candidate.reason_code}"
            )
    if result.mesh_changes:
        lines.append("mesh peer changes:")
        for change in result.mesh_changes:
            owner_value = mesh_region_by_key.get(change.public_key, "unknown")
            region_id_label = ",".join(owner_value) if isinstance(owner_value, tuple) else owner_value
            parts = [f"regionId={region_id_label}", f"action={change.action}"]
            if change.endpoint_port is not None:
                parts.append(f"endpointPort={change.endpoint_port}")
            if change.allowed_network_v4:
                parts.append(f"allowedNetworkV4={change.allowed_network_v4}")
            if change.allowed_network_v6:
                parts.append(f"allowedNetworkV6={change.allowed_network_v6}")
            lines.append("  " + " ".join(parts))
    if result.route_changes:
        lines.append("mesh route changes:")
        for change in result.route_changes:
            reclaimed = " reclaimed=true" if change.reclaimed else ""
            lines.append(f"  cidr={change.cidr} action={change.action}{reclaimed}")

    return "\n".join(lines) + "\n"


def main() -> int:
    setup_logging()
    settings = Settings()

    from .firebase import FirestoreRepository
    from .policy import LocalPolicyManager
    from .wireguard import LocalWireGuardManager

    repository = FirestoreRepository(settings)
    policy = LocalPolicyManager()
    wireguard = LocalWireGuardManager(
        interface=settings.wg_interface,
        server_public_key=settings.wg_server_public_key,
        endpoint_host=settings.wg_endpoint_hostname,
        listen_port=settings.wg_port,
        dns_ipv4=settings.wg_dns_ipv4,
        dns_ipv6=settings.wg_dns_ipv6,
        tunnel_network_v4=settings.wg_tunnel_ipv4_cidr,
        tunnel_network_v6=settings.wg_tunnel_ipv6_cidr,
    )

    log_event(logger, Event.PEER_SYNC_STARTED, region_id=settings.region_id)
    try:
        outcome = run_sync(repository=repository, wireguard=wireguard, settings=settings)
    except Exception as exc:
        log_event(
            logger,
            Event.PEER_SYNC_FAILED,
            level=logging.ERROR,
            region_id=settings.region_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        return EXIT_PEER_SYNC_FAILED

    log_event(
        logger,
        Event.PEER_SYNC_COMPLETED,
        region_id=settings.region_id,
        added=outcome.result.added,
        updated=outcome.result.updated,
        removed=outcome.result.removed,
        mesh_enabled=outcome.mesh_enabled,
        mesh_applied=outcome.result.mesh_applied,
        mesh_added=outcome.result.mesh_added,
        mesh_updated=outcome.result.mesh_updated,
        mesh_removed=outcome.result.mesh_removed,
        mesh_routes_added=outcome.result.routes_added,
        mesh_routes_removed=outcome.result.routes_removed,
        mesh_status_written=outcome.mesh_status_written,
        degraded_client_peers=outcome.degraded_client_peers,
    )

    # Logged separately from the peer pass above: PEER_SYNC_COMPLETED was
    # already emitted, so an operator reading logs can tell "peers synced,
    # policy failed" apart from a full pass failure - this is not a
    # peer-sync failure. It does now affect this process's exit code: a
    # policy failure returns EXIT_POLICY_FAILED so systemd retries the
    # idempotent peer-plus-policy pass. A successful apply whose best-effort
    # status write failed (status_written=False) still returns EXIT_OK - the
    # wire is already correct and that write is best effort by contract.
    log_event(logger, Event.POLICY_REFRESH_STARTED, region_id=settings.region_id)
    try:
        policy_outcome = reconcile_policy(repository=repository, policy=policy, settings=settings)
    except Exception as exc:
        log_event(
            logger,
            Event.POLICY_REFRESH_FAILED,
            level=logging.ERROR,
            region_id=settings.region_id,
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        return EXIT_POLICY_FAILED

    log_event(
        logger,
        Event.POLICY_REFRESH_COMPLETED,
        region_id=settings.region_id,
        row_count=policy_outcome.row_count,
        skipped_rows=policy_outcome.skipped_rows,
        status_written=policy_outcome.status_written,
    )

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())

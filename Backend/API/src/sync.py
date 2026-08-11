import ipaddress
import logging
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime

from .enums import Event, MeshPeerStatus
from .logs import log_event, setup_logging
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
)

logger = logging.getLogger("src.sync")


def desired_peers(repository: FirebaseRepository, region_id: str) -> dict[str, tuple[str, str]]:
    return {
        client.client_public_key: (client.assigned_tunnel_ipv4, client.assigned_tunnel_ipv6)
        for client in repository.list_active_clients(region_id)
    }


@dataclass(frozen=True)
class DesiredMesh:
    peers: tuple[MeshPeer, ...] = ()
    candidates: tuple[MeshPeerState, ...] = ()
    mesh_enabled: bool = False


def desired_mesh_peers(
    repository: FirebaseRepository,
    settings: Settings,
    enabled_regions: Sequence[RegionDoc],
) -> DesiredMesh:
    local_region = repository.get_region(settings.region_id)
    mesh_enabled = bool(local_region and local_region.mesh_enabled)
    if not mesh_enabled:
        # Not in the mesh this pass: no attempt is made, so nothing to report.
        # The (already-empty) apply-set flows through the union sync + route
        # sweep, which removes any previously-applied mesh peers/routes - that
        # is the rollback path.
        return DesiredMesh(mesh_enabled=False)

    candidates = [
        region for region in enabled_regions if region.region_id != settings.region_id and region.mesh_enabled
    ]

    # The local overlap check must trust the host's own tunnel networks
    # (settings, the same values that configure wg0), never the local region
    # doc - a doc other parties can write. `mesh_enabled` above stays sourced
    # from the doc since that is operator-owned state.
    local_networks = _local_networks(settings)
    if local_networks is None:
        # A malformed local network here means the guard can no longer tell a
        # hijack attempt from a benign candidate - fail closed, loudly, rather
        # than silently skipping the overlap check (the old, fail-open bug).
        log_event(
            logger,
            Event.MESH_LOCAL_NETWORK_INVALID,
            level=logging.ERROR,
            region_id=settings.region_id,
        )

    parsed: dict[str, tuple[RegionDoc, ipaddress.IPv4Network | ipaddress.IPv6Network, ipaddress.IPv4Network | ipaddress.IPv6Network]] = {}
    states: dict[str, MeshPeerState] = {}
    for region in candidates:
        networks = _parse_candidate_networks(region)
        if networks is None:
            states[region.region_id] = _mesh_state(region, MeshPeerStatus.SKIPPED_INCOMPLETE)
            continue
        parsed[region.region_id] = (region, networks[0], networks[1])

    overlap_flagged: set[str] = set()
    for region_id, (region, v4, v6) in parsed.items():
        if local_networks is None or _overlaps_local(v4, v6, *local_networks):
            overlap_flagged.add(region_id)
            log_event(
                logger,
                Event.MESH_PEER_SKIPPED,
                level=logging.ERROR,
                region_id=settings.region_id,
                conflicting_region_id=region_id,
                network_v4=str(v4),
                network_v6=str(v6),
            )

    ids = list(parsed.keys())
    for i, region_id_a in enumerate(ids):
        _, v4_a, v6_a = parsed[region_id_a]
        for region_id_b in ids[i + 1 :]:
            _, v4_b, v6_b = parsed[region_id_b]
            if v4_a.overlaps(v4_b) or v6_a.overlaps(v6_b):
                overlap_flagged.add(region_id_a)
                overlap_flagged.add(region_id_b)
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
        status = MeshPeerStatus.SKIPPED_OVERLAP if region_id in overlap_flagged else MeshPeerStatus.APPLIED
        states[region_id] = _mesh_state(region, status)
        if status == MeshPeerStatus.APPLIED:
            peers.append(
                MeshPeer(
                    public_key=region.wireguard_public_key,
                    endpoint_host=region.wireguard_endpoint_hostname,
                    endpoint_port=region.wireguard_port,
                    allowed_network_v4=region.tunnel_network_v4,
                    allowed_network_v6=region.tunnel_network_v6,
                )
            )

    ordered_states = tuple(states[region.region_id] for region in candidates)
    return DesiredMesh(peers=tuple(peers), candidates=ordered_states, mesh_enabled=True)


def _mesh_state(region: RegionDoc, status: MeshPeerStatus) -> MeshPeerState:
    return MeshPeerState(
        region_id=region.region_id,
        endpoint_hostname=region.wireguard_endpoint_hostname,
        public_key=region.wireguard_public_key,
        allowed_network_v4=region.tunnel_network_v4,
        allowed_network_v6=region.tunnel_network_v6,
        status=status,
    )


def _local_networks(
    settings: Settings,
) -> tuple[ipaddress.IPv4Network, ipaddress.IPv6Network] | None:
    try:
        v4 = ipaddress.ip_network(settings.wg_tunnel_ipv4_cidr, strict=True)
        v6 = ipaddress.ip_network(settings.wg_tunnel_ipv6_cidr, strict=True)
    except ValueError:
        return None
    if not isinstance(v4, ipaddress.IPv4Network) or not isinstance(v6, ipaddress.IPv6Network):
        return None
    return v4, v6


def _parse_candidate_networks(region: RegionDoc):
    if not region.wireguard_public_key or not region.wireguard_endpoint_hostname:
        return None
    if not region.tunnel_network_v4 or not region.tunnel_network_v6:
        return None
    try:
        v4 = ipaddress.ip_network(region.tunnel_network_v4, strict=True)
        v6 = ipaddress.ip_network(region.tunnel_network_v6, strict=True)
    except ValueError:
        return None
    if v4.version != 4 or v6.version != 6:
        return None
    if not is_subnet_of(v4, ipaddress.ip_network(MESH_AGGREGATE_V4)):
        return None
    if not is_subnet_of(v6, ipaddress.ip_network(MESH_AGGREGATE_V6)):
        return None
    return v4, v6


def _overlaps_local(v4, v6, local_v4, local_v6) -> bool:
    return v4.overlaps(local_v4) or v6.overlaps(local_v6)


@dataclass(frozen=True)
class SyncOutcome:
    result: PeerSyncResult
    mesh_enabled: bool
    mesh_candidates: tuple[MeshPeerState, ...] = ()
    mesh_region_by_key: dict[str, str] = field(default_factory=dict)


def run_sync(*, repository: FirebaseRepository, wireguard: WireGuardManager, settings: Settings) -> SyncOutcome:
    # Read the desired peer set (clients + mesh) under the lock so a concurrent
    # create/delete/mesh-toggle cannot commit between the Firebase read and the
    # live peer apply, which would otherwise let sync remove a just-created peer
    # (or re-add a removed one) from a stale snapshot.
    with wireguard.lock():
        desired = desired_peers(repository, settings.region_id)
        enabled_regions = repository.list_enabled_regions()
        mesh = desired_mesh_peers(repository, settings, enabled_regions)

        # Every other enabled region, regardless of its own meshEnabled value or
        # this pass's overlap/completeness outcome - used only for live-peer
        # classification and route-sweep "known to Firestore" accounting, so a
        # region that just turned mesh off (but is still deployed) is still
        # recognized as mesh when its peer/route is torn down.
        other_regions = [region for region in enabled_regions if region.region_id != settings.region_id]
        known_region_keys = tuple(region.wireguard_public_key for region in other_regions if region.wireguard_public_key)
        known_mesh_networks = tuple(
            cidr
            for region in other_regions
            for cidr in (region.tunnel_network_v4, region.tunnel_network_v6)
            if cidr
        )
        mesh_region_by_key = {region.wireguard_public_key: region.region_id for region in other_regions if region.wireguard_public_key}

        result = wireguard.sync_peers(
            desired,
            mesh=mesh.peers,
            known_mesh_networks=known_mesh_networks,
            known_region_keys=known_region_keys,
        )

    # mesh.mesh_enabled is the value desired_mesh_peers observed under the lock
    # above - the status doc must record exactly what this pass acted on, not a
    # value re-read after the lock is released (an operator toggle in between
    # would otherwise land in Firestore without ever having been applied).
    #
    # Best-effort observability write. The reconcile above already committed to
    # the interface, so a Firestore write failure here must never fail (or
    # retroactively undo) an already-successful sync - it is the one carve-out
    # to "sync never writes to Firebase" (docs/wireguard-drift-repair.md).
    try:
        repository.write_mesh_status(
            region_id=settings.region_id,
            mesh_enabled=mesh.mesh_enabled,
            peers=mesh.candidates,
        )
    except Exception as exc:
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
        mesh_region_by_key=mesh_region_by_key,
    )


def build_sync_audit_log(
    *,
    region_id: str,
    synced_at: datetime,
    result: PeerSyncResult,
    clients_by_key: dict[str, ClientDoc],
    mesh_enabled: bool,
    mesh_candidates: Sequence[MeshPeerState] = (),
    mesh_region_by_key: dict[str, str] | None = None,
) -> str:
    # Plain text only (no ANSI/color) so the file reads back cleanly. Lists the
    # client peers each pass added/updated/removed; removed peers include Firebase
    # client details when a non-active doc with the same public key still exists.
    # The mesh section is server metadata only (region IDs, CIDRs, endpoint
    # hostnames) - never a public key, never per-user data.
    mesh_region_by_key = mesh_region_by_key or {}
    lines = [
        "CloudGateway peer sync audit log",
        f"region: {region_id}",
        f"syncedAt: {synced_at.isoformat()}",
        (
            f"summary: added={result.added} updated={result.updated} removed={result.removed} "
            f"meshApplied={result.mesh_applied} meshAdded={result.mesh_added} meshRemoved={result.mesh_removed} "
            f"meshRoutesAdded={result.routes_added} meshRoutesRemoved={result.routes_removed}"
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
                f"allowedNetworkV4={candidate.allowed_network_v4} allowedNetworkV6={candidate.allowed_network_v6}"
            )
    if result.mesh_changes:
        lines.append("mesh peer changes:")
        for change in result.mesh_changes:
            region_id_label = mesh_region_by_key.get(change.public_key, "unknown")
            parts = [f"regionId={region_id_label}", f"action={change.action}"]
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
    from .wireguard import LocalWireGuardManager

    repository = FirestoreRepository(settings)
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
        return 1

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
        mesh_removed=outcome.result.mesh_removed,
        mesh_routes_added=outcome.result.routes_added,
        mesh_routes_removed=outcome.result.routes_removed,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

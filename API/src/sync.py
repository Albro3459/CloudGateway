import logging
from datetime import datetime

from .enums import Event
from .logs import log_event, setup_logging
from .repository import ClientDoc, FirebaseRepository
from .settings import Settings
from .wireguard import PEER_ADDED, PEER_REMOVED, PEER_UPDATED, PeerSyncResult, WireGuardManager

logger = logging.getLogger("src.sync")


def desired_peers(repository: FirebaseRepository, region_id: str) -> dict[str, tuple[str, str]]:
    return {
        client.client_public_key: (client.assigned_tunnel_ipv4, client.assigned_tunnel_ipv6)
        for client in repository.list_active_clients(region_id)
    }


def run_sync(*, repository: FirebaseRepository, wireguard: WireGuardManager, region_id: str) -> PeerSyncResult:
    # Read the desired peer set under the lock so a concurrent create/delete
    # cannot commit between the Firebase read and the live peer apply, which
    # would otherwise let sync remove a just-created peer (or re-add a removed
    # one) from a stale snapshot.
    with wireguard.lock():
        desired = desired_peers(repository, region_id)
        return wireguard.sync_peers(desired)


def build_sync_audit_log(
    *,
    region_id: str,
    synced_at: datetime,
    result: PeerSyncResult,
    clients_by_key: dict[str, ClientDoc],
) -> str:
    # Plain text only (no ANSI/color) so the file reads back cleanly. Lists the
    # peers each pass added/updated/removed; added/updated join to the owning
    # client doc, removed peers have no active doc and are shown by key alone.
    lines = [
        "CloudGateway peer sync audit log",
        f"region: {region_id}",
        f"syncedAt: {synced_at.isoformat()}",
        f"summary: added={result.added} updated={result.updated} removed={result.removed}",
    ]
    if not result.changes:
        lines.append("")
        lines.append("No peer changes were required; the live peer set already matched Firebase.")
        return "\n".join(lines) + "\n"

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
                if client.owner_email:
                    parts.append(f"email={client.owner_email}")
                if client.client_name:
                    parts.append(f"clientName={client.client_name}")
            if change.tunnel_ipv4:
                parts.append(f"tunnelIpv4={change.tunnel_ipv4}")
            if change.tunnel_ipv6:
                parts.append(f"tunnelIpv6={change.tunnel_ipv6}")
            lines.append("  " + " ".join(parts))

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
    )

    log_event(logger, Event.PEER_SYNC_STARTED, region_id=settings.region_id)
    try:
        result = run_sync(repository=repository, wireguard=wireguard, region_id=settings.region_id)
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
        added=result.added,
        updated=result.updated,
        removed=result.removed,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

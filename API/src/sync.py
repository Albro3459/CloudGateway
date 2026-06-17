import logging

from .enums import Event
from .logs import log_event, setup_logging
from .repository import FirebaseRepository
from .settings import Settings
from .wireguard import PeerSyncResult, WireGuardManager

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

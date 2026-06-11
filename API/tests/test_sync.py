from dataclasses import replace

from cloudlaunch_api.enums import ClientStatus
from cloudlaunch_api.sync import desired_peers, run_sync
from cloudlaunch_api.wireguard import PeerSyncResult

from .fakes import FakeRepository, FakeWireGuardManager
from .test_repository import REGION_ID, enabled_region, reserve


def make_repository() -> FakeRepository:
    repository = FakeRepository(local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    return repository


def activate(repository: FakeRepository, client, public_key: str):
    return repository.mark_client_active(
        owner_uid=client.owner_uid,
        region_id=client.region_id,
        client_id=client.client_id,
        client_public_key=public_key,
        wireguard_config="[Interface]\nPrivateKey = hidden",
    )


def test_desired_peers_only_includes_active_clients_with_keys():
    repository = make_repository()
    active = activate(repository, reserve(repository), "active-public-key")
    reserve(repository, client_name="still creating")
    removed = activate(repository, reserve(repository, client_name="gone"), "removed-public-key")
    repository.clients[(removed.owner_uid, REGION_ID, removed.client_id)] = replace(
        removed, status=ClientStatus.REMOVED
    )

    desired = desired_peers(repository, REGION_ID)

    assert desired == {
        "active-public-key": (active.assigned_tunnel_ipv4, active.assigned_tunnel_ipv6),
    }


def test_run_sync_restores_missing_peer_and_removes_unknown_peer():
    repository = make_repository()
    active = activate(repository, reserve(repository), "active-public-key")
    wireguard = FakeWireGuardManager()
    wireguard.peers["unknown-public-key"] = ("10.0.0.9/32", "fd42:42:42::9/128")

    result = run_sync(repository=repository, wireguard=wireguard, region_id=REGION_ID)

    assert result == PeerSyncResult(added=1, updated=0, removed=1)
    assert wireguard.peers == {
        "active-public-key": (active.assigned_tunnel_ipv4, active.assigned_tunnel_ipv6),
    }
    assert wireguard.locked is False


def test_run_sync_fixes_drifted_allowed_ips():
    repository = make_repository()
    active = activate(repository, reserve(repository), "active-public-key")
    wireguard = FakeWireGuardManager()
    wireguard.peers["active-public-key"] = ("10.0.0.9/32", "fd42:42:42::9/128")

    result = run_sync(repository=repository, wireguard=wireguard, region_id=REGION_ID)

    assert result == PeerSyncResult(added=0, updated=1, removed=0)
    assert wireguard.peers["active-public-key"] == (
        active.assigned_tunnel_ipv4,
        active.assigned_tunnel_ipv6,
    )


def test_run_sync_with_no_clients_clears_all_peers():
    repository = make_repository()
    wireguard = FakeWireGuardManager()
    wireguard.peers["unknown-public-key"] = ("10.0.0.9/32", "fd42:42:42::9/128")

    result = run_sync(repository=repository, wireguard=wireguard, region_id=REGION_ID)

    assert result == PeerSyncResult(added=0, updated=0, removed=1)
    assert wireguard.peers == {}


def test_run_sync_with_missing_region_doc_is_an_empty_success():
    repository = FakeRepository(local_region_id=REGION_ID)
    wireguard = FakeWireGuardManager()

    result = run_sync(repository=repository, wireguard=wireguard, region_id=REGION_ID)

    assert result == PeerSyncResult(added=0, updated=0, removed=0)
    assert wireguard.sync_calls == 1

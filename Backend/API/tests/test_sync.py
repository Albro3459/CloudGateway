from dataclasses import replace
from datetime import datetime, timezone
from typing import cast

import pytest

from src.enums import ClientStatus, MeshPeerStatus
from src.repository import MeshPeerState, RegionDoc
from src.sync import build_sync_audit_log, desired_mesh_peers, desired_peers, run_sync
from src.wireguard import PEER_ADDED, PEER_REMOVED, MeshPeer, MeshPeerChange, PeerSyncResult, RouteChange

from .conftest import make_settings
from .fakes import (
    FAKE_MESH_PUBLIC_KEY,
    FAKE_MESH_PUBLIC_KEY_2,
    FAKE_MESH_PUBLIC_KEY_3,
    FakeRepository,
    FakeWireGuardManager,
)
from .test_repository import REGION_ID, enabled_region, reserve


def make_repository() -> FakeRepository:
    repository = FakeRepository(local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    return repository


def mesh_ready_local_region(**overrides) -> RegionDoc:
    defaults = {
        "tunnel_network_v4": "10.0.0.0/24",
        "tunnel_network_v6": "fd42:42:42::/64",
        "mesh_enabled": True,
    }
    defaults.update(overrides)
    return replace(enabled_region(), **defaults)


def remote_region(
    region_id: str,
    *,
    public_key: str,
    tunnel_network_v4: str = "10.0.1.0/24",
    tunnel_network_v6: str = "fd42:42:42:1::/64",
    endpoint_hostname: str | None = None,
    mesh_enabled: bool = True,
    **overrides,
) -> RegionDoc:
    return replace(
        enabled_region(),
        region_id=region_id,
        wireguard_public_key=public_key,
        wireguard_endpoint_hostname=endpoint_hostname if endpoint_hostname is not None else f"wg.{region_id}.example.com",
        tunnel_network_v4=tunnel_network_v4,
        tunnel_network_v6=tunnel_network_v6,
        mesh_enabled=mesh_enabled,
        **overrides,
    )


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

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert (outcome.result.added, outcome.result.updated, outcome.result.removed) == (1, 0, 1)
    assert wireguard.peers == {
        "active-public-key": (active.assigned_tunnel_ipv4, active.assigned_tunnel_ipv6),
    }
    assert wireguard.locked is False


def test_run_sync_fixes_drifted_allowed_ips():
    repository = make_repository()
    active = activate(repository, reserve(repository), "active-public-key")
    wireguard = FakeWireGuardManager()
    wireguard.peers["active-public-key"] = ("10.0.0.9/32", "fd42:42:42::9/128")

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert (outcome.result.added, outcome.result.updated, outcome.result.removed) == (0, 1, 0)
    assert wireguard.peers["active-public-key"] == (
        active.assigned_tunnel_ipv4,
        active.assigned_tunnel_ipv6,
    )


def test_run_sync_with_no_clients_clears_all_peers():
    repository = make_repository()
    wireguard = FakeWireGuardManager()
    wireguard.peers["unknown-public-key"] = ("10.0.0.9/32", "fd42:42:42::9/128")

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert (outcome.result.added, outcome.result.updated, outcome.result.removed) == (0, 0, 1)
    assert wireguard.peers == {}


def test_run_sync_with_disabled_local_region_clears_client_peers():
    repository = make_repository()
    active = activate(repository, reserve(repository), "active-public-key")
    repository.regions[REGION_ID] = replace(repository.regions[REGION_ID], enabled=False)
    wireguard = FakeWireGuardManager()
    wireguard.peers[active.client_public_key] = (
        active.assigned_tunnel_ipv4,
        active.assigned_tunnel_ipv6,
    )

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert outcome.result.removed == 1
    assert wireguard.peers == {}


def test_run_sync_with_missing_region_doc_is_an_empty_success():
    repository = FakeRepository(local_region_id=REGION_ID)
    wireguard = FakeWireGuardManager()

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert (outcome.result.added, outcome.result.updated, outcome.result.removed) == (0, 0, 0)
    assert outcome.mesh_enabled is False
    assert wireguard.sync_calls == 1


def test_run_sync_with_active_client_and_missing_region_doc_does_not_readd_peer():
    repository = make_repository()
    active = activate(repository, reserve(repository), "active-public-key")
    repository.regions.pop(REGION_ID)
    wireguard = FakeWireGuardManager()
    wireguard.peers[active.client_public_key] = (
        active.assigned_tunnel_ipv4,
        active.assigned_tunnel_ipv6,
    )
    repository.clients[(active.owner_uid, active.region_id, active.client_id)] = replace(
        active,
        region_id=REGION_ID,
    )

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert outcome.result.removed == 1
    assert wireguard.peers == {}


# --- desired_mesh_peers -----------------------------------------------------


def test_desired_mesh_peers_happy_path_applies_complete_non_overlapping_candidate():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-other-1"] = remote_region("us-other-1", public_key=FAKE_MESH_PUBLIC_KEY)

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert len(desired.peers) == 1
    peer = desired.peers[0]
    assert peer.public_key == FAKE_MESH_PUBLIC_KEY
    assert peer.endpoint_host == "wg.us-other-1.example.com"
    assert peer.allowed_network_v4 == "10.0.1.0/24"
    assert peer.allowed_network_v6 == "fd42:42:42:1::/64"
    assert len(desired.candidates) == 1
    assert desired.candidates[0].region_id == "us-other-1"
    assert desired.candidates[0].status == MeshPeerStatus.APPLIED


def test_desired_mesh_peers_excludes_self():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert desired.candidates == ()


def test_desired_mesh_peers_empty_when_local_mesh_disabled():
    repository = make_repository()  # enabled_region() defaults mesh_enabled to False
    repository.regions["us-other-1"] = remote_region("us-other-1", public_key=FAKE_MESH_PUBLIC_KEY)

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert desired.candidates == ()


def test_desired_mesh_peers_requires_literal_true_mesh_flags():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-other-1"] = remote_region(
        "us-other-1",
        public_key=FAKE_MESH_PUBLIC_KEY,
        mesh_enabled=cast(bool, "true"),
    )

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.mesh_enabled is True
    assert desired.peers == ()
    assert desired.candidates == ()

    repository.regions[REGION_ID] = mesh_ready_local_region(mesh_enabled=cast(bool, "true"))
    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.mesh_enabled is False
    assert desired.peers == ()
    assert desired.candidates == ()


def test_desired_mesh_peers_empty_when_local_region_doc_missing():
    repository = FakeRepository(local_region_id=REGION_ID)
    repository.regions["us-other-1"] = remote_region("us-other-1", public_key=FAKE_MESH_PUBLIC_KEY)

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert desired.candidates == ()


@pytest.mark.parametrize(
    "field, value",
    [
        ("public_key", ""),
        ("endpoint_hostname", ""),
        ("tunnel_network_v4", ""),
        ("tunnel_network_v6", ""),
        ("tunnel_network_v4", "not-a-cidr"),
        ("tunnel_network_v6", "not-a-cidr"),
        ("tunnel_network_v4", "10.0.3.0/25"),
        ("tunnel_network_v6", "fd42:42:42:3::/65"),
        ("tunnel_network_v4", "192.168.1.0/24"),  # outside the mesh aggregate
        ("tunnel_network_v6", "fd00:aaaa::/64"),  # outside the mesh aggregate
    ],
)
def test_desired_mesh_peers_marks_incomplete_candidates_skipped(field, value):
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    kwargs = {"public_key": FAKE_MESH_PUBLIC_KEY, field: value}
    repository.regions["us-other-1"] = remote_region("us-other-1", **kwargs)

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert len(desired.candidates) == 1
    assert desired.candidates[0].status == MeshPeerStatus.SKIPPED_INCOMPLETE


def test_desired_mesh_peers_skips_both_sides_of_an_overlap_pairwise_but_not_a_third_region():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-a-1"] = remote_region(
        "us-a-1",
        public_key=FAKE_MESH_PUBLIC_KEY,
        tunnel_network_v4="10.0.1.0/24",
        tunnel_network_v6="fd42:42:42:1::/64",
    )
    repository.regions["us-b-1"] = remote_region(
        "us-b-1",
        public_key=FAKE_MESH_PUBLIC_KEY_2,
        tunnel_network_v4="10.0.1.0/24",  # overlaps A
        tunnel_network_v6="fd42:42:42:1::/64",  # overlaps A
    )
    repository.regions["us-c-1"] = remote_region(
        "us-c-1",
        public_key=FAKE_MESH_PUBLIC_KEY_3,
        tunnel_network_v4="10.0.2.0/24",
        tunnel_network_v6="fd42:42:42:2::/64",
    )

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    statuses = {candidate.region_id: candidate.status for candidate in desired.candidates}
    assert statuses["us-a-1"] == MeshPeerStatus.SKIPPED_OVERLAP
    assert statuses["us-b-1"] == MeshPeerStatus.SKIPPED_OVERLAP
    assert statuses["us-c-1"] == MeshPeerStatus.APPLIED
    assert {peer.public_key for peer in desired.peers} == {FAKE_MESH_PUBLIC_KEY_3}


def test_desired_mesh_peers_preserves_independently_valid_fields_when_network_invalid():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-other-1"] = remote_region(
        "us-other-1",
        public_key=FAKE_MESH_PUBLIC_KEY,
        tunnel_network_v4="10.0.3.0/25",
    )

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    state = desired.candidates[0]
    assert state.status == MeshPeerStatus.SKIPPED_INCOMPLETE
    assert state.endpoint_hostname == "wg.us-other-1.example.com"
    assert state.endpoint_port == 51820
    assert state.public_key == FAKE_MESH_PUBLIC_KEY
    assert state.allowed_network_v6 == "fd42:42:42:1::/64"
    assert state.reason_code == "invalid-network-v4"


def test_desired_mesh_peers_missing_port_is_skipped_incomplete():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-other-1"] = remote_region(
        "us-other-1",
        public_key=FAKE_MESH_PUBLIC_KEY,
        wireguard_port=None,
    )

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert desired.candidates[0].status == MeshPeerStatus.SKIPPED_INCOMPLETE
    assert desired.candidates[0].endpoint_port is None
    assert desired.candidates[0].reason_code == "invalid-endpoint-port"


def test_desired_mesh_peers_skips_remote_that_overlaps_local():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()  # 10.0.0.0/24, fd42:42:42::/64
    repository.regions["us-other-1"] = remote_region(
        "us-other-1",
        public_key=FAKE_MESH_PUBLIC_KEY,
        tunnel_network_v4="10.0.0.0/24",  # overlaps local
        tunnel_network_v6="fd42:42:42:1::/64",
    )

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert desired.candidates[0].status == MeshPeerStatus.SKIPPED_OVERLAP


def test_desired_mesh_peers_local_overlap_guard_uses_settings_not_region_doc():
    # The local region doc's tunnelNetworkV4/V6 fields are missing/garbage, as
    # if the doc predates this deploy or was hand-edited/tampered. The guard
    # must still catch the overlap because it sources the local networks from
    # settings (the values that actually configure wg0), never the doc.
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region(
        tunnel_network_v4="",
        tunnel_network_v6="not-a-cidr",
    )
    repository.regions["us-other-1"] = remote_region(
        "us-other-1",
        public_key=FAKE_MESH_PUBLIC_KEY,
        tunnel_network_v4="10.0.0.0/24",  # overlaps settings' local network (10.0.0.0/24)
        tunnel_network_v6="fd42:42:42:1::/64",
    )

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert desired.candidates[0].status == MeshPeerStatus.SKIPPED_OVERLAP


def test_desired_mesh_peers_malformed_local_settings_skips_all_candidates(caplog):
    # A malformed settings.wg_tunnel_ipv4_cidr/_v6_cidr means the guard cannot
    # verify no local overlap - fail closed (skip every candidate, applying
    # none) rather than the old fail-open behavior, and log loudly.
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-other-1"] = remote_region("us-other-1", public_key=FAKE_MESH_PUBLIC_KEY)
    settings = make_settings(wg_tunnel_ipv4_cidr="not-a-cidr")

    with caplog.at_level("ERROR", logger="src.sync"):
        desired = desired_mesh_peers(repository, settings, repository.list_enabled_regions())

    assert desired.peers == ()
    assert desired.candidates[0].status == MeshPeerStatus.SKIPPED_OVERLAP
    assert "mesh_local_network_invalid" in caplog.text


def test_desired_mesh_peers_skips_pair_on_v6_only_overlap():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-a-1"] = remote_region(
        "us-a-1",
        public_key=FAKE_MESH_PUBLIC_KEY,
        tunnel_network_v4="10.0.1.0/24",
        tunnel_network_v6="fd42:42:42:9::/64",
    )
    repository.regions["us-b-1"] = remote_region(
        "us-b-1",
        public_key=FAKE_MESH_PUBLIC_KEY_2,
        tunnel_network_v4="10.0.2.0/24",  # distinct v4
        tunnel_network_v6="fd42:42:42:9::/64",  # same v6 as A
    )

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    statuses = {candidate.region_id: candidate.status for candidate in desired.candidates}
    assert statuses["us-a-1"] == MeshPeerStatus.SKIPPED_OVERLAP
    assert statuses["us-b-1"] == MeshPeerStatus.SKIPPED_OVERLAP


# --- run_sync mesh integration ---------------------------------------------


def test_run_sync_reconciles_mesh_peers_routes_and_writes_status():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-other-1"] = remote_region("us-other-1", public_key=FAKE_MESH_PUBLIC_KEY)
    wireguard = FakeWireGuardManager()

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert outcome.mesh_enabled is True
    assert outcome.result.mesh_applied == 1
    assert outcome.result.mesh_added == 1
    assert outcome.result.routes_added == 2
    assert wireguard.mesh_apply_calls == 1
    assert FAKE_MESH_PUBLIC_KEY in wireguard.mesh_peers
    mesh_enabled, peers = repository.mesh_status[REGION_ID]
    assert mesh_enabled is True
    assert peers[0].region_id == "us-other-1"
    assert peers[0].status == MeshPeerStatus.APPLIED


def test_run_sync_reads_region_state_once_per_pass_and_status_reflects_locked_read():
    # Regression for two findings at once: (3) list_enabled_regions() must be
    # read once per pass and shared between desired_mesh_peers and run_sync's
    # own classification sets, not queried twice; (2) the written status must
    # reflect the mesh_enabled value observed under the lock, not a later
    # re-read - simulated here by having get_region flip meshEnabled off on
    # any call after the first, as an operator toggle landing right after the
    # locked read would.
    class CountingRepository(FakeRepository):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.get_region_calls = 0
            self.list_enabled_regions_calls = 0

        def get_region(self, region_id: str):
            self.get_region_calls += 1
            region = super().get_region(region_id)
            if region is not None and region_id == self.local_region_id and self.get_region_calls > 1:
                return replace(region, mesh_enabled=False)
            return region

        def list_enabled_regions(self):
            self.list_enabled_regions_calls += 1
            return super().list_enabled_regions()

    repository = CountingRepository(local_region_id=REGION_ID)
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["us-other-1"] = remote_region("us-other-1", public_key=FAKE_MESH_PUBLIC_KEY)
    wireguard = FakeWireGuardManager()

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert repository.get_region_calls == 1
    assert repository.list_enabled_regions_calls == 1
    assert outcome.mesh_enabled is True
    assert repository.mesh_status[REGION_ID][0] is True


def test_run_sync_rollback_removes_existing_mesh_peer_and_routes_when_local_flag_is_false():
    repository = make_repository()  # mesh_enabled False by default
    repository.regions["us-other-1"] = remote_region("us-other-1", public_key=FAKE_MESH_PUBLIC_KEY)
    wireguard = FakeWireGuardManager()
    wireguard.mesh_peers[FAKE_MESH_PUBLIC_KEY] = MeshPeer(
        public_key=FAKE_MESH_PUBLIC_KEY,
        endpoint_host="wg.us-other-1.example.com",
        endpoint_port=51820,
        allowed_network_v4="10.0.1.0/24",
        allowed_network_v6="fd42:42:42:1::/64",
    )
    wireguard.routes[4]["10.0.1.0/24"] = "static"
    wireguard.routes[6]["fd42:42:42:1::/64"] = "static"

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert outcome.mesh_enabled is False
    assert outcome.result.mesh_removed == 1
    assert FAKE_MESH_PUBLIC_KEY not in wireguard.mesh_peers
    assert outcome.result.routes_removed == 2
    assert wireguard.routes[4] == {}
    assert wireguard.routes[6] == {}


def test_run_sync_write_mesh_status_failure_does_not_fail_sync():
    repository = make_repository()
    repository.write_mesh_status_error = RuntimeError("simulated Firestore write failure")
    wireguard = FakeWireGuardManager()

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert outcome.result.added == 0
    assert REGION_ID not in repository.mesh_status


def test_malformed_mesh_candidate_does_not_block_valid_client_or_mesh():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    active = activate(repository, reserve(repository), "client-public-key")
    repository.regions["bad"] = remote_region("bad", public_key=FAKE_MESH_PUBLIC_KEY, wireguard_port=None)
    repository.regions["good"] = remote_region("good", public_key=FAKE_MESH_PUBLIC_KEY_2)
    wireguard = FakeWireGuardManager()

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert outcome.result.added == 1
    assert active.client_public_key in wireguard.peers
    assert outcome.result.mesh_applied == 1
    states = {state.region_id: state for state in outcome.mesh_candidates}
    assert states["bad"].status == MeshPeerStatus.SKIPPED_INCOMPLETE
    assert states["bad"].reason_code == "invalid-endpoint-port"
    assert states["good"].status == MeshPeerStatus.APPLIED


def test_duplicate_mesh_keys_skip_all_candidates_and_keep_all_region_ids():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["a"] = remote_region("a", public_key=FAKE_MESH_PUBLIC_KEY)
    repository.regions["b"] = remote_region("b", public_key=FAKE_MESH_PUBLIC_KEY)

    desired = desired_mesh_peers(repository, make_settings(), repository.list_enabled_regions())

    assert desired.peers == ()
    assert [(state.region_id, state.reason_code) for state in desired.candidates] == [
        ("a", "duplicate-public-key"),
        ("b", "duplicate-public-key"),
    ]


def test_duplicate_mesh_key_stale_peer_and_routes_are_removed():
    repository = make_repository()
    repository.regions[REGION_ID] = mesh_ready_local_region()
    repository.regions["a"] = remote_region("a", public_key=FAKE_MESH_PUBLIC_KEY)
    repository.regions["b"] = remote_region("b", public_key=FAKE_MESH_PUBLIC_KEY)
    wireguard = FakeWireGuardManager()
    wireguard.mesh_peers[FAKE_MESH_PUBLIC_KEY] = MeshPeer(
        FAKE_MESH_PUBLIC_KEY, "wg.a.example.com", 51820, "10.0.1.0/24", "fd42:42:42:1::/64"
    )
    wireguard.routes[4]["10.0.1.0/24"] = "static"
    wireguard.routes[6]["fd42:42:42:1::/64"] = "static"

    outcome = run_sync(repository=repository, wireguard=wireguard, settings=make_settings())

    assert outcome.result.mesh_removed == 1
    assert outcome.result.routes_removed == 2
    assert FAKE_MESH_PUBLIC_KEY not in wireguard.mesh_peers


# --- audit log ---------------------------------------------------------------


def test_build_sync_audit_log_includes_mesh_section_and_omits_public_keys():
    result = PeerSyncResult(
        mesh_changes=(
            MeshPeerChange(
                public_key=FAKE_MESH_PUBLIC_KEY,
                action=PEER_ADDED,
                endpoint_host="wg.us-other-1.example.com",
                allowed_network_v4="10.0.1.0/24",
                allowed_network_v6="fd42:42:42:1::/64",
            ),
        ),
        mesh_applied_peers=(
            MeshPeer(
                public_key=FAKE_MESH_PUBLIC_KEY,
                endpoint_host="wg.us-other-1.example.com",
                endpoint_port=51820,
                allowed_network_v4="10.0.1.0/24",
                allowed_network_v6="fd42:42:42:1::/64",
            ),
        ),
        route_changes=(RouteChange("10.0.9.0/24", PEER_REMOVED, reclaimed=True),),
    )

    log = build_sync_audit_log(
        region_id=REGION_ID,
        synced_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        result=result,
        clients_by_key={},
        mesh_enabled=True,
        mesh_candidates=(
            MeshPeerState(
                region_id="us-other-1",
                endpoint_hostname="wg.us-other-1.example.com",
                public_key=FAKE_MESH_PUBLIC_KEY,
                allowed_network_v4="10.0.1.0/24",
                allowed_network_v6="fd42:42:42:1::/64",
                status=MeshPeerStatus.APPLIED,
            ),
        ),
        mesh_region_by_key={FAKE_MESH_PUBLIC_KEY: "us-other-1"},
    )

    assert "mesh: enabled=True" in log
    assert "regionId=us-other-1" in log
    assert "status=applied" in log
    assert "cidr=10.0.9.0/24" in log
    assert "reclaimed=true" in log
    assert FAKE_MESH_PUBLIC_KEY not in log
    assert "\x1b" not in log

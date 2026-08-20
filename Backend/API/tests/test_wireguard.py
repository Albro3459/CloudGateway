import logging
import socket
import threading
import time

import pytest

from src import wireguard
from src.enums import OperationResult
from src.errors import SyncInProgressError, WireGuardApplyFailedError
from src.wireguard import (
    LocalWireGuardManager,
    MeshPeer,
    _parse_dump_snapshots,
    _resolve_endpoint_addresses,
)

from .fakes import (
    FAKE_MESH_PUBLIC_KEY,
    FAKE_MESH_PUBLIC_KEY_2,
    FAKE_PRIVATE_KEY,
    FAKE_PUBLIC_KEY,
    FAKE_PUBLIC_KEY_2,
    FAKE_SERVER_PUBLIC_KEY,
    FAKE_UNKNOWN_PUBLIC_KEY,
    FakeWireGuardCommandRunner,
)

TUNNEL_V4 = "10.0.0.2/32"
TUNNEL_V6 = "fd42:42:42::2/128"


def make_manager(
    tmp_path,
    runner,
    *,
    endpoint_host="wg.us-test-1.example.com",
    tunnel_network_v4="10.0.0.0/24",
    tunnel_network_v6="fd42:42:42::/64",
    endpoint_resolver=None,
):
    return LocalWireGuardManager(
        interface="wg0",
        lock_path=str(tmp_path / "cloudgateway-wireguard.lock"),
        server_public_key=FAKE_SERVER_PUBLIC_KEY,
        endpoint_host=endpoint_host,
        listen_port=51820,
        dns_ipv4="10.0.0.1",
        dns_ipv6="fd42:42:42::1",
        tunnel_network_v4=tunnel_network_v4,
        tunnel_network_v6=tunnel_network_v6,
        command_runner=runner,
        endpoint_resolver=endpoint_resolver,
    )


def make_mesh_peer(
    *,
    public_key=FAKE_MESH_PUBLIC_KEY,
    endpoint_host="wg.us-other-1.example.com",
    endpoint_port=51820,
    allowed_network_v4="10.0.1.0/24",
    allowed_network_v6="fd42:42:42:1::/64",
) -> MeshPeer:
    return MeshPeer(
        public_key=public_key,
        endpoint_host=endpoint_host,
        endpoint_port=endpoint_port,
        allowed_network_v4=allowed_network_v4,
        allowed_network_v6=allowed_network_v6,
    )


def mesh_set_calls(runner):
    return [call for call in runner.calls if call.args[:2] == ("wg", "set") and "endpoint" in call.args]


def test_generate_keypair_runs_wg_without_shell(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    keypair = manager.generate_keypair()

    assert keypair.private_key == FAKE_PRIVATE_KEY
    assert keypair.public_key == FAKE_PUBLIC_KEY
    assert runner.calls[0].args == ("wg", "genkey")
    assert runner.calls[1].args == ("wg", "pubkey")
    assert runner.calls[1].input == FAKE_PRIVATE_KEY
    assert all(call.shell is False for call in runner.calls)


def test_render_client_config_uses_endpoint_hostname(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    config = manager.render_client_config(
        private_key=FAKE_PRIVATE_KEY,
        tunnel_ipv4=TUNNEL_V4,
        tunnel_ipv6=TUNNEL_V6,
    )

    assert config == (
        "[Interface]\n"
        f"PrivateKey = {FAKE_PRIVATE_KEY}\n"
        f"Address = {TUNNEL_V4}, {TUNNEL_V6}\n"
        "DNS = 10.0.0.1, fd42:42:42::1\n"
        "\n"
        "[Peer]\n"
        f"PublicKey = {FAKE_SERVER_PUBLIC_KEY}\n"
        "Endpoint = wg.us-test-1.example.com:51820\n"
        "AllowedIPs = 0.0.0.0/0, ::/0\n"
        "PersistentKeepalive = 25\n"
    )


def test_render_client_config_accepts_ip_literal_endpoint(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner, endpoint_host="203.0.113.10")

    config = manager.render_client_config(
        private_key=FAKE_PRIVATE_KEY,
        tunnel_ipv4=TUNNEL_V4,
        tunnel_ipv6=TUNNEL_V6,
    )

    assert "Endpoint = 203.0.113.10:51820\n" in config


def test_rejects_invalid_endpoint_host(tmp_path):
    runner = FakeWireGuardCommandRunner()

    with pytest.raises(WireGuardApplyFailedError, match="endpoint host"):
        make_manager(tmp_path, runner, endpoint_host="bad host name")


def test_add_peer_issues_single_wg_set_command(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    manager.add_peer(public_key=FAKE_PUBLIC_KEY, tunnel_ipv4=TUNNEL_V4, tunnel_ipv6=TUNNEL_V6)

    assert runner.peers == {FAKE_PUBLIC_KEY: f"{TUNNEL_V4},{TUNNEL_V6}"}
    assert runner.calls[-1].args == (
        "wg",
        "set",
        "wg0",
        "peer",
        FAKE_PUBLIC_KEY,
        "allowed-ips",
        f"{TUNNEL_V4},{TUNNEL_V6}",
        "persistent-keepalive",
        "25",
    )
    assert all(call.shell is False for call in runner.calls)


def test_remove_existing_peer_returns_success(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)

    result = manager.remove_peer(public_key=FAKE_PUBLIC_KEY)

    assert result == OperationResult.SUCCESS
    assert runner.peers == {}
    assert [call.args[:2] for call in runner.calls] == [("wg", "show"), ("wg", "set")]
    assert runner.calls[-1].args[-1] == "remove"


def test_remove_missing_peer_is_noop_without_mutation(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    result = manager.remove_peer(public_key=FAKE_PUBLIC_KEY)

    assert result == OperationResult.NOOP
    assert [call.args[:2] for call in runner.calls] == [("wg", "show")]


def test_current_peers_parses_dump_and_skips_interface_line(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    runner.peers[FAKE_PUBLIC_KEY_2] = ""
    manager = make_manager(tmp_path, runner)

    peers = manager.current_peers()

    assert peers == {
        FAKE_PUBLIC_KEY: frozenset({TUNNEL_V4, TUNNEL_V6}),
        FAKE_PUBLIC_KEY_2: frozenset(),
    }
    assert FAKE_PRIVATE_KEY not in str(peers)


def test_peer_snapshot_parses_ipv4_ipv6_absent_endpoint_multiple_allowed_ips_and_keepalive():
    output = (
        f"{FAKE_PRIVATE_KEY}\t{FAKE_SERVER_PUBLIC_KEY}\t51820\toff\n"
        f"{FAKE_PUBLIC_KEY}\t(none)\t198.51.100.10:51820\t10.0.1.0/24,fd42:42:42:1::/64\t0\t0\t0\t25\n"
        f"{FAKE_PUBLIC_KEY_2}\t(none)\t[2001:db8::10]:51821\t10.0.2.0/24,fd42:42:42:2::/64\t0\t0\t0\t(none)\n"
        f"{FAKE_UNKNOWN_PUBLIC_KEY}\t(none)\t(none)\t(none)\t0\t0\t0\t0\n"
    )

    snapshots = _parse_dump_snapshots(output)

    assert snapshots[FAKE_PUBLIC_KEY].endpoint_addresses == frozenset({"198.51.100.10"})
    assert snapshots[FAKE_PUBLIC_KEY].endpoint_port == 51820
    assert snapshots[FAKE_PUBLIC_KEY].allowed_ips == frozenset({"10.0.1.0/24", "fd42:42:42:1::/64"})
    assert snapshots[FAKE_PUBLIC_KEY].persistent_keepalive == 25
    assert snapshots[FAKE_PUBLIC_KEY_2].endpoint_addresses == frozenset({"2001:db8::10"})
    assert snapshots[FAKE_PUBLIC_KEY_2].endpoint_port == 51821
    assert snapshots[FAKE_PUBLIC_KEY_2].persistent_keepalive is None
    assert snapshots[FAKE_UNKNOWN_PUBLIC_KEY].endpoint_addresses == frozenset()


def test_sync_adds_updates_and_removes_to_match_desired(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY] = "10.0.0.9/32,fd42:42:42::9/128"
    runner.peers[FAKE_SERVER_PUBLIC_KEY] = "10.0.0.3/32,fd42:42:42::3/128"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers(
        {
            FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6),
            FAKE_PUBLIC_KEY_2: ("10.0.0.4/32", "fd42:42:42::4/128"),
        }
    )

    assert (result.added, result.updated, result.removed) == (1, 1, 1)
    assert runner.peers == {
        FAKE_PUBLIC_KEY: f"{TUNNEL_V4},{TUNNEL_V6}",
        FAKE_PUBLIC_KEY_2: "10.0.0.4/32,fd42:42:42::4/128",
    }


def test_sync_with_matching_state_is_a_noop(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6)})

    assert (result.added, result.updated, result.removed) == (0, 0, 0)
    # The route sweep always reads the table (ip -j route show), but no mutating
    # command (wg set/peer/remove, ip route replace/del) should ever run.
    assert [call.args[:2] for call in runner.calls] == [
        ("wg", "show"),
        ("ip", "-j"),
        ("ip", "-j"),
    ]


def test_sync_empty_desired_removes_all_peers(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({})

    assert (result.added, result.updated, result.removed) == (0, 0, 1)
    assert runner.peers == {}


def test_wg_set_failure_raises_transient_error_with_static_message(tmp_path):
    runner = FakeWireGuardCommandRunner(
        fail_set_count=1,
        failure_stderr=f"PrivateKey = {FAKE_PRIVATE_KEY}",
    )
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="peer apply failed") as exc_info:
        manager.add_peer(public_key=FAKE_PUBLIC_KEY, tunnel_ipv4=TUNNEL_V4, tunnel_ipv6=TUNNEL_V6)

    assert exc_info.value.transient is True
    assert FAKE_PRIVATE_KEY not in str(exc_info.value)


def test_wg_show_failure_raises_controlled_error(tmp_path):
    runner = FakeWireGuardCommandRunner(fail_show_count=1)
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="state read failed"):
        manager.current_peers()


def test_rejects_invalid_peer_inputs_before_running_commands(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError):
        manager.add_peer(public_key="not-a-public-key", tunnel_ipv4=TUNNEL_V4, tunnel_ipv6=TUNNEL_V6)
    with pytest.raises(WireGuardApplyFailedError):
        manager.add_peer(public_key=FAKE_PUBLIC_KEY, tunnel_ipv4="10.0.0.2/24", tunnel_ipv6=TUNNEL_V6)
    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({"not-a-public-key": (TUNNEL_V4, TUNNEL_V6)})
    assert runner.calls == []


def test_lock_is_exclusive_and_reusable(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    with manager.lock():
        pass
    with manager.lock():
        manager.add_peer(public_key=FAKE_PUBLIC_KEY, tunnel_ipv4=TUNNEL_V4, tunnel_ipv6=TUNNEL_V6)

    assert (tmp_path / "cloudgateway-wireguard.lock").exists()


def test_non_blocking_lock_sheds_while_held_and_recovers_after_release(tmp_path):
    # flock is per open file description, so a second manager on the same path
    # contends exactly as a second process would.
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    other = make_manager(tmp_path, runner)

    with manager.lock():
        with pytest.raises(SyncInProgressError):
            with other.lock(blocking=False):
                pass

    with other.lock(blocking=False):
        pass


def test_command_timeout_is_reported_as_a_transient_failure(tmp_path):
    runner = FakeWireGuardCommandRunner(timeout_command_prefixes={("wg", "show")})
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError) as exc_info:
        manager.current_peers()

    assert exc_info.value.transient is True


# --- Mesh peer validation -------------------------------------------------


def test_constructor_rejects_invalid_tunnel_networks(tmp_path):
    runner = FakeWireGuardCommandRunner()
    with pytest.raises(WireGuardApplyFailedError):
        make_manager(tmp_path, runner, tunnel_network_v4="10.0.0.5/24")  # host bits set
    with pytest.raises(WireGuardApplyFailedError):
        make_manager(tmp_path, runner, tunnel_network_v4="10.1.0.0/25")  # wrong width
    with pytest.raises(WireGuardApplyFailedError):
        make_manager(tmp_path, runner, tunnel_network_v6="10.0.0.0/24")  # wrong family
    with pytest.raises(WireGuardApplyFailedError):
        make_manager(tmp_path, runner, tunnel_network_v6="fd42:42:42:2::/65")  # wrong width


def test_constructor_requires_dns_to_be_first_host_of_each_tunnel_network(tmp_path):
    runner = FakeWireGuardCommandRunner()

    with pytest.raises(WireGuardApplyFailedError):
        LocalWireGuardManager(
            interface="wg0",
            lock_path=str(tmp_path / "cloudgateway-wireguard.lock"),
            server_public_key=FAKE_SERVER_PUBLIC_KEY,
            endpoint_host="wg.us-test-1.example.com",
            listen_port=51820,
            dns_ipv4="10.0.0.2",
            dns_ipv6="fd42:42:42::1",
            tunnel_network_v4="10.0.0.0/24",
            tunnel_network_v6="fd42:42:42::/64",
            command_runner=runner,
        )


@pytest.mark.parametrize(
    "field, value",
    [
        ("allowed_network_v4", "fd42:42:42:1::/64"),  # wrong family (v6 value in v4 field)
        ("allowed_network_v4", "10.0.1.5/24"),  # host bits set
        ("allowed_network_v4", "not-a-network"),  # non-network value
        ("allowed_network_v4", "192.168.1.0/24"),  # outside the mesh aggregate
        ("allowed_network_v6", "10.0.1.0/24"),  # wrong family (v4 value in v6 field)
        ("allowed_network_v6", "fd42:42:42:1::5/64"),  # host bits set
        ("allowed_network_v6", "fd00:aaaa::/64"),  # outside the mesh aggregate
        ("public_key", "not-a-public-key"),
        ("endpoint_host", "bad host name"),
        ("endpoint_port", 0),
        ("endpoint_port", 70000),
    ],
)
def test_sync_peers_rejects_invalid_mesh_peer_fields(tmp_path, field, value):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer(**{field: value})

    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({}, mesh=[peer])
    assert mesh_set_calls(runner) == []


@pytest.mark.parametrize(
    "field, value",
    [
        ("allowed_network_v4", "10.0.0.0/24"),  # identical to the local tunnel network
        ("allowed_network_v6", "fd42:42:42::/64"),
    ],
)
def test_sync_peers_rejects_mesh_network_overlapping_the_local_tunnel_network(tmp_path, field, value):
    # Cryptokey routing is exclusive, so this range would be taken away from every
    # local client peer. sync.py catches it first; the kernel-facing layer must too.
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({}, mesh=[make_mesh_peer(**{field: value})])
    assert mesh_set_calls(runner) == []


@pytest.mark.parametrize(
    "network_v4, network_v6",
    [
        ("10.0.1.0/24", "fd42:42:42:2::/64"),  # v4 collides with the first peer
        ("10.0.2.0/24", "fd42:42:42:1::/64"),  # v6-only collision
    ],
)
def test_sync_peers_rejects_mesh_networks_overlapping_each_other(tmp_path, network_v4, network_v6):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    other = make_mesh_peer(
        public_key=FAKE_MESH_PUBLIC_KEY_2,
        allowed_network_v4=network_v4,
        allowed_network_v6=network_v6,
    )

    # Both sides of a collision are dropped, the way sync.desired_mesh_peers skips
    # them upstream: neither range is safe to claim.
    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({}, mesh=[make_mesh_peer(), other])
    assert mesh_set_calls(runner) == []


def test_sync_peers_rejects_duplicate_mesh_public_keys(tmp_path):
    # The plan requires duplicate server public keys to be rejected: the second
    # `wg set` would steal the first peer's ranges while both count as applied.
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    duplicate = make_mesh_peer(allowed_network_v4="10.0.2.0/24", allowed_network_v6="fd42:42:42:2::/64")

    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({}, mesh=[make_mesh_peer(), duplicate])
    assert mesh_set_calls(runner) == []


def test_sync_peers_accepts_valid_mesh_peer_cidrs(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    result = manager.sync_peers({}, mesh=[peer])

    assert result.mesh_applied == 1
    assert result.mesh_added == 1


def test_client_tunnel_ip_still_requires_exact_host_prefix(tmp_path):
    # Regression guard: mesh network validation must not loosen client validation.
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError):
        manager.add_peer(public_key=FAKE_PUBLIC_KEY, tunnel_ipv4="10.0.0.0/24", tunnel_ipv6=TUNNEL_V6)
    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({FAKE_PUBLIC_KEY: ("10.0.0.0/24", TUNNEL_V6)})


# --- Mesh peer apply / re-apply -------------------------------------------


def test_mesh_peer_apply_issues_exact_wg_set_argv(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    manager.sync_peers({}, mesh=[peer])

    applied = mesh_set_calls(runner)
    assert len(applied) == 1
    assert applied[0].args == (
        "wg",
        "set",
        "wg0",
        "peer",
        FAKE_MESH_PUBLIC_KEY,
        "endpoint",
        "wg.us-other-1.example.com:51820",
        "allowed-ips",
        "10.0.1.0/24,fd42:42:42:1::/64",
        "persistent-keepalive",
        "25",
    )


def test_mesh_peer_is_reapplied_every_pass(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    first = manager.sync_peers({}, mesh=[peer])
    second = manager.sync_peers({}, mesh=[peer])

    assert len(mesh_set_calls(runner)) == 2
    assert first.mesh_added == 1
    assert second.mesh_added == 0  # already live: re-applied, but not counted as newly added
    assert second.mesh_applied == 1


def test_mesh_peer_updated_only_for_live_drift(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(
        tmp_path,
        runner,
        endpoint_resolver=lambda _host: ("203.0.113.10", "203.0.113.11"),
    )
    peer = make_mesh_peer()

    first = manager.sync_peers({}, mesh=[peer])
    # A real wg dump reports the resolved endpoint address, not the hostname
    # passed to wg set. One live address matching the DNS answer set is current.
    runner.peer_endpoints[FAKE_MESH_PUBLIC_KEY] = "203.0.113.10:51820"
    stable = manager.sync_peers({}, mesh=[peer])

    runner.peer_endpoints[FAKE_MESH_PUBLIC_KEY] = "203.0.113.12:51820"
    runner.peer_keepalives[FAKE_MESH_PUBLIC_KEY] = 10
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.99.0/24,fd42:42:42:99::/64"
    repaired = manager.sync_peers({}, mesh=[peer])

    assert first.mesh_added == 1
    assert first.mesh_updated == 0
    assert stable.mesh_updated == 0
    assert repaired.mesh_updated == 1
    assert repaired.mesh_applied == 1


# --- Union sync: clients + mesh -------------------------------------------


def test_mesh_peers_survive_client_sync_and_unknown_peer_is_removed(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.1.0/24,fd42:42:42:1::/64"
    runner.peers[FAKE_UNKNOWN_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    result = manager.sync_peers(
        {FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6)},
        mesh=[peer],
        known_region_keys=[FAKE_MESH_PUBLIC_KEY],
    )

    assert result.added == 1  # FAKE_PUBLIC_KEY
    assert result.removed == 1  # FAKE_UNKNOWN_PUBLIC_KEY, classified as a client removal
    assert result.mesh_removed == 0
    assert runner.peers[FAKE_MESH_PUBLIC_KEY] == "10.0.1.0/24,fd42:42:42:1::/64"
    assert FAKE_UNKNOWN_PUBLIC_KEY not in runner.peers
    assert FAKE_PUBLIC_KEY in runner.peers


def test_protected_client_key_survives_removal_sweep(tmp_path):
    # A degraded Firebase client record (invalid tunnel IP) is dropped from the
    # desired set upstream, but its already-live peer must not be torn down as
    # unknown - sync.py threads its key through as protected instead.
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY_2] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, protected_client_keys=[FAKE_PUBLIC_KEY_2])

    assert result.removed == 0
    assert FAKE_PUBLIC_KEY_2 in runner.peers


def test_malformed_protected_client_key_protects_nothing(tmp_path):
    # A key that is not a syntactically valid WireGuard key cannot correspond to
    # a real live peer, so it must not accidentally shield an unrelated one.
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_UNKNOWN_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, protected_client_keys=["not-a-valid-key"])

    assert result.removed == 1
    assert FAKE_UNKNOWN_PUBLIC_KEY not in runner.peers


def test_mesh_peer_dropped_from_desired_set_is_removed_as_mesh_not_client(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.1.0/24,fd42:42:42:1::/64"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, mesh=[], known_region_keys=[FAKE_MESH_PUBLIC_KEY])

    assert result.removed == 0  # never treated as an unknown client peer
    assert result.mesh_removed == 1
    assert FAKE_MESH_PUBLIC_KEY not in runner.peers


def test_rejected_mesh_candidate_set_still_removes_revoked_client_peers(tmp_path):
    # Whole-set rejection must not abort the pass before removal: a revoked client's
    # peer stays on the interface until the operator fixes unrelated mesh metadata
    # otherwise. The rejection still surfaces once the pass is reconciled.
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_UNKNOWN_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)
    duplicate = make_mesh_peer(allowed_network_v4="10.0.2.0/24", allowed_network_v6="fd42:42:42:2::/64")

    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({}, mesh=[make_mesh_peer(), duplicate])

    assert FAKE_UNKNOWN_PUBLIC_KEY not in runner.peers
    assert mesh_set_calls(runner) == []


def test_rejected_mesh_candidate_does_not_block_the_valid_ones(tmp_path):
    # Per-candidate isolation: one malformed candidate must not cost the mesh its
    # other links for the whole pass.
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    valid = make_mesh_peer()
    invalid = make_mesh_peer(public_key=FAKE_MESH_PUBLIC_KEY_2, endpoint_host="bad host name")

    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({}, mesh=[valid, invalid])

    applied = mesh_set_calls(runner)
    assert len(applied) == 1
    assert applied[0].args[4] == FAKE_MESH_PUBLIC_KEY


def test_known_region_key_without_desired_mesh_peer_is_classified_as_mesh_removal(tmp_path):
    # A region dropped from the mesh (meshEnabled flipped off) still has its key
    # supplied via known_region_keys so its removal is counted correctly, not as
    # a stray unknown client peer.
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_MESH_PUBLIC_KEY_2] = "10.0.2.0/24,fd42:42:42:2::/64"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, known_region_keys=[FAKE_MESH_PUBLIC_KEY_2])

    assert result.mesh_removed == 1
    assert result.removed == 0


# --- Route reconciliation by sweep ----------------------------------------


def test_route_reconcile_adds_desired_mesh_routes(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    result = manager.sync_peers({}, mesh=[peer])

    assert result.routes_added == 2  # v4 + v6
    assert runner.routes[4]["10.0.1.0/24"] == "static"
    assert runner.routes[6]["fd42:42:42:1::/64"] == "static"


def test_route_reconcile_does_not_recount_already_present_route(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.routes[4]["10.0.1.0/24"] = "static"
    runner.routes[6]["fd42:42:42:1::/64"] = "static"
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    result = manager.sync_peers({}, mesh=[peer])

    assert result.routes_added == 0
    assert result.routes_removed == 0


def test_route_sweep_removes_stale_in_aggregate_route(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.routes[4]["10.0.9.0/24"] = "static"  # no longer a desired mesh CIDR
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, mesh=[], known_mesh_networks=["10.0.9.0/24"])

    assert result.routes_removed == 1
    assert "10.0.9.0/24" not in runner.routes[4]
    assert result.route_changes[0].reclaimed is False  # known to a current region doc


def test_route_sweep_logs_and_flags_reclaimed_route(tmp_path, caplog):
    runner = FakeWireGuardCommandRunner()
    runner.routes[4]["10.0.9.0/24"] = "static"  # stale and unknown to any region doc
    manager = make_manager(tmp_path, runner)

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        result = manager.sync_peers({}, mesh=[])

    assert result.routes_removed == 1
    assert result.route_changes[0].reclaimed is True
    assert "mesh_route_reclaimed" in caplog.text


def test_route_sweep_never_touches_local_on_link_network(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)
    runner.routes[4][manager.tunnel_network_v4] = "static"
    runner.routes[6][manager.tunnel_network_v6] = "static"

    result = manager.sync_peers({}, mesh=[])

    assert result.routes_removed == 0
    assert manager.tunnel_network_v4 in runner.routes[4]
    assert manager.tunnel_network_v6 in runner.routes[6]


def test_route_sweep_never_touches_proto_kernel_route(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.routes[4]["10.0.9.0/24"] = "kernel"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, mesh=[])

    assert result.routes_removed == 0
    assert "10.0.9.0/24" in runner.routes[4]


def test_route_sweep_never_touches_out_of_aggregate_route(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.routes[4]["192.168.50.0/24"] = "static"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, mesh=[])

    assert result.routes_removed == 0
    assert "192.168.50.0/24" in runner.routes[4]


# --- Partial mutation recovery ---------------------------------------------


def test_mesh_peer_apply_failure_leaves_no_false_change_and_next_sync_converges(tmp_path):
    runner = FakeWireGuardCommandRunner(fail_set_count=1)
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    with pytest.raises(WireGuardApplyFailedError, match="peer apply failed"):
        manager.sync_peers({}, mesh=[peer])

    assert runner.peers == {}
    result = manager.sync_peers({}, mesh=[peer])

    assert result.mesh_added == 1
    assert runner.peers == {FAKE_MESH_PUBLIC_KEY: "10.0.1.0/24,fd42:42:42:1::/64"}
    assert runner.routes[4] == {"10.0.1.0/24": "static"}
    assert runner.routes[6] == {"fd42:42:42:1::/64": "static"}


def test_mesh_apply_failure_still_removes_stale_peer_and_applies_other_candidates(tmp_path, caplog):
    # `wg set peer ... endpoint <host>:<port>` resolves the hostname itself, so a broken
    # DNS record in one region must not keep a revoked client's peer on the interface.
    runner = FakeWireGuardCommandRunner(fail_set_endpoint_hosts={"wg.us-broken-1.example.com"})
    runner.peers[FAKE_UNKNOWN_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)
    broken = make_mesh_peer(endpoint_host="wg.us-broken-1.example.com")
    healthy = make_mesh_peer(
        public_key=FAKE_MESH_PUBLIC_KEY_2,
        endpoint_host="wg.us-other-2.example.com",
        allowed_network_v4="10.0.2.0/24",
        allowed_network_v6="fd42:42:42:2::/64",
    )

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        with pytest.raises(WireGuardApplyFailedError, match="mesh peer apply failed"):
            manager.sync_peers({}, mesh=[broken, healthy])

    assert "mesh_peer_apply_failed" in caplog.text
    # The failed pass raises instead of returning its result, so the changes that did
    # land are only visible in this log line.
    partial = [record for record in caplog.records if record.message == "peer_sync_partial"]
    assert len(partial) == 1
    assert partial[0].event_fields["removed"] == 1
    assert partial[0].event_fields["meshApplied"] == 1
    assert FAKE_UNKNOWN_PUBLIC_KEY not in runner.peers  # stale client peer still reconciled
    assert FAKE_MESH_PUBLIC_KEY_2 in runner.peers  # healthy candidate still applied
    assert FAKE_MESH_PUBLIC_KEY not in runner.peers
    # No route for the candidate that failed to apply.
    assert runner.routes[4] == {"10.0.2.0/24": "static"}
    assert runner.routes[6] == {"fd42:42:42:2::/64": "static"}


def test_mesh_apply_failure_keeps_the_route_of_a_still_correct_live_peer(tmp_path):
    # A working peer whose re-apply failed for a non-DNS reason must not lose its
    # route until the next successful pass; it is still carrying traffic.
    runner = FakeWireGuardCommandRunner(fail_set_count=1)
    peer = make_mesh_peer()
    runner.peers[FAKE_MESH_PUBLIC_KEY] = f"{peer.allowed_network_v4},{peer.allowed_network_v6}"
    runner.routes[4][peer.allowed_network_v4] = "static"
    runner.routes[6][peer.allowed_network_v6] = "static"
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="mesh peer apply failed"):
        manager.sync_peers({}, mesh=[peer])

    assert runner.routes[4] == {peer.allowed_network_v4: "static"}
    assert runner.routes[6] == {peer.allowed_network_v6: "static"}


def test_mesh_apply_failure_drops_the_route_when_the_live_peer_ranges_differ(tmp_path):
    # The live peer carries a different range, so the desired route would blackhole.
    runner = FakeWireGuardCommandRunner(fail_set_count=1)
    peer = make_mesh_peer()
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.9.0/24,fd42:42:42:9::/64"
    runner.routes[4][peer.allowed_network_v4] = "static"
    runner.routes[6][peer.allowed_network_v6] = "static"
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="mesh peer apply failed"):
        manager.sync_peers({}, mesh=[peer])

    assert runner.routes == {4: {}, 6: {}}


def test_mesh_apply_failure_next_sync_converges_once_the_endpoint_resolves(tmp_path):
    runner = FakeWireGuardCommandRunner(fail_set_endpoint_hosts={"wg.us-broken-1.example.com"})
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer(endpoint_host="wg.us-broken-1.example.com")

    with pytest.raises(WireGuardApplyFailedError, match="mesh peer apply failed"):
        manager.sync_peers({}, mesh=[peer])

    runner.fail_set_endpoint_hosts.clear()
    result = manager.sync_peers({}, mesh=[peer])

    assert result.mesh_applied == 1
    assert result.mesh_added == 1
    assert result.routes_added == 2


def test_mesh_peer_removal_failure_during_rollback_converges_next_sync(tmp_path):
    runner = FakeWireGuardCommandRunner(fail_set_count=1)
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.1.0/24,fd42:42:42:1::/64"
    runner.routes[4]["10.0.1.0/24"] = "static"
    runner.routes[6]["fd42:42:42:1::/64"] = "static"
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="peer removal failed"):
        manager.sync_peers({}, mesh=[], known_region_keys=[FAKE_MESH_PUBLIC_KEY])

    assert FAKE_MESH_PUBLIC_KEY in runner.peers
    result = manager.sync_peers({}, mesh=[], known_region_keys=[FAKE_MESH_PUBLIC_KEY])

    assert result.mesh_removed == 1
    assert runner.peers == {}
    assert runner.routes == {4: {}, 6: {}}


def test_peer_failure_stays_primary_when_route_reconciliation_also_fails(tmp_path, caplog):
    # Two failures in one pass: the route throw used to exit before
    # PEER_SYNC_PARTIAL and replace the earlier peer failure at the caller
    # boundary, so the peer failure disappeared entirely.
    runner = FakeWireGuardCommandRunner(
        fail_set_endpoint_hosts={"wg.us-broken-1.example.com"},
        fail_route_replace_versions={6},
    )
    manager = make_manager(tmp_path, runner)
    broken = make_mesh_peer(endpoint_host="wg.us-broken-1.example.com")
    healthy = make_mesh_peer(
        public_key=FAKE_MESH_PUBLIC_KEY_2,
        endpoint_host="wg.us-other-2.example.com",
        allowed_network_v4="10.0.2.0/24",
        allowed_network_v6="fd42:42:42:2::/64",
    )

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        with pytest.raises(WireGuardApplyFailedError, match="mesh peer apply failed"):
            manager.sync_peers({}, mesh=[broken, healthy])

    partial = [record for record in caplog.records if record.message == "peer_sync_partial"]
    assert len(partial) == 1
    assert partial[0].event_fields["meshApplied"] == 1
    assert partial[0].event_fields["routeReconciliationFailed"] is True
    # The route failure is not the raised error, so it needs its own record.
    assert "mesh_route_reconcile_failed" in caplog.text


def test_route_only_failure_is_primary_and_still_emits_the_partial_event(tmp_path, caplog):
    runner = FakeWireGuardCommandRunner(fail_route_replace_versions={6})
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        with pytest.raises(WireGuardApplyFailedError, match="route apply failed"):
            manager.sync_peers({}, mesh=[peer])

    partial = [record for record in caplog.records if record.message == "peer_sync_partial"]
    assert len(partial) == 1
    assert partial[0].event_fields["meshApplied"] == 1
    assert partial[0].event_fields["routeReconciliationFailed"] is True
    assert "mesh_route_reconcile_failed" in caplog.text


def test_peer_only_failure_reports_no_route_reconciliation_failure(tmp_path, caplog):
    runner = FakeWireGuardCommandRunner(fail_set_endpoint_hosts={"wg.us-broken-1.example.com"})
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer(endpoint_host="wg.us-broken-1.example.com")

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        with pytest.raises(WireGuardApplyFailedError, match="mesh peer apply failed"):
            manager.sync_peers({}, mesh=[peer])

    partial = [record for record in caplog.records if record.message == "peer_sync_partial"]
    assert len(partial) == 1
    assert partial[0].event_fields["routeReconciliationFailed"] is False
    assert "mesh_route_reconcile_failed" not in caplog.text


def test_client_apply_failure_keeps_the_earlier_change_and_finishes_the_pass(tmp_path, caplog):
    # A failed client apply used to raise out of sync_peers immediately, so the
    # removal sweep, the mesh phase, the route sweep, and PEER_SYNC_PARTIAL never
    # ran for that pass.
    runner = FakeWireGuardCommandRunner(fail_set_peer_keys={FAKE_PUBLIC_KEY_2})
    runner.peers[FAKE_UNKNOWN_PUBLIC_KEY] = "10.0.0.9/32,fd42:42:42::9/128"
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        with pytest.raises(WireGuardApplyFailedError) as excinfo:
            manager.sync_peers(
                {
                    FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6),
                    FAKE_PUBLIC_KEY_2: ("10.0.0.4/32", "fd42:42:42::4/128"),
                },
                mesh=[peer],
            )

    assert str(excinfo.value) == "WireGuard peer apply failed."
    # The healthy client landed, the stale peer was still swept, and the mesh peer
    # and its routes still converged behind the failure.
    assert runner.peers == {
        FAKE_PUBLIC_KEY: f"{TUNNEL_V4},{TUNNEL_V6}",
        FAKE_MESH_PUBLIC_KEY: "10.0.1.0/24,fd42:42:42:1::/64",
    }
    assert runner.routes[4] == {"10.0.1.0/24": "static"}
    assert runner.routes[6] == {"fd42:42:42:1::/64": "static"}
    partial = [record for record in caplog.records if record.message == "peer_sync_partial"]
    assert len(partial) == 1
    assert partial[0].event_fields["added"] == 1
    assert partial[0].event_fields["removed"] == 1
    assert partial[0].event_fields["meshApplied"] == 1
    assert partial[0].event_fields["clientApplyFailed"] == 1
    assert "client_peer_apply_failed" in caplog.text
    # The failed peer is never counted as applied and never named in the logs.
    assert FAKE_PUBLIC_KEY_2 not in caplog.text
    assert "10.0.0.4" not in caplog.text


def test_removal_failure_after_partial_progress_still_reconciles_the_rest(tmp_path, caplog):
    runner = FakeWireGuardCommandRunner(fail_remove_peer_keys={FAKE_UNKNOWN_PUBLIC_KEY})
    runner.peers[FAKE_PUBLIC_KEY_2] = "10.0.0.9/32,fd42:42:42::9/128"
    runner.peers[FAKE_UNKNOWN_PUBLIC_KEY] = "10.0.0.8/32,fd42:42:42::8/128"
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        with pytest.raises(WireGuardApplyFailedError) as excinfo:
            manager.sync_peers({FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6)}, mesh=[peer])

    assert str(excinfo.value) == "WireGuard peer removal failed."
    # The peer whose removal failed is still live, so it is not reported removed -
    # the next pass sees it again and retries.
    assert FAKE_UNKNOWN_PUBLIC_KEY in runner.peers
    assert FAKE_PUBLIC_KEY_2 not in runner.peers
    assert FAKE_PUBLIC_KEY in runner.peers
    assert runner.routes[4] == {"10.0.1.0/24": "static"}
    assert runner.routes[6] == {"fd42:42:42:1::/64": "static"}
    partial = [record for record in caplog.records if record.message == "peer_sync_partial"]
    assert len(partial) == 1
    assert partial[0].event_fields["added"] == 1
    assert partial[0].event_fields["removed"] == 1
    assert partial[0].event_fields["meshApplied"] == 1
    assert partial[0].event_fields["peerRemovalFailed"] == 1
    assert "peer_removal_failed" in caplog.text
    assert FAKE_UNKNOWN_PUBLIC_KEY not in caplog.text


def make_multi_phase_failure_case(tmp_path):
    # One pass that fails in all four phases: client apply, removal sweep, mesh
    # apply, and route reconciliation.
    runner = FakeWireGuardCommandRunner(
        fail_set_peer_keys={FAKE_PUBLIC_KEY},
        fail_remove_peer_keys={FAKE_UNKNOWN_PUBLIC_KEY},
        fail_set_endpoint_hosts={"wg.us-broken-1.example.com"},
        fail_route_replace_versions={6},
    )
    runner.peers[FAKE_UNKNOWN_PUBLIC_KEY] = "10.0.0.9/32,fd42:42:42::9/128"
    manager = make_manager(tmp_path, runner)
    broken = make_mesh_peer(endpoint_host="wg.us-broken-1.example.com")
    healthy = make_mesh_peer(
        public_key=FAKE_MESH_PUBLIC_KEY_2,
        endpoint_host="wg.us-other-2.example.com",
        allowed_network_v4="10.0.2.0/24",
        allowed_network_v6="fd42:42:42:2::/64",
    )
    return runner, manager, [broken, healthy]


def test_first_failure_stays_primary_across_every_failing_phase(tmp_path, caplog):
    runner, manager, mesh = make_multi_phase_failure_case(tmp_path)

    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        with pytest.raises(WireGuardApplyFailedError) as excinfo:
            manager.sync_peers({FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6)}, mesh=mesh)

    # The client apply fails first, so it stays primary even though three later
    # phases failed too - and each of those is still separately observable.
    assert str(excinfo.value) == "WireGuard peer apply failed."
    partial = [record for record in caplog.records if record.message == "peer_sync_partial"]
    assert len(partial) == 1
    fields = partial[0].event_fields
    assert fields["clientApplyFailed"] == 1
    assert fields["peerRemovalFailed"] == 1
    assert fields["meshApplyFailed"] == 1
    assert fields["routeReconciliationFailed"] is True
    # The healthy mesh candidate still applied behind all of it.
    assert fields["meshApplied"] == 1
    assert runner.peers[FAKE_MESH_PUBLIC_KEY_2] == "10.0.2.0/24,fd42:42:42:2::/64"


def test_multi_phase_failure_converges_on_the_next_healthy_pass(tmp_path, caplog):
    runner, manager, mesh = make_multi_phase_failure_case(tmp_path)
    desired = {FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6)}

    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers(desired, mesh=mesh)

    runner.fail_set_peer_keys.clear()
    runner.fail_remove_peer_keys.clear()
    runner.fail_set_endpoint_hosts.clear()
    runner.fail_route_replace_versions.clear()
    caplog.clear()

    # Nothing is rolled back and nothing is retried in place: the same idempotent
    # pass run again converges every phase that failed.
    with caplog.at_level(logging.WARNING, logger="src.wireguard"):
        result = manager.sync_peers(desired, mesh=mesh)

    assert (result.added, result.removed) == (1, 1)
    assert result.mesh_applied == 2
    assert runner.peers == {
        FAKE_PUBLIC_KEY: f"{TUNNEL_V4},{TUNNEL_V6}",
        FAKE_MESH_PUBLIC_KEY: "10.0.1.0/24,fd42:42:42:1::/64",
        FAKE_MESH_PUBLIC_KEY_2: "10.0.2.0/24,fd42:42:42:2::/64",
    }
    assert runner.routes[4] == {"10.0.1.0/24": "static", "10.0.2.0/24": "static"}
    assert runner.routes[6] == {"fd42:42:42:1::/64": "static", "fd42:42:42:2::/64": "static"}
    assert [record for record in caplog.records if record.message == "peer_sync_partial"] == []


def test_both_failures_converge_on_a_later_healthy_pass(tmp_path):
    runner = FakeWireGuardCommandRunner(
        fail_set_endpoint_hosts={"wg.us-broken-1.example.com"},
        fail_route_replace_versions={6},
    )
    manager = make_manager(tmp_path, runner)
    broken = make_mesh_peer(endpoint_host="wg.us-broken-1.example.com")

    with pytest.raises(WireGuardApplyFailedError):
        manager.sync_peers({}, mesh=[broken])

    runner.fail_set_endpoint_hosts.clear()
    runner.fail_route_replace_versions.clear()
    result = manager.sync_peers({}, mesh=[broken])

    assert result.mesh_applied == 1
    assert result.routes_added == 2
    assert runner.routes[4] == {"10.0.1.0/24": "static"}
    assert runner.routes[6] == {"fd42:42:42:1::/64": "static"}


def test_route_add_failure_after_peer_mutation_repairs_on_next_sync(tmp_path):
    runner = FakeWireGuardCommandRunner(fail_route_replace_versions={6})
    manager = make_manager(tmp_path, runner)
    peer = make_mesh_peer()

    with pytest.raises(WireGuardApplyFailedError, match="route apply failed"):
        manager.sync_peers({}, mesh=[peer])

    assert runner.peers == {FAKE_MESH_PUBLIC_KEY: "10.0.1.0/24,fd42:42:42:1::/64"}
    assert runner.routes[4] == {"10.0.1.0/24": "static"}
    assert runner.routes[6] == {}
    result = manager.sync_peers({}, mesh=[peer])

    assert result.mesh_applied == 1
    assert result.routes_added == 1
    assert runner.routes[4] == {"10.0.1.0/24": "static"}
    assert runner.routes[6] == {"fd42:42:42:1::/64": "static"}


@pytest.mark.parametrize(
    "fail_version, initial_routes, expected_after_failure, expected_removed",
    [
        (4, {4: {"10.0.1.0/24": "static"}, 6: {"fd42:42:42:1::/64": "static"}},
         {4: {"10.0.1.0/24": "static"}, 6: {"fd42:42:42:1::/64": "static"}}, 2),
        (6, {4: {"10.0.1.0/24": "static"}, 6: {"fd42:42:42:1::/64": "static"}},
         {4: {}, 6: {"fd42:42:42:1::/64": "static"}}, 1),
    ],
)
def test_route_removal_failure_preserves_partial_state_until_next_rollback_sync(
    tmp_path, fail_version, initial_routes, expected_after_failure, expected_removed
):
    runner = FakeWireGuardCommandRunner(fail_route_delete_versions={fail_version})
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.1.0/24,fd42:42:42:1::/64"
    runner.routes = initial_routes
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="route removal failed"):
        manager.sync_peers({}, mesh=[], known_region_keys=[FAKE_MESH_PUBLIC_KEY])

    assert runner.peers == {}
    assert runner.routes == expected_after_failure
    result = manager.sync_peers({}, mesh=[], known_region_keys=[FAKE_MESH_PUBLIC_KEY])

    assert result.mesh_removed == 0
    assert result.routes_removed == expected_removed
    assert runner.peers == {}
    assert runner.routes == {4: {}, 6: {}}


# --- Endpoint resolution ----------------------------------------------------


def _addrinfo(address):
    # (family, type, proto, canonname, sockaddr); only sockaddr[0] is read.
    return (socket.AF_INET, socket.SOCK_DGRAM, 0, "", (address, 0))


def test_endpoint_resolution_normalizes_addresses_and_skips_unusable_entries(monkeypatch):
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda *args, **kwargs: [
            _addrinfo("203.0.113.10"),
            _addrinfo("2001:0db8:0000::1"),
            _addrinfo("Wg.Example.COM."),
            _addrinfo(None),  # non-str sockaddr address: skipped, never crashes
            _addrinfo("203.0.113.10"),  # duplicate collapses
        ],
    )

    # Sorted for a stable comparison against the live peer snapshot.
    assert _resolve_endpoint_addresses("wg.example.com") == (
        "2001:db8::1",
        "203.0.113.10",
        "wg.example.com",
    )


def test_endpoint_resolution_reports_a_resolver_error_as_unresolved(monkeypatch):
    def failing(*args, **kwargs):
        raise OSError("resolver unavailable")

    monkeypatch.setattr(socket, "getaddrinfo", failing)

    assert _resolve_endpoint_addresses("wg.example.com") == ()


def test_unexpected_resolver_error_reads_as_drift_instead_of_escaping_the_pass(tmp_path, caplog):
    # The resolver runs mid-pass, after peers have already been mutated. Only
    # OSError was handled, so anything else (a stdlib UnicodeError, an injected
    # resolver raising its own type) escaped past the remaining reconciliation and
    # the partial-progress event.
    def exploding(_host):
        raise RuntimeError("resolver internals leaked into the message")

    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.1.0/24,fd42:42:42:1::/64"
    runner.peer_endpoints[FAKE_MESH_PUBLIC_KEY] = "198.51.100.10:51820"
    manager = make_manager(tmp_path, runner, endpoint_resolver=exploding)
    peer = make_mesh_peer()

    with caplog.at_level(logging.ERROR, logger="src.wireguard"):
        result = manager.sync_peers({}, mesh=[peer])

    # Unresolved reads as drifted: the peer is re-applied and reported updated.
    assert result.mesh_applied == 1
    assert result.mesh_updated == 1
    failures = [record for record in caplog.records if record.message == "endpoint_resolve_failed"]
    assert len(failures) == 1
    assert failures[0].event_fields["errorType"] == "RuntimeError"
    # The type is recorded, never the message a resolver put lookup data into.
    assert "resolver internals leaked" not in caplog.text


def test_resolver_base_exception_is_never_swallowed(tmp_path):
    def cancelled(_host):
        raise KeyboardInterrupt()

    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.1.0/24,fd42:42:42:1::/64"
    runner.peer_endpoints[FAKE_MESH_PUBLIC_KEY] = "198.51.100.10:51820"
    manager = make_manager(tmp_path, runner, endpoint_resolver=cancelled)

    with pytest.raises(KeyboardInterrupt):
        manager.sync_peers({}, mesh=[make_mesh_peer()])


def test_stuck_resolver_occupies_one_worker_and_queues_no_further_lookups(monkeypatch):
    # A running getaddrinfo cannot be cancelled and shutdown(wait=False) only
    # frees resources once it finishes, so the caller's timeout is not the
    # resolver's timeout. Admission control - not a per-call executor - is what
    # keeps repeated syncs from growing resolver threads without bound.
    monkeypatch.setattr(wireguard, "ENDPOINT_RESOLVE_TIMEOUT_SECONDS", 0.05)
    blocked = threading.Event()
    calls = []

    def blocking(*args, **kwargs):
        calls.append(args)
        blocked.wait(30)
        return [_addrinfo("203.0.113.10")]

    monkeypatch.setattr(socket, "getaddrinfo", blocking)
    try:
        assert _resolve_endpoint_addresses("wg.example.com") == ()
        # Raised well past the refusal path's real cost: a lookup that queued or
        # waited on the wedged worker would now cost seconds, not microseconds.
        monkeypatch.setattr(wireguard, "ENDPOINT_RESOLVE_TIMEOUT_SECONDS", 2.0)
        started = time.monotonic()
        # Every later lookup is refused at the gate instead of queueing another
        # future behind the wedged one.
        for _ in range(5):
            assert _resolve_endpoint_addresses("wg.example.com") == ()
        assert time.monotonic() - started < 1.0
        assert len(calls) == 1
        # Queue depth is the whole point of the gate and only observable here.
        assert wireguard._RESOLVER_EXECUTOR._work_queue.qsize() == 0
        assert len([thread for thread in threading.enumerate() if thread.name.startswith("wg-resolve")]) == 1
    finally:
        blocked.set()

    # Admission reopens only once the wedged call actually returns, not when the
    # caller stopped waiting for it.
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: [_addrinfo("203.0.113.11")])
    deadline = time.monotonic() + 10
    resolved = ()
    while not resolved and time.monotonic() < deadline:
        resolved = _resolve_endpoint_addresses("wg.example.com")
        if not resolved:
            time.sleep(0.01)

    assert resolved == ("203.0.113.11",)
    # Nothing was parked behind the wedge: a queued future would have run the
    # blocking resolver once it was released and shown up as a second call.
    assert len(calls) == 1

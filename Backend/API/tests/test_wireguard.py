import logging

import pytest

from src.enums import OperationResult
from src.errors import WireGuardApplyFailedError
from src.wireguard import LocalWireGuardManager, MeshPeer, _parse_dump_snapshots

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
    assert runner.calls == []


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

    mesh_set_calls = [call for call in runner.calls if call.args[:2] == ("wg", "set") and "endpoint" in call.args]
    assert len(mesh_set_calls) == 1
    assert mesh_set_calls[0].args == (
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

    def mesh_set_call_count():
        return sum(1 for call in runner.calls if call.args[:2] == ("wg", "set") and "endpoint" in call.args)

    assert mesh_set_call_count() == 2
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


def test_mesh_peer_dropped_from_desired_set_is_removed_as_mesh_not_client(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_MESH_PUBLIC_KEY] = "10.0.1.0/24,fd42:42:42:1::/64"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({}, mesh=[], known_region_keys=[FAKE_MESH_PUBLIC_KEY])

    assert result.removed == 0  # never treated as an unknown client peer
    assert result.mesh_removed == 1
    assert FAKE_MESH_PUBLIC_KEY not in runner.peers


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

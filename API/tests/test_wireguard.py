import pytest

from cloudlaunch_api.enums import OperationResult
from cloudlaunch_api.errors import WireGuardApplyFailedError
from cloudlaunch_api.wireguard import LocalWireGuardManager, PeerSyncResult

from .fakes import (
    FAKE_PRIVATE_KEY,
    FAKE_PUBLIC_KEY,
    FAKE_PUBLIC_KEY_2,
    FAKE_SERVER_PUBLIC_KEY,
    FakeWireGuardCommandRunner,
)

TUNNEL_V4 = "10.0.0.2/32"
TUNNEL_V6 = "fd42:42:42::2/128"


def make_manager(tmp_path, runner, *, endpoint_host="wg.us-test-1.example.com"):
    return LocalWireGuardManager(
        interface="wg0",
        lock_path=str(tmp_path / "cloudlaunch-wireguard.lock"),
        server_public_key=FAKE_SERVER_PUBLIC_KEY,
        endpoint_host=endpoint_host,
        listen_port=51820,
        dns_ipv4="10.0.0.1",
        dns_ipv6="fd42:42:42::1",
        command_runner=runner,
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

    assert result == PeerSyncResult(added=1, updated=1, removed=1)
    assert runner.peers == {
        FAKE_PUBLIC_KEY: f"{TUNNEL_V4},{TUNNEL_V6}",
        FAKE_PUBLIC_KEY_2: "10.0.0.4/32,fd42:42:42::4/128",
    }


def test_sync_with_matching_state_is_a_noop(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({FAKE_PUBLIC_KEY: (TUNNEL_V4, TUNNEL_V6)})

    assert result == PeerSyncResult(added=0, updated=0, removed=0)
    assert [call.args[:2] for call in runner.calls] == [("wg", "show")]


def test_sync_empty_desired_removes_all_peers(tmp_path):
    runner = FakeWireGuardCommandRunner()
    runner.peers[FAKE_PUBLIC_KEY] = f"{TUNNEL_V4},{TUNNEL_V6}"
    manager = make_manager(tmp_path, runner)

    result = manager.sync_peers({})

    assert result == PeerSyncResult(added=0, updated=0, removed=1)
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

    assert (tmp_path / "cloudlaunch-wireguard.lock").exists()

import os

import pytest

from cloudlaunch_api.enums import OperationResult
from cloudlaunch_api.errors import WireGuardApplyFailedError
from cloudlaunch_api.wireguard import LocalWireGuardManager

from .fakes import (
    FAKE_PRIVATE_KEY,
    FAKE_PUBLIC_KEY,
    FAKE_SERVER_PUBLIC_KEY,
    FakeWireGuardCommandRunner,
)

BASE_CONFIG = f"""[Interface]
Address = 10.0.0.1/24, fd42:42:42::1/64
ListenPort = 51820
PrivateKey = {FAKE_PRIVATE_KEY}

# PostUp
PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT
"""

PEER_BLOCK = f"""
[Peer]
# cloudlaunch-client-id = client-1
PublicKey = {FAKE_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32, fd42:42:42::2/128
PersistentKeepalive = 25
"""


def make_manager(tmp_path, runner):
    config_path = tmp_path / "wg0.conf"
    lock_path = tmp_path / "cloudlaunch-wireguard.lock"
    return LocalWireGuardManager(
        interface="wg0",
        config_path=str(config_path),
        lock_path=str(lock_path),
        server_public_key=FAKE_SERVER_PUBLIC_KEY,
        endpoint_ipv4="203.0.113.10",
        listen_port=51820,
        dns_ipv4="10.0.0.1",
        dns_ipv6="fd42:42:42::1",
        command_runner=runner,
    )


def write_active_config(tmp_path, contents):
    config_path = tmp_path / "wg0.conf"
    config_path.write_text(contents, encoding="utf-8")
    os.chmod(config_path, 0o600)
    return config_path


def backup_paths(tmp_path):
    return list(tmp_path.glob("wg0.conf.bak.*"))


def command_names(runner):
    return [call.args[:2] for call in runner.calls]


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


def test_render_client_config_matches_wireguard_example_shape(tmp_path):
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    config = manager.render_client_config(
        private_key=FAKE_PRIVATE_KEY,
        tunnel_ipv4="10.0.0.2/32",
        tunnel_ipv6="fd42:42:42::2/128",
    )

    assert config == (
        "[Interface]\n"
        f"PrivateKey = {FAKE_PRIVATE_KEY}\n"
        "Address = 10.0.0.2/32, fd42:42:42::2/128\n"
        "DNS = 10.0.0.1, fd42:42:42::1\n"
        "\n"
        "[Peer]\n"
        f"PublicKey = {FAKE_SERVER_PUBLIC_KEY}\n"
        "Endpoint = 203.0.113.10:51820\n"
        "AllowedIPs = 0.0.0.0/0, ::/0\n"
        "PersistentKeepalive = 25\n"
    )


def test_add_peer_writes_backup_validates_replaces_and_syncs(tmp_path):
    config_path = write_active_config(tmp_path, BASE_CONFIG)
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    manager.add_peer(
        client_id="client-1",
        public_key=FAKE_PUBLIC_KEY,
        tunnel_ipv4="10.0.0.2/32",
        tunnel_ipv6="fd42:42:42::2/128",
    )

    active_config = config_path.read_text(encoding="utf-8")
    backups = backup_paths(tmp_path)

    assert "# cloudlaunch-client-id = client-1" in active_config
    assert f"PublicKey = {FAKE_PUBLIC_KEY}" in active_config
    assert "AllowedIPs = 10.0.0.2/32, fd42:42:42::2/128" in active_config
    assert len(backups) == 1
    assert backups[0].read_text(encoding="utf-8") == BASE_CONFIG
    assert backups[0].stat().st_mode & 0o777 == 0o600
    assert config_path.stat().st_mode & 0o777 == 0o600
    assert runner.strip_modes == [0o600]
    assert runner.sync_modes == [0o600]
    assert command_names(runner) == [("wg-quick", "strip"), ("wg", "syncconf")]
    assert all(call.shell is False for call in runner.calls)


def test_remove_peer_rewrites_config_and_syncs(tmp_path):
    config_path = write_active_config(tmp_path, BASE_CONFIG + PEER_BLOCK)
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    result = manager.remove_peer(client_id="client-1", public_key=FAKE_PUBLIC_KEY)

    active_config = config_path.read_text(encoding="utf-8")
    assert result == OperationResult.SUCCESS
    assert "[Peer]" not in active_config
    assert FAKE_PUBLIC_KEY not in active_config
    assert len(backup_paths(tmp_path)) == 1
    assert command_names(runner) == [("wg-quick", "strip"), ("wg", "syncconf")]


def test_remove_missing_peer_is_noop_without_mutating_files(tmp_path):
    config_path = write_active_config(tmp_path, BASE_CONFIG)
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    result = manager.remove_peer(client_id="client-1", public_key=FAKE_PUBLIC_KEY)

    assert result == OperationResult.NOOP
    assert config_path.read_text(encoding="utf-8") == BASE_CONFIG
    assert backup_paths(tmp_path) == []
    assert runner.calls == []


def test_validation_failure_leaves_active_config_unchanged_and_does_not_sync(tmp_path):
    config_path = write_active_config(tmp_path, BASE_CONFIG)
    runner = FakeWireGuardCommandRunner(fail_strip_count=1)
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="validation failed"):
        manager.add_peer(
            client_id="client-1",
            public_key=FAKE_PUBLIC_KEY,
            tunnel_ipv4="10.0.0.2/32",
            tunnel_ipv6="fd42:42:42::2/128",
        )

    assert config_path.read_text(encoding="utf-8") == BASE_CONFIG
    assert len(backup_paths(tmp_path)) == 1
    assert command_names(runner) == [("wg-quick", "strip")]
    assert runner.strip_modes == [0o600]
    assert runner.sync_modes == []


def test_apply_failure_restores_backup_and_attempts_live_rollback(tmp_path):
    config_path = write_active_config(tmp_path, BASE_CONFIG)
    runner = FakeWireGuardCommandRunner(fail_sync_count=1)
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError, match="live apply failed"):
        manager.add_peer(
            client_id="client-1",
            public_key=FAKE_PUBLIC_KEY,
            tunnel_ipv4="10.0.0.2/32",
            tunnel_ipv6="fd42:42:42::2/128",
        )

    assert config_path.read_text(encoding="utf-8") == BASE_CONFIG
    assert len(backup_paths(tmp_path)) == 1
    assert command_names(runner) == [
        ("wg-quick", "strip"),
        ("wg", "syncconf"),
        ("wg-quick", "strip"),
        ("wg", "syncconf"),
    ]
    assert runner.strip_modes == [0o600, 0o600]
    assert runner.sync_modes == [0o600, 0o600]


def test_command_failures_redact_secrets_and_full_configs(tmp_path):
    write_active_config(tmp_path, BASE_CONFIG)
    runner = FakeWireGuardCommandRunner(
        fail_strip_count=1,
        failure_stderr=f"PrivateKey = {FAKE_PRIVATE_KEY}\n{BASE_CONFIG}",
    )
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError) as exc_info:
        manager.add_peer(
            client_id="client-1",
            public_key=FAKE_PUBLIC_KEY,
            tunnel_ipv4="10.0.0.2/32",
            tunnel_ipv6="fd42:42:42::2/128",
        )

    message = str(exc_info.value)
    assert FAKE_PRIVATE_KEY not in message
    assert "[Interface]" not in message
    assert all(call.shell is False for call in runner.calls)


def test_rejects_invalid_peer_inputs(tmp_path):
    write_active_config(tmp_path, BASE_CONFIG)
    runner = FakeWireGuardCommandRunner()
    manager = make_manager(tmp_path, runner)

    with pytest.raises(WireGuardApplyFailedError):
        manager.add_peer(
            client_id="client\n1",
            public_key=FAKE_PUBLIC_KEY,
            tunnel_ipv4="10.0.0.2/32",
            tunnel_ipv6="fd42:42:42::2/128",
        )
    with pytest.raises(WireGuardApplyFailedError):
        manager.add_peer(
            client_id="client-1",
            public_key="not-a-public-key",
            tunnel_ipv4="10.0.0.2/32",
            tunnel_ipv6="fd42:42:42::2/128",
        )
    with pytest.raises(WireGuardApplyFailedError):
        manager.add_peer(
            client_id="client-1",
            public_key=FAKE_PUBLIC_KEY,
            tunnel_ipv4="10.0.0.2/24",
            tunnel_ipv6="fd42:42:42::2/128",
        )
    assert runner.calls == []

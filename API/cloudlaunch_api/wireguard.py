import base64
import binascii
import fcntl
import ipaddress
import os
import re
import subprocess
import tempfile
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from .enums import OperationResult
from .errors import WireGuardApplyFailedError

CommandRunner = Callable[..., subprocess.CompletedProcess[str]]

DEFAULT_LOCK_PATH = "/run/cloudlaunch-wireguard.lock"
_CLIENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_INTERFACE_PATTERN = re.compile(r"^[A-Za-z0-9_=+.-]{1,15}$")


@dataclass(frozen=True)
class WireGuardKeypair:
    private_key: str
    public_key: str


class WireGuardManager(ABC):
    @abstractmethod
    def generate_keypair(self) -> WireGuardKeypair:
        """Generate a fresh WireGuard keypair."""

    @abstractmethod
    def render_client_config(
        self,
        *,
        private_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> str:
        """Render a client-facing WireGuard config."""

    @abstractmethod
    def add_peer(
        self,
        *,
        client_id: str,
        public_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> None:
        """Add a peer to the persistent config and live interface."""

    @abstractmethod
    def remove_peer(self, *, client_id: str, public_key: str) -> OperationResult:
        """Remove a peer. An already-absent peer returns NOOP."""


class LocalWireGuardManager(WireGuardManager):
    def __init__(
        self,
        *,
        interface: str = "wg0",
        config_path: str = "/etc/wireguard/wg0.conf",
        lock_path: str = DEFAULT_LOCK_PATH,
        server_public_key: str,
        endpoint_ipv4: str,
        listen_port: int = 51820,
        dns_ipv4: str,
        dns_ipv6: str,
        command_runner: CommandRunner = subprocess.run,
    ):
        self.interface = _validate_interface(interface)
        self.config_path = Path(config_path)
        self.lock_path = Path(lock_path)
        self.server_public_key = _validate_key(server_public_key, "server public key")
        self.endpoint_ipv4 = _validate_ip_address(endpoint_ipv4, 4, "endpoint IPv4")
        self.listen_port = _validate_port(listen_port)
        self.dns_ipv4 = _validate_ip_address(dns_ipv4, 4, "DNS IPv4")
        self.dns_ipv6 = _validate_ip_address(dns_ipv6, 6, "DNS IPv6")
        self.command_runner = command_runner

    def generate_keypair(self) -> WireGuardKeypair:
        private_key = self._run_secret_command(["wg", "genkey"]).stdout.strip()
        _validate_key(private_key, "client private key")
        public_key = self._run_secret_command(["wg", "pubkey"], input=private_key).stdout.strip()
        _validate_key(public_key, "client public key")
        return WireGuardKeypair(private_key=private_key, public_key=public_key)

    def render_client_config(
        self,
        *,
        private_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> str:
        private_key = _validate_key(private_key, "client private key")
        tunnel_ipv4 = _validate_ip_interface(tunnel_ipv4, 4, 32, "client tunnel IPv4")
        tunnel_ipv6 = _validate_ip_interface(tunnel_ipv6, 6, 128, "client tunnel IPv6")
        return (
            "[Interface]\n"
            f"PrivateKey = {private_key}\n"
            f"Address = {tunnel_ipv4}, {tunnel_ipv6}\n"
            f"DNS = {self.dns_ipv4}, {self.dns_ipv6}\n"
            "\n"
            "[Peer]\n"
            f"PublicKey = {self.server_public_key}\n"
            f"Endpoint = {self.endpoint_ipv4}:{self.listen_port}\n"
            "AllowedIPs = 0.0.0.0/0, ::/0\n"
            "PersistentKeepalive = 25\n"
        )

    def add_peer(
        self,
        *,
        client_id: str,
        public_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> None:
        client_id = _validate_client_id(client_id)
        public_key = _validate_key(public_key, "client public key")
        tunnel_ipv4 = _validate_ip_interface(tunnel_ipv4, 4, 32, "client tunnel IPv4")
        tunnel_ipv6 = _validate_ip_interface(tunnel_ipv6, 6, 128, "client tunnel IPv6")

        def render(active_config: str) -> tuple[str, bool]:
            candidate = _remove_peer_blocks(active_config, client_id=client_id, public_key=public_key)[0]
            candidate = _append_peer_block(
                candidate,
                client_id=client_id,
                public_key=public_key,
                tunnel_ipv4=tunnel_ipv4,
                tunnel_ipv6=tunnel_ipv6,
            )
            return candidate, True

        self._mutate(render)

    def remove_peer(self, *, client_id: str, public_key: str) -> OperationResult:
        client_id = _validate_client_id(client_id)
        public_key = _validate_key(public_key, "client public key")

        def render(active_config: str) -> tuple[str, bool]:
            return _remove_peer_blocks(active_config, client_id=client_id, public_key=public_key)

        return self._mutate(render)

    def _mutate(self, render: Callable[[str], tuple[str, bool]]) -> OperationResult:
        self.config_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock_path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        with _exclusive_lock(self.lock_path):
            active_config = self.config_path.read_text(encoding="utf-8")
            candidate_config, changed = render(active_config)
            if not changed:
                return OperationResult.NOOP

            backup_path = _write_backup(self.config_path, active_config)
            candidate_path: Path | None = None
            stripped_path: Path | None = None
            replaced_active_config = False
            try:
                candidate_path = _write_temp_config(self.config_path.parent, "wg-candidate-", candidate_config)
                stripped_config = self._strip_config(candidate_path)
                stripped_path = _write_temp_config(self.config_path.parent, "wg-stripped-", stripped_config)
                os.replace(candidate_path, self.config_path)
                candidate_path = None
                replaced_active_config = True
                self._sync_config(stripped_path)
                return OperationResult.SUCCESS
            except WireGuardApplyFailedError:
                if replaced_active_config:
                    _restore_backup(self.config_path, backup_path)
                    self._attempt_live_rollback(backup_path)
                raise
            finally:
                _unlink_if_present(candidate_path)
                _unlink_if_present(stripped_path)

    def _run_secret_command(self, args: list[str], *, input: str | None = None) -> subprocess.CompletedProcess[str]:
        try:
            return self.command_runner(
                args,
                input=input,
                capture_output=True,
                text=True,
                check=True,
                shell=False,
            )
        except subprocess.CalledProcessError as exc:
            raise WireGuardApplyFailedError(f"{args[0]} command failed.") from exc

    def _strip_config(self, config_path: Path) -> str:
        try:
            return self.command_runner(
                ["wg-quick", "strip", str(config_path)],
                capture_output=True,
                text=True,
                check=True,
                shell=False,
            ).stdout
        except subprocess.CalledProcessError as exc:
            raise WireGuardApplyFailedError("WireGuard configuration validation failed.") from exc

    def _sync_config(self, stripped_path: Path) -> None:
        try:
            self.command_runner(
                ["wg", "syncconf", self.interface, str(stripped_path)],
                capture_output=True,
                text=True,
                check=True,
                shell=False,
            )
        except subprocess.CalledProcessError as exc:
            raise WireGuardApplyFailedError("WireGuard live apply failed.", transient=True) from exc

    def _attempt_live_rollback(self, backup_path: Path) -> None:
        rollback_path: Path | None = None
        try:
            stripped_config = self._strip_config(backup_path)
            rollback_path = _write_temp_config(self.config_path.parent, "wg-rollback-", stripped_config)
            self._sync_config(rollback_path)
        except WireGuardApplyFailedError:
            pass
        finally:
            _unlink_if_present(rollback_path)


class UnavailableWireGuardManager(WireGuardManager):
    def generate_keypair(self) -> WireGuardKeypair:
        raise WireGuardApplyFailedError("WireGuard manager is not implemented yet.")

    def render_client_config(
        self,
        *,
        private_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> str:
        raise WireGuardApplyFailedError("WireGuard manager is not implemented yet.")

    def add_peer(
        self,
        *,
        client_id: str,
        public_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> None:
        raise WireGuardApplyFailedError("WireGuard manager is not implemented yet.")

    def remove_peer(self, *, client_id: str, public_key: str) -> OperationResult:
        raise WireGuardApplyFailedError("WireGuard manager is not implemented yet.")


def _validate_client_id(client_id: str) -> str:
    if not _CLIENT_ID_PATTERN.fullmatch(client_id):
        raise WireGuardApplyFailedError("Invalid WireGuard client identifier.")
    return client_id


def _validate_interface(interface: str) -> str:
    if not _INTERFACE_PATTERN.fullmatch(interface):
        raise WireGuardApplyFailedError("Invalid WireGuard interface name.")
    return interface


def _validate_key(key: str, label: str) -> str:
    try:
        decoded = base64.b64decode(key, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.") from exc
    if len(decoded) != 32 or len(key) != 44:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.")
    return key


def _validate_ip_address(value: str, version: int, label: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.") from exc
    if address.version != version:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.")
    return str(address)


def _validate_ip_interface(value: str, version: int, prefix_length: int, label: str) -> str:
    try:
        address = ipaddress.ip_interface(value)
    except ValueError as exc:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.") from exc
    if address.version != version or address.network.prefixlen != prefix_length:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.")
    return str(address)


def _validate_port(port: int) -> int:
    if port < 1 or port > 65535:
        raise WireGuardApplyFailedError("Invalid WireGuard listen port.")
    return port


def _append_peer_block(
    config: str,
    *,
    client_id: str,
    public_key: str,
    tunnel_ipv4: str,
    tunnel_ipv6: str,
) -> str:
    config = config.rstrip()
    return (
        f"{config}\n\n"
        "[Peer]\n"
        f"# cloudlaunch-client-id = {client_id}\n"
        f"PublicKey = {public_key}\n"
        f"AllowedIPs = {tunnel_ipv4}, {tunnel_ipv6}\n"
        "PersistentKeepalive = 25\n"
    )


def _remove_peer_blocks(config: str, *, client_id: str, public_key: str) -> tuple[str, bool]:
    lines = config.splitlines()
    result: list[str] = []
    changed = False
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.strip() != "[Peer]":
            result.append(line)
            index += 1
            continue

        block_start = index
        index += 1
        while index < len(lines) and not _is_section_header(lines[index]):
            index += 1
        block = lines[block_start:index]
        if _peer_block_matches(block, client_id=client_id, public_key=public_key):
            changed = True
            if result and result[-1] == "":
                result.pop()
            continue
        result.extend(block)

    return "\n".join(result).rstrip() + "\n", changed


def _is_section_header(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("[") and stripped.endswith("]")


def _peer_block_matches(block: list[str], *, client_id: str, public_key: str) -> bool:
    block_client_id = None
    block_public_key = None
    for line in block:
        stripped = line.strip()
        if stripped.startswith("# cloudlaunch-client-id ="):
            block_client_id = stripped.split("=", 1)[1].strip()
            continue
        key, separator, value = stripped.partition("=")
        if separator and key.strip().lower() == "publickey":
            block_public_key = value.strip()
    return block_client_id == client_id or block_public_key == public_key


class _exclusive_lock:
    def __init__(self, path: Path):
        self.path = path
        self.file = None

    def __enter__(self):
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        os.fchmod(fd, 0o600)
        self.file = os.fdopen(fd, "w")
        fcntl.flock(self.file.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, traceback):
        if self.file is not None:
            fcntl.flock(self.file.fileno(), fcntl.LOCK_UN)
            self.file.close()


def _write_backup(config_path: Path, contents: str) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f")
    backup_path = config_path.with_name(f"{config_path.name}.bak.{timestamp}")
    _write_file_0600(backup_path, contents)
    return backup_path


def _restore_backup(config_path: Path, backup_path: Path) -> None:
    restore_path = _write_temp_config(config_path.parent, "wg-restore-", backup_path.read_text(encoding="utf-8"))
    os.replace(restore_path, config_path)


def _write_temp_config(directory: Path, prefix: str, contents: str) -> Path:
    fd, name = tempfile.mkstemp(prefix=prefix, suffix=".conf", dir=directory)
    path = Path(name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(contents)
        os.chmod(path, 0o600)
    except Exception:
        _unlink_if_present(path)
        raise
    return path


def _write_file_0600(path: Path, contents: str) -> None:
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(contents)
    except Exception:
        _unlink_if_present(path)
        raise


def _unlink_if_present(path: Path | None) -> None:
    if path is not None:
        try:
            path.unlink()
        except FileNotFoundError:
            pass

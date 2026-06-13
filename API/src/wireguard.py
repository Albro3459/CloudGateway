import base64
import binascii
import fcntl
import ipaddress
import os
import re
import subprocess
from abc import ABC, abstractmethod
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

from .enums import OperationResult
from .errors import WireGuardApplyFailedError

CommandRunner = Callable[..., subprocess.CompletedProcess[str]]

DEFAULT_LOCK_PATH = "/run/cloudlaunch-wireguard.lock"
PERSISTENT_KEEPALIVE_SECONDS = 25
_INTERFACE_PATTERN = re.compile(r"^[A-Za-z0-9_=+.-]{1,15}$")
_HOSTNAME_PATTERN = re.compile(
    r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)


@dataclass(frozen=True)
class WireGuardKeypair:
    private_key: str
    public_key: str


@dataclass(frozen=True)
class PeerSyncResult:
    added: int
    updated: int
    removed: int


class WireGuardManager(ABC):
    """Peers live only in Firebase and on the live interface.

    Nothing here persists peers to disk; /etc/wireguard/wg0.conf stays
    interface-only and the boot sync rebuilds the peer set from Firebase.
    Callers must hold lock() across a WireGuard mutation and its matching
    Firebase write so a concurrent sync never observes mid-operation state.
    """

    @abstractmethod
    def lock(self) -> AbstractContextManager[None]:
        """Exclusive cross-process lock context manager for peer mutations."""

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
    def add_peer(self, *, public_key: str, tunnel_ipv4: str, tunnel_ipv6: str) -> None:
        """Add or update a peer on the live interface."""

    @abstractmethod
    def remove_peer(self, *, public_key: str) -> OperationResult:
        """Remove a peer from the live interface. An absent peer returns NOOP."""

    @abstractmethod
    def current_peers(self) -> dict[str, frozenset[str]]:
        """Return the live peer set as public key -> allowed IPs."""

    @abstractmethod
    def sync_peers(self, desired: dict[str, tuple[str, str]]) -> PeerSyncResult:
        """Make the live peer set equal the desired set. Caller holds lock()."""


class LocalWireGuardManager(WireGuardManager):
    def __init__(
        self,
        *,
        interface: str = "wg0",
        lock_path: str = DEFAULT_LOCK_PATH,
        server_public_key: str,
        endpoint_host: str,
        listen_port: int = 51820,
        dns_ipv4: str,
        dns_ipv6: str,
        command_runner: CommandRunner = subprocess.run,
    ):
        self.interface = _validate_interface(interface)
        self.lock_path = Path(lock_path)
        self.server_public_key = _validate_key(server_public_key, "server public key")
        self.endpoint_host = _validate_endpoint_host(endpoint_host)
        self.listen_port = _validate_port(listen_port)
        self.dns_ipv4 = _validate_ip_address(dns_ipv4, 4, "DNS IPv4")
        self.dns_ipv6 = _validate_ip_address(dns_ipv6, 6, "DNS IPv6")
        self.command_runner = command_runner

    @contextmanager
    def lock(self) -> Iterator[None]:
        self.lock_path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        os.fchmod(fd, 0o600)
        file = os.fdopen(fd, "w")
        try:
            fcntl.flock(file.fileno(), fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(file.fileno(), fcntl.LOCK_UN)
            file.close()

    def generate_keypair(self) -> WireGuardKeypair:
        private_key = self._run(["wg", "genkey"], transient=False).stdout.strip()
        _validate_key(private_key, "client private key")
        public_key = self._run(["wg", "pubkey"], input=private_key, transient=False).stdout.strip()
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
            f"Endpoint = {self.endpoint_host}:{self.listen_port}\n"
            "AllowedIPs = 0.0.0.0/0, ::/0\n"
            "PersistentKeepalive = 25\n"
        )

    def add_peer(self, *, public_key: str, tunnel_ipv4: str, tunnel_ipv6: str) -> None:
        public_key = _validate_key(public_key, "client public key")
        tunnel_ipv4 = _validate_ip_interface(tunnel_ipv4, 4, 32, "client tunnel IPv4")
        tunnel_ipv6 = _validate_ip_interface(tunnel_ipv6, 6, 128, "client tunnel IPv6")
        self._run(
            [
                "wg",
                "set",
                self.interface,
                "peer",
                public_key,
                "allowed-ips",
                f"{tunnel_ipv4},{tunnel_ipv6}",
                "persistent-keepalive",
                str(PERSISTENT_KEEPALIVE_SECONDS),
            ],
            failure_message="WireGuard peer apply failed.",
        )

    def remove_peer(self, *, public_key: str) -> OperationResult:
        public_key = _validate_key(public_key, "client public key")
        if public_key not in self.current_peers():
            return OperationResult.NOOP
        self._remove_peer_command(public_key)
        return OperationResult.SUCCESS

    def current_peers(self) -> dict[str, frozenset[str]]:
        # The first dump line carries the interface private key; it is parsed
        # away here and must never be logged.
        output = self._run(
            ["wg", "show", self.interface, "dump"],
            failure_message="WireGuard state read failed.",
        ).stdout
        return _parse_dump(output)

    def sync_peers(self, desired: dict[str, tuple[str, str]]) -> PeerSyncResult:
        validated: dict[str, tuple[str, str]] = {}
        for public_key, (tunnel_ipv4, tunnel_ipv6) in desired.items():
            validated[_validate_key(public_key, "client public key")] = (
                _validate_ip_interface(tunnel_ipv4, 4, 32, "client tunnel IPv4"),
                _validate_ip_interface(tunnel_ipv6, 6, 128, "client tunnel IPv6"),
            )

        current = self.current_peers()
        added = updated = removed = 0
        for public_key, (tunnel_ipv4, tunnel_ipv6) in validated.items():
            if public_key not in current:
                self.add_peer(public_key=public_key, tunnel_ipv4=tunnel_ipv4, tunnel_ipv6=tunnel_ipv6)
                added += 1
            elif current[public_key] != frozenset({tunnel_ipv4, tunnel_ipv6}):
                self.add_peer(public_key=public_key, tunnel_ipv4=tunnel_ipv4, tunnel_ipv6=tunnel_ipv6)
                updated += 1
        for public_key in current:
            if public_key not in validated:
                self._remove_peer_command(_validate_key(public_key, "client public key"))
                removed += 1
        return PeerSyncResult(added=added, updated=updated, removed=removed)

    def _remove_peer_command(self, public_key: str) -> None:
        self._run(
            ["wg", "set", self.interface, "peer", public_key, "remove"],
            failure_message="WireGuard peer removal failed.",
        )

    def _run(
        self,
        args: list[str],
        *,
        input: str | None = None,
        failure_message: str | None = None,
        transient: bool = True,
    ) -> subprocess.CompletedProcess[str]:
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
            raise WireGuardApplyFailedError(
                failure_message or f"{args[0]} command failed.",
                transient=transient,
            ) from exc


def _parse_dump(output: str) -> dict[str, frozenset[str]]:
    peers: dict[str, frozenset[str]] = {}
    lines = output.splitlines()
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) < 4:
            continue
        public_key = fields[0]
        allowed_ips = frozenset(ip for ip in fields[3].split(",") if ip and ip != "(none)")
        peers[public_key] = allowed_ips
    return peers


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


def _validate_endpoint_host(value: str) -> str:
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        pass
    if not _HOSTNAME_PATTERN.fullmatch(value):
        raise WireGuardApplyFailedError("Invalid WireGuard endpoint host.")
    return value


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

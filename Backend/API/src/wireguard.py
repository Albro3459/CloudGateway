import base64
import binascii
import fcntl
import ipaddress
import json
import logging
import os
import re
import subprocess
from abc import ABC, abstractmethod
from collections.abc import Sequence
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

from .enums import Event, OperationResult
from .errors import WireGuardApplyFailedError
from .logs import log_event

logger = logging.getLogger("src.wireguard")

CommandRunner = Callable[..., subprocess.CompletedProcess[str]]

DEFAULT_LOCK_PATH = "/run/cloudgateway-wireguard.lock"
PERSISTENT_KEEPALIVE_SECONDS = 25
_INTERFACE_PATTERN = re.compile(r"^[A-Za-z0-9_=+.-]{1,15}$")
_HOSTNAME_PATTERN = re.compile(
    r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)

# Documentation-only aggregates covering every region's tunnel subnet (see
# TODO/shared-subnet-mesh.md). Nothing routes them as a whole; they exist so the
# mesh route sweep has a safe scope to operate within.
MESH_AGGREGATE_V4 = "10.0.0.0/16"
MESH_AGGREGATE_V6 = "fd42:42:42::/48"

IPNetwork = ipaddress.IPv4Network | ipaddress.IPv6Network


def is_subnet_of(network: IPNetwork, other: IPNetwork) -> bool:
    """Same-family subnet check. `ip_network()` returns a union type that
    `Network.subnet_of()` itself rejects across families, so narrow both
    operands by isinstance before delegating; different families are never
    subnets of each other."""
    if isinstance(network, ipaddress.IPv4Network) and isinstance(other, ipaddress.IPv4Network):
        return network.subnet_of(other)
    if isinstance(network, ipaddress.IPv6Network) and isinstance(other, ipaddress.IPv6Network):
        return network.subnet_of(other)
    return False


@dataclass(frozen=True)
class WireGuardKeypair:
    private_key: str
    public_key: str


@dataclass(frozen=True)
class MeshPeer:
    public_key: str
    endpoint_host: str
    endpoint_port: int
    allowed_network_v4: str
    allowed_network_v6: str


PEER_ADDED = "added"
PEER_UPDATED = "updated"
PEER_REMOVED = "removed"


@dataclass(frozen=True)
class PeerChange:
    public_key: str
    action: str
    tunnel_ipv4: str | None = None
    tunnel_ipv6: str | None = None


@dataclass(frozen=True)
class MeshPeerChange:
    public_key: str
    action: str
    endpoint_host: str = ""
    allowed_network_v4: str = ""
    allowed_network_v6: str = ""


@dataclass(frozen=True)
class RouteChange:
    cidr: str
    action: str
    reclaimed: bool = False


@dataclass(frozen=True)
class PeerSyncResult:
    changes: tuple[PeerChange, ...] = ()
    mesh_changes: tuple[MeshPeerChange, ...] = ()
    mesh_applied_peers: tuple[MeshPeer, ...] = ()
    route_changes: tuple[RouteChange, ...] = ()

    @property
    def added(self) -> int:
        return sum(1 for change in self.changes if change.action == PEER_ADDED)

    @property
    def updated(self) -> int:
        return sum(1 for change in self.changes if change.action == PEER_UPDATED)

    @property
    def removed(self) -> int:
        return sum(1 for change in self.changes if change.action == PEER_REMOVED)

    @property
    def mesh_applied(self) -> int:
        return len(self.mesh_applied_peers)

    @property
    def mesh_added(self) -> int:
        return sum(1 for change in self.mesh_changes if change.action == PEER_ADDED)

    @property
    def mesh_removed(self) -> int:
        return sum(1 for change in self.mesh_changes if change.action == PEER_REMOVED)

    @property
    def routes_added(self) -> int:
        return sum(1 for change in self.route_changes if change.action == PEER_ADDED)

    @property
    def routes_removed(self) -> int:
        return sum(1 for change in self.route_changes if change.action == PEER_REMOVED)


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
    def sync_peers(
        self,
        desired: dict[str, tuple[str, str]],
        *,
        mesh: Sequence[MeshPeer] = (),
        known_mesh_networks: Sequence[str] = (),
        known_region_keys: Sequence[str] = (),
    ) -> PeerSyncResult:
        """Make the live peer set (clients + mesh) and mesh routes equal the desired union.

        Caller holds lock(). Mesh peers are always re-applied (idempotent, and this
        re-resolves each endpoint hostname). A live peer is classified as mesh iff its
        public key is in `mesh` or `known_region_keys`; everything else is judged
        against `desired` (client peers) and removed if unknown.
        """


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
        tunnel_network_v4: str,
        tunnel_network_v6: str,
        command_runner: CommandRunner = subprocess.run,
    ):
        self.interface = _validate_interface(interface)
        self.lock_path = Path(lock_path)
        self.server_public_key = _validate_key(server_public_key, "server public key")
        self.endpoint_host = _validate_endpoint_host(endpoint_host)
        self.listen_port = _validate_port(listen_port)
        self.dns_ipv4 = _validate_ip_address(dns_ipv4, 4, "DNS IPv4")
        self.dns_ipv6 = _validate_ip_address(dns_ipv6, 6, "DNS IPv6")
        self.tunnel_network_v4 = _validate_network(tunnel_network_v4, 4, "tunnel network v4")
        self.tunnel_network_v6 = _validate_network(tunnel_network_v6, 6, "tunnel network v6")
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

    def sync_peers(
        self,
        desired: dict[str, tuple[str, str]],
        *,
        mesh: Sequence[MeshPeer] = (),
        known_mesh_networks: Sequence[str] = (),
        known_region_keys: Sequence[str] = (),
    ) -> PeerSyncResult:
        validated_clients: dict[str, tuple[str, str]] = {}
        for public_key, (tunnel_ipv4, tunnel_ipv6) in desired.items():
            validated_clients[_validate_key(public_key, "client public key")] = (
                _validate_ip_interface(tunnel_ipv4, 4, 32, "client tunnel IPv4"),
                _validate_ip_interface(tunnel_ipv6, 6, 128, "client tunnel IPv6"),
            )
        validated_mesh = [self._validate_mesh_peer(peer) for peer in mesh]
        mesh_by_key = {peer.public_key: peer for peer in validated_mesh}
        # Known region keys are used only for classification (never applied), so a
        # malformed value never aborts the pass - it just fails to match.
        known_keys = set(known_region_keys) | set(mesh_by_key)

        current = self.current_peers()

        changes: list[PeerChange] = []
        for public_key, (tunnel_ipv4, tunnel_ipv6) in validated_clients.items():
            if public_key in mesh_by_key:
                continue
            if public_key not in current:
                self.add_peer(public_key=public_key, tunnel_ipv4=tunnel_ipv4, tunnel_ipv6=tunnel_ipv6)
                changes.append(PeerChange(public_key, PEER_ADDED, tunnel_ipv4, tunnel_ipv6))
            elif current[public_key] != frozenset({tunnel_ipv4, tunnel_ipv6}):
                self.add_peer(public_key=public_key, tunnel_ipv4=tunnel_ipv4, tunnel_ipv6=tunnel_ipv6)
                changes.append(PeerChange(public_key, PEER_UPDATED, tunnel_ipv4, tunnel_ipv6))

        mesh_changes: list[MeshPeerChange] = []
        for public_key, peer in mesh_by_key.items():
            was_live = public_key in current
            self._apply_mesh_peer_command(peer)
            if not was_live:
                mesh_changes.append(
                    MeshPeerChange(
                        public_key=public_key,
                        action=PEER_ADDED,
                        endpoint_host=peer.endpoint_host,
                        allowed_network_v4=peer.allowed_network_v4,
                        allowed_network_v6=peer.allowed_network_v6,
                    )
                )

        for public_key in current:
            if public_key in validated_clients or public_key in mesh_by_key:
                continue
            self._remove_peer_command(_validate_key(public_key, "peer public key"))
            if public_key in known_keys:
                mesh_changes.append(MeshPeerChange(public_key=public_key, action=PEER_REMOVED))
            else:
                changes.append(PeerChange(public_key, PEER_REMOVED))

        route_changes = self._reconcile_mesh_routes(validated_mesh, known_mesh_networks)

        return PeerSyncResult(
            changes=tuple(changes),
            mesh_changes=tuple(mesh_changes),
            mesh_applied_peers=tuple(validated_mesh),
            route_changes=tuple(route_changes),
        )

    def _validate_mesh_peer(self, peer: MeshPeer) -> MeshPeer:
        return MeshPeer(
            public_key=_validate_key(peer.public_key, "mesh peer public key"),
            endpoint_host=_validate_endpoint_host(peer.endpoint_host),
            endpoint_port=_validate_port(peer.endpoint_port),
            allowed_network_v4=_validate_mesh_network(peer.allowed_network_v4, 4, "mesh allowed network v4"),
            allowed_network_v6=_validate_mesh_network(peer.allowed_network_v6, 6, "mesh allowed network v6"),
        )

    def _apply_mesh_peer_command(self, peer: MeshPeer) -> None:
        self._run(
            [
                "wg",
                "set",
                self.interface,
                "peer",
                peer.public_key,
                "endpoint",
                f"{peer.endpoint_host}:{peer.endpoint_port}",
                "allowed-ips",
                f"{peer.allowed_network_v4},{peer.allowed_network_v6}",
                "persistent-keepalive",
                str(PERSISTENT_KEEPALIVE_SECONDS),
            ],
            failure_message="WireGuard mesh peer apply failed.",
        )

    def _remove_peer_command(self, public_key: str) -> None:
        self._run(
            ["wg", "set", self.interface, "peer", public_key, "remove"],
            failure_message="WireGuard peer removal failed.",
        )

    def _reconcile_mesh_routes(
        self,
        mesh_peers: Sequence[MeshPeer],
        known_mesh_networks: Sequence[str],
    ) -> list[RouteChange]:
        known = {
            normalized
            for value in known_mesh_networks
            for normalized in (_soft_normalize_network(value),)
            if normalized is not None
        }
        changes: list[RouteChange] = []
        changes += self._reconcile_routes_for_family(
            version=4,
            desired={peer.allowed_network_v4 for peer in mesh_peers},
            aggregate=MESH_AGGREGATE_V4,
            local_network=self.tunnel_network_v4,
            known=known,
        )
        changes += self._reconcile_routes_for_family(
            version=6,
            desired={peer.allowed_network_v6 for peer in mesh_peers},
            aggregate=MESH_AGGREGATE_V6,
            local_network=self.tunnel_network_v6,
            known=known,
        )
        return changes

    def _reconcile_routes_for_family(
        self,
        *,
        version: int,
        desired: set[str],
        aggregate: str,
        local_network: str,
        known: set[str],
    ) -> list[RouteChange]:
        current = self._current_routes(version)
        aggregate_net = ipaddress.ip_network(aggregate)
        changes: list[RouteChange] = []

        for cidr in desired:
            self._run(
                ["ip", f"-{version}", "route", "replace", cidr, "dev", self.interface],
                failure_message="WireGuard mesh route apply failed.",
            )
            if cidr not in current:
                changes.append(RouteChange(cidr, PEER_ADDED))

        for cidr, protocol in current.items():
            if cidr in desired or cidr == local_network or protocol == "kernel":
                continue
            try:
                network = ipaddress.ip_network(cidr)
            except ValueError:
                continue
            if not is_subnet_of(network, aggregate_net):
                continue
            self._run(
                ["ip", f"-{version}", "route", "del", cidr, "dev", self.interface],
                failure_message="WireGuard mesh route removal failed.",
            )
            reclaimed = cidr not in known
            if reclaimed:
                # A route inside the mesh aggregate that no current region doc
                # claims: the sweep repaired it silently, so the operator needs
                # to know (deleted/rewritten region doc is the likely cause).
                log_event(
                    logger,
                    Event.MESH_ROUTE_RECLAIMED,
                    level=logging.WARNING,
                    interface=self.interface,
                    cidr=cidr,
                )
            changes.append(RouteChange(cidr, PEER_REMOVED, reclaimed=reclaimed))

        return changes

    def _current_routes(self, version: int) -> dict[str, str]:
        output = self._run(
            ["ip", "-j", f"-{version}", "route", "show", "dev", self.interface],
            failure_message="WireGuard mesh route read failed.",
        ).stdout
        try:
            entries = json.loads(output) if output.strip() else []
        except (TypeError, ValueError) as exc:
            raise WireGuardApplyFailedError("WireGuard mesh route read failed.") from exc

        routes: dict[str, str] = {}
        for entry in entries:
            dst = entry.get("dst")
            if not dst:
                continue
            normalized = _normalize_route_dst(dst, version)
            if normalized is None:
                continue
            routes[normalized] = str(entry.get("protocol") or "")
        return routes

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


def _normalize_route_dst(dst: str, version: int) -> str | None:
    if dst == "default":
        return None
    if "/" not in dst:
        dst = f"{dst}/{32 if version == 4 else 128}"
    try:
        return str(ipaddress.ip_network(dst, strict=False))
    except ValueError:
        return None


def _soft_normalize_network(value: str) -> str | None:
    try:
        return str(ipaddress.ip_network(value, strict=False))
    except ValueError:
        return None


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


def _validate_network(value: str, version: int, label: str) -> str:
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.") from exc
    if network.version != version:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.")
    return str(network)


def _validate_mesh_network(value: str, version: int, label: str) -> str:
    network = ipaddress.ip_network(_validate_network(value, version, label))
    aggregate = ipaddress.ip_network(MESH_AGGREGATE_V4 if version == 4 else MESH_AGGREGATE_V6)
    if not is_subnet_of(network, aggregate):
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}: outside the mesh aggregate.")
    return str(network)


def _validate_port(port: int) -> int:
    if port < 1 or port > 65535:
        raise WireGuardApplyFailedError("Invalid WireGuard listen port.")
    return port

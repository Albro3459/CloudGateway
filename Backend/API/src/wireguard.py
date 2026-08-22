import base64
import binascii
import fcntl
import ipaddress
import json
import logging
import os
import re
import socket
import subprocess
import threading
from abc import ABC, abstractmethod
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeoutError
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

from .enums import Event, OperationResult
from .errors import SyncInProgressError, WireGuardApplyFailedError
from .logs import log_event

logger = logging.getLogger("src.wireguard")

CommandRunner = Callable[..., subprocess.CompletedProcess[str]]

DEFAULT_LOCK_PATH = "/run/cloudgateway-wireguard.lock"
PERSISTENT_KEEPALIVE_SECONDS = 25
# Every wg/ip call is local and fast except `wg set peer ... endpoint <host>:<port>`,
# which resolves the hostname itself. Both bounds keep a degraded resolver or a
# wedged netlink call from pinning a thread (and the lock) for the resolver's own
# retry budget.
COMMAND_TIMEOUT_SECONDS = 20.0
ENDPOINT_RESOLVE_TIMEOUT_SECONDS = 5.0
# One resolver worker per process, and a semaphore that admits exactly one
# lookup at a time without queueing - see _resolve_endpoint_addresses.
_RESOLVER_EXECUTOR = ThreadPoolExecutor(max_workers=1, thread_name_prefix="wg-resolve")
_RESOLVER_GATE = threading.BoundedSemaphore(1)
_INTERFACE_PATTERN = re.compile(r"^[A-Za-z0-9_=+.-]{1,15}$")
_HOSTNAME_PATTERN = re.compile(
    r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)

# Documentation-only aggregates covering every region's tunnel subnet (see
# docs/shared-subnet-mesh.md). Nothing routes them as a whole; they exist so the
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
    endpoint_port: int | None
    allowed_network_v4: str
    allowed_network_v6: str


@dataclass(frozen=True)
class LivePeerSnapshot:
    public_key: str
    endpoint_addresses: frozenset[str] = frozenset()
    endpoint_port: int | None = None
    allowed_ips: frozenset[str] = frozenset()
    persistent_keepalive: int | None = None


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
    endpoint_port: int | None = None
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
    def mesh_updated(self) -> int:
        return sum(1 for change in self.mesh_changes if change.action == PEER_UPDATED)

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
    def lock(self, *, blocking: bool = True) -> AbstractContextManager[None]:
        """Exclusive cross-process lock context manager for peer mutations.

        blocking=False raises SyncInProgressError instead of queueing when another
        process already holds the lock, so an HTTP caller can shed the request.
        """

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
        protected_client_keys: Sequence[str] = (),
    ) -> PeerSyncResult:
        """Make the live peer set (clients + mesh) and mesh routes equal the desired union.

        Caller holds lock(). Mesh peers are always re-applied (idempotent, and this
        re-resolves each endpoint hostname). A live peer is classified as mesh iff its
        public key is in `mesh` or `known_region_keys`; everything else is judged
        against `desired` (client peers) and removed if unknown, unless its key is in
        `protected_client_keys` - a degraded Firebase client record (invalid tunnel IP)
        whose status still belongs in the desired set, so its already-live peer must
        survive the sweep instead of being torn down as unknown. A key that is not a
        syntactically valid WireGuard key protects nothing.

        Unknown-peer removal runs before the mesh apply phase, and each mesh candidate
        is applied in isolation, so one unreachable mesh endpoint cannot leave a revoked
        client's peer or a stale route in place. A candidate that fails to apply is never
        reported as applied; it keeps its route only if it is still live with exactly the
        desired ranges. The failure is re-raised once route reconciliation is done.
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
        endpoint_resolver: Callable[[str], Sequence[str]] | None = None,
    ):
        self.interface = _validate_interface(interface)
        self.lock_path = Path(lock_path)
        self.server_public_key = _validate_key(server_public_key, "server public key")
        self.endpoint_host = _validate_endpoint_host(endpoint_host)
        self.listen_port = validate_port(listen_port)
        (
            self.tunnel_network_v4,
            self.tunnel_network_v6,
            self.dns_ipv4,
            self.dns_ipv6,
        ) = validate_local_tunnel_settings(
            tunnel_network_v4=tunnel_network_v4,
            tunnel_network_v6=tunnel_network_v6,
            dns_ipv4=dns_ipv4,
            dns_ipv6=dns_ipv6,
        )
        self.command_runner = command_runner
        self.endpoint_resolver = endpoint_resolver or _resolve_endpoint_addresses

    @contextmanager
    def lock(self, *, blocking: bool = True) -> Iterator[None]:
        self.lock_path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        os.fchmod(fd, 0o600)
        file = os.fdopen(fd, "w")
        operation = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
        try:
            fcntl.flock(file.fileno(), operation)
        except BlockingIOError as exc:
            file.close()
            raise SyncInProgressError() from exc
        except BaseException:
            file.close()
            raise
        try:
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
        return {
            public_key: snapshot.allowed_ips
            for public_key, snapshot in self.peer_snapshots().items()
        }

    def peer_snapshots(self) -> dict[str, LivePeerSnapshot]:
        # The first dump line carries the interface private key; it is parsed
        # away here and must never be logged.
        output = self._run(
            ["wg", "show", self.interface, "dump"],
            failure_message="WireGuard state read failed.",
        ).stdout
        return _parse_dump_snapshots(output)

    def sync_peers(
        self,
        desired: dict[str, tuple[str, str]],
        *,
        mesh: Sequence[MeshPeer] = (),
        known_mesh_networks: Sequence[str] = (),
        known_region_keys: Sequence[str] = (),
        protected_client_keys: Sequence[str] = (),
    ) -> PeerSyncResult:
        validated_clients: dict[str, tuple[str, str]] = {}
        for public_key, (tunnel_ipv4, tunnel_ipv6) in desired.items():
            validated_clients[_validate_key(public_key, "client public key")] = (
                _validate_ip_interface(tunnel_ipv4, 4, 32, "client tunnel IPv4"),
                _validate_ip_interface(tunnel_ipv6, 6, 128, "client tunnel IPv6"),
            )
        # A rejected candidate is dropped, not fatal here: the removal phase below
        # must still run so a bad mesh candidate cannot keep a revoked client's peer
        # on the interface. The rejection is raised once the pass is reconciled.
        validated_mesh, mesh_error = validate_mesh_peers(
            mesh,
            tunnel_network_v4=self.tunnel_network_v4,
            tunnel_network_v6=self.tunnel_network_v6,
        )
        mesh_by_key = {peer.public_key: peer for peer in validated_mesh}
        # Known region keys are used only for classification (never applied), so a
        # malformed value never aborts the pass - it just fails to match.
        known_keys = set(known_region_keys) | set(mesh_by_key)
        # A malformed key protects nothing - it cannot match a live peer, which is
        # always keyed by a syntactically valid WireGuard public key.
        protected_keys = {key for key in protected_client_keys if is_valid_wireguard_key(key)}

        current = self.peer_snapshots()

        # Every phase below is independent: one client peer, one removal, one mesh
        # candidate, or one route is applied on its own, so a single failure must
        # not strand the rest of the pass mid-convergence. The first failure is kept
        # as the primary error and re-raised once every phase has run, which keeps
        # the pass reporting failure while still converging what it safely can.
        apply_error: WireGuardApplyFailedError | None = mesh_error
        client_failures = 0
        removal_failures = 0

        changes: list[PeerChange] = []
        for public_key, (tunnel_ipv4, tunnel_ipv6) in validated_clients.items():
            if public_key in mesh_by_key:
                continue
            live = current.get(public_key)
            if live is not None and live.allowed_ips == frozenset({tunnel_ipv4, tunnel_ipv6}):
                continue
            action = PEER_ADDED if live is None else PEER_UPDATED
            try:
                self.add_peer(public_key=public_key, tunnel_ipv4=tunnel_ipv4, tunnel_ipv6=tunnel_ipv6)
            except WireGuardApplyFailedError as exc:
                # No change is recorded: the peer is not on the interface in the
                # desired shape, so counting it would report progress that the
                # next pass would have to undo.
                client_failures += 1
                apply_error = apply_error or exc
                continue
            changes.append(PeerChange(public_key, action, tunnel_ipv4, tunnel_ipv6))

        if client_failures:
            # Counters only. A client peer key or tunnel address here would tie an
            # account to this host's logs, so the failure is recorded by count and
            # interface alone.
            log_event(
                logger,
                Event.CLIENT_PEER_APPLY_FAILED,
                level=logging.ERROR,
                interface=self.interface,
                failed=client_failures,
            )

        # Removal runs before the mesh apply phase: a mesh endpoint that fails to
        # resolve must not keep a revoked client's peer on the interface, and sync is
        # the only removal path for peers orphaned by a hard-deleted account.
        mesh_changes: list[MeshPeerChange] = []
        for public_key in current:
            if public_key in validated_clients or public_key in mesh_by_key or public_key in protected_keys:
                continue
            try:
                self._remove_peer_command(_validate_key(public_key, "peer public key"))
            except WireGuardApplyFailedError as exc:
                # A peer that is still live must not be reported as removed; the
                # next pass sees it again and retries.
                removal_failures += 1
                apply_error = apply_error or exc
                continue
            if public_key in known_keys:
                mesh_changes.append(MeshPeerChange(public_key=public_key, action=PEER_REMOVED))
            else:
                changes.append(PeerChange(public_key, PEER_REMOVED))

        if removal_failures:
            # Same constraint as above: the sweep removes revoked client peers, so
            # the key stays out of the log.
            log_event(
                logger,
                Event.PEER_REMOVAL_FAILED,
                level=logging.ERROR,
                interface=self.interface,
                failed=removal_failures,
            )

        # Each candidate is isolated: `wg set peer ... endpoint <host>:<port>` resolves
        # the hostname itself, so one broken DNS record must not stop the other peers
        # from being applied. The first failure is re-raised after routes are
        # reconciled, so the pass still reports failure and publishes no success status.
        applied_mesh: list[MeshPeer] = []
        # Routes follow what the interface can actually carry, which is not the same
        # as what applied this pass: a candidate that failed to re-apply but is still
        # live with exactly the desired ranges keeps its route, because tearing it
        # down would break a working peer until the next successful pass. A candidate
        # that never applied still gets no route.
        routed_mesh: list[MeshPeer] = []
        mesh_failures = 0
        for public_key, peer in mesh_by_key.items():
            live = current.get(public_key)
            try:
                self._apply_mesh_peer_command(peer)
            except WireGuardApplyFailedError as exc:
                log_event(
                    logger,
                    Event.MESH_PEER_APPLY_FAILED,
                    level=logging.ERROR,
                    interface=self.interface,
                    endpoint_host=peer.endpoint_host,
                    endpoint_port=peer.endpoint_port,
                )
                if live is not None and live.allowed_ips == frozenset(
                    {peer.allowed_network_v4, peer.allowed_network_v6}
                ):
                    routed_mesh.append(peer)
                mesh_failures += 1
                apply_error = apply_error or exc
                continue
            applied_mesh.append(peer)
            routed_mesh.append(peer)
            if live is None:
                mesh_changes.append(
                    MeshPeerChange(
                        public_key=public_key,
                        action=PEER_ADDED,
                        endpoint_host=peer.endpoint_host,
                        endpoint_port=peer.endpoint_port,
                        allowed_network_v4=peer.allowed_network_v4,
                        allowed_network_v6=peer.allowed_network_v6,
                    )
                )
            elif self._mesh_peer_drifted(live, peer):
                mesh_changes.append(
                    MeshPeerChange(
                        public_key=public_key,
                        action=PEER_UPDATED,
                        endpoint_host=peer.endpoint_host,
                        endpoint_port=peer.endpoint_port,
                        allowed_network_v4=peer.allowed_network_v4,
                        allowed_network_v6=peer.allowed_network_v6,
                    )
                )

        # Route reconciliation is part of the same partial-failure model as the
        # mesh apply phase above: letting it throw straight out would skip
        # PEER_SYNC_PARTIAL and replace an earlier peer failure at the caller
        # boundary, hiding it entirely. The first failure stays primary; a
        # route-only failure becomes primary itself.
        route_changes: list[RouteChange] = []
        route_error: WireGuardApplyFailedError | None = None
        try:
            route_changes = self._reconcile_mesh_routes(routed_mesh, known_mesh_networks)
        except WireGuardApplyFailedError as exc:
            route_error = exc

        result = PeerSyncResult(
            changes=tuple(changes),
            mesh_changes=tuple(mesh_changes),
            mesh_applied_peers=tuple(applied_mesh),
            route_changes=tuple(route_changes),
        )
        if route_error is not None:
            # The raised error can only carry one failure, so the route failure
            # gets its own structured record - otherwise a peer failure raised
            # as primary would be the only thing the caller ever sees. Interface
            # only; no peer keys, addresses, or route CIDRs.
            log_event(
                logger,
                Event.MESH_ROUTE_RECONCILE_FAILED,
                level=logging.ERROR,
                interface=self.interface,
            )
        apply_error = apply_error or route_error
        if apply_error is not None:
            # The caller only sees the exception, so the changes that did land -
            # notably client peers removed before the mesh phase - would otherwise
            # go unrecorded. Counters only; peer keys are never logged.
            log_event(
                logger,
                Event.PEER_SYNC_PARTIAL,
                level=logging.WARNING,
                interface=self.interface,
                added=result.added,
                updated=result.updated,
                removed=result.removed,
                mesh_applied=result.mesh_applied,
                mesh_removed=result.mesh_removed,
                routes_added=result.routes_added,
                routes_removed=result.routes_removed,
                client_apply_failed=client_failures,
                peer_removal_failed=removal_failures,
                mesh_apply_failed=mesh_failures,
                route_reconciliation_failed=route_error is not None,
            )
            raise apply_error

        return result

    def _mesh_peer_drifted(self, live: LivePeerSnapshot, peer: MeshPeer) -> bool:
        return mesh_peer_drifted(live, peer, self.endpoint_resolver)

    def _apply_mesh_peer_command(self, peer: MeshPeer) -> None:
        self._run(
            [
                "wg",
                "set",
                self.interface,
                "peer",
                peer.public_key,
                "endpoint",
                _format_endpoint(peer.endpoint_host, peer.endpoint_port),
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
            for normalized in (soft_normalize_network(value),)
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
                timeout=COMMAND_TIMEOUT_SECONDS,
            )
        except subprocess.CalledProcessError as exc:
            raise WireGuardApplyFailedError(
                failure_message or f"{args[0]} command failed.",
                transient=transient,
            ) from exc
        except subprocess.TimeoutExpired as exc:
            # The caller holds the sync lock; a wedged wg/ip call must not pin it.
            raise WireGuardApplyFailedError(
                failure_message or f"{args[0]} command timed out.",
                transient=True,
            ) from exc


def _parse_dump_snapshots(output: str) -> dict[str, LivePeerSnapshot]:
    peers: dict[str, LivePeerSnapshot] = {}
    lines = output.splitlines()
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) < 8:
            continue
        public_key = fields[0]
        endpoint_addresses, endpoint_port = _parse_dump_endpoint(fields[2])
        allowed_values: set[str] = set()
        for raw_allowed_ip in fields[3].split(","):
            if not raw_allowed_ip or raw_allowed_ip == "(none)":
                continue
            normalized_allowed_ip = _normalize_live_allowed_ip(raw_allowed_ip)
            if normalized_allowed_ip is not None:
                allowed_values.add(normalized_allowed_ip)
        allowed_ips = frozenset(allowed_values)
        keepalive = _parse_optional_int(fields[7])
        peers[public_key] = LivePeerSnapshot(
            public_key=public_key,
            endpoint_addresses=endpoint_addresses,
            endpoint_port=endpoint_port,
            allowed_ips=allowed_ips,
            persistent_keepalive=keepalive,
        )
    return peers


def _parse_dump_endpoint(value: str) -> tuple[frozenset[str], int | None]:
    if not value or value == "(none)":
        return frozenset(), None
    host: str
    port_text: str
    if value.startswith("[") and "]" in value:
        end = value.index("]")
        host, port_text = value[1:end], value[end + 1 :].removeprefix(":")
    elif value.count(":") == 1:
        host, port_text = value.rsplit(":", 1)
    else:
        return frozenset(), None
    port = _parse_optional_int(port_text)
    if port is None or not 1 <= port <= 65535:
        return frozenset(), None
    try:
        host = str(ipaddress.ip_address(host))
    except ValueError:
        host = host.lower().rstrip(".")
    return frozenset({host}), port


def _normalize_live_allowed_ip(value: str) -> str | None:
    try:
        return str(ipaddress.ip_network(value, strict=False))
    except ValueError:
        return None


def _parse_optional_int(value: str) -> int | None:
    try:
        return int(value) if value != "(none)" else None
    except (TypeError, ValueError):
        return None


def _resolve_endpoint_addresses(host: str) -> Sequence[str]:
    # getaddrinfo takes no timeout, so it runs in a worker thread and the caller
    # gives up on the bound: this call happens under the sync lock and must not
    # wait out the resolver's own retry budget. A timed-out lookup reads as
    # unresolved, which only forces a re-apply of that mesh peer.
    #
    # A running future cannot be cancelled and shutdown(wait=False) only frees
    # resources once pending work finishes, so the caller's timeout is not the
    # resolver's timeout: a per-call executor left one live thread behind per
    # stuck lookup, and repeated syncs grew that without bound. One process-wide
    # single-worker executor plus non-queueing admission control caps the damage
    # at one occupied worker and zero queued lookups. The gate is released from
    # the future's completion callback, not when the caller stops waiting, so a
    # wedged libc call keeps admission closed until it actually returns.
    if not _RESOLVER_GATE.acquire(blocking=False):
        return ()
    try:
        future = _RESOLVER_EXECUTOR.submit(socket.getaddrinfo, host, None, type=socket.SOCK_DGRAM)
    except BaseException:
        _RESOLVER_GATE.release()
        raise
    future.add_done_callback(lambda _future: _RESOLVER_GATE.release())
    try:
        addresses = future.result(timeout=ENDPOINT_RESOLVE_TIMEOUT_SECONDS)
    except (OSError, FutureTimeoutError):
        return ()
    normalized: set[str] = set()
    for entry in addresses:
        address = entry[4][0]
        if not isinstance(address, str):
            continue
        try:
            normalized.add(str(ipaddress.ip_address(address)))
        except ValueError:
            normalized.add(address.lower().rstrip("."))
    return tuple(sorted(normalized))


def _format_endpoint(host: str, port: int | None) -> str:
    if port is None:
        raise WireGuardApplyFailedError("Invalid WireGuard endpoint port.")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return f"{host}:{port}"
    if address.version == 6:
        return f"[{address}]:{port}"
    return f"{address}:{port}"


def _normalize_route_dst(dst: str, version: int) -> str | None:
    if dst == "default":
        return None
    if "/" not in dst:
        dst = f"{dst}/{32 if version == 4 else 128}"
    try:
        return str(ipaddress.ip_network(dst, strict=False))
    except ValueError:
        return None


def soft_normalize_network(value: str) -> str | None:
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None
    if network.version == 4 and network.prefixlen != 24:
        return None
    if network.version == 6 and network.prefixlen != 64:
        return None
    return str(network)


def _validate_interface(interface: str) -> str:
    if not _INTERFACE_PATTERN.fullmatch(interface):
        raise WireGuardApplyFailedError("Invalid WireGuard interface name.")
    return interface


def _validate_key(key: str, label: str) -> str:
    if not isinstance(key, str):
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.")
    try:
        decoded = base64.b64decode(key, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.") from exc
    if len(decoded) != 32 or len(key) != 44:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}.")
    return key


def _validate_endpoint_host(value: str) -> str:
    if not isinstance(value, str):
        raise WireGuardApplyFailedError("Invalid WireGuard endpoint host.")
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


def _parse_tunnel_ip_interface(
    value: object, version: int, prefix_length: int
) -> ipaddress.IPv4Interface | ipaddress.IPv6Interface | None:
    if not isinstance(value, str):
        return None
    try:
        address = ipaddress.ip_interface(value)
    except ValueError:
        return None
    if address.version != version or address.network.prefixlen != prefix_length:
        return None
    return address


def _validate_ip_interface(value: str, version: int, prefix_length: int, label: str) -> str:
    address = _parse_tunnel_ip_interface(value, version, prefix_length)
    if address is None:
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


def validate_local_tunnel_settings(
    *,
    tunnel_network_v4: str,
    tunnel_network_v6: str,
    dns_ipv4: str,
    dns_ipv6: str,
) -> tuple[str, str, str, str]:
    network_v4 = _validate_network(tunnel_network_v4, 4, "tunnel network v4")
    network_v6 = _validate_network(tunnel_network_v6, 6, "tunnel network v6")
    parsed_v4 = ipaddress.ip_network(network_v4)
    parsed_v6 = ipaddress.ip_network(network_v6)
    if parsed_v4.prefixlen != 24 or parsed_v6.prefixlen != 64:
        raise WireGuardApplyFailedError("Invalid WireGuard tunnel network prefix length.")
    dns_v4 = _validate_ip_address(dns_ipv4, 4, "DNS IPv4")
    dns_v6 = _validate_ip_address(dns_ipv6, 6, "DNS IPv6")
    if dns_v4 != str(parsed_v4.network_address + 1) or dns_v6 != str(parsed_v6.network_address + 1):
        raise WireGuardApplyFailedError("WireGuard DNS addresses must be the first tunnel network hosts.")
    return network_v4, network_v6, dns_v4, dns_v6


def _validate_mesh_network(value: str, version: int, label: str) -> str:
    network = ipaddress.ip_network(_validate_network(value, version, label))
    expected_prefix = 24 if version == 4 else 64
    if network.prefixlen != expected_prefix:
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}: expected /{expected_prefix}.")
    aggregate = ipaddress.ip_network(MESH_AGGREGATE_V4 if version == 4 else MESH_AGGREGATE_V6)
    if not is_subnet_of(network, aggregate):
        raise WireGuardApplyFailedError(f"Invalid WireGuard {label}: outside the mesh aggregate.")
    return str(network)


def _networks_overlap(network: IPNetwork, other: IPNetwork) -> bool:
    """Same-family overlap check; `overlaps()` rejects mixed families itself."""
    if isinstance(network, ipaddress.IPv4Network) and isinstance(other, ipaddress.IPv4Network):
        return network.overlaps(other)
    if isinstance(network, ipaddress.IPv6Network) and isinstance(other, ipaddress.IPv6Network):
        return network.overlaps(other)
    return False


def validate_mesh_peers(
    peers: Sequence[MeshPeer],
    *,
    tunnel_network_v4: str,
    tunnel_network_v6: str,
) -> tuple[list[MeshPeer], WireGuardApplyFailedError | None]:
    """Validate a whole mesh candidate set, returning (accepted, first rejection).

    Shared by LocalWireGuardManager and the test fake so the fake cannot pass a
    peer set the real host would reject. Cryptokey routing is exclusive, so a
    range colliding with the local tunnel network or with another candidate -
    and a duplicate public key, which docs/shared-subnet-mesh.md requires be
    rejected - silently steals the ranges of whoever applied first.

    A rejection drops the candidate instead of aborting the caller's pass, the
    same isolation a failed apply gets: unknown-peer removal still runs and the
    caller raises the returned error at the end, so bad candidate metadata can
    never keep a revoked client's peer on the interface. A conflict between two
    candidates drops both, and a duplicated key drops every peer holding it,
    matching how sync.desired_mesh_peers skips them upstream.
    """
    validated: list[MeshPeer] = []
    error: WireGuardApplyFailedError | None = None
    for peer in peers:
        try:
            validated.append(_validate_mesh_peer(peer, tunnel_network_v4, tunnel_network_v6))
        except WireGuardApplyFailedError as exc:
            error = error or exc

    rejected: set[int] = set()
    key_counts: dict[str, int] = {}
    for peer in validated:
        key_counts[peer.public_key] = key_counts.get(peer.public_key, 0) + 1
    for index, peer in enumerate(validated):
        if key_counts[peer.public_key] > 1:
            rejected.add(index)
            error = error or WireGuardApplyFailedError("Duplicate WireGuard mesh peer public key.")
    for index, peer in enumerate(validated):
        for other_index in range(index + 1, len(validated)):
            if _mesh_networks_overlap(peer, validated[other_index]):
                rejected.update({index, other_index})
                error = error or WireGuardApplyFailedError(
                    "Overlapping WireGuard mesh allowed networks."
                )
    return [peer for index, peer in enumerate(validated) if index not in rejected], error


def _mesh_networks_overlap(peer: MeshPeer, other: MeshPeer) -> bool:
    return _networks_overlap(
        ipaddress.ip_network(peer.allowed_network_v4),
        ipaddress.ip_network(other.allowed_network_v4),
    ) or _networks_overlap(
        ipaddress.ip_network(peer.allowed_network_v6),
        ipaddress.ip_network(other.allowed_network_v6),
    )


def _validate_mesh_peer(peer: MeshPeer, tunnel_network_v4: str, tunnel_network_v6: str) -> MeshPeer:
    validated = MeshPeer(
        public_key=_validate_key(peer.public_key, "mesh peer public key"),
        endpoint_host=_validate_endpoint_host(peer.endpoint_host),
        endpoint_port=validate_port(peer.endpoint_port),
        allowed_network_v4=_validate_mesh_network(peer.allowed_network_v4, 4, "mesh allowed network v4"),
        allowed_network_v6=_validate_mesh_network(peer.allowed_network_v6, 6, "mesh allowed network v6"),
    )
    # A mesh range covering this host's own tunnel network would take every local
    # client /32 away from its peer.
    for value, local, label in (
        (validated.allowed_network_v4, tunnel_network_v4, "mesh allowed network v4"),
        (validated.allowed_network_v6, tunnel_network_v6, "mesh allowed network v6"),
    ):
        if _networks_overlap(ipaddress.ip_network(value), ipaddress.ip_network(local)):
            raise WireGuardApplyFailedError(
                f"Invalid WireGuard {label}: overlaps this host's tunnel network."
            )
    return validated


def mesh_peer_drifted(
    live: LivePeerSnapshot,
    peer: MeshPeer,
    endpoint_resolver: Callable[[str], Sequence[str]],
) -> bool:
    """A live mesh peer is current when one of its dump-reported endpoint addresses
    is still a DNS answer for the desired hostname and port, allowed-IPs match, and
    keepalive matches. Shared with the fake so both model drift identically."""
    try:
        desired_addresses = frozenset(endpoint_resolver(peer.endpoint_host))
    except Exception as exc:
        # This runs mid-sync, after peers have already been mutated. An unexpected
        # resolver failure (a stdlib UnicodeError on a hostile hostname, an
        # injected resolver raising something of its own) must not escape past the
        # remaining reconciliation and the partial-progress event - it reads as
        # unresolved, which only marks this peer drifted and re-applies it next
        # pass. BaseException still propagates: an interpreter shutdown or a
        # cancelled worker is not drift. The endpoint host is region
        # infrastructure, not client metadata, and the exception type is recorded
        # without its message so a resolver cannot log lookup data.
        log_event(
            logger,
            Event.ENDPOINT_RESOLVE_FAILED,
            level=logging.ERROR,
            endpoint_host=peer.endpoint_host,
            error_type=type(exc).__name__,
        )
        desired_addresses = frozenset()
    endpoint_current = (
        bool(live.endpoint_addresses & desired_addresses)
        and live.endpoint_port == peer.endpoint_port
    )
    return (
        not endpoint_current
        or live.allowed_ips != frozenset({peer.allowed_network_v4, peer.allowed_network_v6})
        or live.persistent_keepalive != PERSISTENT_KEEPALIVE_SECONDS
    )


def validate_port(port: int | None) -> int:
    if not isinstance(port, int) or isinstance(port, bool) or port < 1 or port > 65535:
        raise WireGuardApplyFailedError("Invalid WireGuard listen port.")
    return port


def is_valid_wireguard_key(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        return False
    return len(decoded) == 32 and len(value) == 44


def is_valid_endpoint_host(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return _HOSTNAME_PATTERN.fullmatch(value) is not None


def is_valid_port(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 65535


def is_valid_tunnel_ip(value: object, version: int) -> bool:
    """Same host-address check `sync_peers` applies to a client tunnel IP: a
    single-host interface (/32 for v4, /128 for v6) of the given family."""
    prefix_length = 32 if version == 4 else 128
    return _parse_tunnel_ip_interface(value, version, prefix_length) is not None

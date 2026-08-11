import json
import subprocess
from collections.abc import Iterable, Sequence
from contextlib import contextmanager
from ipaddress import ip_network
from typing import Iterator
from dataclasses import dataclass, replace
from threading import Lock

from src.auth import AuthenticatedUser, TokenVerifier
from src.enums import ClientStatus, OperationResult, Role
from src.errors import (
    AccountDisabledError,
    AuthRequiredError,
    ClientNotFoundError,
    DuplicateEmailError,
    WireGuardApplyFailedError,
)
from src.repository import (
    ALLOCATED_CLIENT_STATUSES,
    ClientDoc,
    CreateUserResult,
    FirebaseRepository,
    MeshPeerState,
    RegionDoc,
    RegionRegistration,
    UserDoc,
    assert_capacity_available,
    assert_user_limit_available,
    assign_tunnel_ips,
    clean_client_name,
    ensure_delete_allowed,
    ensure_local_region,
    ensure_region_enabled,
    new_client_id,
    region_display_order,
    require_region,
    utc_now,
)
from src.wireguard import (
    MESH_AGGREGATE_V4,
    MESH_AGGREGATE_V6,
    PEER_ADDED,
    PEER_REMOVED,
    PEER_UPDATED,
    MeshPeer,
    MeshPeerChange,
    PeerChange,
    PeerSyncResult,
    RouteChange,
    WireGuardKeypair,
    WireGuardManager,
    is_subnet_of,
)

FAKE_PRIVATE_KEY="OUJITKcYj6d2yNq4H2N8nmFzEVKW6Q7sVpnsZWgz8GA="
FAKE_PUBLIC_KEY="eZEOz7uD1jjbTD70Uv+aJcZ0ASxsxz9bTKZQ9vdOQCo="
FAKE_PUBLIC_KEY_2="QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI="
FAKE_SERVER_PUBLIC_KEY="4jVSiiUySTwbsm72pcNxtEUhE37gESbsLPo3nCAaBks="
# Mesh-peer (region server) test keys, distinct from client keys above.
FAKE_MESH_PUBLIC_KEY="Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQkI="
FAKE_MESH_PUBLIC_KEY_2="RUVGRUVGRUVGRUVGRUVGRUVGRUVGRUVGRUVGRUVGQkI="
FAKE_MESH_PUBLIC_KEY_3="SElKSElKSElKSElKSElKSElKSElKSElKSElKSElKQkI="
# A live host peer with no matching Firebase doc (client or mesh) - still a
# valid WireGuard key, since LocalWireGuardManager validates before removal.
FAKE_UNKNOWN_PUBLIC_KEY="VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVU="


@dataclass(frozen=True)
class FakeCommandCall:
    args: tuple[str, ...]
    input: str | None
    shell: bool


class FakeWireGuardCommandRunner:
    """Emulates the wg/ip CLIs: peer state lives in self.peers (pubkey -> allowed-ips csv),
    route state lives in self.routes (family -> cidr -> protocol)."""

    def __init__(
        self,
        *,
        fail_set_count: int = 0,
        fail_show_count: int = 0,
        failure_stderr: str = "simulated command failure",
    ):
        self.calls: list[FakeCommandCall] = []
        self.peers: dict[str, str] = {}
        self.routes: dict[int, dict[str, str]] = {4: {}, 6: {}}
        self.fail_set_count = fail_set_count
        self.fail_show_count = fail_show_count
        self.failure_stderr = failure_stderr

    def __call__(
        self,
        args: Sequence[str],
        *,
        input: str | None = None,
        capture_output: bool = False,
        text: bool = False,
        check: bool = False,
        shell: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        # Signature-compat params for subprocess.run callers; consumed here so
        # vulture doesn't need repo-wide ignore_names entries for them.
        del capture_output, text, check
        if shell is not False:
            raise AssertionError("WireGuard commands must run with shell=False.")

        # Converted once to a distinct, explicitly-typed local (not reassigned
        # onto the `args` parameter name). Matching below uses `len(argv) >= N`
        # plus per-index equality rather than slice-equality against tuple
        # literals (e.g. `argv[:2] == (...)`) - pyright's tuple narrowing
        # collapses a `tuple[str, ...]` to an impossible zero-length type
        # across a chain of slice-equality checks like that (a known pyright
        # limitation, not a real type error).
        argv: tuple[str, ...] = tuple(args)
        self.calls.append(FakeCommandCall(args=argv, input=input, shell=shell))

        if argv == ("wg", "genkey"):
            return subprocess.CompletedProcess(argv, 0, stdout=f"{FAKE_PRIVATE_KEY}\n", stderr="")
        if argv == ("wg", "pubkey"):
            return subprocess.CompletedProcess(argv, 0, stdout=f"{FAKE_PUBLIC_KEY}\n", stderr="")
        if len(argv) == 4 and argv[0] == "wg" and argv[1] == "show" and argv[3] == "dump":
            if self.fail_show_count:
                self.fail_show_count -= 1
                raise subprocess.CalledProcessError(1, argv, stderr=self.failure_stderr)
            lines = [f"{FAKE_PRIVATE_KEY}\t{FAKE_SERVER_PUBLIC_KEY}\t51820\toff"]
            for public_key, allowed_ips in self.peers.items():
                lines.append(f"{public_key}\t(none)\t(none)\t{allowed_ips or '(none)'}\t0\t0\t0\t25")
            return subprocess.CompletedProcess(argv, 0, stdout="\n".join(lines) + "\n", stderr="")
        if len(argv) >= 5 and argv[0] == "wg" and argv[1] == "set" and argv[3] == "peer":
            if self.fail_set_count:
                self.fail_set_count -= 1
                raise subprocess.CalledProcessError(1, argv, stderr=self.failure_stderr)
            public_key = argv[4]
            if len(argv) == 6 and argv[5] == "remove":
                self.peers.pop(public_key, None)
            else:
                self.peers[public_key] = argv[argv.index("allowed-ips") + 1]
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        if len(argv) >= 5 and argv[0] == "ip" and argv[1] == "-j" and argv[3] == "route" and argv[4] == "show":
            version = int(argv[2].lstrip("-"))
            entries = [
                {"dst": cidr, "dev": argv[-1], "protocol": protocol}
                for cidr, protocol in self.routes[version].items()
            ]
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(entries), stderr="")

        if len(argv) >= 5 and argv[0] == "ip" and argv[2] == "route" and argv[3] == "replace":
            version = int(argv[1].lstrip("-"))
            cidr = argv[4]
            self.routes[version][cidr] = "static"
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        if len(argv) >= 5 and argv[0] == "ip" and argv[2] == "route" and argv[3] == "del":
            version = int(argv[1].lstrip("-"))
            cidr = argv[4]
            self.routes[version].pop(cidr, None)
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        raise AssertionError(f"Unexpected WireGuard command: {argv}")


class FakeTokenVerifier(TokenVerifier):
    def __init__(self, users: dict[str, AuthenticatedUser] | None = None):
        self.users = users or {}
        self.disabled_tokens: set[str] = set()
        self.revoked_tokens: set[str] = set()

    def verify_token(self, token: str) -> AuthenticatedUser:
        if token in self.disabled_tokens or token in self.revoked_tokens:
            raise AuthRequiredError("Invalid or expired token.")
        user = self.users.get(token)
        if user is None:
            raise AuthRequiredError("Invalid or expired token.")
        return user


class FakeRepository(FirebaseRepository):
    def __init__(
        self,
        *,
        local_region_id: str = "us-test-1",
        ipv4_cidr: str = "10.0.0.0/24",
        ipv6_cidr: str = "fd42:42:42::/64",
    ):
        self.local_region_id = local_region_id
        self.ipv4_cidr = ipv4_cidr
        self.ipv6_cidr = ipv6_cidr
        self._lock = Lock()
        self.roles: dict[str, Role] = {}
        self.role_defaults: dict[Role, int | None] = {Role.USER: 3, Role.ADMIN: 10}
        self.per_region_client_limits: dict[str, int | None] = {}
        self.users: dict[str, UserDoc] = {}
        self.regions: dict[str, RegionDoc] = {}
        self.clients: dict[tuple[str, str, str], ClientDoc] = {}
        self.disabled_auth_uids: set[str] = set()
        self.revoked_auth_uids: list[str] = []
        self.deleted_auth_uids: list[str] = []
        self.created_user_count = 0
        self.mark_client_active_error: Exception | None = None
        self.create_user_error: Exception | None = None
        self.delete_client_error: Exception | None = None
        self.hard_delete_account_error: Exception | None = None
        self.delete_auth_user_error: Exception | None = None
        # Last mesh status written per region, keyed by region_id: (mesh_enabled, peers).
        self.mesh_status: dict[str, tuple[bool, tuple[MeshPeerState, ...]]] = {}
        self.write_mesh_status_error: Exception | None = None

    def get_role(self, uid: str) -> Role | None:
        return self.roles.get(uid)

    def get_user(self, uid: str) -> UserDoc | None:
        return self.users.get(uid)

    def get_region(self, region_id: str) -> RegionDoc | None:
        return self.regions.get(region_id)

    def list_enabled_regions(self) -> list[RegionDoc]:
        return sorted(
            [region for region in self.regions.values() if region.enabled],
            key=region_display_order,
        )

    def upsert_region(self, registration: RegionRegistration, *, set_enabled: bool) -> RegionDoc:
        # meshEnabled mirrors the real Firestore create-only semantics: seeded false
        # only when the region doc does not yet exist, otherwise carried forward
        # untouched (operator-owned via the dashboard afterward).
        existing = self.regions.get(registration.region_id)
        mesh_enabled = existing.mesh_enabled if existing is not None else False
        region = RegionDoc(
            region_id=registration.region_id,
            display_name=registration.display_name,
            enabled=set_enabled,
            wireguard_endpoint_ipv4=registration.wireguard_endpoint_ipv4,
            wireguard_endpoint_ipv6=registration.wireguard_endpoint_ipv6,
            wireguard_port=registration.wireguard_port,
            wireguard_dns_ipv4=registration.wireguard_dns_ipv4,
            wireguard_dns_ipv6=registration.wireguard_dns_ipv6,
            wireguard_public_key=registration.wireguard_public_key,
            capacity_limit=registration.capacity_limit,
            wireguard_endpoint_hostname=registration.wireguard_endpoint_hostname,
            display_order=registration.display_order,
            updated_at=utc_now(),
            tunnel_network_v4=registration.tunnel_network_v4,
            tunnel_network_v6=registration.tunnel_network_v6,
            mesh_enabled=mesh_enabled,
        )
        self.regions[registration.region_id] = region
        return region

    def write_mesh_status(self, *, region_id: str, mesh_enabled: bool, peers: Sequence[MeshPeerState]) -> None:
        if self.write_mesh_status_error is not None:
            raise self.write_mesh_status_error
        self.mesh_status[region_id] = (mesh_enabled, tuple(peers))

    def get_client(self, *, owner_uid: str, region_id: str, client_id: str) -> ClientDoc | None:
        return self.clients.get((owner_uid, region_id, client_id))

    def list_active_clients(self, region_id: str) -> list[ClientDoc]:
        return [
            client
            for client in self.clients.values()
            if client.region_id == region_id
            and client.status == ClientStatus.ACTIVE
            and client.client_public_key
        ]

    def list_allocated_clients(self, region_id: str) -> list[ClientDoc]:
        return self._allocated_region_clients(region_id)

    def list_clients_by_public_key(self, region_id: str, public_keys: set[str]) -> list[ClientDoc]:
        return [
            client
            for client in self.clients.values()
            if client.region_id == region_id and client.client_public_key in public_keys
        ]

    def list_clients_for_owner(self, owner_uid: str) -> list[ClientDoc]:
        return [
            client
            for client in self.clients.values()
            if client.owner_uid == owner_uid
        ]

    def list_admin_emails(self) -> list[str]:
        emails: list[str] = []
        seen: set[str] = set()
        for uid, role in self.roles.items():
            if role != Role.ADMIN:
                continue
            user = self.users.get(uid)
            if user is None:
                continue
            email = user.email.strip()
            if not email:
                continue
            normalized = email.lower()
            if normalized in seen:
                continue
            seen.add(normalized)
            emails.append(email)
        return emails

    def create_user(self, *, email: str) -> CreateUserResult:
        if self.create_user_error is not None:
            raise self.create_user_error
        with self._lock:
            existing = next(
                (user for user in self.users.values() if user.email.lower() == email.lower()),
                None,
            )
            if existing is not None:
                if self.roles.get(existing.uid) is not None:
                    if existing.uid in self.disabled_auth_uids:
                        raise AccountDisabledError("This user already has access, but their Firebase account is disabled.")
                    raise DuplicateEmailError()
                if existing.uid in self.disabled_auth_uids:
                    self.enable_auth_user(existing.uid)
                self.roles[existing.uid] = Role.USER
                return CreateUserResult(user=existing, already_existed=True)
            self.created_user_count += 1
            uid = f"created-user-{self.created_user_count}"
            while uid in self.users or uid in self.roles:
                self.created_user_count += 1
                uid = f"created-user-{self.created_user_count}"
            user = UserDoc(uid=uid, email=email, created_at=utc_now())
            self.users[uid] = user
            self.roles[uid] = Role.USER
            return CreateUserResult(user=user)

    def disable_auth_user(self, uid: str) -> None:
        self.disabled_auth_uids.add(uid)
        self.revoked_auth_uids.append(uid)

    def enable_auth_user(self, uid: str) -> None:
        self.disabled_auth_uids.discard(uid)

    def delete_auth_user(self, uid: str) -> None:
        if self.delete_auth_user_error is not None:
            raise self.delete_auth_user_error
        self.deleted_auth_uids.append(uid)
        self.disabled_auth_uids.discard(uid)

    def hard_delete_account_documents(self, uid: str) -> None:
        if self.hard_delete_account_error is not None:
            raise self.hard_delete_account_error
        self.roles.pop(uid, None)
        self.per_region_client_limits.pop(uid, None)
        self.users.pop(uid, None)
        for key, client in list(self.clients.items()):
            if client.owner_uid == uid:
                del self.clients[key]

    def reserve_client(
        self,
        *,
        owner_uid: str,
        owner_email: str | None,
        region_id: str,
        client_name: str,
    ) -> ClientDoc:
        ensure_local_region(region_id, self.local_region_id)
        with self._lock:
            region = ensure_region_enabled(self.regions.get(region_id))
            allocated_clients = self._allocated_region_clients(region_id)
            owner_allocated_count = sum(1 for client in allocated_clients if client.owner_uid == owner_uid)
            assert_capacity_available(allocated_count=len(allocated_clients), capacity_limit=region.capacity_limit)
            assert_user_limit_available(
                owner_allocated_count=owner_allocated_count,
                per_region_client_limit=self._effective_per_region_client_limit(owner_uid),
            )
            assigned_ipv4, assigned_ipv6 = assign_tunnel_ips(
                ipv4_cidr=self.ipv4_cidr,
                ipv6_cidr=self.ipv6_cidr,
                used_ipv4={client.assigned_tunnel_ipv4 for client in allocated_clients},
                used_ipv6={client.assigned_tunnel_ipv6 for client in allocated_clients},
            )
            client_id = new_client_id()
            while (owner_uid, region_id, client_id) in self.clients:
                client_id = new_client_id()

            now = utc_now()
            self.users.setdefault(
                owner_uid,
                UserDoc(
                    uid=owner_uid,
                    email=owner_email or "",
                    created_at=now,
                ),
            )
            client = ClientDoc(
                client_id=client_id,
                owner_uid=owner_uid,
                owner_email=owner_email or "",
                client_name=clean_client_name(client_name),
                region_id=region.region_id,
                status=ClientStatus.CREATING,
                assigned_tunnel_ipv4=assigned_ipv4,
                assigned_tunnel_ipv6=assigned_ipv6,
                server_endpoint_ipv4=region.wireguard_endpoint_ipv4,
                server_endpoint_hostname=region.wireguard_endpoint_hostname,
                server_public_key=region.wireguard_public_key,
                client_public_key="",
                wireguard_config=None,
                created_at=now,
                updated_at=now,
                removed_at=None,
                last_error_code=None,
                last_error_message=None,
            )
            self.clients[(owner_uid, region_id, client_id)] = client
            return client

    def mark_client_active(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        client_public_key: str,
        wireguard_config: str,
    ) -> ClientDoc:
        if self.mark_client_active_error is not None:
            raise self.mark_client_active_error
        ensure_local_region(region_id, self.local_region_id)
        with self._lock:
            client = self._require_client(owner_uid=owner_uid, region_id=region_id, client_id=client_id)
            if client.status not in {ClientStatus.CREATING, ClientStatus.ACTIVE}:
                raise ClientNotFoundError()
            updated = replace(
                client,
                status=ClientStatus.ACTIVE,
                client_public_key=client_public_key,
                wireguard_config=wireguard_config,
                updated_at=utc_now(),
                removed_at=None,
                last_error_code=None,
                last_error_message=None,
            )
            self.clients[(owner_uid, region_id, client_id)] = updated
            return updated

    def mark_client_failed(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        error_code: str,
        error_message: str,
    ) -> ClientDoc:
        return self._mark_client_terminal(
            owner_uid=owner_uid,
            region_id=region_id,
            client_id=client_id,
            status=ClientStatus.FAILED,
            error_code=error_code,
            error_message=error_message,
        )

    def remove_client_reservation(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> ClientDoc:
        return self._mark_client_terminal(
            owner_uid=owner_uid,
            region_id=region_id,
            client_id=client_id,
            status=ClientStatus.REMOVED,
            error_code=error_code,
            error_message=error_message,
        )

    def delete_client(
        self,
        *,
        requester_uid: str,
        target_uid: str,
        region_id: str,
        client_id: str,
    ) -> ClientDoc:
        if self.delete_client_error is not None:
            raise self.delete_client_error
        ensure_local_region(region_id, self.local_region_id)
        with self._lock:
            ensure_delete_allowed(
                requester_uid=requester_uid,
                requester_role=self.roles.get(requester_uid),
                target_uid=target_uid,
            )
            require_region(self.regions.get(region_id))
            return self._mark_client_terminal_locked(
                owner_uid=target_uid,
                region_id=region_id,
                client_id=client_id,
                status=ClientStatus.REMOVED,
                error_code=None,
                error_message=None,
            )

    def _mark_client_terminal(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        status: ClientStatus,
        error_code: str | None,
        error_message: str | None,
    ) -> ClientDoc:
        ensure_local_region(region_id, self.local_region_id)
        with self._lock:
            require_region(self.regions.get(region_id))
            return self._mark_client_terminal_locked(
                owner_uid=owner_uid,
                region_id=region_id,
                client_id=client_id,
                status=status,
                error_code=error_code,
                error_message=error_message,
            )

    def _mark_client_terminal_locked(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        status: ClientStatus,
        error_code: str | None,
        error_message: str | None,
    ) -> ClientDoc:
        client = self._require_client(owner_uid=owner_uid, region_id=region_id, client_id=client_id)
        now = utc_now()
        updated = replace(
            client,
            status=status,
            wireguard_config=None if status == ClientStatus.REMOVED else client.wireguard_config,
            updated_at=now,
            removed_at=now if status == ClientStatus.REMOVED else None,
            last_error_code=error_code,
            last_error_message=error_message,
        )
        self.clients[(owner_uid, region_id, client_id)] = updated
        return updated

    def _allocated_region_clients(self, region_id: str) -> list[ClientDoc]:
        return [
            client
            for client in self.clients.values()
            if client.region_id == region_id and client.status in ALLOCATED_CLIENT_STATUSES
        ]

    def _effective_per_region_client_limit(self, uid: str) -> int | None:
        override = self.per_region_client_limits.get(uid)
        if override is not None:
            return override
        role = self.roles.get(uid) or Role.USER
        return self.role_defaults.get(role)

    def _require_client(self, *, owner_uid: str, region_id: str, client_id: str) -> ClientDoc:
        client = self.clients.get((owner_uid, region_id, client_id))
        if client is None:
            raise ClientNotFoundError()
        if client.client_id != client_id or client.owner_uid != owner_uid or client.region_id != region_id:
            raise ClientNotFoundError()
        return client


class FakeWireGuardManager(WireGuardManager):
    def __init__(
        self,
        *,
        tunnel_network_v4: str = "10.0.0.0/24",
        tunnel_network_v6: str = "fd42:42:42::/64",
    ):
        self.peers: dict[str, tuple[str, str]] = {}
        self.mesh_peers: dict[str, MeshPeer] = {}
        self.routes: dict[int, dict[str, str]] = {4: {}, 6: {}}
        self.tunnel_network_v4 = tunnel_network_v4
        self.tunnel_network_v6 = tunnel_network_v6
        self.keypair_count = 0
        self.add_peer_calls = 0
        self.remove_peer_calls = 0
        self.sync_calls = 0
        self.mesh_apply_calls = 0
        self.fail_generate_count = 0
        self.fail_add_count = 0
        self.fail_remove_count = 0
        self.fail_add_transient = False
        self.fail_remove_transient = False
        self.locked = False

    @contextmanager
    def lock(self) -> Iterator[None]:
        if self.locked:
            raise AssertionError("WireGuard lock() is not reentrant.")
        self.locked = True
        try:
            yield
        finally:
            self.locked = False

    def _require_lock(self) -> None:
        if not self.locked:
            raise AssertionError("WireGuard mutation must run inside lock().")

    def generate_keypair(self) -> WireGuardKeypair:
        if self.fail_generate_count:
            self.fail_generate_count -= 1
            raise WireGuardApplyFailedError("Simulated key generation failure.")
        self.keypair_count += 1
        return WireGuardKeypair(
            private_key=f"fake-private-{self.keypair_count}",
            public_key=f"fake-public-{self.keypair_count}",
        )

    def render_client_config(
        self,
        *,
        private_key: str,
        tunnel_ipv4: str,
        tunnel_ipv6: str,
    ) -> str:
        return (
            "[Interface]\n"
            f"PrivateKey = {private_key}\n"
            f"Address = {tunnel_ipv4}, {tunnel_ipv6}\n"
            "\n"
            "[Peer]\n"
            "PublicKey = fake-server-public\n"
            "Endpoint = wg.us-test-1.example.com:51820\n"
        )

    def add_peer(self, *, public_key: str, tunnel_ipv4: str, tunnel_ipv6: str) -> None:
        self._require_lock()
        self.add_peer_calls += 1
        if self.fail_add_count:
            self.fail_add_count -= 1
            raise WireGuardApplyFailedError("Simulated add peer failure.", transient=self.fail_add_transient)
        self.peers[public_key] = (tunnel_ipv4, tunnel_ipv6)

    def remove_peer(self, *, public_key: str) -> OperationResult:
        self._require_lock()
        self.remove_peer_calls += 1
        if self.fail_remove_count:
            self.fail_remove_count -= 1
            raise WireGuardApplyFailedError("Simulated remove peer failure.", transient=self.fail_remove_transient)
        if public_key not in self.peers and public_key not in self.mesh_peers:
            return OperationResult.NOOP
        self.peers.pop(public_key, None)
        self.mesh_peers.pop(public_key, None)
        return OperationResult.SUCCESS

    def current_peers(self) -> dict[str, frozenset[str]]:
        current = {
            public_key: frozenset({tunnel_ipv4, tunnel_ipv6})
            for public_key, (tunnel_ipv4, tunnel_ipv6) in self.peers.items()
        }
        for public_key, peer in self.mesh_peers.items():
            current[public_key] = frozenset({peer.allowed_network_v4, peer.allowed_network_v6})
        return current

    def sync_peers(
        self,
        desired: dict[str, tuple[str, str]],
        *,
        mesh: Sequence[MeshPeer] = (),
        known_mesh_networks: Sequence[str] = (),
        known_region_keys: Sequence[str] = (),
    ) -> PeerSyncResult:
        self._require_lock()
        self.sync_calls += 1
        mesh_by_key = {peer.public_key: peer for peer in mesh}
        known_keys = set(known_region_keys) | set(mesh_by_key)

        changes: list[PeerChange] = []
        for public_key, ips in desired.items():
            if public_key in mesh_by_key:
                continue
            if public_key not in self.peers:
                self.peers[public_key] = ips
                changes.append(PeerChange(public_key, PEER_ADDED, ips[0], ips[1]))
            elif self.peers[public_key] != ips:
                self.peers[public_key] = ips
                changes.append(PeerChange(public_key, PEER_UPDATED, ips[0], ips[1]))

        mesh_changes: list[MeshPeerChange] = []
        for public_key, peer in mesh_by_key.items():
            self.mesh_apply_calls += 1
            was_live = public_key in self.mesh_peers or public_key in self.peers
            self.mesh_peers[public_key] = peer
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

        for public_key in set(self.peers) | set(self.mesh_peers):
            if public_key in desired or public_key in mesh_by_key:
                continue
            self.peers.pop(public_key, None)
            self.mesh_peers.pop(public_key, None)
            if public_key in known_keys:
                mesh_changes.append(MeshPeerChange(public_key=public_key, action=PEER_REMOVED))
            else:
                changes.append(PeerChange(public_key, PEER_REMOVED))

        route_changes = self._reconcile_routes(mesh_by_key.values(), known_mesh_networks)

        return PeerSyncResult(
            changes=tuple(changes),
            mesh_changes=tuple(mesh_changes),
            mesh_applied_peers=tuple(mesh_by_key.values()),
            route_changes=tuple(route_changes),
        )

    def _reconcile_routes(
        self,
        mesh_peers: Iterable[MeshPeer],
        known_mesh_networks: Sequence[str],
    ) -> list[RouteChange]:
        known = set(known_mesh_networks)
        changes: list[RouteChange] = []
        changes += self._reconcile_routes_for_family(
            4,
            {peer.allowed_network_v4 for peer in mesh_peers},
            MESH_AGGREGATE_V4,
            self.tunnel_network_v4,
            known,
        )
        changes += self._reconcile_routes_for_family(
            6,
            {peer.allowed_network_v6 for peer in mesh_peers},
            MESH_AGGREGATE_V6,
            self.tunnel_network_v6,
            known,
        )
        return changes

    def _reconcile_routes_for_family(
        self,
        version: int,
        desired: set[str],
        aggregate: str,
        local_network: str,
        known: set[str],
    ) -> list[RouteChange]:
        aggregate_net = ip_network(aggregate)
        current = self.routes[version]
        changes: list[RouteChange] = []

        for cidr in desired:
            existed = cidr in current
            current[cidr] = "static"
            if not existed:
                changes.append(RouteChange(cidr, PEER_ADDED))

        for cidr in list(current):
            if cidr in desired or cidr == local_network or current[cidr] == "kernel":
                continue
            if not is_subnet_of(ip_network(cidr), aggregate_net):
                continue
            del current[cidr]
            changes.append(RouteChange(cidr, PEER_REMOVED, reclaimed=cidr not in known))

        return changes

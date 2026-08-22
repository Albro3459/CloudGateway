import json
import subprocess
from collections.abc import Iterable, Sequence
from contextlib import contextmanager
from ipaddress import ip_address, ip_network
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
    PolicyApplyFailedError,
    SyncInProgressError,
    WireGuardApplyFailedError,
)
from src.policy import LivePolicyFamily, LivePolicyMap, PolicyManager, PolicyRow
from src.repository import (
    ALLOCATED_CLIENT_STATUSES,
    AccountCleanupTally,
    ClientDoc,
    CreateUserResult,
    FirebaseRepository,
    MeshPeerState,
    PolicyClientEntry,
    PolicyStatus,
    RegionDoc,
    RegionRegistration,
    UserDoc,
    assert_capacity_available,
    assert_user_limit_available,
    clean_client_name,
    ensure_delete_allowed,
    ensure_local_region,
    ensure_region_enabled,
    new_client_id,
    next_account_slot,
    next_tunnel_index,
    region_display_order,
    require_region,
    tunnel_addresses_for_index,
    used_tunnel_indices,
    utc_now,
    valid_account_slot,
)
from src.wireguard import (
    MESH_AGGREGATE_V4,
    MESH_AGGREGATE_V6,
    PEER_ADDED,
    PEER_REMOVED,
    PEER_UPDATED,
    MeshPeer,
    LivePeerSnapshot,
    MeshPeerChange,
    PeerChange,
    PeerSyncResult,
    RouteChange,
    WireGuardKeypair,
    WireGuardManager,
    is_subnet_of,
    is_valid_wireguard_key,
    mesh_peer_drifted,
    soft_normalize_network,
    validate_mesh_peers,
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
        fail_set_endpoint_hosts: set[str] | None = None,
        fail_set_peer_keys: set[str] | None = None,
        fail_remove_peer_keys: set[str] | None = None,
        fail_show_count: int = 0,
        fail_route_replace_versions: set[int] | None = None,
        fail_route_delete_versions: set[int] | None = None,
        timeout_command_prefixes: set[tuple[str, ...]] | None = None,
        failure_stderr: str = "simulated command failure",
    ):
        self.calls: list[FakeCommandCall] = []
        self.peers: dict[str, str] = {}
        self.peer_endpoints: dict[str, str] = {}
        self.peer_keepalives: dict[str, int | None] = {}
        self.routes: dict[int, dict[str, str]] = {4: {}, 6: {}}
        self.fail_set_count = fail_set_count
        # Endpoint hostnames whose `wg set ... endpoint` always fails, as wg does when
        # it cannot resolve the hostname itself.
        self.fail_set_endpoint_hosts = fail_set_endpoint_hosts or set()
        # Peer keys whose apply (or removal) always fails, so a pass can fail one
        # peer while the others still apply.
        self.fail_set_peer_keys = fail_set_peer_keys or set()
        self.fail_remove_peer_keys = fail_remove_peer_keys or set()
        self.fail_show_count = fail_show_count
        self.fail_route_replace_versions = fail_route_replace_versions or set()
        self.fail_route_delete_versions = fail_route_delete_versions or set()
        # argv prefixes whose command hangs past the caller's timeout.
        self.timeout_command_prefixes = timeout_command_prefixes or set()
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
        timeout: float | None = None,
    ) -> subprocess.CompletedProcess[str]:
        # Signature-compat params for subprocess.run callers; consumed here so
        # vulture doesn't need repo-wide ignore_names entries for them.
        del capture_output, text, check
        if shell is not False:
            raise AssertionError("WireGuard commands must run with shell=False.")
        if timeout is None:
            raise AssertionError("WireGuard commands must run with an explicit timeout.")

        # Converted once to a distinct, explicitly-typed local (not reassigned
        # onto the `args` parameter name). Matching below uses `len(argv) >= N`
        # plus per-index equality rather than slice-equality against tuple
        # literals (e.g. `argv[:2] == (...)`) - pyright's tuple narrowing
        # collapses a `tuple[str, ...]` to an impossible zero-length type
        # across a chain of slice-equality checks like that (a known pyright
        # limitation, not a real type error).
        argv: tuple[str, ...] = tuple(args)
        self.calls.append(FakeCommandCall(args=argv, input=input, shell=shell))

        for prefix in self.timeout_command_prefixes:
            if argv[: len(prefix)] == prefix:
                raise subprocess.TimeoutExpired(list(argv), timeout)

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
                endpoint = self.peer_endpoints.get(public_key, "(none)")
                keepalive = self.peer_keepalives.get(public_key, 25)
                keepalive_text = str(keepalive) if keepalive is not None else "(none)"
                lines.append(f"{public_key}\t(none)\t{endpoint}\t{allowed_ips or '(none)'}\t0\t0\t0\t{keepalive_text}")
            return subprocess.CompletedProcess(argv, 0, stdout="\n".join(lines) + "\n", stderr="")
        if len(argv) >= 5 and argv[0] == "wg" and argv[1] == "set" and argv[3] == "peer":
            if self.fail_set_count:
                self.fail_set_count -= 1
                raise subprocess.CalledProcessError(1, argv, stderr=self.failure_stderr)
            if "endpoint" in argv:
                endpoint = argv[argv.index("endpoint") + 1]
                if endpoint.rsplit(":", 1)[0].strip("[]") in self.fail_set_endpoint_hosts:
                    raise subprocess.CalledProcessError(1, argv, stderr="Name or service not known")
            public_key = argv[4]
            removing = len(argv) == 6 and argv[5] == "remove"
            if public_key in (self.fail_remove_peer_keys if removing else self.fail_set_peer_keys):
                raise subprocess.CalledProcessError(1, argv, stderr=self.failure_stderr)
            if removing:
                self.peers.pop(public_key, None)
                self.peer_endpoints.pop(public_key, None)
                self.peer_keepalives.pop(public_key, None)
            else:
                self.peers[public_key] = argv[argv.index("allowed-ips") + 1]
                if "endpoint" in argv:
                    self.peer_endpoints[public_key] = argv[argv.index("endpoint") + 1]
                if "persistent-keepalive" in argv:
                    self.peer_keepalives[public_key] = int(argv[argv.index("persistent-keepalive") + 1])
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
            if version in self.fail_route_replace_versions:
                self.fail_route_replace_versions.remove(version)
                raise subprocess.CalledProcessError(1, argv, stderr=self.failure_stderr)
            cidr = argv[4]
            self.routes[version][cidr] = "static"
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        if len(argv) >= 5 and argv[0] == "ip" and argv[2] == "route" and argv[3] == "del":
            version = int(argv[1].lstrip("-"))
            if version in self.fail_route_delete_versions:
                self.fail_route_delete_versions.remove(version)
                raise subprocess.CalledProcessError(1, argv, stderr=self.failure_stderr)
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
        self.mark_account_clients_inactive_error: Exception | None = None
        self.mark_account_clients_inactive_calls = 0
        # Last mesh status written per region, keyed by region_id: (mesh_enabled, peers).
        self.mesh_status: dict[str, tuple[bool, tuple[MeshPeerState, ...]]] = {}
        self.write_mesh_status_error: Exception | None = None
        self.list_clients_by_public_key_error: Exception | None = None
        # Mirrors Users/{uid}.accountSlot (uid -> allocated slot) plus the raw
        # Counters/accountSlots.nextSlot value the real doc would hold. Slot 0
        # is reserved, so a seeded fleet starts at 1 (see
        # repository.MIN_ACCOUNT_SLOT). None models a deleted/missing counter
        # doc; tests may also set this to an out-of-range int to model a
        # corrupted counter, both of which now fail closed end to end (see
        # repository.next_account_slot and docs/access-control-list.md,
        # "Account slot allocation").
        self.account_slots: dict[str, int] = {}
        self.account_slot_counter: int | None = 1
        # Last policy status written per region, keyed by region_id.
        self.policy_status: dict[str, PolicyStatus] = {}
        self.write_policy_status_error: Exception | None = None

    def get_role(self, uid: str) -> Role | None:
        return self.roles.get(uid)

    def get_user(self, uid: str) -> UserDoc | None:
        return self.users.get(uid)

    def get_region(self, region_id: str) -> RegionDoc | None:
        return self.regions.get(region_id)

    def list_enabled_regions(self) -> list[RegionDoc]:
        return sorted(
            [region for region in self.regions.values() if region.enabled is True],
            key=region_display_order,
        )

    def list_regions(self) -> list[RegionDoc]:
        return sorted(self.regions.values(), key=region_display_order)

    def upsert_region(self, registration: RegionRegistration, *, set_enabled: bool | None) -> RegionDoc:
        # meshEnabled mirrors the real Firestore create-only semantics: seeded false
        # only when the region doc does not yet exist, otherwise carried forward
        # untouched (operator-owned via the dashboard afterward). set_enabled=None
        # preserves the stored enabled value, seeding false on create.
        existing = self.regions.get(registration.region_id)
        mesh_enabled = existing.mesh_enabled if existing is not None else False
        # Real Firestore merge preserves tunnelIndexV4/V6 across a re-register
        # the same way it preserves meshEnabled: this write never sets them.
        tunnel_index_v4 = existing.tunnel_index_v4 if existing is not None else None
        tunnel_index_v6 = existing.tunnel_index_v6 if existing is not None else None
        if set_enabled is None:
            enabled = existing.enabled if existing is not None else False
        else:
            enabled = set_enabled
        region = RegionDoc(
            region_id=registration.region_id,
            display_name=registration.display_name,
            enabled=enabled,
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
            tunnel_index_v4=tunnel_index_v4,
            tunnel_index_v6=tunnel_index_v6,
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
        if self.list_clients_by_public_key_error is not None:
            raise self.list_clients_by_public_key_error
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
                # Slot first, role second: the real provisioning transaction
                # commits both or neither, so a failed allocation must not
                # leave a rostered account behind.
                existing = self._with_account_slot(existing)
                self.roles[existing.uid] = Role.USER
                return CreateUserResult(user=existing, already_existed=True)
            self.created_user_count += 1
            uid = f"created-user-{self.created_user_count}"
            while uid in self.users or uid in self.roles:
                self.created_user_count += 1
                uid = f"created-user-{self.created_user_count}"
            user = UserDoc(uid=uid, email=email, created_at=utc_now())
            # _with_account_slot writes self.users itself, and raises before
            # any mutation when the counter cannot allocate.
            user = self._with_account_slot(user)
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
        # Production stores the slot on Users/{uid} only, so hard-deleting that
        # document takes the slot out of every live scan with it - the reason
        # the counter, not a live scan, is the allocation authority.
        self.account_slots.pop(uid, None)
        for key, client in list(self.clients.items()):
            if client.owner_uid == uid:
                del self.clients[key]

    def mark_account_clients_inactive(self, uid: str) -> AccountCleanupTally:
        # Mirrors firebase.py's semantics, including ignoring local_region_id:
        # fleet-wide, not gated to this fake's own region. Region grouping
        # uses client.region_id, the fake's stand-in for the real path-based
        # region (the fake has no Firestore document path to fall back from).
        self.mark_account_clients_inactive_calls += 1
        if self.mark_account_clients_inactive_error is not None:
            raise self.mark_account_clients_inactive_error
        clients_by_region: dict[str, int] = {}
        marked_by_region: dict[str, int] = {}
        with self._lock:
            for key, client in list(self.clients.items()):
                if client.owner_uid != uid:
                    continue
                clients_by_region[client.region_id] = clients_by_region.get(client.region_id, 0) + 1
                if client.status not in {ClientStatus.ACTIVE, ClientStatus.CREATING}:
                    continue
                marked_by_region[client.region_id] = marked_by_region.get(client.region_id, 0) + 1
                now = utc_now()
                self.clients[key] = replace(
                    client,
                    status=ClientStatus.REMOVED,
                    wireguard_config=None,
                    updated_at=now,
                    removed_at=now,
                    last_error_code=None,
                    last_error_message=None,
                )
        return AccountCleanupTally(clients_by_region=clients_by_region, marked_by_region=marked_by_region)

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
            # Lazy allocation covers accounts provisioned before this feature.
            # Mirrors the real transaction's ordering: the slot is allocated
            # before anything is mutated, so a failed allocation leaves no
            # user, slot, client, or advanced tunnel index behind.
            owner = self.users.get(owner_uid) or UserDoc(
                uid=owner_uid,
                email=owner_email or "",
                created_at=utc_now(),
            )
            self._with_account_slot(owner)
            next_index = next_tunnel_index(
                stored_index=region.tunnel_index_v4,
                used_indices=used_tunnel_indices(
                    allocated_clients,
                    ipv4_cidr=self.ipv4_cidr,
                    ipv6_cidr=self.ipv6_cidr,
                ),
                ipv4_cidr=self.ipv4_cidr,
            )
            assigned_ipv4, assigned_ipv6 = tunnel_addresses_for_index(
                index=next_index,
                ipv4_cidr=self.ipv4_cidr,
                ipv6_cidr=self.ipv6_cidr,
            )
            self.regions[region_id] = replace(region, tunnel_index_v4=next_index, tunnel_index_v6=next_index)
            client_id = new_client_id()
            while (owner_uid, region_id, client_id) in self.clients:
                client_id = new_client_id()

            now = utc_now()
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

    def list_policy_clients(self) -> list[PolicyClientEntry]:
        return [
            PolicyClientEntry(
                owner_uid=client.owner_uid,
                region_id=client.region_id,
                assigned_tunnel_ipv4=client.assigned_tunnel_ipv4,
                assigned_tunnel_ipv6=client.assigned_tunnel_ipv6,
            )
            for client in self.clients.values()
            if client.status == ClientStatus.ACTIVE and client.client_public_key
        ]

    def list_account_slots(self) -> dict[str, int]:
        # Mirrors firebase.py: validated once, here, the same way the real
        # Firestore read is validated (see repository.valid_account_slot).
        slots: dict[str, int] = {}
        for uid, raw in self.account_slots.items():
            slot = valid_account_slot(raw)
            if slot is not None:
                slots[uid] = slot
        return slots

    def list_admin_uids(self) -> set[str]:
        return {uid for uid, role in self.roles.items() if role == Role.ADMIN}

    def get_account_slot(self, uid: str) -> int | None:
        return valid_account_slot(self.account_slots.get(uid))

    def write_policy_status(self, status: PolicyStatus) -> None:
        if self.write_policy_status_error is not None:
            raise self.write_policy_status_error
        self.policy_status[status.region_id] = status

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

    def _allocate_account_slot(self) -> int:
        # Mirrors firebase.py's transactional counter allocation: the stored
        # counter is the only allocation authority, and the live assigned
        # slots are read alongside it purely to disprove a regressed counter.
        # A deleted or corrupted counter raises AccountSlotUnavailableError
        # instead of being re-derived (see repository.next_account_slot).
        slot = next_account_slot(
            stored_next_slot=self.account_slot_counter,
            assigned_slots=list(self.account_slots.values()),
        )
        self.account_slot_counter = slot + 1
        return slot

    def _with_account_slot(self, user: UserDoc) -> UserDoc:
        # Allocation is once per account, never reused: reuse a slot already
        # on the user doc or already recorded for this uid before minting one.
        slot = user.account_slot or self.account_slots.get(user.uid)
        if slot is None:
            slot = self._allocate_account_slot()
        self.account_slots[user.uid] = slot
        if user.account_slot != slot:
            user = replace(user, account_slot=slot)
        self.users[user.uid] = user
        return user


class FakeWireGuardManager(WireGuardManager):
    def __init__(
        self,
        *,
        tunnel_network_v4: str = "10.0.0.0/24",
        tunnel_network_v6: str = "fd42:42:42::/64",
    ):
        self.peers: dict[str, tuple[str, str]] = {}
        self.mesh_peers: dict[str, MeshPeer] = {}
        self.mesh_endpoint_addresses: dict[str, frozenset[str]] = {}
        self.mesh_keepalives: dict[str, int | None] = {}
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
        self.fail_mesh_apply_count = 0
        self.fail_mesh_remove_count = 0
        self.fail_route_replace_versions: set[int] = set()
        self.fail_route_delete_versions: set[int] = set()
        self.fail_add_transient = False
        self.fail_remove_transient = False
        self.locked = False
        # A real `wg show dump` reports endpoint addresses, never hostnames, so the
        # fake resolves each hostname to a stable synthetic address and stores that
        # as the live endpoint. Tests can pre-seed an answer or force a lookup
        # failure to exercise the same drift path as the real manager.
        self.resolved_endpoints: dict[str, frozenset[str]] = {}
        self.resolve_failure_hosts: set[str] = set()

    @contextmanager
    def lock(self, *, blocking: bool = True) -> Iterator[None]:
        if self.locked and not blocking:
            # Mirrors LOCK_NB on the real manager: a contended non-blocking
            # acquisition sheds instead of queueing.
            raise SyncInProgressError()
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

    def resolve_endpoint(self, host: str) -> Sequence[str]:
        if host in self.resolve_failure_hosts:
            return ()
        addresses = self.resolved_endpoints.get(host)
        if addresses is None:
            addresses = frozenset({f"203.0.113.{len(self.resolved_endpoints) + 1}"})
            self.resolved_endpoints[host] = addresses
        return tuple(sorted(addresses))

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
        self.mesh_endpoint_addresses.pop(public_key, None)
        self.mesh_keepalives.pop(public_key, None)
        return OperationResult.SUCCESS

    def current_peers(self) -> dict[str, frozenset[str]]:
        return {
            public_key: snapshot.allowed_ips
            for public_key, snapshot in self.peer_snapshots().items()
        }

    def peer_snapshots(self) -> dict[str, LivePeerSnapshot]:
        current = {
            public_key: LivePeerSnapshot(
                public_key=public_key,
                allowed_ips=frozenset({tunnel_ipv4, tunnel_ipv6}),
                persistent_keepalive=25,
            )
            for public_key, (tunnel_ipv4, tunnel_ipv6) in self.peers.items()
        }
        for public_key, peer in self.mesh_peers.items():
            current[public_key] = LivePeerSnapshot(
                public_key=public_key,
                endpoint_addresses=self.mesh_endpoint_addresses.get(
                    public_key, frozenset(self.resolve_endpoint(peer.endpoint_host))
                ),
                endpoint_port=peer.endpoint_port,
                allowed_ips=frozenset({peer.allowed_network_v4, peer.allowed_network_v6}),
                persistent_keepalive=self.mesh_keepalives.get(public_key, 25),
            )
        return current

    def sync_peers(
        self,
        desired: dict[str, tuple[str, str]],
        *,
        mesh: Sequence[MeshPeer] = (),
        known_mesh_networks: Sequence[str] = (),
        known_region_keys: Sequence[str] = (),
        protected_client_keys: Sequence[str] = (),
    ) -> PeerSyncResult:
        self._require_lock()
        self.sync_calls += 1
        # Same validator the real manager runs, so a candidate set the host would
        # reject (bad field, local/cross-peer overlap, duplicate key) cannot pass
        # here either. Client keys stay symbolic on purpose - readable test keys -
        # and client validation is covered against the real manager. A rejection
        # drops the candidate and is raised after removal, as the manager does.
        validated_mesh, mesh_error = validate_mesh_peers(
            mesh,
            tunnel_network_v4=self.tunnel_network_v4,
            tunnel_network_v6=self.tunnel_network_v6,
        )
        mesh_by_key = {peer.public_key: peer for peer in validated_mesh}
        known_keys = set(known_region_keys) | set(mesh_by_key)
        protected_keys = {key for key in protected_client_keys if is_valid_wireguard_key(key)}

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

        # Mirrors LocalWireGuardManager: unknown-peer removal runs before the mesh
        # apply phase so an unreachable mesh endpoint cannot block it.
        mesh_changes: list[MeshPeerChange] = []
        apply_error: WireGuardApplyFailedError | None = mesh_error
        for public_key in set(self.peers) | set(self.mesh_peers):
            if public_key in desired or public_key in mesh_by_key or public_key in protected_keys:
                continue
            if public_key in self.mesh_peers and self.fail_mesh_remove_count:
                self.fail_mesh_remove_count -= 1
                # Mirrors LocalWireGuardManager: the peer stays live, no change is
                # recorded, and the rest of the pass still converges.
                apply_error = apply_error or WireGuardApplyFailedError("Simulated mesh peer removal failure.")
                continue
            self.peers.pop(public_key, None)
            self.mesh_peers.pop(public_key, None)
            self.mesh_endpoint_addresses.pop(public_key, None)
            self.mesh_keepalives.pop(public_key, None)
            if public_key in known_keys:
                mesh_changes.append(MeshPeerChange(public_key=public_key, action=PEER_REMOVED))
            else:
                changes.append(PeerChange(public_key, PEER_REMOVED))

        applied_mesh: list[MeshPeer] = []
        routed_mesh: list[MeshPeer] = []
        for public_key, peer in mesh_by_key.items():
            self.mesh_apply_calls += 1
            was_live = public_key in self.mesh_peers or public_key in self.peers
            live = self.peer_snapshots().get(public_key)
            if self.fail_mesh_apply_count:
                self.fail_mesh_apply_count -= 1
                # Mirrors LocalWireGuardManager: a still-live peer with the desired
                # ranges keeps its route even when the re-apply failed.
                if live is not None and live.allowed_ips == frozenset(
                    {peer.allowed_network_v4, peer.allowed_network_v6}
                ):
                    routed_mesh.append(peer)
                apply_error = apply_error or WireGuardApplyFailedError("Simulated mesh peer apply failure.")
                continue
            applied_mesh.append(peer)
            routed_mesh.append(peer)
            drifted = was_live and (
                live is None or mesh_peer_drifted(live, peer, self.resolve_endpoint)
            )
            self.mesh_peers[public_key] = peer
            self.mesh_endpoint_addresses[public_key] = frozenset(self.resolve_endpoint(peer.endpoint_host))
            self.mesh_keepalives[public_key] = 25
            if not was_live:
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
            elif drifted:
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

        # Mirrors LocalWireGuardManager: a route failure never replaces an earlier
        # peer failure, and never skips the reconciliation that follows it.
        route_changes: list[RouteChange] = []
        try:
            route_changes = self._reconcile_routes(routed_mesh, known_mesh_networks)
        except WireGuardApplyFailedError as exc:
            apply_error = apply_error or exc
        if apply_error is not None:
            raise apply_error

        return PeerSyncResult(
            changes=tuple(changes),
            mesh_changes=tuple(mesh_changes),
            mesh_applied_peers=tuple(applied_mesh),
            route_changes=tuple(route_changes),
        )

    def _reconcile_routes(
        self,
        mesh_peers: Iterable[MeshPeer],
        known_mesh_networks: Sequence[str],
    ) -> list[RouteChange]:
        # Normalized exactly as the real sweep does, so `reclaimed` matches for
        # non-canonical or wrong-width known values.
        known = {
            normalized
            for value in known_mesh_networks
            for normalized in (soft_normalize_network(value),)
            if normalized is not None
        }
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
            if version in self.fail_route_replace_versions:
                self.fail_route_replace_versions.remove(version)
                raise WireGuardApplyFailedError("Simulated mesh route apply failure.")
            current[cidr] = "static"
            if not existed:
                changes.append(RouteChange(cidr, PEER_ADDED))

        for cidr in list(current):
            if cidr in desired or cidr == local_network or current[cidr] == "kernel":
                continue
            if not is_subnet_of(ip_network(cidr), aggregate_net):
                continue
            if version in self.fail_route_delete_versions:
                self.fail_route_delete_versions.remove(version)
                raise WireGuardApplyFailedError("Simulated mesh route removal failure.")
            del current[cidr]
            changes.append(RouteChange(cidr, PEER_REMOVED, reclaimed=cidr not in known))

        return changes


class FakePolicyManager(PolicyManager):
    """Mirrors FakeWireGuardManager: rows live in-memory, mutations must run
    under lock(), and failures are injectable via the fail_* counters."""

    def __init__(self):
        self.rows: dict[tuple[str, str], PolicyRow] = {}
        self.infra_v4: tuple[str, ...] = ()
        self.infra_v6: tuple[str, ...] = ()
        self.apply_calls = 0
        self.add_row_calls = 0
        self.read_calls = 0
        self.fail_apply_count = 0
        self.fail_add_row_count = 0
        self.fail_read_count = 0
        self.locked = False

    @contextmanager
    def lock(self, *, blocking: bool = True) -> Iterator[None]:
        if self.locked and not blocking:
            raise SyncInProgressError()
        if self.locked:
            raise AssertionError("Policy lock() is not reentrant.")
        self.locked = True
        try:
            yield
        finally:
            self.locked = False

    def _require_lock(self) -> None:
        if not self.locked:
            raise AssertionError("Policy mutation must run inside lock().")

    def apply_map(
        self,
        rows: Sequence[PolicyRow],
        *,
        infra_v4: Sequence[str] = (),
        infra_v6: Sequence[str] = (),
    ) -> None:
        self._require_lock()
        self.apply_calls += 1
        if self.fail_apply_count:
            self.fail_apply_count -= 1
            raise PolicyApplyFailedError("Simulated policy map apply failure.")
        self.rows = {(row.address_v4, row.address_v6): row for row in rows}
        self.infra_v4 = tuple(infra_v4)
        self.infra_v6 = tuple(infra_v6)

    def add_client_row(self, row: PolicyRow) -> None:
        self._require_lock()
        self.add_row_calls += 1
        if self.fail_add_row_count:
            self.fail_add_row_count -= 1
            raise PolicyApplyFailedError("Simulated policy row apply failure.")
        self.rows[(row.address_v4, row.address_v6)] = row

    def read_map(self) -> LivePolicyMap:
        self.read_calls += 1
        if self.fail_read_count:
            self.fail_read_count -= 1
            raise PolicyApplyFailedError("Simulated policy map read failure.")
        return LivePolicyMap(v4=self._family(4), v6=self._family(6))

    def _family(self, version: int) -> LivePolicyFamily:
        # Mirrors the real host: cg_tunnel4/6 are the static mesh aggregate
        # bootstrap.sh installs and apply_map never touches; cg_infra4/6 come
        # from apply_map's own args; cg_admin4/6, cg_slot4/6, and cg_pairs4/6
        # are all derived from the same applied rows, so a role change that
        # flips a row's .admin flag changes the admin set and therefore the
        # family hash through the same path production code exercises.
        address_attr = "address_v4" if version == 4 else "address_v6"
        tunnel = (MESH_AGGREGATE_V4,) if version == 4 else (MESH_AGGREGATE_V6,)
        infra = self.infra_v4 if version == 4 else self.infra_v6
        admin = tuple(
            sorted(
                (getattr(row, address_attr) for row in self.rows.values() if row.admin),
                key=lambda address: ip_address(address).packed,
            )
        )
        slots = tuple(
            sorted(
                ((getattr(row, address_attr), row.slot) for row in self.rows.values()),
                key=lambda item: ip_address(item[0]).packed,
            )
        )
        return LivePolicyFamily(
            version=version,
            tunnel=tunnel,
            infra=tuple(sorted(infra, key=lambda address: ip_address(address).packed)),
            admin=admin,
            slots=slots,
            pairs=slots,  # cg_pairs carries the same (address, mark) content as cg_slot.
        )

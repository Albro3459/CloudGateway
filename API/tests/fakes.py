import subprocess
from contextlib import contextmanager
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
    RegionDoc,
    UserDoc,
    assert_capacity_available,
    assert_user_limit_available,
    assign_tunnel_ips,
    clean_client_name,
    ensure_delete_allowed,
    ensure_local_region,
    ensure_region_enabled,
    new_client_id,
    require_region,
    utc_now,
)
from src.wireguard import PeerSyncResult, WireGuardKeypair, WireGuardManager

FAKE_PRIVATE_KEY="OUJITKcYj6d2yNq4H2N8nmFzEVKW6Q7sVpnsZWgz8GA="
FAKE_PUBLIC_KEY="eZEOz7uD1jjbTD70Uv+aJcZ0ASxsxz9bTKZQ9vdOQCo="
FAKE_PUBLIC_KEY_2="QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI="
FAKE_SERVER_PUBLIC_KEY="4jVSiiUySTwbsm72pcNxtEUhE37gESbsLPo3nCAaBks="


@dataclass(frozen=True)
class FakeCommandCall:
    args: tuple[str, ...]
    input: str | None
    shell: bool


class FakeWireGuardCommandRunner:
    """Emulates the wg CLI: peer state lives in self.peers (pubkey -> allowed-ips csv)."""

    def __init__(
        self,
        *,
        fail_set_count: int = 0,
        fail_show_count: int = 0,
        failure_stderr: str = "simulated command failure",
    ):
        self.calls: list[FakeCommandCall] = []
        self.peers: dict[str, str] = {}
        self.fail_set_count = fail_set_count
        self.fail_show_count = fail_show_count
        self.failure_stderr = failure_stderr

    def __call__(
        self,
        args,
        *,
        input=None,
        capture_output=False,
        text=False,
        check=False,
        shell=False,
    ):
        if shell is not False:
            raise AssertionError("WireGuard commands must run with shell=False.")

        args = tuple(args)
        self.calls.append(FakeCommandCall(args=args, input=input, shell=shell))

        if args == ("wg", "genkey"):
            return subprocess.CompletedProcess(args, 0, stdout=f"{FAKE_PRIVATE_KEY}\n", stderr="")
        if args == ("wg", "pubkey"):
            return subprocess.CompletedProcess(args, 0, stdout=f"{FAKE_PUBLIC_KEY}\n", stderr="")
        if args[:2] == ("wg", "show") and args[3:] == ("dump",):
            if self.fail_show_count:
                self.fail_show_count -= 1
                raise subprocess.CalledProcessError(1, args, stderr=self.failure_stderr)
            lines = [f"{FAKE_PRIVATE_KEY}\t{FAKE_SERVER_PUBLIC_KEY}\t51820\toff"]
            for public_key, allowed_ips in self.peers.items():
                lines.append(f"{public_key}\t(none)\t(none)\t{allowed_ips or '(none)'}\t0\t0\t0\t25")
            return subprocess.CompletedProcess(args, 0, stdout="\n".join(lines) + "\n", stderr="")
        if args[:2] == ("wg", "set") and len(args) >= 5 and args[3] == "peer":
            if self.fail_set_count:
                self.fail_set_count -= 1
                raise subprocess.CalledProcessError(1, args, stderr=self.failure_stderr)
            public_key = args[4]
            if args[5:] == ("remove",):
                self.peers.pop(public_key, None)
            else:
                self.peers[public_key] = args[args.index("allowed-ips") + 1]
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        raise AssertionError(f"Unexpected WireGuard command: {args}")


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
        self.users: dict[str, UserDoc] = {}
        self.regions: dict[str, RegionDoc] = {}
        self.clients: dict[tuple[str, str, str], ClientDoc] = {}
        self.disabled_auth_uids: set[str] = set()
        self.revoked_auth_uids: list[str] = []
        self.created_user_count = 0
        self.mark_client_active_error: Exception | None = None
        self.create_user_error: Exception | None = None
        self.delete_client_error: Exception | None = None

    def get_role(self, uid: str) -> Role | None:
        return self.roles.get(uid)

    def get_user(self, uid: str) -> UserDoc | None:
        return self.users.get(uid)

    def get_region(self, region_id: str) -> RegionDoc | None:
        return self.regions.get(region_id)

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

    def create_user(self, *, email: str, display_name: str | None) -> CreateUserResult:
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
                if display_name is not None:
                    existing = replace(existing, display_name=display_name)
                    self.users[existing.uid] = existing
                self.roles[existing.uid] = Role.USER
                return CreateUserResult(user=existing, already_existed=True)
            self.created_user_count += 1
            uid = f"created-user-{self.created_user_count}"
            while uid in self.users or uid in self.roles:
                self.created_user_count += 1
                uid = f"created-user-{self.created_user_count}"
            user = UserDoc(uid=uid, email=email, display_name=display_name, created_at=utc_now())
            self.users[uid] = user
            self.roles[uid] = Role.USER
            return CreateUserResult(user=user)

    def disable_auth_user(self, uid: str) -> None:
        self.disabled_auth_uids.add(uid)
        self.revoked_auth_uids.append(uid)

    def enable_auth_user(self, uid: str) -> None:
        self.disabled_auth_uids.discard(uid)

    def reserve_client(
        self,
        *,
        owner_uid: str,
        owner_email: str | None,
        owner_display_name: str | None,
        region_id: str,
        client_name: str | None,
    ) -> ClientDoc:
        ensure_local_region(region_id, self.local_region_id)
        with self._lock:
            region = ensure_region_enabled(self.regions.get(region_id))
            allocated_clients = self._allocated_region_clients(region_id)
            owner_allocated_count = sum(1 for client in allocated_clients if client.owner_uid == owner_uid)
            assert_capacity_available(allocated_count=len(allocated_clients), capacity_limit=region.capacity_limit)
            assert_user_limit_available(
                requester_role=self.roles.get(owner_uid),
                owner_allocated_count=owner_allocated_count,
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
                    display_name=owner_display_name,
                    created_at=now,
                ),
            )
            client = ClientDoc(
                client_id=client_id,
                owner_uid=owner_uid,
                owner_email=owner_email or "",
                owner_display_name=owner_display_name,
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
            self.regions[region_id] = replace(region, active_client_count=len(allocated_clients) + 1, updated_at=now)
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
        region = self.regions[region_id]
        allocated_count = len(self._allocated_region_clients(region_id))
        next_count = max(0, allocated_count - 1) if client.status in ALLOCATED_CLIENT_STATUSES else allocated_count
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
        self.regions[region_id] = replace(region, active_client_count=next_count, updated_at=now)
        return updated

    def _allocated_region_clients(self, region_id: str) -> list[ClientDoc]:
        return [
            client
            for client in self.clients.values()
            if client.region_id == region_id and client.status in ALLOCATED_CLIENT_STATUSES
        ]

    def _require_client(self, *, owner_uid: str, region_id: str, client_id: str) -> ClientDoc:
        client = self.clients.get((owner_uid, region_id, client_id))
        if client is None:
            raise ClientNotFoundError()
        if client.client_id != client_id or client.owner_uid != owner_uid or client.region_id != region_id:
            raise ClientNotFoundError()
        return client


class FakeWireGuardManager(WireGuardManager):
    def __init__(self):
        self.peers: dict[str, tuple[str, str]] = {}
        self.keypair_count = 0
        self.add_peer_calls = 0
        self.remove_peer_calls = 0
        self.sync_calls = 0
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
        if public_key not in self.peers:
            return OperationResult.NOOP
        del self.peers[public_key]
        return OperationResult.SUCCESS

    def current_peers(self) -> dict[str, frozenset[str]]:
        return {
            public_key: frozenset({tunnel_ipv4, tunnel_ipv6})
            for public_key, (tunnel_ipv4, tunnel_ipv6) in self.peers.items()
        }

    def sync_peers(self, desired: dict[str, tuple[str, str]]) -> PeerSyncResult:
        self._require_lock()
        self.sync_calls += 1
        added = updated = removed = 0
        for public_key, ips in desired.items():
            if public_key not in self.peers:
                self.peers[public_key] = ips
                added += 1
            elif self.peers[public_key] != ips:
                self.peers[public_key] = ips
                updated += 1
        for public_key in list(self.peers):
            if public_key not in desired:
                del self.peers[public_key]
                removed += 1
        return PeerSyncResult(added=added, updated=updated, removed=removed)

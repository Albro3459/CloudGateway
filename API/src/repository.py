from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime, timezone
from ipaddress import ip_network
from uuid import uuid4

from .enums import ClientStatus, Role
from .errors import (
    AdminRequiredError,
    CapacityReachedError,
    LimitReachedError,
    RegionDisabledError,
    RegionMismatchError,
)


DEFAULT_CLIENT_NAME = "CloudGateway Client"
# Fallback per-normal-user client limit when a region doc omits userClientLimit.
DEFAULT_USER_CLIENT_LIMIT = 3
ALLOCATED_CLIENT_STATUSES = {ClientStatus.CREATING, ClientStatus.ACTIVE}


@dataclass(frozen=True)
class RegionDoc:
    region_id: str
    display_name: str
    enabled: bool
    wireguard_endpoint_ipv4: str
    wireguard_endpoint_ipv6: str | None
    wireguard_port: int
    wireguard_dns_ipv4: str
    wireguard_dns_ipv6: str
    wireguard_public_key: str
    capacity_limit: int
    active_client_count: int
    user_client_limit: int = DEFAULT_USER_CLIENT_LIMIT
    wireguard_endpoint_hostname: str = ""
    display_order: int | None = None
    health_status: str | None = None
    updated_at: datetime | None = None


@dataclass(frozen=True)
class RegionRegistration:
    """Infra + config fields a host self-reports when registering its region doc."""

    region_id: str
    display_name: str
    display_order: int
    capacity_limit: int
    user_client_limit: int
    wireguard_endpoint_ipv4: str
    wireguard_endpoint_hostname: str
    wireguard_port: int
    wireguard_dns_ipv4: str
    wireguard_dns_ipv6: str
    wireguard_public_key: str
    wireguard_endpoint_ipv6: str | None = None


@dataclass(frozen=True)
class UserDoc:
    uid: str
    email: str
    display_name: str | None
    created_at: datetime | None = None
    disabled: bool = False


@dataclass(frozen=True)
class CreateUserResult:
    user: UserDoc
    already_existed: bool = False


@dataclass(frozen=True)
class ClientDoc:
    client_id: str
    owner_uid: str
    owner_email: str
    owner_display_name: str | None
    client_name: str
    region_id: str
    status: ClientStatus
    assigned_tunnel_ipv4: str
    assigned_tunnel_ipv6: str
    server_endpoint_ipv4: str
    server_public_key: str
    client_public_key: str
    wireguard_config: str | None
    server_endpoint_hostname: str = ""
    created_at: datetime | None = None
    updated_at: datetime | None = None
    removed_at: datetime | None = None
    last_error_code: str | None = None
    last_error_message: str | None = None


def clean_client_name(value: str | None) -> str:
    if value is None:
        return DEFAULT_CLIENT_NAME
    value = value.strip()
    return value or DEFAULT_CLIENT_NAME


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def ensure_local_region(region_id: str, local_region_id: str) -> None:
    if region_id != local_region_id:
        raise RegionMismatchError()


def ensure_region_enabled(region: RegionDoc | None) -> RegionDoc:
    if region is None or not region.enabled:
        raise RegionDisabledError()
    return region


def require_region(region: RegionDoc | None) -> RegionDoc:
    # Delete/cleanup paths must keep working when a region is disabled for
    # maintenance or drain; they only need the region doc for counter updates.
    if region is None:
        raise RegionDisabledError()
    return region


def role_or_user(role: Role | None) -> Role:
    return role or Role.USER


def ensure_delete_allowed(*, requester_uid: str, requester_role: Role | None, target_uid: str) -> None:
    if requester_uid != target_uid and role_or_user(requester_role) != Role.ADMIN:
        raise AdminRequiredError()


def assert_capacity_available(*, allocated_count: int, capacity_limit: int) -> None:
    if allocated_count >= capacity_limit:
        raise CapacityReachedError()


def assert_user_limit_available(
    *, requester_role: Role | None, owner_allocated_count: int, user_client_limit: int
) -> None:
    if role_or_user(requester_role) != Role.ADMIN and owner_allocated_count >= user_client_limit:
        raise LimitReachedError()


def assign_tunnel_ips(*, ipv4_cidr: str, ipv6_cidr: str, used_ipv4: set[str], used_ipv6: set[str]) -> tuple[str, str]:
    ipv4_network = ip_network(ipv4_cidr, strict=False)
    ipv6_network = ip_network(ipv6_cidr, strict=False)

    ipv4_hosts = ipv4_network.hosts()
    ipv6_hosts = ipv6_network.hosts()
    try:
        next(ipv4_hosts)
        next(ipv6_hosts)
    except StopIteration as exc:
        raise CapacityReachedError()

    for ipv4, ipv6 in zip(ipv4_hosts, ipv6_hosts, strict=False):
        assigned_ipv4 = f"{ipv4}/32"
        assigned_ipv6 = f"{ipv6}/128"
        if assigned_ipv4 not in used_ipv4 and assigned_ipv6 not in used_ipv6:
            return assigned_ipv4, assigned_ipv6
    raise CapacityReachedError()


def new_client_id() -> str:
    return str(uuid4())


class FirebaseRepository(ABC):
    @abstractmethod
    def get_role(self, uid: str) -> Role | None:
        """Return the role for a UID, or None when no role doc exists."""

    @abstractmethod
    def get_user(self, uid: str) -> UserDoc | None:
        """Return a user document, or None when it does not exist."""

    @abstractmethod
    def get_region(self, region_id: str) -> RegionDoc | None:
        """Return a region document, or None when it does not exist."""

    @abstractmethod
    def upsert_region(self, registration: RegionRegistration, *, set_enabled: bool) -> RegionDoc:
        """Create or update a region doc from host-reported infra fields.

        activeClientCount is preserved when the doc exists (0 on insert) and is never
        reset. enabled is set to set_enabled. Returns the resulting region document.
        """

    @abstractmethod
    def get_client(self, *, owner_uid: str, region_id: str, client_id: str) -> ClientDoc | None:
        """Return a client document, or None when it does not exist."""

    @abstractmethod
    def list_active_clients(self, region_id: str) -> list[ClientDoc]:
        """Return active clients with a public key for one region (peer sync input)."""

    @abstractmethod
    def list_admin_emails(self) -> list[str]:
        """Return non-empty admin user emails, de-duplicated case-insensitively."""

    @abstractmethod
    def create_user(self, *, email: str, display_name: str | None) -> CreateUserResult:
        """Create an Auth user and matching Users/Roles documents.

        When the Auth account already exists but has no provisioning docs,
        provision it instead and report already_existed.
        """

    @abstractmethod
    def disable_auth_user(self, uid: str) -> None:
        """Disable an Auth user and revoke refresh tokens."""

    @abstractmethod
    def enable_auth_user(self, uid: str) -> None:
        """Enable a disabled Auth user."""

    @abstractmethod
    def reserve_client(
        self,
        *,
        owner_uid: str,
        owner_email: str | None,
        owner_display_name: str | None,
        region_id: str,
        client_name: str | None,
    ) -> ClientDoc:
        """Reserve a creating client document and regional capacity."""

    @abstractmethod
    def mark_client_active(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        client_public_key: str,
        wireguard_config: str,
    ) -> ClientDoc:
        """Store generated client material after host-side WireGuard work succeeds."""

    @abstractmethod
    def mark_client_failed(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        error_code: str,
        error_message: str,
    ) -> ClientDoc:
        """Mark a creating client failed and repair regional counters."""

    @abstractmethod
    def remove_client_reservation(
        self,
        *,
        owner_uid: str,
        region_id: str,
        client_id: str,
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> ClientDoc:
        """Mark a reserved client removed and repair regional counters."""

    @abstractmethod
    def delete_client(
        self,
        *,
        requester_uid: str,
        target_uid: str,
        region_id: str,
        client_id: str,
    ) -> ClientDoc:
        """Reserve client deletion by marking the client removed and repairing counters."""

from abc import ABC, abstractmethod
from collections.abc import Collection, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from ipaddress import IPv4Network, IPv6Network, ip_address, ip_network
from uuid import uuid4

from .enums import ClientStatus, MeshPeerStatus, Role
from .errors import (
    AccountSlotUnavailableError,
    AdminRequiredError,
    CapacityReachedError,
    LimitReachedError,
    RegionDisabledError,
    RegionMismatchError,
)


ALLOCATED_CLIENT_STATUSES = {ClientStatus.CREATING, ClientStatus.ACTIVE}


@dataclass(frozen=True)
class RegionDoc:
    region_id: str
    display_name: str
    enabled: bool
    wireguard_endpoint_ipv4: str
    wireguard_endpoint_ipv6: str | None
    wireguard_port: int | None
    wireguard_dns_ipv4: str
    wireguard_dns_ipv6: str
    wireguard_public_key: str
    capacity_limit: int
    wireguard_endpoint_hostname: str = ""
    display_order: int | None = None
    health_status: str | None = None
    updated_at: datetime | None = None
    tunnel_network_v4: str = ""
    tunnel_network_v6: str = ""
    mesh_enabled: bool = False
    # Per-region monotonic client-address allocator index; see next_tunnel_index.
    tunnel_index_v4: int | None = None
    tunnel_index_v6: int | None = None


@dataclass(frozen=True)
class RegionRegistration:
    """Infra + config fields a host self-reports when registering its region doc."""

    region_id: str
    display_name: str
    display_order: int
    capacity_limit: int
    wireguard_endpoint_ipv4: str
    wireguard_endpoint_hostname: str
    wireguard_port: int
    wireguard_dns_ipv4: str
    wireguard_dns_ipv6: str
    wireguard_public_key: str
    tunnel_network_v4: str
    tunnel_network_v6: str
    wireguard_endpoint_ipv6: str | None = None


@dataclass(frozen=True)
class UserDoc:
    uid: str
    email: str
    created_at: datetime | None = None
    disabled: bool = False
    # Opaque account-scoped ACL identifier, allocated once from
    # Counters/accountSlots and never reused. See next_account_slot.
    account_slot: int | None = None


@dataclass(frozen=True)
class UserRoleDoc:
    uid: str
    role: Role
    per_region_client_limit: int | None = None
    updated_at: datetime | None = None


@dataclass(frozen=True)
class RoleDefaultDoc:
    role: Role
    default_per_region_client_limit: int | None
    updated_at: datetime | None = None


@dataclass(frozen=True)
class CreateUserResult:
    user: UserDoc
    already_existed: bool = False


@dataclass(frozen=True)
class ClientDoc:
    client_id: str
    owner_uid: str
    owner_email: str
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


@dataclass(frozen=True)
class MeshPeerState:
    region_id: str
    endpoint_hostname: str
    public_key: str
    allowed_network_v4: str
    allowed_network_v6: str
    status: MeshPeerStatus
    endpoint_port: int | None = None
    reason_code: str | None = None


@dataclass(frozen=True)
class PolicyClientEntry:
    """One fleet-wide row input to the account-scoped ACL map (see policy.py).

    No updated_at: a malformed timestamp must never be able to abort a
    policy pass, so the field never entered the policy path (see
    TODO/account-scoped-acl.md Wave 2). ClientDoc.updated_at still exists for
    other features.
    """

    owner_uid: str
    region_id: str
    assigned_tunnel_ipv4: str
    assigned_tunnel_ipv6: str


@dataclass(frozen=True)
class PolicyStatus:
    """Observability snapshot for Policy/{regionId}; describes what a region's
    live nftables map actually contains, not what it intended to apply."""

    region_id: str
    map_hash_v4: str
    map_hash_v6: str
    row_count: int


def clean_client_name(value: str) -> str:
    return value.strip()


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


def assert_user_limit_available(*, owner_allocated_count: int, per_region_client_limit: int | None) -> None:
    if per_region_client_limit is not None and owner_allocated_count >= per_region_client_limit:
        raise LimitReachedError()


def region_display_order(region: RegionDoc) -> tuple[int, str]:
    return (region.display_order if region.display_order is not None else 1000, region.region_id)


# Index 1 is the server interface/DNS address (assigned outside this
# allocator, see Region.wireguardDnsIpv4/6); client indices start at 2.
MIN_TUNNEL_INDEX = 2

# Slot 0 is reserved on the wire (see policy.py MIN_SLOT: an unmarked packet's
# mark defaults to 0, meaning "unknown source"), so account slots start at 1.
# MIN_ACCOUNT_SLOT/MAX_ACCOUNT_SLOT must always agree with policy.MIN_SLOT/
# policy.MAX_SLOT (the 32-bit nft mark range). Duplicated here rather than
# imported from policy.py to keep repository.py free of the nft-facing
# module's dependencies; test_repository.py asserts the two pairs never
# drift.
MIN_ACCOUNT_SLOT = 1
MAX_ACCOUNT_SLOT = 2**32 - 1


def region_tunnel_index_bounds(ipv4_cidr: str) -> tuple[int, int]:
    """Client host index range for a region's v4 network: 2..top of host range.

    Only the v4 network bounds the range. v6 is a /64 that never wraps; the
    two indices are kept paired by always deriving both addresses from the
    same index (see tunnel_addresses_for_index), so pairing to the smaller v4
    range is what makes the wrap possible at all.
    """
    network = ip_network(ipv4_cidr, strict=False)
    max_index = network.num_addresses - 2  # exclude network and broadcast addresses
    return MIN_TUNNEL_INDEX, max_index


def _index_from_address(address: str, network: IPv4Network | IPv6Network) -> int | None:
    """Best-effort address -> index; None for anything unparseable or outside network."""
    host = address.partition("/")[0]
    try:
        ip = ip_address(host)
    except ValueError:
        return None
    if ip not in network:
        return None
    return int(ip) - int(network.network_address)


def used_tunnel_indices(clients: Sequence[ClientDoc], *, ipv4_cidr: str, ipv6_cidr: str) -> set[int]:
    """Indices currently held by allocated clients, from whichever of v4/v6 parses.

    A client's v4 and v6 addresses share one index by construction, so either
    field alone reserves the index. Malformed or out-of-network values (stale
    data, a resized network) are skipped rather than raised, since one bad row
    must not block every future allocation.
    """
    ipv4_network = ip_network(ipv4_cidr, strict=False)
    ipv6_network = ip_network(ipv6_cidr, strict=False)
    used: set[int] = set()
    for client in clients:
        v4_index = _index_from_address(client.assigned_tunnel_ipv4, ipv4_network)
        if v4_index is not None:
            used.add(v4_index)
        v6_index = _index_from_address(client.assigned_tunnel_ipv6, ipv6_network)
        if v6_index is not None:
            used.add(v6_index)
    return used


def next_tunnel_index(*, stored_index: int | None, used_indices: set[int], ipv4_cidr: str) -> int:
    """Advance the per-region monotonic index by one, wrapping and skipping in-use.

    NOT dead code: the wrap (index above the top of the host range resets to
    MIN_TUNNEL_INDEX) is a real event, not a theoretical edge case - a /24
    region wraps after roughly 253 lifetime allocations. The in-use skip after
    a wrap is what stops a still-live client's address from being handed out
    twice. Both are exercised by test_next_tunnel_index_wraps_and_skips_in_use.
    """
    min_index, max_index = region_tunnel_index_bounds(ipv4_cidr)
    if stored_index is None or stored_index < min_index or stored_index > max_index:
        candidate = min_index
    else:
        candidate = stored_index + 1
        if candidate > max_index:
            candidate = min_index

    for _ in range(max_index - min_index + 1):
        if candidate not in used_indices:
            return candidate
        candidate += 1
        if candidate > max_index:
            candidate = min_index
    raise CapacityReachedError()


def tunnel_addresses_for_index(*, index: int, ipv4_cidr: str, ipv6_cidr: str) -> tuple[str, str]:
    ipv4_network = ip_network(ipv4_cidr, strict=False)
    ipv6_network = ip_network(ipv6_cidr, strict=False)
    return (
        f"{ipv4_network.network_address + index}/32",
        f"{ipv6_network.network_address + index}/128",
    )


def valid_account_slot(value: object) -> int | None:
    """value as a slot int in MIN_ACCOUNT_SLOT..MAX_ACCOUNT_SLOT, else None.

    The one source of truth for slot range validation across the API package
    (next_account_slot, policy_sync.desired_policy, and
    routes._write_inline_policy_row all call this instead of duplicating the
    range check).
    """
    if isinstance(value, int) and not isinstance(value, bool) and MIN_ACCOUNT_SLOT <= value <= MAX_ACCOUNT_SLOT:
        return value
    return None


def next_account_slot(*, stored_next_slot: object, assigned_slots: Collection[object]) -> int:
    """Next value to allocate from Counters/accountSlots.nextSlot.

    Fails closed instead of ever resetting to MIN_ACCOUNT_SLOT once a slot has
    been handed out (see TODO/account-scoped-acl-review.md finding 2: a lost
    or corrupted counter must never re-issue an already-assigned slot, or two
    accounts collide onto one nftables tenant). `stored_next_slot` and every
    value in `assigned_slots` are raw, unclassified Firestore reads - this
    function does all malformed-value handling so callers never have to.

    stored_next_slot is classified as:
      * valid   - a real int (never bool) in MIN_ACCOUNT_SLOT..MAX_ACCOUNT_SLOT.
      * exhausted - a real int above MAX_ACCOUNT_SLOT. Always raises: an
        exhausted counter must never recover downward, which is the reset
        hazard this function exists to prevent, in a subtler form.
      * absent/malformed - doc missing, field missing, non-int, bool, or
        below MIN_ACCOUNT_SLOT. Enters the recovery path below.
    """
    if isinstance(stored_next_slot, int) and not isinstance(stored_next_slot, bool) and stored_next_slot > MAX_ACCOUNT_SLOT:
        raise AccountSlotUnavailableError()

    valid_stored = valid_account_slot(stored_next_slot)
    if valid_stored is not None:
        # Valid-counter path. A malformed or duplicated slot on some *other*
        # user document does not block allocation: the candidate derived here
        # is provably above every *valid* assigned slot, and Wave 2 excludes
        # non-conforming rows from the policy map, so no on-wire collision is
        # possible. Contrast with the recovery path below, which derives the
        # counter from this data and therefore must be able to trust it.
        valid_assigned = [slot for value in assigned_slots if (slot := valid_account_slot(value)) is not None]
        candidate = valid_stored
        if valid_assigned and candidate <= max(valid_assigned):
            # A counter that would hand out an already-assigned slot is
            # inconsistent and must never be used as-is.
            candidate = max(valid_assigned) + 1
        assigned_for_check = valid_assigned
    else:
        # Recovery path: the counter is absent or malformed. This is the only
        # place a counter may be re-derived, and only "when safe" - every
        # assigned slot must itself be a valid, unique int, or the live data
        # cannot be trusted enough to derive a counter from.
        validated: list[int] = []
        seen: set[int] = set()
        for value in assigned_slots:
            slot = valid_account_slot(value)
            if slot is None or slot in seen:
                raise AccountSlotUnavailableError()
            seen.add(slot)
            validated.append(slot)

        # Zero assigned slots fleet-wide is a genuine first allocation, not a
        # reset, so seeding at MIN_ACCOUNT_SLOT is permitted here.
        candidate = MIN_ACCOUNT_SLOT if not validated else max(validated) + 1
        assigned_for_check = validated

    if candidate > MAX_ACCOUNT_SLOT:
        raise AccountSlotUnavailableError()
    if candidate in assigned_for_check:
        # Defensive: every path above is constructed to make this
        # unreachable.
        raise AccountSlotUnavailableError()
    return candidate


def new_client_id() -> str:
    return str(uuid4())


class FirebaseRepository(ABC):
    @abstractmethod
    def get_role(self, uid: str) -> Role | None:
        """Return the assigned role for a UID, or None when no user-role doc exists."""

    @abstractmethod
    def get_user(self, uid: str) -> UserDoc | None:
        """Return a user document, or None when it does not exist."""

    @abstractmethod
    def get_region(self, region_id: str) -> RegionDoc | None:
        """Return a region document, or None when it does not exist."""

    @abstractmethod
    def list_enabled_regions(self) -> list[RegionDoc]:
        """Return enabled regions sorted by display order."""

    @abstractmethod
    def list_regions(self) -> list[RegionDoc]:
        """Return every region document sorted by display order, enabled or not.

        Sync classifies a live peer as a mesh peer from this set, so a disabled or
        rekeyed region's peer is still recognised as a server peer instead of being
        reported (and audit-logged) as a client peer.
        """

    @abstractmethod
    def upsert_region(self, registration: RegionRegistration, *, set_enabled: bool | None) -> RegionDoc:
        """Create or update a region metadata doc from host-reported infra fields.

        set_enabled=None preserves the stored enabled value (new docs are seeded false),
        so a readiness failure never disables a region that is already serving.
        """

    @abstractmethod
    def write_mesh_status(self, *, region_id: str, mesh_enabled: bool, peers: Sequence[MeshPeerState]) -> None:
        """Write this region's mesh status doc (observability only; best-effort caller)."""

    @abstractmethod
    def get_client(self, *, owner_uid: str, region_id: str, client_id: str) -> ClientDoc | None:
        """Return a client document, or None when it does not exist."""

    @abstractmethod
    def list_active_clients(self, region_id: str) -> list[ClientDoc]:
        """Return active clients with a public key for one region (peer sync input)."""

    @abstractmethod
    def list_allocated_clients(self, region_id: str) -> list[ClientDoc]:
        """Return clients that hold regional capacity for one region."""

    @abstractmethod
    def list_clients_by_public_key(self, region_id: str, public_keys: set[str]) -> list[ClientDoc]:
        """Return clients in one region whose public key is in public_keys."""

    @abstractmethod
    def list_clients_for_owner(self, owner_uid: str) -> list[ClientDoc]:
        """Return every client document owned by one user across all regions and statuses."""

    @abstractmethod
    def list_admin_emails(self) -> list[str]:
        """Return non-empty admin user emails, de-duplicated case-insensitively."""

    @abstractmethod
    def create_user(self, *, email: str) -> CreateUserResult:
        """Create an Auth user and matching Users/UserRoles documents.

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
    def delete_auth_user(self, uid: str) -> None:
        """Hard-delete an Auth user if it exists."""

    @abstractmethod
    def hard_delete_account_documents(self, uid: str) -> None:
        """Hard-delete the user's Firestore account, role, and owned client documents."""

    @abstractmethod
    def reserve_client(
        self,
        *,
        owner_uid: str,
        owner_email: str | None,
        region_id: str,
        client_name: str,
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

    @abstractmethod
    def list_policy_clients(self) -> list[PolicyClientEntry]:
        """Return every ACTIVE, keyed client fleet-wide (account-scoped ACL map input).

        Unfiltered across regions on purpose (see TODO/account-scoped-acl.md,
        "Firestore model"): status filtering happens in the caller so this
        needs no new composite index. A client with no live public key cannot
        source traffic and is excluded.
        """

    @abstractmethod
    def list_account_slots(self) -> dict[str, int]:
        """Return uid -> accountSlot for every user holding a valid, positive slot."""

    @abstractmethod
    def list_admin_uids(self) -> set[str]:
        """Return uids with the admin role (mirrors list_admin_emails, keyed by uid)."""

    @abstractmethod
    def get_account_slot(self, uid: str) -> int | None:
        """Return one user's account slot, or None when absent."""

    @abstractmethod
    def write_policy_status(self, status: PolicyStatus) -> None:
        """Write this region's account-scoped ACL status doc (observability only; best-effort caller)."""

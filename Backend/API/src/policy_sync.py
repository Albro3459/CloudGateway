import ipaddress
import logging
import threading
from collections.abc import Callable
from dataclasses import dataclass

from .enums import Event
from .logs import log_event
from .policy import LivePolicyMap, PolicyManager, PolicyRow
from .repository import FirebaseRepository, PolicyStatus, valid_account_slot
from .settings import Settings
from .wireguard import MESH_AGGREGATE_V4, MESH_AGGREGATE_V6, is_valid_tunnel_ip

logger = logging.getLogger("src.policy_sync")

# Checked under policy.lock() immediately before apply_map, so it is evaluated
# atomically with the mutation it may veto. Returns True to proceed, False when
# a newer pull has already applied (see PolicyCoordinator._sequence_is_current).
SequenceGuard = Callable[[int], bool]

# Same aggregates bootstrap.sh installs as cg_tunnel4/6 (see wireguard.py).
# Precomputed once so bare_tunnel_address/_infra_address don't re-parse a
# constant CIDR on every row.
_TUNNEL_AGGREGATE_V4 = ipaddress.ip_network(MESH_AGGREGATE_V4)
_TUNNEL_AGGREGATE_V6 = ipaddress.ip_network(MESH_AGGREGATE_V6)


@dataclass(frozen=True)
class DesiredPolicy:
    rows: tuple[PolicyRow, ...] = ()
    infra_v4: tuple[str, ...] = ()
    infra_v6: tuple[str, ...] = ()
    # Client rows excluded this pass (no/duplicate account slot, malformed or
    # out-of-aggregate address, or a duplicate address) - a count only, never
    # which client or its address/uid/slot.
    skipped_rows: int = 0


def bare_tunnel_address(value: object, version: int) -> str | None:
    """Strip a stored tunnel address's CIDR prefix ("10.0.0.2/32") down to the
    bare host address the nftables map wants. Never raises: a malformed,
    wrong-family, wrong-prefix, or out-of-aggregate value is reported as None
    so a corrupt row can be skipped instead of aborting the pass.

    Reuses wireguard.is_valid_tunnel_ip for the family/host-prefix rule so the
    policy map and WireGuard peer validation cannot drift apart.
    """
    if not isinstance(value, str):
        return None
    if not is_valid_tunnel_ip(value, version):
        return None
    interface = ipaddress.ip_interface(value)
    aggregate = _TUNNEL_AGGREGATE_V4 if version == 4 else _TUNNEL_AGGREGATE_V6
    if interface.ip not in aggregate:
        return None
    return str(interface.ip)


def _infra_address(cidr: object, version: int) -> str | None:
    """The region's interface address: network address + 1 of its tunnel CIDR
    (see TODO/account-scoped-acl.md, "Filter design" - cg_infra). Malformed,
    wrong-family, or out-of-aggregate CIDRs are skipped, matching
    desired_mesh_peers's tolerance - a garbage region CIDR must never put a
    public address in cg_infra."""
    if not isinstance(cidr, str) or not cidr:
        return None
    try:
        network = ipaddress.ip_network(cidr, strict=True)
    except ValueError:
        return None
    if network.version != version:
        return None
    try:
        address = network.network_address + 1
    except ValueError:
        return None
    aggregate = _TUNNEL_AGGREGATE_V4 if version == 4 else _TUNNEL_AGGREGATE_V6
    if address not in aggregate:
        return None
    return str(address)


@dataclass(frozen=True)
class _Candidate:
    """A row that passed owner/slot/address validation but has not yet
    cleared the address-collision pass below."""

    owner_uid: str
    address_v4: str
    address_v6: str
    slot: int


def desired_policy(repository: FirebaseRepository) -> DesiredPolicy:
    """Build the fleet-wide account-scoped ACL map from Firestore. Malformed
    data must never abort a pass, exactly like desired_mesh_peers: a bad row is
    excluded and counted, not raised.

    Two passes over the fleet snapshot: pass 1 validates each row in
    isolation (owner, slot, addresses) into candidates; pass 2 drops every
    candidate whose v4 or v6 address collides with another candidate's, so
    collection order never picks a winner between them. Account-slot
    collisions are resolved up front, excluding every uid that shares a slot
    with another uid (not clients that legitimately share their own uid's
    slot).
    """
    admin_uids = repository.list_admin_uids()

    # A slot claimed by more than one uid is a collision that excludes every
    # participating uid, never just the loser.
    valid_slots: dict[str, int] = {}
    for uid, raw_slot in repository.list_account_slots().items():
        slot = valid_account_slot(raw_slot)
        if slot is not None:
            valid_slots[uid] = slot
    slot_owners: dict[int, set[str]] = {}
    for uid, slot in valid_slots.items():
        slot_owners.setdefault(slot, set()).add(uid)
    collided_uids = {uid for uids in slot_owners.values() if len(uids) > 1 for uid in uids}

    skipped_rows = 0
    candidates: list[_Candidate] = []
    for entry in repository.list_policy_clients():
        owner_uid = entry.owner_uid
        if not isinstance(owner_uid, str) or not owner_uid:
            # Unhashable/blank owner: skipped, never used as a dict key/set member.
            skipped_rows += 1
            continue
        if owner_uid in collided_uids:
            skipped_rows += 1
            continue
        slot = valid_slots.get(owner_uid)
        if slot is None:
            # Fail closed: an owner with no valid slot is skipped, never defaulted.
            skipped_rows += 1
            continue
        address_v4 = bare_tunnel_address(entry.assigned_tunnel_ipv4, 4)
        address_v6 = bare_tunnel_address(entry.assigned_tunnel_ipv6, 6)
        if address_v4 is None or address_v6 is None:
            skipped_rows += 1
            continue
        candidates.append(_Candidate(owner_uid=owner_uid, address_v4=address_v4, address_v6=address_v6, slot=slot))

    # Count occurrences across every candidate before excluding any of them,
    # so both collection orders of a duplicate pair exclude both rows.
    v4_counts: dict[str, int] = {}
    v6_counts: dict[str, int] = {}
    for candidate in candidates:
        v4_counts[candidate.address_v4] = v4_counts.get(candidate.address_v4, 0) + 1
        v6_counts[candidate.address_v6] = v6_counts.get(candidate.address_v6, 0) + 1

    rows: list[PolicyRow] = []
    for candidate in candidates:
        if v4_counts[candidate.address_v4] > 1 or v6_counts[candidate.address_v6] > 1:
            # Corruption, not a legitimate collision (addresses are allocated
            # per-region, monotonically, and never reused while live): skip
            # rather than let one client's slot claim another's address.
            skipped_rows += 1
            continue
        rows.append(
            PolicyRow(
                address_v4=candidate.address_v4,
                address_v6=candidate.address_v6,
                slot=candidate.slot,
                admin=candidate.owner_uid in admin_uids,
            )
        )

    infra_v4: list[str] = []
    infra_v6: list[str] = []
    for region in repository.list_regions():
        # Every region doc, enabled or not: a disabled region's host still
        # exists and its interface address is still infra.
        addr_v4 = _infra_address(region.tunnel_network_v4, 4)
        if addr_v4 is not None:
            infra_v4.append(addr_v4)
        addr_v6 = _infra_address(region.tunnel_network_v6, 6)
        if addr_v6 is not None:
            infra_v6.append(addr_v6)

    return DesiredPolicy(
        rows=tuple(rows),
        # De-duplicated: a repeated element makes apply_map's atomic nft
        # batch reject the whole set (see _infra_address).
        infra_v4=tuple(dict.fromkeys(infra_v4)),
        infra_v6=tuple(dict.fromkeys(infra_v6)),
        skipped_rows=skipped_rows,
    )


@dataclass(frozen=True)
class PolicyOutcome:
    applied: bool
    applied_sequence: int
    skipped_rows: int
    row_count: int = 0
    map_hash_v4: str = ""
    map_hash_v6: str = ""
    # False when the live apply succeeded but the Policy/{regionId} snapshot
    # never persisted (mirrors SyncOutcome.mesh_status_written).
    status_written: bool = False


def reconcile_policy(
    *,
    repository: FirebaseRepository,
    policy: PolicyManager,
    settings: Settings,
    sequence: int,
    sequence_guard: SequenceGuard | None = None,
) -> PolicyOutcome:
    """One account-scoped ACL pass: pull the fleet snapshot, apply it
    atomically, read back what is actually on the wire, and write status from
    that read-back - never from the pulled snapshot, or the status would
    always look healthy and report nothing (mirrors write_mesh_status's rule
    in sync.py). The status write is best effort and never fails the pass.

    sequence_guard, when given, is evaluated under policy.lock() immediately
    before the apply. Boot's one-shot pass (sync.main()) has no coordinator
    and no concurrent pass to race, so it passes none.
    """
    desired = desired_policy(repository)
    if desired.skipped_rows:
        log_event(
            logger,
            Event.POLICY_ROWS_SKIPPED,
            level=logging.WARNING,
            region_id=settings.region_id,
            skipped_rows=desired.skipped_rows,
        )

    with policy.lock():
        if sequence_guard is not None and not sequence_guard(sequence):
            # A newer pull already applied while this one was in flight.
            # Cancellation is not available in this runtime, so the older
            # result is discarded here instead of overwriting fresher state.
            log_event(
                logger,
                Event.POLICY_REFRESH_DISCARDED,
                level=logging.WARNING,
                region_id=settings.region_id,
                sequence=sequence,
            )
            return PolicyOutcome(applied=False, applied_sequence=sequence, skipped_rows=desired.skipped_rows)

        policy.apply_map(desired.rows, infra_v4=desired.infra_v4, infra_v6=desired.infra_v6)
        live: LivePolicyMap = policy.read_map()
        status_written = True
        try:
            repository.write_policy_status(
                PolicyStatus(
                    region_id=settings.region_id,
                    map_hash_v4=live.hash_v4,
                    map_hash_v6=live.hash_v6,
                    row_count=live.row_count,
                    applied_sequence=sequence,
                )
            )
        except Exception as exc:
            # Reported, not raised: the interface is already reconciled, so
            # failing the pass here would discard correct work over a status write.
            status_written = False
            log_event(
                logger,
                Event.POLICY_STATUS_WRITE_FAILED,
                level=logging.ERROR,
                region_id=settings.region_id,
                exc_info=(type(exc), exc, exc.__traceback__),
            )

    return PolicyOutcome(
        applied=True,
        applied_sequence=sequence,
        skipped_rows=desired.skipped_rows,
        row_count=live.row_count,
        map_hash_v4=live.hash_v4,
        map_hash_v6=live.hash_v6,
        status_written=status_written,
    )


class PolicyCoordinator:
    """Depth-1 coalescing plus the sequence guard (see
    TODO/account-scoped-acl.md, "Refresh model"). One instance lives on
    app.state, shared by the /sync/refresh poke handler and admin Sync All.

    request() is called from a background task with nothing able to observe
    or react to a failure, so it - and everything it calls - must never raise.
    """

    def __init__(self, *, repository: FirebaseRepository, policy: PolicyManager, settings: Settings):
        self._repository = repository
        self._policy = policy
        self._settings = settings
        self._condition = threading.Condition()
        self._running = False
        self._pending = False
        self._next_sequence = 1
        self._last_applied_sequence = 0
        self._last_outcome: PolicyOutcome | None = None

    def request(self) -> None:
        """Fire-and-forget entry point for a poke. Any number of concurrent
        callers arriving while a pass is running coalesce into a single
        follow-up pass - one is sufficient since the pull is a full snapshot,
        not a delta. That bounds the pending backlog to one queued pass, not
        the total work a caller can request over time; there is no rate limit.
        Never blocks the caller and never raises."""
        with self._condition:
            if self._running:
                self._pending = True
                return
            self._running = True
        self._drain()

    def run_blocking(self) -> PolicyOutcome | None:
        """Synchronous full pass for boot-equivalent and admin Sync All
        callers that want the outcome rather than fire-and-forget. Coalesces
        with an in-flight pass exactly as request() does, but waits for the
        pass that picks up the coalesced flag to finish. Returns None only
        when reconcile_policy itself raised (logged in _run_one_pass, never
        propagated - a policy failure must not fail the admin endpoint)."""
        with self._condition:
            if self._running:
                self._pending = True
                self._condition.wait_for(lambda: not self._running)
                return self._last_outcome
            self._running = True
        return self._drain()

    def _drain(self) -> PolicyOutcome | None:
        # Do not turn this into a real queue. The invariant is depth-1 on the
        # *pending backlog*: at most one follow-up pass is ever queued, however
        # many callers poke while a pass is in flight. It is not a bound on the
        # total passes this loop can run - a caller arriving after the follow-up
        # has already started may set `pending` again, deliberately, because its
        # Firestore mutation may be newer than that follow-up's snapshot and
        # dropping it would lose the event.
        outcome: PolicyOutcome | None = None
        while True:
            outcome = self._run_one_pass()
            with self._condition:
                if self._pending:
                    self._pending = False
                    continue
                self._running = False
                self._last_outcome = outcome
                self._condition.notify_all()
                return outcome

    def _run_one_pass(self) -> PolicyOutcome | None:
        with self._condition:
            sequence = self._next_sequence
            self._next_sequence += 1
        log_event(logger, Event.POLICY_REFRESH_STARTED, region_id=self._settings.region_id, sequence=sequence)
        try:
            outcome = reconcile_policy(
                repository=self._repository,
                policy=self._policy,
                settings=self._settings,
                sequence=sequence,
                sequence_guard=self._sequence_is_current,
            )
        except Exception as exc:
            # PolicyApplyFailedError, Firestore errors, etc. must not escape:
            # this may be running from a background task with no caller to
            # catch it.
            log_event(
                logger,
                Event.POLICY_REFRESH_FAILED,
                level=logging.ERROR,
                region_id=self._settings.region_id,
                sequence=sequence,
                exc_info=(type(exc), exc, exc.__traceback__),
            )
            return None

        if outcome.applied:
            with self._condition:
                self._last_applied_sequence = max(self._last_applied_sequence, sequence)
            log_event(
                logger,
                Event.POLICY_REFRESH_COMPLETED,
                region_id=self._settings.region_id,
                sequence=sequence,
                row_count=outcome.row_count,
                skipped_rows=outcome.skipped_rows,
                status_written=outcome.status_written,
            )
        return outcome

    def _sequence_is_current(self, sequence: int) -> bool:
        with self._condition:
            return sequence >= self._last_applied_sequence

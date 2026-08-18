import ipaddress
import logging
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime

from .enums import Event
from .logs import log_event
from .policy import LivePolicyMap, PolicyManager, PolicyRow
from .repository import FirebaseRepository, PolicyStatus
from .settings import Settings

logger = logging.getLogger("src.policy_sync")

# Checked under policy.lock() immediately before apply_map, so it is evaluated
# atomically with the mutation it may veto. Returns True to proceed, False when
# a newer pull has already applied (see PolicyCoordinator._sequence_is_current).
SequenceGuard = Callable[[int], bool]


@dataclass(frozen=True)
class DesiredPolicy:
    rows: tuple[PolicyRow, ...] = ()
    infra_v4: tuple[str, ...] = ()
    infra_v6: tuple[str, ...] = ()
    data_vintage: datetime | None = None
    # Client rows excluded this pass (no account slot, malformed address, or a
    # duplicate address) - a count only, never which client or its address/uid.
    skipped_rows: int = 0


def bare_tunnel_address(value: object, version: int) -> str | None:
    """Strip a stored tunnel address's CIDR prefix ("10.0.0.2/32") down to the
    bare host address the nftables map wants. Never raises: a malformed or
    wrong-family value is reported as None so a corrupt row can be skipped
    instead of aborting the pass."""
    if not isinstance(value, str) or not value:
        return None
    try:
        interface = ipaddress.ip_interface(value)
    except ValueError:
        return None
    if interface.ip.version != version:
        return None
    return str(interface.ip)


def _infra_address(cidr: object, version: int) -> str | None:
    """The region's interface address: network address + 1 of its tunnel CIDR
    (see TODO/account-scoped-acl.md, "Filter design" - cg_infra). Malformed or
    wrong-family CIDRs are skipped, matching desired_mesh_peers's tolerance."""
    if not isinstance(cidr, str) or not cidr:
        return None
    try:
        network = ipaddress.ip_network(cidr, strict=True)
    except ValueError:
        return None
    if network.version != version:
        return None
    try:
        return str(network.network_address + 1)
    except ValueError:
        return None


def desired_policy(repository: FirebaseRepository) -> DesiredPolicy:
    """Build the fleet-wide account-scoped ACL map from Firestore. Malformed
    data must never abort a pass, exactly like desired_mesh_peers: a bad row is
    excluded and counted, not raised."""
    account_slots = repository.list_account_slots()
    admin_uids = repository.list_admin_uids()

    seen_v4: set[str] = set()
    seen_v6: set[str] = set()
    rows: list[PolicyRow] = []
    skipped_rows = 0
    data_vintage: datetime | None = None

    for entry in repository.list_policy_clients():
        slot = account_slots.get(entry.owner_uid)
        if slot is None:
            # Fail closed: an owner with no slot is skipped, never defaulted.
            skipped_rows += 1
            continue
        address_v4 = bare_tunnel_address(entry.assigned_tunnel_ipv4, 4)
        address_v6 = bare_tunnel_address(entry.assigned_tunnel_ipv6, 6)
        if address_v4 is None or address_v6 is None:
            skipped_rows += 1
            continue
        if address_v4 in seen_v4 or address_v6 in seen_v6:
            # Corruption, not a legitimate collision (addresses are allocated
            # per-region, monotonically, and never reused while live): skip
            # rather than let one client's slot claim another's address.
            skipped_rows += 1
            continue
        seen_v4.add(address_v4)
        seen_v6.add(address_v6)
        rows.append(
            PolicyRow(
                address_v4=address_v4,
                address_v6=address_v6,
                slot=slot,
                admin=entry.owner_uid in admin_uids,
            )
        )
        if entry.updated_at is not None and (data_vintage is None or entry.updated_at > data_vintage):
            data_vintage = entry.updated_at

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
        infra_v4=tuple(infra_v4),
        infra_v6=tuple(infra_v6),
        data_vintage=data_vintage,
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
                    data_vintage=desired.data_vintage,
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

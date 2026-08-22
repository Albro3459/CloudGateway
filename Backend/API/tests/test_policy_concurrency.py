"""Concurrency coverage for the account-scoped ACL cross-process ordering and
create-path isolation: policy.lock() itself is the sole ordering mechanism
across an API process and the boot/manual peer-sync process, and the create
path's inline row must neither block on nor be blocked by a full reconcile
pass, nor ever run under the WireGuard lock.
"""

import threading
from collections.abc import Sequence
from contextlib import contextmanager
from ipaddress import ip_address
from pathlib import Path
from time import time
from typing import Iterator

from fastapi.testclient import TestClient

import src.routes as routes
from src.app import create_app
from src.auth import AuthenticatedUser
from src.enums import Role
from src.policy import LivePolicyFamily, LivePolicyMap, LocalPolicyManager, PolicyRow
from src.wireguard import MESH_AGGREGATE_V4, MESH_AGGREGATE_V6
from src.policy_sync import PolicyCoordinator, PolicyOutcome, reconcile_policy

from .conftest import REGION_ID, make_settings
from .fakes import (
    FAKE_PUBLIC_KEY,
    FAKE_PUBLIC_KEY_2,
    FakePolicyManager,
    FakeRepository,
    FakeTokenVerifier,
    FakeWireGuardManager,
)
from .test_policy_sync import reserve_and_activate
from .test_routes_clients import auth_header, enabled_region, seed_region


# --- real-flock harness ----------------------------------------------------


class SharedPolicyState:
    """The "wire" state two LockingPolicyManager instances mutate through -
    shared the way two OS processes would share nftables state, but backed by
    a plain dict since no test here touches nft."""

    def __init__(self) -> None:
        self.rows: dict[tuple[str, str], PolicyRow] = {}


class LockingPolicyManager(LocalPolicyManager):
    """A LocalPolicyManager that keeps the inherited real fcntl-backed
    lock() but replaces the nft-backed mutation/read methods with in-memory
    ones against a shared SharedPolicyState. Two instances built with the
    same lock_path and state behave like two OS processes that share a lock
    file but not memory - real flock contention, no /run/, no nft."""

    def __init__(
        self,
        *,
        lock_path: Path,
        state: SharedPolicyState,
        name: str,
        events: list[str] | None = None,
    ) -> None:
        super().__init__(lock_path=str(lock_path))
        self._state = state
        self._name = name
        self._events = events

    @contextmanager
    def lock(self, *, blocking: bool = True) -> Iterator[None]:
        with super().lock(blocking=blocking):
            if self._events is not None:
                self._events.append(f"{self._name}:enter")
            try:
                yield
            finally:
                if self._events is not None:
                    self._events.append(f"{self._name}:exit")

    def apply_map(
        self,
        rows: Sequence[PolicyRow],
        *,
        infra_v4: Sequence[str] = (),
        infra_v6: Sequence[str] = (),
    ) -> None:
        del infra_v4, infra_v6
        self._state.rows = {(row.address_v4, row.address_v6): row for row in rows}

    def add_client_row(self, row: PolicyRow) -> None:
        self._state.rows[(row.address_v4, row.address_v6)] = row

    def read_map(self) -> LivePolicyMap:
        return LivePolicyMap(v4=self._family(4), v6=self._family(6))

    def _family(self, version: int) -> LivePolicyFamily:
        address_attr = "address_v4" if version == 4 else "address_v6"
        slots = tuple(
            sorted(
                ((getattr(row, address_attr), row.slot) for row in self._state.rows.values()),
                key=lambda item: ip_address(item[0]).packed,
            )
        )
        return LivePolicyFamily(
            version=version,
            tunnel=(MESH_AGGREGATE_V4,) if version == 4 else (MESH_AGGREGATE_V6,),
            infra=(),
            admin=(),
            slots=slots,
            pairs=slots,
        )


def test_reconcile_policy_two_processes_never_interleave_their_lock_sections(tmp_path):
    """policy.lock() alone serializes reconcile_policy across two separate
    PolicyManager instances sharing one lock file, the way an API process and
    the boot/manual peer-sync process would - proven against a real
    fcntl.flock, not a mock."""
    lock_path = tmp_path / "policy.lock"
    state = SharedPolicyState()
    events: list[str] = []
    manager_a = LockingPolicyManager(lock_path=lock_path, state=state, name="api", events=events)
    manager_b = LockingPolicyManager(lock_path=lock_path, state=state, name="boot", events=events)

    repository_a = FakeRepository(local_region_id=REGION_ID)
    repository_a.regions[REGION_ID] = enabled_region()
    reserve_and_activate(repository_a, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    repository_b = FakeRepository(local_region_id=REGION_ID)
    repository_b.regions[REGION_ID] = enabled_region()
    reserve_and_activate(repository_b, uid="user-2", public_key=FAKE_PUBLIC_KEY_2)
    settings = make_settings()

    passes_per_thread = 20
    errors: list[BaseException] = []

    def run(policy, repository):
        try:
            for _ in range(passes_per_thread):
                reconcile_policy(repository=repository, policy=policy, settings=settings)
        except BaseException as exc:  # noqa: BLE001 - captured to fail the test, not swallowed
            errors.append(exc)

    thread_a = threading.Thread(target=run, args=(manager_a, repository_a))
    thread_b = threading.Thread(target=run, args=(manager_b, repository_b))
    thread_a.start()
    thread_b.start()
    try:
        thread_a.join(timeout=10)
        thread_b.join(timeout=10)
    finally:
        assert not thread_a.is_alive()
        assert not thread_b.is_alive()

    assert not errors
    assert len(events) == passes_per_thread * 2 * 2  # enter+exit, two threads
    for previous, current in zip(events, events[1:]):
        assert not (previous.endswith(":enter") and current.endswith(":enter")), (
            f"lock sections interleaved: {previous} -> {current}"
        )


class PausingRepository(FakeRepository):
    """Pauses inside write_policy_status - which runs while reconcile_policy
    still holds the policy lock - until released, so a test can mutate the
    fleet while the first pass's lock is still held and prove a second
    caller's own pull happens only after it acquires the lock, never
    before. Pauses only the first call; a later pass's own status write
    proceeds normally."""

    def __init__(self, *, entered: threading.Event, release: threading.Event, **kwargs):
        super().__init__(**kwargs)
        self._entered = entered
        self._release = release
        self._paused = False

    def write_policy_status(self, status):
        if not self._paused:
            self._paused = True
            self._entered.set()
            assert self._release.wait(timeout=5)
        super().write_policy_status(status)


def test_reconcile_policy_second_caller_pull_never_predates_its_own_lock_acquisition(tmp_path):
    """Regression test for the old pull-before-lock race: a second writer
    blocked on the policy lock must pull its own Firestore snapshot only
    after it acquires the lock, so a mutation landing while it waits is
    never lost to a pull that ran before the lock was acquired. A
    pull-outside-the-lock implementation would see only the first client
    here and fail this assertion."""
    lock_path = tmp_path / "policy.lock"
    state = SharedPolicyState()
    manager_a = LockingPolicyManager(lock_path=lock_path, state=state, name="api")
    manager_b = LockingPolicyManager(lock_path=lock_path, state=state, name="boot")

    entered = threading.Event()
    release = threading.Event()
    repository = PausingRepository(entered=entered, release=release, local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    settings = make_settings()

    outcomes: dict[str, PolicyOutcome] = {}

    def run(key: str, policy: LockingPolicyManager) -> None:
        outcomes[key] = reconcile_policy(repository=repository, policy=policy, settings=settings)

    thread_a = threading.Thread(target=run, args=("a", manager_a))
    thread_b = threading.Thread(target=run, args=("b", manager_b))

    thread_a.start()
    try:
        assert entered.wait(timeout=5)
        thread_b.start()
        try:
            # Added while A still holds the lock; B cannot have pulled yet -
            # it cannot even acquire the lock until A releases it below.
            reserve_and_activate(repository, uid="user-2", public_key=FAKE_PUBLIC_KEY_2)
        finally:
            release.set()
            thread_b.join(timeout=5)
            assert not thread_b.is_alive()
    finally:
        release.set()
        thread_a.join(timeout=5)
        assert not thread_a.is_alive()

    assert outcomes["a"].row_count == 1
    assert outcomes["b"].row_count == 2


# --- inline row versus a full reconcile pass --------------------------------


class BlockingPullRepository(FakeRepository):
    """Blocks list_policy_clients (the pull) until released, so a test can
    hold a full reconcile pass's lock open long enough to attempt a
    concurrent inline row write against the same PolicyManager."""

    def __init__(self, *, entered: threading.Event, release: threading.Event, **kwargs):
        super().__init__(**kwargs)
        self._entered = entered
        self._release = release

    def list_policy_clients(self):
        self._entered.set()
        assert self._release.wait(timeout=5)
        return super().list_policy_clients()


def test_inline_policy_row_is_a_no_op_when_a_full_pass_holds_the_lock(caplog):
    """While a full reconcile pass holds the policy lock, the create path's
    inline row write must return normally without applying a row and must
    log a busy event - and the full pass's own outcome must be unaffected by
    the attempt."""
    entered = threading.Event()
    release = threading.Event()
    repository = BlockingPullRepository(entered=entered, release=release, local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    active = reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    policy = FakePolicyManager()
    settings = make_settings()

    outcomes: dict[str, PolicyOutcome] = {}

    def run_pass() -> None:
        outcomes["pass"] = reconcile_policy(repository=repository, policy=policy, settings=settings)

    thread = threading.Thread(target=run_pass)
    thread.start()
    try:
        assert entered.wait(timeout=5)

        with caplog.at_level("INFO", logger="src.routes"):
            routes._write_inline_policy_row(
                repository=repository,
                policy=policy,
                client=active,
                request_id="req-inline-busy",
            )

        assert policy.add_row_calls == 0
        assert "policy_row_lock_busy" in caplog.text
    finally:
        release.set()
        thread.join(timeout=5)
        assert not thread.is_alive()

    outcome = outcomes["pass"]
    assert outcome.row_count == 1
    assert policy.apply_calls == 1


# --- create path over HTTP --------------------------------------------------


def test_create_client_returns_success_when_policy_lock_is_already_held(client, repository, wireguard, policy, caplog):
    """A busy non-blocking policy lock on the create path must never turn a
    successful create into a failure: the next reconcile (poked right after)
    repairs the row instead."""
    seed_region(repository)

    with policy.lock():
        with caplog.at_level("INFO", logger="src.routes"):
            response = client.post(
                "/clients",
                json={"regionId": REGION_ID, "clientName": "Phone"},
                headers=auth_header(),
            )

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "active"
    assert payload["wireguardConfig"].startswith("[Interface]\n")
    assert policy.add_row_calls == 0
    assert "policy_row_lock_busy" in caplog.text


def test_create_client_account_slot_lookup_failure_never_fails_the_create(client, repository, wireguard, policy, caplog):
    """Regression test for review finding 4: the account-slot lookup used to
    sit outside the inline row's exception boundary. A Firestore read
    failure there must be absorbed, not turn a successful create into a 500."""
    seed_region(repository)

    def _raise(uid):
        raise RuntimeError("simulated Firestore read failure")

    repository.get_account_slot = _raise  # type: ignore[method-assign]

    with caplog.at_level("WARNING", logger="src.routes"):
        response = client.post(
            "/clients",
            json={"regionId": REGION_ID, "clientName": "Phone"},
            headers=auth_header(),
        )

    assert response.status_code == 200
    assert response.json()["status"] == "active"
    assert policy.add_row_calls == 0
    assert "policy_row_apply_failed" in caplog.text


class WireGuardLockObservingPolicyManager(FakePolicyManager):
    """Records whether the WireGuard lock was held at the moment policy.lock()
    or add_client_row is invoked from the create path, proving no policy work
    - lock acquisition or the row apply - ever runs inside wireguard.lock()."""

    def __init__(self, *, wireguard: FakeWireGuardManager):
        super().__init__()
        self._wireguard = wireguard
        self.wireguard_locked_at_lock_call: list[bool] = []
        self.wireguard_locked_at_add_row: list[bool] = []

    @contextmanager
    def lock(self, *, blocking: bool = True) -> Iterator[None]:
        self.wireguard_locked_at_lock_call.append(self._wireguard.locked)
        with super().lock(blocking=blocking):
            yield

    def add_client_row(self, row: PolicyRow) -> None:
        self.wireguard_locked_at_add_row.append(self._wireguard.locked)
        super().add_client_row(row)


def _test_client(*, repository: FakeRepository, wireguard: FakeWireGuardManager, policy) -> TestClient:
    """Builds a TestClient the way the `client` fixture in conftest.py does,
    but with a caller-supplied policy manager - the shared fixture always
    builds a plain FakePolicyManager, and this suite needs an instrumented
    subclass instead."""
    settings = make_settings()
    token_verifier = FakeTokenVerifier()
    token_verifier.users["user-token"] = AuthenticatedUser(
        uid="user-1",
        email="user@example.com",
        auth_time=int(time()),
    )
    repository.roles["user-1"] = Role.USER
    app = create_app(
        settings=settings,
        token_verifier=token_verifier,
        repository=repository,
        wireguard=wireguard,
        policy=policy,
    )
    return TestClient(app, raise_server_exceptions=False)


def test_create_client_policy_lock_and_row_apply_never_run_under_the_wireguard_lock():
    """Direct guard against a slow Firestore status write (or nft call)
    stalling the WireGuard mutation lock: neither taking the policy lock nor
    applying the inline row may happen while wireguard.lock() is held.

    TestClient runs FastAPI's BackgroundTasks synchronously before returning
    the response, so policy.lock() is entered twice here - once for the
    inline row, once for the background policy_coordinator.request() poke
    queued right after - and both must see the WireGuard lock released.
    add_client_row is only ever the inline path's call, since the follow-up
    is a full apply_map pass, not an additive row.
    """
    repository = FakeRepository(local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    wireguard = FakeWireGuardManager()
    policy = WireGuardLockObservingPolicyManager(wireguard=wireguard)
    test_client = _test_client(repository=repository, wireguard=wireguard, policy=policy)

    response = test_client.post(
        "/clients",
        json={"regionId": REGION_ID, "clientName": "Phone"},
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert policy.wireguard_locked_at_lock_call
    assert all(locked is False for locked in policy.wireguard_locked_at_lock_call)
    assert policy.wireguard_locked_at_add_row == [False]


# --- PolicyCoordinator depth-1 backlog vs. total work over time ------------


class SteppablePullRepository(FakeRepository):
    """Each list_policy_clients call - each pass's pull - signals its own
    "started" event and then waits on its own "release" event, so a test can
    deterministically poke the coordinator relative to exactly which pass's
    pull is currently in flight."""

    def __init__(self, *, started: list[threading.Event], release: list[threading.Event], **kwargs):
        super().__init__(**kwargs)
        self._started = started
        self._release = release
        self.pull_count = 0
        self._step_lock = threading.Lock()

    def list_policy_clients(self):
        with self._step_lock:
            index = self.pull_count
            self.pull_count += 1
        self._started[index].set()
        assert self._release[index].wait(timeout=5)
        return super().list_policy_clients()


def test_policy_coordinator_poke_after_follow_up_pull_has_started_runs_a_third_pass():
    """Depth-1 bounds the pending backlog to one queued follow-up, not the
    total number of passes a caller can trigger over time: a poke that
    arrives after the follow-up pass's own pull has already begun must still
    schedule and run a third pass, since its Firestore mutation may postdate
    that pull. This does not contradict depth-1 - at no point are two passes
    pending at once, only ever at most one."""
    started = [threading.Event() for _ in range(3)]
    release = [threading.Event() for _ in range(3)]
    repository = SteppablePullRepository(started=started, release=release, local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    policy = FakePolicyManager()
    coordinator = PolicyCoordinator(repository=repository, policy=policy, settings=make_settings())

    thread = threading.Thread(target=coordinator.request)
    thread.start()
    try:
        assert started[0].wait(timeout=5)  # pass 1's pull is in flight
        coordinator.request()  # poke 1: coalesces into the pending bit -> pass 2 will run
        release[0].set()

        assert started[1].wait(timeout=5)  # pass 2's pull is in flight
        coordinator.request()  # poke 2: arrives after pass 2's pull has already started
        release[1].set()

        assert started[2].wait(timeout=5)  # pass 3 running proves poke 2 was not dropped
        release[2].set()
    finally:
        thread.join(timeout=5)
        assert not thread.is_alive()
        for event in release:
            event.set()  # unblock any pull left waiting if an assertion above failed

    assert repository.pull_count == 3
    assert policy.apply_calls == 3

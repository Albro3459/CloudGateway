import threading
from dataclasses import replace

import pytest

from src.enums import Role
from src.errors import PolicyApplyFailedError
from src.policy import LivePolicyMap, PolicyRow
from src.policy_sync import PolicyCoordinator, bare_tunnel_address, desired_policy, reconcile_policy
from src.repository import PolicyStatus

from .conftest import make_settings
from .fakes import FAKE_PUBLIC_KEY, FAKE_PUBLIC_KEY_2, FakePolicyManager, FakeRepository
from .test_repository import REGION_ID, enabled_region, reserve


def make_repository() -> FakeRepository:
    repository = FakeRepository(local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    return repository


def activate(repository: FakeRepository, client, public_key: str):
    return repository.mark_client_active(
        owner_uid=client.owner_uid,
        region_id=client.region_id,
        client_id=client.client_id,
        client_public_key=public_key,
        wireguard_config="[Interface]\nPrivateKey = hidden",
    )


def reserve_and_activate(repository: FakeRepository, *, uid: str = "user-1", public_key: str = FAKE_PUBLIC_KEY):
    return activate(repository, reserve(repository, uid=uid), public_key)


# --- bare_tunnel_address ------------------------------------------------


def test_bare_tunnel_address_strips_prefix():
    assert bare_tunnel_address("10.0.0.2/32", 4) == "10.0.0.2"
    assert bare_tunnel_address("fd42:42:42::2/128", 6) == "fd42:42:42::2"


def test_bare_tunnel_address_rejects_wrong_family_and_malformed():
    assert bare_tunnel_address("10.0.0.2/32", 6) is None
    assert bare_tunnel_address("not-an-address", 4) is None
    assert bare_tunnel_address("10.0.0.2/99", 4) is None
    assert bare_tunnel_address(None, 4) is None
    assert bare_tunnel_address("", 4) is None


def test_bare_tunnel_address_rejects_non_host_prefixes():
    # Only the exact /32 (v4) and /128 (v6) host prefix is accepted, not a
    # wider network prefix nor an adjacent single-bit-off prefix.
    assert bare_tunnel_address("10.0.0.2/24", 4) is None
    assert bare_tunnel_address("10.0.0.2/31", 4) is None
    assert bare_tunnel_address("fd42:42:42::2/64", 6) is None
    assert bare_tunnel_address("fd42:42:42::2/127", 6) is None


def test_bare_tunnel_address_rejects_addresses_outside_the_tunnel_aggregate():
    # Syntactically valid /32 and /128 host addresses, right family, but
    # outside MESH_AGGREGATE_V4/V6 (10.0.0.0/16, fd42:42:42::/48).
    assert bare_tunnel_address("10.1.0.2/32", 4) is None
    assert bare_tunnel_address("fd42:42:43::2/128", 6) is None


def test_bare_tunnel_address_rejects_non_string_values():
    assert bare_tunnel_address(123, 4) is None
    assert bare_tunnel_address(["10.0.0.2/32"], 4) is None
    assert bare_tunnel_address({"ip": "10.0.0.2/32"}, 4) is None


# --- desired_policy ------------------------------------------------------


def test_desired_policy_skips_owner_without_account_slot():
    repository = make_repository()
    active = reserve_and_activate(repository)
    repository.account_slots.pop(active.owner_uid, None)

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 1


def test_desired_policy_sets_admin_flag_from_admin_uids():
    repository = make_repository()
    admin_client = reserve_and_activate(repository, uid="admin-1", public_key=FAKE_PUBLIC_KEY)
    user_client = reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY_2)
    repository.roles["admin-1"] = Role.ADMIN
    repository.roles["user-1"] = Role.USER

    desired = desired_policy(repository)

    rows_by_address = {row.address_v4: row for row in desired.rows}
    assert rows_by_address[admin_client.assigned_tunnel_ipv4.split("/")[0]].admin is True
    assert rows_by_address[user_client.assigned_tunnel_ipv4.split("/")[0]].admin is False
    assert desired.skipped_rows == 0


def test_desired_policy_strips_tunnel_address_prefix():
    repository = make_repository()
    active = reserve_and_activate(repository)

    desired = desired_policy(repository)

    assert len(desired.rows) == 1
    row = desired.rows[0]
    assert row.address_v4 == active.assigned_tunnel_ipv4.split("/")[0]
    assert row.address_v6 == active.assigned_tunnel_ipv6.split("/")[0]
    assert "/" not in row.address_v4
    assert "/" not in row.address_v6


def test_desired_policy_skips_duplicate_address_as_corruption():
    repository = make_repository()
    first = reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    second = reserve_and_activate(repository, uid="user-2", public_key=FAKE_PUBLIC_KEY_2)
    # Simulate corrupt data: two different owners' rows claim the same address.
    # Every participant is excluded, not just the "loser" - collection order
    # must never choose a winner (see test_..._regardless_of_collection_order).
    collided = replace(
        second,
        assigned_tunnel_ipv4=first.assigned_tunnel_ipv4,
        assigned_tunnel_ipv6=first.assigned_tunnel_ipv6,
    )
    repository.clients[(second.owner_uid, second.region_id, second.client_id)] = collided

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 2


@pytest.mark.parametrize("reorder_first_last", [False, True])
def test_desired_policy_duplicate_ipv4_excludes_both_regardless_of_collection_order(reorder_first_last):
    repository = make_repository()
    first = reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    second = reserve_and_activate(repository, uid="user-2", public_key=FAKE_PUBLIC_KEY_2)
    second_key = (second.owner_uid, second.region_id, second.client_id)
    repository.clients[second_key] = replace(second, assigned_tunnel_ipv4=first.assigned_tunnel_ipv4)
    if reorder_first_last:
        # Move the non-colliding row to the end of iteration order, so the
        # colliding row is seen first - the outcome must not depend on this.
        first_key = (first.owner_uid, first.region_id, first.client_id)
        repository.clients[first_key] = repository.clients.pop(first_key)

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 2


@pytest.mark.parametrize("reorder_first_last", [False, True])
def test_desired_policy_duplicate_ipv6_excludes_both_regardless_of_collection_order(reorder_first_last):
    repository = make_repository()
    first = reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    second = reserve_and_activate(repository, uid="user-2", public_key=FAKE_PUBLIC_KEY_2)
    second_key = (second.owner_uid, second.region_id, second.client_id)
    repository.clients[second_key] = replace(second, assigned_tunnel_ipv6=first.assigned_tunnel_ipv6)
    if reorder_first_last:
        first_key = (first.owner_uid, first.region_id, first.client_id)
        repository.clients[first_key] = repository.clients.pop(first_key)

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 2


def test_desired_policy_duplicate_account_slot_excludes_every_participating_uid():
    repository = make_repository()
    reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    reserve_and_activate(repository, uid="user-2", public_key=FAKE_PUBLIC_KEY_2)
    # Simulate corrupt Counters/accountSlots data: two different uids assigned
    # the same slot.
    repository.account_slots["user-2"] = repository.account_slots["user-1"]

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 2


def test_desired_policy_same_uid_multiple_clients_sharing_one_slot_is_not_a_collision():
    repository = make_repository()
    first = reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    second = activate(repository, reserve(repository, uid="user-1", client_name="Second"), FAKE_PUBLIC_KEY_2)

    desired = desired_policy(repository)

    assert len(desired.rows) == 2
    assert desired.skipped_rows == 0
    slot = repository.get_account_slot("user-1")
    assert {row.slot for row in desired.rows} == {slot}
    assert {row.address_v4 for row in desired.rows} == {
        first.assigned_tunnel_ipv4.split("/")[0],
        second.assigned_tunnel_ipv4.split("/")[0],
    }


def test_desired_policy_skips_non_string_owner_uid():
    repository = make_repository()
    active = reserve_and_activate(repository)
    key = (active.owner_uid, active.region_id, active.client_id)
    repository.clients[key] = replace(active, owner_uid=123)  # type: ignore[arg-type]

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 1


def test_desired_policy_skips_unhashable_owner_uid():
    repository = make_repository()
    active = reserve_and_activate(repository)
    key = (active.owner_uid, active.region_id, active.client_id)
    repository.clients[key] = replace(active, owner_uid=["not", "hashable"])  # type: ignore[arg-type]

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 1


def test_desired_policy_skips_blank_owner_uid():
    repository = make_repository()
    active = reserve_and_activate(repository)
    key = (active.owner_uid, active.region_id, active.client_id)
    repository.clients[key] = replace(active, owner_uid="")

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 1


def test_desired_policy_skips_non_string_client_address():
    repository = make_repository()
    active = reserve_and_activate(repository)
    key = (active.owner_uid, active.region_id, active.client_id)
    repository.clients[key] = replace(active, assigned_tunnel_ipv4=12345)  # type: ignore[arg-type]

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 1


def test_desired_policy_mixed_valid_and_invalid_rows_skipped_count_is_exact():
    repository = make_repository()
    valid = reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)

    no_slot = reserve_and_activate(repository, uid="user-2", public_key=FAKE_PUBLIC_KEY_2)
    repository.account_slots.pop(no_slot.owner_uid, None)

    malformed_address = reserve_and_activate(repository, uid="user-3", public_key="pubkey-3")
    malformed_key = (malformed_address.owner_uid, malformed_address.region_id, malformed_address.client_id)
    repository.clients[malformed_key] = replace(malformed_address, assigned_tunnel_ipv4="garbage")

    bad_owner = reserve_and_activate(repository, uid="user-4", public_key="pubkey-4")
    bad_owner_key = (bad_owner.owner_uid, bad_owner.region_id, bad_owner.client_id)
    repository.clients[bad_owner_key] = replace(bad_owner, owner_uid=None)  # type: ignore[arg-type]

    desired = desired_policy(repository)

    assert len(desired.rows) == 1
    assert desired.rows[0].address_v4 == valid.assigned_tunnel_ipv4.split("/")[0]
    assert desired.skipped_rows == 3


def test_desired_policy_skips_malformed_region_cidr_for_infra():
    repository = make_repository()
    repository.regions[REGION_ID] = replace(
        enabled_region(),
        tunnel_network_v4="10.0.0.0/24",
        tunnel_network_v6="fd42:42:42::/64",
    )
    repository.regions["us-broken-1"] = replace(
        enabled_region(),
        region_id="us-broken-1",
        tunnel_network_v4="not-a-cidr",
        tunnel_network_v6="also-not-a-cidr",
        enabled=False,  # disabled regions are still included, per list_regions()
    )

    desired = desired_policy(repository)

    assert desired.infra_v4 == ("10.0.0.1",)
    assert desired.infra_v6 == ("fd42:42:42::1",)


def test_desired_policy_infra_address_is_network_address_plus_one():
    repository = make_repository()
    repository.regions[REGION_ID] = replace(
        enabled_region(),
        tunnel_network_v4="10.0.5.0/24",
        tunnel_network_v6="fd42:42:42:5::/64",
    )

    desired = desired_policy(repository)

    assert desired.infra_v4 == ("10.0.5.1",)
    assert desired.infra_v6 == ("fd42:42:42:5::1",)


def test_desired_policy_dedupes_infra_addresses_across_regions():
    repository = make_repository()
    # Two distinct regions that happen to derive the same interface address
    # (e.g. a misconfiguration): apply_map's atomic nft batch rejects a
    # repeated set element, so the pass must de-duplicate before returning.
    repository.regions[REGION_ID] = replace(
        enabled_region(), tunnel_network_v4="10.0.0.0/24", tunnel_network_v6="fd42:42:42::/64"
    )
    repository.regions["us-dup-1"] = replace(
        enabled_region(),
        region_id="us-dup-1",
        tunnel_network_v4="10.0.0.0/24",
        tunnel_network_v6="fd42:42:42::/64",
    )

    desired = desired_policy(repository)

    assert desired.infra_v4 == ("10.0.0.1",)
    assert desired.infra_v6 == ("fd42:42:42::1",)


def test_desired_policy_rejects_infra_address_outside_tunnel_aggregate():
    repository = make_repository()
    # A garbage region CIDR must never put a public address in cg_infra.
    repository.regions[REGION_ID] = replace(
        enabled_region(),
        tunnel_network_v4="203.0.113.0/24",
        tunnel_network_v6="2001:db8::/64",
    )

    desired = desired_policy(repository)

    assert desired.infra_v4 == ()
    assert desired.infra_v6 == ()


def test_desired_policy_malformed_updated_at_cannot_affect_a_pass():
    # updatedAt never enters the policy path at all (see
    # repository.PolicyClientEntry); a garbage value on the underlying client
    # doc is structurally incapable of aborting the pass or changing its
    # output, since desired_policy never reads it.
    repository = make_repository()
    active = reserve_and_activate(repository)
    key = (active.owner_uid, active.region_id, active.client_id)
    repository.clients[key] = replace(active, updated_at="not-a-timestamp")  # type: ignore[arg-type]

    desired = desired_policy(repository)

    assert len(desired.rows) == 1
    assert desired.skipped_rows == 0


# --- reconcile_policy ------------------------------------------------------


class DriftingPolicyManager(FakePolicyManager):
    """read_map reports one extra row beyond what apply_map actually received,
    proving the status write reflects the read-back rather than the snapshot
    that was applied (see reconcile_policy's docstring)."""

    def read_map(self) -> LivePolicyMap:
        live = super().read_map()
        return LivePolicyMap(
            v4=replace(
                live.v4,
                slots=live.v4.slots + (("10.0.0.250", 999),),
                pairs=live.v4.pairs + (("10.0.0.250", 999),),
            ),
            v6=replace(
                live.v6,
                slots=live.v6.slots + (("fd42:42:42::250", 999),),
                pairs=live.v6.pairs + (("fd42:42:42::250", 999),),
            ),
        )


def test_reconcile_policy_writes_status_from_the_read_back_not_the_snapshot():
    repository = make_repository()
    reserve_and_activate(repository)
    policy = DriftingPolicyManager()
    settings = make_settings()

    outcome = reconcile_policy(repository=repository, policy=policy, settings=settings)

    assert outcome.row_count == 2  # 1 real row applied + 1 phantom row read back
    assert policy.read_calls == 1
    status = repository.policy_status[REGION_ID]
    assert status.row_count == 2
    assert status.map_hash_v4 == policy.read_map().hash_v4


def test_reconcile_policy_status_write_failure_does_not_fail_the_pass():
    repository = make_repository()
    reserve_and_activate(repository)
    repository.write_policy_status_error = RuntimeError("simulated Firestore write failure")
    policy = FakePolicyManager()
    settings = make_settings()

    outcome = reconcile_policy(repository=repository, policy=policy, settings=settings)

    assert outcome.status_written is False
    assert policy.apply_calls == 1
    assert REGION_ID not in repository.policy_status


def test_reconcile_policy_status_write_failure_preserves_the_last_good_status_document():
    # A best-effort status write failure must never raise (Wave 6, W6-2 for
    # the write leg): the interface is already reconciled, so the pass
    # returns a successful outcome with status_written=False and the last
    # good Policy/{regionId} document is untouched, exactly like a failed
    # apply or read-back below.
    repository = make_repository()
    reserve_and_activate(repository)
    previous_status = PolicyStatus(region_id=REGION_ID, map_hash_v4="prev-v4", map_hash_v6="prev-v6", row_count=7)
    repository.policy_status[REGION_ID] = previous_status
    repository.write_policy_status_error = RuntimeError("simulated Firestore write failure")
    policy = FakePolicyManager()
    settings = make_settings()

    outcome = reconcile_policy(repository=repository, policy=policy, settings=settings)

    assert outcome.status_written is False
    assert repository.policy_status[REGION_ID] == previous_status


def test_reconcile_policy_apply_failure_raises_and_never_writes_status():
    # W6-2: a failed apply must never reach write_policy_status at all - the
    # raise in reconcile_policy precedes it - so the last good
    # Policy/{regionId} document is preserved exactly, not overwritten with a
    # failure status (there is no failure status; none is ever written).
    repository = make_repository()
    reserve_and_activate(repository)
    previous_status = PolicyStatus(region_id=REGION_ID, map_hash_v4="prev-v4", map_hash_v6="prev-v6", row_count=7)
    repository.policy_status[REGION_ID] = previous_status
    policy = FakePolicyManager()
    policy.fail_apply_count = 1
    settings = make_settings()

    with pytest.raises(PolicyApplyFailedError):
        reconcile_policy(repository=repository, policy=policy, settings=settings)

    assert policy.read_calls == 0
    assert repository.policy_status[REGION_ID] == previous_status


def test_reconcile_policy_read_failure_raises_and_never_writes_status():
    # Same contract as the apply failure above, for the read-back leg: a
    # failed read_map still precedes write_policy_status, so the last good
    # status document survives untouched.
    repository = make_repository()
    reserve_and_activate(repository)
    previous_status = PolicyStatus(region_id=REGION_ID, map_hash_v4="prev-v4", map_hash_v6="prev-v6", row_count=7)
    repository.policy_status[REGION_ID] = previous_status
    policy = FakePolicyManager()
    policy.fail_read_count = 1
    settings = make_settings()

    with pytest.raises(PolicyApplyFailedError):
        reconcile_policy(repository=repository, policy=policy, settings=settings)

    assert policy.apply_calls == 1
    assert policy.read_calls == 1
    assert repository.policy_status[REGION_ID] == previous_status


class LockObservingRepository(FakeRepository):
    """Records whether the policy lock was already held at the moment the
    Firestore pull started, proving reconcile_policy's pull runs inside
    policy.lock() rather than before it."""

    def __init__(self, *, policy: FakePolicyManager, **kwargs):
        super().__init__(**kwargs)
        self._policy = policy
        self.locked_during_pull: bool | None = None

    def list_policy_clients(self):
        self.locked_during_pull = self._policy.locked
        return super().list_policy_clients()


def test_reconcile_policy_pull_happens_inside_the_lock():
    policy = FakePolicyManager()
    repository = LockObservingRepository(policy=policy, local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    reserve_and_activate(repository)
    settings = make_settings()

    outcome = reconcile_policy(repository=repository, policy=policy, settings=settings)

    assert repository.locked_during_pull is True
    assert outcome.row_count == 1


def test_desired_policy_never_raises_on_malformed_client_address():
    repository = make_repository()
    active = reserve_and_activate(repository)
    repository.clients[(active.owner_uid, active.region_id, active.client_id)] = replace(
        active, assigned_tunnel_ipv4="garbage"
    )

    desired = desired_policy(repository)

    assert desired.rows == ()
    assert desired.skipped_rows == 1


# --- PolicyCoordinator -------------------------------------------------


class BlockingRepository(FakeRepository):
    """Blocks list_policy_clients (the "pull") until released, so a test can
    reliably observe a pass mid-flight and issue concurrent pokes against it."""

    def __init__(self, *, entered: threading.Event, release: threading.Event, **kwargs):
        super().__init__(**kwargs)
        self._entered = entered
        self._release = release

    def list_policy_clients(self):
        self._entered.set()
        self._release.wait(timeout=5)
        return super().list_policy_clients()


def test_policy_coordinator_coalesces_concurrent_requests_into_one_follow_up():
    entered = threading.Event()
    release = threading.Event()
    repository = BlockingRepository(entered=entered, release=release, local_region_id=REGION_ID)
    repository.regions[REGION_ID] = enabled_region()
    policy = FakePolicyManager()
    coordinator = PolicyCoordinator(repository=repository, policy=policy, settings=make_settings())

    thread = threading.Thread(target=coordinator.request)
    thread.start()
    assert entered.wait(timeout=5)

    # Any number of pokes arriving while a pass is running must coalesce into
    # a single pending flag, not one pass each.
    for _ in range(5):
        coordinator.request()

    release.set()
    thread.join(timeout=5)

    assert policy.apply_calls == 2  # the running pass, plus exactly one follow-up


def test_policy_coordinator_run_blocking_returns_the_outcome():
    repository = make_repository()
    reserve_and_activate(repository)
    policy = FakePolicyManager()
    coordinator = PolicyCoordinator(repository=repository, policy=policy, settings=make_settings())

    outcome = coordinator.run_blocking()

    assert outcome is not None
    assert policy.apply_calls == 1


def test_policy_coordinator_request_never_raises_when_apply_fails():
    repository = make_repository()
    policy = FakePolicyManager()
    policy.fail_apply_count = 1
    coordinator = PolicyCoordinator(repository=repository, policy=policy, settings=make_settings())

    coordinator.request()  # must not raise

    assert policy.apply_calls == 1


def test_policy_coordinator_run_blocking_returns_none_when_apply_fails():
    repository = make_repository()
    policy = FakePolicyManager()
    policy.fail_apply_count = 1
    coordinator = PolicyCoordinator(repository=repository, policy=policy, settings=make_settings())

    outcome = coordinator.run_blocking()  # must not raise

    assert outcome is None


def test_policy_apply_failed_error_is_reachable_through_the_fake():
    # Exercises PolicyApplyFailedError's transient flag via the same fake path
    # production code hits, so the flag stays covered without importing errors
    # from a route test.
    policy = FakePolicyManager()
    policy.fail_apply_count = 1
    with policy.lock():
        try:
            policy.apply_map([PolicyRow(address_v4="10.0.0.2", address_v6="fd42:42:42::2", slot=1)])
        except PolicyApplyFailedError as exc:
            assert exc.transient is False


# --- role-change convergence (review finding 6) -----------------------------


def test_reconcile_policy_role_change_updates_admin_hash_and_every_region_converges():
    """Wave 5: current roles are re-read on every pass, an operator promoting
    or demoting a user out of band changes cg_admin4/6, changes the
    comprehensive live-policy hash, and every enabled region that reconciles
    against the same Firestore state converges to the same hashes - proven
    with two independent PolicyManager instances standing in for two hosts."""
    repository = make_repository()
    reserve_and_activate(repository, uid="user-1", public_key=FAKE_PUBLIC_KEY)
    repository.roles["user-1"] = Role.USER
    policy_region_a = FakePolicyManager()
    policy_region_b = FakePolicyManager()
    settings = make_settings()

    baseline_a = reconcile_policy(repository=repository, policy=policy_region_a, settings=settings)
    baseline_b = reconcile_policy(repository=repository, policy=policy_region_b, settings=settings)
    assert baseline_a.map_hash_v4 == baseline_b.map_hash_v4
    assert baseline_a.map_hash_v6 == baseline_b.map_hash_v6

    # A trusted operator promotes the user directly in UserRoles, out of band -
    # no role-mutation API is involved, matching the Wave 5 decision that role
    # mutation is not a product feature.
    repository.roles["user-1"] = Role.ADMIN

    promoted_a = reconcile_policy(repository=repository, policy=policy_region_a, settings=settings)
    promoted_b = reconcile_policy(repository=repository, policy=policy_region_b, settings=settings)

    assert promoted_a.map_hash_v4 != baseline_a.map_hash_v4
    assert promoted_a.map_hash_v6 != baseline_a.map_hash_v6
    assert promoted_a.map_hash_v4 == promoted_b.map_hash_v4
    assert promoted_a.map_hash_v6 == promoted_b.map_hash_v6
    # row_count is slot-map rows only and must not move on a pure role change.
    assert promoted_a.row_count == baseline_a.row_count == 1

    # Demoting back must restore the original (pre-promotion) hash exactly -
    # proves the admin set is rebuilt from current roles every pass, not
    # accumulated.
    repository.roles["user-1"] = Role.USER
    demoted_a = reconcile_policy(repository=repository, policy=policy_region_a, settings=settings)
    assert demoted_a.map_hash_v4 == baseline_a.map_hash_v4
    assert demoted_a.map_hash_v6 == baseline_a.map_hash_v6


# --- status write shape (Wave 5: dataVintage/appliedSequence removal) ------


class _FakeDocRef:
    def __init__(self, sink: dict):
        self._sink = sink

    def set(self, data):
        self._sink["data"] = data


class _FakeCollection:
    def __init__(self, sink: dict):
        self._sink = sink

    def document(self, doc_id):
        self._sink["doc_id"] = doc_id
        return _FakeDocRef(self._sink)


class _FakeFirestoreDb:
    def __init__(self, sink: dict):
        self._sink = sink

    def collection(self, name):
        self._sink["collection"] = name
        return _FakeCollection(self._sink)


def test_write_policy_status_document_has_exactly_five_keys(monkeypatch):
    """Wave 5 removed dataVintage (Wave 2) and appliedSequence (Wave 3) from
    the Policy/{regionId} document entirely, not merely nulled them - assert
    the literal document FirestoreRepository.write_policy_status sends."""
    from src.firebase import FirestoreRepository
    from src.repository import PolicyStatus

    repository = FirestoreRepository(make_settings())
    sink: dict = {}
    monkeypatch.setattr(repository, "_db", lambda: _FakeFirestoreDb(sink))

    repository.write_policy_status(
        PolicyStatus(region_id=REGION_ID, map_hash_v4="hash-v4", map_hash_v6="hash-v6", row_count=3)
    )

    assert sink["collection"] == "Policy"
    assert sink["doc_id"] == REGION_ID
    assert set(sink["data"].keys()) == {"regionId", "mapHashV4", "mapHashV6", "rowCount", "updatedAt"}
    assert sink["data"]["regionId"] == REGION_ID
    assert sink["data"]["mapHashV4"] == "hash-v4"
    assert sink["data"]["mapHashV6"] == "hash-v6"
    assert sink["data"]["rowCount"] == 3

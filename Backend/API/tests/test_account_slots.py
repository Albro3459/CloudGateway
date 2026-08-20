"""Account-scoped ACL slot allocator integrity (TODO/account-scoped-acl.md
finding 2, review finding 1): Counters/accountSlots.nextSlot is the sole
allocation authority, and a lost, corrupted, or regressed counter must fail
closed rather than re-issue a slot - re-issuing one would merge two accounts
onto a single nftables tenant. A live Users scan cannot stand in for the
counter, because account deletion hard-deletes Users/{uid} and its slot with
it. See repository.next_account_slot for the fail-closed design.
"""

import pytest

from src.enums import Role
from src.errors import AccountSlotUnavailableError
from src.repository import MAX_ACCOUNT_SLOT, MIN_ACCOUNT_SLOT, RegionDoc, next_account_slot

from .fakes import FakeRepository

REGION_ID = "us-test-1"


def enabled_region() -> RegionDoc:
    return RegionDoc(
        region_id=REGION_ID,
        display_name="Test Region",
        enabled=True,
        wireguard_endpoint_ipv4="203.0.113.10",
        wireguard_endpoint_ipv6=None,
        wireguard_port=51820,
        wireguard_dns_ipv4="10.0.0.1",
        wireguard_dns_ipv6="fd42:42:42::1",
        wireguard_public_key="server-public-key",
        capacity_limit=10,
    )


@pytest.fixture
def repository() -> FakeRepository:
    repo = FakeRepository(local_region_id=REGION_ID)
    repo.regions[REGION_ID] = enabled_region()
    repo.roles["user-1"] = Role.USER
    return repo


# --- Pure-function coverage: repository.next_account_slot ---------------


def test_valid_counter_no_assigned_slots_allocates_counter_value():
    assert next_account_slot(stored_next_slot=5, assigned_slots=[]) == 5


def test_valid_counter_strictly_above_max_assigned_allocates_unchanged():
    assert next_account_slot(stored_next_slot=10, assigned_slots=[1, 2, 9]) == 10


def test_valid_counter_exactly_one_above_max_assigned_is_the_healthy_boundary():
    # The steady-state shape: every allocation writes nextSlot = slot + 1.
    assert next_account_slot(stored_next_slot=4, assigned_slots=[1, 2, 3]) == 4


def test_counter_at_or_below_max_assigned_raises_and_never_advances_itself():
    # A counter that would hand out an already-assigned slot has regressed
    # (stale restore, hand edit). Live users cannot be used to advance past it:
    # the slots of hard-deleted accounts are invisible there, so "max assigned
    # + 1" could re-issue one. Fail closed instead.
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=1, assigned_slots=[1])
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=1, assigned_slots=[1, 2, 3])
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=3, assigned_slots=[1, 2, 3])


def test_counter_missing_raises_even_with_zero_assigned_slots():
    # An empty fleet is indistinguishable from a fleet whose accounts were all
    # deleted, so seeding at MIN_ACCOUNT_SLOT here could re-issue slot 1.
    # Seeding is an explicit operator action; see
    # releases/access-control-lists/README.md.
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=None, assigned_slots=[])


def test_counter_missing_with_assigned_slots_raises():
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=None, assigned_slots=[1, 2, 3])


@pytest.mark.parametrize("malformed", [0, -1, "3", True, 3.0, None, [], {}])
def test_counter_malformed_raises(malformed):
    # `malformed=None` also covers "field missing" / "doc missing", since the
    # caller passes None in both of those cases too.
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=malformed, assigned_slots=[1, 5, 2])
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=malformed, assigned_slots=[])


def test_counter_exhausted_raises_even_when_lower_slots_are_free():
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT + 1, assigned_slots=[])
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT + 1, assigned_slots=[1, 2, 3])


def test_last_slot_is_allocatable_then_the_counter_is_exhausted():
    assert next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT, assigned_slots=[1]) == MAX_ACCOUNT_SLOT
    # The allocation above stores MAX_ACCOUNT_SLOT + 1, which never allocates.
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT + 1, assigned_slots=[MAX_ACCOUNT_SLOT])


def test_counter_at_the_last_slot_that_is_already_assigned_raises():
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT, assigned_slots=[MAX_ACCOUNT_SLOT])


def test_valid_counter_path_tolerates_malformed_or_duplicated_rows_on_other_users():
    # Deliberate asymmetry documented on next_account_slot: a malformed or
    # duplicated slot on some *other* user's document must not block
    # allocation when the stored counter is itself valid and already above
    # every valid assigned slot.
    assert next_account_slot(stored_next_slot=10, assigned_slots=[1, 1, "bad", None, True]) == 10


# --- End-to-end through FakeRepository / the transaction-shaped path ----


def test_provisioning_after_counter_deleted_fails_closed_without_writing(
    repository: FakeRepository,
):
    first = repository.create_user(email="first@example.com")
    assert first.user.account_slot == MIN_ACCOUNT_SLOT

    # Simulate the counter document being lost after slot 1 was handed out.
    repository.account_slot_counter = None
    users_before = dict(repository.users)
    roles_before = dict(repository.roles)

    with pytest.raises(AccountSlotUnavailableError):
        repository.create_user(email="second@example.com")

    assert repository.users == users_before
    assert repository.roles == roles_before
    assert repository.account_slots == {first.user.uid: MIN_ACCOUNT_SLOT}
    assert repository.account_slot_counter is None


@pytest.mark.parametrize("corrupt", [0, -1, "2", MAX_ACCOUNT_SLOT + 1])
def test_provisioning_with_corrupted_counter_fails_closed(repository: FakeRepository, corrupt):
    repository.create_user(email="first@example.com")
    repository.account_slot_counter = corrupt

    with pytest.raises(AccountSlotUnavailableError):
        repository.create_user(email="second@example.com")

    assert repository.account_slot_counter == corrupt


def test_provisioning_with_regressed_counter_fails_closed(repository: FakeRepository):
    repository.create_user(email="first@example.com")
    second = repository.create_user(email="second@example.com")
    assert second.user.account_slot == MIN_ACCOUNT_SLOT + 1

    # A stale restore put the counter back onto a live slot.
    repository.account_slot_counter = second.user.account_slot

    with pytest.raises(AccountSlotUnavailableError):
        repository.create_user(email="third@example.com")


def test_deleted_accounts_slot_is_never_reissued_to_a_new_account(repository: FakeRepository):
    # Review finding 1, end to end: hard delete removes Users/{uid} and its
    # slot from every live scan, so only the counter still knows the slot was
    # issued. The next account must allocate above it, not reuse it.
    first = repository.create_user(email="first@example.com")
    second = repository.create_user(email="second@example.com")
    deleted_slot = second.user.account_slot
    assert deleted_slot is not None

    repository.hard_delete_account_documents(second.user.uid)
    assert repository.list_account_slots() == {first.user.uid: first.user.account_slot}

    third = repository.create_user(email="third@example.com")

    assert third.user.account_slot == deleted_slot + 1
    assert third.user.account_slot not in {first.user.account_slot, deleted_slot}


def test_reserve_client_after_counter_deleted_fails_closed_without_reserving(
    repository: FakeRepository,
):
    reserved_first = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Phone",
    )
    first_slot = repository.get_account_slot(reserved_first.owner_uid)
    assert first_slot == MIN_ACCOUNT_SLOT

    repository.account_slot_counter = None
    clients_before = dict(repository.clients)
    region_before = repository.regions[REGION_ID]

    with pytest.raises(AccountSlotUnavailableError):
        repository.reserve_client(
            owner_uid="user-2",
            owner_email="user2@example.com",
            region_id=REGION_ID,
            client_name="Laptop",
        )

    assert repository.clients == clients_before
    assert repository.regions[REGION_ID] == region_before
    assert repository.get_account_slot("user-2") is None
    assert "user-2" not in repository.users


def test_reserve_client_for_an_account_that_already_has_a_slot_never_reads_the_counter(
    repository: FakeRepository,
):
    # A corrupted counter must not break existing accounts: allocation only
    # happens for an account with no slot yet.
    repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Phone",
    )
    repository.account_slot_counter = None

    second = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Laptop",
    )

    assert repository.get_account_slot(second.owner_uid) == MIN_ACCOUNT_SLOT


# --- Transaction-retry consistency ---------------------------------------


def test_next_account_slot_is_deterministic_across_a_simulated_transaction_retry():
    # Firestore may retry a transaction function on contention; the retry
    # re-reads the same pre-write state and re-runs the body. Given identical
    # inputs (no intervening commit), the pure allocator must return the same
    # answer every time it is invoked, not just the first.
    kwargs = {"stored_next_slot": 5, "assigned_slots": [1, 2, 4]}

    first_attempt = next_account_slot(**kwargs)
    retried_attempt = next_account_slot(**kwargs)

    assert first_attempt == retried_attempt == 5


def test_next_account_slot_retry_after_concurrent_commit_still_does_not_duplicate():
    # A retry that runs after a *different* transaction committed a new slot
    # re-reads both the counter and the assigned slots. The result must be the
    # committed counter's new value, never a repeat of the first attempt.
    first_attempt = next_account_slot(stored_next_slot=2, assigned_slots=[1])
    assert first_attempt == 2

    # Simulate: another transaction committed slot 2 and advanced the counter
    # in between attempt 1 and the retry (attempt 1 above never wrote
    # anything, mirroring an aborted first try).
    retried_attempt = next_account_slot(stored_next_slot=3, assigned_slots=[1, 2])

    assert retried_attempt == 3
    assert retried_attempt != first_attempt

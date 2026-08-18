"""Account-scoped ACL slot allocator integrity (TODO/account-scoped-acl-review.md
finding 2): a lost or corrupted Counters/accountSlots.nextSlot must never
re-issue an already-assigned slot, which would merge two accounts onto one
nftables tenant. See repository.next_account_slot for the fail-closed design.
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


def test_counter_at_or_below_max_assigned_advances_past_it_never_a_duplicate():
    # The exact finding-2 regression: the counter says 1, but slot 1 is
    # already assigned to another account. The result must not be 1.
    assert next_account_slot(stored_next_slot=1, assigned_slots=[1]) == 2
    # Counter below the max assigned slot, not just equal to it.
    assert next_account_slot(stored_next_slot=1, assigned_slots=[1, 2, 3]) == 4


def test_counter_missing_with_zero_assigned_slots_allocates_minimum():
    assert next_account_slot(stored_next_slot=None, assigned_slots=[]) == MIN_ACCOUNT_SLOT


def test_counter_missing_with_assigned_slots_allocates_above_max_never_minimum():
    result = next_account_slot(stored_next_slot=None, assigned_slots=[1, 2, 3])
    assert result == 4
    assert result != MIN_ACCOUNT_SLOT


@pytest.mark.parametrize("malformed", [0, -1, "3", True, 3.0, None])
def test_counter_malformed_with_assigned_slots_allocates_above_max_never_minimum(malformed):
    # `malformed=None` also covers "field missing" / "doc missing", since the
    # caller passes None in both of those cases too.
    result = next_account_slot(stored_next_slot=malformed, assigned_slots=[1, 5, 2])
    assert result == 6
    assert result != MIN_ACCOUNT_SLOT


def test_counter_missing_and_duplicated_assigned_slot_raises():
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=None, assigned_slots=[1, 2, 2])


@pytest.mark.parametrize("bad_value", ["not-a-slot", True, 3.5, None, -1, 0])
def test_counter_missing_and_malformed_assigned_slot_raises(bad_value):
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=None, assigned_slots=[1, bad_value])


def test_counter_exhausted_raises_even_when_lower_slots_are_free():
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT + 1, assigned_slots=[])
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT + 1, assigned_slots=[1, 2, 3])


def test_candidate_exceeding_max_account_slot_raises_on_valid_counter_path():
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=MAX_ACCOUNT_SLOT, assigned_slots=[MAX_ACCOUNT_SLOT])


def test_candidate_exceeding_max_account_slot_raises_on_recovery_path():
    with pytest.raises(AccountSlotUnavailableError):
        next_account_slot(stored_next_slot=None, assigned_slots=[MAX_ACCOUNT_SLOT])


def test_valid_counter_path_tolerates_malformed_or_duplicated_rows_on_other_users():
    # Deliberate asymmetry documented on next_account_slot: a malformed or
    # duplicated slot on some *other* user's document must not block
    # allocation when the stored counter is itself valid and already above
    # every valid assigned slot.
    assert next_account_slot(stored_next_slot=10, assigned_slots=[1, 1, "bad", None, True]) == 10


# --- End-to-end through FakeRepository / the transaction-shaped path ----


def test_provisioning_second_account_after_counter_deleted_does_not_duplicate_slot(
    repository: FakeRepository,
):
    first = repository.create_user(email="first@example.com")
    assert first.user.account_slot == MIN_ACCOUNT_SLOT

    # Simulate the counter document being lost after slot 1 was handed out.
    repository.account_slot_counter = None

    second = repository.create_user(email="second@example.com")

    assert second.user.account_slot is not None
    assert second.user.account_slot != first.user.account_slot
    assert second.user.account_slot > MIN_ACCOUNT_SLOT


def test_provisioning_second_account_after_counter_corrupted_does_not_duplicate_slot(
    repository: FakeRepository,
):
    first = repository.create_user(email="first@example.com")
    assert first.user.account_slot == MIN_ACCOUNT_SLOT

    # Simulate a corrupted counter that would otherwise reset allocation to
    # slot 1 (the exact finding-2 scenario).
    repository.account_slot_counter = 0

    second = repository.create_user(email="second@example.com")

    assert second.user.account_slot is not None
    assert second.user.account_slot != first.user.account_slot


def test_reserve_client_after_counter_deleted_does_not_duplicate_slot(repository: FakeRepository):
    reserved_first = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Phone",
    )
    first_slot = repository.get_account_slot(reserved_first.owner_uid)
    assert first_slot == MIN_ACCOUNT_SLOT

    repository.account_slot_counter = None

    reserved_second = repository.reserve_client(
        owner_uid="user-2",
        owner_email="user2@example.com",
        region_id=REGION_ID,
        client_name="Laptop",
    )
    second_slot = repository.get_account_slot(reserved_second.owner_uid)

    assert second_slot is not None
    assert second_slot != first_slot


# --- Transaction-retry consistency ---------------------------------------


def test_next_account_slot_is_deterministic_across_a_simulated_transaction_retry():
    # Firestore may retry a transaction function on contention; the retry
    # re-reads the same pre-write state and re-runs the body. Given identical
    # inputs (no intervening commit), the pure allocator must return the same
    # answer every time it is invoked, not just the first.
    kwargs = {"stored_next_slot": None, "assigned_slots": [1, 2, 4]}

    first_attempt = next_account_slot(**kwargs)
    retried_attempt = next_account_slot(**kwargs)

    assert first_attempt == retried_attempt == 5


def test_next_account_slot_retry_after_concurrent_commit_still_does_not_duplicate():
    # A retry that runs after a *different* transaction committed a new slot
    # sees updated assigned_slots on its re-read. The result must still not
    # collide with anything already committed.
    first_attempt = next_account_slot(stored_next_slot=None, assigned_slots=[1])
    assert first_attempt == 2

    # Simulate: another transaction committed slot 2 in between attempt 1 and
    # the retry (attempt 1 above never wrote anything, mirroring an aborted
    # first try). The retry re-reads with the new state.
    retried_attempt = next_account_slot(stored_next_slot=None, assigned_slots=[1, 2])

    assert retried_attempt == 3
    assert retried_attempt != first_attempt

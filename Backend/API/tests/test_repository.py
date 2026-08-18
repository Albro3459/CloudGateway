from dataclasses import replace
from uuid import UUID

import pytest

from src.enums import ClientStatus, MeshPeerStatus, Role
from src.errors import (
    AdminRequiredError,
    CapacityReachedError,
    ClientNotFoundError,
    LimitReachedError,
    RegionDisabledError,
    RegionMismatchError,
)
from src.firebase import FirestoreRepository, _region_from_data, _user_from_data, _user_write_data
from src.repository import (
    MAX_ACCOUNT_SLOT,
    MIN_ACCOUNT_SLOT,
    ClientDoc,
    MeshPeerState,
    PolicyStatus,
    RegionDoc,
    RegionRegistration,
    UserDoc,
    next_account_slot,
    next_tunnel_index,
    region_tunnel_index_bounds,
    tunnel_addresses_for_index,
    used_tunnel_indices,
    valid_account_slot,
)

from .fakes import FakeRepository


REGION_ID = "us-test-1"


def enabled_region(*, capacity_limit: int = 10) -> RegionDoc:
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
        capacity_limit=capacity_limit,
    )


@pytest.fixture
def repository() -> FakeRepository:
    repo = FakeRepository(local_region_id=REGION_ID)
    repo.regions[REGION_ID] = enabled_region()
    repo.roles["user-1"] = Role.USER
    repo.roles["admin-1"] = Role.ADMIN
    return repo


class AuthDeleteRecorder:
    def __init__(self):
        self.deleted_uids: list[str] = []

    def delete_user(self, uid: str) -> None:
        self.deleted_uids.append(uid)


class RollbackRepository(FirestoreRepository):
    def __init__(self, role: Role | None):
        self.role = role

    def get_role(self, uid: str) -> Role | None:
        return self.role


def reserve(
    repository: FakeRepository,
    *,
    uid: str = "user-1",
    email: str = "user@example.com",
    client_name: str = "Phone",
):
    return repository.reserve_client(
        owner_uid=uid,
        owner_email=email,
        region_id=REGION_ID,
        client_name=client_name,
    )


@pytest.mark.parametrize("field", ["enabled", "meshEnabled"])
@pytest.mark.parametrize("value", ["true", "false", 1, 0, [], {}])
def test_region_decode_only_accepts_literal_true_for_booleans(field, value):
    data = {field: value}

    region = _region_from_data(data, REGION_ID)

    assert getattr(region, "mesh_enabled" if field == "meshEnabled" else field) is False


def test_region_decode_missing_wireguard_port_is_incomplete():
    region = _region_from_data({}, REGION_ID)

    assert region.wireguard_port is None


def test_rollback_does_not_delete_auth_when_role_exists():
    repository = RollbackRepository(Role.USER)
    auth = AuthDeleteRecorder()

    repository._rollback_created_auth_user(auth=auth, uid="user-1", already_existed=False)

    assert auth.deleted_uids == []


def test_rollback_deletes_created_auth_when_role_absent():
    repository = RollbackRepository(None)
    auth = AuthDeleteRecorder()

    repository._rollback_created_auth_user(auth=auth, uid="user-1", already_existed=False)

    assert auth.deleted_uids == ["user-1"]


def test_user_write_data_omits_display_name():
    data = _user_write_data(uid="user-1", email="user@example.com", exists=True)

    assert "displayName" not in data


def test_list_admin_emails_filters_missing_blank_non_admin_and_duplicates(repository: FakeRepository):
    repository.roles["admin-2"] = Role.ADMIN
    repository.roles["admin-3"] = Role.ADMIN
    repository.roles["missing-admin"] = Role.ADMIN
    repository.users["admin-1"] = UserDoc(uid="admin-1", email=" admin@example.com ")
    repository.users["admin-2"] = UserDoc(uid="admin-2", email="ADMIN@example.com")
    repository.users["admin-3"] = UserDoc(uid="admin-3", email=" ")
    repository.users["user-1"] = UserDoc(uid="user-1", email="user@example.com")

    assert repository.list_admin_emails() == ["admin@example.com"]


def _client_doc(*, ipv4: str, ipv6: str, status: ClientStatus = ClientStatus.ACTIVE) -> ClientDoc:
    return ClientDoc(
        client_id="client-1",
        owner_uid="user-1",
        owner_email="user@example.com",
        client_name="Test",
        region_id=REGION_ID,
        status=status,
        assigned_tunnel_ipv4=ipv4,
        assigned_tunnel_ipv6=ipv6,
        server_endpoint_ipv4="203.0.113.10",
        server_public_key="server-public-key",
        client_public_key="client-public-key",
        wireguard_config=None,
    )


def test_region_tunnel_index_bounds_excludes_network_and_broadcast_addresses():
    assert region_tunnel_index_bounds("10.0.0.0/24") == (2, 254)
    assert region_tunnel_index_bounds("10.0.0.0/29") == (2, 6)


def test_used_tunnel_indices_reserves_index_from_either_address_family():
    clients = [
        _client_doc(ipv4="10.0.0.5/32", ipv6=""),
        _client_doc(ipv4="", ipv6="fd42:42:42::9/128"),
    ]
    assert used_tunnel_indices(clients, ipv4_cidr="10.0.0.0/24", ipv6_cidr="fd42:42:42::/64") == {5, 9}


def test_used_tunnel_indices_ignores_unparseable_and_out_of_network_addresses():
    clients = [
        _client_doc(ipv4="not-an-ip/32", ipv6="fd42:42:42::9/128"),
        _client_doc(ipv4="192.168.0.5/32", ipv6=""),
    ]
    assert used_tunnel_indices(clients, ipv4_cidr="10.0.0.0/24", ipv6_cidr="fd42:42:42::/64") == {9}


def test_next_tunnel_index_starts_at_minimum_when_stored_index_missing_or_invalid():
    assert next_tunnel_index(stored_index=None, used_indices=set(), ipv4_cidr="10.0.0.0/24") == 2
    assert next_tunnel_index(stored_index=1, used_indices=set(), ipv4_cidr="10.0.0.0/24") == 2
    assert next_tunnel_index(stored_index=999, used_indices=set(), ipv4_cidr="10.0.0.0/24") == 2


def test_next_tunnel_index_advances_by_one():
    assert next_tunnel_index(stored_index=5, used_indices=set(), ipv4_cidr="10.0.0.0/24") == 6


def test_next_tunnel_index_wraps_and_skips_in_use():
    # /29 -> bounds (2, 6). This is the load-bearing path: a real region
    # wraps after exhausting its host range, and a wrapped index must still
    # skip whatever is still in use rather than double-issuing an address.
    assert next_tunnel_index(stored_index=6, used_indices=set(), ipv4_cidr="10.0.0.0/29") == 2
    assert next_tunnel_index(stored_index=6, used_indices={2, 3}, ipv4_cidr="10.0.0.0/29") == 4


def test_next_tunnel_index_raises_when_every_index_in_use():
    with pytest.raises(CapacityReachedError):
        next_tunnel_index(stored_index=2, used_indices={2, 3, 4, 5, 6}, ipv4_cidr="10.0.0.0/29")


def test_tunnel_addresses_for_index_matches_hosts_output_form():
    assert tunnel_addresses_for_index(index=2, ipv4_cidr="10.0.0.0/24", ipv6_cidr="fd42:42:42::/64") == (
        "10.0.0.2/32",
        "fd42:42:42::2/128",
    )
    assert tunnel_addresses_for_index(index=6, ipv4_cidr="10.0.0.0/29", ipv6_cidr="fd42:42:42::/126") == (
        "10.0.0.6/32",
        "fd42:42:42::6/128",
    )


def test_next_account_slot_defaults_to_minimum_when_missing_or_invalid_and_no_assigned_slots():
    assert next_account_slot(stored_next_slot=None, assigned_slots=[]) == 1
    assert next_account_slot(stored_next_slot=0, assigned_slots=[]) == 1
    assert next_account_slot(stored_next_slot=-3, assigned_slots=[]) == 1


def test_next_account_slot_returns_stored_value_when_above_every_assigned_slot():
    assert next_account_slot(stored_next_slot=42, assigned_slots=[1, 2]) == 42


def test_next_account_slot_constants_agree_with_policy_module():
    from src import policy

    assert MIN_ACCOUNT_SLOT == policy.MIN_SLOT
    assert MAX_ACCOUNT_SLOT == policy.MAX_SLOT


@pytest.mark.parametrize(
    "value",
    [0, -1, True, False, "5", "not-a-slot", 2**32, MAX_ACCOUNT_SLOT + 1, None, 3.5, [], {}],
)
def test_valid_account_slot_rejects_invalid_types_and_ranges(value):
    assert valid_account_slot(value) is None


@pytest.mark.parametrize("value", [MIN_ACCOUNT_SLOT, MAX_ACCOUNT_SLOT, 42])
def test_valid_account_slot_accepts_in_range_ints(value):
    assert valid_account_slot(value) == value


def test_region_decode_parses_tunnel_indices():
    region = _region_from_data({"tunnelIndexV4": 5, "tunnelIndexV6": 5}, REGION_ID)

    assert region.tunnel_index_v4 == 5
    assert region.tunnel_index_v6 == 5


def test_user_decode_parses_account_slot():
    user = _user_from_data({"accountSlot": 7}, "user-1")

    assert user.account_slot == 7


def test_user_write_data_never_clears_existing_slot_when_none_passed():
    data = _user_write_data(uid="user-1", email="user@example.com", exists=True)

    assert "accountSlot" not in data


def test_user_write_data_sets_account_slot_when_provided():
    data = _user_write_data(uid="user-1", email="user@example.com", exists=True, account_slot=9)

    assert data["accountSlot"] == 9


def test_reserve_client_creates_creating_doc_and_user_doc(repository: FakeRepository):
    client = reserve(repository, client_name=" Phone ")

    parsed_id = UUID(client.client_id)
    assert parsed_id.version == 4
    assert client.status == ClientStatus.CREATING
    assert client.owner_uid == "user-1"
    assert client.owner_email == "user@example.com"
    assert client.client_name == "Phone"
    assert client.assigned_tunnel_ipv4 == "10.0.0.2/32"
    assert client.assigned_tunnel_ipv6 == "fd42:42:42::2/128"
    assert client.server_endpoint_ipv4 == "203.0.113.10"
    assert client.server_public_key == "server-public-key"
    assert client.client_public_key == ""
    assert client.wireguard_config is None
    assert client.last_error_code is None
    assert client.last_error_message is None
    assert repository.get_user("user-1") is not None
    assert len(repository._allocated_region_clients(REGION_ID)) == 1


def test_reserve_client_enforces_local_region(repository: FakeRepository):
    with pytest.raises(RegionMismatchError):
        repository.reserve_client(
            owner_uid="user-1",
            owner_email="user@example.com",
            region_id="us-other-1",
            client_name="Phone",
        )


def test_reserve_client_enforces_region_enabled(repository: FakeRepository):
    repository.regions[REGION_ID] = enabled_region()
    repository.regions[REGION_ID] = replace(repository.regions[REGION_ID], enabled=False)

    with pytest.raises(RegionDisabledError):
        reserve(repository)


def test_normal_user_limit_is_three_per_region(repository: FakeRepository):
    for index in range(3):
        reserve(repository, client_name=f"Client {index}")

    with pytest.raises(LimitReachedError):
        reserve(repository, client_name="Client 4")


def test_normal_user_limit_follows_user_role_override(repository: FakeRepository):
    repository.per_region_client_limits["user-1"] = 5

    for index in range(5):
        reserve(repository, client_name=f"Client {index}")

    with pytest.raises(LimitReachedError):
        reserve(repository, client_name="Client 6")


def test_zero_user_limit_override_blocks_first_client(repository: FakeRepository):
    repository.per_region_client_limits["user-1"] = 0

    with pytest.raises(LimitReachedError):
        reserve(repository)


def test_null_role_default_means_no_user_limit(repository: FakeRepository):
    repository.role_defaults[Role.USER] = None

    for index in range(10):
        reserve(repository, client_name=f"Client {index}")


def test_admin_can_exceed_normal_limit_until_capacity(repository: FakeRepository):
    repository.regions[REGION_ID] = enabled_region(capacity_limit=4)

    for index in range(4):
        reserve(
            repository,
            uid="admin-1",
            email="admin@example.com",
            client_name=f"Admin Client {index}",
        )

    assert len(repository._allocated_region_clients(REGION_ID)) == 4
    with pytest.raises(CapacityReachedError):
        reserve(
            repository,
            uid="admin-1",
            email="admin@example.com",
            client_name="Admin Client 5",
        )


def test_capacity_applies_to_all_allocated_clients(repository: FakeRepository):
    repository.regions[REGION_ID] = enabled_region(capacity_limit=1)
    reserve(repository)

    with pytest.raises(CapacityReachedError):
        repository.reserve_client(
            owner_uid="user-2",
            owner_email="user2@example.com",
            region_id=REGION_ID,
            client_name="Laptop",
        )


def test_mark_client_active_stores_public_key_and_config(repository: FakeRepository):
    client = reserve(repository)

    updated = repository.mark_client_active(
        owner_uid=client.owner_uid,
        region_id=client.region_id,
        client_id=client.client_id,
        client_public_key="client-public-key",
        wireguard_config="[Interface]\nPrivateKey = hidden",
    )

    assert updated.status == ClientStatus.ACTIVE
    assert updated.client_public_key == "client-public-key"
    assert updated.wireguard_config == "[Interface]\nPrivateKey = hidden"
    assert len(repository._allocated_region_clients(REGION_ID)) == 1


def test_mark_client_failed_records_error(repository: FakeRepository):
    client = reserve(repository)

    failed = repository.mark_client_failed(
        owner_uid=client.owner_uid,
        region_id=client.region_id,
        client_id=client.client_id,
        error_code="WIREGUARD_APPLY_FAILED",
        error_message="Apply failed.",
    )

    assert failed.status == ClientStatus.FAILED
    assert failed.last_error_code == "WIREGUARD_APPLY_FAILED"
    assert failed.last_error_message == "Apply failed."
    assert len(repository._allocated_region_clients(REGION_ID)) == 0


def test_remove_client_reservation_is_idempotent(repository: FakeRepository):
    client = reserve(repository)

    removed = repository.remove_client_reservation(
        owner_uid=client.owner_uid,
        region_id=client.region_id,
        client_id=client.client_id,
        error_code="WIREGUARD_APPLY_FAILED",
        error_message="Apply failed.",
    )
    removed_again = repository.remove_client_reservation(
        owner_uid=client.owner_uid,
        region_id=client.region_id,
        client_id=client.client_id,
        error_code="WIREGUARD_APPLY_FAILED",
        error_message="Apply failed.",
    )

    assert removed.status == ClientStatus.REMOVED
    assert removed.removed_at is not None
    assert removed_again.status == ClientStatus.REMOVED
    assert len(repository._allocated_region_clients(REGION_ID)) == 0


def test_normal_user_cannot_delete_another_users_client(repository: FakeRepository):
    client = repository.reserve_client(
        owner_uid="user-2",
        owner_email="user2@example.com",
        region_id=REGION_ID,
        client_name="Laptop",
    )

    with pytest.raises(AdminRequiredError):
        repository.delete_client(
            requester_uid="user-1",
            target_uid="user-2",
            region_id=REGION_ID,
            client_id=client.client_id,
        )


def test_admin_can_delete_any_users_client(repository: FakeRepository):
    client = reserve(repository)

    removed = repository.delete_client(
        requester_uid="admin-1",
        target_uid="user-1",
        region_id=REGION_ID,
        client_id=client.client_id,
    )

    assert removed.status == ClientStatus.REMOVED
    assert removed.removed_at is not None
    assert len(repository._allocated_region_clients(REGION_ID)) == 0


def test_delete_works_in_disabled_region(repository: FakeRepository):
    client = reserve(repository)
    repository.regions[REGION_ID] = replace(repository.regions[REGION_ID], enabled=False)

    removed = repository.delete_client(
        requester_uid="user-1",
        target_uid="user-1",
        region_id=REGION_ID,
        client_id=client.client_id,
    )

    assert removed.status == ClientStatus.REMOVED
    assert len(repository._allocated_region_clients(REGION_ID)) == 0


def test_delete_missing_client_raises_not_found(repository: FakeRepository):
    with pytest.raises(ClientNotFoundError):
        repository.delete_client(
            requester_uid="admin-1",
            target_uid="user-1",
            region_id=REGION_ID,
            client_id="missing-client",
        )


def test_region_doc_defaults_mesh_disabled_and_no_tunnel_cidrs():
    region = enabled_region()
    assert region.mesh_enabled is False
    assert region.tunnel_network_v4 == ""
    assert region.tunnel_network_v6 == ""


def test_write_mesh_status_records_last_write_per_region(repository: FakeRepository):
    peer = MeshPeerState(
        region_id="us-other-1",
        endpoint_hostname="wg.us-other-1.example.com",
        public_key="peer-public-key",
        allowed_network_v4="10.0.1.0/24",
        allowed_network_v6="fd42:42:42:1::/64",
        status=MeshPeerStatus.APPLIED,
    )

    repository.write_mesh_status(region_id=REGION_ID, mesh_enabled=True, peers=[peer])

    mesh_enabled, peers = repository.mesh_status[REGION_ID]
    assert mesh_enabled is True
    assert peers == (peer,)


def test_write_mesh_status_can_be_forced_to_fail(repository: FakeRepository):
    repository.write_mesh_status_error = RuntimeError("simulated Firestore write failure")

    with pytest.raises(RuntimeError):
        repository.write_mesh_status(region_id=REGION_ID, mesh_enabled=True, peers=[])


def test_create_user_allocates_account_slot_once_per_account(repository: FakeRepository):
    first = repository.create_user(email="new@example.com")
    second = repository.create_user(email="second@example.com")

    assert first.user.account_slot == 1
    assert second.user.account_slot == 2


def test_create_user_reuses_slot_for_existing_unrostered_account(repository: FakeRepository):
    repository.users["user-9"] = UserDoc(uid="user-9", email="existing@example.com", account_slot=None)

    result = repository.create_user(email="existing@example.com")

    assert result.already_existed is True
    assert result.user.account_slot == 1
    assert repository.account_slots["user-9"] == 1


def test_reserve_client_lazily_allocates_account_slot(repository: FakeRepository):
    reserve(repository)

    slot = repository.get_account_slot("user-1")
    assert slot is not None
    assert repository.users["user-1"].account_slot == slot


def test_reserve_client_does_not_reallocate_existing_account_slot(repository: FakeRepository):
    reserve(repository)
    first_slot = repository.get_account_slot("user-1")

    reserve(repository, client_name="Second")

    assert repository.get_account_slot("user-1") == first_slot


def test_reserve_client_advances_region_tunnel_index(repository: FakeRepository):
    reserve(repository)
    assert repository.regions[REGION_ID].tunnel_index_v4 == 2
    assert repository.regions[REGION_ID].tunnel_index_v6 == 2

    reserve(repository, client_name="Second")
    assert repository.regions[REGION_ID].tunnel_index_v4 == 3
    assert repository.regions[REGION_ID].tunnel_index_v6 == 3


def test_upsert_region_preserves_tunnel_indices_across_reregister(repository: FakeRepository):
    reserve(repository)
    registration = RegionRegistration(
        region_id=REGION_ID,
        display_name="Test Region",
        display_order=1,
        capacity_limit=10,
        wireguard_endpoint_ipv4="203.0.113.10",
        wireguard_endpoint_hostname="",
        wireguard_port=51820,
        wireguard_dns_ipv4="10.0.0.1",
        wireguard_dns_ipv6="fd42:42:42::1",
        wireguard_public_key="server-public-key",
        tunnel_network_v4="10.0.0.0/24",
        tunnel_network_v6="fd42:42:42::/64",
    )

    updated = repository.upsert_region(registration, set_enabled=None)

    assert updated.tunnel_index_v4 == 2
    assert updated.tunnel_index_v6 == 2


def test_list_policy_clients_only_active_clients_with_a_public_key(repository: FakeRepository):
    active = reserve(repository)
    repository.mark_client_active(
        owner_uid=active.owner_uid,
        region_id=active.region_id,
        client_id=active.client_id,
        client_public_key="pubkey-1",
        wireguard_config="[Interface]",
    )
    reserve(repository, uid="user-2", email="user2@example.com", client_name="Still creating")

    entries = repository.list_policy_clients()

    assert len(entries) == 1
    assert entries[0].owner_uid == "user-1"
    assert entries[0].region_id == REGION_ID
    assert entries[0].assigned_tunnel_ipv4 == active.assigned_tunnel_ipv4
    assert entries[0].assigned_tunnel_ipv6 == active.assigned_tunnel_ipv6


def test_list_account_slots_returns_positive_slots_only(repository: FakeRepository):
    repository.account_slots["user-1"] = 3
    repository.account_slots["user-2"] = 0

    assert repository.list_account_slots() == {"user-1": 3}


def test_list_account_slots_excludes_invalid_types_and_out_of_range_values(repository: FakeRepository):
    repository.account_slots["user-1"] = 3
    repository.account_slots["user-2"] = -1
    repository.account_slots["user-3"] = MAX_ACCOUNT_SLOT + 1
    repository.account_slots["user-4"] = True  # type: ignore[assignment]
    repository.account_slots["user-5"] = "5"  # type: ignore[assignment]

    assert repository.list_account_slots() == {"user-1": 3}


def test_list_admin_uids_returns_admin_role_uids(repository: FakeRepository):
    assert repository.list_admin_uids() == {"admin-1"}


def test_get_account_slot_returns_none_when_absent(repository: FakeRepository):
    assert repository.get_account_slot("nobody") is None


def test_get_account_slot_returns_none_for_invalid_stored_value(repository: FakeRepository):
    repository.account_slots["user-1"] = MAX_ACCOUNT_SLOT + 1

    assert repository.get_account_slot("user-1") is None


def test_write_policy_status_records_last_write_per_region(repository: FakeRepository):
    status = PolicyStatus(
        region_id=REGION_ID,
        map_hash_v4="hash-v4",
        map_hash_v6="hash-v6",
        row_count=1,
        applied_sequence=1,
    )

    repository.write_policy_status(status)

    assert repository.policy_status[REGION_ID] == status


def test_write_policy_status_can_be_forced_to_fail(repository: FakeRepository):
    repository.write_policy_status_error = RuntimeError("simulated Firestore write failure")

    with pytest.raises(RuntimeError):
        repository.write_policy_status(
            PolicyStatus(region_id=REGION_ID, map_hash_v4="", map_hash_v6="", row_count=0, applied_sequence=0)
        )

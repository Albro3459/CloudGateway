from dataclasses import replace
from uuid import UUID

import pytest

from src.enums import ClientStatus, Role
from src.errors import (
    AdminRequiredError,
    CapacityReachedError,
    ClientNotFoundError,
    LimitReachedError,
    RegionDisabledError,
    RegionMismatchError,
)
from src.firebase import FirestoreRepository, _user_write_data
from src.repository import RegionDoc, UserDoc

from .fakes import FakeRepository


REGION_ID = "us-test-1"


def enabled_region(*, capacity_limit: int = 10, active_client_count: int = 0) -> RegionDoc:
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
        active_client_count=active_client_count,
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
    client_name: str | None = "Phone",
):
    return repository.reserve_client(
        owner_uid=uid,
        owner_email=email,
        region_id=REGION_ID,
        client_name=client_name,
    )


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


def require_test_region(repository: FakeRepository) -> RegionDoc:
    region = repository.get_region(REGION_ID)
    assert region is not None
    return region


def test_reserve_client_creates_creating_doc_user_doc_and_counter(repository: FakeRepository):
    client = reserve(repository, client_name="  ")

    parsed_id = UUID(client.client_id)
    assert parsed_id.version == 4
    assert client.status == ClientStatus.CREATING
    assert client.owner_uid == "user-1"
    assert client.owner_email == "user@example.com"
    assert client.client_name == "CloudGateway Client"
    assert client.assigned_tunnel_ipv4 == "10.0.0.2/32"
    assert client.assigned_tunnel_ipv6 == "fd42:42:42::2/128"
    assert client.server_endpoint_ipv4 == "203.0.113.10"
    assert client.server_public_key == "server-public-key"
    assert client.client_public_key == ""
    assert client.wireguard_config is None
    assert client.last_error_code is None
    assert client.last_error_message is None
    assert repository.get_user("user-1") is not None
    user_region = repository.user_regions[("user-1", REGION_ID)]
    assert set(user_region) == {"regionId", "updatedAt"}
    assert user_region["regionId"] == REGION_ID
    assert user_region["updatedAt"] is not None
    assert require_test_region(repository).active_client_count == 1


def test_reserve_client_enforces_local_region(repository: FakeRepository):
    with pytest.raises(RegionMismatchError):
        repository.reserve_client(
            owner_uid="user-1",
            owner_email="user@example.com",
            region_id="us-other-1",
            client_name=None,
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


def test_normal_user_limit_follows_region_doc(repository: FakeRepository):
    repository.regions[REGION_ID] = replace(
        enabled_region(capacity_limit=10), user_client_limit=5
    )

    for index in range(5):
        reserve(repository, client_name=f"Client {index}")

    with pytest.raises(LimitReachedError):
        reserve(repository, client_name="Client 6")


def test_admin_can_exceed_normal_limit_until_capacity(repository: FakeRepository):
    repository.regions[REGION_ID] = enabled_region(capacity_limit=4)

    for index in range(4):
        reserve(
            repository,
            uid="admin-1",
            email="admin@example.com",
            client_name=f"Admin Client {index}",
        )

    assert require_test_region(repository).active_client_count == 4
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
    assert require_test_region(repository).active_client_count == 1


def test_mark_client_failed_repairs_counter_and_records_error(repository: FakeRepository):
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
    assert require_test_region(repository).active_client_count == 0


def test_remove_client_reservation_repairs_counter_once(repository: FakeRepository):
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
    assert require_test_region(repository).active_client_count == 0


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
    assert require_test_region(repository).active_client_count == 0


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
    assert require_test_region(repository).active_client_count == 0


def test_delete_missing_client_raises_not_found(repository: FakeRepository):
    with pytest.raises(ClientNotFoundError):
        repository.delete_client(
            requester_uid="admin-1",
            target_uid="user-1",
            region_id=REGION_ID,
            client_id="missing-client",
        )

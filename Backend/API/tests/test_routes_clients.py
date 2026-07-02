from dataclasses import replace

import pytest

from src.enums import ClientStatus
from src.errors import FirebaseWriteFailedError
from src.repository import RegionDoc

from .conftest import REGION_ID
from .test_errors import assert_error_shape


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
        wireguard_endpoint_hostname="wg.us-test-1.example.com",
    )


def auth_header(token: str = "user-token") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def seed_region(repository) -> None:
    repository.regions[REGION_ID] = enabled_region()


def create_active_client(repository, wireguard, *, uid: str = "user-1"):
    client = repository.reserve_client(
        owner_uid=uid,
        owner_email=f"{uid}@example.com",
        region_id=REGION_ID,
        client_name="Phone",
    )
    active = repository.mark_client_active(
        owner_uid=uid,
        region_id=REGION_ID,
        client_id=client.client_id,
        client_public_key="fake-public-existing",
        wireguard_config="[Interface]\nPrivateKey = hidden",
    )
    wireguard.peers[active.client_public_key] = (active.assigned_tunnel_ipv4, active.assigned_tunnel_ipv6)
    return active


def test_create_client_requires_auth(client, repository):
    seed_region(repository)

    response = client.post("/clients", json={"regionId": REGION_ID, "clientName": "Phone"})

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")


def test_capacity_requires_auth(client, repository):
    seed_region(repository)

    response = client.get("/capacity")

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")


def test_capacity_counts_allocated_local_region_clients(client, repository):
    repository.regions[REGION_ID] = enabled_region(capacity_limit=3)
    repository.regions["us-other-1"] = replace(enabled_region(capacity_limit=99), region_id="us-other-1")

    creating = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Creating",
    )
    active = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Active",
    )
    repository.mark_client_active(
        owner_uid="user-1",
        region_id=REGION_ID,
        client_id=active.client_id,
        client_public_key="fake-public-active",
        wireguard_config="[Interface]\nPrivateKey = hidden",
    )
    failed = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Failed",
    )
    repository.mark_client_failed(
        owner_uid="user-1",
        region_id=REGION_ID,
        client_id=failed.client_id,
        error_code="TEST",
        error_message="failed",
    )
    removed = repository.reserve_client(
        owner_uid="user-1",
        owner_email="user@example.com",
        region_id=REGION_ID,
        client_name="Removed",
    )
    repository.remove_client_reservation(
        owner_uid="user-1",
        region_id=REGION_ID,
        client_id=removed.client_id,
    )
    repository.clients[("user-2", "us-other-1", "other-client")] = replace(
        creating,
        owner_uid="user-2",
        region_id="us-other-1",
        client_id="other-client",
    )

    response = client.get("/capacity", headers=auth_header())

    assert response.status_code == 200
    assert response.json() == {
        "regionId": REGION_ID,
        "capacityLimit": 3,
        "allocatedClientCount": 2,
    }


def test_create_client_reserves_applies_and_activates(client, repository, wireguard):
    seed_region(repository)

    response = client.post(
        "/clients",
        json={"regionId": REGION_ID, "clientName": " Phone "},
        headers=auth_header(),
    )

    assert response.status_code == 200
    payload = response.json()
    assert set(payload.keys()) == {
        "clientId",
        "regionId",
        "clientName",
        "status",
        "assignedTunnelIpv4",
        "assignedTunnelIpv6",
        "serverEndpointIpv4",
        "serverEndpointHostname",
        "wireguardConfig",
    }
    assert payload["regionId"] == REGION_ID
    assert payload["clientName"] == "Phone"
    assert payload["status"] == "active"
    assert payload["assignedTunnelIpv4"] == "10.0.0.2/32"
    assert payload["assignedTunnelIpv6"] == "fd42:42:42::2/128"
    assert payload["serverEndpointIpv4"] == "203.0.113.10"
    assert payload["serverEndpointHostname"] == "wg.us-test-1.example.com"
    assert payload["wireguardConfig"].startswith("[Interface]\n")
    assert "client_id" not in payload

    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=payload["clientId"])
    assert stored.status == ClientStatus.ACTIVE
    assert stored.client_public_key == "fake-public-1"
    assert set(wireguard.peers) == {"fake-public-1"}
    assert wireguard.peers["fake-public-1"] == ("10.0.0.2/32", "fd42:42:42::2/128")


@pytest.mark.parametrize("body", [
    {"regionId": REGION_ID},
    {"regionId": REGION_ID, "clientName": " "},
])
def test_create_client_requires_client_name(client, repository, body):
    seed_region(repository)

    response = client.post("/clients", json=body, headers=auth_header())

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")
    assert repository.clients == {}


def test_create_client_retries_one_transient_wireguard_add_failure(client, repository, wireguard):
    seed_region(repository)
    wireguard.fail_add_count = 1
    wireguard.fail_add_transient = True

    response = client.post(
        "/clients",
        json={"regionId": REGION_ID, "clientName": "Phone"},
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert wireguard.add_peer_calls == 2
    assert response.json()["status"] == "active"


def test_create_client_region_mismatch_is_controlled(client, repository):
    seed_region(repository)

    response = client.post(
        "/clients",
        json={"regionId": "us-other-1", "clientName": "Phone"},
        headers=auth_header(),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "REGION_MISMATCH")


def test_create_client_wireguard_failure_marks_reservation_failed(client, repository, wireguard):
    seed_region(repository)
    wireguard.fail_add_count = 1

    response = client.post(
        "/clients",
        json={"regionId": REGION_ID, "clientName": "Phone"},
        headers=auth_header(),
    )

    assert response.status_code == 500
    assert_error_shape(response.json(), "WIREGUARD_APPLY_FAILED")
    stored = next(iter(repository.clients.values()))
    assert stored.status == ClientStatus.FAILED
    assert stored.last_error_code == "WIREGUARD_APPLY_FAILED"
    assert all(client.status != ClientStatus.CREATING for client in repository.clients.values())
    assert wireguard.peers == {}


def test_create_client_final_firebase_failure_removes_peer_and_reservation(client, repository, wireguard):
    seed_region(repository)
    repository.mark_client_active_error = FirebaseWriteFailedError("Simulated final write failure.")

    response = client.post(
        "/clients",
        json={"regionId": REGION_ID, "clientName": "Phone"},
        headers=auth_header(),
    )

    assert response.status_code == 500
    assert_error_shape(response.json(), "FIREBASE_WRITE_FAILED")
    stored = next(iter(repository.clients.values()))
    assert stored.status == ClientStatus.REMOVED
    assert stored.last_error_code == "FIREBASE_WRITE_FAILED"
    assert all(client.status != ClientStatus.CREATING for client in repository.clients.values())
    assert wireguard.peers == {}


def test_delete_client_self_removes_peer_and_marks_removed(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert response.json() == {
        "userId": "user-1",
        "clientId": active.client_id,
        "regionId": REGION_ID,
        "status": "removed",
    }
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored.status == ClientStatus.REMOVED
    assert wireguard.peers == {}


def test_delete_client_retries_one_transient_wireguard_remove_failure(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    wireguard.fail_remove_count = 1
    wireguard.fail_remove_transient = True

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert wireguard.remove_peer_calls == 2


def test_delete_client_firebase_failure_after_peer_removed_keeps_doc_active(client, repository, wireguard):
    # Peer removal runs before the Firebase write, so a failed write leaves the
    # doc ACTIVE (retryable) with the peer already gone. The next peer sync (at
    # boot, or a manual cloudgateway-sync-peers) re-adds the peer from the
    # still-ACTIVE doc; the doc never reaches REMOVED.
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    repository.delete_client_error = FirebaseWriteFailedError("Simulated delete write failure.")

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 500
    assert_error_shape(response.json(), "FIREBASE_WRITE_FAILED")
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored.status == ClientStatus.ACTIVE
    assert wireguard.peers == {}
    assert wireguard.remove_peer_calls == 1


def test_delete_client_wireguard_failure_keeps_firebase_active(client, repository, wireguard):
    # A failed peer removal aborts before the Firebase write, so the doc stays
    # ACTIVE and the live peer is never orphaned by a REMOVED doc.
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    wireguard.fail_remove_count = 1

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 500
    assert_error_shape(response.json(), "WIREGUARD_APPLY_FAILED")
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored.status == ClientStatus.ACTIVE
    assert set(wireguard.peers) == {"fake-public-existing"}
    assert wireguard.remove_peer_calls == 1


def test_delete_client_normal_user_cannot_remove_another_users_client(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard, uid="user-2")

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-2", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 403
    assert_error_shape(response.json(), "ADMIN_REQUIRED")
    assert set(wireguard.peers) == {"fake-public-existing"}


def test_delete_client_admin_can_remove_any_users_client(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard, uid="user-1")

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header("admin-token"),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "removed"
    assert wireguard.peers == {}


def test_delete_client_missing_returns_not_found(client, repository):
    seed_region(repository)

    response = client.request(
        "DELETE",
        "/clients/missing-client",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 404
    assert_error_shape(response.json(), "CLIENT_NOT_FOUND")


def test_delete_client_mismatched_document_fields_returns_not_found_before_peer_mutation(
    client,
    repository,
    wireguard,
):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    repository.clients[("user-1", REGION_ID, active.client_id)] = replace(active, owner_uid="user-2")

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 404
    assert_error_shape(response.json(), "CLIENT_NOT_FOUND")
    assert set(wireguard.peers) == {"fake-public-existing"}


def test_delete_client_uses_removed_status_even_if_document_was_already_removed(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    repository.clients[("user-1", REGION_ID, active.client_id)] = replace(active, status=ClientStatus.REMOVED)

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "removed"

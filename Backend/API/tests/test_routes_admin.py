from .test_errors import assert_error_shape
from .test_routes_clients import auth_header, create_active_client, seed_region
from .conftest import REGION_ID


def test_admin_sync_requires_auth(client, repository):
    seed_region(repository)

    response = client.post("/admin/sync", json={"regionId": REGION_ID})

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")


def test_admin_sync_requires_admin(client, repository):
    seed_region(repository)

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("user-token"))

    assert response.status_code == 403
    assert_error_shape(response.json(), "ADMIN_REQUIRED")


def test_admin_sync_rejects_region_mismatch(client, repository):
    seed_region(repository)

    response = client.post("/admin/sync", json={"regionId": "eu-other-1"}, headers=auth_header("admin-token"))

    assert response.status_code == 400
    assert_error_shape(response.json(), "REGION_MISMATCH")


def test_admin_sync_reports_no_changes_when_state_matches(client, repository, wireguard):
    seed_region(repository)
    create_active_client(repository, wireguard)

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 200
    payload = response.json()
    assert payload["regionId"] == REGION_ID
    assert (payload["added"], payload["updated"], payload["removed"]) == (0, 0, 0)
    assert payload["noChanges"] is True
    assert "No peer changes were required" in payload["log"]
    assert "\x1b" not in payload["log"]


def test_admin_sync_adds_missing_and_removes_unknown_with_audit_detail(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    # Drop the active client's peer (must be re-added) and inject an unknown
    # host peer with no Firebase doc (must be removed).
    del wireguard.peers[active.client_public_key]
    wireguard.peers["unknown-public-key"] = ("10.0.0.9/32", "fd42:42:42::9/128")

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 200
    payload = response.json()
    assert (payload["added"], payload["updated"], payload["removed"]) == (1, 0, 1)
    assert payload["noChanges"] is False

    log = payload["log"]
    assert "\x1b" not in log
    assert f"clientId={active.client_id}" in log
    assert "email=user-1@example.com" in log
    assert "publicKey=unknown-public-key" in log
    # The re-added peer is now live again; the unknown peer is gone.
    assert active.client_public_key in wireguard.peers
    assert "unknown-public-key" not in wireguard.peers

from dataclasses import replace

import pytest

from .fakes import FAKE_MESH_PUBLIC_KEY, FAKE_MESH_PUBLIC_KEY_2
from .test_errors import assert_error_shape
from .test_routes_clients import auth_header, create_active_client, enabled_region, seed_region
from .conftest import REGION_ID


def seed_mesh_enabled_region(repository) -> None:
    repository.regions[REGION_ID] = replace(
        enabled_region(),
        tunnel_network_v4="10.0.0.0/24",
        tunnel_network_v6="fd42:42:42::/64",
        mesh_enabled=True,
    )


def seed_mesh_candidate(repository, *, region_id: str = "us-other-1") -> None:
    repository.regions[region_id] = replace(
        enabled_region(),
        region_id=region_id,
        wireguard_public_key=FAKE_MESH_PUBLIC_KEY,
        wireguard_endpoint_hostname=f"wg.{region_id}.example.com",
        tunnel_network_v4="10.0.1.0/24",
        tunnel_network_v6="fd42:42:42:1::/64",
        mesh_enabled=True,
    )


def test_admin_sync_reports_unwritten_mesh_status_without_failing(client, repository, wireguard):
    # The interface is reconciled either way; only the durable snapshot the dashboard
    # renders from is stale, so the pass must succeed and say so in the response.
    seed_mesh_enabled_region(repository)
    seed_mesh_candidate(repository)
    repository.write_mesh_status_error = RuntimeError("simulated Firestore write failure")

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 200
    payload = response.json()
    assert payload["meshStatusWritten"] is False
    assert payload["meshApplied"] == 1


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


def test_admin_sync_sheds_instead_of_queueing_when_a_sync_is_running(client, repository, wireguard):
    # A retry or a concurrent Sync All must fail fast rather than block a thread-pool
    # slot on the flock behind the running pass.
    seed_region(repository)
    wireguard.locked = True

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 409
    assert_error_shape(response.json(), "SYNC_IN_PROGRESS")
    assert wireguard.sync_calls == 0


def test_admin_sync_reports_no_changes_when_state_matches(client, repository, wireguard):
    seed_region(repository)
    create_active_client(repository, wireguard)

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 200
    payload = response.json()
    assert payload["regionId"] == REGION_ID
    assert (payload["added"], payload["updated"], payload["removed"]) == (0, 0, 0)
    assert payload["noChanges"] is True
    assert "No client peer changes were required; the live peer set already matched Firebase." in payload["log"]
    assert "\x1b" not in payload["log"]


def test_admin_sync_returns_success_when_audit_enrichment_fails(client, repository, wireguard, caplog):
    seed_region(repository)
    create_active_client(repository, wireguard)
    repository.list_clients_by_public_key_error = RuntimeError("enrichment unavailable")

    with caplog.at_level("WARNING", logger="src.routes"):
        response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 200
    payload = response.json()
    assert (payload["added"], payload["updated"], payload["removed"]) == (0, 0, 0)
    assert payload["noChanges"] is True
    assert "peer_sync_enrichment_failed" in caplog.text


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


def test_admin_sync_response_carries_full_mesh_wire_contract(client, repository, wireguard):
    seed_mesh_enabled_region(repository)
    seed_mesh_candidate(repository)

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 200
    payload = response.json()
    assert payload["meshEnabled"] is True
    assert payload["meshApplied"] == 1
    assert payload["meshAdded"] == 1
    assert payload["meshRemoved"] == 0
    assert payload["meshSkipped"] == 0
    assert payload["meshRoutesAdded"] == 2
    assert payload["meshRoutesRemoved"] == 0
    assert payload["meshStatusWritten"] is True
    assert payload["noChanges"] is False
    assert payload["meshPeers"] == [
        {
            "regionId": "us-other-1",
            "status": "applied",
            "endpointHostname": "wg.us-other-1.example.com",
            "endpointPort": 51820,
            "allowedNetworkV4": "10.0.1.0/24",
            "allowedNetworkV6": "fd42:42:42:1::/64",
        }
    ]
    # The pinned contract deliberately omits the mesh peer public key.
    assert "publicKey" not in response.text
    assert "mesh: enabled=True" in payload["log"]


@pytest.mark.parametrize(
    ("field", "value", "omitted", "retained"),
    [
        ("wireguard_endpoint_hostname", "", "endpointHostname", ["endpointPort", "allowedNetworkV4", "allowedNetworkV6"]),
        ("tunnel_network_v4", "10.0.1.0/25", "allowedNetworkV4", ["endpointHostname", "endpointPort", "allowedNetworkV6"]),
    ],
)
def test_admin_sync_skipped_incomplete_omits_invalid_optional_fields(
    client, repository, wireguard, field, value, omitted, retained
):
    seed_mesh_enabled_region(repository)
    seed_mesh_candidate(repository)
    repository.regions["us-other-1"] = replace(repository.regions["us-other-1"], **{field: value})

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    assert response.status_code == 200
    peer = response.json()["meshPeers"][0]
    assert peer["status"] == "skipped-incomplete"
    assert omitted not in peer
    for field_name in retained:
        assert field_name in peer


def test_admin_sync_skipped_incomplete_retains_independent_valid_fields(client, repository, wireguard):
    seed_mesh_enabled_region(repository)
    seed_mesh_candidate(repository)
    repository.regions["us-other-1"] = replace(
        repository.regions["us-other-1"],
        tunnel_network_v4="not-a-network",
    )

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    peer = response.json()["meshPeers"][0]
    assert peer["status"] == "skipped-incomplete"
    assert peer["endpointHostname"] == "wg.us-other-1.example.com"
    assert peer["endpointPort"] == 51820
    assert peer["allowedNetworkV6"] == "fd42:42:42:1::/64"
    assert "allowedNetworkV4" not in peer


def test_admin_sync_no_changes_is_false_then_true_across_two_mesh_passes(client, repository, wireguard):
    seed_mesh_enabled_region(repository)
    seed_mesh_candidate(repository)

    first = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))
    assert first.json()["noChanges"] is False

    second = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))
    payload = second.json()
    assert payload["noChanges"] is True
    assert payload["meshApplied"] == 1  # always re-applied
    assert payload["meshAdded"] == 0
    assert payload["meshRoutesAdded"] == 0


def test_admin_sync_reports_skipped_overlap_candidates_pairwise_and_never_leaks_the_key(client, repository, wireguard):
    # Two overlapping remotes both get skipped (picking a winner would silently
    # misroute the loser's client traffic); a third, healthy region still applies.
    seed_mesh_enabled_region(repository)
    seed_mesh_candidate(repository, region_id="us-other-1")
    repository.regions["us-conflict-1"] = replace(
        enabled_region(),
        region_id="us-conflict-1",
        wireguard_public_key=FAKE_MESH_PUBLIC_KEY_2,
        wireguard_endpoint_hostname="wg.us-conflict-1.example.com",
        tunnel_network_v4="10.0.1.0/24",  # overlaps us-other-1's 10.0.1.0/24
        tunnel_network_v6="fd42:42:42:9::/64",
        mesh_enabled=True,
    )

    response = client.post("/admin/sync", json={"regionId": REGION_ID}, headers=auth_header("admin-token"))

    payload = response.json()
    assert payload["meshSkipped"] == 2
    assert payload["meshApplied"] == 0
    peers = {peer["regionId"]: peer for peer in payload["meshPeers"]}
    assert peers["us-conflict-1"]["status"] == "skipped-overlap"
    assert peers["us-other-1"]["status"] == "skipped-overlap"
    assert peers["us-conflict-1"]["endpointPort"] == 51820
    assert peers["us-other-1"]["endpointPort"] == 51820
    assert FAKE_MESH_PUBLIC_KEY not in response.text
    assert FAKE_MESH_PUBLIC_KEY_2 not in response.text

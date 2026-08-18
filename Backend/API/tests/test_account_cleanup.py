import json
import logging
from dataclasses import replace
from urllib.error import URLError

from src.auth import AuthenticatedUser
import src.routes as routes
from src.enums import ClientStatus
from src.errors import FirebaseWriteFailedError
from src.policy_sync import desired_policy, reconcile_policy
from src.repository import ClientDoc, UserDoc, utc_now

from .conftest import REGION_ID
from .fakes import FAKE_PUBLIC_KEY_2
from .test_errors import assert_error_shape
from .test_routes_clients import auth_header, create_active_client, seed_region

# Wave 4 (account deletion ordering) test matrix - see
# .claude/subagents/LEDGER.md "Session 4 scope: Wave 4 only" (W4-0..W4-9) and
# TODO/account-scoped-acl.md "Account deletion". The implementation lives in
# src/routes.py (delete_account, delete_client, _remove_account_peers,
# _refresh_other_regions_once) and src/repository.py/src/firebase.py
# (mark_account_clients_inactive / AccountCleanupTally).


class _FakeUrlResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False


def _record_urlopen(calls: list[tuple[str, str, dict | None]]):
    """Records (method, url, parsed JSON body) per call. Never touches header
    values, so a bearer token can never end up in a test assertion or a
    pytest failure message."""

    def _fake(request, timeout=None):
        body = json.loads(request.data) if request.data else None
        calls.append((request.get_method(), request.full_url, body))
        return _FakeUrlResponse()

    return _fake


def _record_urlopen_unreachable(calls: list[tuple[str, str, dict | None]]):
    def _fake(request, timeout=None):
        body = json.loads(request.data) if request.data else None
        calls.append((request.get_method(), request.full_url, body))
        raise URLError("simulated unreachable region")

    return _fake


def _forbid_urlopen(calls: list[tuple[str, str]]):
    def _fake(request, timeout=None):
        calls.append((request.get_method(), request.full_url))
        raise AssertionError("no cross-region call is expected in this scenario")

    return _fake


def _seed_other_region(repository, region_id: str) -> None:
    repository.regions[region_id] = replace(repository.regions[REGION_ID], region_id=region_id)


def _seed_remote_client(
    repository,
    *,
    uid: str = "user-1",
    region_id: str,
    client_id: str,
    public_key: str,
) -> ClientDoc:
    # FakeRepository.clients is keyed by (owner_uid, region_id, client_id).
    # reserve_client enforces ensure_local_region, so a remote-region client
    # (one the local API does not own) has to be seeded directly here. A real
    # client always has a parent User doc, so seed one too (mirrors
    # reserve_client's own lazy-provisioning fallback) - otherwise
    # repository.get_user(uid) can never distinguish "never existed" from
    # "hard-deleted", which several assertions below rely on.
    repository.users.setdefault(uid, UserDoc(uid=uid, email=f"{uid}@example.com", created_at=utc_now()))
    client = ClientDoc(
        client_id=client_id,
        owner_uid=uid,
        owner_email=f"{uid}@example.com",
        client_name="Remote",
        region_id=region_id,
        status=ClientStatus.ACTIVE,
        assigned_tunnel_ipv4="10.0.0.2",
        assigned_tunnel_ipv6="fd00::2",
        server_endpoint_ipv4="203.0.113.20",
        server_public_key="server-pub-remote",
        client_public_key=public_key,
        wireguard_config=None,
    )
    repository.clients[(uid, region_id, client_id)] = client
    return client


def _completed_event_fields(caplog) -> dict:
    completed = [record for record in caplog.records if record.message == "account_delete_completed"]
    assert len(completed) == 1
    return completed[0].event_fields


# --- 1. Local-only deletion -------------------------------------------------


def test_delete_account_local_only_has_no_cross_region_calls(client, repository, wireguard, policy, monkeypatch):
    # Only the local region is registered at all, so "every other enabled
    # region" is empty: no refresh wave, no remote per-client delete, nothing.
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(routes, "urlopen", _forbid_urlopen(calls))

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 200
    assert response.json() == {"userId": "user-1", "deletedClientCount": 1}
    assert calls == []
    assert wireguard.peers == {}
    assert repository.mark_account_clients_inactive_calls == 1
    assert repository.get_user("user-1") is None
    assert repository.get_role("user-1") is None
    assert repository.deleted_auth_uids == ["user-1"]
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id) is None
    # The local reconcile is still queued exactly once, even with nothing to poke.
    assert policy.apply_calls == 1


# --- 2. Remote deletion ------------------------------------------------------


def test_delete_account_remote_client_sends_cleanup_delete_then_refresh(client, repository, wireguard, monkeypatch):
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    remote = _seed_remote_client(repository, region_id="us-other-1", client_id="remote-1", public_key="pub-remote-1")
    calls: list[tuple[str, str, dict | None]] = []
    monkeypatch.setattr(routes, "urlopen", _record_urlopen(calls))

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 200
    assert response.json() == {"userId": "user-1", "deletedClientCount": 1}
    assert len(calls) == 2
    delete_call, refresh_call = calls
    assert delete_call == (
        "DELETE",
        f"https://us-other-1.gocloudlaunch.com/api/clients/{remote.client_id}",
        {"userId": "user-1", "regionId": "us-other-1", "accountCleanup": True},
    )
    assert refresh_call == ("POST", "https://us-other-1.gocloudlaunch.com/api/sync/refresh", None)


# --- 3. Mixed-region deletion ------------------------------------------------


def test_delete_account_mixed_local_and_remote_clients(client, repository, wireguard, monkeypatch):
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    local_active = create_active_client(repository, wireguard, uid="user-1")
    remote = _seed_remote_client(repository, region_id="us-other-1", client_id="remote-1", public_key="pub-remote-1")
    calls: list[tuple[str, str, dict | None]] = []
    monkeypatch.setattr(routes, "urlopen", _record_urlopen(calls))

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 200
    assert response.json() == {"userId": "user-1", "deletedClientCount": 2}
    # Local peer path exercised.
    assert local_active.client_public_key not in wireguard.peers
    assert wireguard.remove_peer_calls == 1
    # Remote peer path exercised: one delete, one refresh, still exactly one
    # refresh for the one other enabled region.
    delete_calls = [c for c in calls if c[0] == "DELETE"]
    refresh_calls = [c for c in calls if c[0] == "POST"]
    assert len(delete_calls) == 1
    assert delete_calls[0][1] == f"https://us-other-1.gocloudlaunch.com/api/clients/{remote.client_id}"
    assert refresh_calls == [("POST", "https://us-other-1.gocloudlaunch.com/api/sync/refresh", None)]
    assert not any(REGION_ID in call[1] for call in calls)


# --- 4. Unreachable region ----------------------------------------------------


def test_delete_account_completes_despite_unreachable_remote_region(client, repository, wireguard, monkeypatch, caplog):
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    _seed_remote_client(repository, region_id="us-other-1", client_id="remote-1", public_key="pub-remote-1")
    calls: list[tuple[str, str, dict | None]] = []
    monkeypatch.setattr(routes, "urlopen", _record_urlopen_unreachable(calls))

    with caplog.at_level(logging.INFO, logger="src.routes"):
        response = client.delete("/account", headers=auth_header())

    # A host that never answers must not abort the deletion: the remote
    # per-client delete is transient-tolerant, and the refresh wave swallows
    # every error by design.
    assert response.status_code == 200
    assert response.json() == {"userId": "user-1", "deletedClientCount": 1}
    fields = _completed_event_fields(caplog)
    # Nothing here may be silently reported as reachable: both counters must
    # reflect the failure, not be coerced to zero.
    assert fields["unreachableRegionCount"] == 1
    assert fields["refreshFailedRegionCount"] == 1


def test_delete_account_fences_unreachable_regions_client_even_when_hard_delete_fails(client, repository, wireguard, monkeypatch):
    # hard_delete_account_error is injected purely as an observation trick:
    # a normal run hard-deletes the client documents, making it impossible to
    # inspect their post-fence state. Blocking the hard delete lets the test
    # see that the unreachable region's client was fenced non-active anyway.
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    remote = _seed_remote_client(repository, region_id="us-other-1", client_id="remote-1", public_key="pub-remote-1")
    calls: list[tuple[str, str, dict | None]] = []
    monkeypatch.setattr(routes, "urlopen", _record_urlopen_unreachable(calls))
    repository.hard_delete_account_error = FirebaseWriteFailedError("simulated hard delete failure")

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 500
    assert repository.mark_account_clients_inactive_calls == 1
    fenced = repository.get_client(owner_uid="user-1", region_id="us-other-1", client_id=remote.client_id)
    assert fenced is not None
    assert fenced.status == ClientStatus.REMOVED
    assert repository.get_user("user-1") is not None  # hard delete never ran


# --- 5. Partial failure and retry --------------------------------------------


def test_delete_account_hard_delete_failure_after_fence_then_retry_is_idempotent(client, repository, wireguard, caplog):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    repository.hard_delete_account_error = FirebaseWriteFailedError("simulated hard delete failure")

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "FIREBASE_WRITE_FAILED")
    assert repository.mark_account_clients_inactive_calls == 1
    fenced = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert fenced is not None
    assert fenced.status == ClientStatus.REMOVED
    assert repository.get_user("user-1") is not None
    assert repository.deleted_auth_uids == []

    repository.hard_delete_account_error = None
    with caplog.at_level(logging.INFO, logger="src.routes"):
        retry = client.delete("/account", headers=auth_header())

    assert retry.status_code == 200
    assert retry.json() == {"userId": "user-1", "deletedClientCount": 1}
    assert repository.mark_account_clients_inactive_calls == 2
    assert repository.get_user("user-1") is None
    assert repository.deleted_auth_uids == ["user-1"]
    # Idempotent: the retry's fence sees the already-REMOVED document and
    # marks nothing new, while still counting the document it saw.
    fields = _completed_event_fields(caplog)
    assert fields["markedNonActiveCount"] == 0
    assert fields["deletedClientCount"] == 1


def test_delete_account_auth_delete_failure_after_fence_then_retry_is_idempotent(client, repository, wireguard, caplog):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    repository.delete_auth_user_error = RuntimeError("simulated auth service failure")

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "INTERNAL_ERROR")
    assert repository.mark_account_clients_inactive_calls == 1
    # hard_delete_account_documents already ran (it is before delete_auth_user
    # in W4-6's ordering), so the Firestore doc is gone even though the Auth
    # user survives - only the Auth user side is retryable here.
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id) is None
    assert repository.get_user("user-1") is None
    assert repository.deleted_auth_uids == []

    repository.delete_auth_user_error = None
    with caplog.at_level(logging.INFO, logger="src.routes"):
        retry = client.delete("/account", headers=auth_header())

    assert retry.status_code == 200
    assert retry.json() == {"userId": "user-1", "deletedClientCount": 0}
    assert repository.mark_account_clients_inactive_calls == 2
    assert repository.deleted_auth_uids == ["user-1"]
    fields = _completed_event_fields(caplog)
    assert fields["markedNonActiveCount"] == 0
    assert fields["deletedClientCount"] == 0


def test_delete_account_peer_removal_failure_before_fence_leaves_clients_active(client, repository, wireguard):
    seed_region(repository)
    active = create_active_client(repository, wireguard)
    wireguard.fail_remove_count = 1  # non-transient by default

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "WIREGUARD_APPLY_FAILED")
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored is not None
    assert stored.status == ClientStatus.ACTIVE
    assert set(wireguard.peers) == {FAKE_PUBLIC_KEY_2}
    assert repository.mark_account_clients_inactive_calls == 0
    assert repository.get_user("user-1") is not None
    assert repository.deleted_auth_uids == []


# --- 6. Spoofed cleanup mode --------------------------------------------------


def test_delete_client_cleanup_mode_rejects_admin_deleting_another_users_client(client, repository, wireguard, policy, monkeypatch):
    seed_region(repository)
    active = create_active_client(repository, wireguard, uid="user-1")
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(routes, "urlopen", _forbid_urlopen(calls))

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID, "accountCleanup": True},
        headers=auth_header("admin-token"),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored is not None
    assert stored.status == ClientStatus.ACTIVE
    assert set(wireguard.peers) == {FAKE_PUBLIC_KEY_2}
    assert policy.apply_calls == 0
    assert calls == []


def test_delete_client_cleanup_mode_rejects_stale_self_auth(client, repository, wireguard, policy, token_verifier, monkeypatch):
    seed_region(repository)
    active = create_active_client(repository, wireguard, uid="user-1")
    token_verifier.users["user-token"] = AuthenticatedUser(uid="user-1", email="user@example.com", auth_time=0)
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(routes, "urlopen", _forbid_urlopen(calls))

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID, "accountCleanup": True},
        headers=auth_header(),
    )

    assert response.status_code == 401
    assert_error_shape(response.json(), "AUTH_REQUIRED")
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored is not None
    assert stored.status == ClientStatus.ACTIVE
    assert policy.apply_calls == 0
    assert calls == []


def test_delete_client_cleanup_mode_rejects_admin_role_self_delete(client, repository, wireguard, policy, monkeypatch):
    seed_region(repository)
    active = create_active_client(repository, wireguard, uid="admin-1")
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(routes, "urlopen", _forbid_urlopen(calls))

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "admin-1", "regionId": REGION_ID, "accountCleanup": True},
        headers=auth_header("admin-token"),
    )

    assert response.status_code == 400
    assert_error_shape(response.json(), "INVALID_REQUEST")
    stored = repository.get_client(owner_uid="admin-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored is not None
    assert stored.status == ClientStatus.ACTIVE
    assert policy.apply_calls == 0
    assert calls == []


def test_delete_client_cleanup_mode_happy_path_suppresses_reconcile_and_poke(client, repository, wireguard, policy, monkeypatch):
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    active = create_active_client(repository, wireguard, uid="user-1")
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(routes, "urlopen", _forbid_urlopen(calls))

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID, "accountCleanup": True},
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "removed"
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored.status == ClientStatus.REMOVED
    assert wireguard.peers == {}
    # A legitimate cleanup-mode self-delete suppresses both fan-outs - the
    # account-delete orchestrator (not this per-client call) owns propagation
    # (review finding 8).
    assert policy.apply_calls == 0
    assert calls == []


# --- 7. No duplicate fleet-poke fan-out --------------------------------------


def test_delete_account_sends_exactly_one_refresh_per_other_enabled_region(client, repository, wireguard, monkeypatch):
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    _seed_other_region(repository, "us-other-2")
    create_active_client(repository, wireguard, uid="user-1")  # local
    remote_a = _seed_remote_client(repository, region_id="us-other-1", client_id="remote-a", public_key="pub-remote-a")
    remote_b = _seed_remote_client(repository, region_id="us-other-1", client_id="remote-b", public_key="pub-remote-b")
    calls: list[tuple[str, str, dict | None]] = []
    monkeypatch.setattr(routes, "urlopen", _record_urlopen(calls))

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 200
    delete_indices = [i for i, call in enumerate(calls) if call[0] == "DELETE"]
    post_indices = [i for i, call in enumerate(calls) if call[0] == "POST"]
    assert len(delete_indices) == 2  # one per remote client, never coalesced
    assert {calls[i][1] for i in delete_indices} == {
        f"https://us-other-1.gocloudlaunch.com/api/clients/{remote_a.client_id}",
        f"https://us-other-1.gocloudlaunch.com/api/clients/{remote_b.client_id}",
    }
    # Exactly one refresh per *other enabled region* - us-other-1 has two
    # clients but gets one refresh, us-other-2 has zero clients but still
    # gets its one refresh, and the local region never appears at all.
    assert sorted(calls[i][1] for i in post_indices) == [
        "https://us-other-1.gocloudlaunch.com/api/sync/refresh",
        "https://us-other-2.gocloudlaunch.com/api/sync/refresh",
    ]
    assert not any(REGION_ID in call[1] for call in calls)
    # Every remote per-client delete happens before the refresh wave (W4-6).
    assert max(delete_indices) < min(post_indices)


def test_ordinary_client_delete_still_pokes_proving_suppression_is_mode_specific(client, repository, wireguard, policy, monkeypatch):
    # Proves the case-7/case-6 suppression is specific to accountCleanup mode,
    # not a general regression: an ordinary per-client delete still fans out.
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    active = create_active_client(repository, wireguard)
    calls: list[tuple[str, str, dict | None]] = []
    monkeypatch.setattr(routes, "urlopen", _record_urlopen(calls))

    response = client.request(
        "DELETE",
        f"/clients/{active.client_id}",
        json={"userId": "user-1", "regionId": REGION_ID},
        headers=auth_header(),
    )

    assert response.status_code == 200
    assert policy.apply_calls == 1
    assert calls == [("POST", "https://us-other-1.gocloudlaunch.com/api/sync/refresh", None)]


# --- 8. Post-fence policy exclusion -------------------------------------------


def test_mark_account_clients_inactive_excludes_account_from_desired_policy(repository, wireguard):
    seed_region(repository)
    deleting = create_active_client(repository, wireguard, uid="user-1")
    survivor = create_active_client(repository, wireguard, uid="user-2")
    slot = repository.account_slots["user-1"]

    repository.mark_account_clients_inactive("user-1")
    desired = desired_policy(repository)

    assert all(row.slot != slot for row in desired.rows)
    deleting_v4 = deleting.assigned_tunnel_ipv4.split("/")[0]
    deleting_v6 = deleting.assigned_tunnel_ipv6.split("/")[0]
    assert all(row.address_v4 != deleting_v4 for row in desired.rows)
    assert all(row.address_v6 != deleting_v6 for row in desired.rows)
    survivor_v4 = survivor.assigned_tunnel_ipv4.split("/")[0]
    assert any(row.address_v4 == survivor_v4 for row in desired.rows)


def test_delete_account_reconcile_after_fence_excludes_account_end_to_end(client, repository, wireguard, policy, settings):
    seed_region(repository)
    deleting = create_active_client(repository, wireguard, uid="user-1")
    survivor = create_active_client(repository, wireguard, uid="user-2")
    # Blocks the hard delete so the deleted account's documents still exist
    # when the reconcile pass below runs - proving exclusion comes from the
    # fence, not from the documents simply being gone.
    repository.hard_delete_account_error = FirebaseWriteFailedError("simulated hard delete failure")

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 500
    assert repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=deleting.client_id) is not None

    # TestClient does not run background tasks for a failed response, so this
    # stands in for the reconcile pass that runs after the response (the next
    # boot/manual sync, or a retried request).
    reconcile_policy(repository=repository, policy=policy, settings=settings)

    applied_v4 = {row.address_v4 for row in policy.rows.values()}
    assert deleting.assigned_tunnel_ipv4.split("/")[0] not in applied_v4
    assert survivor.assigned_tunnel_ipv4.split("/")[0] in applied_v4


# --- Consolidated Wave 4 review additions -------------------------------------


def test_delete_account_fence_write_failure_aborts_before_any_propagation(client, repository, wireguard, policy, monkeypatch):
    # The fence is the ordering pivot: if it cannot be written there is no
    # guarantee that a later pull excludes the account, so nothing past it may
    # run - no refresh wave, no hard delete, no Auth delete. The account stays
    # fully retryable. The local peer is already gone at this point (step 1
    # precedes the fence); that reverse window is the pre-existing one
    # cloudgateway-sync-peers repairs by re-adding the peer from the still
    # ACTIVE document.
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    active = create_active_client(repository, wireguard)
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(routes, "urlopen", _forbid_urlopen(calls))
    repository.mark_account_clients_inactive_error = FirebaseWriteFailedError("simulated fence failure")

    response = client.delete("/account", headers=auth_header())

    assert response.status_code == 500
    assert_error_shape(response.json(), "FIREBASE_WRITE_FAILED")
    assert calls == []
    assert policy.apply_calls == 0
    stored = repository.get_client(owner_uid="user-1", region_id=REGION_ID, client_id=active.client_id)
    assert stored is not None
    assert stored.status == ClientStatus.ACTIVE
    assert repository.get_user("user-1") is not None
    assert repository.get_role("user-1") is not None
    assert repository.deleted_auth_uids == []


def test_delete_account_records_a_failed_region_list_read_instead_of_reporting_a_clean_wave(
    client, repository, wireguard, monkeypatch, caplog
):
    # An unreadable region list means the refresh wave was never sent. That
    # must be visible in the logs rather than showing up as a wave with zero
    # failed regions, which is what a silently swallowed read looked like.
    seed_region(repository)
    _seed_other_region(repository, "us-other-1")
    create_active_client(repository, wireguard)
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(routes, "urlopen", _forbid_urlopen(calls))

    def _unreadable():
        raise RuntimeError("simulated Firestore region read failure")

    monkeypatch.setattr(repository, "list_enabled_regions", _unreadable)

    with caplog.at_level(logging.INFO, logger="src.routes"):
        response = client.delete("/account", headers=auth_header())

    assert response.status_code == 200
    assert calls == []
    poke_failures = [
        record.event_fields
        for record in caplog.records
        if record.message == "policy_poke_failed"
    ]
    assert len(poke_failures) == 1
    assert poke_failures[0]["stage"] == "region_list"
    assert poke_failures[0]["errorType"] == "RuntimeError"
    # The deletion still completes: the fence is already committed, so no pull
    # anywhere can restore the account even though no region was refreshed.
    assert repository.get_user("user-1") is None
    assert repository.deleted_auth_uids == ["user-1"]

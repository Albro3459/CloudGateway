# ACL-B: API Integration Review (Account-Scoped ACL)

Scope: `Backend/API/src/{routes.py,repository.py,firebase.py,sync.py,app.py,errors.py,enums.py,models.py}`
plus tests: `test_account_cleanup.py`, `test_repository.py`, `fakes.py`, `test_account_slots.py`,
`test_routes_clients.py`, `test_routes_admin.py`, `test_sync.py`, `test_routes_users.py`, `test_models.py`, `conftest.py`.

Diff range: `bc7d99a..HEAD`. Excludes `policy.py`/`policy_sync.py` (ACL-A).

## Reviewed

- [x] `Backend/API/src/routes.py`
- [x] `Backend/API/src/repository.py`
- [x] `Backend/API/src/firebase.py`
- [x] `Backend/API/src/sync.py`
- [x] `Backend/API/src/app.py`
- [x] `Backend/API/src/errors.py`
- [x] `Backend/API/src/enums.py`
- [x] `Backend/API/src/models.py`
- [x] `Backend/API/tests/test_account_cleanup.py`
- [x] `Backend/API/tests/test_repository.py`
- [x] `Backend/API/tests/fakes.py`
- [x] `Backend/API/tests/test_account_slots.py`
- [x] `Backend/API/tests/test_routes_clients.py`
- [x] `Backend/API/tests/test_routes_admin.py`
- [x] `Backend/API/tests/test_sync.py`
- [x] `Backend/API/tests/test_routes_users.py`
- [x] `Backend/API/tests/test_models.py`
- [x] `Backend/API/tests/conftest.py`

## Findings

(populated incrementally below)

### [P2] Account-slot recovery path can reissue a deleted account's slot
- **Where:** `Backend/API/src/firebase.py:1089-1126` (`_allocate_account_slot`), `Backend/API/src/repository.py:343-404` (`next_account_slot` recovery branch), `Backend/API/src/firebase.py:381-401` (`hard_delete_account_documents`)
- **What:** `next_account_slot`'s recovery path (taken whenever `Counters/accountSlots.nextSlot` is absent or malformed) derives the next slot as `max(assigned_slots) + 1`, where `assigned_slots` comes from a live scan of the `Users` collection (`_allocate_account_slot` streams `db.collection("Users")`). `hard_delete_account_documents` (called from `DELETE /account`) hard-deletes the `Users/{uid}` doc for a deleted account. Once that doc is gone, the deleted account's slot no longer appears anywhere in Firestore except the (now-corrupt/missing) counter doc itself.
- **Failure:** Account A is provisioned last and holds the fleet's highest slot, e.g. slot 12 (`nextSlot` becomes 13). Account A is later deleted via `DELETE /account`, which hard-deletes `Users/A` (its slot 12 is now unrepresented in any live doc). If `Counters/accountSlots` is later lost or corrupted (manual edit, restore from stale backup, accidental delete — the exact case this recovery path exists for), the next provisioned account recomputes the counter from the remaining `Users` docs, whose max slot is now 11, and hands out slot 12 again — the same slot number account A held. This directly violates the invariant the code repeatedly documents ("allocated once ... and never reused", `repository.py:71-73`, `343-350`), risking policy/nftables confusion if any residual state (audit logs, cached mappings, in-flight sync data) still associates slot 12 with account A.
- **Fix:** Either keep a tombstone of every slot ever issued (e.g. write to a separate `Counters/accountSlots.issuedSlots` set or a `highestIssuedSlot` field that is never decremented, updated on both allocation and account deletion) and have the recovery path take `max(that record, live assigned slots) + 1`, or stop hard-deleting the `Users` doc's `accountSlot` field on account deletion (tombstone the doc / retain a minimal record) so the recovery scan still sees it.
- **Test-fidelity note:** `Backend/API/tests/fakes.py:434-443` (`FakeRepository.hard_delete_account_documents`) never removes the deleted uid from `self.account_slots`, so `_allocate_account_slot`/`list_account_slots` (`fakes.py:649-663`, `738-748`) keep "seeing" a deleted account's slot forever. This diverges from `firebase.py`'s real behavior (where the slot only lives on the `Users/{uid}` doc that gets hard-deleted), which is why no test in `test_account_slots.py` caught this: the fake can't reproduce the scenario even if a test were written for it.

## Clean (no findings)

- `Backend/API/src/enums.py` — new ErrorCode/Event values are consistent with usage elsewhere; no dead or misused variants found.
- `Backend/API/src/errors.py` — `ACCOUNT_SLOT_UNAVAILABLE` correctly mapped to 500; `PolicyApplyFailedError`/`WireGuardApplyFailedError` transient flag plumbed consistently.
- `Backend/API/src/app.py` — policy manager/coordinator wiring and exception handlers look correct; no new authz surface here.
- `Backend/API/src/models.py` — `DeleteClientRequest.account_cleanup` documented and consistent with routes.py enforcement (verified there).
- `Backend/API/src/sync.py` — ACL-side change is a thin, well-commented wire-up of `reconcile_policy` (owned by ACL-A) into `main()`'s exit-code path; no correctness issue in the API-integration slice.
- `Backend/API/src/routes.py` — walked every changed/new endpoint (`POST /clients`, `DELETE /clients/{clientId}`, `DELETE /account`, `POST /users`, `POST /sync/refresh`, `POST /admin/sync`) for account-scoping: self-vs-admin checks (`ensure_delete_allowed`), `account_cleanup` impersonation guard (`_ensure_account_cleanup_allowed` requires `body.user_id == user.uid`), region-id URL-injection guard (`_regional_api_url`/`_REGION_ID_PATTERN`) before building cross-region URLs, and the documented account-deletion ordering (peer removal -> fleet-wide fence -> refresh wave -> hard delete). No cross-account access path found; `DELETE /account` only ever operates on the caller's own `user.uid`, never a body-supplied target.
- `Backend/API/tests/test_account_cleanup.py` — thorough Wave-4 ordering matrix: local/remote/mixed deletion, unreachable regions, partial-failure retries at each ordering step (fence, hard-delete, auth-delete), cleanup-mode impersonation/staleness/admin-self-delete rejection, exactly-once-per-region poke fan-out, and post-fence policy exclusion end to end. No gaps found for the scenarios this file targets.
- `Backend/API/tests/test_repository.py` — solid coverage of tunnel-index wrap/skip/exhaustion, account-slot allocation via `FakeRepository` (once-per-account, lazy allocation, `MIN_ACCOUNT_SLOT`/`MAX_ACCOUNT_SLOT` cross-checked against `policy.MIN_SLOT`/`MAX_SLOT`), and delete/capacity/limit authz paths. No gaps beyond the account-deletion-then-corruption scenario noted above.
- `Backend/API/tests/fakes.py` — `FakeRepository`/`FakeWireGuardManager`/`FakePolicyManager` mirror the real transactional/locking semantics closely (see the account-slot divergence noted in the P2 finding above, the one place fidelity breaks down).
- `Backend/API/tests/test_routes_clients.py` — full create/delete client route coverage: capacity/limit enforcement, transient WireGuard retry, failure-path rollback (peer cleanup + reservation removal), self-vs-admin delete authz, mismatched-doc-fields fail-closed to `CLIENT_NOT_FOUND`, and the inline policy-row write path (missing/invalid slot, lock contention, apply failure, admin-row flag) all skip-safely without failing the create response.
- `Backend/API/tests/test_routes_admin.py` — `/admin/sync` and `/sync/refresh` coverage: auth/admin/region-mismatch gating, non-blocking lock shedding, mesh wire-contract pinning (no public-key leakage), and the new policy-reconcile piggyback (success, apply failure, coordinator-raise) all correctly leave `policyApplied=false` with the two optional fields omitted (not null) on failure.
- `Backend/API/tests/test_sync.py` — `main()`'s new two-stage exit-code contract (`EXIT_OK`/`EXIT_PEER_SYNC_FAILED`/`EXIT_POLICY_FAILED`) is covered for full success, policy-after-peer-success failure, peer-failure-skips-policy, and best-effort status-write failure staying `EXIT_OK`.
- `Backend/API/tests/test_routes_users.py`, `test_models.py`, `conftest.py` — small, additive changes (fence-call-count assertion, `DeleteClientRequest.account_cleanup` model round-trip, `policy` fixture wiring) consistent with the rest of the suite; no gaps.

## Summary

Reviewed all files in the ACL-B chunk (API integration: routes.py, repository.py, firebase.py, sync.py,
app.py, errors.py, enums.py, models.py, plus the associated test suite) against the diff `bc7d99a..HEAD`.

**1 finding, P2:**
- [P2] Account-slot recovery path can reissue a deleted account's slot (`firebase.py:1089-1126`,
  `repository.py:343-404`, `firebase.py:381-401`) — the fail-closed slot-recovery path derives the next
  slot from a live scan of the `Users` collection, which no longer includes a hard-deleted account's slot,
  so a subsequent counter-doc corruption can reissue a deleted account's slot to a new account. Requires
  two conditions (account deletion of the highest-slot account, then counter corruption) but directly
  undermines the "never reused" invariant the code repeatedly documents. The test double (`fakes.py`)
  cannot reproduce the scenario because it never clears its `account_slots` map on hard delete, which is
  likely why no test caught it.

**No P0/P1 findings.** Account-scoping/authz on every changed route (`POST /clients`,
`DELETE /clients/{clientId}`, `DELETE /account`, `POST /users`, `POST /sync/refresh`, `POST /admin/sync`)
held up under review: self-vs-admin checks, the `account_cleanup` self-delete-only guard, and the
region-id regex guard before cross-region URL construction all look sound, with no cross-account access
path found. Transaction boundaries in `firebase.py` correctly place every read before any write (Firestore
requirement) and slot/tunnel-index allocation happens inside the same transaction as the client-doc write.
Monotonic tunnel-address allocation (`next_tunnel_index`) correctly wraps and skips in-use indices with no
off-by-one. Account cleanup ordering (peer removal -> fleet-wide fence -> synchronous refresh wave ->
hard delete) is deliberate, extensively commented, and backed by a strong test matrix covering partial
failure and retry at every step. No logging of tunnel IPs, keys, tokens, or full configs was found; the
poke/refresh helpers explicitly avoid logging bearer tokens or response bodies.

Nothing in the assigned scope was skipped; `policy.py`/`policy_sync.py` were read only for context per
the assignment boundary and are owned by ACL-A.

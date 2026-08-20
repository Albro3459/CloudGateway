# Review Findings: Recommended Solutions

This document turns the eleven findings consolidated in `99-summary.md` into an
implementation plan. Each resolution was checked against the current branch, the detailed
review notes, the affected production code, and existing tests. The goal is the safest
repo-conforming fix, not merely the smallest edit.

## Scope and decisions

| Finding | Severity | Decision |
| --- | --- | --- |
| 1. Account-slot reuse | P1 | Make the counter authoritative, fail closed when it cannot prove history, and make the migration respect it |
| 2. Swift integer trap | P1 | Use `Int(exactly:)` at the shared mesh conversion boundary |
| 3. Apple cross-session data leak | P1 | Clear all account-scoped state on identity/authorization changes and generation-guard async work |
| 4. DNS resolver thread leak | P2 | Use one bounded resolver worker with non-queueing admission control |
| 5. Route error masks peer error | P2 | Capture both failures, preserve the first failure, and always emit partial progress |
| 6. Cross-tab login race | P2 | Validate completion against Firebase's current user and the current manual-attempt token |
| 7. Sync races mesh toggle | P2 | Put a write barrier in front of every Sync All entry point |
| 8. Degenerate CIDR enters `cg_infra` | P2 | Reject unsupported prefixes and require the derived address to remain inside both networks |
| 9. Missing slot-reuse regression test | P2 | Test a valid counter above the live maximum with pending assignments |
| 10. Missing 400-write guard tests | P2 | Test 400/401 at both enforcement points, including the counter write |
| 11. Missing degenerate-CIDR tests | P3 | Cover `/31`, `/32`, `/127`, and `/128` at the policy boundary |

Three principles apply across the fixes:

1. Authorization data fails closed when its history or validity cannot be proven.
2. UI state is not a correctness barrier; durable writes, current identity, and operation
   generations are.
3. Partial convergence is acceptable only when every failure and the progress already made are
   observable and a later idempotent pass repairs the state.

## Finding 1 — hard-deleted accounts can have their slot reissued (P1)

### Root cause

`Users/{uid}.accountSlot` and `Counters/accountSlots.nextSlot` together represent allocation
state. `hard_delete_account_documents()` deletes the user document. A later live `Users` scan
therefore cannot see every slot ever issued.

The defect has two call sites:

- Runtime recovery in `Backend/API/src/firebase.py::_allocate_account_slot` and
  `Backend/API/src/repository.py::next_account_slot` derives a replacement counter from live
  users when `nextSlot` is absent or malformed.
- `releases/access-control-lists/backfill_account_slots.py::compute_plan` always starts new
  assignments above the live maximum, even when a valid stored counter is higher.

The latter is more reachable: it can reuse a deleted slot while the counter is healthy. Once a
slot is reused, a stale host can temporarily authorize addresses from different accounts under
the same nftables mark.

### Optimal solution

Treat `Counters/accountSlots.nextSlot` as the authoritative, monotonically increasing allocation
watermark after ACL slot allocation is activated:

```text
nextSlot > every slot ever issued
```

The complete fix is:

1. In migration `compute_plan`, choose the first new slot from:

   ```text
   max(max_live_slot + 1, counter_before)
   ```

   when `counter_before` is valid. A live gap below the counter is historical allocation, not
   reusable capacity.

2. In the runtime allocator, remove the live-user recovery behavior. Missing, malformed,
   exhausted, or regressed counter state must raise `AccountSlotUnavailableError`; it must not
   guess from `Users` or reset to `MIN_ACCOUNT_SLOT`.

3. Keep the counter read, user/account write, and increment in one Firestore transaction. A retry
   must reread the counter and recompute the candidate.

4. Allow live-scan seeding only in the explicit one-time, pre-activation migration path, when the
   operator can prove that no account slots have previously been issued. After activation,
   missing counter state is an operational repair condition.

5. Update `releases/access-control-lists/README.md`, Firebase schema comments, backup guidance,
   and the release setup notes: the counter is Admin-SDK-only, must never be lowered or deleted,
   and must be restored or deliberately repaired before provisioning resumes.

No new collection, index, or Firestore client rule is required. Retaining deleted `Users`
documents is weaker because it changes hard-delete semantics and may retain PII. An append-only
slot ledger would make automatic recovery possible, but it is unnecessary unless automatic
recovery from a lost counter becomes a product requirement.

### Files

- `Backend/API/src/repository.py`
- `Backend/API/src/firebase.py`
- `Backend/API/tests/test_account_slots.py`
- `releases/access-control-lists/backfill_account_slots.py`
- `releases/access-control-lists/test_backfill_account_slots.py`
- `releases/access-control-lists/README.md`
- `Backend/Firebase/schema.ts` and release/setup documentation, if their invariant text changes

### Validation

- A valid counter above the live maximum is honored by runtime and migration paths.
- Missing, malformed, regressed, and exhausted runtime counters fail without writing a user,
  account slot, or replacement counter.
- Concurrent allocators still produce unique increasing values after Firestore retries.
- Re-running the migration is idempotent.
- A transactional reread that differs from preflight aborts without partial writes.
- Run `./scripts/test.sh api release`.

### Completion condition

No runtime path derives allocation history from live users, and the migration never allocates a
slot below a valid `nextSlot`.

## Finding 2 — `Int(Double)` boundary trap in the mesh mapper (P1)

### Root cause

`CloudGatewayFirestoreMeshMapper.integer(_:)` checks a `Double` against
`Double(Int.min)...Double(Int.max)` before calling `Int(value)`. On 64-bit Apple platforms,
`Double(Int.max)` rounds to `2^63`, so the out-of-range value `2^63` passes the check and the
conversion traps.

### Optimal solution

Replace the hand-written range check with the same exact conversion used by the sibling policy
mapper:

```swift
private static func integer(_ value: Double) -> Int? {
    Int(exactly: value)
}
```

Do not clamp corrupt values. Existing callers should retain their current invalid-value behavior:

- invalid `displayOrder` falls back to `1000`;
- invalid region or peer ports become `nil` or cause incomplete peers to be skipped;
- valid integral values, including `Int.min` for the generic helper, remain representable.

### Files

- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayFirestoreMeshMapper.swift`
- `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayAppCoreTests/CloudGatewayMeshStatusTests.swift`

### Validation

- Test `0x1p63`/`Double(Int.max)` through `displayOrder`, `wireguardPort`, and peer
  `endpointPort`; mapping must return fallback/nil rather than crash.
- Test NaN, both infinities, a fractional value, a normal port, and `Double(Int.min)`.
- Run `./scripts/test.sh apple`.

### Completion condition

Every mesh `Double`-to-`Int` conversion is exact and non-trapping.

## Finding 3 — Server Health state leaks across Apple sessions (P1)

### Root cause

`CloudGatewayServerHealthViewModel` is retained for the app process. Dismissing
`ServerHealthView` on sign-out only changes presentation; it does not clear `syncResults` or the
other published state. Completed sync logs can contain emails, client names and IDs, public keys,
and tunnel IPs. Existing in-flight UID checks do not clear results that completed before sign-out.

### Optimal solution

Make the Server Health view model own its account-session boundary:

1. Register an auth-state listener in the view model, retain the registration, and track the last
   observed UID. A change from A to B, A to nil, or nil to B increments a session generation and
   immediately clears all account-scoped state. Repeated callbacks for the same UID do nothing.

2. Add one reset method that clears at least:

   - `regions`, `meshDocs`, `linkRows`, `warnings`, and `anyPending`;
   - `policyRows`, cached policy documents, and policy-load failure state;
   - `syncResults` and `bannerText`;
   - `dataAvailable`, pending toggle state, and deferred reload state.

3. Capture both UID and session generation in `load()`, `toggleMesh(region:)`, and `syncAll()`.
   Before any result is published or a catch-up load begins, require both values to still match.
   This prevents an old task from repopulating state after reset even if cancellation is delayed.

4. Cancel the auth listener when the view model is destroyed.

5. Keep `ContentView`'s cover dismissal. On an admin-role downgrade for the same UID, also call
   the reset method because the auth listener cannot observe authorization changes.

Clearing only `syncResults`, clearing only on `.signedOut`, or constructing a new view model when
the sheet opens all leave weaker lifecycle gaps.

### Files

- `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayServerHealthViewModel.swift`
- `Frontend/Apple/iOS/CloudGateway/ContentView.swift`
- `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayAppCoreTests/CloudGatewayServerHealthViewModelTests.swift`
- Apple mock service/auth-listener helpers used by those tests

### Validation

- Populate completed sync results as Admin A, emit sign-out, and assert every account-scoped
  field is empty before another view can render.
- Repeat with a direct A-to-B account swap.
- Release a gated A-owned load/sync/toggle after B signs in; it must publish nothing and must not
  launch a B-session catch-up load.
- Re-emitting A while A remains current must not clear the page.
- A same-UID admin-role loss clears data through the UI authorization path.
- Run `./scripts/test.sh apple`.

### Completion condition

No account-scoped Server Health value survives an identity or authorization boundary, and stale
async work cannot restore cleared data.

## Finding 4 — hung DNS resolution leaks API worker threads (P2)

### Root cause

`_resolve_endpoint_addresses()` creates a new single-worker `ThreadPoolExecutor` for every
`socket.getaddrinfo()` call. `future.result(timeout=...)` limits caller wait time, not the running
libc resolver. `shutdown(wait=False)` cannot cancel that call, so every retry can leave another
thread behind.

Python documents that a running future cannot be cancelled and that `shutdown(wait=False)` only
releases resources after pending work finishes. A caller timeout is therefore not a resolver
timeout.

### Optimal repo-compatible solution

Use one process-wide, single-worker resolver executor plus non-queueing admission control:

1. A module-level executor has `max_workers=1` and a recognizable thread name.
2. A module-level gate is acquired non-blockingly before submission.
3. If the gate is held, return the existing unresolved result immediately; do not queue another
   future.
4. Release the gate from the future's completion callback, not when the caller times out. Release
   it immediately if submission itself fails.
5. Preserve the injected resolver path used by unit tests and callers.

This bounds damage to one worker and zero queued lookups per API process while preserving the
current fail-soft drift behavior. A permanently blocked libc call can still occupy that one
worker and delay interpreter shutdown. Eliminating that residual entirely would require a
killable resolver subprocess or a new cancellable DNS dependency; that larger operational change
is not needed to close the unbounded-growth finding.

### Files

- `Backend/API/src/wireguard.py`
- `Backend/API/tests/test_wireguard.py`

### Validation

- Block `socket.getaddrinfo` on a test event and reduce the timeout.
- Repeated calls must return promptly, submit only one resolver call, create at most one named
  worker, and queue no work.
- Release the event and verify a later lookup succeeds and reopens admission.
- Preserve IPv4/IPv6 normalization, trailing-dot hostname, and `OSError` coverage.
- Run `./scripts/test.sh api`.

### Completion condition

Repeated syncs cannot increase DNS resolver threads or queued lookups while a resolver call is
stuck.

## Finding 5 — route reconciliation hides an earlier peer failure (P2)

### Root cause

`sync_peers()` accumulates the first mesh-peer apply error so it can continue converging, but it
calls `_reconcile_mesh_routes()` outside that error path. A route exception exits immediately,
skips `PEER_SYNC_PARTIAL`, and replaces the earlier failure at the caller boundary.

### Optimal solution

Integrate route reconciliation into the same partial-failure model:

1. Initialize an empty route-change list and capture a route error separately.
2. Catch `WireGuardApplyFailedError` around `_reconcile_mesh_routes()`.
3. Preserve the first failure as the primary error. If the route failure is the only failure,
   make it primary.
4. Emit `PEER_SYNC_PARTIAL` exactly once for every failed pass, with the peer counters already
   available and a structured `route_reconciliation_failed` indicator. Log the second failure as
   a separate structured error without peer keys, addresses, or other prohibited metadata.
5. Raise the primary error after logging. Exception chaining may supplement the structured log
   if the top-level logger renders it reliably, but it must not be the only record of the second
   failure.
6. Keep the current idempotent retry model; do not attempt an unreliable multi-command rollback.

The first version may report zero route changes when the route helper throws after partial route
progress because the helper returns only on success. If exact partial route counters are required,
add an internal reconciliation result/error carrying accumulated `RouteChange` values. That is an
observability enhancement, not required for correctness.

### Files

- `Backend/API/src/wireguard.py`
- `Backend/API/tests/test_wireguard.py`
- Event definitions or logging whitelist/config only if the structured field requires them

### Validation

- Combine a mesh-peer apply failure and a later route failure in one pass.
- Assert the peer failure remains primary, the route failure is separately observable, and
  `PEER_SYNC_PARTIAL` occurs once.
- Test a route-only failure: it is primary and still emits the partial event.
- Verify a later healthy pass converges peers and both route families.
- Preserve existing isolated route-add/removal recovery tests.
- Run `./scripts/test.sh api`.

### Completion condition

No failure bypasses the partial-progress event, and two failures in one pass remain independently
diagnosable.

## Finding 6 — cross-tab auth race strands a successful login (P2)

### Root cause

The manual sign-in flow compares its returned UID with shared observer state in `authUid`. An
unrelated cross-tab auth event can overwrite that value while the manual result is still unknown.
When the manual promise resolves, it is incorrectly invalidated even though Firebase's actual
current user is now the returned user. The matching observer event may already have been consumed,
so no later callback performs navigation.

### Optimal solution

Use the Firebase session and a per-attempt token as the completion authority:

1. Centralize the completion check used by password, Google, and Apple sign-in.
2. Give each manual attempt a unique generation/token and invalidate older attempts when a new
   one starts or the component unmounts.
3. After the provider promise resolves, consider the attempt current only when:

   ```text
   component is mounted
   AND attempt token is latest
   AND attempt was not explicitly invalidated
   AND auth.currentUser?.uid == result.user.uid
   ```

4. Keep `authUid` and auth generation for observer bookkeeping and stale observer provisioning,
   but do not use a stale observer snapshot to reject a completed manual sign-in whose Firebase
   current user matches.
5. Retain observer-side invalidation once the manual UID is known, so a genuine later account
   switch or sign-out still stops provisioning/navigation.

Do not fix this by overwriting `authUid`, deleting all UID checks, or waiting for another observer
callback.

### Files

- `Frontend/Web/src/pages/Login.tsx`
- `Frontend/Web/src/pages/__tests__/Login.test.tsx`

### Validation

- Defer Tab A's provider promise, fire Tab B's UID through the observer, then set
  `auth.currentUser` and resolve A as UID A. A must provision and navigate once.
- After A's result is known, switch Firebase to UID B; A must not navigate.
- Cover sign-out during provisioning, same-UID observer repeats, component unmount, and the shared
  path used by password/Google/Apple.
- Manually reproduce the two-tab ordering without requiring a reload.
- Run `./scripts/test.sh web`.

### Completion condition

A successful current Firebase sign-in cannot be rejected by a superseded observer snapshot, and a
real later identity change still cancels it.

## Finding 7 — Sync All can run before mesh-membership writes are durable (P2)

### Root cause

`handleToggleMesh` updates `regions` optimistically before `setRegionMeshEnabled` resolves.
`enabledRegions` therefore reflects UI intent, while the regional API may still read old Firestore
state. `togglingRegionIds` is presentation state and can be cleared by auth lifecycle code while a
write promise remains unresolved, so checking that set alone is not a complete barrier.

### Optimal solution

Put a durable-write barrier in front of every Sync All entry point:

1. Track unresolved `setRegionMeshEnabled` promises in a ref-backed registry, preferably keyed by
   region ID. Register before awaiting and remove in `finally`.
2. Keep `togglingRegionIds` for checkbox state and immediate UI feedback.
3. Disable the visible Sync All button and modal confirmation while the registry or
   `togglingRegionIds` is non-empty. Provide accessible busy/help text.
4. Make `confirmSync` await a snapshot of all pending writes, loop if a new write appears, and
   abort the sync intent if any write failed.
5. After the barrier, recheck mount state, auth generation, JWT ownership, and that the registry
   is empty. Compute target region IDs from the latest post-acknowledgement state only then.
6. Apply the same barrier to the Home-originated `pendingRunSync` path; UI button gating does not
   protect that entry point.
7. Preserve optimistic rollback. A failed write must settle and restore/refresh state before a
   newly confirmed sync can run.

### Files

- `Frontend/Web/src/pages/ServerHealth.tsx`
- `Frontend/Web/src/pages/__tests__/ServerHealth.test.tsx`
- `Frontend/Web/src/components/SyncRegionsConfirmModal.tsx` only if disabled/help state is exposed

### Validation

- One deferred toggle blocks both the button and defensive confirm handler until acknowledgement.
- Two concurrent toggles remain blocked until both settle.
- A failed toggle aborts the pending sync intent and rolls back before another sync can be
  confirmed.
- A same-user observer callback cannot erase the promise barrier.
- An A-to-B auth change while waiting aborts A's sync intent.
- The Home/pending path uses the same barrier.
- Final sync IDs include a newly enabled region and exclude a newly disabled one.
- Run `./scripts/test.sh web`.

### Completion condition

No Sync All path calls a regional API while any mesh-membership write from the current session is
unresolved.

## Finding 8 — a degenerate region CIDR can promote an unrelated client to `cg_infra` (P2)

### Root cause

`policy_sync.py::_infra_address` computes `network.network_address + 1` and checks only the fleet
aggregate. For `10.0.5.5/32`, that produces `10.0.5.6`: outside the region network but potentially
inside the aggregate and assigned to a real client. `cg_infra` then bypasses the normal account
slot boundary for that address.

### Optimal solution

Make policy derivation independently enforce the region-network contract even though normal
registration already validates it:

```python
expected_prefix = 24 if version == 4 else 64
if network.prefixlen != expected_prefix:
    return None

address = network.network_address + 1
if address not in network or address not in aggregate:
    return None
```

This deliberately rejects IPv4 `/31` and `/32` and IPv6 `/127` and `/128`. Checking only
`address in network` closes `/32` but would still accept unsupported point-to-point prefixes.
Policy generation is an authorization boundary and should fail closed for any Firestore document
that bypassed or predates registration validation.

### Files

- `Backend/API/src/policy_sync.py`
- `Backend/API/tests/test_policy_sync.py`

### Validation

- Unsupported prefixes produce no `infra_v4`/`infra_v6` row.
- The specific addresses immediately above `/32` and `/128` are never emitted.
- Valid `/24` and `/64` regions still emit network-address-plus-one.
- Preserve malformed, wrong-family, out-of-aggregate, and duplicate-address coverage.
- Run `./scripts/test.sh api`.

### Completion condition

Every address placed in `cg_infra` comes from a supported region network and lies inside both that
network and the fleet aggregate.

## Finding 9 — migration lacks the valid-counter-above-live-max regression (P2)

### Root cause

The existing test named for counter advancement has no unassigned user. It never asks
`compute_plan` to choose a new candidate while `counter_before` is above the highest live slot,
which is the ordering that exposes Finding 1.

### Optimal solution

Add a focused regression before broadening the matrix:

```text
provisioned users: uid-a, uid-b
live slots:        uid-a -> 1
counter_before:    10

expected assignment: uid-b -> 10
expected counter:    11
```

Then cover multiple missing users, a deleted-slot gap, `counter == max_live + 1`, a regressed
counter, initial pre-activation seeding, malformed state, exhaustion, idempotent rerun, Firestore
retry, and preflight/transaction mismatch.

The regressed-counter expectation must match Finding 1's decision: after activation, inconsistency
blocks instead of silently advancing from incomplete live history.

### Files

- `releases/access-control-lists/test_backfill_account_slots.py`

### Validation

- The focused regression fails against the old candidate calculation and passes only when the
  valid counter raises the allocation floor.
- Run `./scripts/test.sh release`.

### Completion condition

The exact ordering that caused migration slot reuse is permanently represented in tests.

## Finding 10 — migration's 400-write safety guard is untested (P2)

### Root cause

The migration enforces a conservative 400-write limit in both `main()` and
`_apply_within_transaction()`, but no test pins the boundary or proves refusal occurs before any
write. The counter update is itself one write.

### Optimal solution

Use one shared write-count calculation in production code, then test both enforcement points with
this matrix:

| Assignment writes | Counter write | Total | Expected |
| ---: | ---: | ---: | --- |
| 399 | 1 | 400 | Allowed |
| 400 | 0 | 400 | Allowed |
| 400 | 1 | 401 | Refused |
| 401 | 0 | 401 | Refused |

For `_apply_within_transaction`, assert 401 raises `MigrationAbortedError` and queues zero writes.
For `main()`, assert 401 exits unsuccessfully, never calls `_run_apply`, and performs no Firestore
write. Keep the check before the first transaction write and preserve all reads-before-writes
ordering.

The 400 limit remains a deliberate safety margin below Firestore's documented 500-write maximum;
the solution is not to raise it.

### Files

- `releases/access-control-lists/backfill_account_slots.py` if write counting is deduplicated
- `releases/access-control-lists/test_backfill_account_slots.py`

### Validation

- Exercise exactly 400 and exactly 401 at CLI/preflight and transactional boundaries.
- Prove rejection is atomic and produces zero queued writes.
- Run `./scripts/test.sh release`.

### Completion condition

Any off-by-one change, especially omission of the counter write, fails the test suite.

## Finding 11 — no policy tests for degenerate region networks (P3)

### Root cause

Existing policy tests cover malformed and out-of-aggregate values using normal `/24` and `/64`
regions. They do not pin behavior for syntactically valid but unsupported small networks.

### Optimal solution

Add policy-level, parameterized defense-in-depth tests for:

- IPv4 `/31` and `/32`;
- IPv6 `/127` and `/128`;
- a `/32`/`/128` whose computed plus-one address is still inside the fleet aggregate;
- valid `/24` and `/64` controls.

Assert that every unsupported case yields empty infra tuples and never emits the neighboring
address. Keep registration validation tests as a separate layer; `desired_policy()` must remain
safe when Firestore contains a document that bypassed registration.

### Files

- `Backend/API/tests/test_policy_sync.py`

### Validation

- The new `/32` case fails against the old `_infra_address` implementation.
- The `/31` and `/127` cases prove the policy layer enforces supported prefix widths, not merely
  address containment.
- Run `./scripts/test.sh api`.

### Completion condition

Tests pin the full malformed/unsupported CIDR boundary that protects `cg_infra`.

## Separate required pre-deploy gate — real-host nftables verification

This is not a twelfth source-code finding. Static review and the official nftables manual support
the intended semantics: lower priority numbers run first, an `accept` can continue into later base
chains, and a `drop` terminates ruleset evaluation. Static evidence cannot prove the exact target
kernel, nftables, and iptables compatibility combination.

Before deploying ACL to a serving region:

1. Use a disposable or newly built canary host with no customer traffic.
2. Record kernel, nftables, iptables, and ip6tables versions locally. Inspect `cg_forward`, the
   legacy FORWARD chains, and the `cg_pairs4`/`cg_pairs6` object types. Do not copy full rulesets,
   client addresses, public-key inventories, or WireGuard configuration into tickets.
3. Run syntax-only validation against `/etc/cloudgateway/cloudgateway.nft`:

   ```sh
   sudo nft -c -f /etc/cloudgateway/cloudgateway.nft
   ```

4. With synthetic, non-production peers, verify both families:

   - different account slots are denied;
   - equal account slots are allowed;
   - an explicit legacy FORWARD accept cannot override the cross-account nft drop;
   - the concatenated destination/mark lookup matches as rendered.

5. Use temporary counters on the isolated canary rules only. Do not enable packet tracing, packet
   logging, or DNS/traffic metadata logging.
6. Remove only the named temporary test objects. Never use `nft flush ruleset`, `iptables -F`, or
   `ip6tables -F` as rollback.
7. Block rollout if syntax fails, cross-account traffic succeeds, same-account traffic fails, or
   IPv4 and IPv6 differ.

The durable evidence should record only versions, pass/fail observations, counter deltas, and the
exact tested build—not client identifiers, keys, addresses, configs, tokens, or packet metadata.

## Recommended implementation order

1. Run the nftables canary verification before any live ACL rollout.
2. Fix Findings 1, 9, and 10 together; they share the allocator/migration invariant.
3. Fix Apple P1 Findings 2 and 3.
4. Fix API P2 Findings 4 and 5.
5. Fix Web P2 Findings 6 and 7.
6. Fix Findings 8 and 11 together; the same policy edit and matrix close both.
7. Run `./scripts/test.sh api release web apple`, then run the full test entry point if the
   targeted suite is clean.

## Primary platform references

- [Python `concurrent.futures`](https://docs.python.org/3/library/concurrent.futures.html) —
  running futures, timeout, cancellation, and executor shutdown semantics.
- [Swift `BinaryInteger`](https://developer.apple.com/documentation/swift/binaryinteger) — exact
  conversion behavior used by `Int(exactly:)`.
- [Firestore transactions](https://firebase.google.com/docs/firestore/manage-data/transactions) —
  atomicity, retries, reads-before-writes, request size, and transaction timing constraints.
- [Firestore transaction API limit](https://firebase.google.com/docs/reference/node/firebase.firestore.Firestore#runtransaction)
  — 500 maximum writes; this migration intentionally keeps a 400-write safety margin.
- [nftables manual](https://netfilter.org/projects/nftables/manpage.html) — base-chain priority and
  terminal verdict semantics.


# Shared Subnet Mesh: Post-Review Fixes

Findings from a full static review of the `shared-subnet` branch (mesh + iOS Server Health), and the staged plan to fix them. Review was read-only: no builds, no test runs, no live Firestore or OCI inspection. Every finding below was traced through the actual code path unless marked otherwise.

Nothing here changes the mesh design. The reconciliation core, the Terraform/preflight subnet work, and the Firestore rules came through the review clean. All four real bugs are client-side async state coordination, and three of them are races that the surface's own design doc claims to have eliminated.

## Findings

Severity is about blast radius, not effort. Confidence is CONFIRMED when the code path was traced end to end.

### 1. iOS: a stale `load()` silently clobbers fresher state

`Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayServerHealthViewModel.swift:64-80`. CONFIRMED, high.

`load()` has no generation counter. Its only guard is a snapshot of `togglingRegionIds.isEmpty` taken when its own fetch resolves, so two loads can complete out of order with a toggle between them:

1. Pull-to-refresh starts load A; its fetch is slow and reads pre-toggle state.
2. The user toggles a region. `toggleMesh` writes, succeeds, clears `togglingRegionIds`, and issues its own load B (`:121-123`).
3. B resolves and applies the correct post-toggle state.
4. A resolves last. `togglingRegionIds` is empty again, so A's guard passes and it applies stale pre-toggle data over B.

Reachable through ordinary gestures: `canToggleMesh` (`:42`) does not include `isLoading`, and `ServerHealthView` only renders a spinner without disabling the toggles, so "refresh, then toggle" is enough. The Firestore write itself succeeded, so the damage is display-only — but the toggle visibly flips back, which invites the operator to toggle again and turn mesh membership genuinely off.

`TODO/ios-server-health.md:101` claims "a single gated refresh path removes the race instead of reconciling it". That rationale is wrong: the gate covers toggle-during-load, not load-versus-load.

### 2. Web: an optimistic mesh-toggle override can never retire

`Frontend/Web/src/pages/ServerHealth.tsx:175` versus `:198`. CONFIRMED, high.

The success path returns at `:175` before reaching the `clearOverride` block at `:177-187`. The catch path at `:198-207` clears unconditionally. So when a toggle's confirming read is superseded by any later load, the override is orphaned. Clicking Sync All Regions right after a toggle does exactly this: `runSync` calls `loadServerHealthData()` (`:231`) on the shared generation counter.

Nothing else retires an override except a matching confirming read, a write failure, or an auth-generation reset, so the region's `meshEnabled` stays pinned client-side for the rest of the session and `hasAnyMeshPending`/link rows derive from the stale overlay. The comment at `:199-202` names this exact failure — the defense was applied to one path and not the other. The immediate render is correct; it goes wrong once another admin or tab changes the value.

### 3. Web: `Login.tsx` account-switch invalidation compares against the wrong uid

`Frontend/Web/src/pages/Login.tsx:289`. CONFIRMED logic, narrow trigger.

The branch compares the observer's new uid against `manualStartUidRef` — the uid signed in *before* the attempt began (`:149`). For any legitimate account switch those always differ, so a successful sign-in invalidates itself. `isCurrentManualAttempt` then fails, `navigateProvisionedUser` returns early at every `isCurrent()` guard, `signingIn` resets in `finally`, and the user is left on the login page with no error shown.

`:184-186` performs the same guard correctly against `authUidRef.current`. Line 289 fires first and gets it backwards. The trigger needs an existing session while on `/login` plus the observer firing before the sign-in promise resolves; the signed-out path is safe because `manualStartUidRef` is null.

### 4. API: one malformed client doc wedges the whole region, mesh included

`Backend/API/src/sync.py:39-42`, `Backend/API/src/wireguard.py:363-368`, `Backend/API/src/firebase.py:230`. CONFIRMED, high.

`desired_peers` passes Firestore client data through unvalidated, and `sync_peers` raises on the first bad record before mesh reconciliation and route cleanup run. The mesh path was deliberately hardened against this — `wireguard.py:369-371` says "A rejected candidate is dropped, not fatal here" — but the client path was not. `list_active_clients` guards a missing public key but not empty or corrupt tunnel IPs, so such a doc passes the filter and then raises.

One corrupt `Instances/*` doc therefore means that region can never join or leave the mesh, routes never reconcile, and Server Health shows a permanent failure card. This PR's own cutover procedure has operators hand-deleting client docs (`TODO/shared-subnet-mesh.md:84`), which raises the odds of a malformed leftover.

### 5. iOS: uid-mismatch early return leaks the pending reload

`CloudGatewayServerHealthViewModel.swift:100-123`. CONFIRMED, low.

Both uid-mismatch guards `return` before the `reloadPendingAfterToggle` bookkeeping at `:117`. If a `load()` dropped its results while the toggle was in flight and this toggle is the last one to clear, the pending catch-up reload is never issued and the flag stays true. Muted because a uid change dismisses the cover, but the flag leaks and the reload is silently lost.

### 6. iOS: unreachable branch in `syncAll`

`CloudGatewayServerHealthViewModel.swift:156-158`. CONFIRMED, nit.

`syncAll` requires `togglingRegionIds.isEmpty` to start (`:127`) and `toggleMesh` refuses while `isSyncing` (`:89`), with `isSyncing` held for the whole function via `defer`. The `reloadPendingAfterToggle = true` branch cannot execute. The repo's dead-code scans are symbol-level, so they will not catch a dead branch.

### 7. API: cross-module import of an underscore-private symbol

`Backend/API/src/register.py:14` imports `_validate_port` from `wireguard.py`. Style, nit.

### 8. API: `appliedAt` uses the host clock, `updatedAt` uses the server timestamp

`Backend/API/src/firebase.py:write_mesh_status`. Cosmetic, decided.

Per-peer `appliedAt` comes from `utc_now()` on the host; the doc's `updatedAt` uses `_server_timestamp()`. Staleness derives from `updatedAt`, so the 24h logic is drift-immune — only the per-peer "last applied" label a clock-skewed host renders is affected. Resolved in favour of a server timestamp; see Decisions.

### 9. Web: `isReasonStillPresent` default branch reads inverted

`Frontend/Web/src/helpers/meshHelper.ts:258-259`. PLAUSIBLE, low.

For an unrecognized `reasonCode`, "reason still present" is defined as "the target now has complete valid data that does not match the recorded entry", which reads backwards. The reason-code enum is closed and every known code has its own case, so this should not execute against a compliant backend.

### 10. Docs: stale claims

* `TODO/shared-subnet-mesh.md:121` states the final validation gate passed for API, web, infrastructure, and Firebase. It omits Apple, and the iOS work landed after that claim in the last four commits. `TODO/ios-server-health.md:123` requires `./scripts/test.sh apple`. As written the checklist overstates coverage for the code that landed last.
* `TODO/ios-server-health.md:5` and `:142` still reference a "Server Health is web-only" line that has already been removed from `shared-subnet-mesh.md`.

## Decisions

* **Degraded client records are isolated, and their existing peer is preserved.** One malformed Firestore document must not block mesh and route convergence, and must not disconnect a user. Skip the record, keep only its already-live peer, report the degraded record without sensitive data, and continue reconciling. Never build a new peer from invalid data. Where revocation or disabled state can still be validated safely, honor it — a client that is both malformed and revoked still gets its peer removed.
* **iOS gets a load generation counter.** This is the direct fix for stale results overwriting newer state. `isLoading` gating changes the UX and still does not solve load-versus-load ordering. The "no revision-stamped overrides or load generations" decision in `TODO/ios-server-health.md:28` and `:101` is amended: the discovered race invalidates the assumption it rested on.
* **The `Login.tsx` correctness fix and the ref consolidation are separate waves.** The inverted comparison is fixed with regression coverage first; collapsing the eight refs into one attempt-state object follows as a lower-priority wave, isolated for easier review and rollback.
* **`appliedAt` becomes a Firestore server timestamp.** `write_mesh_status` performs one full-document write after reconciliation, and `updatedAt` in that same write already uses server time. `appliedAt` only drives the operator-facing "recorded" label — it does not feed staleness or reconciliation — so server time costs nothing and removes host-clock skew, giving every timestamp in the snapshot one consistent source. Implementation is `applied_at = _server_timestamp()`, still assigned to every peer entry, with `updatedAt` unchanged.

  Verified against the installed SDK rather than assumed, because two things had to hold. `_helpers.extract_fields` walks nested dicts depth-first, so sentinels inside `peers.{regionId}` are extracted as transforms instead of being written as literals. And `render_field_path` backtick-escapes non-identifier segments, so a hyphenated region ID yields ``peers.`us-chicago-1`.appliedAt`` rather than a malformed three-segment path. A test extraction produced both the nested and top-level transforms in one write, with the sentinel correctly stripped from the document body. Firestore applies all request-time transforms in a single write at one timestamp, so every peer in a snapshot shares an instant with `updatedAt`. Peer entries always carry at least `status`, so stripping the sentinel never leaves an empty map.

* **Validation runs per surface after each wave, then the full suite at the end.** Fast attribution when a wave breaks something, plus a real integration gate. This also closes the recorded-coverage gap for the Apple target.

## Waves

Waves 1-3 touch disjoint surfaces and run in parallel. Everything after is sequential because of file overlap.

### Wave 1 — API client isolation (finding 4)

Subagent: one, scoped to `Backend/API`.

* Validate each client record in `desired_peers` (or a helper it calls) instead of letting `sync_peers` raise on the first bad one. A record with an invalid public key, tunnel IPv4, or tunnel IPv6 is excluded from the desired set.
* Add a protected-key set threaded into `sync_peers` so the removal sweep skips a degraded client's already-live peer instead of deleting it as unknown. Protection requires a syntactically valid public key to match the live peer against; if the key itself is invalid it cannot correspond to a real WireGuard peer, so no protection is possible or needed.
* A degraded record that is also revoked or no longer active must still have its peer removed — protection applies only to records whose status would otherwise have kept them in the desired set.
* Report degraded records in the audit log and in a response counter. Log region-scoped identifiers only: never the client public key, email, client name, or tunnel IP.
* Mesh reconciliation and route cleanup must complete regardless of how many client records are degraded.
* Tests: a malformed tunnel IP does not prevent mesh convergence; a degraded client's live peer survives the sweep; a degraded *and* revoked client's peer is still removed; no sensitive field reaches the log.

Validation: `./scripts/test.sh api`

### Wave 2 — Web correctness (findings 2, 3)

Subagent: one, scoped to `Frontend/Web/src/pages`.

* `ServerHealth.tsx`: make the success path symmetric with the catch path so a superseded confirming read still retires its own override. Preserve the existing revision check — only the override whose revision matches is retired, so a newer toggle's override is never dropped by an older read.
* `Login.tsx`: fix the `:289` comparison so it does not invalidate a legitimate account switch. Do not touch the eight-ref structure in this wave.
* Tests: toggle succeeds, then a later load supersedes the confirming read, and the override still retires; account switch from `/login` with the observer firing before the promise resolves still navigates.

Validation: `./scripts/test.sh web`

### Wave 3 — iOS correctness (findings 1, 5, 6)

Subagent: one, scoped to `Frontend/Apple`.

* Add a monotonic load generation to `CloudGatewayServerHealthViewModel`. A resolving fetch applies only if it is still the newest; keep the existing `togglingRegionIds` and uid guards alongside it.
* Route both uid-mismatch early returns through the `reloadPendingAfterToggle` bookkeeping so the pending reload is not lost.
* Remove the unreachable `reloadPendingAfterToggle` branch in `syncAll`, or restructure so it is genuinely reachable — do not leave a dead branch.
* Tests: load A starts, toggle completes and issues load B, B resolves first, A resolves last and does not clobber; the pending reload survives a uid mismatch.

Validation: `./scripts/test.sh apple`

### Wave 4 — Lower-severity cleanups (findings 7, 8, 9)

Sequential after waves 1-3; wave 1 and this wave both touch `wireguard.py`, and this wave touches `meshHelper.ts`.

Subagent: one, cross-surface but small.

* Promote `_validate_port` to a public name in `wireguard.py` and update `register.py`, or expose a thin public wrapper.
* Replace the host-clock `applied_at = utc_now()` in `write_mesh_status` with `applied_at = _server_timestamp()`, keeping it assigned to every peer entry and leaving `updatedAt` as is. No call-site or schema change: `FirebaseMeshPeerEntry.appliedAt` is already `FirestoreTimestamp`, and both clients already decode it as a timestamp.
* Confirm the round trip once against the emulator or a real write — the extraction behaviour is verified, but the resolved value should be seen landing on a nested peer entry at least once, since a silently-literal sentinel would surface as an unreadable `appliedAt` on both clients rather than as an error.
* Correct the `isReasonStillPresent` default branch in `meshHelper.ts` so an unknown reason code means "assume the reason persists", and mirror the same change in the Swift port so the two implementations stay in step.

Validation: `./scripts/test.sh api web apple`

### Wave 5 — Login ref consolidation (lower priority)

Sequential after wave 2, same file.

Subagent: one, scoped to `Frontend/Web/src/pages/Login.tsx`.

Collapse `manualAttemptRef`, `manualUserUidRef`, `manualStartGenerationRef`, `manualStartUidRef`, `manualInvalidatedRef`, `authGenerationRef`, and `authUidRef` into a single attempt-state object with the invariants stated in one place. `mountedRef` stays as is. Behavior must not change: the wave 2 regression tests plus the existing `Login.test.tsx` cases are the contract. This is auth-critical code — if the consolidation cannot be made obviously equivalent, stop and leave the targeted fix standing.

Validation: `./scripts/test.sh web`

### Wave 6 — Docs (finding 10, plus the amended decision)

Sequential, last, so it can record what actually happened.

* `TODO/ios-server-health.md`: amend the "no load generations" decision at `:28` and `:101` to record the race and the counter that replaced it. Remove the stale "web-only" references at `:5` and `:142`.
* `TODO/shared-subnet-mesh.md`: correct the validation-gate claim at `:121` to state which targets actually ran and when, including Apple.
* `docs/api-contract.md`: document the degraded-client counter added in wave 1, and state the `appliedAt` semantics precisely — it is when Firestore recorded the host's applied-state snapshot, not the instant WireGuard changed. That is slightly later than the actual application, and deliberately so: a trustworthy source beats a precise one read off an untrusted host clock. Note that it shares its instant with `updatedAt` in the same write.
* Update this document's checklist.

Validation: manual review; docs-only per `AGENTS.md`.

### Final gate

`./scripts/test.sh` across every target.

## Checklist

* [x] Wave 1 — API client isolation, protected-peer sweep, degraded-record reporting, tests
* [x] Wave 2 — `ServerHealth.tsx` override retirement, `Login.tsx` uid comparison, tests
* [x] Wave 3 — iOS load generation, pending-reload leak, dead branch, tests
* [x] Wave 4 — `validate_port` visibility, `appliedAt` server timestamp, `isReasonStillPresent` in both implementations
* [x] Wave 5 — `Login.tsx` ref consolidation
* [x] Wave 6 — doc corrections and amended decisions
* [x] Final `./scripts/test.sh` gate

## Outcomes

Recorded where implementation diverged from the plan, so a later pass does not re-derive it.

* **Finding 3 resolved by deletion, not correction.** Pointing `Login.tsx:289` at `authUidRef.current` makes the condition provably always false: the observer assigns `authUidRef.current = uid` in the same synchronous callback immediately above. That trades a wrong branch for a dead one, which finding 6 rejects elsewhere in this document. The window it guarded — an observer fire before the manual attempt's promise resolves, when `manualUserUid` is still unset — has no meaningful uid comparison available, because a competing switch and this attempt's own completion are indistinguishable at that point. `handleLogin` already catches it once the promise resolves, comparing `authUid` against `result.user.uid`. The branch and the then-write-only `manualStartUidRef` were removed, leaving the reachable branch. Wave 5 therefore consolidated seven refs, not eight.
* **Wave 1's key validation was stricter than the existing tests.** `desired_peers` now runs `is_valid_wireguard_key` on every active client, and much of the suite used human-readable placeholder keys (`"active-public-key"`, `"fake-public-existing"`) that are not valid base64. Those clients were silently reclassified as degraded, breaking 7 passing tests; the fixtures were moved to the repo's valid-format fakes. No live `Instances/*` document carries a key that fails this predicate: every client in the four August backups passes it (10, 9, 10, and 9 clients, zero failures). Had one failed, it would be dropped from the desired set but not disconnected. The protection sweep is not what saves it: `sync.py:69-70` gates `protected_keys` on `valid_key`, so an invalid-key record is left unprotected. It survives because a key that fails the predicate cannot match anything on the interface in the first place — every key in `wg show` passed `_validate_key` at `add_peer` time — so the removal sweep has nothing to tear down. Protection covers the other degraded case, a valid key with a malformed tunnel IP. The failure mode is therefore display-level either way.
* **`appliedAt` round trip was exercised, not just reasoned about.** Ran against the offline `demo-cloudgateway` Firestore emulator with a throwaway harness: `peers.us-chicago-1.appliedAt` and `updatedAt` both resolved to identical real timestamps in one write, confirming the sentinel is extracted as a transform at the nested hyphenated path rather than stored as a literal.
* **`_validate_port` became `validate_port`,** a plain rename rather than a wrapper, matching the module's existing split between raising `validate_*` helpers and boolean `is_valid_*` predicates.

## Not changing

The review confirmed these are correct; they are recorded so a later pass does not relitigate them.

* Mesh peer/route reconciliation, the client-versus-mesh peer classification via `list_regions`, and the runtime overlap defense.
* Subnet registry validation, exact registry-to-tfvars matching, aggregate containment, and the Terraform DNS/interface canonicalization fix for both address families.
* `wg0.conf` staying interface-only, and the workspace-isolated destroy blast radius.
* `firestore.rules`: the field-limited `meshEnabled` update and the client-write denial on `Mesh`.
* The cross-surface response contract, including the deliberate required-on-server, optional-on-client asymmetry for `meshStatusWritten`.
* The Swift ports of `meshValidation.ts` and `meshHelper.ts`, traced function by function against the TypeScript with no divergence beyond finding 9.
* No secrets in the diff and no sync-log leakage into logs on either client.

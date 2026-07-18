# Apple Shared App Core Review Fixes Plan

Follow-up fixes for the `shared-apple-refactor` PR after the full review of the
extraction and the `70cdaa4` "WIP Final review updates" hardening pass.

## Context

The refactor that moved iOS non-UI behavior into `CloudGatewayAppCore` (and split
Firebase Auth into `CloudGatewayFirebaseAdapter`) is behavior-preserving and has
no blocking or major defects. The review surfaced a small set of test gaps and
minor hardening items. This plan implements those items.

The `70cdaa4` commit is accepted as-is. Do **not** reword, squash, rebase, or
otherwise rewrite that commit or any existing history. All work here lands as new
commits on top of the branch.

## Scope

* `Frontend/Apple/CloudGatewayFirebaseAdapter/` (auth adapter + tests);
* `Frontend/Apple/CloudGatewayKit/Sources/CloudGatewayAppCore/CloudGatewayViewModel.swift`;
* `Frontend/Apple/CloudGatewayKit/Tests/CloudGatewayAppCoreTests/`;
* `scripts/test.sh`.

No backend, Firebase schema, API contract, Cloudflare, WireGuard, or VPN behavior
change is intended. No production behavior change beyond the narrow fencing fix in
item 3 and the guard-quality fix in item 5.

## Do Not

* Do not rewrite, reword, squash, or rebase `70cdaa4` or any prior commit.
* Do not change public API shapes, endpoint paths, payloads, or copy.
* Do not touch the packet-tunnel extension (`Frontend/Apple/iOS/CloudGatewayTunnel/`);
  it must stay byte-identical to the refactor baseline.
* Do not stage, unstage, reset, stash, or otherwise modify the git index except
  for the commits this plan explicitly calls for.
* Do not push.

## Fixes

Each fix keeps the existing `70cdaa4` behavior; it adds coverage or closes a
narrow remaining gap in the same style as the tests that commit already added
(gate-based interleaving with `AsyncTestGate`, `emitAuthState`, `waitUntil`).

### Fix 1 - Adapter-level `expectedUserId` guard tests

The Firebase auth adapter rejects a mid-flight user swap in
`CloudGatewayFirebaseAuthAdapter.linkGoogle` and `reauthenticateWithGoogle`
(`CloudGatewayFirebaseAuthAdapter.swift:102,150`) by throwing `CancellationError`
when `auth.currentUser?.uid != expectedUserId`. The adapter test target currently
covers only error-code mapping, so the guard itself is unproven at the adapter
boundary (the facade tests exercise a re-implemented guard in a fake).

* Add tests in `CloudGatewayFirebaseAdapter/Tests/.../` that drive the adapter's
  guard directly, without contacting Firebase, by injecting a seam over
  `currentUser`/`uid`. If the adapter cannot be exercised without a live
  `FirebaseAuth.Auth`, introduce the smallest possible internal seam (for example
  an internal current-user provider) rather than reaching into Firebase; keep the
  public API unchanged.
* Assert: matching `expectedUserId` proceeds; a swapped `uid` throws
  `CancellationError` and performs no link/reauth credential call.

If a live-`Auth` dependency makes a true unit test infeasible, record that
explicitly in the adapter test file and in this plan instead of asserting a
weaker behavior.

### Fix 2 - Missing mid-operation user-swap race tests

`70cdaa4` fenced `createClient`, `deleteClient`, and `grantAccess`, and added the
`ensureNoReplacementUser` nil-user branch used by
`removeInstalledConfigsAfterAccountDelete`, but only `syncRegion`, `deleteAccount`,
Apple link recovery, and pull-to-refresh got race tests.

Add `CloudGatewayViewModelTests` cases, following the existing gate pattern:

* `createClient`: swap the signed-in user while the create call is gated; assert
  the replacement user's state is intact, no success text from the stale flow, and
  the stale create does not publish the previous user's client.
* `deleteClient`: swap the user while the delete call (or the preceding
  `ensureDestructiveOperationAllowed`) is gated; assert no cross-user profile
  removal and the captured option is not applied to the new session.
* `grantAccess`: swap the user while the grant call is gated; assert no stale
  success text lands under the new session.
* `ensureNoReplacementUser` nil-user branch: after server-side account deletion
  with `currentUser == nil`, assert local profile cleanup still proceeds (the
  branch must allow a nil current user), and that a *replacement* user instead
  aborts cleanup with `CancellationError`.

Add the minimal gates/counters to `MockGatewayService` as needed, matching the
existing `reauthenticateWithPasswordGate` / `syncRegionGate` style.

### Fix 3 - Fence the `pullFreshAndInstall` install tail

`CloudGatewayViewModel.pullFreshAndInstall` (`CloudGatewayViewModel.swift:1029`)
fences the remote reload, but the trailing `selectedClientId` write and
`configManager.install(freshOption)` run unfenced, so a user swap during the
install applies the stale flow's local result under the new session.

* Capture the generation at entry and gate the tail with the existing
  `ensureCurrentSession(user, generation:)` / `performForCurrentUser` helpers,
  matching how `deleteClient` fences its config mutation.
* This is device-local state only, so keep the change minimal and preserve the
  current "pull fresh, then install" ordering and the not-ready error copy.
* Add a race test in the same style asserting the stale install cannot select or
  install under the replacement user.

### Fix 4 - Replace the `reloadAuthState` busy-poll

`reloadAuthState` (`CloudGatewayViewModel.swift:1247`) spins on `isWorking` with a
fixed 10 ms `ContinuousClock().sleep` on the main actor. It is bounded in practice
because `run()` clears `isWorking` in a `defer`, but a wedged operation means
sustained polling.

* Replace the fixed-interval poll with an await on completion of the in-flight
  work rather than a sleep loop, or at minimum bound the loop with a sensible cap
  and exit. Preserve the exact current semantics: reload runs once, only when the
  generation and current user still match and `loadedRemoteUserId != user.uid`.
* Keep injected-clock testability. Extend or add a test that proves a single
  refresh still happens after the in-flight operation completes, and that no
  refresh happens when `loadedRemoteUserId` already matches.

If a clean non-polling rewrite risks changing ordering, prefer the bounded-loop
option and document the bound; do not alter the once-only refresh guarantee.

### Fix 5 - Harden the signed-build keychain prerequisite

`check_apple_signing_prerequisites` in `scripts/test.sh:113` uses
`security show-keychain-info`, which does not reliably fail on a locked keychain,
so the signed path can pass the guard and then stall on a keychain prompt during
the build.

* Use a check that actually reflects lock state (for example verifying the
  keychain is unlocked, or that a codesigning identity is usable) so a locked
  keychain fails fast with the existing guidance message.
* Keep the unsigned default path unchanged. Validate by shell parse
  (`bash -n scripts/test.sh`) and, where possible, a dry check of the guard
  function; do not run the signed build (keychain is intentionally locked).

## Review Loops

Run these only after every fix above is implemented and `./scripts/test.sh apple`
passes on the working tree.

### Loop A - Sonnet 5 medium reviewer

1. Launch a Sonnet 5 subagent at medium reasoning to review only the changes in
   this plan's scope (the fix commits, not the whole PR).
2. Triage findings: fix every real issue; for anything declined, record a one-line
   reason.
3. Re-run `./scripts/test.sh apple` until green.
4. Repeat the review/fix/test cycle until the reviewer returns no real issues and
   you are satisfied. Then stop Loop A.

### Loop B - Opus 4.8 high review of the entire PR

Only after Loop A is satisfied:

1. Launch an Opus 4.8 subagent at high reasoning to review the entire
   `shared-apple-refactor` PR (diff against the refactor baseline), not just the
   fixes.
2. Triage and fix every real issue, recording a one-line reason for anything
   declined.
3. Re-run `./scripts/test.sh apple` until green.
4. Repeat the review/fix/test cycle until the reviewer returns no real issues and
   you are satisfied. Then stop Loop B.

For both loops, keep subagent reasoning between Low and High per the standing
instruction, and use Sonnet 5 for reading/research-heavy passes and Opus 4.8 when
deeper judgment is needed.

## Acceptance

* Fixes 1-5 implemented with the described tests.
* `./scripts/test.sh apple` passes (Kit + AppCore package tests, Firebase auth
  adapter tests, project listing, unsigned generic-device iOS build).
* Loop A (Sonnet 5 medium) and Loop B (Opus 4.8 high) both reach a state with no
  outstanding real findings.
* No change to `70cdaa4` or earlier history; packet-tunnel extension unchanged.
* Signed-device manual matrix from the refactor plan remains outstanding and is
  not claimed by these gates.

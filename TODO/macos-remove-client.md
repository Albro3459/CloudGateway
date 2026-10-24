# Remove Client from the macOS menu

Base: `ceeeb5c816c35aa7d3733601c90c87a7fdc121b2` on branch `mac-review-client`.
Worktree: `/Users/alexbrodsky/GitHub/CloudGateway-mac-review-client`.
Start from committed files only. Leave the original checkout and its untracked
plan alone. Keep all commits local.

## User flow

Add **Remove Client…** immediately below **Add Client…** in the signed-in menu.
Use Remove Client for the menu action and modal title.
Open a modal with a Region picker, a Config picker limited to that region, a
Delete button, and Cancel. Show the selected client name and region clearly.
Deleting removes the cloud client and its local profile through the existing
controller command. Explain that deletion cannot be undone.

The user must disconnect the selected config and wait for it to stop first.
Keep active configs visible, with a clear explanation and Delete disabled.
Connecting, connected, reasserting, and disconnecting all count as active.
An unrelated active config must not block deleting an inactive config. A
last-used selection alone does not make a config active.

Do not connect, disconnect, or change the last-used client to remove a config.
Do not create a new backend delete endpoint, duplicate the CLI removal path, or
perform cloud deletion directly in the app UI.

## Existing implementation

The base commit already implements `.removeClient` through the owner controller,
fresh account and inventory checks, inactive-profile validation at dispatch,
cache eviction, local profile cleanup, and structured operation outcomes.
Reuse `CloudGatewayMacFrontendClient.userRequest` and its confirmation protocol.
The app currently exposes only Add Client. Its async AppKit modal and task
cancellation are the local pattern to follow.

Connection eligibility is separate from removal eligibility. Missing config
bytes, region capacity, or an unavailable extension must not by themselves
prevent a user from selecting a cloud client for deletion. The owner remains
responsible for fresh authorization and profile checks.

## Implementation checkpoints

- [x] 1. Finish plan review with SOL xhigh, resolve findings, record the result,
  and commit this plan before implementation
- [x] 2. Add a small testable removal selection model at the macOS frontend
  boundary. Use account/region/client identifiers as identity, never labels or
  picker indexes. Preserve the existing region/client sort order and owner
  labels. Distinguish duplicate names and regions with the same display name.
  Reset the config selection when its region changes. Handle no clients and no
  selection without enabling Delete
- [x] 3. Derive removal availability from current authenticated controller state,
  independently of Add Client capacity and connect eligibility. Require current
  snapshot/build, settled authorized session, and no conflicting operation.
  Extend the menu projection with minimal removal data, including stable region
  IDs, removal availability, and per-client removal eligibility. Derive inactivity
  from fresh `observedProfiles` matched by canonical identifier. Neither nullable
  client status nor connect enablement proves inactivity: a cached row with a
  mismatched secret reference can have nil status while its profile is active.
  Unknown or unavailable observations must not enable Delete. Include absent
  and inactive local profiles without requiring a downloaded config
- [x] 4. Add the async cancellable modal and menu action, register any new app
  source in the Xcode project, and update both initial rendering and open-menu
  enablement. Keep Delete disabled until a valid inactive config is selected.
  Update the open dialog when snapshots change. Invalidate it on account change,
  sign-out, controller replacement, shutdown, or incompatible/stale controller
  state. Avoid returning a captured selection after it becomes invalid
- [x] 5. Submit `.removeClient` with the full selected identifier. Recheck the
  current account and selection immediately before submission. Keep UI work
  serialized while a deletion runs. Use the same operation ID to await its
  terminal outcome, including a lost confirmation. `userRequest` can return
  running and can throw a coarse immediate-confirmation error. Keep the action
  task alive through terminal lookup and recover the structured `reply.outcome`
  by operation ID after confirmation errors. Keep definite admission rejection
  distinct from an accepted operation. Never automatically replay deletion.
  Treat unknown outcomes as uncertain and ask the user to Refresh. Surface
  access, inactive-client, network, and partial-cleanup results with safe text.
  Report a completed deletion with a warning separately from a failed deletion
- [x] 6. Add focused host-free tests for selection identity, region changes,
  empty lists, inactive versus all active statuses, unrelated active profiles,
  stale or unavailable observations, session changes, cancellation, and mutation
  outcomes. Extend the real frontend/IPC test harness where needed to prove the
  selected identifier is submitted, confirmation happens once, and unknown
  outcomes are not resent. Cover nil cached-row status hiding an active observed
  profile, immediate and delayed failures, and completed cleanup warnings.
  Retain existing controller/CLI removal regressions
- [x] 7. Update macOS user/development docs with Remove Client and the
  disconnect-first rule. Record automated and manual checks with their actual
  results. Leave checks open when the environment cannot exercise them
- [x] 8. Run the repository validation entry point, resolve SOL code review,
  check off completed work, and commit the tested implementation locally

## Validation and review

Use `./scripts/test.sh macos` as required by the project instructions. It runs
shared Apple tests, host-free macOS tests, strict dead-code scans when Periphery
is available, the unsigned arm64 app/extension build, and packaging checks.
Use the pinned committed WireGuard submodule, never uncommitted dependency
files. Do not install the app, change live VPN state, or delete a real cloud
client as part of validation. This feature is confined to macOS, so iOS code
changes are not planned.

Manual acceptance checklist:

- [ ] Remove Client appears directly under Add Client in the signed-in menu
- [ ] Region selection shows only configs from that region, including duplicate
  display names with distinct identifiers
- [ ] Delete is disabled for the active config with a disconnect-first message
- [ ] An inactive config can be selected while a different config is active
- [ ] Cancel, Escape, or session/controller invalidation closes without deletion
- [ ] Successful deletion refreshes the list and preserves unrelated selection
- [ ] Failed or uncertain deletion and partial cleanup produce clear feedback

Use SOL (`gpt-6.1-sol`) with `reasoningEffort: xhigh` for the plan review. Spread
implementation and review across `codex_main` and `codex_secure`. If a provider
hits its limit, stop assigning it work and continue on the other provider.
Each review round is a new delegated task including previous findings and
resolutions. Do not overlap edits to the same files. The parent owns commits.

## Review record

Plan review: SOL `gpt-6.1-sol`, xhigh, `codex_secure`, 2026-10-24. Two P2
findings resolved in checkpoints 3, 5, and 6: project explicit removal data from
fresh observed profiles, and recover typed terminal outcomes after confirmation
errors. Reviewer marked the plan ready after these additions. No unresolved
plan findings.
Implementation review: SOL `gpt-6.1-sol`, xhigh, `codex_secure`. Round 1
found one P2: snapshot polling rebuilt open picker menus. Fixed by preserving
unchanged items and deferring structural updates until picker tracking ends.
Delete eligibility and the explanation still update immediately. Added two
AppKit regressions for menu-item identity and deferred updates. Round 2 verified
the fix and returned no remaining actionable findings.
Validation: baseline host-free macOS tests passed (720 tests), as did shared
Apple tests. The first baseline run selected Xcode's Python 3.9 and lacked the
ignored Firebase resource in the new worktree, so Python packaging checks and
the app build failed before implementation. Final validation will put Homebrew
Python first on PATH and use an ignored synthetic `GoogleService-Info.plist`
containing only a fixture marker, matching the packaging verifier fixtures. No
live Firebase configuration or uncommitted source files are copied. Final
validation: 741 macOS host-free tests passed, including 21 new regressions.
Final `PATH=/opt/homebrew/bin:$PATH ./scripts/test.sh macos` passed in full:
shared Apple tests, 741 macOS host-free tests, both strict macOS Periphery scans,
unsigned arm64 app/system extension build, bundle packaging, and 58 packaged CLI
help/version/usage smoke checks. `git diff --check` passed. Both Codex providers
were used without reaching an account limit.

The manual acceptance checklist remains a signed, live-account release check.
No app was installed and no real cloud config was deleted during this task.

Remove Client naming correction:

- [x] Name the menu action and modal Remove Client, with removal names in code,
  tests, and docs
- [x] Keep deletion routed through the existing controller `.removeClient`
  command and require an inactive target
- [x] Add a native AppKit regression for the Remove Client title
- [x] Complete SOL xhigh review on `codex_secure`, with no findings
- [x] Complete the macOS validation rerun and commit the correction locally.
  All 742 macOS tests, shared tests, strict Periphery scans, unsigned arm64
  app/system extension build, packaging, and 58 packaged CLI smoke checks passed

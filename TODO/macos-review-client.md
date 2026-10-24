# Review client from the macOS menu

Base: `ceeeb5c816c35aa7d3733601c90c87a7fdc121b2` on branch `mac-review-client`.
Worktree: `/Users/alexbrodsky/GitHub/CloudGateway-mac-review-client`.
Start from committed files only. Leave the original checkout and its untracked
plan alone. Keep all commits local.

## User flow

Add **Review client…** immediately below **Add Client…** in the signed-in menu.
Use the requested Review client label even though the action removes a client.
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
prevent a user from reviewing a cloud client for deletion. The owner remains
responsible for fresh authorization and profile checks.

## Implementation checkpoints

- [x] 1. Finish plan review with SOL xhigh, resolve findings, record the result,
  and commit this plan before implementation
- [ ] 2. Add a small testable review selection model at the macOS frontend
  boundary. Use account/region/client identifiers as identity, never labels or
  picker indexes. Preserve the existing region/client sort order and owner
  labels. Distinguish duplicate names and regions with the same display name.
  Reset the config selection when its region changes. Handle no clients and no
  selection without enabling Delete
- [ ] 3. Derive review availability from current authenticated controller state,
  independently of Add Client capacity and connect eligibility. Require current
  snapshot/build, settled authorized session, and no conflicting operation.
  Extend the menu projection with minimal review data, including stable region
  IDs, review availability, and per-client removal eligibility. Derive inactivity
  from fresh `observedProfiles` matched by canonical identifier. Neither nullable
  client status nor connect enablement proves inactivity: a cached row with a
  mismatched secret reference can have nil status while its profile is active.
  Unknown or unavailable observations must not enable Delete. Include absent
  and inactive local profiles without requiring a downloaded config
- [ ] 4. Add the async cancellable modal and menu action, register any new app
  source in the Xcode project, and update both initial rendering and open-menu
  enablement. Keep Delete disabled until a valid inactive config is selected.
  Update the open dialog when snapshots change. Invalidate it on account change,
  sign-out, controller replacement, shutdown, or incompatible/stale controller
  state. Avoid returning a captured selection after it becomes invalid
- [ ] 5. Submit `.removeClient` with the full selected identifier. Recheck the
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
- [ ] 6. Add focused host-free tests for selection identity, region changes,
  empty lists, inactive versus all active statuses, unrelated active profiles,
  stale or unavailable observations, session changes, cancellation, and mutation
  outcomes. Extend the real frontend/IPC test harness where needed to prove the
  selected identifier is submitted, confirmation happens once, and unknown
  outcomes are not resent. Cover nil cached-row status hiding an active observed
  profile, immediate and delayed failures, and completed cleanup warnings.
  Retain existing controller/CLI removal regressions
- [ ] 7. Update macOS user/development docs with Review client and the
  disconnect-first rule. Record automated and manual checks with their actual
  results. Leave checks open when the environment cannot exercise them
- [ ] 8. Run the repository validation entry point, resolve SOL code review,
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

- [ ] Review client appears directly under Add Client in the signed-in menu
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
findings resolved in checkpoints 3, 5, and 6: project explicit review data from
fresh observed profiles, and recover typed terminal outcomes after confirmation
errors. Reviewer marked the plan ready after these additions. No unresolved
plan findings.
Implementation review: pending.
Validation: pending.

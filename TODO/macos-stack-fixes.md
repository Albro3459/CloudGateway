# Fix the macOS stack review findings

Status: complete, unsigned validation and fresh implementation review passed
Base: `9733914b` on `mac-remove-client`
Review: [validated findings](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-stack-review.md)

The user authorized fixing all three findings, regression tests, unsigned
validation, a fresh implementation review loop of at most three rounds, and
local commits. Use only Secure Codex, `gpt-6.1-sol` with high reasoning. Do not
push or run signed tests/builds.

## Commit checkpoints

- [x] Commit the review document: `9733914b`
- [x] Resolve a fresh subagent's plan review and commit this plan
- [x] Implement menu restoration, cache recovery, and PATH setup fixes
- [x] Pass unsigned validation and independent implementation review
- [x] Check off this plan, record final results, and commit the fixes

## 1. Allow menu removal after session restoration

- [x] In the
  [menu projection](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerViewMapping.swift),
  derive removal permission from the authorized account and settled inventory.
  Remove the requirement that the browser coordinator itself reports signed in.
  Keep mutation ownership, account presence, authorization, restoration/auth
  settling, and inventory freshness checks. Preserve row-level inactive-profile
  checks and controller authorization at execution.
- [x] Add a controller-to-view regression in the
  [controller tests](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift)
  using a retained session and real snapshot projection. After restoration and
  inventory refresh, removal must be available before and after another refresh,
  even though the browser coordinator did not perform a new sign-in.
- [x] Check that signed-out, unauthorized, restoring, settling, busy, stale-build,
  unavailable-inventory, and active-target cases remain blocked at their owning
  boundaries. Reuse existing coverage and add only missing regression cases.

## 2. Recover online inventory when optional cache preload fails

- [x] In the
  [controller refresh](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift),
  make the early cache preload optional. A malformed, invalid, or unreadable
  cache must not prevent a fresh access check and inventory fetch. On preload
  failure, clear installed selection/presentation and cached authorization before
  allowing asynchronous cloud work to continue. Clear only in-memory
  `hasAuthorizedInventory`, installed rows, and selection. Do not persist denial
  or sign out because cache metadata is unreadable.
- [x] Keep the session/cancellation fence immediately after the cache await,
  including failure paths. Preserve valid cache availability during a slow
  refresh. Fresh cloud authorization still owns cache rebuilding; failures to
  persist the authoritative result must still fail the refresh.
- [x] Add admin retained-session regressions for malformed JSON and a decoded
  payload that fails cache validation. With a healthy server, refresh must fetch
  inventory and rewrite a readable cache without an unrelated client mutation.
- [x] Verify invalid cache cannot become an offline connection source, explicit
  access denial still invalidates/signs out, and account changes cannot publish
  the old session's cache or cloud result. Check that authoritative persistence
  failure cannot produce a successful refresh. Use existing fixtures and gates.

## 3. Avoid false PATH setup success after later replacement

- [x] Update
  [startup-file inspection](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacCLIInstaller.swift)
  to account for the interactive startup file running after the login profile.
  Reuse the existing bounded assignment parser. Keep enough inspection state to
  distinguish a file that preserves an inherited local-bin entry from one that
  replaces it. No shell execution or general shell interpreter is needed.
- [x] Before reporting an existing profile configuration or appending to the
  profile, require later recognized PATH assignments to retain or explicitly
  restore the local-bin entry. If they erase it, return the existing
  `manualShellConfiguration` error before creating or modifying the profile.
  A later file that explicitly supplies local bin can still report existing
  configuration. Keep the existing app-PATH result and custom-shell handling.
- [x] Add installer regressions for scalar/array PATH replacement, unsupported
  PATH assignments, replacement after an existing profile export, and a later
  preserving/appending assignment. Include scalar and array preservation,
  `PATH+=:/opt/bin`, `PATH+=/opt/bin`, and replacement followed by an explicit
  restoration. Unsupported assignments invalidate inferred state until a later
  supported assignment establishes it again. Check return/error results,
  unchanged bytes, and no newly created profile on rejection. Update old cases
  that expect false success.
- [x] Preserve no-follow editing, ownership/permission checks, read bounds, locks,
  symlink inspection without editing, and explicit-path CLI usage. During
  development use fixture files only. Rejected configurations remain untouched;
  the successful authorized installer action still appends to the profile.
  Update the menu's manual-configuration explanation and
  [macOS usage documentation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md)
  if needed to describe rejection of a later PATH replacement accurately.

## Validation and review

- [x] Parent manually reviews the combined diff and runs
  `/Users/alexbrodsky/GitHub/CloudGateway/scripts/test.sh macos` with no signed
  option. This includes shared tests, macOS host-free tests, Periphery, unsigned
  arm64 app/extension build, packaging verification, and CLI smoke checks.
  Delegate code edits by disjoint files; one owner runs validation to avoid
  concurrent package builds.
- [x] A fresh Secure subagent reviews the implementation, regression coverage,
  security boundaries, and this plan's acceptance criteria. Each new round gets
  the original brief plus prior findings and responses. Maximum three rounds.
  Fix validated findings and rerun affected unsigned checks before the next round.
  Stop after a clean round. If three rounds leave issues, record them clearly
  rather than claiming the loop passed.
- [x] Mark the original findings resolved with source/test evidence, keeping the
  reviewed snapshot and historical review record clear. Update this plan with
  validation results and review dispositions before the implementation commit.
- [x] Check whitespace, file links, branch/index state, and intended diff. Commit
  only this task's files. Do not change version/build numbers or other stack
  branches as part of these fixes.

## Plan review record

Fresh Secure Codex reviewer, `gpt-6.1-sol`, high reasoning, approved the plan.
The parent accepted its clarifications: fence both cache preload outcomes before
changing state, clear only in-memory cache authorization, keep fresh persistence
mandatory, carry PATH state in startup order, test preserving/appending and
restoring assignments, and leave rejected startup files unchanged. No blocking
objections remain. No tests or production code changed for this checkpoint.

## Implementation review and validation record

The parent implemented controller/menu changes and their regression cases. A
Secure implementation subagent handled the installer, fixture coverage, and
matching menu/usage wording. Files were divided between them.

The full unsigned macOS entry point passed: 789 macOS host-free tests, shared
package tests, both strict Periphery scans, unsigned arm64 app/extension build,
packaging verification, and 88 packaged CLI checks. The runner also passed its
release/packaging and WireGuard startup checks. No signed operations ran.

Fresh Secure Codex implementation review round 1 passed with no actionable bugs,
security regressions, or blocking plan gaps. The reviewer checked the combined
diff against `ba7ca08e`, production boundaries, regression coverage, and plan
acceptance criteria. No further rounds were needed, and no objections remain.

Only Secure Codex was used for planning, implementation, and this review loop.
The review document and agreed plan were committed separately as `9733914b` and
`ba7ca08e`. The implementation, final checklist, and resolution record are
committed together. No version/build changes or pushes were made.

Limits: fixture tests do not execute real Zsh startup files. The bounded parser
does not evaluate arbitrary shell code. Signed Keychain/XPC/NetworkExtension and
live Firebase behavior were not exercised. These limits do not leave any of the
three validated findings unresolved.

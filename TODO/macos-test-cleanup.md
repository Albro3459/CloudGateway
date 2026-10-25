# Keep useful macOS test coverage and trim weak checks

Status: audit and independent review complete, cleanup not implemented
Reviewed base: `507cbfa9` on `mac-remove-client`

The audit supports targeted cleanup: three deletion candidates, three small
consolidations, one optional merge, and five assertion or coverage-claim repairs.
The dialog-title check stays after independent review. Most of the suite checks
concrete behavior. No large test-count reduction is justified by these findings.

## Scope and count

The macOS package has **789 test declarations** across 53 files containing tests
(plus one support-only Swift file). The split is 330 core, 276 controller IPC,
149 CLI, and 34 tunnel IPC tests. Of those declarations, 165 use Swift Testing
arguments. Parameter rows and loops exercise additional cases, so this is a
source count, not a count of distinct user workflows or runtime invocations.

The [unsigned runner](/Users/alexbrodsky/GitHub/CloudGateway/scripts/test.sh:288)
also runs 543 shared Kit/AppCore test declarations, 31 Firebase auth adapter
tests, 22 packaging verifier tests, 50 release workflow tests, WireGuard startup
regressions, Periphery scans, an unsigned arm64 build, and 88 packaged CLI
checks. The shared packages run once per runner invocation. These extra checks
are separate from the 789 macOS declarations.

The detailed audit covers the 789 macOS declarations and their production paths.
Shared tests and runner checks were inspected to establish scope and compare
apparent overlap, without doing a second full audit of those suites.

## Decision rule

Keep a test when it can catch a distinct functional regression: wrong target,
wrong account, unsafe replay, missing consent, incorrect output, failed cleanup,
or a late callback changing a newer session. A fake at an OS, network, storage,
or clock boundary does not by itself make a test weak. Check what real code the
fixture exercises and what the assertions would catch.

Deletion candidates prove language behavior, repeat stronger coverage, or constrain
an input that cannot reach the tested boundary in production. Literal output
assertions can protect useful behavior. Consolidate overlapping setup only when
every distinct case survives and the result stays readable. Fewer declarations
alone do not mean less maintenance or faster validation.

## Findings and review decisions

### 1. Remove the setup enum inequality test

- [ ] Delete `pendingAndFailedSetupNeverPresentReadiness` from the
  [setup tests](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacSetupStateTests.swift:6)

It constructs enum values and checks `state != .ready`. The
[enum](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacSetupState.swift:3)
uses synthesized equality. The test never reads `canActivate`, projects menu
readiness, or tries an activation. Broken activation or readiness logic would
still pass it. The remaining tests in the same file directly check activation
and replacement policy. Keep the controller and view tests that exercise actual
setup admission and presentation.

Review agreed that synthesized enum equality adds no readiness coverage. The
parent kept the deletion recommendation.

### 2. Consolidate the setup activation policy checks

- [ ] Combine `pendingRequestsCannotSubmitAnotherActivation`,
  `requiredRestartBlocksActivation`, `ordinarySetupStatesAllowActivationRetries`,
  and `invalidEmbeddedBundleCannotActivate` in the
  [same file](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacSetupStateTests.swift:16)
  into an explicit expected-value matrix

The pending-state test already asserts `.required` and `.failed` are activatable,
and the ordinary-state test repeats those assertions. Restart and invalid-bundle
checks are separate one-row versions of the same property test. Preserve all ten
enum cases and both allowed/blocked outcomes. This reduces repeated assertions
and declarations without reducing policy coverage. Keep the two extension
replacement tests, which call a different policy and cover active profiles,
missing preferences, and a replaced app.

Review agreed the literal matrix removes repeated assertions while preserving
all policy cases. The parent kept consolidation.

### 3. Delete the test-local inventory adapter smoke test

- [ ] Delete `macControllerInventoryRemovalUsesTheRealRequestHelper` in the
  [controller tests](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:11)

It calls the test-local `MacControllerInventory.deleteClient` directly. That
fixture forwards to the real request helper, but the test exercises neither the
controller nor the app's inventory-service adapter. Its DELETE, single-request,
owner/status, and authorization/dispatch-order assertions repeat
[`clientRemovalSendsOneRegionalDeleteWithTheCapturedOwner`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacClientRemovalRequestTests.swift:6).
Keep that stronger request test and controller removal workflows. Neither test
establishes wiring in the
[app adapter](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift:152),
so deleting this smoke test loses no production-adapter coverage.

Review confirmed the stronger request test covers these assertions and neither
test checks app-adapter wiring. The parent kept deletion.

### 4. Consolidate confirmed creation followed by refresh failure

- [ ] Fold
  [`macControllerReportsConfirmedCreationWhenInventoryRefreshFails`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:471)
  into the confirmed cases of
  [`macControllerCreationCompletionDistinguishesConfirmedAndUnknownResults`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:1376)

Both run successful creation followed by failed inventory refresh. The first
checks the submitted name/count and literal user-facing warning. The second
checks asynchronous completion and the typed warning versus uncertain creation.
Move the first assertions into the retained test, including its wait for
`snapshot.canCreateClient`. Completion alone does not prove creation admission
reopened. Preserve both refresh-error inputs (`.unavailable` and `.offline`),
and retain the unknown-create case. A literal table of scenarios is clearer than
adding unrelated Boolean switches.
Delete the standalone test only after preserving those checks.

Review required preserving the readiness wait as well as both error inputs. The
parent added that requirement and kept consolidation.

### 5. Simplify coordinator tests that reproduce adapter behavior in a fake

- [ ] Replace the detailed fake-adapter removal matrices with focused coordinator
  error propagation checks

[`macConfigExternalActivationAtRemovalBoundaryPreventsRemoval`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacConfigCoordinatorTests.swift:452)
changes profile status while the fake adapter is suspended. The decisive second
inactivity check is in test-local
[`MacConfigTestProfiles.remove`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacConfigCoordinatorTests.swift:787).
It does not test the real adapter's recheck. The four active-state cases already
exercise the real removal helper in
[`macProfileRemovalRechecksExternalActivationImmediatelyBeforeMutation`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacProfileRemovalTests.swift:60).

Similarly,
[`macConfigRemovalDoesNotHideRemovalOrReloadFailure`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacConfigCoordinatorTests.swift:439)
models reload and retained-profile verification inside that fake. Real-helper
[failure propagation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacProfileRemovalTests.swift:95)
and
[verified absence](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacProfileRemovalTests.swift:105)
tests cover those decisions in production code.

Keep coordinator checks for `.clientActive` and ordinary adapter errors reaching
the caller and releasing ownership. Preserve coordinator serialization,
cancellation, and authorization forwarding. Simplify only fake behavior used
solely by the removed matrices, after checking other callers. Keep all detailed
real-helper boundary tests.

Review agreed, while warning that removal gates and authorization callbacks
serve other tests. The parent retained focused error/ownership checks and
limited fake simplification to otherwise unused behavior.

### 6. Isolate the installer's masked startup-file rejection

- [ ] Rewrite the final assertion in
  [`cliInstallerPathEditLeavesCustomShellConfigurationAlone`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacCLIInstallerTests.swift:137)
  using a fresh fixture or benign profile

The test first creates a custom PATH assignment that independently causes
`manualShellConfiguration`, then adds an empty `.zshenv` and expects the same
error. Removing the production `.zshenv` guard would still leave the earlier
reason to reject. Isolate `.zshenv` as the rejection reason and assert that the
installer leaves existing bytes unchanged or creates no profile. Retain the
shell, ZDOTDIR, and custom-PATH cases. Existing tests that accept an already
available PATH do not replace this rejection check.

Review confirmed the earlier custom PATH rejection masks the guard. The parent
kept the isolated-fixture repair.

### 7. Make the cache secret-reference test exercise its claimed boundary

- [ ] Keep the namespace assertions in
  [`cacheRejectsUnboundOrNonMacSecretReferences`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacAccountCacheTests.swift:163)
  and add correctly bound fixtures with a foreign service and malformed reference

The current inputs only mismatch account/identifier or supply an empty account.
They retain a valid macOS secret service and reference. Metadata validation
rejects them before evaluating the
[service/reference guard](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift:17).
Its name promises coverage the assertions do not provide. Use otherwise valid,
authorized metadata so each bad secret reference is the only rejection reason.
Assert the concrete service/reference boundary errors, which differ from namespace
validation errors. This is a coverage repair, with no deletion saving.

Review agreed and noted the different boundary error types. The parent added
concrete-error assertions to the repair requirements.

### 8. Keep the dialog-title check

Keep
[`removalDialogShowsRemoveClientTitle`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacControllerIPCTests/CloudGatewayMacClientRemovalDialogTests.swift:198).
It walks real AppKit view labels and checks that one says `Remove Client`.
Other dialog tests exercise picker identity, tracking, invalidation, and
cancellation, but do not preserve this output assertion.

Review rejected the proposed deletion: literal copy is still observable output
and this check catches a unique regression. The parent accepted the objection
and withdrew deletion. Keep this test with the other functional dialog tests.

### 9. Delete the CLI case that bypasses the controller's validated IP contract

- [ ] Delete
  [`cliLongRendererStripsCIDRWhileKeepingMachineMetadata`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLISelectorTests.swift:383)

It injects `10.0.0.2/32` using raw `JSONDecoder`, bypassing protocol validation,
and expects the renderer to strip the prefix while machine metadata retains it.
The production
[controller state](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerState.swift:123)
rejects CIDR on the wire and normalizes domain addresses before transmission.
The CLI cannot receive this state through the validated controller path.

Keep
[`controllerMapsValidTunnelCIDRToBareIPv4WithoutRelaxingWireValidation`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacControllerIPCTests/CloudGatewayMacControllerOutcomeTests.swift:154),
which checks prefixes 0–32 and wire rejection, plus
[`cliListsUseUUIDsAndIdenticalOrderingAcrossLayoutsAndJSON`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLISelectorTests.swift:95)
for real long-format output. Reconsider deletion only if accepting raw,
unvalidated controller state becomes a supported renderer contract. This finding
does not propose deleting the production renderer fallback.

Review traced validated XPC decoding and agreed the injected state is
unreachable through the supported path. The parent kept test deletion and
excluded production fallback removal.

### 10. Remove the fake-only terminal EOF assertion

- [ ] Remove `LoginInput.restoredAfterEOF` and its assertion, and rename
  [`loginEOFAndFailedShortcutsLeaveReadableChallengeAndPolling`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCLITests/CloudGatewayMacCLILoginTests.swift:114)
  around the shortcut/polling behavior it actually tests

The fake sets that flag when its key array is empty. The assertion proves the
fake ran, and never exercises
[production terminal restoration](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCLI/CloudGatewayMacCLILoginTerminal.swift:64).
Keep readable challenge output, failed clipboard/browser guidance, narrow-terminal
handling, and continued polling. Actual EOF/termios restoration remains a
coverage gap. Do not report this test as covering it after cleanup.

Review confirmed the flag only reports fake behavior. The parent kept assertion
removal and the narrower test name.

### 11. Correct the unsigned-bundle fixture's claim

- [ ] Rewrite or rename
  [`macSignedBundleRejectsUnsignedInstalledBundle`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacIPCTests/CloudGatewayMacBuildIdentityTests.swift:99)
  so its fixture and name match the rejection being tested

The fixture's executable is a text shell script. Production constructs static
code, checks validity, then requires signing metadata and CMS in
[build identity loading](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacBuildIdentity.swift:53).
The test only observes the shared `invalidRequest` result.

Inference from inspection: another rejection reason could keep the test passing
if validity checking regressed. This audit did not execute it or establish which
guard fails. Describe the current case literally as rejection of a synthetic
shell-script app bundle, without claiming a particular guard caused it. A valid Mach-O with the
intended missing/untrusted signing state could make unsigned-rejection coverage
more faithful if that coverage is pursued. It would still not alone prove the
validity-check call is required, because missing metadata also rejects. A new
binary fixture is optional. Record the unsigned-executable coverage gap. Keep
metadata mismatch, code-hash, symlink, and requirement-injection tests.

Review rejected calling the cause malformed executable rejection because the
failing guard is unknown. The parent changed the proposed name to describe the
synthetic shell-script bundle and made a new binary fixture optional.

### 12. Merge idle-result retention setup only if it stays simpler

Optional: combine
  [`controllerOrchestratorIdleExitWaitsForTheRetainedResultWindow`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacControllerIPCTests/CloudGatewayMacControllerOwnershipTests.swift:248)
  and
  [`controllerOrchestratorRetainsLateCommandResultsForRecoveryWithoutRenewingActivity`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacControllerIPCTests/CloudGatewayMacControllerOrchestratorTests.swift:607)
  into a shared scenario with explicit connect/stop cases

Both hold a command past idle expiry, complete it, retain the result through
599 seconds, and allow exit at 600 without passive lookup renewing activity.
Their initial timing differs: connect starts before idle expiry, while stop first
establishes idle exit and starts afterward. Preserve that distinction, connect's
inventory-admission reopening, stop's explicit activity renewal, retention checks
at 60/300/599/600 seconds, lookup before and after expiry, and renewed-activity
boundaries at 1499/1500 seconds after completion.

A small literal table may simplify the repeated setup. Keep both tests if the
merge needs a scenario helper or flags controlling different follow-up checks.
Reducing the declaration count alone does not justify this merge.

Review required preserving distinct initial timing and making the merge
conditional on readability. The parent accepted both limits. Keeping the
existing tests is a valid outcome.

### 13. Consolidate same-generation stale snapshot success/failure setup

- [ ] Parameterize the old reply outcome in
  [`frontendClientOldSnapshotCannotReplaceNewerObservation`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacControllerIPCTests/CloudGatewayMacFrontendClientTests.swift:130)
  and
  [`frontendClientOldTransportFailureCannotEraseNewerFreshState`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacControllerIPCTests/CloudGatewayMacFrontendClientTests.swift:151)

They hold an old snapshot, publish a newer connected observation, then deliver
old success or failure. Preserve both outcomes, the expected thrown failure,
freshness, connected presentation, clear error, active-tunnel state, and connected
transport state. The latter two assertions can apply to both outcomes. Success and
failure are fenced in separate production branches, so neither outcome is
redundant. Keep previous-generation, changed-instance, and old-lifecycle tests
separate.

Review agreed one success/failure parameter removes repeated setup while
preserving both production branches. The parent kept consolidation and applies
active-tunnel and connected-transport assertions to both cases.

## Similar coverage to keep

The core auditor proposed two further workflow merges. The parent and fresh
reviewer agreed to keep them separate:

- **Refresh coalescing:**
  [`macControllerTimerMenuAndExplicitRefreshShareOneFetch`](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:923)
  starts from scheduled refresh. The
  [repeated awaited refresh test](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:1762)
  starts from an awaited call and verifies two waiting callers. They share setup
  but have different initiators and completion contracts. Merging for one fewer
  declaration offers little benefit unless both paths remain explicit.
- **Removal eviction:** the
  [presentation/refresh matrix](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:1262)
  covers empty remaining inventory and reconnecting a remaining client. The
  [HTTP/active-VPN matrix](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Tests/CloudGatewayMacCoreTests/CloudGatewayMacControllerTests.swift:2728)
  covers an unrelated active VPN, both inactive target statuses, caller lifetime,
  cleanup, busy rejection, and stale-cloud suppression. A merged matrix could
  become harder to follow or expand the case count. Shared assertions alone do
  not justify deleting either workflow.

Keep these functional categories:

- Secret install/commit/rollback and recovery after partial persistence
- Account/session epochs, stale completions, explicit denial versus transport
  failure, and authorization persistence across restart
- Removal consent, target identity, active-profile rejection, uncertain remote
  results, and avoiding duplicate destructive requests
- Read, mutation, and verification failures at real profile-removal boundaries
- Controller ownership, receipt replay, update handoff, draining, and restoration
- Login request/poll/exchange deadlines and cleanup after late SDK completion
- Real file locks, atomic replacement, modes, bounds, symlink/FIFO rejection
- QR generation followed by actual decode to the approval URL

The packaged CLI checks exercise a built executable through direct and symlink
entry points. Parser unit tests do not establish bundle resources, launch routing,
or bundle-derived version output. Keep smoke coverage of those boundaries.

## Follow-up validation

Implement only the agreed items, keeping each survivor assertion listed above.
Run the unsigned
[macOS entry point](/Users/alexbrodsky/GitHub/CloudGateway/scripts/test.sh:288)
after test changes, including Periphery so fixture simplification does not leave
dead support code. Compare retained cases and assertions, not just declaration
counts. Measure duration before claiming faster validation. No new signed or
live-service validation is needed for this documentation task.

## Review and validation

Two Secure Codex auditors inspected the core and CLI/IPC suites. A fresh Secure
Codex reviewer then checked all 13 findings, their cited production paths,
survivor assertions, source counts, and file links. The parent answered every
finding above. Round 1 rejected item 8 and narrowed items 4, 11, and 12. All
objections were accepted into this revision. A second fresh Secure reviewer
verified every final disposition and approved the document with no remaining
material corrections. Implementation remains deferred to a separate task.

Only Secure Codex (`codex_secure`, `gpt-6.1-sol`, high reasoning) is used for this
audit and its delegated reviews. This task changes documentation only. No tests,
builds, signed operations, live service calls, or production code changes have
run as part of this audit. Counts come from source inspection. The parent
manually reviewed the document, checked all local file links and whitespace,
and confirmed that only this report is included in the local commit. No runtime
speedup or passing test result is claimed. Nothing was pushed.

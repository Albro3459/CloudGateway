# macOS controller refactor review

Reviewed 2026-10-21. Source implementation is complete. Final validation and review are in progress. Checked items indicate source
changes and automated coverage, while live acceptance remains tracked separately.

Scope: [PR #16](https://github.com/Albro3459/CloudGateway/pull/16), `mac-cli`
at `376e6b20`, compared with `main` at `9f426542`. The checkout was clean before
this review. The diff contains 54 files, including the controller extraction,
menu IPC, subsequent bug fixes, extension updates, packaging, tests, and docs.

The [earlier design and debugging thread](t3-thread://v1/67b45205-2685-43e0-b03f-01cc12f1881e)
provided requirements and failure history. Findings below were checked against
the current source. Historical fixes are not counted again as open defects.
Three GPT-6.1 Sol High reviewers on the Secure Codex account reviewed transport,
domain behavior, and extension updates. The main agent verified and consolidated
their findings and made the recommendations below.

## Decision

Keep the single background controller and the existing VPN/auth core. The
separation is appropriate for a menu app and a future CLI, but the controller/menu
milestone is not finished. Fix the seven defects below and complete the signed
runtime checks before treating it as stable.

The implementation moves controller lifecycle, request admission/results, and
extension-update reconciliation into package components with injected effects.
The app-target service now owns platform construction and process lifetime.
Findings below describe the reviewed baseline. The current implementation and
validation record are tracked here as work completes.

Keep these parts:

- One non-root controller per macOS user, with ownership acquired before Firebase
  initialization
- Existing Firebase session recovery, account fencing, authorized offline cache,
  config transaction recovery, and confirmed-stop sequencing
- Authenticated, bounded XPC and the extension's UID-bound secret/start-grant
  boundary. Frontend snapshots must remain free of configs and credentials
- GUI ownership of extension approval and replacement requests
- Build-specific extension Mach endpoints and independent app/extension versions,
  with a release process that enforces their identity rules

Keep the shared Apple packages and iOS outside this cleanup unless a concrete
limitation requires a separately reviewed change. Do not start CLI commands yet.

## Implementation checkpoints

- [x] Enforce fresh signed extension builds against a distributed baseline
- [x] Validate inventory commit/publication, signed-out stop, and bounded preparation
- [x] Validate the package dispatcher, durable extension transitions, and frontend races
- [x] Pass unsigned macOS checks, including strict dead-code scans
- [ ] Pass signed macOS build and entitlement/profile verification
- [ ] Complete fresh Sol High review rounds and resolve their findings
- [ ] Complete the live runtime matrix below

The menu and controller remain the implementation scope. CLI commands wait for
the runtime gate. Checked source tasks do not imply that installed-process,
reboot, SSH, approval, or replacement scenarios have been exercised.

## Reviewed defects

All seven are P2: concrete conditional failures to fix in this milestone. They
are supported by source traces, not new live VPN reproductions. The order below
puts loss of local control and release failures first.

### F1. Disconnect depends on receipt capacity and disk writes

- [x] Let an idempotent disconnect proceed when durable receipt admission fails

[Mutation admission](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
reserves a receipt before dispatching `turnOff`.
[Reservation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
fails at 64 live receipts or when the receipt file cannot be written. Accepted
and rejected mutations occupy slots for ten minutes.

**Trigger and impact:** with an active VPN, fill the receipt window or encounter a
write failure such as a full disk, then choose Disconnect. The service returns
`unavailable` without calling the VPN controller. Its special permission to
disconnect while draining does not bypass this storage gate.

**Fix:** keep VPN-command serialization, but make local stop independent of
durable receipts. A retry should reconcile observed state and safely stop any
remaining owned tunnel. Preserve deduplication for operations that can create or
install something.

**Done when:** the production dispatcher stops a connected profile with full
receipt storage and with an injected persistence failure. Repeated stop requests
are safe, and neither case starts or removes a profile.

### F2. Update handoff removes status and disconnect from the menu

- [x] Separate safe inspection/disconnect from current-build mutation admission

The [menu poll](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacMenuClient.swift)
rejects a draining lifecycle and clears the snapshot. Its
[request gate](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacMenuClient.swift)
then permits only lifecycle requests. The
[service](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
explicitly permits snapshot and disconnect while draining, but the frontend
cannot use that exception.

**Trigger and impact:** replace the app while cloud work or an Add Client
preparation holds the old controller open. The VPN keeps running, but the menu
loses observed status and disconnect access until handoff finishes. F7 can extend
this interval.

**Fix:** retain clearly identified last-observed state during reconnection and
support compatible live status/disconnect during drain. Coordinate both ends:
[normal request validation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerContracts.swift)
also requires exact build identity, so relaxing only the menu gate will not let a
new-build frontend inspect an old controller. Define a small authenticated
compatibility contract for these safe operations. Keep new connects blocked.

**Done when:** with an active VPN and held cloud work, an app replacement preserves
status and allows disconnect from the applicable old/new client. Stale snapshots
must never be presented as fresh observations.

### F3. Re-signing can change extension identity without changing its version

- [x] Enforce the extension artifact/version relationship during release preparation

The [release archive/export path](/Users/alexbrodsky/GitHub/CloudGateway/scripts/macos-release.py)
retains the extension's project version while signing/exporting it again.
[Build identity](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacBuildIdentity.swift)
hashes the complete CMS signature as well as the CodeDirectory identity. The
release verifier checks the requested versions but does not compare against the
previously distributed extension artifact.

**Evidence:** read-only parsing of existing archive/export pairs under
[/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/.build/releases/1.0.0-2-gufhrmtl](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/.build/releases/1.0.0-2-gufhrmtl)
and
[/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/.build/releases/1.0.0-2-xfcg9gvb](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/.build/releases/1.0.0-2-xfcg9gvb)
found equal extension versions and CodeDirectories but different CMS blobs within
each pair. These older local artifacts demonstrate signing behavior, not a live
upgrade reproduction of this PR.

**Trigger and impact:** an app-only release produces a newly signed extension at
the same version/build. Readiness rejects the old installed fingerprint, while
[Apple's replacement decision uses the extension version identifiers](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequestdelegate/request(_:actionforreplacingextension:withextension:)).
The result can remain Update Required despite repeated activation, with new VPN
starts blocked. The equal build also reuses the same Mach endpoint.

**Fix:** either reuse the exact previously signed extension artifact or require a
new extension build whenever packaging signs it again. Reject fingerprint drift
under a reused build before publication. Preserve signer validation. The manual
warning in the [release guide](/Users/alexbrodsky/GitHub/CloudGateway/docs/apple-macos-release.md)
needs an enforceable packaging rule.

**Done when:** consecutive app-only releases satisfy the chosen artifact policy,
and their upgrade reaches authenticated readiness with SIP enabled and system
extension developer mode disabled. That installation consequence remains untested.

### F4. Connect can use inventory from before a committed refresh

- [x] Make authorization-cache commit and published inventory coherent at command admission

[Refresh](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift)
persists new cache authorization before publishing its new options and installed
metadata. [Connect](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift)
captures the old option/config and cancels refresh without reconciling a commit
that has already happened.

**Trigger and impact:** cloud config B replaces A, refresh commits B's authorized
hash, and Connect runs before the refreshed options publish. A saved A fails its
authorization check. An unsaved A can reach installation, then fail metadata
persistence against B's hash. The
[install sequence](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift)
saves the profile and commits its secret before that metadata check, so failure
can leave profile/storage changes from obsolete material.

**Fix:** serialize the commit/publication boundary with command admission, or
resolve commands against an explicit coherent inventory revision. Cancel stalled
network fetches promptly, but reconcile any completed authorization commit before
resolving the selected config. Merely awaiting a cancelled task is insufficient
if cancellation already suppressed publication.

**Done when:** pause after authorization commits and before publication, then
connect a changed or removed config. No obsolete config is installed, stale
authorization cannot start a tunnel, and failed reconciliation preserves the
active VPN. Existing stalled-fetch tests do not cover this boundary.

### F5. A controller restart can require a reboot despite a ready extension

- [x] Reconcile the expected running extension before keeping an uncertain activation blocked

[Startup restoration](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
changes a saved same-boot `activating` attempt to `restart`.
[Readiness](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
then returns Awaiting Restart before attempting its authenticated ping.

**Trigger and impact:** macOS finishes activation, but the controller restarts
before it receives the completion report or finishes its readiness poll. The exact
target extension may already be running, yet Refresh and menu relaunch cannot
clear the reboot requirement. New VPN starts remain disabled.

**Fix:** represent an interrupted activation separately from an OS-confirmed reboot
requirement. When the target still matches the installed bundle, allow a read-only
authenticated identity probe to resolve uncertainty. Keep the safety gate on a
mismatch, unavailable endpoint, or a genuine OS reboot requirement.

**Done when:** restoring an interrupted attempt with a matching running target
recovers without reboot. Mismatched/unreachable targets remain blocked, and an
explicit `willCompleteAfterReboot` result retains its required semantics.

### F6. Readiness can discard an attempt before its completion report arrives

- [x] Use one durable terminal transition for readiness and GUI completion

[Successful readiness](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
clears `extensionUpdate` without recording its ID in `finishedExtensionUpdates`.
[Report handling](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
accepts only an active attempt or a retained terminal receipt.

**Trigger and impact:** polling observes the expected extension before the GUI's
delayed or retried completion report. That report is rejected. The
[frontend report loop](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift)
stops retrying and displays the generic account/client-change error even though
setup succeeded.

**Fix:** persist the same bounded completion receipt before clearing an attempt,
whether completion came from readiness reconciliation or an OS delegate report.
Late reports for that attempt should acknowledge completion without changing a
newer attempt.

**Done when:** readiness wins the race, the terminal report arrives and retries,
and the controller is reconstructed between those events. All old terminal reports
acknowledge success without changing newer state.

### F7. Add Client preparation can outlive its transport deadline

- [x] Bound aggregate region preparation and cancel abandoned read-only work

[Preparation](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift)
holds the RPC until [all serial capacity reads finish](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift).
Each HTTP request can take ten seconds, Firebase token retrieval has no enclosing
preparation deadline, and the
[transport times out after 30 seconds](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerXPC.swift).

**Trigger and impact:** several unavailable regions consume the deadline even
when another region has capacity. The dialog closes and discards the eventual
result. The [server task survives disconnection](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerXPC.swift),
so abandoned preparation also holds an active request and can delay controller
handoff.

**Fix:** use bounded concurrent capacity reads with an overall deadline below the
RPC deadline, returning unresolved capacities as unknown. Alternatively, give
preparation an explicit asynchronous result contract. Give read-only preparations
their own cancellation lifetime, separate from accepted VPN mutations that must
survive a client disappearing.

**Done when:** one healthy region remains usable among enough stalled regions to
exceed 30 seconds serially. Cancellation releases preparation work, and replacing
the app during preparation does not leave the controller draining indefinitely.

## Targeted rewrites and cleanup

### R1. Put production orchestration under tests

- [x] Extract the service's lifecycle, admission, receipt, and activation policies
  into a macOS package component with injected effects
- [x] Keep Firebase construction, launchd, Security.framework, NetworkExtension,
  OS extension requests, and process exit in thin adapters
- [x] Inject the clock, persistence, installed-identity probe, tunnel observation,
  and transport so tests can pause the real production transitions

The [package manifest](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Package.swift)
does not include the app-target service, menu client, or activation coordinator in
its host-free test targets. Current lifecycle tests cover the small
[update helper](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacUpdateLifecycle.swift),
wire validation, and storage utilities. They do not exercise the production
prepare/start/report/ping/restart sequence that contains F5 and F6.

Keep those useful tests. Add boundary coverage that calls the extracted production
code, without rebuilding its decision logic inside test fakes. This is the first
rewrite to make because it supports the remaining fixes.

### R2. Give extension updates one state machine

- [x] Replace string phases and scattered nullable fields with typed states and
  explicit transitions
- [x] Distinguish prepared-but-not-submitted, submitted, approval pending,
  outcome unknown, OS-confirmed reboot required, and completed
- [x] Centralize persistence and terminal receipt handling, with target/attempt
  fencing for delayed callbacks and readiness responses
- [x] Keep status observation, local stop permission, and permission for a new
  start separate from update presentation

Reconcile observed extension identity after interruptions. Do not infer readiness
from activation completion alone, and do not infer a required reboot solely from
losing the frontend or controller.

### R3. Finish the client-independent command contract before CLI work

These are agreed design gaps, not additional newly introduced menu regressions.

- [x] Replace UI-derived command authorization with explicit domain preconditions.
  [Current stop admission](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift)
  uses the menu's `canTurnOff`, which requires a signed-in account and an active
  observation. The agreed contract requires signed-out `down` and idempotent
  success when no owned tunnel is active. Preserve logout's running VPN
- [x] Publish a sanitized domain snapshot with separate auth/access, inventory
  freshness, local installation, observed VPN, setup, and operation state.
  [The current wire view](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerView.swift)
  primarily contains menu titles, groups, and enabled flags. Keep menu wording
  and browser-opening decisions in the frontend
- [x] Implement accepted/running/completed/failed/unknown operation state with a
  bounded active/latest result. The current receipt stores `accepted`, not the
  result of the VPN command. A reconnect cannot recover start submission or
  failure by operation ID. Preserve the no-history and no-crash-replay policy
- [x] Define and test the acceptance handoff before route-changing work begins.
  Owning a detached task does not by itself prove the response reached the client
- [x] Make lifecycle compatibility independent of normal protocol-version
  validation. Today the validator rejects a different schema/protocol before
  applying the lifecycle exception. Existing tests vary app/build identities,
  not protocol versions. This is a future upgrade gap, not a current version-1
  interoperability failure
- [x] Give the frontend explicit connected, reconnecting, draining, and incompatible
  states. Use request/snapshot generations and controller instance identity to
  prevent old responses from restoring stale state

### R4. Make failures diagnosable and simplify the plan

- [x] Preserve bounded, sanitized launch/bootstrap failure categories and exit
  status. The [launcher](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerLaunch.swift)
  discards all subprocess output, while bootstrap's false result is ignored by
  the menu retry loop. Distinguish an already registered job from a real failure
- [x] Use operation-specific errors. An extension attempt rejection should not
  tell the user that their account/client list changed
- [x] After fixes, reconcile the current milestone checklist in
  [the CLI plan](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-cli.md).
  Keep historical troubleshooting as evidence, but make current blockers and
  completed runtime proofs easy to find

## Work order and acceptance

1. Extract the production orchestration seams in R1 and add failing boundary
   cases for F1, F2, F5, and F6
2. Fix local disconnect availability and update reconciliation. Enforce F3's
   artifact/version rule before another release candidate
3. Fix refresh/command coherence and aggregate preparation deadlines, F4 and F7
4. Complete R3's domain/operation contract and reconnect behavior while the menu
   remains the only implemented frontend
5. Run the existing macOS validation entry point, then the signed runtime matrix.
   Start the CLI only after the controller/menu milestone passes

For implementation validation, use
[/Users/alexbrodsky/GitHub/CloudGateway/scripts/test.sh](/Users/alexbrodsky/GitHub/CloudGateway/scripts/test.sh)
with `macos`, then `macos --signed` from a signing-capable session. If shared
Apple code changes, include the relevant iOS/shared checks. Passing package tests,
Periphery, and an unsigned build does not establish installed-process behavior.

Required live evidence:

- [ ] Fresh signed installation: startup, sign-in, setup approval, install,
  connect, switch, disconnect, quit/reopen, and retained VPN after logout
- [ ] Existing installation: controller idle exit/relaunch, menu reconnect, and
  menu closure during accepted work
- [ ] Update with active VPN, held cloud work, and a pending Add Client dialog.
  Observe old/new app, controller, and extension identities. Do not manually
  restart the controller first, which would bypass the handoff being tested
- [ ] Extension approval, delayed completion, interrupted activation, genuine
  reboot-required state, same-version re-sign rejection, and distinct-build
  endpoint replacement
- [ ] Slow/unreachable cloud, locked or unavailable credential storage, failed
  receipt persistence, and config changes during refresh. Local stop stays usable
- [ ] After one-time desktop setup, reboot and SSH before graphical login.
  Confirm Firebase session access, launch context, extension reachability, VPN
  preference operations, and accepted work surviving SSH loss
- [ ] Sleep/wake and multiple desktop/SSH clients. Treat fast user switching as a
  separate check because a per-user controller is not a machine-wide VPN lock

## Fresh implementation review

Round 1 uses fresh Main Codex GPT-6.1 Sol High reviewers for requests/frontend,
inventory/domain, and extension/release behavior.

- [x] Evaluate idle exit before each timer schedules another readiness probe
- [x] Let durable extension attempts survive controller handoff, including an
  abandoned preparation. The successor restores and expires the reservation
- [x] Retire an obsolete activation target after a verified later boot, retaining
  a terminal receipt and requiring authenticated readiness for the new target

- [x] Keep known command results in memory without redundant receipt writes
- [x] Retain only the active/latest result while durable digests suppress replay
- [x] Distinguish definite Connect failures from successful start submission and
  retain success if later selection metadata cannot be written
- [x] Report credential cleanup failure as a failed Sign Out operation

The domain and requests reviewers reported four distinct outcome/retention issues
(the Connect finding was duplicated). All seven distinct fixes passed the full macOS validation run, including 263
package tests and both strict dead-code scans. A second fresh review round is
pending.

## Implementation validation

`./scripts/test.sh macos` passed after the review fixes with 263 macOS package tests, both strict
Periphery scans, the unsigned arm64 app/system-extension build, and packaging
verification. Shared Kit/AppCore and Firebase adapter tests also passed.
The signed run repeated the passing tests and dead-code checks, then failed
while signing the Release system extension with `errSecInternalComponent`.
Signing/profile verification remains pending. The exact failure is recorded in
[/private/tmp/cloudgateway-macos-signed-1.log](/private/tmp/cloudgateway-macos-signed-1.log).
The fresh Sol High review loop is in progress.

Production policies now live in the
[controller orchestrator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift),
[request store](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerRequests.swift),
and [extension update orchestrator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacExtensionUpdateOrchestrator.swift).
The [frontend client](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacFrontendClient.swift)
uses domain snapshots and fences responses by sequence, generation, and controller
instance. Its app adapter handles platform construction. The tracked CLI plan
and macOS runbook describe the acceptance handshake and recovery behavior.

Source checks cover the seven findings. The live evidence list above remains
open. No installed app, running controller, VPN profile, or active tunnel was
changed during implementation.

## Original review validation and limits

This pass used source/diff review, inspection of existing tests and plans, Apple
primary documentation, and read-only comparison of existing signed artifacts.
The main agent independently confirmed the archive/export CMS mismatch and
checked all seven control-flow findings. `git diff --check main...HEAD` passed.

No implementation, index, installed app, controller process, VPN, profiles, or
credentials were changed. No new build or test suite was run for this docs-only
pass. The previous thread's 199-test result is historical evidence, not a fresh
result or proof of the remaining signed runtime scenarios.

The packaging mismatch is observed in existing artifacts. Its live installation
effect and the timing-dependent defects still need the reproductions listed
above. No confirmed secret leak or authentication bypass was found in this pass.

# Implement the macOS CLI

Status: **researched, implementation pending**. Updated 2026-10-22.

This is the implementation sequence for the CLI on top of PR #17's controller.
The command and product contract remains in
[macos-cli.md](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-cli.md).
This plan replaces its earlier requirement to finish signed runtime proof before
implementing CLI commands. Implement and validate unsigned now, through
[scripts/test.sh](/Users/alexbrodsky/GitHub/CloudGateway/scripts/test.sh).
Keep signed installation and runtime acceptance for a later manual session.
The user confirmed no live controller checks have been completed since PR #17
and directed implementation to assume the controller works. Do not block CLI
work on those checks or request that evidence again during implementation.

## Baseline and scope

- Research baseline: `b7d0410d`, the head of
  [PR #17](https://github.com/Albro3459/CloudGateway/pull/17) and the starting
  commit of `mac-cli`. The controller orchestration rewrite is complete
- The [review thread](t3-thread://v1/9f89dcc8-7d21-40bc-b796-8b3c99c19473)
  records two fresh Secure Sol High reviews without actionable findings,
  263 passing macOS package tests, unsigned build/packaging checks, and the
  user's passing signed run. These are prior evidence, not new CLI validation
- Live reboot/pre-desktop SSH, final SSH disconnect, credential context,
  replacement, and recovery checks are deferred. Assume the controller works
  for implementation planning, without recording those checks as passed
- Main and Secure GPT-6.1 Sol High subagents independently researched controller
  contracts and packaging/testing. This task changes planning docs only

Ship `auth login`, `auth status`, `auth logout`, `list`, `status`, `up`, `down`,
`refresh`, `doctor`, and help/version with the existing flags and exits. Keep
canonical `FirebaseUID/regionId/clientId` IDs, NDJSON schema version 1, and the
existing one-time desktop setup requirement. Bare `cloudgateway` prints help.

Use the existing bundled executable and background controller. The CLI owns
parsing, terminal interaction, output, and caller deadlines. The controller
owns Firebase, authorization, inventory, selection, and accepted VPN work.
Preserve confirmed stops, authorized offline use, retained VPN on logout,
signed-out disconnect, and refresh without reconnecting.

Keep changes in the macOS layer. No second auth store, standalone VPN engine,
root helper, CLI client creation, config export, automatic reconnect, or new
dependency is needed. Keep iOS and shared Kit/AppCore behavior unchanged. A
narrow shared Firebase adapter diagnostic change is authorized if needed to
distinguish inaccessible credentials from signed out.

## What the existing implementation provides

- [Controller service](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift):
  singleton ownership before Firebase initialization and thin production adapters
- [Launcher](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerLaunch.swift):
  fixed installed bundle, `user/<uid>`, Background session, bounded bootstrap
- [Controller IPC](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerXPC.swift):
  same non-root UID, exact signing identity, bounds, version checks, and deadlines
- [Request orchestrator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift):
  reservation/confirmation, independent tasks, safe status/stop, and update draining
- [Config coordinator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift):
  install/rollback, missing-profile recovery, secret grants, idempotent starts,
  and confirmed-stop switching
- [Account cache](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift):
  account-scoped installed metadata, role invalidation, and selection
- [Browser auth coordinator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacBrowserAuthCoordinator.swift):
  validated device flow, monotonic expiry, throttling, and fenced token exchange

Reuse these paths. The CLI work fills concrete contract and frontend gaps.

## Decisions and implementation defaults

The confirmed decisions and implementation defaults are:

- `up` uses the controller's existing authorized inventory/cache policy. Explicit
  `refresh` or `list --refresh` obtains fresh inventory. The user confirmed this
  policy. Do not add a mandatory inventory fetch to every online start
- Retain the latest VPN result and keep the controller alive for ten minutes
  after completion. This matches the existing result TTL. Reads need not extend
  that expiry. Idle exit can remain 60 seconds when no result or work needs it.
  App replacement, crash, reboot, or a newer result can end recovery earlier
- Credential status supports `unknown`. Never infer accessible credentials from
  a nil Firebase user. The user authorized a narrow shared Firebase adapter
  diagnostic change if needed to distinguish inaccessible credentials from
  signed out. Use supported evidence and preserve existing auth/storage behavior.
  Report unknown when the available APIs cannot establish the distinction
- Login startup/challenge acquisition has a bounded internal deadline. Once a
  challenge exists, default waiting follows its remaining server expiry.
  Explicit `--timeout` bounds the whole invocation and can only shorten waiting
- Explicit login cancellation/deadline cleanup targets only that attempt. An
  unexpected transport loss detaches the frontend, leaving controller polling
  bounded by the server expiry. It never cancels an unrelated login/session

Both product questions are resolved. Live controller checks are deferred by the
user's decision and do not block implementation.

## Implementation sequence

Each step should leave the menu app working and include its targeted coverage.
No implementation step is complete yet.

### 1. Add CLI-ready domain results and metadata

Primary files:
[core contracts](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacControllerContracts.swift),
[controller](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacController.swift),
[IPC contracts](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerContracts.swift),
[state projection](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerState.swift).

- [ ] Replace coarse completed/failed/unknown command reporting with macOS-owned
  typed outcomes and sanitized failure codes. Distinguish auth/access, setup,
  credential availability, selection/config, network, busy, deadlines, VPN
  failure, and uncertain/expired outcomes. Never parse menu messages for exits
- [ ] Distinguish `startRequested` and `alreadyActive`. A successful start API
  return stays successful if later selection/cache persistence fails, with a
  sanitized warning. A reservation alone never means a start was submitted
- [ ] Extend inventory rows with internal IP, cloud state, eligibility reason,
  installation/profile state, source, and freshness/observation timestamps.
  Project existing models/cache metadata, without serializing configs or secrets
- [ ] Distinguish a retained local profile from current authorized installed
  metadata. Refresh can invalidate metadata while an old profile remains active
- [ ] Expose explicit identity, access-verification, and credential-evidence
  states for auth status. Retained identity is separate from online/offline
  authorization. Include unknown evidence rather than inventing a diagnosis
- [ ] If needed, add the authorized narrow diagnostic to the
  [Firebase adapter](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/CloudGatewayFirebaseAdapter/Sources/CloudGatewayFirebaseAuthAdapter/CloudGatewayFirebaseAuthAdapter.swift).
  Keep it observational, preserve existing token/session recovery, and expose
  only sanitized availability evidence. Do not introduce a second credential
  store or change iOS sign-in behavior
- [ ] Associate account-bound operation details with their account/session in
  memory. Redact after logout/account change, including explicit ID lookup.
  Preserve minimal local VPN status and signed-out stop results
- [ ] Version richer ordinary IPC where required, update exact bounds and
  validation, and keep public CLI JSON versioning separate. Preserve or
  explicitly version the compatible lifecycle/status/stop/lookup protocol.
  New Codable enum cases are not automatically backward compatible

Acceptance: typed fixtures cover every CLI exit category, cross-account output,
freshness, and malformed/oversized replies. Existing menu mapping and compatible
status/stop remain valid. No raw SDK errors, tokens, keys, or full configs cross
the frontend boundary.

### 2. Complete command ownership and recovery contracts

Primary files:
[frontend client](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacFrontendClient.swift),
[orchestrator](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerOrchestrator.swift),
[request store](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacControllerIPC/CloudGatewayMacControllerRequests.swift),
[production service](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacControllerService.swift).

- [ ] Expose raw domain replies and separate reservation from confirmation.
  The current frontend converts snapshots to menu presentation and confirms
  inside `request()`. Preserve a menu convenience API using the same transport
- [ ] For VPN mutations: reserve, write/flush the operation ID, confirm, then
  await the final command outcome. Failed output before confirmation leaves
  the reservation unexecuted and subject to its existing 30-second expiry
- [ ] After confirmation, frontend timeout, interruption, broken pipe, or SSH
  loss only detaches the caller. Retain controller-owned tasks. Do not replay
  uncertain work with a new request ID, including automatic retries of `down`
- [ ] Keep request-ID payload checking and instance/generation fencing.
  Unknown lookup returns `operation_unknown` and current observed state.
  Ordinary status can succeed while reporting an unknown prior outcome
- [ ] Align idle exit with the ten-minute reconnect grace. Keep only active
  and latest result in memory. Durable anti-replay receipts remain separate
  from results, contain no user labels/configs/tokens, and do not replay work
- [ ] Resolve bare `up` inside the controller using that account's selection.
  Bind the request to the admitted session and revalidate at execution.
  Missing/removed/unusable selection fails with authorized choices
- [ ] Add correlated refresh completion, not an immediate snapshot reply.
  `refresh` and `list --refresh` await their own fetch/authorization result and
  report network failure with retained rows marked stale. Represent skipped,
  superseded, denied, and timed-out refreshes explicitly
- [ ] Keep status and local stop available during cloud reads/login, and
  serialize actual VPN mutations. Preserve existing refresh cancellation and
  generation fences when a start takes priority

Acceptance: output failure cannot release work, uncertain confirmation cannot
replay it, refresh cannot claim success from stale rows, and caller loss cannot
cancel confirmed VPN work. Use injected time to verify result expiry/idle exit.

### 3. Add the CLI module, dispatch, and read commands

Add a `CloudGatewayMacCLI` library and host-free test target inside
[the existing macOS package](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGatewayMacCore/Package.swift).
Keep parsing, command execution, public output DTOs, and renderers free of
AppKit, Firebase, live credentials, and an app host. Inject controller, output,
clock, terminal, and diagnostic effects. Use a small typed parser with shared
help definitions and no new parsing dependency.

Wire the product and thin adapters into
[the Xcode project](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway.xcodeproj/project.pbxproj).
Keep the CLI as a mode of the app executable.

- [ ] Move mode selection ahead of signed operational identity lookup in
  [main.swift](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/main.swift).
  Exact private `--controller` selects the service, private `--cli` selects CLI,
  and original invocation basename `cloudgateway` selects CLI before resolving
  symlinks. Normal app launch selects the menu. Reject conflicting dispatch
- [ ] Help, version, and usage errors finish before creating `NSApplication`,
  Firebase, a controller, or credential adapters. Operational commands retain
  signature/peer checks. Do not add a production unsigned security bypass
- [ ] Implement strict parsing for nested auth/help commands, common flag
  placement, command-specific options, canonical IDs, UUIDs, and positive finite
  timeouts. Reject duplicate value options, unknown flags, and extra arguments
- [ ] Implement `auth status`, local `status`, `status --operation`, `list`,
  and region filtering against typed domain replies. Wait for bounded startup
  restoration where needed, and identify pending/stale/unknown observations
- [ ] Implement dedicated public NDJSON envelopes, stable string enums,
  explicit nulls, UTC timestamps, and the existing exits 0–10/130. Human
  diagnostics use stderr. Help/version JSON requires no IPC
- [ ] Sanitize terminal labels and errors, keep IDs copyable, honor `NO_COLOR`,
  and suppress ANSI/shortcuts/prompts when redirected or noninteractive

Acceptance: unsigned packaged direct/symlink help and version work without
opening the menu or starting a controller. Host-free command fixtures cover
signed-out, restoring, authorized online/offline, denied, and stale inventory.
JSON is line-complete and independent of internal Codable layouts.

### 4. Add refresh and VPN/auth mutations

- [ ] Implement `refresh` and `list --refresh` using correlated completion
- [ ] Implement `up [config-id]` through controller resolution/install/start.
  Use controller-authorized inventory/cache, with fresh inventory fetched through
  explicit `refresh` or `list --refresh`
- [ ] Implement idempotent `down` while signed out and with no owned active
  profile. Confirm stop before reporting success
- [ ] Implement logout with explicit cleanup failure reporting, retaining the
  running VPN, profiles, secrets, and caches
- [ ] Print/flush human or JSON acceptance before confirmation. On final `up`
  success say `VPN start requested` or report already active, with observed
  tunnel state separate. Do not wait for delayed connected notifications
- [ ] Apply caller deadlines across bootstrap, IPC, and polling. Existing
  per-request transport deadlines must not silently override a shorter caller
  budget. Show the operation ID and recovery hint on uncertain outcomes

Acceptance: existing switch/install/offline policy tests plus CLI integration
fixtures cover missing selection, foreign account IDs, cloud-only install,
changed config, missing secret/profile, unchanged active config, and stop
timeout. A delayed status notification cannot delay successful start submission.
Refresh and logout never implicitly reconnect or stop the tunnel.

### 5. Add attempt-scoped login and terminal interaction

Extend the existing macOS browser coordinator, service, IPC, and
[menu frontend](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift).

- [ ] Introduce a nonsecret login attempt ID, frontend origin, phase,
  validated challenge, remaining expiry, and typed terminal result. Submission
  completion is separate from authorized sign-in completion
- [ ] Return current status for an already authorized session, busy for another
  active attempt, and bounded restoration/verification for a retained identity
- [ ] Scope cancellation to the matching attempt. A late cancel after success
  or from an older invocation must not clear a newer account presentation or
  cancel a newer exchange. Keep custom-token recovery fences intact
- [ ] Keep matching-attempt cancellation and expiry cleanup reachable while
  `down` runs. Login success, expiry, and cancellation must preserve accepted
  account-independent stop work. Separate that work from the current blanket
  account cleanup, while continuing to fence account-authorized starts
- [ ] Enforce the acquisition deadline and monotonic challenge expiry in the
  controller, including while request, poll, exchange, or access calls are
  suspended and after each completion. Expiry ends the attempt without a
  frontend. Preserve the existing custom-token cancellation/recovery fence so
  late callbacks cannot establish an expired session. An underlying SDK call
  may still settle later, and must block another exchange until it does
- [ ] Let the menu automatically open only a login it initiated. Observing a
  CLI challenge must not open a browser. Keep explicit GUI open/copy actions
- [ ] Print/flush link and code immediately, then poll in the controller.
  Generate QR locally with a thin Core Image adapter and render its matrix in
  the terminal, with quiet zone, correct orientation, and terminal-width checks
- [ ] Support `--no-qr`, `c`/`o`, JSON/noninteractive suppression, and remote-Mac
  clipboard/browser hints. Failed QR/shortcuts leave readable approval data
  and polling available. Never auto-open the CLI browser
- [ ] Read shortcut input only from a suitable interactive terminal. JSON,
  noninteractive, and redirected modes never start terminal reading. Closed
  stdin must still allow approval polling through success or expiry
- [ ] Use nonblocking terminal input with saved/restored settings and handled
  signals. Interactive EOF restores settings and disables shortcuts while
  polling continues. Clean up on success, denial, expiry, explicit cancellation,
  timeout, and output failure. No claim of recovery from uncatchable termination
- [ ] Keep challenge URL/code out of diagnostics, retained operation records,
  and logs. Device secret and Firebase/custom tokens remain controller-only

Acceptance: concurrent GUI/CLI login, duplicate submission, stale cancellation,
expiry/throttling, exchange cleanup, and terminal failures have focused tests.
Hold a stop open while login succeeds, is cancelled, or expires, and verify the
stop still completes. With the frontend absent, use fake time and held request,
poll, exchange, and access calls to verify timely expiry and harmless late
completions. Repeated challenge-acquisition throttling must also stay bounded.
Noninteractive/JSON login with stdin already at EOF still approves or expires.
A locally decoded generated QR matches the validated URL, or a controlled
fixture establishes matrix encoding. Real-terminal scan/shortcut checks remain
manual. Login polling does not occupy the VPN stop lane.

### 6. Add bounded, read-only doctor

- [ ] Aggregate `pass`, `warning`, `fail`, and `unknown` checks with evidence,
  suggested fixes, individual deadlines, and an overall deadline. Preserve
  partial results on timeout
- [ ] Inspect app location/resources, CLI link/PATH, OS/architecture, component
  identities, controller handshake/protocol, extension readiness, and readable
  app-owned preferences. Keep local checks useful when the controller fails
- [ ] Add passive controller startup for diagnostic-only use. Acquire ownership
  and serve authenticated lifecycle/diagnostic probes before constructing the
  Firebase runtime or starting normal auth restoration/inventory work. A normal
  menu/CLI domain command can then initialize the existing runtime once, behind
  the same owner. Timers and diagnostic status reads must not initialize it
- [ ] On a cold diagnostic controller, report auth/credential evidence as
  unknown/uninitialized. With an initialized runtime, read its existing snapshot.
  Independent normal clients may progress auth, but doctor must not trigger it
- [ ] Keep approval evidence richer than the current setup-state mapping.
  XPC failure or an extension-properties timeout cannot prove a Settings toggle
  is disabled. Preference read success cannot prove write/start permission
- [ ] Read auth/credential evidence without sign-in, token exchange, refresh,
  cache invalidation, or test writes. Report unknown when unsupported
- [ ] Separate network path, cancellable DNS resolution, HTTPS response, and
  service health. Require bounded HTTPS reachability to the configured dashboard
  origin. For known regional APIs, use existing read-only `/api/health` as an
  optional service check, validating region identity. Do not probe arbitrary
  user-supplied hosts or all regions, or interpret an HTTP error as healthy
- [ ] Return setup failure `4` before required online failure `6`, otherwise
  success `0`. Overall deadline gives `8` with partial results. Optional
  warnings/unknowns alone do not fail doctor

Acceptance: fake probes verify precedence, partial deadlines, cleanup, honest
unknowns, and absence of mutation effects. A cold-controller fixture with a
retained denied session must perform no auth restoration, sign-out, inventory
fetch, or cache invalidation until a separate normal command initializes it.
No approval requests, preference writes, start grants, VPN operations, traffic
capture, or DNS-query logging.

### 7. Add menu installation and package verification

- [ ] Add **Install Command Line Tool…**, available while signed out, outside
  ordinary controller mutation gating
- [ ] Validate the canonical installed app. Create the user's local bin
  directory and symlink to the bundled executable without admin rights.
  Reject DMG/translocated/development targets. Keep the signed bundle untouched
- [ ] Recognize the correct link. Report conflicting files/directories,
  conflicting links, and broken links without replacing them automatically
- [ ] Offer a separate explicit PATH edit for ordinary zsh login configuration.
  Preserve contents/mode, avoid duplicates, and handle custom `ZDOTDIR`, symlinked
  startup files, and unsupported shells conservatively with manual guidance.
  Always show the explicit user-local executable path for noninteractive SSH
- [ ] Extend
  [bundle verification](/Users/alexbrodsky/GitHub/CloudGateway/scripts/verify_macos_build.py)
  and its fixtures for CLI product/resources and bounded direct/symlink
  help/version/invalid-usage smoke checks. Use temporary links/homes, without
  installing the CLI, registering a service, or touching the running app/VPN
- [ ] Update the
  [README](/Users/alexbrodsky/GitHub/CloudGateway/Frontend/Apple/macOS/README.md),
  [development runbook](/Users/alexbrodsky/GitHub/CloudGateway/docs/apple-macos-development.md),
  and [release guide](/Users/alexbrodsky/GitHub/CloudGateway/docs/apple-macos-release.md)
  with commands, schema/exits, setup, SSH/PATH, recovery, logout semantics,
  and update/version behavior. Retain deferred research as historical

Acceptance: temporary-filesystem tests cover repeat install, conflicts, app
location, shell edits, and app removal/replacement. Packaged CLI help never
falls through to GUI mode. Existing app/extension identity and update rules hold.

## Validation and completion

All automated testing flows through
[scripts/test.sh](/Users/alexbrodsky/GitHub/CloudGateway/scripts/test.sh).
Do not run individual Swift/Python test commands as a parallel workflow.

- [ ] Add the new host-free test target to the existing macOS package. The
  `macos` suite already runs package tests, shared package/auth adapter tests,
  verifier/release tests, strict Periphery scans, unsigned arm64 app/extension
  builds, and bundle verification
- [ ] Wire any packaged CLI smoke helper into that same `macos` target, with
  deadlines and temporary files. Do not add signing or live service dependencies
- [ ] Run `./scripts/test.sh macos` after coherent implementation steps. Fix
  dead production/test code instead of broadly suppressing Periphery
- [ ] If the authorized shared diagnostic change is needed, use
  `./scripts/test.sh apple` to validate both consumers through the same script
- [ ] Use injected clocks/transport/output and deterministic synchronization
  for races and deadlines. Avoid tiny wall-clock sleeps, which made an older
  token-deadline test scheduling-sensitive
- [ ] Finish with fresh 6.1 Sol High source reviews across Main and Secure,
  covering command/output/security boundaries and production packaging/lifecycle.
  Fix confirmed findings and rerun the affected script target

No `--signed` run is required during this implementation. Unsigned packaged
help/version smoke checks validate dispatch, while operational flows use fakes
and compilation. This does not establish signed IPC or live VPN behavior.

Before release, separately record Terminal/local agent/noninteractive SSH,
reboot before desktop login, final SSH disconnect, concurrent menu/SSH startup,
locked credentials, offline/denied restoration, account switch, sleep/wake,
active-VPN replacement, stale clients, and extension approval/reboot recovery.
Use the downloaded notarized/stapled DMG with SIP/Gatekeeper enabled. Check the
actual bundled/symlink invocation identity and ownership in that context.
Do not alter the installed app, running controller, session, profiles, or VPN
while implementing without a separately planned runtime session.

If pre-desktop access fails, record the exact execution context and failing API.
A GUI-only service, root daemon, or separate credential store changes the product
architecture and needs a new decision. Unsigned progress does not waive the SSH
requirement or turn it into a proven capability.

## Source research

- [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains):
  Data Protection Keychain availability depends on user login context. A matching
  UID/bundle or unlocked file-based login Keychain does not establish access
- [Apple QR generator](https://developer.apple.com/documentation/coreimage/ciqrcodegenerator):
  use the platform QR encoder behind an injected adapter, without a QR dependency
- [Zsh startup files](https://zsh.sourceforge.io/Doc/Release/Files.html):
  login and interactive startup files differ, and `ZDOTDIR` changes their location.
  Editing login configuration cannot guarantee noninteractive SSH PATH
- [Existing health route](/Users/alexbrodsky/GitHub/CloudGateway/Backend/API/src/routes.py:154):
  optional regional doctor checks can use the current read-only endpoint

These sources guide implementation. They do not prove runtime behavior of the
CloudGateway distribution bundle. Research and document review ran here, with
no tests/builds, signing, app launch, installation, or live VPN changes.
Fresh Main Sol High plan review identified cold-doctor startup and stdin EOF
ambiguity. Both are addressed in the diagnostic/login steps and acceptance checks.
The follow-up Main/Secure reviews found no additional issues. A focused Main
review confirmed two further acceptance gaps found during source review:
preserving accepted stops during login cleanup, and enforcing login deadlines
while controller calls are suspended. Both are included above.

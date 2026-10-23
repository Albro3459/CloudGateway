# Implement controller-owned CLI updates

Status: approved with Main Astra High, implementation pending

Behavior contract:
[macos-cli-update.md](/Users/alexbrodsky/GitHub/CloudGateway/TODO/macos-cli-update.md).
Implement and validate unsigned. Do not run a live disconnect or extension
replacement while developing this feature.

## Existing code to reuse

- The app executable already provides menu, CLI, and headless controller modes.
  The controller's signature/build handshake protects current-build mutations
- `CloudGatewayMacControllerOrchestrator` owns request admission, confirmation,
  runtime ownership, extension readiness, and installed-app handoff
- `CloudGatewayMacControllerRequests` provides ordinary reservations/results,
  but its result is in memory only. A durable update requires its own record
- `CloudGatewayMacControllerUpdateStorage` provides private atomic records
- `CloudGatewayMacExtensionUpdateOrchestrator` stores extension attempts and
  validates readiness using target identity and authenticated ping
- `CloudGatewayExtensionActivationCoordinator` in the app target submits OS
  requests and gates replacement on confirmed idle profiles. Currently the
  menu owns its lifetime and sends attempt callbacks to the controller
- Controller `turnOff` and `connectClient` implement the real stop/start paths.
  Reuse them directly, without spawning CLI subprocesses
- CLI `CloudGatewayMacCLISession` already supports acceptance, confirmation,
  bounded observation, structured operation lookup, and read-compatible status

## 1. Durable update model and storage

Add a focused package-owned workflow with an injected clock, profile/readiness
observations, existing stop/start effects, OS activation events, and persistence.
Keep SystemExtensions/NetworkExtension adapters in the app target.

Represent prepared confirmation, confirmed stop, activation, approval/restart,
readiness checking, reconnect, and terminal phases. Keep one operation and target
identity, captured owner/config, reconnect decision, and bounded deadlines/results.
Keep transition rules in this workflow rather than duplicating them in the CLI.

Add a separate storage record with bounded decoding, version checks, and atomic
owner-only writes through existing storage helpers. Persist before advancing an
effect. Add recovery that reconciles actual profiles and authenticated readiness
before resuming. Unconfirmed operations expire without effects. Failure to read
or write must preserve ordinary local stop and prevent unsafe continuation.

Acceptance: fixture round trips and resumed instances preserve exact identity,
phase and reconnect intent; failures do not issue the next effect; already-ready
and initially disconnected updates never stop or start unnecessarily.

## 2. Controller admission, orchestration, and recovery

Add a current-build update request with explicit disconnect-consent input and a
typed update status in replies. Use a new action rather than changing the
compatible unscoped stop contract. Validate that consent applies only to update.

Persist the update reservation before acceptance. Route the existing confirmation
and operation lookup to the durable update when its ID matches. Keep generic
command results and update results distinct. Do not discard or substitute a
requested operation ID. Expose active update status in normal snapshots/status.

Admission observes current signed identity and owned-profile state. Recheck at
confirmation and immediately before stop/replacement. No-op if target is already
ready. Capture the actual active identifier, not last selection; reject ambiguous
or unauthorized reconnect targets before disruption. Wait for an already-running
disconnect to settle before choosing an initially disconnected update.

After confirmation, run controller-owned work independently of any IPC call.
Exclude concurrent mutating work and legacy/menu activation while it runs.
Preserve compatible status/operation lookup and local stop. A newer explicit
stop/logout/account change durably suppresses reconnect before taking effect.
If an OS request is already submitted, observation can finish without reconnect.

Block idle exit during live or actionable work. On startup resume the persisted
confirmed flow after bounded identity/session/profile checks. Detect app handoff
or target replacement and persist a superseded outcome rather than starting an
unrelated artifact. Keep account data redacted in operation/snapshot replies.

Use the existing extension-attempt orchestrator as the sole activation gate.
The workflow operation ID is its attempt ID, allowing two-record reconciliation
without ambiguous links. Current menu updates forward to the controller-owned
adapter; preserve the legacy callback gate without allowing it to compete with
managed activation. Do not permit independent menu and controller activation
requests. Do not weaken signature,
target-code-hash, no-active-profile, or account checks for headless execution.

Preflight reconnect metadata without contacting the new extension's build-specific
secret endpoint. Reconnect the captured client through ordinary `up` config
revision/authorization rules, with a non-displacing policy that refuses to stop
a different active profile. This preserves the user's requested client identity
while avoiding a separate pinned-secret/config-revision subsystem.

Use an explicit core auth-change hook for irreversible reconnect suppression,
including logout/login of the same account. Suppress on unscoped stop and scoped
stop of the captured target. Try the journal first and then an independent bounded
revocation marker. If both fail, continue local stop and surface the durability
warning. Recovery checks the marker before any start. A corrupt update journal
loads a blocked-update state instead of throwing out service initialization.

Acceptance: real controller integration covers one confirmed flow through
disconnect → ready → exact reconnect, CLI loss, restored state, active-operation
admission, new stop/logout suppression, and both frontends' shared activation gate.

## 3. Headless activation adapter

Make supported OS activation/replacement available to the headless controller
using its existing signed installed executable. Inject the fixed verified bundle
location and expected target into a reusable app-target adapter. The CLI symlink
must not be used as the app bundle location.

Retain the OS request/delegate for its whole lifetime, including approval waits.
Report activation, approval, restart, failure, and completion to the owning
workflow, independent of menu presence. Preserve the existing menu path through
shared code or compatible forwarding, with exclusive admission for either path.

Recheck installed identity and actual idle profile state before returning
`.replace` from Apple's callback. Keep main-queue NetworkExtension completions
unblocked. Do not treat `.completed` as readiness until the target authenticated
ping succeeds. Reconcile unknown outcomes after restart before resubmission.
Reconcile workflow/attempt records after partial writes. A verified app handoff
during approval marks managed work superseded, suppresses reconnect, fences the
old OS request until its owner exits, then allows the new controller to reconcile.
Bound post-completion authenticated readiness to 120 seconds.

Acceptance: injected adapter events exercise request ownership and state changes;
the real production adapter is wired into controller service, can live with no
NSApplication/menu, and builds in the signed bundle architecture without invoking
OS replacement during tests.

## 4. CLI command, recovery status, and diagnostics

Add `update` and `--allow-disconnect`, examples, JSON help, and consistent flag
validation. No interactive confirmation is required when the flag is present.
No CLI initial-setup command and no mutation under `doctor`.

The CLI prints/flushed accepted ID before confirmation and observes the durable
operation within the existing one caller deadline. Timeout/interrupt detaches;
it must not cancel confirmed work or tell the user to blindly resubmit. Include
the lookup command in diagnostics. Extend `status --operation` and human/JSON
rendering for update phases, approval/restart, reconnect result and coarse
compatible fallback. Preserve account redaction and current observed tunnel data.
Approval/reboot phases return exit 4 immediately with pending update data and ID,
while the compatible operation remains running. They are not durable failures.

Map setup failures accurately to extension mismatch, initial setup, approval,
restart, invalid bundle, checking readiness, or activation failure. Recommend
`update` for mismatch in `up` and doctor. Include disconnect opt-in guidance when
the VPN is active. Preserve machine schema v1 field types with additive fields.

Acceptance: CLI integration covers active/no-opt-in rejection without mutations,
no-op, initially off update, opt-in acceptance and exact target, lost frontend,
durable lookup after recreated controller, precise setup errors and JSON exits.

## 5. Documentation and packaged checks

Update the macOS README with build/install → `update` → operation lookup examples,
the disconnect flag, SSH route loss, unchanged extension no-op, initial GUI setup,
and actual Apple approval/reboot outcomes. Clarify that update uses the installed
bundle rather than downloading a release.

Add packaged direct/symlink help, JSON help, and invalid-usage checks for update.
Static checks must finish locally without IPC initialization or OS activation.
Update fixtures and retain bounded temporary homes and no terminal escapes.

## 6. Validation, review, and commits

1. Agree on these plans with Main Codex Astra High, then commit them together
   with the user's already-staged deletion of the completed selector TODO
2. Implement all steps with Main Codex Sol High subagents as needed. Keep file
   ownership explicit; centralize builds/tests to avoid overlapping Apple builds
3. After the full implementation, run unsigned `./scripts/test.sh macos` and
   fresh Main Sol High review rounds. Fix findings and repeat until parent and
   reviewer agree. Do not start implementation review before all steps exist
4. Commit the completed implementation locally. Never push

Meaningful coverage must include confirmation loss before effects, caller loss
after confirmation, disk failure before each effect, restart with each saved
phase, unknown/corrupt state, exact reconnect identity and account ownership,
initially off, disconnecting/connecting profiles, stop failure, activation failure,
approval/reboot, unchanged/changed signed targets, duplicate requests, stale
callbacks, menu/CLI concurrency, new explicit stop/logout, retention, and update
status surviving controller recreation. Avoid tests that only mirror enum values.

Preserve existing ordinary command semantics and all current unsigned checks.
Record live SystemExtensions/SSH behavior as unverified until an explicitly
authorized signed runtime exercise occurs. Do not run signed tests or mutate
the live VPN as part of implementation validation.

# macOS CLI and shared controller

Status: **background controller and menu IPC built and reviewed, signed runtime proof pending**.
This is the plan of record for the initial macOS CLI. It extends the existing
menu app, Firebase session, and NetworkExtension VPN implementation.

Keep [macos-cli-deferred.md](macos-cli-deferred.md) for now as historical research.
Its two-mode design, claim that no controller is needed, proposed REST auth,
unimplemented device-flow note, and larger command surface are superseded here.
Do not use its old API support table as proof of SSH compatibility.

## Agreed behavior

- Support humans, local agents, scripts, and SSH users
- After one-time desktop setup, routine commands must work after reboot when
  SSH is available, before anyone logs into the graphical desktop
- Desktop setup installs the app in `/Applications`, activates/approves the
  system extension, approves VPN preferences, and establishes the initial session
- FileVault preboot unlock and enabling macOS Remote Login remain prerequisites
  outside this feature. This does not promise SSH before macOS has booted
- One on-demand background controller serves both the menu app and CLI
- Require CloudGateway sign-in for every new `up`, including installed configs
- Preserve the app's authorized offline use for the same signed-in account
- Finish accepted VPN work if the issuing SSH connection or frontend disappears
- `up` returns when macOS accepts the start request. Do not wait for the delayed
  connected notification or claim that traffic connectivity has been verified
- Keep confirmed-stop sequencing before switching to another config
- Logout retains the running VPN, installed profiles, secrets, and account caches
- `down` works while signed out and retains installed configs
- Refresh inventory without interrupting a running tunnel. Apply changed config
  contents on the next explicit `up`
- Ship through the existing signed, notarized app and DMG
- Include help, doctor, JSON output, stable exit codes, and noninteractive use

## Scope

Implement the controller and migrate the existing menu app before adding the
CLI. The menu app is the first client. All its current behavior, including Add
Client, must work through the controller before the CLI becomes a second client.

Keep `CloudGatewayKit`, shared `CloudGatewayAppCore`, the Firebase adapter, and
iOS unchanged during this refactor. Compose their existing APIs in the macOS
layer. Raise a concrete shared-core limitation before expanding that scope.

Initial commands:

```text
cloudgateway auth login
cloudgateway auth status
cloudgateway auth logout
cloudgateway list
cloudgateway status
cloudgateway up [config-id]
cloudgateway down
cloudgateway refresh
cloudgateway doctor
cloudgateway help [command...]
```

Keep account administration and cloud client creation/removal out of the CLI.
`up` may install an existing authorized cloud config locally. It does not create
a cloud client. Preserve the menu app's existing Add Client feature when moving
its shared services into the controller.

No separate WireGuard engine, `wg-quick` wrapper, privileged CLI installer,
traffic monitoring, connection history, or automatic reconnect policy. Optional
waiting for `up` is deferred until a concrete need appears.

## One executable, three modes

Keep the existing app's signed main executable in its bundle:

```text
/Applications/CloudGateway.app/Contents/MacOS/CloudGateway
~/.local/bin/cloudgateway -> /Applications/CloudGateway.app/Contents/MacOS/CloudGateway
```

Dispatch modes before creating `NSApplication`, the status item, or the current
`CloudGatewayMacAppController`:

- Normal app launch starts the menu interface
- Invocation through `cloudgateway` starts the CLI client. Bare `cloudgateway`
  prints help rather than opening the menu interface
- A private controller launch argument starts the headless owner. It is an
  internal service entry point, excluded from public command help
- Provide an explicit internal CLI dispatch path for direct executable calls,
  and verify symlink/argument dispatch in the packaged app

The CLI and controller need Foundation/async event processing without creating
`NSApp`. Linking AppKit into the executable is separate from initializing it.
Browser and clipboard actions belong to the frontend and run only when requested.

The bundle retains its provisioning profile, resources, signing identity,
Keychain group, and extension. Sharing the executable is a promising way to
preserve profile ownership and extension IPC identity. It still needs proof in
the exact launch context. A separately provisioned app-like helper is possible
but adds a signing and deployment surface without a current need.

## Why the controller is necessary

The packet-tunnel system extension already owns WireGuard execution and secure
config storage. It does not own the Firebase session, cloud inventory, account
authorization, config selection, or menu/CLI command sequencing. Adding those
services to the root extension would expand its privilege and dependencies.

The new controller runs as the owning non-root macOS user. Both frontends call
it, and it calls the existing NetworkExtension adapter and authenticated
extension XPC service. The extension keeps its current narrow role.

There are three concrete reasons to have one owner:

1. **Auth consistency.** Shared Keychain storage does not provide live shared
   Firebase state. Firebase says other consumers must reload after changes.
   The current custom-token recovery marker can also make a second process
   mistake an active login exchange for an interrupted one and sign out
2. **Mutation ordering.** The config coordinator's actor and busy flag protect
   one instance. Independent GUI and CLI instances would still race when
   installing, switching, selecting, signing out, or invalidating account caches
3. **Caller lifetime.** Route changes can disconnect SSH during `up` or `down`.
   A command owned by the SSH process cannot reliably finish. The background
   owner must retain accepted work independently of its IPC connection

A file lock alone does not solve auth propagation or caller lifetime. A broker
inside the menu interface does not meet the pre-desktop SSH requirement.

### Ownership and boundaries

Controller owns:

- Firebase initialization, session restoration, device-code polling/token
  exchange, product-access checks, sign-out, and auth change publication
- Authorized cloud inventory, memory-only Firestore caching, per-account
  installed metadata, last selection, and role/offline policy
- Config install/replacement, start/stop sequencing, preference observation,
  extension readiness checks, and a shared snapshot for both frontends
- Serialized mutations, account/session fencing, active operation lifetime,
  and bounded command result state

Menu interface owns presentation, menu interactions, browser/clipboard actions,
extension activation/replacement prompts, Settings navigation, the CLI install
action, and its existing Launch at Login preference. Quitting the menu closes
that frontend. It does not cancel accepted controller work or stop the VPN.

CLI owns parsing, help, terminal interaction, output, and exit codes. It does
not initialize an independent Firebase session or mutate the account cache.

System extension keeps the existing root-owned System Keychain configs,
WireGuard backend, UID-bound secret references, and single-use start grants.
Full configs cross only the existing authenticated installation boundary.
Never return them through the controller's frontend protocol.

### Launch and IPC

- Prove a launchd-managed per-user background owner that can start on demand
  from both desktop and SSH contexts. Select the exact registration/bootstrap
  mechanism during the runtime proof, before committing to launch plists
- An ordinary Aqua-only LaunchAgent or `SMAppService.mainApp` Launch at Login
  setting is not evidence that pre-desktop SSH launch works
- Do not substitute a root daemon or a daemon with a configured user UID and
  assume it acquires a user login/Keychain context
- Enforce one owner per macOS user across concurrent desktop and SSH clients,
  including startup races. A losing startup attaches to the existing owner
  before initializing Firebase or performing recovery
- Prefer authenticated local XPC if the proven bootstrap context supports it.
  If a Unix socket is needed, keep the same contracts and authenticate peers
  with supported connection credentials/code-signing APIs
- Authenticate the exact app identity/team and same non-root UID in both
  directions. Do not trust a supplied UID, PID, account ID, path, or socket
  permissions as the sole authorization check
- Version and bound requests, responses, subscriptions, and deadlines. Reject
  incompatible clients with an actionable update message
- Frontends reconnect to the controller and replace state from its snapshot.
  They never infer sign-in or tunnel success from a sent request
- Keep the controller alive while clients or accepted operations need it.
  Define and prove safe idle exit/relaunch without tying it to the SSH session
- Keep extension activation and explicit replacement in the GUI. The headless
  service reports setup/update required instead of opening approval dialogs

The existing extension rejects root clients and verifies the app's signing
identity. Preserve those checks rather than broadening them for the CLI.
Separate per-user controllers also do not create a machine-wide VPN lock.
Validate fast user switching and global tunnel interactions without claiming
cross-user serialization that the current extension does not implement.

Keep reusable controller contracts, parsing, and rendering in Foundation-only
targets within the existing macOS Swift package where practical. Keep launch,
NetworkExtension, and AppKit adapters at their platform boundaries. Preserve
`CloudGatewayKit` APIs and iOS behavior. Host-free tests should not require an
app host, signing, a live Firebase session, or an activated tunnel extension.

### Accepted requests and observed status

- Validate the request and acquire controller ownership before acknowledging an
  operation ID. Send and flush the acceptance response before changing routes
- Separate `accepted` from the final command result. An acceptance response
  means the controller owns the work. It does not mean macOS accepted a start
- Detaching a client, Ctrl-C, a broken pipe, or a client deadline must not
  cancel an accepted VPN operation
- A successful `up` result means the start API returned without an immediate
  error, or the matching installed config was already active/connecting
- Print `VPN start requested` when a start was submitted. Keep observed status
  separate, since macOS notifications may lag by 30 seconds or more
- A failed stop during a switch prevents the replacement start. Preserve the
  current stop timeout and cleanup/commit safeguards
- `down` retains current confirmed-stop behavior. No active owned profile is
  an idempotent success
- Report immediate errors and later observed failures separately. Avoid
  converting a lagging observation into a false successful connection
- Retain only the active and latest sanitized command result in memory, with
  an operation ID. `status` can recover it after SSH reconnects
- Keep the latest result through a documented reconnect grace period before
  idle exit. Deduplicate transport retries by request ID within that lifetime.
  A lost response leaves the result uncertain, so inspect status before issuing
  another mutation rather than automatically repeating a request with a new ID
- Do not build a persistent per-user connection/operation history. Results
  expire on controller restart or replacement by a newer result. Report
  `operation_unknown`, then show current observed state
- Surviving SSH/frontend loss is required. Automatic replay after controller
  crash, OS termination, or reboot is outside v1. On restart, reconcile actual
  preferences, storage transactions, and auth state without replaying `up`
- Preserve account generation fencing. Logout/account changes can invalidate
  unauthorized pending work even though caller disconnection cannot
- Reject conflicting mutations with a stable busy error rather than silently
  dropping or reordering them. Keep status and local disconnect available
  during cloud requests, with serialized entry to actual VPN mutations

## CLI contract

These flags and output details define the initial implementation target.
Support flags before or after command words where unambiguous. Unknown flags,
extra positional arguments, and malformed IDs return usage errors.

### Common options

| Option | Behavior |
| --- | --- |
| `-h`, `--help` | Show help for the current command and exit successfully |
| `--json` | Emit the versioned JSON records described below, without terminal decoration or keyboard shortcuts |
| `--non-interactive` | Disable keyboard shortcuts/prompts even with a TTY. Device approval polling still works |
| `--timeout <seconds>` | Positive finite caller deadline. Default 30 seconds, except login uses the server's code expiry. Does not cancel accepted VPN work |
| `--version` | Root command: show app version/build and exit without starting the controller |

No implicit prompts when stdin or output is redirected. Honor `NO_COLOR`, avoid
ANSI cursor controls outside a suitable terminal, and keep displayed IDs
copyable. A supplied timeout can shorten login waiting, never extend code
validity. All controller calls and doctor probes also need bounded internal
timeouts. Caller deadlines and controller operation deadlines are separate.

Help must work without a controller, network, Keychain, or sign-in:

```text
cloudgateway
cloudgateway help
cloudgateway -h
cloudgateway --help
cloudgateway help auth login
cloudgateway auth login --help
```

### Command behavior and options

| Command | Options | Result |
| --- | --- | --- |
| `auth login` | `--no-qr` | Start the existing device approval flow, display its challenge, and wait for authorized sign-in |
| `auth status` | Common options | Report identity/session state, access verification state, and credential availability separately |
| `auth logout` | Common options | Sign out the shared controller session, fence pending account work, retain VPN/configs/cache |
| `list` | `--region <region-id>`, `--refresh` | Show authorized configs grouped by region. `--refresh` explicitly fetches before listing |
| `status` | `--operation <operation-id>` | Show observed local VPN state, pending request, and latest command result, or look up the retained operation |
| `up [config-id]` | Common options | Select/install an authorized existing config and request a start |
| `down` | Common options | Stop app-owned active/transitional profiles, including while signed out |
| `refresh` | Common options | Recheck authorization and fetch current cloud inventory/metadata |
| `doctor` | Common options | Inspect local setup, permissions where observable, auth, and network/service reachability |
| `help [command...]` | Common help/output options | Show usage, options, examples, and the meaning of request acceptance |

All commands accept the common options where applicable. `help --json` and
`--version --json` use the same versioned result envelope without IPC.
No `--yes`, password/token argument, config export, name-prefix selector,
numbered selector, or `--wait` in v1.

### IDs, inventory, and offline access

- `config-id` is the existing canonical `FirebaseUID/regionId/clientId`
  identifier. Emit it exactly in `list` and JSON. Names are display labels
- Validate the ID against the current account and authorized inventory.
  An opaque/composite ID is never proof of authorization
- Bare `up` uses this account's last selection. If missing, removed, or unusable,
  fail with a useful explanation and available choices. Do not choose arbitrarily
- Online `up` follows existing auth/access checks and config comparison rules.
  Install an uninstalled cloud config or replace a changed installed config
  before connecting. Persist selection through the account cache
- An unchanged active/connecting config is an idempotent `up`. If fresh
  inventory reveals changed contents, the next explicit `up` may replace and
  reconnect it using confirmed-stop sequencing
- Online `list` includes authorized cloud configs, including those not installed
  on this Mac. Show region/name, ID, assigned internal IP, cloud state, local
  installation state, and observed local tunnel state. Label unusable rows
- Plain `list` uses controller inventory and existing restoration behavior.
  Include freshness/source metadata. Do not promise a disk cache of all cloud
  configs, since the current persistent cache covers installed metadata only
- Offline `list` contains only this account's previously authorized installed
  metadata and labels its reduced scope. Offline `up` additionally requires a
  retained valid session, permitted cached role, and an available committed
  secret. Recreate a missing profile from authorized installed metadata
- Distinguish connectivity failures from confirmed denial/revocation. Denial,
  account changes, and role downgrades must preserve current cache invalidation
  rules. Never treat them as offline authorization
- `refresh` and `list --refresh` report network failure rather than claiming a
  fresh result. Retained data may be shown as stale with the failure recorded
- Refresh does not reinstall, stop, or restart a tunnel. Changed/removed cloud
  rows can affect eligibility for future `up` without disconnecting the current VPN
- Signed-out `list`/`up` require login. Signed-out `status`/`down` can inspect or
  stop owned local VPN state without exposing another account's inventory,
  cached client labels, internal IPs, or retained operation details
- `auth status` distinguishes signed out, retained identity, restoring/checking,
  online authorized, offline authorized, access denied, and credentials
  unavailable. Retained identity alone does not imply current product access

### Login interaction

- Reuse the existing request/poll/custom-token/product-access flow and its
  server-provided expiry, rate limits, and validated approval URL
- Print the link and user code immediately, with a locally generated terminal
  QR code encoding the validated approval link
- Poll in the controller while the interactive frontend accepts `c` to copy
  the approval link and `o` to open it in the default browser
- Do not automatically launch a browser in CLI mode. Keep automatic opening
  for the GUI flow. Separate the current coordinator's open callback from
  shared polling/state so the controller never initializes AppKit
- Over SSH, those shortcuts target the remote Mac's clipboard/browser. Failure
  reports a short hint and leaves polling running. Another device can use the
  displayed link, code, or QR
- Suppress QR/shortcuts for JSON, noninteractive mode, or unsuitable terminals.
  `--no-qr` hides only the QR. Always retain a readable link/code in human output
- Exit on successful authorized sign-in, denial, expiry, error, or Ctrl-C.
  Restore terminal input settings on every exit path
- Explicitly cancelling the login attempt cancels polling/exchange with the
  existing recovery safeguards. It does not log out an unrelated newer session
- Already signed-in login is an idempotent status result. Reject a second
  concurrent login attempt with a busy result rather than creating two exchanges
- Keep device secrets and Firebase/custom tokens out of output, logs, request
  arguments, and frontend IPC. The short-lived approval link/code are intentional
  login output, excluded from diagnostics and retained operation records

### JSON and exit codes

Use newline-delimited JSON records on stdout, one complete object per line.
Ordinary reads emit one final record. Login emits a `login_required` challenge
record before the final result. VPN mutations emit `accepted` with an operation
ID before any route change, then a final `result` or `error` when available.
This lets agents recover the operation even if the route change breaks SSH.

Every record has `schemaVersion: 1`, `type`, and `command`. Include `operationId`
for accepted VPN operations. Results have structured `data`, errors have
`error.code`, a sanitized `error.message`, and an optional actionable
`error.suggestion`. Use stable enum strings, explicit nulls for unavailable
fields, and UTC timestamps for observations/freshness. Distinguish requested
state, command result, and observed tunnel state.

No progress text, QR, ANSI escapes, or keyboard instructions on JSON stdout.
Human diagnostics go to stderr. Flush challenge/acceptance records immediately.
Document additive schema changes and keep existing fields/types stable within
version 1. Do not serialize SDK errors or WireGuard/provider dictionaries.

| Exit | Meaning |
| --- | --- |
| `0` | Command succeeded, including start request accepted, successful offline inventory, and status inspection of a signed-out/disconnected state |
| `1` | Unexpected internal failure |
| `2` | Usage, malformed argument, or unknown command |
| `3` | Sign-in required, authorization denied, or login approval denied |
| `4` | Setup, permissions, credential access, or version compatibility prevents the command |
| `5` | Config/selection missing or unusable |
| `6` | Network/service unavailable when a fresh online result is required |
| `7` | Another mutation/login owns the conflicting operation |
| `8` | Caller deadline, login expiry, or operation deadline exceeded |
| `9` | VPN/config operation failed |
| `10` | Requested operation result is unknown/expired |
| `130` | Caller interrupted |

Errors also expose a more specific stable string code. A status read returning
success does not mean the VPN is connected. `doctor` returns `4` for a required
local setup failure, otherwise `6` for failed required online checks, otherwise
`0`. Warnings/unknown optional checks alone do not fail doctor. Partial probe
results remain available if its overall deadline expires (`8`).

## Doctor

Report each check as `pass`, `warning`, `fail`, or `unknown`, with evidence and
a suggested fix. Inspect without activating an extension, saving preferences,
starting/stopping a VPN, signing in/out, or changing Settings. Starting the
on-demand controller and bounded network probes are allowed.

- Installed app location, bundle/resources, app/extension versions, OS/architecture
- CLI symlink target, executable availability, and this invocation's PATH
- Controller launch/handshake, protocol version, peer authentication
- Bundled/running extension compatibility and authenticated extension readiness
- Extension/VPN approval state where supported public APIs expose it
- Ability to load app-owned VPN preferences and validate profile metadata
- Firebase session/restoration state and credential-store access, with no secret dump
- Basic network path, DNS resolution, and HTTPS reachability to the configured
  CloudGateway services as separate checks with individual deadlines

An XPC failure alone cannot identify a specific Settings toggle. Unknown
permission state must say unknown. A successful preference read does not prove
write/start permission. A network path is not proof of Internet access, and
service reachability is not proof that tunnel traffic passes. Probes must not
inspect or record VPN destinations, DNS queries, packets, or user traffic.
Menu-app PATH is not evidence of what Terminal or a noninteractive SSH shell uses.

## CLI installation and release

- Add **Install Command Line Tool…** to the menu, available while signed out
- Require the app at `/Applications/CloudGateway.app`. Reject a mounted DMG,
  translocated copy, or development build location as the permanent link target
- Create `~/.local/bin` and the `cloudgateway` symlink without admin privileges
- Recognize the correct existing link. Report conflicting/broken links or files
  and offer a clear remedy without overwriting them automatically
- Offer a separate, explicit PATH update for the user's shell. For standard
  zsh login shells, add the directory to `~/.zprofile` once, preserving contents
  and avoiding duplicate entries. Explain unsupported/custom shell configuration
- Do not assume that login-shell configuration is read by noninteractive SSH.
  Always show the explicit path example `~/.local/bin/cloudgateway status`
- Replacing the app at the same path updates the CLI target automatically.
  Moving/removing it leaves a diagnosable broken installation
- Coordinate controller shutdown/update with accepted work and detect old
  running controller/new bundle mismatches. Do not silently mix versions
- Include service launch resources in the bundle's normal signing and
  verification. Keep the installed app bundle unchanged after signing
- Extend release verification for mode dispatch, controller resources,
  entitlements/profiles, and app/extension/controller compatibility
- Exercise CLI mode from a downloaded, notarized/stapled DMG installation with
  SIP and Gatekeeper enabled. An Xcode or unsigned result is insufficient

Follow [macOS release deployment](../docs/apple-macos-release.md). The existing
workflow signs/notarizes the app, then signs/notarizes the DMG. Do not copy an
entitled executable out of its bundle as a standalone installed CLI.

### Proposed update lifecycle

This handoff is not implemented yet. Replacing a bundle currently leaves a live
controller running until its normal idle exit.

- Ship menu, controller, and CLI modes in the same signed app. Keep the CLI
  symlink pointed at that installed bundle. Increment every distributed app
  build, and detect different local rebuilds even when version/build are reused
- Capture the running build identity at process startup. Compare it with the
  installed bundle using a signed build fingerprint, including from the running
  controller so drag-and-drop replacements are detected without a new client.
  Reading the replaced bundle's current Info.plist must not relabel old code
- Add a small authenticated lifecycle handshake separate from ordinary command
  version validation. Report the running and installed identities, protocol
  support, and update state even when normal commands are incompatible
- Treat the verified installed bundle as the update target. An old menu or CLI
  invocation must not switch the service back to its own older build
- On replacement, stop admitting new mutations, finish accepted work through
  safe profile/secret persistence points, retain recoverable command outcomes,
  then release ownership and exit. Clients reconnect to the launchd-started
  replacement. Do not replay an uncertain mutation after reconnect
- Keep active VPNs running through app/controller updates. Reconcile Apple VPN
  preferences after restart instead of stopping or starting a tunnel implicitly
- Keep extension versions independent. Each app release declares its expected
  extension and supported IPC. Use Apple's activation/replacement flow for
  changed extensions, represent approval/reboot requirements, and defer a
  disruptive replacement while a VPN is active. Incompatible extensions block
  new starts while safe status/disconnect operations remain available
- Show component identities and update state in CLI diagnostics. Validate live
  replacement during an active VPN, pending commands, stale clients, reused
  development build numbers, and extension approval/reboot states

## Tradeoffs and concerns

| Choice or concern | Benefit / risk | What to watch |
| --- | --- | --- |
| Single user controller | Shared auth/policy and independent command lifetime, with extra launch/IPC lifecycle work | Prove bootstrap context and singleton behavior before implementing the full CLI |
| Existing bundled executable | Reuses signing/profile/resource identity, but has several startup modes | Dispatch before AppKit/Firebase side effects and verify the notarized bundle |
| Firebase SDK reuse | Preserves current auth and recovery behavior | Data Protection Keychain availability depends on execution context |
| Root system extension stays narrow | Preserves storage and privilege separation | Do not move Firebase or cloud policy into the extension or relax UID/signature checks |
| Fast `up` | Matches existing UX despite delayed status notifications | API acceptance cannot establish connected state or working traffic |
| Authorized offline configs | Keeps existing VPN use possible during outages | Revocation is not observable offline. Preserve role/account isolation and invalidate on confirmed denial |
| Retained VPN after logout | Matches the selected behavior | Explain that logout is not disconnect and keep signed-out status output minimal |
| Refresh without reconnect | Avoids surprise route/SSH interruptions | Show stale/pending changes and apply only on explicit next `up` |
| User-local symlink | No installer privilege or extra signed binary | PATH differs by shell/session, app movement breaks the link |
| Caller-independent VPN work | Route changes do not abort accepted work | Cancellation semantics differ between login and VPN operations |
| Memory-only latest result | Supports SSH recovery without connection history | No crash/reboot replay guarantee or unbounded operation journal |
| Multiple macOS users | Preserves existing UID ownership | Per-user ownership does not itself serialize machine-wide VPN activity |

If the runtime proof fails, record the exact launch context and failing API.
Revisit shared auth storage/service architecture explicitly. A GUI-only broker
would reduce the selected SSH scope. A REST/token-store rewrite or root helper
would add scope. A second WireGuard implementation would create divergent VPN
state. None is an automatic fallback authorized by this plan.

## Implementation checklist

### 0. Extract services without disturbing the installed app

- [x] Extract a Foundation-only macOS controller with injected dependencies,
  sanitized snapshots, and explicit lifecycle, separate from menu presentation
- [x] Host it in the menu process for this structural checkpoint. This is not
  the background launch mechanism or proof of independent process lifetime
- [x] Move browser opening and Add Client dialogs into the menu client. Keep
  service tasks and account/session fencing inside the controller
- [x] Validate with host-free tests, dead-code scans, and builds, without
  launching another auth owner or changing the currently running VPN
- [x] Bump the app version independently. Change extension versions only when
  its binary or protocol changes require replacement
- [x] Review and commit logical checkpoints before the signed runtime session

On 2026-10-21, `./scripts/test.sh macos` passed with 112 macOS core/IPC tests,
both strict macOS dead-code scans, and the unsigned arm64 build/packaging checks.
Two Sol review rounds finished without remaining confirmed issues. The user
also passed `./scripts/test.sh macos --signed` over SSH after unlocking the login
Keychain in that session. The agent independently verified the resulting signed
Release bundle. Its separate remote session had reported the Keychain locked
and signing failed with `errSecInteractionNotAllowed`, surfaced by `codesign`
as `errSecInternalComponent`. Account for the security session when diagnosing
credential access. No new app/controller was launched, and the installed app,
profiles, Firebase session, and VPN were left intact. This does not establish
background-controller launch or Firebase Data Protection Keychain behavior.

The development machine currently runs the existing menu app and an active
VPN. Keep that installation, process, session, and profiles intact during
build-only validation. Plan the quit/replacement/profile cleanup checkpoint
with the user after the new code is built and reviewed. Do not treat this as
permission to remove every account's profiles or cached data.

The background-controller checkpoint passed `./scripts/test.sh macos` on
2026-10-21: 139 macOS host-free tests, both strict macOS Periphery scans, and
the unsigned arm64 app/extension build and packaging checks. Shared Kit/AppCore
and Firebase adapter tests passed too. Main and Secure Codex accounts split
implementation and review. Review fixes cover bounded launch/cancellation,
installed-path registration, bootstrap retry, activation feedback, display-text
normalization, and confirmed creation results. No installed app, launchd job,
Firebase session, profile, or active VPN was changed during validation.

The launch candidate uses `user/<uid>` with a fixed
`/Applications/CloudGateway.app/Contents/MacOS/CloudGateway` executable and
private plist/locks in `~/Library/Application Support/CloudGateway/macOS`.
Ownership precedes Firebase initialization. The menu polls authenticated XPC
and preserves accepted core work when it closes. After 60 seconds without
requests or pending work, the controller exits and can start on demand again.
This is code/build proof only. Signed launch, Keychain access, live menu/VPN
behavior, and pre-desktop SSH survival remain open. The CLI surface and its
acceptance/result recovery contract remain subsequent work.

The first signed menu launch on 2026-10-21 (app 1.1.0, build 4) crashed before
controller bootstrap. The crash report identified a MainActor assertion in
the XPC proxy error callback. Foundation's connection error, interruption,
and invalidation callbacks now explicitly use `@Sendable` so they can complete
the lock-protected pending reply on the XPC queue. A real-XPC regression uses
a unique nonexistent Mach service and retries with the same client; it
reproduced the same SIGTRAP before the fix. Reinstall and signed runtime
validation remain required. The existing system extension, credentials,
profiles, and installed app were unchanged while fixing the crash.
The follow-up `./scripts/test.sh macos --signed` passed all 140 macOS tests
and both strict Periphery scans, then failed signing the extension with
`errSecInternalComponent`. Repeat signed build/install from a session with
access to the signing private key; this run did not produce a validated
signed replacement app.
The follow-up unsigned `./scripts/test.sh macos` passed all checks, including
140 macOS tests, both strict Periphery scans, the arm64 app/extension build,
and bundle packaging verification.

The next signed menu launch stayed up but could not find its controller Mach
service. With the user's approval, read-only launchctl checks confirmed the job
was absent from both user and GUI domains. Retrying the generated plist in
`user/501` returned error 5. Adding `LimitLoadToSessionType = Background` to that
plist made the same bootstrap succeed; launchctl reported the signed controller
running as UID 501, PID 19906, with no exit. The launcher now generates that
session setting and its plist regression checks it. `ProcessType = Background`
alone controls resource limits and does not select a background session.
The user confirmed the menu recovered, proving the installed frontend reached
the background controller through authenticated XPC. Firebase credential access
and the pre-desktop SSH matrix still need confirmation. No VPN
connect/disconnect command was issued during diagnosis. Rebuild/reinstall the
app to preserve the generated-plist fix on future registrations.
The follow-up `./scripts/test.sh macos` passed all checks, including 140 macOS
tests, both strict Periphery scans, the unsigned arm64 app/extension build,
and bundle packaging verification.

The user's next connect/disconnect capture showed Apple confirming stop in
about 0.8 seconds. The menu could then show Working while a cloud inventory
refresh remained pending. The status now follows the observed VPN state,
including VPN off during pending commands or inventory work. Refreshing clients
appears on the Refresh row. Cloud transport failures still allow authorized
cached configs but no longer label the internet connection Offline.
Regression coverage holds an inventory refresh open while disconnect completes,
then checks both successful refresh and cached fallback. `./scripts/test.sh macos`
passed all checks, including 142 macOS tests, both strict Periphery scans,
the unsigned arm64 app/extension build, and bundle packaging verification.
Signed rebuild/reinstall and live menu confirmation remain required for this
status change.

The next reinstall capture again confirmed a fast stop, about 0.53 seconds,
followed later by a Firestore ping timeout. Process inspection showed controller
PID 19906 still running from 18:50, predating the installed fixed Release binary
built at 19:08. The installed executable matched the rebuilt Release app, but
replacing the bundle had left the old controller serving the new menu. The local
install instructions now require waiting for the controller to exit before
replacement, including when rebuilding with the same version/build.
When restart was authorized, the old controller and menu had already exited.
`launchctl kickstart` successfully started the installed controller as PID 38511;
launchd reported the previous exit code as 0. The menu was closed at this check.

The next report exposed a separate refresh gate: both menu eligibility and
controller admission rejected connections while inventory loaded. Cached
metadata also required an existing Apple profile, and Firestore server reads
had no app deadline. That capture covered about 23 seconds of XPC activity and
did not contain the refresh start or a Firestore completion.
Authorized connections now remain available during refresh. Selecting a config
cancels the competing read and fences its late cleanup. Previously fetched
in-memory configs remain installable, and authorized metadata can restore a
missing profile through its existing committed system secret. Cache denial and
missing secrets still prevent a start. Startup exposes cached configs before
the initial inventory read finishes. Menu openings reuse inventory for 30
seconds; explicit Refresh bypasses that interval. Access checks and parallel
server inventory queries each have 10-second deadlines. Query listeners ignore
cache-only snapshots and detach on completion, cancellation, or timeout.
The installed app and running processes were not changed for this fix.
`./scripts/test.sh macos` passed all checks, including 153 macOS tests, both
strict Periphery scans, the unsigned arm64 app/extension build, and bundle
packaging verification. Signed installation and live confirmation remain open.
The next installed Release binary matched the rebuilt app and contained the
new inventory deadline code, but controller PID 39831 was still running from
19:20, before the 19:34 build. The new capture contained another Firestore ping
timeout. Using the user's existing controller restart approval, a launchd
restart loaded the installed controller as PID 56664. The menu and packet
extension processes were retained. The README install command now refuses to
build or replace the bundle while an installed app/controller is running.
The user confirmed an installed config connects while Refreshing clients is
shown after the controller restart, providing live proof of the refresh fix.

Add Client still used the cached-inventory transport-failure flag as a creation
gate after refresh finished. It now allows retrying the dialog while signed in
and idle. Submission retains its fresh access check and account/context fences;
a denial signs out and clears cached authorization before any create request.
Successful creation and inventory reload clear the cached-only presentation
flag so newly created clients appear. Regression coverage checks successful
retry and access denial after an inventory transport failure. The installed app
and controller were not changed for this source fix.
`./scripts/test.sh macos` passed all checks, including 154 macOS tests, both
strict Periphery scans, the unsigned arm64 app/extension build, and bundle
packaging verification. Signed reinstall and live confirmation remain open.

Switching to a config with a missing Apple profile exposed a retained-secret
recovery gap. The 19:49 capture showed System Keychain access rejected for the
running extension, with no recorded NetworkExtension preferences error.
Read-only Security.framework checks confirmed the running extension was signed
with Developer ID Application while the retained item's ACL required Apple
Development. Both extension copies still reported 1.0.0 (2), so the version-only
readiness check could not identify this development signing mismatch.

Availability reads now classify missing or unreadable retained secrets as
unavailable. Missing-profile restoration shares the existing one-attempt
reinstall fallback, requiring this account's authorized online config. Cache
authorization stays outside that fallback; authorization, transport, timeout,
and cancellation errors do not trigger secret replacement. Old secrets remain
retained, and another active VPN is not stopped until installation finishes.
Fresh-install storage failures show a fixed secure-storage message instead of
suggesting that VPN preferences need refreshing. Signing identities should stay
consistent across builds, and extension updates need distinct build numbers.
Regression coverage includes both installed and missing target profiles,
missing and unreadable secrets, offline/authorization failures, and replacement
failure while another VPN stays connected. Signed reinstall and live switching
confirmation remain open.
`./scripts/test.sh macos` passed with 157 macOS tests, both strict Periphery
scans, the unsigned arm64 app/extension build, and bundle packaging verification.
Fresh Sol research confirmed the signing mismatch, and a separate patch review
reported no blockers. The running installation was not changed.

### 1. Signed runtime proof, before the full command surface

- [x] Add the minimum headless dispatch and launch harness inside the existing
  signed app bundle, preserving production identity/entitlements
- [ ] Record OS build, app/extension versions, signature/profile, launch mechanism,
  UID, session/bootstrap context, and sanitized results for reproducibility
- [ ] Perform one-time GUI setup, then reboot. Once macOS/SSH is available,
  connect before graphical desktop login and without launching the menu app
- [ ] Start the controller on demand as the owning user. Verify it survives the
  issuing SSH session ending, including the last SSH session
- [ ] Restore the existing Firebase session and prove Data Protection Keychain
  access. Distinguish inaccessible credentials from a truly signed-out state
- [ ] If manual login Keychain unlock is needed, document it without capturing
  the password. Independently prove that Firebase storage is accessible
- [ ] Reach authenticated extension XPC and obtain readiness/start authorization
  before the first post-reboot tunnel start
- [ ] Load GUI-created VPN profiles, save/reload when needed, start, observe,
  and stop without new desktop prompts in the intended runtime context
- [ ] Prove an accepted command finishes after frontend/SSH loss and that a
  later invocation can report its result/current state
- [ ] Race simultaneous GUI and SSH startup and prove only one auth/core owner
- [ ] Exercise locked/unlocked credentials, offline restoration, logout, and
  re-login. Repeat with the Developer ID/notarized distribution build
- [ ] Stop at this gate if launch context, Keychain, extension availability, or
  preference operations cannot satisfy the requirement. Document evidence

### 2. Extract the shared owner and frontend protocol

- [x] Move auth, access/offline policy, inventory, account cache/selection, config
  commands, and observation out of AppKit presentation code
- [x] Reuse existing domain protocols, Firebase adapter, device-code flow,
  config coordinator, and extension IPC instead of duplicating them
- [x] Implement authenticated/versioned/bounded controller IPC and shared snapshots
- [ ] Add request IDs, acceptance handoff, independent VPN tasks, busy handling,
  latest-result retrieval, restart reconciliation, and client reconnect behavior
- [x] Keep explicit account fencing and install commit/rollback recovery intact
- [x] Route all existing menu mutations, including Add Client, through the owner
- [ ] Preserve menu setup/update, browser auth, status, logout, quit, launch at
  login, offline behavior, and selection UX
- [ ] Finish the menu-through-background-controller runtime milestone before
  starting CLI commands. Quitting the menu must then detach only its client

### 3. CLI and diagnostics

- [ ] Implement the commands/options, canonical IDs, help, JSON schema, and exit codes
- [ ] Add login challenge output, QR, concurrent shortcuts/polling, expiry, and
  terminal cleanup. Keep headless polling independent of AppKit
- [ ] Implement doctor with supported signals, bounded probes, and honest unknowns
- [ ] Verify secret redaction and account-safe output in every error/status path

### 4. Install, package, and document

- [ ] Add the menu installer, conflict handling, explicit PATH offer, and shell guidance
- [ ] Extend bundle/release verification and controller version/update handling
- [ ] Update the macOS README, development runbook, and release instructions
  with controller ownership, CLI examples/options, SSH prerequisites, and recovery
- [ ] Review the deferred document for any remaining useful research before
  deciding separately whether to archive or remove it

### 5. Validation and release acceptance

- [ ] Add targeted host-free coverage for parsing/output, account and role
  isolation, offline policy, login cancellation, singleton races, command
  ownership, idempotency, switching, and IPC validation
- [x] Run `./scripts/test.sh macos`, then `./scripts/test.sh ios` if shared Apple
  code changes. Use `./scripts/test.sh apple` when both platforms need validation
- [x] Run `./scripts/test.sh macos --signed` for signing/profile checks
- [ ] Manually verify the signed runtime matrix: Terminal, local agent,
  noninteractive SSH, reboot before desktop login, desktop plus SSH, final SSH
  disconnect, lock/logout, sleep/wake, network loss, account switch, and app update
- [ ] Confirm stop timeout prevents replacement start, and delayed start status
  does not hold up a successful start-request response
- [ ] Confirm `refresh` changes inventory without reconnecting, logout retains VPN,
  signed-out `down` works, and unknown result IDs do not imply command failure
- [ ] Verify the installed notarized DMG path, menu CLI installation, PATH hints,
  symlink dispatch, approval QR, and doctor without changing VPN state

Automated checks cannot establish pre-desktop launch context or live VPN access.
Run disruptive reboot/SSH/VPN checks in a planned manual session with another
access path. Writing this plan does not run those operations or publish a release.

## Existing code to reuse

- [Entry point](../Frontend/Apple/macOS/CloudGateway/main.swift): currently starts AppKit immediately
- [Menu controller](../Frontend/Apple/macOS/CloudGateway/CloudGatewayMacAppController.swift): current auth, inventory, offline, selection, and command ownership
- [Device auth coordinator](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacBrowserAuthCoordinator.swift): request/poll/exchange/access flow, currently auto-opens the approval URL
- [Firebase exchange recovery](../Frontend/Apple/CloudGatewayFirebaseAdapter/Sources/CloudGatewayFirebaseAuthAdapter/CloudGatewayFirebaseCustomTokenSession.swift): shared unsettled-exchange marker and cancellation fencing
- [Inventory service](../Frontend/Apple/macOS/CloudGateway/CloudGatewayMacInventoryService.swift) and [account cache](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacAccountCache.swift): authorized cloud reads and installed metadata
- [Config coordinator](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacCore/CloudGatewayMacConfigCoordinator.swift): transaction recovery, process-local serialization, confirmed stops, and start grants
- [VPN adapter](../Frontend/Apple/macOS/CloudGateway/CloudGatewayMacVPNProfileAdapter.swift): preferences, start submission, confirmed stop, and status observation
- [Extension XPC](../Frontend/Apple/macOS/CloudGatewayMacCore/Sources/CloudGatewayMacIPC/CloudGatewayMacXPC.swift): exact signing identity, non-root UID, bounded secret operations, and readiness ping
- [Activation coordinator](../Frontend/Apple/macOS/CloudGateway/CloudGatewayExtensionActivationCoordinator.swift): explicit GUI activation/replacement and extension version checks

## Apple and Firebase references

Reviewed for the design on 2026-10-21. These describe constraints and related
failures, not proof that this app works over SSH. Forum examples using Personal
VPN or DNS proxies do not establish packet-tunnel support in another context.

- [Apple DTS: Running headless app as root for handling VPN and launching microservices](https://developer.apple.com/forums/thread/808699).
  DTS explains that Terminal and launchd daemon execution contexts differ and
  that context matters for Keychain/VPN design. The example uses Personal VPN.
  Apply the context lesson, not its root-process assumptions
- [Apple DTS: DNS Proxy network extension doesn't start even after saving preferences successfully](https://developer.apple.com/forums/thread/776759).
  The accepted answer identifies a Mach service/app-group mismatch and OS error
  paths that crashed instead of failing cleanly. Preserve matching app group,
  `NEMachServiceName`, entitlements, and provider metadata when packaging changes.
  This is a DNS-proxy case, not evidence of our headless packet-tunnel behavior
- [TN3137: On Mac keychain APIs and implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
  Data Protection Keychain requires a user login context. `security` primarily
  handles file-based keychains. Unlocking the login Keychain alone does not prove
  Firebase storage access, and matching UID/signature is not enough evidence.
  Keychain access-group entitlements also require an app-like bundle with an
  embedded provisioning profile. Packaging alone does not grant a user context
- [TN2083: Daemons and Agents](https://developer.apple.com/library/archive/technotes/tn2083/_index.html).
  Background, Aqua, and SSH/StandardIO contexts have different lifecycles and
  service visibility. This is archived guidance, so verify current macOS behavior
- [NETunnelProviderManager](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)
  and [NETunnelProviderSession](https://developer.apple.com/documentation/networkextension/netunnelprovidersession).
  Use the existing app-owned preferences/session APIs. Start submission and
  observed connected state remain different events
- [System Extensions](https://developer.apple.com/documentation/systemextensions).
  Keep installation/approval/replacement in the containing app's explicit setup
  path, separate from ordinary headless VPN commands
- [Firebase: cross-app authentication with shared Apple Keychain](https://firebase.google.com/docs/auth/ios/single-sign-on).
  Shared credentials do not update other consumers' live auth state in real time.
  One controller avoids separate GUI/CLI Firebase owners
- [Firebase SDK Keychain implementation used in the earlier research](https://github.com/firebase/firebase-ios-sdk/blob/fdc352fabaf5916e7faa1f96ad02b1957e93e5a5/FirebaseAuth/Sources/Swift/Storage/AuthKeychainServices.swift#L223-L234).
  The SDK selects Data Protection Keychain. Recheck the resolved dependency
  version during implementation rather than assuming its storage context changed

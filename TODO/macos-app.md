# macOS Menu Bar Implementation Plan

Status: implementation and automated validation are complete. The native menu,
packet-tunnel provider, browser auth, account-scoped offline inventory,
authenticated IPC, System Keychain storage, and launch-at-login composition
are implemented. Signed activation and live native VPN/auth checks remain
pending, so this is a stable WIP rather than a runtime-verified release.

The API and React device-auth flow is deployed. Live browser approval, Firebase
custom-token sign-in, authenticated API access, cross-region polling, and
dashboard anti-framing headers were verified on 2026-10-01 with the protocol
tools. Deployed Firestore rules and active TTL policies still need operator
verification. See the [device-auth runbook](../docs/device-auth.md).

The user is remote and deferred signed activation and live VPN checks until
they can handle macOS approval. Continue implementation and automated builds,
recording those runtime gates as pending. See the
[macOS development runbook](../docs/apple-macos-development.md).

Build a thin menu app and packet-tunnel system extension together. Prove the
signed tunnel before adding auth and daily-use inventory. Keep the UI plain.
Tests and docs land with each logical checkpoint, followed by review and cleanup.

## Scope And Decisions

| Item | v1 choice |
|---|---|
| Platform | Initial target: macOS 26, Apple silicon arm64 |
| Shared package floors | Keep existing iOS 17 and macOS 14 floors |
| GUI | `NSStatusItem`, `NSMenu`, `LSUIElement`, no dashboard window |
| Tunnel | `NEPacketTunnelProvider` packaged as a system extension |
| Auth | Default browser, deployed device-auth flow, Firebase custom-token session |
| Inventory | Authorized clients grouped by region, with online client creation |
| VPN | Select to install/connect/switch, top status row toggles off/last-used connection |
| Offline | Current account's previously authorized installed configs |
| Launch at Login | Optional, off initially, starts the app without connecting |
| Sign Out / Quit | Retain the running VPN, profiles, secrets, and cloud clients |
| Admin/account management and client deletion | Website or mobile app |
| Distribution | Eventual direct ZIP, Developer ID signing and notarization |

macOS 26 and arm64 are the initial implementation choice within the user's
accepted range. Revisit older OS or Intel support only for a concrete need.

No blackout detection, traffic probes, runtime-counter polling, automatic
blackout recovery, health snapshots, notifications, native provider login,
client deletion, dashboard, automatic VPN connection, updater, or release
hosting work. Keep normal WireGuard network-change and sleep/wake handling.
[CLI work remains deferred](macos-cli-deferred.md).

## Identifiers And Capabilities

| Purpose | Identifier |
|---|---|
| Menu app | `com.gocloudlaunch.gateway.macos` |
| Tunnel | `com.gocloudlaunch.gateway.tunnel.macos` |
| App Group, both targets | `group.com.gocloudlaunch.gateway.macos` |
| Mach service | `group.com.gocloudlaunch.gateway.macos.tunnel` |

The user registered the app IDs and group. Verify profile membership and actual
signed entitlements during checkpoint 1. The Mach service starts with the exact
App Group string, without a Team ID prepended to its `group.` value. Name the
extension bundle `com.gocloudlaunch.gateway.tunnel.macos.systemextension`.

| Capability | Menu app | Tunnel |
|---|---|---|
| App Groups | macOS group | Same macOS group |
| Network Extensions | Packet tunnel | Packet tunnel |
| System Extension installation | Yes | No |
| Keychain Sharing | Firebase session access group | No user-session sharing |
| Data Protection / Sign In with Apple | Omit | Omit |

Firebase documents Keychain Sharing for macOS session persistence. Use the
native app's configuration in the existing Firebase project. The tunnel has no
Firebase registration, configuration, or auth credentials. See
[Firebase Apple setup](https://firebase.google.com/docs/ios/setup).

Sign both targets with the same team. Apple Development signing uses
`packet-tunnel-provider`. Eventual Developer ID distribution uses
`packet-tunnel-provider-systemextension` with matching profiles. The containing
app is unsandboxed for direct distribution. Configure the extension sandbox,
required networking access, and Hardened Runtime for its target/channel.
Inspect built products rather than copying iOS entitlements. See
[Apple packaging guidance](https://developer.apple.com/forums/thread/800887)
and [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

## Architecture And Shared Core

```text
Frontend/Apple/macOS/CloudGateway.xcodeproj
    CloudGateway          menu, auth/session, inventory, activation,
                          VPN preferences, XPC client, launch at login
    CloudGatewayTunnel    entry point, XPC listener, System Keychain,
                          packet provider, WireGuardKit
```

Reuse Kit configuration parsing, models, selection, snapshots, provider
metadata, `CloudGatewayVPNManager`, and suitable lifecycle helpers. Reuse
AppCore HTTP/error/document mapping and session contracts where useful.
Do not compose the full iOS view model or require a Google presenter for Mac
auth. Neither Mac target compiles iOS sources.

Keep menu state/coordinators testable outside AppKit. Use AppCore for genuinely
platform-neutral additions. If macOS-only logic needs a separate host-free
test module, keep it under `Frontend/Apple/macOS/`. Choose the smallest layout
that supports tests and the target boundaries, without a new framework.

The shared config manager makes synchronous secret-store calls. Its concrete
Keychain store uses the user Data Protection Keychain on macOS, which a system
extension cannot access. Use a small macOS coordinator for asynchronous XPC
plus shared VPN/model APIs. Add a compatible shared seam only when needed.
Preserve existing iOS contracts/defaults and avoid blocking the menu thread.

The tunnel links Kit, the existing WireGuard fork/Go bridge, and necessary Apple
frameworks. It has no AppCore, Firebase, Google Sign-In, AppKit, SwiftUI, UIKit,
or User Notifications dependency. Keep WireGuardKit outside the shared package.
Extract common runtime code only when a second working consumer proves useful.
Do not port the iOS health-monitor composition.

## Storage And Account Boundaries

| Data | Owner |
|---|---|
| Firebase session | User app, Firebase SDK Keychain persistence |
| Pending device secret/custom token | App memory, discard when the flow ends |
| Inventory metadata, snapshots, last selection | User storage, per Firebase UID |
| Full configs/private keys | Extension-owned System Keychain |
| Installed profiles | Apple preferences, metadata and secret references only |

The system extension runs as root. Its App Group container differs from the
user app's container, and it cannot access the user's Data Protection Keychain.
Keep VPN secret operations in the extension and transfer installation material
through authenticated XPC in memory. See
[Apple storage and IPC guidance](https://developer.apple.com/forums/thread/800887).

Use a narrow XPC service with bounded typed messages for installing secrets,
checking availability, and necessary rollback/cleanup. The menu needs no
full-config readback API. Authenticate both ends through supported signed
peer-identity checks. Derive the caller's macOS user from the audit token,
not asserted UID, bundle ID, or group membership. Use the privileged Mach
service connection option. Bind opaque references to the installing macOS
user/config and reject other users' handles.

Firebase account filtering remains a containing-app and backend/rules boundary.
Admin product access does not authorize another macOS user's secret handles.
The extension does not become another Firebase auth service. Preserve secrets
across app quit, sign-out, and XPC disconnection.

Configure the Mac Firestore adapter for memory-only SDK caching. Persist an
explicit metadata-only offline cache, never raw documents containing
`wireGuardConfig`. Namespace cache and selection by Firebase UID. Keep full
configs out of files, VPN preferences, URLs, and logs. Offline fallback uses
only that account's previously authorized installed cache. Explicit access
denial must not become an offline transport fallback.

## Logical Implementation Checkpoints

### 1. Signed App And Extension Foundation

* Create macOS arm64 targets/schemes, separate entitlements, embedding, and
  dependencies. Start with a tiny Setup/Quit menu.
* Embed under `Contents/Library/SystemExtensions`. Use the system-extension
  `NetworkExtension` dictionary, packet-tunnel `NEProviderClasses` mapping,
  `NEMachServiceName`, and `NEProvider.startSystemExtensionMode()` entry point.
* Retain the activation delegate. Handle approval, failure, replacement,
  completion, and reboot-required results. Gate connection on readiness and
  show actionable setup guidance.
* Implement authenticated XPC and System Keychain storage. Verify persistence
  across app relaunch and extension replacement with an isolated test fixture.
* Add `macos` to `scripts/test.sh` now: host-free tests, Periphery, unsigned
  arm64 builds of both products, and a signed build option using the existing
  script convention. Add macOS to the default suite once targets exist.
  Automated checks never activate extensions or change the machine's VPN.

Gate: signed activation from `/Applications`, correct signed profiles and
entitlements, working secret storage/IPC, rejected unauthorized callers and
cross-user handles, and no DerivedData dependency after relocation. Unit tests
cover authorization and storage failures.

### 2. Working Packet Tunnel

* Add the provider and macOS arm64 WireGuardKit/Go bridge. Resolve an
  extension-owned secret reference and map through shared config models.
* Use the thin app to install and explicitly start/stop a controlled test
  config. Remove temporary fixture UI before completing the daily-use app.
* Preserve per-start identity, start/stop ordering, late-callback fencing,
  exactly-once completion, and bounded stop completion. Reuse suitable Kit
  helpers without importing blackout-monitor dependencies.
* Coordinate secret installation, profile save/reload, and snapshot persistence.
  Roll back new secrets after failed profile installation. Keep the old working
  reference until replacement succeeds. Surface partial persistence errors
  without deleting a secret referenced by a live profile.
* App quit and XPC invalidation never stop the provider. Clear session state
  on stop so repeated sessions work in one extension process.

Gate: TCP/IP, then DNS and UDP connectivity, repeated connect/stop, sleep/wake
and network changes, and VPN continuity after app quit/relaunch. Host-free
tests cover lifecycle races and installation failure/rollback with fake adapters.

### 3. Native Browser Authentication

* Register the macOS bundle ID as an Apple app in the existing Firebase project.
  Add its config only to the menu target and verify native custom-token sign-in
  and session persistence. Preserve the web key's restrictions. Do not spoof a
  dashboard Referer in the shipping app. Keep the existing SDK pin unless a
  concrete build failure requires a reviewed change.
* Add custom-token sign-in to the existing Firebase adapter through a small
  additive contract. Do not force iOS callers/test doubles to implement a new
  requirement on the existing broad auth protocol.
* Implement one pending attempt against the deployed
  [API contract](../docs/api-contract.md) and [protocol](../docs/device-auth.md).
  Generate 32 bytes with secure OS randomness. Send lowercase SHA-256 hex
  `deviceSecretHash` to `/api/device/code`, retaining the bytes in memory.
* Open the validated HTTPS `verificationUriComplete` on the configured
  dashboard origin. Show the six-digit code, preserving zeros, with Open
  Browser and Cancel actions. No callback URL or native provider login.
* Poll `/api/device/token` with the request ID and canonical unpadded base64url
  secret. Honor `interval`, lifetime, and 429 `Retry-After`. Use bounded HTTP
  requests and a recognizable app User-Agent.
* Handle denial, expiry, invalid/consumed requests, offline interruption,
  service failure, and cancellation. Exchange the custom token promptly with
  Firebase, discard it, and check product access. Fence late HTTP/Firebase
  completions so cancellation/sign-out cannot restore a session. A lost or
  consumed exchange needs a user-started new attempt. Cancel stops polling
  and leaves the request to expire.

Gate: deployed browser approval to native Firebase sign-in, session restoration,
and local sign-out without account-wide revocation. Deterministic tests cover
encoding, code zeros, timers/backoff, terminal states, unexpected approval URLs,
duplicate actions, cancellation, and late completion fencing.

### 4. Daily-Use Menu And Offline Inventory

* Fetch authorized clients and regions through existing Firestore/API contracts.
  Show other owners only with backend-authorized admin access. No client
  mutations, capacity polling, or admin pages.
* Compose the metadata-only cache and asynchronous config coordinator.
  Selection installs when needed and connects. Switching stops the current
  CloudGateway tunnel and waits for confirmed stop before starting the next.
  Stop timeout leaves the new tunnel unstarted. Do not stop unrelated VPNs.
* A user-requested connection may replace another account's retained
  CloudGateway tunnel with generic guidance revealing no hidden client details.
  Sign-in, refresh, and menu opening alone never change the running VPN.
* Show signed-out, setup-required, connecting, connected, disconnecting,
  offline, and error states. Provide a checkmarked top-row VPN toggle,
  region/client submenus, Refresh,
  Open Website, Sign Out, Quit, and optional Launch at Login.
* Observe Apple status events for app-owned managers. Refresh preferences
  asynchronously at launch, menu opening, preference changes, and commands.
  Keep the menu responsive and fence stale results.
* Derive a monochrome template glyph from `cloudgateway.svg`, with distinct
  off/on shapes. An active hidden tunnel may affect the icon, but exposes no
  hidden client name, region, owner, or config. Connected means Apple's status.
* Signed-out menus expose no configs or VPN controls. Sign-out cancels pending
  work and clears account presentation, retaining
  VPN, profiles, secrets, and account caches. Another account never inherits
  that inventory. Retained profiles remain in System Settings. Quit exits only
  the user app.
* Implement optional Launch at Login with `SMAppService`. Reflect actual
  status/required approval and never start a VPN automatically.

Gate: owned/admin inventory, account-isolated offline fallback, connect/switch/
toggle off/last-used reconnect, status changes through macOS controls, retained VPN after sign-out/
quit, and launch at login without connecting. Tests cover action availability,
account isolation, stale work, denial versus transport errors, and command order.

### 5. Final Integration And Docs

* Run `./scripts/test.sh apple` for both iOS and macOS, then the full
  `./scripts/test.sh` after integration. Existing iOS/shared tests, dead-code
  scans, and unsigned iOS build remain regression gates. No unrelated
  API/web/Firebase changes are expected.
* Complete signed macOS 26 arm64 checks: clean activation, delayed/denied
  approval, replacement/reboot, user isolation, repeated sessions, sleep/wake,
  network changes, offline use, and account/app lifecycle cases.
* Update the macOS README, affected shared-adapter docs, and test-script usage.
  Add a development runbook for `/Applications` setup, Firebase configuration,
  signed profile inspection, safe diagnostics, replacement, and manual checks.
* Review the integrated diff, remove dead code/spike UI, fix material findings,
  rerun affected checks, and record evidence and unresolved prerequisites.

Gate: working minimal app against deployed auth, signed tunnel validation,
passing automated checks, unchanged iOS behavior, and accurate docs.
Developer ID export, notarization, clean ZIP installation, and hosting remain
separate release work. A signed build alone does not prove activation/networking.

## Apple Traps And Prevention

Sources: [provider debugging](https://developer.apple.com/forums/thread/725805),
[Mach service mismatch](https://developer.apple.com/forums/thread/776759),
and [packaging guidance](https://developer.apple.com/forums/thread/800887).

| Trap | Prevention |
|---|---|
| Copying iOS metadata | System-extension dictionary, mapping, and entry point |
| Wrong location or missing activation | Correct embedding, GUI app in `/Applications`, retained delegate |
| Mach service/group mismatch | Exact group prefix, inspect signed entitlements/profiles |
| Preferences save mistaken for startup | Reload, start, verify provider startup and Apple status |
| Dependencies disappear after relocation | Static linkage or extension-embedded frameworks and correct runpaths |
| Old extension survives rebuild | Deliberate replacement/reactivation and version inspection |
| Root/user storage treated as shared | System Keychain, authenticated IPC, separate metadata cache |
| Fresh process assumed each connection | Session cleanup and late-callback fencing |
| Framework logs expose private data | Sanitized errors only, never forward raw WireGuard logs |

Keep SIP enabled. No kernel-extension approval, Reduced Security, privileged
helper daemon, or shell-based product activation. Use safe startup/activation/
error logs with a dedicated subsystem/category. Never log keys, configs, tokens,
codes, endpoints, traffic, DNS queries, packet metadata, counters, or per-user
connection history.

Status events are the default. Add low-frequency Apple-status reconciliation
only if signed testing proves missed events, without traffic probes. The mismatch
thread involves a DNS proxy, so apply its packaging lessons without assuming
every OS crash has that cause. Record sanitized errors and report OS crashes.

## Delegation, Review, And Commits

The main agent owns architecture, security boundaries, contracts, integration,
review, the index, and local commits when authorized. Use `gpt-6.1-sol` helpers
at high effort as requested, with bounded tasks and
file ownership. Helpers do not stage, commit, push, deploy, activate extensions,
or change the running VPN. Keep shared files under one owner.

Hold review until a logical checkpoint is complete. Review its diff/evidence,
delegate bounded fixes and cleanup, and use at most two review rounds per chunk
with affected validation. Use a Sol High review helper for substantial
XPC/Keychain, lifecycle, or auth changes when useful. Finish with an integrated
review across checkpoints.

Use checkpoints as logical local commits once commit permission exists. Split
large work only at a working/testable boundary. If signing or hardware blocks
progress, record the failed gate and use a clearly labeled stable WIP checkpoint
when authorized. Never claim unsigned builds or mocked IPC prove signed runtime
behavior. Planning does not authorize commits, deployment, pushes, or live VPN
changes.

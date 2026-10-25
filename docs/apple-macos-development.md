# macOS development

The menu app, `cloudgateway` CLI, and background controller share one signed
executable. The root packet-tunnel system extension runs separately. The app
targets macOS 26 on Apple silicon; shared Kit/AppCore deployment floors stay
unchanged.

* [CLI setup and reference](../Frontend/Apple/macOS/README.md#command-line-tool)
* [Local testing install](quick-deployment.md#install-macos-app-for-local-testing)
* [Developer ID releases](apple-macos-release.md)
* [Known issues](apple-known-issues.md)

## Validation

Run from the repository root:

```sh
./scripts/test.sh macos
./scripts/test.sh macos --signed
./scripts/test.sh apple
```

The macOS gate runs host-free core/IPC and installer fixtures, Python
verifier/release fixtures, strict Periphery scans, an unsigned arm64 build, and
bounded packaged CLI help/version/usage checks in temporary homes. `--signed`
also checks signatures, profiles, entitlements, and Hardened Runtime. `apple`
runs both platforms with shared tests once.

These checks do not install the app/CLI, edit real shell files, activate an
extension, or change the VPN. Keep the installed menu and VPN running during
validation; use a planned runtime session for replacement and live checks.
Signed runtime acceptance for the reviewed stack is recorded
[here](apple-macos-release.md#runtime-acceptance-2026-10-24).

## Controller and frontends

`CloudGatewayMacController` owns auth, account-scoped inventory, offline
metadata, VPN commands, and observed status in the Foundation-only macOS core.
The composition layer supplies Firebase, memory-only Firestore, preferences,
cache, and extension IPC adapters. The menu owns AppKit presentation, dialogs,
browser opening, activation, and optional launch at login. It does not reuse
the full iOS view model. Snapshots exclude full configs, tokens, and secret
references.

The private `--controller` entry point acquires a per-user ownership lock before
initializing Firebase. It runs through an on-demand launchd Mach service in
`user/<uid>`, using `/Applications/CloudGateway.app` and private files under
`~/Library/Application Support/CloudGateway/macOS`. Its plist requires
`LimitLoadToSessionType = Background`; `ProcessType` only controls resource limits.
Both XPC peers require the same non-root UID, signing identity/team, protocol,
app version/build, and captured CodeDirectory fingerprint. Never start a second
Firebase owner as a fallback.

Inventory refresh runs every minute for the first two minutes after activity,
then every five minutes until 15 minutes idle. Menu interactions and CLI
invocations count as activity; passive polls and a connected VPN do not.
Menu polling pauses at 15 minutes. The controller can exit once requests,
accepted work, extension work, and retained results allow it; the tunnel stays
connected independently. Sleep does not catch up missed refreshes.

Menu opening shows cached state and refreshes inventory older than 30 seconds.
CLI `list` waits for that refresh within its deadline. Explicit Refresh and
`list --refresh` fetch immediately, joining an existing fetch. Refresh never
reconnects the VPN. Access checks and parallel region/client reads have separate
10-second deadlines; only server snapshots count as fresh, and listeners detach
on completion, cancellation, or timeout.

Commands reserve an operation UUID before the frontend confirms acceptance.
Unconfirmed reservations expire after 30 seconds. Confirmed work belongs to the
controller after caller loss; an uncertain outcome never authorizes automatic
replay. Results remain available for ten minutes, subject to replacement or
restart. Request UUID/digest receipts persist for ten minutes, with at most 64
live entries. The [client-removal contract](../Frontend/Apple/macOS/README.md#controller-client-removal-contract)
details removal's separate result and cleanup rules.

Routing mode is account-local metadata with a legacy Full default. The Mac
extension resolves the canonical System Keychain config through the existing
single-use grant, then derives Full or Mesh only in memory. The canonical hash
and secret remain unchanged. A mode change uses the controller's confirmed
operation flow and reconnects the same authorized client after a confirmed stop.
The new start receives a fresh grant after stop and profile save/reload.

Applied mode comes from a bounded packet-provider reply containing only config
identity and mode after adapter startup succeeds. The selected preference is
separate. Missing or unreadable applied evidence remains unknown. Invalid mode
metadata rejects starts without hiding the profile or preventing local stop.
Combined CLI status adds auth from the same snapshot and retains the coarse
status/stop path for compatible older builds.

A five-second installed-bundle check detects verified replacements, closes new
mutation admission, drains accepted work, and exits without stopping the VPN.
Stale menus reopen the verified fixed app. Invalid/partial installations cannot
authorize handoff. Status and signed-out local disconnect remain available while
draining. Older controllers need a one-time restart on their first lifecycle
migration. Managed CLI update has its own durable operation recovery; see
[CLI updates](../Frontend/Apple/macOS/README.md#update-from-the-cli-or-ssh).

## Signing and installation

Both targets use the same team and macOS App Group:

| Resource | Identifier |
|---|---|
| App | `com.gocloudlaunch.gateway.macos` |
| Packet tunnel | `com.gocloudlaunch.gateway.tunnel.macos` |
| App group | `group.com.gocloudlaunch.gateway.macos` |
| Extension Mach service | `group.com.gocloudlaunch.gateway.macos.tunnel.<build>` |

Development profiles authorize `packet-tunnel-provider`; Developer ID profiles
authorize `packet-tunnel-provider-systemextension`. The app also needs System
Extension installation and Firebase Keychain Sharing. The extension needs App
Sandbox and network access, with no Firebase config/session access group.
Register the development Mac and install matching profiles before signed builds;
a certificate alone is insufficient. See [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

Install the signed app at `/Applications/CloudGateway.app`, keep SIP enabled,
and complete Setup VPN and Apple approvals in the GUI. See the
[local install command](quick-deployment.md#install-macos-app-for-local-testing).
Keep development and Developer ID installations separate to avoid Keychain
identity mismatches. Bump the synchronized app/extension build for every new
installation or release preparation, including signing/profile changes and
app-only releases.
The [release guide](apple-macos-release.md#version-and-artifact-policy) owns the
version and distributed-artifact policy.

Readiness requires an authenticated ping matching the embedded extension's
versions and signed identity. OS activation state or saved preferences alone do
not prove readiness. A mismatch blocks new connections while preserving status
and disconnect. `cloudgateway update` refuses changed extension code at reused
versions before stopping a VPN; doctor reports `extension_replacement_blocked`.
Use a higher build. The menu's explicit update action can replace a same-version
artifact only in System Extension developer mode.

Activation waits for all owned tunnels to be idle. Pending approval and reboot
requirements survive relaunch; a confirmed reboot requirement remains fenced
until a later boot. Late callbacks cannot reopen old attempts. Authenticated
readiness can reconcile an interrupted attempt unless macOS required a reboot.
An automatic attempt never disconnects a tunnel.

The extension belongs under `Contents/Library/SystemExtensions/` and must embed
or statically link its dependencies. It cannot rely on the app's Frameworks or
build directories. Its Info.plist needs `NSSystemExtensionUsageDescription`,
the packet provider, and a build-specific `NEMachServiceName`. Startup calls
`NEProvider.startSystemExtensionMode()` before the extra XPC listener.
See the [endpoint replacement issue](apple-known-issues.md#extension-replacement-loses-its-mach-endpoint-fb17032197).
Both Apple projects build the checked-in `wireguard-apple` submodule.

## Auth and inventory

The controller uses the native Firebase config bundled with the app. Browser
approval follows the [device-auth flow](device-auth.md): validate the full HTTPS
approval URL, preserve leading zeros in the code, keep secrets/tokens in memory,
and honor polling interval, lifetime, and `Retry-After`.

Firebase persists its session in the user's Keychain. Cancelled exchanges are
fenced; an unsettled-exchange marker forces cleanup after relaunch. Failed
cleanup hides the session until sign-out succeeds. Product access precedes
inventory. Sign-out remains available during failed restoration and retains the
VPN, profiles, committed secrets, and account caches.

Offline inventory and last selection are metadata-only and scoped to Firebase
UID and authorization role. Known denial blocks offline fallback. An admin-to-user
change clears admin inventory before fetching; failed invalidation signs out.
Role-less caches require an online refresh. Temporary token-verification outages
retain the session/cache without authorizing fresh inventory. Successful refresh
prunes removed clients and stale hashes.

Add Client preparation has a 20-second total budget with four concurrent
capacity reads; unresolved capacity stays unknown. Closing its frontend cancels
preparation without cancelling confirmed VPN work. Creation requires fresh access
and known capacity. Creation does not install
or connect; a failed refresh after success asks the user to refresh before retrying.
Removal requires fresh authorization and an inactive target, sends DELETE once,
and reports cloud success separately from local cleanup/refresh warnings.
Active or unobservable targets are retained. Another active client stays connected.

Connecting cancels a competing refresh and ignores its late result. Cached
metadata may restore a missing profile using its committed system secret.
A missing/unreadable secret permits one reinstall from an authorized in-memory
cloud config, preparing the replacement before stopping another VPN. Account
switching waits for cancellation and required installation cleanup. Failed
preferences reads retain the last observed status until a successful read.

## Secret storage and IPC

The root extension stores configs in the file-based System Keychain. The user's
Data Protection Keychain and App Group files are not shared with it. Authenticated
XPC verifies the exact peer target; the extension derives the user from OS
connection identity. No method returns a full config to the menu.

Installation creates a provisional opaque reference, saves/reloads the profile,
then commits the reference. Rollback requires proof that no profile uses it.
Ambiguous preferences, failed commit, or failed metadata persistence retain the
secret for recovery. Replacement retains prior committed secrets; sign-out,
quit, and IPC loss never delete them. Encoded writes use the same size bound as
reads so accepted records remain readable.

Start requires a short-lived, single-use in-memory grant bound to user, config,
and reference. The provider consumes it before reading the secret. Profile
owner fields do not authorize access. System Settings can stop and display a
VPN but cannot start it without the controller's grant.

Startup fails if WireGuard or network settings fail. An unconfirmed settings
call fences the adapter, including late callbacks, until a new provider instance.
Backend shutdown must finish before stop completion; a deadline alone cannot
permit a replacement tunnel. macOS does not enable traffic health monitoring,
automatic outage recovery, or notifications.

## Runtime checklist

Record build, macOS version, architecture, and sanitized pass/fail outcomes with
an isolated account/config. Never record keys, tokens, configs, approval codes,
addresses, traffic, DNS queries, or connection history.

1. Install from a browser-downloaded notarized DMG at `/Applications`; check
   Gatekeeper, approval/denial, replacement, and reboot with SIP enabled.
   Repeat with the build directory unavailable.
2. Connect, verify Apple's status and controlled TCP/IP, DNS, and UDP connectivity,
   then repeat start/stop, sleep/wake, and network changes. A stop timeout blocks
   replacement. Check wrong-target/unsigned and other-user IPC rejection.
3. Quit/relaunch and sign out while connected. The VPN stays on; signed-out
   status/disconnect work and inventory stays hidden. Check macOS status changes
   and Launch at Login without an automatic connection.
4. Exercise browser approval, cancellation, expiry, denial, token exchange,
   restoration, and cleanup. Verify offline inventory belongs only to the
   authorized account and role; known access denial cannot reveal cached clients.
5. Install the CLI while signed out. Check repeated installation, conflicts,
   PATH offers, JSON/exits, and explicit-path noninteractive SSH. Existing PATH
   entries must not cause startup-file changes. App replacement preserves the link.
6. Verify refresh leaves VPN state alone; logout retains it; doctor changes no
   auth/inventory/VPN state. Recover accepted commands by UUID after caller loss
   without replay. Restart/replacement may make ordinary results unknown.
7. With another access path available, check reboot before desktop login,
   pre-desktop SSH/Keychain access, final SSH disconnect, lock/logout, unavailable
   credentials, concurrent menu/SSH startup, and active-VPN app replacement.

The [2026-10-24 acceptance record](apple-macos-release.md#runtime-acceptance-2026-10-24)
covers the reviewed stack. Repeat relevant checks for later runtime changes and
releases. Builds alone do not establish activation, IPC, Keychain, or networking.

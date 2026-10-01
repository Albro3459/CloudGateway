# CloudGateway macOS

Future native macOS menu bar app and packet-tunnel system extension.

No macOS app or packet-tunnel targets exist yet. The plan of record is
[TODO/macos-app.md](../../../TODO/macos-app.md).

The containing app is an `LSUIElement` agent using `NSStatusItem` and `NSMenu`,
with no dashboard window. React owns provider sign-in and account management,
and the Python API owns the temporary device-auth exchange through Firestore.
The proposed approval page is `/#/auth/code`. Admin dashboards stay on the site
or mobile app. Small device-code and permission dialogs are allowed.

Each sign-in attempt generates a fresh 32-byte secret on the Mac using secure
OS randomness. Send its SHA-256 verifier when creating the API request and prove
possession of the secret during polling/exchange. Never bundle or reuse a device
secret, accept the verifier as a bearer credential, or persist pending secrets
beyond the flow. Proposed user-code defaults are six digits, five-minute expiry,
and three failed guesses per UID, with shared source creation limits and
per-request polling intervals. Approval requires the random request ID and code,
so codes can repeat. See the [device auth plan](../../../TODO/device-auth.md).

Import `CloudGatewayAppCore` for suitable Firebase-free contracts and API
workflows, and `CloudGatewayKit` for VPN/config APIs. Supply native menu state,
session/inventory, account-scoped cache, IPC, status, and identifier adapters.
Neither macOS target compiles iOS app sources. Aim for no iOS source or behavior
changes; preserve existing shared interfaces and defaults when adding seams.

macOS v1 has no blackout detection, health snapshots, automatic blackout recovery,
or notifications. It does not instantiate `CloudGatewayTunnelHealthMonitor`.
The shared detector and iOS notification behavior remain available to iOS.
Normal WireGuard network-change and sleep/wake handling still need validation.

## Menu App Dependency Boundary

| Workflow | Reusable product | Native macOS composition |
|---|---|---|
| Auth session | Suitable AppCore session contracts | Browser device flow and Firebase custom-token session adapter; no native provider login UI |
| Client inventory | Repository contracts and document mappers where suitable | Current account's authorized inventory, including backend-authorized admin access |
| APIs | `CloudGatewayControlPlaneClient`, DTOs, URL validation, error mapping, and bounded sessions | Inject the origin and finalize account-level device-auth routing |
| Menu state | Shared selection/config models | Minimal state outside AppKit; do not compose the full iOS view model unchanged |
| VPN/config | Kit VPN manager, config models, parser, selection, cache and secret contracts | Account-scoped offline inventory and extension-owned secrets accessed through IPC |
| VPN status | Kit status APIs over NetworkExtension | Observe Apple status events, refresh on menu opening, and update the template icon |

The shared config manager currently makes synchronous secret-store calls.
Asynchronous extension IPC needs a compatible shared seam or native composition.
Do not block the menu thread or change iOS storage contracts merely to fit macOS.

## Menu And Account Lifecycle

Observe `NEVPNStatusDidChange` for loaded app-owned managers and asynchronously
refresh Apple preferences/status at launch, on every menu opening, and after
commands. Keep refresh results generation-qualified and the menu responsive.
If signed validation demonstrates missed events, a low-frequency reconciliation
poll may read Apple status while the menu app runs. It must not probe traffic,
sample WireGuard counters, or implement blackout detection.

The icon reflects CloudGateway's Apple VPN status, including an active retained
tunnel outside the current inventory. It reveals no hidden client, region, or
owner. Connected does not guarantee traffic is passing. Do not inspect unrelated
VPN providers.

Disconnect retains local profiles/configs/secrets and cloud clients. Sign Out
ends the Firebase session and clears current account presentation, preserving
the running tunnel, installed profiles, secrets, and per-account caches. Quit
exits the menu app without stopping the tunnel. Fence pending user-app work so
late callbacks cannot restore signed-out inventory. Closing an XPC connection
must not stop the provider or delete secrets.

While signed out, show signed-out state, no configs, and no VPN controls,
including a generic Turn Off action. Users can control retained tunnels through
macOS settings. A new account must not inherit the previous account's visible
inventory or offline fallback. Namespace
caches and last selection by Firebase UID; show other owners only through
existing backend-authorized admin access. Do not delete hidden retained profiles
or merge them into the new account's menu. They remain in macOS System Settings.

Offer Launch at Login for the user-session app. It observes an existing tunnel;
automatic VPN connection remains outside v1. Direct ZIP distribution from GitHub
or the site is planned; hosting and release packaging are deferred. Final OS and
hardware support are selected during the signed spike. macOS 26 and Apple silicon
only are acceptable if useful, without raising the shared package's OS floors.

## System Extension Storage Boundary

Use the registered macOS identifiers and App Group from the plan. Both targets
claim the group, which is the exact prefix of `NEMachServiceName`. Provision both
and inspect the signed products. See [Apple's App Group guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

The system extension runs as root. Matching App Groups do not create a common
root/user directory or shared user Keychain. Full VPN configs belong in an
extension-owned System Keychain adapter. Installation transfers config material
through authenticated IPC in memory. Firebase credentials remain in the user
app. No full configs enter files, VPN preference dictionaries, or logs.

The plan's [storage and IPC section](../../../TODO/macos-app.md#macos-storage-and-ipc)
defines ownership and its [trap checklist](../../../TODO/macos-app.md#system-extension-traps-and-prevention)
defines signed validation. Authenticate XPC callers using signed identity and
audit token. Bind secret handles to the installing macOS user/config and reject
other users' handles. Account inventory filtering is a separate Firebase UID
boundary; admin product access does not authorize another macOS user's secrets.

Do not pass the concrete iOS Keychain store or App Group files to macOS unchanged.
Retain extension-owned secrets across app quit, sign-out, and IPC disconnection.
There is no health snapshot, notification bridge, or telemetry IPC.

## Packet-Tunnel Dependency Boundary

The extension links `CloudGatewayKit`, WireGuardKit, and needed Apple networking,
IPC, Security, and logging frameworks. It does not link AppCore, Firebase,
Google Sign-In, SwiftUI, UIKit, AppKit, or User Notifications.

The iOS provider is a reference for ordering and adapter roles. Reuse occurs
through named shared modules, not by compiling the iOS source directory.

| Boundary | Reuse / macOS ownership |
|---|---|
| Configuration | Shared WireGuard models/parser, provider metadata, and secret references; native System Keychain resolution |
| VPN preferences | Shared install/start/stop/status APIs with macOS identifiers |
| WireGuard runtime | Native adapter construction, config mapping, start/stop callbacks, and network-change handling |
| Start and stop | Suitable shared pending-start, joined-stop, and completion helpers; native bounded stop deadline |
| Storage and IPC | Authenticated secret installation/removal, isolated macOS-user handles, and persistent extension-owned secrets |

Each start attempt has an identity. Stop prevents pending starts from installing;
late or duplicate callbacks cannot alter a replacement session. Explicit stop
must complete once within a bounded deadline even when callbacks disappear.
System-extension processes outlive individual provider instances, so cleanup
must work across repeated sessions without relying on process exit. User-app
quit or sign-out is not a provider stop request.

Keep WireGuardKit outside the shared package. Extract common lifecycle or mapping
code only after the Mac implementation proves a second consumer needs it. No
macOS blackout-recovery or backend-restart API work is required for v1.

## Signed Validation

Verify on supported hardware and OS versions:

* WireGuard fork/Go bridge linkage and normal networking, sleep/wake, and
  Wi-Fi/Ethernet/DNS/gateway changes;
* activation/replacement from `/Applications`, profiles, Mach service prefix,
  relocated dependencies, and repeated provider sessions in one process;
* authenticated IPC, macOS-user isolation, and System Keychain secret retention;
* start/stop races, lost/late callbacks, and bounded explicit stop completion;
* VPN persistence after app quit/sign-out, and observation after relaunch;
* empty signed-out inventory, account/admin filtering, isolated offline caches,
  and icon/menu refresh after changes through macOS controls;
* launch at login without an automatic tunnel start;
* Developer ID notarization and a clean ZIP install with SIP enabled at release.

Simulator or package-test success does not establish signed extension parity.
Remaining work includes native targets, entitlements/profiles, menu/browser auth,
macOS storage/IPC, and signed hardware validation. None is implemented yet.

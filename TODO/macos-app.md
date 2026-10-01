# macOS App Plan

Status: planning. No macOS app, system extension, or device-auth endpoints exist
yet. This is the plan of record for macOS v1. Implement and deploy the separate
[device auth plan](device-auth.md) before starting macOS development.

A minimal menu bar app replaces the WireGuard app for daily use. It signs in
through the React site, lists clients by region, and installs, connects,
switches, and disconnects VPN configurations. The Python API handles the
browser-to-app authorization exchange. Account and client management stay on
the site. Admin dashboards stay on the site or mobile app.

A command line tool remains deferred. See [macos-cli-deferred.md](macos-cli-deferred.md).

## Decisions

| Decision | Choice |
|---|---|
| Distribution | Direct download ZIP from GitHub or the site, Developer ID and notarization at release; hosting and packaging deferred |
| Extension packaging | Network Extension packet tunnel packaged as a macOS system extension |
| Minimum OS / hardware | Choose during the signed spike; macOS 26 and Apple silicon only are acceptable if useful; shared package floors remain unchanged |
| Identifiers | Separate macOS app, extension, and App Group identifiers |
| Auth | React browser sign-in and approval, Python device-auth endpoints |
| Native session | Firebase custom-token sign-in behind the existing auth adapter, no native provider UI |
| Client inventory | Existing Firebase/Firestore model through a containing-app repository adapter |
| GUI | `NSStatusItem` and `NSMenu`, `LSUIElement` agent, no dashboard window or popover |
| Launch at login | Optional menu setting; automatic VPN connection remains outside v1 |
| Offline use | Retain installed configs and secrets, show only the current account's authorized cached inventory |
| Blackout detection / notifications | Outside macOS scope; existing iOS behavior remains unchanged |
| Sign out / quit | Preserve the running VPN, installed profiles, secrets, and cloud clients |
| Admin | React site or mobile app |
| CLI | Deferred |

Both extension packages use `NEPacketTunnelProvider`. iOS uses an app extension
(`.appex`). macOS will use a system extension (`.systemextension`). Apple supports
system-extension distribution through Developer ID or the Mac App Store, while
macOS packet-tunnel app extensions are App Store only. Packaging does not commit
us to an App Store release. See [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

## Scope

The menu owns sign-in progress, client selection, connection state, extension
setup, permission guidance, disconnect, sign-out, and quit. Small system dialogs
for a device code or an approval explanation are allowed. There is no normal
main window, native login form, account editor, client creation/deletion UI,
Server Health panel, or region administration.

Reuse existing Kit VPN/config protocols and AppCore workflows where they fit.
Do not assume the entire iOS view model or service facade must be composed
unchanged. Keep new menu state and device-auth logic testable outside AppKit.
Do not instantiate a tunnel-health monitor, add blackout detection or its
automatic recovery, request notification permission, or implement notification
delivery on macOS. Retain normal WireGuard network-change and sleep/wake
handling. Speculative CLI support remains deferred.

## Identifiers And Capabilities

The user confirmed these portal registrations. Provisioning and signed target
validation remain pending.

| Purpose | Identifier |
|---|---|
| App | `com.gocloudlaunch.gateway.macos` |
| System extension | `com.gocloudlaunch.gateway.tunnel.macos` |
| App Group, both macOS targets | `group.com.gocloudlaunch.gateway.macos` |
| Mach service | `group.com.gocloudlaunch.gateway.macos.tunnel` |

The Mach service begins with the exact App Group string. Do not prepend a Team
ID to this `group.` value, which would break the prefix match. App IDs, App
Group IDs, and Mach service names are different identifiers even when their
text overlaps.

Name the extension bundle
`com.gocloudlaunch.gateway.tunnel.macos.systemextension` to match its bundle ID.
Sign both targets with the same Team ID. See Apple's
[System Extensions requirements](https://developer.apple.com/documentation/systemextensions).

A separate macOS App Group is our choice, not an Apple requirement to separate
platforms. Both Mac targets claim the same macOS group. It does not synchronize
with iOS or make root and user storage the same directory.

| Capability | Menu app | System extension |
|---|---|---|
| App Groups | Yes, macOS group | Yes, same macOS group |
| Network Extensions | Yes, packet tunnel | Yes, packet tunnel |
| System Extension installation | Yes, `com.apple.developer.system-extension.install` | No, the container installs it |
| Data Protection | Omit | Omit |
| Sign In with Apple | Omit, provider login is on the site | Omit |

Do not copy the iOS `com.apple.developer.default-data-protection` setting,
including Protected Until First User Authentication, into native macOS
entitlements. It is not the VPN secret-storage solution. See Apple's
[Data Protection entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.default-data-protection).

Register the `group.` App Group and authorize membership in both targets'
profiles. Include the macOS application identifier and matching Team ID in the
signed products. Recheck profiles after changing capabilities. Apple recommends
`group.` identifiers for new macOS code. See
[App Group provisioning](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

Use `packet-tunnel-provider` for Apple Development signing. The Developer ID
release uses `packet-tunnel-provider-systemextension`. The selected profile must
authorize the value actually signed into each target. Configure the app's
[System Extension installation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install).

Keep platform entitlements separate. Configure sandbox/network access and
Hardened Runtime for the target and distribution channel, then inspect the built
products. Do not add unrelated iOS capabilities to silence signing errors.
The existing distribution plan uses an unsandboxed containing app.

## Targets And Shared Boundaries

```text
Frontend/Apple/macOS/CloudGateway.xcodeproj
    CloudGateway          menu bar agent, browser sign-in, client inventory,
                          VPN preferences, activation, IPC, launch at login
    CloudGatewayTunnel    system extension, NEPacketTunnelProvider,
                          WireGuardKit, VPN secret storage
```

The extension imports `CloudGatewayKit`, WireGuardKit, and needed Apple
frameworks. It does not link AppCore, Firebase, Google Sign-In, SwiftUI, or
AppKit. Neither macOS target compiles iOS app sources.

Reuse shared parsers, config models, selection, the VPN preferences wrapper,
and suitable start/stop ordering helpers. Supply macOS adapters for IPC,
storage, WireGuard runtime, and native lifecycle. See
[the macOS architecture notes](../Frontend/Apple/macOS/README.md).

Aim for no changes to iOS app sources or behavior. Shared-package additions must
preserve existing iOS contracts and defaults. The config manager currently uses
synchronous secret-store calls; resolve asynchronous extension IPC through a
compatible shared seam or macOS composition, not blocking IPC on the menu thread.
Do not migrate the iOS provider or view model merely to support the second app.

## Browser Auth

The [device auth implementation plan](device-auth.md) defines the Firebase,
API, React, test, and release contract. Implement that flow independently first.
The summary below records the future native client's responsibilities.

The React site retains Apple, Google, and email/password login. A browser device
flow avoids native provider UI and callback URL routing in the Mac app.

1. For each sign-in attempt, the app generates a fresh 32-byte device secret
   using the operating system's cryptographically secure random generator. It
   sends its SHA-256 verifier to proposed `POST /api/device/code` and receives a
   request ID, user code, verification URI, expiry, and polling interval.
2. It opens the React approval page and displays the user code in a small native
   dialog or menu action. The page requires explicit code confirmation.
3. The signed-in site calls proposed `POST /api/device/approve` with its Firebase
   ID token. The Python API checks identity and product access before approval.
4. The app polls proposed `POST /api/device/token` with the request ID and device
   secret in the HTTPS request body. The API hashes the secret and compares it
   with the verifier; the verifier itself is never a redemption credential.
   A successful, single-use exchange returns a Firebase custom token for the
   approved account.
5. The native auth adapter calls `signIn(withCustomToken:)` and supplies Firebase
   ID tokens to existing API clients. The SDK handles refresh and local session
   persistence. Firebase auth credentials stay in the user app, never the tunnel.

These endpoints are proposed, not implemented. The existing account-level
`api.<origin>/api/*` route will host them. Verify deployed routing during release.
The site uses `HashRouter`; the proposed approval route is `/#/auth/code`.
This is a device-flow design informed by RFC 8628 with a client-generated
redemption secret, not a claim of exact RFC wire compatibility.

### Temporary Request Storage

Use a top-level `DeviceAuthRequests` collection, one document per request. A
request begins before the Firebase user is known. Set `approvedUid` only after
authenticated approval; no empty user document, array, or seeded request is
needed. Concurrent requests have independent approval, expiry, and consumption.

Proposed fields include device/user code verifiers, `createdAt`, `expiresAt`,
state (pending, approved, denied, consumed), and the approving Firebase UID.
The Mac generates a cryptographically random device secret with 256 bits for
each attempt; it is never bundled, hard-coded, derived from a device identifier,
or reused as a permanent installation credential. Keep it in app memory only
for the pending flow and discard it after success, cancellation, expiry, or quit.
Store only its SHA-256 verifier in Firestore. A plain hash needs no private key
or shared API secret. Do not accept the verifier in place of the device secret.
Keep the short displayed user code separate from the device secret. Approval
requires the random request ID and matching code. The code cannot redeem a
session. Finite validity, explicit confirmation, and shared failed-guess limits
remain required. Codes may repeat across different request IDs.

Proposed initial defaults are a uniformly random six-digit user code, a
five-minute request lifetime, and three failed approval-code attempts per
authenticated Firebase UID in a rolling five-minute window. Preserve leading
zeros by treating codes as strings. Enforce shared source creation limits and
per-request polling intervals across API instances. Changing a code, request ID,
or API replica must not reset an actor's guess budget. Successful approval
requires authenticated product access and
explicit confirmation. Expiry is measured from creation and is not extended by
polling or failed guesses.

Six digits and these limits are product defaults, not a universal device-flow
standard. Scope approval links to a random request ID plus the matching code.
There is no code-only lookup, globally unique code reservation, or live-code
allocation budget. See the [device auth plan](device-auth.md) for the contract.

Use unkeyed SHA-256 verifiers for this flow. No new shared hashing key or
Terraform secret distribution is required. Firebase custom-token signing uses
the Admin SDK's signing credentials and is separate from request-code hashing.

Store `expiresAt` as a Firestore timestamp and return `expiresIn` in seconds to
the app. The API checks server-side expiry on approval and exchange. Firestore
TTL provides eventual cleanup, typically within 24 hours, not immediate expiry
enforcement. See [Firestore TTL](https://firebase.google.com/docs/firestore/ttl).

Only the Python API accesses request documents. React approves through the API
using its Firebase ID token; the Mac polls using its device secret. Approval and
single-use consumption must be transactional and account-bound across API
instances. Update Firebase schema, rules, required indexes, and TTL setup docs
when implementing the collection. Firebase Auth still owns provider sign-in and
the resulting session; our API owns this temporary authorization flow.

Keep expiry, denied/expired states, polling backoff, cancellation, and sign-out
fencing explicit. Generate high-entropy device codes, store only verifiers where
possible, rate-limit user-code attempts, atomically consume approvals, and reject
replays. Firestore TTL cleanup is not the authorization expiry check. Never
auto-approve a prefilled link or put bearer credentials in URLs or logs. See
[RFC 8628](https://www.rfc-editor.org/rfc/rfc8628).

The native Firebase SDK remains a session/inventory adapter, not a second login
UI. No Apple or Google credential presenter is added. Add the custom-token seam
and device-flow state behind shared contracts only where needed. Local sign-out
must not call account-wide `revoke_refresh_tokens` and sign out every device.

## Menu

* Show signed-out, setup-required, connecting, connected, and error states.
* Provide Sign In and an explicit device-code/progress action while pending.
* List authorized clients in region submenus only while signed in. Selecting one
  installs its config when needed; explicit switches preserve stop-before-start
  ordering.
* Provide VPN turn-off controls, Refresh, Open Website, Sign Out, Quit, and an
  optional Launch at Login setting.
* Open the site for account/client management. Do not reproduce its dashboard.

Use normal menu behavior on both mouse buttons. A hidden right-click toggle is
outside v1. Persist the last client in user app preferences, not in a supposed
root/user shared `UserDefaults` suite.

Derive a monochrome template glyph from `cloudgateway.svg` for light/dark menu
bars. Use separate off/on shapes and clear textual state. The full-color asset
remains the app icon source.

Refresh VPN preferences/status from Apple at launch, every menu opening, and
after a VPN command. Observe `NEVPNStatusDidChange` for every loaded app-owned
manager so the icon tracks changes made through macOS controls, including a
retained tunnel outside the visible account inventory. Keep refresh asynchronous
and fence stale results; opening the menu must not block on network or IPC. Use
the last known state while refreshing and show unavailable state after failure.
If signed validation reveals missed events, add a low-frequency status-only
reconciliation poll while the menu app runs. This reads Apple VPN state and does
not probe traffic, sample WireGuard counters, or detect a blackout. See
[Apple's status notification](https://developer.apple.com/documentation/networkextension/nevpnstatusdidchangenotification).

The icon may report that a CloudGateway VPN is active without exposing a hidden
client name, region, owner, or config. Connected means Apple's VPN status, not a
guarantee that traffic is passing. Restrict status inspection to this app's
provider, not unrelated VPN products.

Disconnect keeps local profiles, configs, secrets, and cloud clients. Sign Out
ends the local Firebase session and clears current account presentation without
stopping the tunnel or deleting installed profiles, secrets, or per-account
caches. Quit exits only the user app and leaves the VPN running. Fence pending
auth, inventory, and install work so late completions cannot repopulate a
signed-out menu. App shutdown and XPC invalidation must not call tunnel stop.
Only explicit user VPN commands or macOS VPN controls change the running tunnel.

Signed-out menus show signed-out state, no configs, and no global turn-off or
other VPN controls. Users can stop retained tunnels through macOS controls.
A different signed-in account sees only its own authorized inventory and cached
configs. Admins may see other owners through existing backend-authorized admin
access; a local role
flag or a retained macOS profile does not grant account access. Namespace caches
and last selection by Firebase UID, and never merge all installed profiles into
a new account's menu. Switching accounts must not delete hidden profiles or
their secrets. They remain visible in macOS System Settings, as intended.

Offline fallback uses only the current account's prior authorized cache. Do not
use another account's cache when network access or role checks fail. Retained
configs are never listed while signed out. Launch at Login starts the menu app
in the user session and observes existing VPN state; it does not start a new
tunnel.

## macOS Storage And IPC

The iOS shared App Group files and user Keychain cannot be carried over by
changing identifier strings. The system extension runs as root, with a different
group container and no user Data Protection Keychain access. VPN secrets belong
in extension-owned System Keychain storage. Config installation uses IPC.
See [Apple's packaging guidance](https://developer.apple.com/forums/thread/800887).

| Data | Owner / route |
|---|---|
| Firebase session | User app auth adapter |
| Inventory cache and last client | User app storage, namespaced by Firebase UID |
| VPN private keys and full configs | System extension secret-store adapter |
| VPN preferences | Kit wrapper over NetworkExtension preferences |
| VPN status for menu/icon | Apple NetworkExtension preferences and status events |

Use a narrow authenticated XPC interface for config secret operations.
Authorize callers from signed identity and audit token, not an
asserted bundle ID or App Group membership. Bind secret handles and mutations
to their owning user/config. Reject other users' handles. Do not expose arbitrary
filesystem, shell, or Keychain operations.

The app must not open the root App Group directory directly. Keep full configs
out of files and VPN preference dictionaries. Config material may cross
authenticated IPC in memory for installation, never through logs. Preserve
extension-owned secrets across containing-app quit, sign-out, and XPC client
disconnection. Firebase-account menu filtering and macOS-user IPC authorization
are separate boundaries; admin account access does not grant access to another
macOS user's secret handles. There is no health snapshot or notification IPC.

## System Extension Traps And Prevention

Sources: Apple's [debugging guide](https://developer.apple.com/forums/thread/725805),
the [Mach service mismatch thread](https://developer.apple.com/forums/thread/776759),
and [packaging guidance](https://developer.apple.com/forums/thread/800887).

| Trap | Prevention / evidence |
|---|---|
| Wrong metadata | Use a system-extension `NetworkExtension` dictionary, `NEProviderClasses` packet-tunnel mapping, and `NEProvider.startSystemExtensionMode()` entry point. Do not copy the iOS `NSExtension` dictionary. |
| Wrong installation path | Embed under `Contents/Library/SystemExtensions`, install and run the GUI app from `/Applications`. Point Xcode's run executable there too. |
| Activation never completes | Retain the activation manager/delegate. Handle approval, failure, replacement, completion, and reboot-required results. Connect only after readiness is established. |
| Invalid Mach service | Match `NEMachServiceName` to the exact entitled App Group prefix. Inspect signed entitlements and embedded profiles, not just source plists. |
| Preferences save mistaken for startup | Reload preferences, start the session, and verify provider startup plus connection state separately. |
| Old extension after rebuild | Stop the tunnel and deliberately replace/reactivate the extension. Inspect installed versions and lifecycle state. |
| New process assumed on every connection | Clear per-session state on stop and reject late callbacks across restart cycles. |
| Dependencies lost after activation | Statically link suitable package code or embed dynamic frameworks inside the system extension with correct runpaths. |
| Root/user storage confused | Implement the storage/IPC boundary above before an end-to-end connection. |

Add safe startup logs in the extension entry point and provider lifecycle, with a
dedicated subsystem/category. Log activation and sanitized error codes, never
configs, keys, tokens, runtime traffic counters, DNS queries, endpoints, packet
metadata, or connection history. Use Console and installed-extension state to
distinguish registration, activation, provider startup, and connection.

The second thread confirmed a group/Mach mismatch and exposed OS crashes while
reporting validation errors. Do not assume every similar crash has that cause or
that it remains fixed on every supported OS. Check sanitized system logs/crash
reports and submit an Apple report if the OS crashes.

Keep SIP enabled. No kernel-extension approval or Reduced Security boot policy
is needed. `systemextensionsctl` is a development aid, not a product installation
API. Do not install diagnostic profiles that collect private traffic data as
part of normal validation.

Preserve pending-start fencing, joined start/stop cleanup, and bounded physical
stop completion for explicit VPN commands. Validate normal WireGuard network
changes and sleep/wake independently of the excluded health monitor. No work
to expose a blackout-triggered backend restart is required for macOS v1.

## Phases And Validation Gates

| Phase | Work and required evidence |
|---|---|
| 0 | IDs/group registered, per user confirmation. Verify capability/group assignment in the signed products, configure development profiles, and confirm Developer ID release profiles. A new distribution certificate is not assumed merely because bundle IDs are new. |
| 1 | Complete the separate [device auth plan](device-auth.md): Firebase, Python API, React approval, tests through `test.sh`, and docs. Deploy and verify the flow with a test device client before macOS development. No native auth adapter is needed for this gate. |
| 2 | Minimal signed app/system-extension spike: WireGuard Go bridge on macOS arm64, activation, metadata, Mach service, authenticated XPC, System Keychain, repeated sessions without the app. This gates storage reuse and the OS/hardware support choice before full app composition. |
| 3 | Compose native device-flow state and the custom-token auth adapter against the deployed contract. Complete the menu bar target, account-scoped inventory/cache, template icons, offline state, launch at login, Apple status observation and refresh. No native provider/admin UI. |
| 4 | Install/connect/switch/disconnect, normal path changes, signed-out/account-switch visibility, retained profiles/secrets, and quit without disconnect. No blackout monitor or notifications. |
| 5 | Add a `macos` target to `./scripts/test.sh`, Periphery coverage, operational docs. Developer ID/notarized ZIP release and hosting are later work. The target does not exist yet. |

Pure package tests and unsigned compile checks need no registered macOS IDs.
Signed VPN integration requires real identifiers, capabilities, and development
provisioning. Distribution signing and notarization are release work. Use the
repo test entry point when implementation lands. This docs-only update needs
manual review, not builds or tests.

On signed hardware, cover the chosen minimum OS and each later supported major
version, including macOS 15+ App Group authorization behavior. Raising the app's
minimum does not raise the shared package's macOS or iOS floors. Validate:

* clean activation, denied/delayed approval, upgrade/replacement, and reboot;
* both embedded profiles, actual entitlement values, and group/Mach prefix;
* user/root isolation, rejected unauthorized XPC callers, and secret handles;
* provider availability after relocation, with no dependency on DerivedData;
* repeated connect/stop/switch cycles in one extension process;
* sleep/wake, Wi-Fi/Ethernet changes, DNS/gateway changes, and late callbacks;
* sign-out and quit leave the VPN running and profiles/secrets intact;
* signed-out menus expose no configs or VPN controls; account switching and
  offline caches do not expose another account's inventory; admin visibility
  follows backend ACLs;
* icon/menu status follows macOS controls, including hidden retained tunnels;
* offline installed configs, launch at login, and explicit bounded disconnect;
* a notarized Developer ID install on a clean Mac with SIP enabled.

Start basic connectivity checks with a controlled TCP/IP request, then DNS and
UDP, before complex browser behavior. Do not record user traffic. Unit tests and
simulator behavior do not establish signed extension parity.

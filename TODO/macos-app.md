# macOS App Plan

Status: planning. No macOS app, system extension, or device-auth endpoints exist
yet. This is the plan of record for macOS v1.

A minimal menu bar app replaces the WireGuard app for daily use. It signs in
through the React site, lists clients by region, and installs, connects,
switches, and disconnects VPN configurations. The Python API handles the
browser-to-app authorization exchange. Account and client management stay on
the site. Admin dashboards stay on the site or mobile app.

A command line tool remains deferred. See [macos-cli-deferred.md](macos-cli-deferred.md).

## Decisions

| Decision | Choice |
|---|---|
| Distribution | Developer ID, notarized, DMG, retaining the existing release plan |
| Extension packaging | Network Extension packet tunnel packaged as a macOS system extension |
| Minimum OS | macOS 14, matching the shared package floor |
| Identifiers | Separate macOS app, extension, and App Group identifiers |
| Auth | React browser sign-in and approval, Python device-auth endpoints |
| Native session | Firebase custom-token sign-in behind the existing auth adapter, no native provider UI |
| Client inventory | Existing Firebase/Firestore model through a containing-app repository adapter |
| GUI | `NSStatusItem` and `NSMenu`, `LSUIElement` agent, no dashboard window or popover |
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
Do not add a second tunnel-health detector or speculative CLI support.

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
                          VPN preferences, activation, IPC, notifications
    CloudGatewayTunnel    system extension, NEPacketTunnelProvider,
                          WireGuardKit, health monitor, VPN secret storage
```

The extension imports `CloudGatewayKit`, WireGuardKit, and needed Apple
frameworks. It does not link AppCore, Firebase, Google Sign-In, SwiftUI, or
AppKit. Neither macOS target compiles iOS app sources.

Reuse shared parsers, config models, the VPN preferences wrapper, health monitor,
ordering policies, runtime contracts, and callback fences. Supply macOS adapters
for IPC, storage, notifications, WireGuard runtime, and native lifecycle. See
[the macOS architecture notes](../Frontend/Apple/macOS/README.md).

## Browser Auth

The React site retains Apple, Google, and email/password login. A browser device
flow avoids native provider UI and callback URL routing in the Mac app.

1. The app requests a proposed `POST /api/device/code` endpoint and receives a
   device code, user code, verification URI, expiry, and polling interval.
2. It opens the React approval page and displays the user code in a small native
   dialog or menu action. The page requires explicit code confirmation.
3. The signed-in site calls proposed `POST /api/device/approve` with its Firebase
   ID token. The Python API checks identity and product access before approval.
4. The app polls proposed `POST /api/device/token`. A successful, single-use
   exchange returns a Firebase custom token for the approved account.
5. The native auth adapter calls `signIn(withCustomToken:)` and supplies Firebase
   ID tokens to existing API clients. The SDK handles refresh and local session
   persistence. Firebase auth credentials stay in the user app, never the tunnel.

These endpoints are proposed, not implemented. Confirm routing in the deployed
account-level API rather than assuming an apex API deployment already exists.
The site uses `HashRouter`, so its route is `/#/device`.

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
* List clients in region submenus. Selecting one installs its config when needed
  and performs the existing stop-before-start switch sequence.
* Provide Disconnect, Refresh, Open Website, Sign Out, and Disconnect and Quit.
* Open the site for account/client management. Do not reproduce its dashboard.

Use normal menu behavior on both mouse buttons. A hidden right-click toggle is
outside v1. Persist the last client in user app preferences, not in a supposed
root/user shared `UserDefaults` suite.

Derive a monochrome template glyph from `cloudgateway.svg` for light/dark menu
bars. Use separate off/on shapes and clear textual state. The full-color asset
remains the app icon source.

Observe `NEVPNStatusDidChange` and reread preferences when state changes outside
the app. Menu opening must not block on network or IPC. Cache the most recent
safe state and show unavailable/stale state when appropriate.

Sign Out and Disconnect and Quit drain or fence in-flight work and request a
bounded tunnel stop. Signing out also clears the local auth session and private
app inventory cache. Define config/secret removal separately from cloud client
deletion, and do not delete cloud clients during local sign-out.

## macOS Storage And IPC

The iOS shared App Group files and user Keychain cannot be carried over by
changing identifier strings. The system extension runs as root, with a different
group container and no user Data Protection Keychain access. VPN secrets belong
in extension-owned System Keychain storage. Health/config transfer uses IPC.
See [Apple's packaging guidance](https://developer.apple.com/forums/thread/800887).

| Data | Owner / route |
|---|---|
| Firebase session | User app auth adapter |
| Inventory cache and last client | User app storage |
| VPN private keys and full configs | System extension secret-store adapter |
| VPN preferences | Kit wrapper over NetworkExtension preferences |
| Outward health state | Extension-owned snapshot, returned through IPC |
| Notifications | User-session menu app, consuming safe health events |

Use a narrow authenticated XPC interface for config installation/removal and
health state. Authorize callers from signed identity and audit token, not an
asserted bundle ID or App Group membership. Bind secret handles and mutations
to their owning user/config. Reject other users' handles. Do not expose arbitrary
filesystem, shell, or Keychain operations.

Persist only the safe current health snapshot on the extension side. The app
must not open the root App Group directory directly. Keep full configs out of
files, VPN preference dictionaries, and health messages. Config material may
cross authenticated IPC in memory for installation, never through logs.

Notification delivery from the user-session app needs signed validation. Shared
health detection continues without the app. Do not promise visible notifications
when the menu process is absent. Validate missed-event reconciliation when it
returns, without adding connection history or traffic telemetry.

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

Backend restart remains unsupported in the pinned WireGuard macOS API until
separately implemented and tested. Preserve shared bounded recovery, callback
fences, joined stop, path generations, and the five-second stop deadline.

## Phases And Validation Gates

| Phase | Work and required evidence |
|---|---|
| 0 | IDs/group registered, per user confirmation. Verify capability/group assignment in the signed products, configure development profiles, and confirm Developer ID release profiles. A new distribution certificate is not assumed merely because bundle IDs are new. |
| 1 | Python device-auth endpoints and React approval page, custom-token seam and pure device-flow state. Verify expiry, denial, rate limiting, replay, and account binding. |
| 2 | Menu bar target, browser sign-in, inventory, template icons, offline state. No native provider/admin UI. |
| 3 | Signed system-extension spike: WireGuard Go bridge on macOS arm64, activation, metadata, Mach service, authenticated XPC, System Keychain, safe health events. This gates storage reuse. |
| 4 | Install/connect/switch/disconnect, health/recovery adapters, notification reconciliation, sign-out and quit. |
| 5 | Add a `macos` target to `./scripts/test.sh`, Periphery coverage, notarization/DMG workflow, operational docs. The target does not exist yet. |

Pure package tests and unsigned compile checks need no registered macOS IDs.
Signed VPN integration requires real identifiers, capabilities, and development
provisioning. Distribution signing and notarization are release work. Use the
repo test entry point when implementation lands. This docs-only update needs
manual review, not builds or tests.

On signed hardware, cover macOS 14 and each later supported major version,
especially macOS 15+ App Group authorization changes. Validate:

* clean activation, denied/delayed approval, upgrade/replacement, and reboot;
* both embedded profiles, actual entitlement values, and group/Mach prefix;
* user/root isolation, rejected unauthorized XPC callers, and secret handles;
* provider availability after relocation, with no dependency on DerivedData;
* repeated connect/stop/switch cycles in one extension process;
* sleep/wake, Wi-Fi/Ethernet changes, DNS/gateway changes, and late callbacks;
* local sign-out/account switch, offline installed configs, and bounded quit;
* notifications and snapshot reconciliation in the user session;
* a notarized Developer ID install on a clean Mac with SIP enabled.

Start basic connectivity checks with a controlled TCP/IP request, then DNS and
UDP, before complex browser behavior. Do not record user traffic. Unit tests and
simulator behavior do not establish signed extension parity.

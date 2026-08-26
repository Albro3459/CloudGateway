# macOS App Plan

Status: planning. No implementation yet.

A native macOS GUI that reuses `CloudGatewayKit` and `CloudGatewayAppCore`,
replacing the WireGuard app for daily use. Mirrors the iOS app: a login gate,
then a dashboard with client creation and a region-grouped client table.

A command line tool is deferred. See `TODO/macos-cli-deferred.md`.

## Decisions

| Decision | Choice |
|---|---|
| Distribution | Developer ID, notarized, DMG. Not Mac App Store. |
| Extension packaging | System extension (confirm against TN3134) |
| Minimum OS | macOS 14, matching `CloudGatewayKit`'s existing platform floor |
| Auth | Browser device flow, then Firebase SDK `signIn(withCustomToken:)` |
| Firestore | Firebase SDK, port of the iOS repository |
| GUI | Normal window app plus an `NSStatusItem` menu. No popover. |
| Admin panel | Not on macOS. The web dashboard keeps Server Health. |
| CLI | Deferred |

The Mac App Store is not an option. App Store Review Guideline 5.4 requires VPN
apps to be published by an organization, and this is an individual account. That
constraint does not apply to Developer ID distribution.

## Non-Goals For v1

* no command line tool;
* no admin dashboard, access granting, or region sync UI;
* no popover UI;
* no cross-process locking, tunnel-coordinator extraction, or client selector.
  Those exist only to serve a second, non-UI consumer. See "Deliberately Not
  Building" below.

## Targets

```
Frontend/Apple/macOS/CloudGateway.xcodeproj
    CloudGateway         SwiftUI app, window UI, NSStatusItem menu,
                         composition root, system extension activation
    CloudGatewayTunnel    system extension; links CloudGatewayKit and
                         WireGuardKit and the Apple frameworks only
```

The extension must not link `CloudGatewayAppCore`, Firebase, SwiftUI, or AppKit,
per `Frontend/Apple/macOS/README.md`.

The macOS target must not compile sources from `Frontend/Apple/iOS/`. Reuse
happens through the shared packages.

## Reused Unchanged

| Workflow | Source |
|---|---|
| App state and commands | `CloudGatewayViewModel` |
| Auth and account actions | `CloudGatewayAppServiceFacade`, `CloudGatewayFirebaseAuthAdapter` |
| Apex and regional APIs | `CloudGatewayControlPlaneClient` |
| VPN, config, cache, Keychain | `CloudGatewayKit` |
| Tunnel health detection | `CloudGatewayTunnelHealthMonitor` in the extension |
| Health presentation | AppCore presentation refresh plus the Kit health store |

`CloudGatewayViewModel` is used directly, the same way iOS uses it. No
refactoring of the shared core is required for this plan.

## New macOS Code

| Piece | Rough size |
|---|---|
| `CloudGatewayMacComposition` root | ~80 lines, mirrors the iOS root |
| `CloudGatewayMacFirestoreRepository` | ~110 lines, port of the iOS repository |
| `CloudGatewayTunnelHealthReader` | ~10 lines |
| Notification authorizer | ~30 lines |
| `CloudGatewayDeviceAuthClient` in AppCore | ~150 lines, pure networking, testable |
| `CloudGatewayDeviceAuthViewModel` in AppCore | ~120 lines, testable |
| Window UI | ~800-1200 lines SwiftUI |
| Status item menu | ~250 lines AppKit |
| Packet tunnel provider | ~400 lines, macOS adapters around the shared monitor |

## Auth

The React site already implements Apple, Google, and email/password. Reusing it
through a browser device flow means macOS needs no `ASAuthorizationController`,
no Google presenter, and no Sign in with Apple entitlement.

1. app calls `POST /api/device/code`, receives `device_code`, `user_code`,
   `verification_uri`, `expires_in` 300, `interval` 5;
2. app displays the code and opens the default browser to the React `/device`
   page;
3. user signs in on any device and confirms the displayed code matches;
4. the page calls `POST /api/device/approve` with its Firebase ID token and the
   user code; the API verifies the token and records the approval;
5. the app polls `POST /api/device/token` and receives a Firebase custom token
   from `auth.create_custom_token(uid)`;
6. the app calls `Auth.auth().signIn(withCustomToken:)`.

Step 6 is why this is cheap. The Firebase SDK persists the resulting session in
the Keychain itself, so there is no token store to write, and the existing auth
state listener in `CloudGatewayViewModel` picks up the sign-in with no changes.
Firestore is then used through the SDK exactly as on iOS.

Shared-core changes are additive and small:

* add `signInWithCustomToken(_:)` to `CloudGatewayAuthServicing` and implement it
  in `CloudGatewayFirebaseAuthAdapter`;
* add `CloudGatewayDeviceAuthClient` and `CloudGatewayDeviceAuthViewModel` to
  `CloudGatewayAppCore`, used only by macOS.

`CloudGatewayViewModel`'s existing `signIn`, `signInWithGoogle`, and
`linkApple` paths are simply not called by the macOS UI.

Backend work, on the apex API rather than regional because this is account
level:

* `POST /api/device/code`, `/api/device/approve`, `/api/device/token`;
* pending codes in Firestore with a TTL;
* `user_code` entropy, single-use codes, `device_code` bound to `user_code`,
  poll rate limiting returning `slow_down`;
* wire `auth logout` to `auth.revoke_refresh_tokens(uid)`, already used at
  `Backend/API/src/firebase.py:357`.

Anti-phishing: the approval page must display the code and require the user to
confirm it matches what the app shows. Never accept a prefilled link that
auto-approves. This is the known weakness of device flows and the reason
cross-device sign-in is otherwise safe.

Web work: a `/device` route in the React app. Note the app uses `HashRouter`, so
the verification URI is `gocloudlaunch.com/#/device`.

## Window UI

Mirrors the iOS app.

* login gate: sign-in button that starts the device flow, displays the user
  code, and shows progress and expiry;
* dashboard: an input area to create a client, then a table of clients grouped
  by region;
* per-client: install, toggle, delete, and a details disclosure;
* keep the offline and stale handling. It comes free from
  `CloudGatewayConfigManager` and it is what makes the table useful when the
  network is unavailable.

Use a `Table` and a real toolbar rather than transcribing the iOS layout. The
view models are shared, so behavior stays in sync without sharing views.

## Status Item Menu

Docker Desktop is the reference. `NSStatusItem` with an `NSMenu`, no popover.

* a "Open Dashboard" item;
* one submenu per region, listing that region's clients, click to toggle;
* right-click toggles the most recently used client;
* current status shown at the top;
* Quit.

Two implementation notes:

**Click handling.** Assigning `statusItem.menu` makes the system show the menu on
both left and right click, and you cannot intercept right-click. To distinguish
them, leave `menu` unset and drive the button directly:

```swift
button.action = #selector(handleClick)
button.sendAction(on: [.leftMouseUp, .rightMouseUp])
```

On left click, temporarily assign `statusItem.menu`, call
`statusItem.button?.performClick(nil)`, then clear it. `popUpMenu(_:)` is
deprecated; do not use it.

Rebuild the menu in `NSMenuDelegate.menuNeedsUpdate` so it reflects live state.

**Icons.** `cloudgateway.svg` is a full-color asset with gradients and a rounded
rectangle background. Menu bar template images are alpha-only, so it cannot be
used directly. Derive a monochrome glyph from the cloud silhouette, drop the
background and gradients, and simplify: the tunnel detail will not read at
16-18pt. Ship two shapes, outline for off and filled for on, as vector PDFs in
an asset catalog.

Mark both as Template Image so macOS adapts them to light and dark menu bars.
A literal filled-white icon is invisible on a light menu bar. If an accent color
is wanted for the on state instead, that requires non-template rendering and
gives up automatic appearance adaptation.

The full-color SVG is still the right source for the app icon `.icns`.

Most-recently-used client is persisted in app group `UserDefaults` so the
window and the menu agree.

Observe `NEVPNStatusDidChange` to keep the icon live. Even with a single app
process, status changes outside the app when the extension dies, the network
drops, or the user disconnects from System Settings.

## System Extension

Activation is GUI-only and happens once per machine. Per Apple DTS,
`OSSystemExtensionRequest` holds its delegate weakly, so hold the manager in a
static on the `@main` app and activate from `init`.

Gotchas, from Apple forum threads 725805 and 776759:

* the container app must live in `/Applications` for activation to succeed;
* `NEMachServiceName` in the extension `Info.plist` must be prefixed with the
  app group identifier. A mismatch leaves the extension stuck in
  `validating by category` and can crash `sysextd` and `nesessionmanager`;
* network system extensions are sandboxed; the app is not;
* debug with `systemextensionctl`;
* add a build post-action that copies the app to `/Applications`, since the
  activation path requires it.

Three things require a GUI session, once per machine: system extension
activation, the first `saveToPreferences()` which prompts to add VPN
configurations, and notification authorization for the dead-tunnel
notification. The app owns all three.

Recovery behavior follows `Frontend/Apple/macOS/README.md`. Backend restart is
iOS-only in the pinned WireGuard fork, so the macOS runtime adapter reports it
as `unsupported` initially; the shared bounded recovery policy still confirms
and notifies.

## Deliberately Not Building

These appeared in earlier drafts to serve a command line tool. With a single
GUI consumer they are speculative, and the Periphery scans would fail the build
on unused code.

* `CloudGatewayTunnelCoordinator`. The sequencing in `CloudGatewayViewModel`
  (`activeTunnelClient` line 917, `switchTunnel` line 936, `pullFreshAndInstall`
  line 890) stays where it is. Extract it when a real second consumer exists and
  can say where the seam belongs.
* `CloudGatewayStateLock`. A cross-process `flock` protects against mutation
  from a second process. There is no second process.
* `CloudGatewayClientSelector`. Name and index resolution is a CLI concern.

## Risks

1. **Developer ID Network Extension provisioning.** The existing entitlement
   covers App Store and TestFlight distribution. Developer ID uses a different
   provisioning profile type, and Apple has historically gated Network
   Extension on Developer ID behind a separate capability request. Confirm this
   path in the developer portal before phase 3, and submit any request
   immediately. This is a lead-time risk, not a technical one, and it is the
   most likely thing to block the release.
2. WireGuardKitGo building for macOS arm64. The fork's bridge is device-only
   today.
3. Firebase and Firestore SDKs on macOS. Officially supported, never compiled in
   this repo.
4. Confirm the system extension versus app extension rule against TN3134 before
   creating the target.
5. Notarization and the signed hardware test matrix.

## Phases

| Phase | Work |
|---|---|
| 0 | Portal: confirm Developer ID plus Network Extension provisioning. Submit any capability request. Does not block phases 1 and 2. |
| 1 | Device flow endpoints on the apex API, `/device` page in the React app, `signInWithCustomToken` on the auth adapter, `CloudGatewayDeviceAuthClient` and view model in AppCore with `swift test` coverage |
| 2 | macOS app target, composition root, Firestore repository port, login gate and dashboard window. No tunnel yet; proves Firebase and Firestore on macOS |
| 3 | System extension target, WireGuardKitGo macOS build, entitlements, signing, install and toggle working end to end |
| 4 | Status item menu, icon assets, most-recently-used persistence |
| 5 | `./scripts/test.sh macos`, Periphery config, notarization and DMG release script mirroring `scripts/ios-release.sh`, docs |

Phases 1 and 2 carry most of the logic and no signing risk. Phase 3 carries
nearly all the risk.

## Validation

Beyond `./scripts/test.sh`, on a signed Mac verify:

* system extension activation from `/Applications`, and `NEMachServiceName` app
  group prefixing;
* the three bootstrap prompts, and that the app explains each;
* device flow across two machines, code expiry, and replay of a used code;
* `NEVPNStatusDidChange` keeping the status item icon correct after the tunnel
  drops on its own;
* template icons in light and dark menu bars;
* app group snapshot and Keychain access under real entitlements;
* sleep and wake, Wi-Fi to Ethernet, and DNS and gateway changes against the
  shared path policy;
* start and stop ordering, callback loss, stale sessions, and the bounded stop
  deadline.

Simulator behavior is not evidence for the extension, entitlement, sleep,
WireGuard, notification, or deadline contracts.

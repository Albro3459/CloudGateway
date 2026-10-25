# iOS architecture

The SwiftUI app composes shared VPN and app workflows with iOS UI and vendor
adapters. The packet tunnel extension owns VPN runtime independently of the app.
See the [iOS README](../Frontend/Apple/iOS/README.md) for API integration,
validation, and [App Store releases](../Frontend/Apple/iOS/README.md#app-store-release).

## Product boundaries

* `CloudGatewayKit`: VPN preferences, config parsing, reconciliation, metadata
  cache, Keychain storage, and tunnel-health policies.
* `CloudGatewayAppCore`: Firebase-free service contracts, control-plane client,
  app model, and presentation refresh. It depends on Kit.
* `CloudGatewayFirebaseAuthAdapter`: wraps Firebase Auth behind AppCore protocols.
* iOS app: Firebase/Firestore composition, Google Sign-In presentation,
  notification authorization, SwiftUI, and app lifecycle.
* iOS packet extension: Kit, WireGuardKit, the Go bridge, and Apple frameworks.
  It has no Firebase, AppCore, or UI dependency.

Neither shared product imports Firebase, Google Sign-In, SwiftUI, UIKit, or
AppKit. The [package README](../Frontend/Apple/CloudGatewayKit/README.md)
describes their APIs. Both products support iOS 17 and macOS 14; the macOS app
has its own higher deployment target and controller architecture.

| iOS resource | Identifier |
|---|---|
| App | `com.gocloudlaunch.gateway` |
| Packet tunnel | `com.gocloudlaunch.gateway.tunnel` |
| App group | `group.com.gocloudlaunch.gateway` |

Inject bundle IDs, app group, display name, Keychain access group, and storage
locations through `CloudGatewayPlatformConfiguration`.

## Config storage

Firestore and the regional API are the product source of truth. Users select a
client from their inventory; local Apple state is an install/offline cache.
Full WireGuard configs contain private keys and live only in the shared
Keychain through `CloudGatewayKeychainConfigSecretStore`.

* Default service: `com.gocloudlaunch.gateway.wireguard-config`.
* Account: `wireguard-config/<clientId>/<configHash>`.
* Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
* Synchronizable: false; access group comes from platform configuration.

App-group JSON, provider preferences, and UserDefaults may contain lookup and
staleness metadata only: client/region IDs, display names, timestamps, hashes,
and Keychain references. Never put full configs, keys, tokens, or Firebase
credentials in those stores, logs, diagnostics, or UI error text.

Install/update ordering:

1. Validate the remote config and compute its hash.
2. Save it to Keychain.
3. Save the metadata-only Network Extension profile.
4. Save app-group metadata.
5. Delete the old Keychain item if its reference changed.

Removal first removes the Network Extension profile, then clears app-group
metadata, then deletes the matching Keychain item.

Each client has its own Apple VPN profile. Identity uses stable `clientId`;
the Apple-visible name uses the required client display name. Installing or
updating one profile does not stop another tunnel. Starting may require enabling
the selected manager because iOS allows one enabled app VPN profile slot.
Row actions own install, sync, connect/disconnect, details, and deletion.

## Packet tunnel lifecycle

`PacketTunnelProvider` reads the Keychain reference from provider preferences,
loads and parses the config through Kit, maps it to WireGuardKit types, and
starts `WireGuardAdapter`. Keep WireGuardKit mapping outside SwiftUI/Firebase
code. Both Apple projects use the checked-in `wireguard-apple` submodule, which
carries Xcode 26 and runtime fixes. Keep product logic outside that fork.

The provider composes WireGuard, path, app-group persistence, and notification
adapters around `CloudGatewayTunnelHealthMonitor`. It obtains the monitor's
opaque session, starts the session-qualified path adapter, and only then
reports startup complete. The monitor's policies do not import WireGuardKit,
Network, or User Notifications.

Shutdown arms a five-second deadline, closes effect admission, cancels the path
session, and joins any start still installing monitoring. Normal completion
orders admitted effects before adapter stop and waits for artifact reconciliation
and the stop callback. At the deadline, still-queued effects are cancelled;
stop is submitted after the bounded submission point, and best-effort cleanup
completes without claiming durable success or waiting for physical callbacks.
Late work reconciles toward the current session's desired artifacts.

Health detection and notification continue while the app is closed, backgrounded,
or signed out. See [tunnel health](apple-tunnel-health-notification.md) for
recovery, timing, notification, and device-validation rules. macOS reuses Kit
VPN APIs but does not enable this monitor or notifications.

## Auth and presentation

Guest mode is tokenless, separate from Firebase anonymous auth. Guests can
browse enabled regions through the apex API; clients, capacity, installed VPN
controls, admin tools, and mutations require sign-in and product access.
Firebase authentication alone does not provision an account.

The app loads local installed state before auth-dependent remote state but hides
VPN controls while signed out. It requests notification authorization when
undetermined, including for an existing signed-out install; install/connect
retain their in-context request. Tunnel health remains independent of app auth.
Admins can manage authorized clients and access, and use the Server Health page.
See the [iOS README](../Frontend/Apple/iOS/README.md#firebase-and-control-plane)
for API and admin-data boundaries.

## Validation

Use `./scripts/test.sh ios` for host-free shared/adapter tests, strict Periphery
scans, release-script checks, and an unsigned device build. Add `--signed` for
provisioning checks, or use `apple` for both platforms with shared tests once.
Do not use the production app scheme for simulator unit tests: its WireGuard Go
bridge is device-only.

Builds do not establish real-device VPN installation, Keychain sharing, provider
sign-in, notification delivery, sleep/wake, network changes, or recovery/stop
behavior with late callbacks. Keep those checks explicit when changing runtime
code. See the [health validation checklist](apple-tunnel-health-notification.md#device-validation).

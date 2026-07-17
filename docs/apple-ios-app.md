# Apple iOS App Architecture

The CloudGateway iOS app is the first native Apple client, but its reusable code
is split into two Swift products for a future macOS app. `CloudGatewayKit` owns
VPN/configuration and packet-tunnel behavior. `CloudGatewayAppCore` owns
Firebase-free app workflows and presentation refresh. The iOS target owns only
native UI/lifecycle and platform/vendor composition.

## Layout

```text
Frontend/Apple/iOS/
  CloudGateway/                 iOS SwiftUI app target
  CloudGatewayTunnel/           iOS packet tunnel extension

Frontend/Apple/CloudGatewayKit/
  Sources/CloudGatewayKit/      shared Apple VPN/config core
  Sources/CloudGatewayAppCore/  shared app state and orchestration
  Tests/CloudGatewayKitTests/   shared model, cache, reconciliation tests
  Tests/CloudGatewayAppCoreTests/ shared app-model tests

Frontend/Apple/CloudGatewayFirebaseAdapter/
  Sources/CloudGatewayFirebaseAuthAdapter/ Firebase Auth protocol adapter
  Tests/CloudGatewayFirebaseAuthAdapterTests/ native error-mapping tests

Frontend/Apple/macOS/
  README.md                     future macOS app placeholder
```

The implemented dependency graph is:

```text
iOS app -> CloudGatewayAppCore + CloudGatewayKit
iOS screenshot fixture -> CloudGatewayAppCore + CloudGatewayKit
CloudGatewayAppCore -> CloudGatewayKit
iOS app -> CloudGatewayFirebaseAuthAdapter
CloudGatewayFirebaseAuthAdapter -> CloudGatewayAppCore + FirebaseAuth
iOS app -> FirebaseCore + FirebaseFirestore + GoogleSignIn
iOS packet extension -> CloudGatewayKit + WireGuardKit only
```

`CloudGatewayAppCore` depends on `CloudGatewayKit`; the reverse dependency does
not exist. Neither shared product imports Firebase, Google Sign-In, SwiftUI,
UIKit, or AppKit. The Firebase-auth adapter is a separate package so vendor SDK
availability cannot leak into the shared package graph.

The production iOS bundle IDs are:

* App: `com.gocloudlaunch.gateway`
* Packet tunnel extension: `com.gocloudlaunch.gateway.tunnel`
* App group: `group.com.gocloudlaunch.gateway`

Both the app and packet tunnel extension use the app group for nonsecret shared metadata. Full WireGuard configs are stored in the shared Keychain, not in app-group files.

## Shared Product Boundaries

The package targets iOS 17 and macOS 14. Its APIs are deliberately not named or
shaped around iOS-only concepts.

`CloudGatewayKit` responsibilities:

* `CloudGatewayPlatformConfiguration` carries injected platform identifiers: app group ID, app bundle ID, provider bundle ID, tunnel display name, Keychain access group, and config-secret service name.
* `CloudGatewayVPNManager` wraps `NETunnelProviderManager` install, update, remove, start, stop, profile lookup, and status checks.
* `CloudGatewayTunnelConfiguration` and `CloudGatewayProviderConfiguration` build metadata-only Network Extension provider preferences.
* `CloudGatewayWireGuardConfig`, `CloudGatewayWireGuardConfigParser`, and related parsed models validate and parse raw WireGuard configs behind a kit boundary.
* `CloudGatewayRegion`, `CloudGatewayClient`, `CloudGatewayClientOption`, `CloudGatewayConfigSelection`, and capacity types provide Firebase/API-derived sorting, filtering, selection, merge, and installability logic without importing Firebase.
* `CloudGatewayConfigManager` owns install orchestration, local/remote reconciliation, stale-state detection, per-client start/stop/remove behavior, and cache update ordering.
* `CloudGatewayConfigCache` stores installed config metadata in the app group.
* `CloudGatewayKeychainConfigSecretStore` stores the full WireGuard config in the shared Keychain.
* `CloudGatewayTunnelHealthMonitor` owns the single shared wake, callback tokens,
  deterministic coordinator and recovery policies, generation-aware artifact
  reconciliation, and cancellable FIFO effect submission used by packet-tunnel
  extensions.
* `CloudGatewayTunnelHealthTiming`, the evaluator/recovery/path/persistence policies,
  and `CloudGatewayTunnelHealthStore` define one monotonic timing and snapshot
  contract for the extension producer and app consumer.
* Plain callback adapter protocols isolate WireGuard runtime operations,
  session-qualified path events, snapshot persistence, notification
  registration, and backend-restart capability from the coordinator.

`CloudGatewayAppCore` responsibilities:

* Firebase-free auth, repository, control-plane, provider-presentation,
  notification, health-reader, and presentation-sleeper contracts;
* request/response DTOs, URL validation, bounded URLSession construction, and
  the apex/regional `CloudGatewayControlPlaneClient`;
* `CloudGatewayAppServiceFacade`, which composes those narrow services behind
  `CloudGatewayServicing`;
* `CloudGatewayViewModel`, including guest/auth startup, access/role and
  region/client workflows, VPN command orchestration, destructive-operation
  guards, dead-tunnel presentation, notification policy, and the cancellable
  five-second presentation refresh loop.

Do not import Firebase, Google Sign-In, SwiftUI, UIKit, AppKit, or native app
lifecycle code into either shared product.
The tunnel-health coordinator and monitor also import neither WireGuardKit,
Network, nor User Notifications; the packet extension maps those frameworks at
the platform boundary. The kit can depend on Apple platform frameworks needed
for VPN and secret storage, such as NetworkExtension, Security, Foundation, and
CryptoKit.

## iOS App Responsibilities

The iOS app target composes the shared products with vendor services and UI:

* Configures Firebase on launch.
* Uses the separate `CloudGatewayFirebaseAuthAdapter` package for
  email/password, Sign in with Apple, Google credentials, provider linking,
  reauthentication, token refresh, and sign-out through Firebase Auth.
* Implements the Firestore client/role repository and iOS Google Sign-In
  presenter behind AppCore protocols.
* Uses the AppCore control-plane client for apex and regional APIs with Firebase
  ID tokens.
* Maps remote config state into Kit VPN/config types at the composition boundary.
* Owns SwiftUI views, theme tokens, navigation, loading/guest/signed-in modes, admin screens, banners, dialogs, and share/export UI.
* Hides installed/cached VPN controls when signed out or in guest mode.
* Loads installed local state before auth-dependent remote state and requests
  notification authorization if it is undetermined. This also covers an
  existing install while signed out; install/connect actions retain their
  in-context authorization request.

`CloudGatewayIOSCompositionRoot` explicitly creates the Firebase-auth adapter,
iOS Firestore repository, shared control-plane client, iOS Google presenter,
`CloudGatewayAppServiceFacade`, Kit config/health dependencies, and shared view
model. `ContentView` receives that model and only starts
`presentationDidAppear()` plus the model's cancellable presentation monitor
from its existing lifecycle hooks. App workflows stay testable without
Firebase, network, or UI targets.

Global/read traffic uses the apex API:

```text
GET  https://api.gocloudlaunch.com/api/regions
POST https://api.gocloudlaunch.com/api/auth/check-access
DELETE https://api.gocloudlaunch.com/api/account
```

Region-specific actions use the selected region host:

```text
GET    https://<regionId>.gocloudlaunch.com/api/capacity
POST   https://<regionId>.gocloudlaunch.com/api/clients
DELETE https://<regionId>.gocloudlaunch.com/api/clients/{clientId}
POST   https://<regionId>.gocloudlaunch.com/api/admin/sync
```

The app never asks normal users to paste WireGuard configs, import QR codes, use the external WireGuard app, or manage config files manually. Firestore and the regional API are the source of truth. Local Apple state is only an install/offline cache.

## Packet Tunnel Extension

`CloudGatewayTunnel` is VPN runtime code only. It should not link Firebase.

On startup, `PacketTunnelProvider`:

1. Reads `NETunnelProviderProtocol.providerConfiguration`.
2. Extracts the Keychain service, Keychain account, and optional Keychain access group.
3. Loads the full WireGuard config from the shared Keychain.
4. Parses it through `CloudGatewayWireGuardConfigParser`.
5. Converts the parsed config into WireGuardKit `TunnelConfiguration`, `InterfaceConfiguration`, and `PeerConfiguration`.
6. Starts WireGuard through `WireGuardAdapter`.
7. Uses the app-group ID and tunnel ID to compose queue-confined WireGuard,
   app-group snapshot, User Notifications, and `NWPathMonitor` adapters around
   the shared tunnel-health monitor.
8. Waits for the monitor's opaque health session, starts the session-qualified
   path adapter, and only then reports tunnel startup complete.

On shutdown, the provider arms a five-second deadline immediately, closes the
session's effect admission, cancels its path session, and joins a start that is
still installing health monitoring. Normal completion preserves every
already-admitted persistence and notification submission ahead of WireGuard
stop, then waits for durable artifact reconciliation and the adapter stop
callback. If the deadline wins, still-queued health effects are cancelled,
WireGuard stop is submitted after the bounded submission point, and the
Network Extension completion runs after idempotent best-effort cleanup without
waiting for physical callbacks or claiming durable cleanup succeeded.

The extension logs WireGuardKit messages with private formatting and does not log VPN traffic, DNS queries, destination metadata, private keys, full configs, auth tokens, or Firebase credentials.

The extension also monitors tunnel health, silently attempts binding-refresh
and backend-restart recovery, and raises one "VPN connection interrupted"
notification for a persistently dead tunnel (a blackholed full tunnel on
otherwise working Internet, e.g. during a server deployment). Detection and
notification remain active while the app is backgrounded, closed, in guest
mode, or signed out. The provider contains lifecycle and platform translation;
the detection state machine lives in `CloudGatewayKit`. See
`docs/apple-tunnel-health-notification.md`.

## WireGuardKit Integration

The app uses WireGuardKit from a Swift Package dependency. CloudGateway currently pins Alex's fork:

```text
https://github.com/Albro3459/wireguard-apple
```

The fork is intentionally small and exists to carry Xcode 26 build fixes on top of upstream `wireguard-apple`, including the `WireGuardKitC` include fix and Go bridge discovery fix for Xcode GUI builds on ARM macOS. Keep CloudGateway-specific product logic out of the fork.

The tunnel extension links WireGuardKit and depends on the external `WireGuardGoBridgeiOS` build target, which builds WireGuard's Go userspace bridge (`libwg-go.a`). Go must be installed and visible to Xcode for signed/device builds.

CloudGateway's own WireGuard boundary is:

* Raw config text is accepted only from authenticated remote state during install/update.
* `CloudGatewayWireGuardConfig` validates non-empty config text.
* `CloudGatewayWireGuardConfigParser` handles CloudGateway-owned parsing into a platform-neutral parsed representation.
* `PacketTunnelProvider` maps parsed values into WireGuardKit types at tunnel start.

SwiftUI and Firebase code should not perform WireGuardKit mapping directly.

## App Store Archive

Firestore must use its source SwiftPM distribution for App Store archives. The default binary distribution embeds `FirebaseFirestoreInternal.framework`, `absl.framework`, `grpc.framework`, `grpcpp.framework`, and `openssl_grpc.framework`; App Store Connect then expects dSYMs for those prebuilt frameworks.

The normal CLI release path is:

```sh
./scripts/ios-release.sh
```

The script increments the build number on every run. Use `--version patch`,
`--version minor`, or `--version major` to bump the marketing version as well;
those runs also increment the build number. The script validates the individual
App Store Connect API key, archives with source Firestore, exports an IPA,
uploads it with Transporter, and commits a `Deploy iOS v<version> (build <n>)`
commit without pushing it.

The configured team key path is
`$HOME/.ssh/Apple_API_KEY/AuthKey_YDM2P5LSK8.p8`. It must have mode `600`. The
key ID and issuer ID are identifiers, not secrets; never commit or log the `.p8`
private key.

For the manual Xcode flow, quit Xcode and reopen the project with source
Firestore:

Archive from Xcode with the source Firestore environment:

1. Quit Xcode.
2. Reopen the project from the repo root:

   ```sh
   open --env FIREBASE_SOURCE_FIRESTORE=1 Frontend/Apple/iOS/CloudGateway.xcodeproj
   ```

3. In Xcode, choose `Product > Archive`.
4. Quit and reopen Xcode normally after archiving for faster development device builds.

The source distribution compiles Firestore, abseil, gRPC, and BoringSSL into the app build instead of embedding those dependencies as separate prebuilt frameworks. The code is still present; the standalone framework folders are not.

If Xcode archiving does not work, use isolated DerivedData and SwiftPM checkout directories so Xcode does not mix the normal binary package graph with the source Firestore graph:

```sh
mkdir -p /private/tmp/CloudGatewaySourceFirestoreDerivedData /private/tmp/CloudGatewaySourceFirestorePackages
FIREBASE_SOURCE_FIRESTORE=1 CLOUDGATEWAY_SOURCE_PACKAGES_DIR=/private/tmp/CloudGatewaySourceFirestorePackages xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS -configuration Release -derivedDataPath /private/tmp/CloudGatewaySourceFirestoreDerivedData -clonedSourcePackagesDirPath /private/tmp/CloudGatewaySourceFirestorePackages archive
```

After archiving, `CloudGateway.app` should not contain `FirebaseFirestoreInternal`, `absl`, `grpc`, `grpcpp`, or `openssl_grpc` under `Frameworks/`.

## Local Storage And Secret Handling

Full WireGuard configs contain private key material and must live only in the shared Keychain.

Allowed durable full-config storage:

* Shared Keychain generic password item through `CloudGatewayKeychainConfigSecretStore`.

Not allowed:

* App-group JSON cache.
* `NETunnelProviderProtocol.providerConfiguration`.
* UserDefaults.
* Logs, diagnostics, banners, or debug text.

The Keychain item uses:

* Service: `com.gocloudlaunch.gateway.wireguard-config` by default.
* Account: `wireguard-config/<clientId>/<configHash>`.
* Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
* Synchronizable: false.
* Optional explicit access group from app build settings/entitlements.

App-group cache and provider preferences store only lookup and staleness metadata, such as client ID, region ID, display names, status, read/update timestamps, config hash, Keychain service/account, and Keychain access group.

Install ordering should preserve this invariant:

1. Normalize/validate the remote WireGuard config and compute its hash.
2. Save the full config to Keychain.
3. Save/update the Network Extension profile with metadata only.
4. Save app-group installed metadata.
5. Delete any old Keychain item for that client if the reference changed.

Remove ordering:

1. Remove the Network Extension profile.
2. Clear app-group metadata.
3. Delete the matching Keychain item.

## Multiple VPN Profiles

The iOS app treats each CloudGateway client as its own Apple VPN profile:

* Apple-visible profile name comes from the user-required client display name.
* Profile identity and lookup use stable `clientId`, never display name.
* Multiple profiles can coexist for one app.
* Installing/updating one profile does not force-stop another running tunnel.
* Starting a profile may require enabling that manager because iOS only allows one enabled app VPN profile slot at a time.

The row-level UI owns install, sync, start/stop toggle, details, and delete actions for each client. There is no separate global "Installed VPN" control surface.

## Guest, Auth, And Admin Behavior

Guest mode is tokenless. It is not Firebase anonymous auth.

Guests can browse enabled regions from the apex `GET /regions` endpoint. They cannot view clients, capacity, installed VPN state, admin tools, or mutating actions. Gated actions route to sign-in or request-access.

Signed-in users go through Firebase Auth plus `check-access`. Provisioning still comes from CloudGateway user/role records; a newly authenticated provider user is not considered provisioned until access is granted.

Dead-tunnel detection and notification do not depend on Firebase auth or the
app process. An already-installed tunnel can therefore notify while the user is
signed out, provided notification permission is available.

Admins can see visible users' VPN clients, grant access, delete clients they are authorized to manage, and run selected-region peer sync. The admin sync result can include operational audit data such as user emails, client names, client IDs, public keys, tunnel IPs, statuses, and removed-peer details. Treat it as admin-only operational data.

## macOS Reuse Guidance

The future macOS GUI app should import both `CloudGatewayAppCore` and
`CloudGatewayKit` rather than duplicating iOS workflows or VPN/config logic. It
should not compile sources from the iOS app target.

Expected macOS shape:

* macOS app target owns AppKit/SwiftUI lifecycle, Firebase/Firestore setup,
  provider-sign-in presentation, notification authorization, identifiers, and
  UI. It reuses the AppCore control-plane client, service facade, app model, and
  presentation refresh instead of rebuilding them.
* macOS packet tunnel extension owns runtime startup and links WireGuardKit.
* Both macOS targets share an app group for nonsecret metadata and a Keychain access group for WireGuard config secrets.
* The macOS composition passes macOS bundle IDs, provider bundle ID, app group, display name, and Keychain access group into `CloudGatewayPlatformConfiguration`.
* `CloudGatewayKeychainConfigSecretStore` already has a macOS path that uses `kSecUseDataProtectionKeychain`.
* The macOS packet-tunnel extension imports only Kit plus WireGuardKit and Apple
  system frameworks. It instantiates the public
  `CloudGatewayTunnelHealthMonitor`, which encapsulates the internal
  coordinator, artifact driver, and effect arbiter, and reuses the public
  timing/store/notification/start-stop contracts. It adds only WireGuardKit,
  `NWPathMonitor`, notification, persistence, and lifecycle adapters.
* Backend restart is an explicit runtime capability. The current macOS adapter
  should report it unsupported until the pinned WireGuard fork exposes and
  validates that public API on macOS; the bounded policy still reaches outage
  confirmation and notification.

No macOS target, entitlement, signing, UI/Firebase composition, platform
adapter, or signed-device validation was implemented by this refactor. The
exact packet-extension ownership map and parity checklist live in
`Frontend/Apple/macOS/README.md`.

When adding macOS, keep platform-specific behavior in composition/configuration or small adapters. Do not fork `CloudGatewayConfigManager`, selection logic, WireGuard parsing, cache metadata shape, or secret-reference model unless macOS exposes a real API difference that cannot be injected.

## Validation

Docs-only changes can be manually reviewed. Apple code changes should use the existing Apple validation path:

```sh
./scripts/test.sh apple
./scripts/test.sh apple --signed
```

The unsigned gate checks release-script syntax, runs `CloudGatewayKit` and
`CloudGatewayAppCore` tests, runs native `CloudGatewayFirebaseAuthAdapter`
tests, lists the Xcode project, and builds the full iOS app and extension graph
for a generic device without signing. The `--signed` variant validates generic
device provisioning, but no signed build or real-device check was performed as
part of this refactor.

Signed real-device validation remains outstanding for Network Extension
installation, App Group and Keychain Sharing entitlements, provider sign-in UI,
notification authorization/delivery, sleep/wake and network changes, live
WireGuard start/stop/recovery, and bounded stop behavior with late or missing
callbacks.

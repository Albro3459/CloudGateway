# CloudGateway iOS

Native iOS app project home.

Targets:

* CloudGateway app: `com.gocloudlaunch.gateway`
* Packet tunnel extension: `com.gocloudlaunch.gateway.tunnel`

Both targets should use the app group `group.com.gocloudlaunch.gateway`.

## App Composition

The app target is a thin native composition layer:

* `CloudGatewayAppCore` supplies the shared service contracts, control-plane
  client, service facade, app model, and presentation-refresh lifecycle;
* `CloudGatewayKit` supplies VPN/config, cache, Keychain, and tunnel-health APIs;
* `CloudGatewayFirebaseAuthAdapter` is a local Swift package that alone wraps
  Firebase Auth behind the AppCore auth protocol;
* the iOS target supplies Firebase Core setup, the Firestore repository, Google
  Sign-In presentation, notification authorization, injected production
  identifiers, SwiftUI views, and app lifecycle.

`CloudGatewayIOSCompositionRoot` constructs this graph explicitly. The shared
`CloudGatewayViewModel` owns the immediate presentation refresh and its
cancellable five-second status/health loop; `ContentView` only starts those
operations from its existing appearance and task lifecycle.

## Firebase And Control Plane

The app target uses Firebase email/password auth, reads client and role state from Firestore, fetches enabled regions from the apex API, and verifies access through the apex API endpoint:

```text
GET  https://api.gocloudlaunch.com/api/regions
POST https://api.gocloudlaunch.com/api/auth/check-access
DELETE https://api.gocloudlaunch.com/api/account
```

The signed-in user can browse enabled regions, see region capacity, filter owned configs by region, create a config in the selected region, delete a selected config, refresh Firestore/API state, and install/start/stop a chosen WireGuard config internally. The app does not auto-select a VPN config, and it does not use pasted configs, QR codes, the WireGuard app, or manual config files.

Regional API calls use the selected region endpoint:

```text
GET    https://<regionId>.gocloudlaunch.com/api/capacity
POST   https://<regionId>.gocloudlaunch.com/api/clients
DELETE https://<regionId>.gocloudlaunch.com/api/clients/{clientId}
POST   https://<regionId>.gocloudlaunch.com/api/admin/sync
```

`POST /admin/sync` is shown only for admins. The UI displays the sync counts
and can show/share the full peer audit log. Treat that log as admin-only
operational data: it can include user emails, client names, client IDs, public
keys, tunnel IPs, statuses, and removed-peer details.

The app target directly links:

* `FirebaseCore`
* `FirebaseFirestore`
* `GoogleSignIn`
* `CloudGatewayAppCore`
* `CloudGatewayKit`
* `CloudGatewayFirebaseAuthAdapter`

`CloudGatewayFirebaseAuthAdapter` links `FirebaseAuth` behind its
`CloudGatewayAuthServicing` implementation. The app supplies the Firestore and
Google presentation adapters; the shared control-plane client owns URLSession
and API request behavior.

Do not link Firebase, Google Sign-In, or AppCore to `CloudGatewayTunnel`. The
packet tunnel extension links only `CloudGatewayKit`, WireGuardKit, its iOS Go
bridge, and Apple system frameworks, and receives installed provider
configuration from the containing app.

## Tunnel Health

The packet tunnel extension uses the shared `CloudGatewayTunnelHealthMonitor`,
which encapsulates the Kit's coordinator and recovery policies, to detect a
blackholed full tunnel, attempt binding-refresh and backend restart recovery,
persist the app warning, and post at most one stable local notification per
continuous outage. Detection remains active while the app is backgrounded,
closed, or signed out. Persistence, notification registration, and stop
ordering are generation-fenced so late work cannot overwrite a newer session.
See [Apple tunnel health detection](../../../docs/apple-tunnel-health-notification.md).

`GoogleService-Info.plist` belongs under `CloudGateway/` and must be included in the app bundle only. It contains Firebase app identifiers, not service account credentials.

## App Store Archive Symbols

Firestore resolves to a binary distribution by default when Xcode evaluates the Firebase Swift package. App Store Connect may reject that archive with missing dSYM warnings for `FirebaseFirestoreInternal.framework`, `absl.framework`, `grpc.framework`, `grpcpp.framework`, and `openssl_grpc.framework`.

Archive from Xcode with the source Firestore environment:

1. Quit Xcode.
2. Reopen the project from the repo root:

   ```sh
   open --env FIREBASE_SOURCE_FIRESTORE=1 Frontend/Apple/iOS/CloudGateway.xcodeproj
   ```

3. In Xcode, choose `Product > Archive`.
4. Quit and reopen Xcode normally after archiving for faster development device builds.

The source distribution compiles Firestore, abseil, gRPC, and BoringSSL into the app build instead of embedding those dependencies as separate prebuilt frameworks. The code is still present; the standalone framework folders are not.

If Xcode archiving does not work, use isolated DerivedData and SwiftPM checkout directories. The `CLOUDGATEWAY_SOURCE_PACKAGES_DIR` value lets the WireGuard legacy target find the same SwiftPM checkout root:

```sh
mkdir -p /private/tmp/CloudGatewaySourceFirestoreDerivedData /private/tmp/CloudGatewaySourceFirestorePackages
FIREBASE_SOURCE_FIRESTORE=1 CLOUDGATEWAY_SOURCE_PACKAGES_DIR=/private/tmp/CloudGatewaySourceFirestorePackages xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS -configuration Release -derivedDataPath /private/tmp/CloudGatewaySourceFirestoreDerivedData -clonedSourcePackagesDirPath /private/tmp/CloudGatewaySourceFirestorePackages archive
```

After archiving, confirm the archive no longer embeds the binary Firestore dependency frameworks under `Products/Applications/CloudGateway.app/Frameworks/`.

## Current Limitations

Shared sorting, filtering, reconciliation, selection/merge, cache, VPN, and
tunnel-health behavior are covered by `CloudGatewayKitTests`. App workflows,
control-plane transport, service composition, view-model orchestration, and the
presentation loop are covered by `CloudGatewayAppCoreTests` against protocol
doubles, so no Firebase project or network is involved. Both suites run in the
`CloudGatewayKit` package gate. The separate Firebase-auth-adapter package also
runs native macOS mapping tests; iOS Firestore and Google presentation adapters
are covered by compilation in the full app build.

Capacity is best-effort. If a regional capacity request fails, the region
remains visible with "Capacity unavailable," but client creation stays disabled
until a later refresh provides a known capacity below the region limit.

## No-Device Build Verification

From the repo root:

```sh
./scripts/test.sh apple
./scripts/test.sh apple --signed
```

The unsigned Apple target validates the release-script syntax, runs the
CloudGatewayKit/AppCore package tests, runs the Firebase-auth-adapter package
tests, lists the Xcode project, and performs the no-device app build. The signed
variant replaces only the unsigned build with explicit provisioning for the app
and tunnel extension.

Signed builds and archives use your login keychain. If it is locked, unlock it
first with a command that omits the password so macOS prompts for it:

```sh
security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
```

Release export signs manually against the installed `CloudGateway AppStore` and
`CloudGateway Tunnel AppStore` profiles, which embed the team's Apple
Distribution certificate and expire 2027-07-19. See
[apple-ios-app.md](../../../docs/apple-ios-app.md#distribution-signing-profiles)
for how to recreate them when they lapse.

Equivalent raw commands:

```sh
swift test --package-path Frontend/Apple/CloudGatewayKit
swift test --package-path Frontend/Apple/CloudGatewayFirebaseAdapter
xcodebuild -list -project Frontend/Apple/iOS/CloudGateway.xcodeproj
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS build
```

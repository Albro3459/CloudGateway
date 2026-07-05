# CloudGateway iOS

Native iOS app project home.

Targets:

* CloudGateway app: `com.gocloudlaunch.gateway`
* Packet tunnel extension: `com.gocloudlaunch.gateway.tunnel`

Both targets should use the app group `group.com.gocloudlaunch.gateway`.

## Firebase Config Manager

The app target uses Firebase email/password auth, reads client and role state from Firestore, fetches enabled regions from the apex API, and verifies access through the apex API endpoint:

```text
GET  https://api.gocloudlaunch.com/api/regions
POST https://api.gocloudlaunch.com/api/auth/check-access
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

Firebase packages are linked to the app target only:

* `FirebaseCore`
* `FirebaseAuth`
* `FirebaseFirestore`

Do not link Firebase to `CloudGatewayTunnel`. The packet tunnel extension receives the installed provider configuration from the containing app.

`GoogleService-Info.plist` belongs under `CloudGateway/` and must be included in the app bundle only. It contains Firebase app identifiers, not service account credentials.

## App Store Archive Symbols

Firestore resolves to a binary distribution by default when Xcode evaluates the Firebase Swift package. App Store Connect may reject that archive with missing dSYM warnings for `FirebaseFirestoreInternal.framework`, `absl.framework`, `grpc.framework`, `grpcpp.framework`, and `openssl_grpc.framework`.

For CLI App Store archives, build Firestore from source in isolated SwiftPM and DerivedData directories. The `CLOUDGATEWAY_SOURCE_PACKAGES_DIR` value lets the WireGuard legacy target find the same SwiftPM checkout root:

```sh
mkdir -p /private/tmp/CloudGatewaySourceFirestoreDerivedData /private/tmp/CloudGatewaySourceFirestorePackages
FIREBASE_SOURCE_FIRESTORE=1 CLOUDGATEWAY_SOURCE_PACKAGES_DIR=/private/tmp/CloudGatewaySourceFirestorePackages xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS -configuration Release -derivedDataPath /private/tmp/CloudGatewaySourceFirestoreDerivedData -clonedSourcePackagesDirPath /private/tmp/CloudGatewaySourceFirestorePackages archive
```

When archiving from Xcode, quit Xcode and reopen the project with:

```sh
open --env FIREBASE_SOURCE_FIRESTORE Frontend/Apple/iOS/CloudGateway.xcodeproj
```

After archiving, confirm the archive no longer embeds the binary Firestore dependency frameworks under `Products/Applications/CloudGateway.app/Frameworks/`.

## Current Limitations

Shared sorting, filtering, reconciliation, selection/merge, and cache behavior are covered by `CloudGatewayKit` tests (run under `swift test`). View-model orchestration (remote-load sequencing, sign-out branching, capacity gating, selection prune) has tests in `CloudGatewayTests/`, wired against a mock `CloudGatewayServicing` so no Firebase or network is involved.

That test target is a host-less logic bundle because the app scheme cannot build for the iOS Simulator — the `CloudGatewayTunnel` extension links WireGuard's device-only `libwg-go.a`. It therefore is not part of the `./scripts/test.sh apple` gate (which stays `swift test` + the unsigned no-device build); see [CloudGatewayTests/README.md](CloudGatewayTests/README.md) for the one-time Xcode wiring and the `xcodebuild test` command. The thin `CloudGatewayFirebaseService` URLSession/Firestore adapter remains build-validated only.

Capacity is best-effort. If a regional capacity request fails, the region remains visible with "Capacity unavailable" and creation is allowed to surface the authoritative API response.

## No-Device Build Verification

From the repo root:

```sh
./scripts/test.sh apple
./scripts/test.sh apple --signed
```

The unsigned Apple target proves compile health and package resolution. The signed variant checks explicit provisioning for the app and tunnel extension.

Equivalent raw commands:

```sh
swift test --package-path Frontend/Apple/CloudGatewayKit
xcodebuild -list -project Frontend/Apple/iOS/CloudGateway.xcodeproj
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS build
```

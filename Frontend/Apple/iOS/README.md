# CloudGateway iOS

Native SwiftUI app and packet tunnel extension. See the
[architecture guide](../../../docs/apple-ios-app.md) for storage and lifecycle
invariants, and the [Apple docs index](../README.md) for related guides.

Targets:

* CloudGateway app: `com.gocloudlaunch.gateway`
* Packet tunnel extension: `com.gocloudlaunch.gateway.tunnel`

Both targets should use the app group `group.com.gocloudlaunch.gateway`.

## App Composition

`CloudGatewayIOSCompositionRoot` composes Kit VPN/storage APIs, the AppCore
view model and control-plane client, the Firebase Auth adapter, and iOS
Firestore, Google Sign-In, notification, and UI adapters. `ContentView` starts
the model's immediate refresh and cancellable five-second presentation loop.
Shared product responsibilities live in the [package README](../CloudGatewayKit/README.md).

## Firebase And Control Plane

The app reads clients/roles from Firestore, authenticates through Firebase,
and uses the apex API for regions and product access:

```text
GET  https://api.gocloudlaunch.com/api/regions
POST https://api.gocloudlaunch.com/api/auth/check-access
DELETE https://api.gocloudlaunch.com/api/account
```

Signed-in users select clients from their inventory, install VPN profiles, and
connect/disconnect in the app. They can filter by region, create/delete clients,
and refresh state. Unknown regional capacity keeps creation disabled until a
refresh establishes room below the limit.

Regional API calls use the selected region endpoint:

```text
GET    https://<regionId>.gocloudlaunch.com/api/capacity
POST   https://<regionId>.gocloudlaunch.com/api/clients
DELETE https://<regionId>.gocloudlaunch.com/api/clients/{clientId}
POST   https://<regionId>.gocloudlaunch.com/api/admin/sync
```

`POST /admin/sync` backs the admin-only Server Health page, which replaces the
old per-region sync button. The page fans out one sync request per enabled
region, reads mesh membership and link status directly from Firestore
`Regions/*` and `Mesh/*` (the API's `/regions` summary carries no mesh
fields), and writes only the single `meshEnabled` field back to a region
document. It also reads `Policy/*` - observability-only account-scoped ACL
status written by each region's host via the Admin SDK, which the app never
writes - and renders a per-region client-isolation panel: row counts and
comprehensive IPv4/IPv6 policy hashes only, never uids, emails, client names,
addresses, or keys. A `Policy` read failure is isolated to its own
read-failure card; it cannot blank the mesh status or be mistaken for "no
region has synced." The UI displays per-region sync counts and can show/share
the full peer audit log via `ShareLink`, never written to disk or logs. Treat
that log as admin-only operational data: it can include user emails, client
names, client IDs, public keys, and tunnel IPs.

`GoogleService-Info.plist` belongs under `CloudGateway/` and in the app bundle
only. It contains Firebase app identifiers, not service account credentials.
The tunnel extension links Kit, WireGuardKit, the iOS Go bridge, and Apple
frameworks. Keep Firebase, Google Sign-In, and AppCore out of that target.
Both Apple projects build the checked-in `../wireguard-apple` submodule;
initialize it when checking out the repository.

## Tunnel Health

The packet tunnel extension uses the shared `CloudGatewayTunnelHealthMonitor`,
which encapsulates the Kit's coordinator and recovery policies, to detect a
blackholed full tunnel, attempt binding-refresh and backend restart recovery,
persist the app warning, and post at most one stable local notification per
continuous outage. Detection remains active while the app is backgrounded,
closed, or signed out. Persistence, notification registration, and stop
ordering are generation-fenced so late work cannot overwrite a newer session.
See [tunnel health](../../../docs/apple-tunnel-health-notification.md).

## App Store Release

App Store archives require source Firestore. Its default binary distribution
embeds frameworks whose missing dSYMs can cause App Store Connect warnings.
The release script selects source Firestore automatically.

Run from the repository root with a clean working tree:

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

Code signing uses your login keychain. If it is locked, the release script
unlocks it before archiving and macOS prompts for the password. To unlock it
beforehand, run the command without a password so macOS prompts for it:

```sh
security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
```

### Distribution signing profiles

Export uses manual signing. `ios-release.sh` writes an `ExportOptions.plist`
that pins each bundle ID to a named App Store provisioning profile:

* `com.gocloudlaunch.gateway` -> `CloudGateway AppStore`
* `com.gocloudlaunch.gateway.tunnel` -> `CloudGateway Tunnel AppStore`

Both profiles must be installed in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and must embed the
team's current Apple Distribution certificate, whose private key lives in the
login keychain. The App Store Connect API key only authorizes the upload; it
cannot sign the binary, so a valid certificate and a profile that lists it are
required locally.

The recorded profiles/certificate expire 2027-07-19; inspect installed copies
after renewal. Expired or mismatched profiles can fail export with:

```
error: exportArchive Provisioning profile "..." doesn't include signing certificate "Apple Distribution: ... (CRQWDQ7QQR)".
```

Recreate both profiles against the live certificate:

1. In the Apple Developer portal, create two App Store Connect distribution
   profiles, one for `com.gocloudlaunch.gateway` and one for
   `com.gocloudlaunch.gateway.tunnel`, each selecting the current Apple
   Distribution certificate. Name them `CloudGateway AppStore` and
   `CloudGateway Tunnel AppStore` so they match `ExportOptions`.
2. Download both and double-click to install; they land in the directory above,
   keyed by UUID.
3. Re-run `./scripts/ios-release.sh`.

Use the existing valid distribution identity and regenerate the profiles
against it. Creating another certificate does not repair a profile that omits
the certificate used for signing.

### Manual Xcode archive

Use source Firestore when archiving outside the release script:

1. Quit Xcode.
2. Reopen the project from the repo root:

   ```sh
   open --env FIREBASE_SOURCE_FIRESTORE=1 Frontend/Apple/iOS/CloudGateway.xcodeproj
   ```

3. In Xcode, choose `Product > Archive`.
4. Quit and reopen Xcode normally after archiving for faster development device builds.

If Xcode mixes binary and source package graphs, use isolated build/checkouts:

```sh
mkdir -p /private/tmp/CloudGatewaySourceFirestoreDerivedData /private/tmp/CloudGatewaySourceFirestorePackages
FIREBASE_SOURCE_FIRESTORE=1 \
CLOUDGATEWAY_SOURCE_PACKAGES_DIR=/private/tmp/CloudGatewaySourceFirestorePackages \
  xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
    -scheme CloudGateway -destination generic/platform=iOS -configuration Release \
    -derivedDataPath /private/tmp/CloudGatewaySourceFirestoreDerivedData \
    -clonedSourcePackagesDirPath /private/tmp/CloudGatewaySourceFirestorePackages archive
```

After archiving, `CloudGateway.app` should not contain `FirebaseFirestoreInternal`, `absl`, `grpc`, `grpcpp`, or `openssl_grpc` under `Frameworks/`.

## Validation

Run from the repository root:

```sh
./scripts/test.sh ios
./scripts/test.sh ios --signed
```

The gate runs Kit/AppCore host-free tests, native Firebase-adapter tests,
strict Periphery scans, release-script checks, and an unsigned device build.
`--signed` adds device provisioning; `apple` runs both platforms with shared tests
once. Shared workflows use protocol doubles without Firebase/network access;
iOS Firestore and Google presentation adapters are compiled in the full app.
Real-device runtime checks are listed in the
[architecture guide](../../../docs/apple-ios-app.md#validation).

# CloudGateway iOS

Native iOS app project home.

Targets:

* CloudGateway app: `com.gocloudlaunch.gateway`
* Packet tunnel extension: `com.gocloudlaunch.gateway.tunnel`

Both targets should use the app group `group.com.gocloudlaunch.gateway`.

## Firebase Config Manager

The app target uses Firebase email/password auth, reads Firestore directly, and verifies access through the first enabled region API endpoint:

```text
https://<regionId>.gocloudlaunch.com/api/auth/check-access
```

The signed-in user can browse enabled regions, see region capacity, filter owned configs by region, create a config in the selected region, delete a selected config, refresh Firestore/API state, and install/start/stop a chosen WireGuard config internally. The app does not auto-select a VPN config, and it does not use pasted configs, QR codes, the WireGuard app, or manual config files.

Regional API calls use the selected region endpoint:

```text
GET    https://<regionId>.gocloudlaunch.com/api/capacity
POST   https://<regionId>.gocloudlaunch.com/api/clients
DELETE https://<regionId>.gocloudlaunch.com/api/clients/{clientId}
POST   https://<regionId>.gocloudlaunch.com/api/admin/sync
```

`POST /admin/sync` is shown only for admins. The UI displays sync counts, not the raw audit log.

Firebase packages are linked to the app target only:

* `FirebaseCore`
* `FirebaseAuth`
* `FirebaseFirestore`

Do not link Firebase to `CloudGatewayTunnel`. The packet tunnel extension receives the installed provider configuration from the containing app.

`GoogleService-Info.plist` belongs under `CloudGateway/` and must be included in the app bundle only. It contains Firebase app identifiers, not service account credentials.

## Current Limitations

The native iOS app has no dedicated XCTest target yet. Shared sorting, filtering, reconciliation, and cache behavior are covered by `CloudGatewayKit` tests; app-target service and view-model behavior is currently validated by the generic iOS build.

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

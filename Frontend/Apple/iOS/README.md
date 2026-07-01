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

`POST /admin/sync` is shown only for admins. The UI displays sync counts, not the raw audit log.

Firebase packages are linked to the app target only:

* `FirebaseCore`
* `FirebaseAuth`
* `FirebaseFirestore`

Do not link Firebase to `CloudGatewayTunnel`. The packet tunnel extension receives the installed provider configuration from the containing app.

`GoogleService-Info.plist` belongs under `CloudGateway/` and must be included in the app bundle only. It contains Firebase app identifiers, not service account credentials.

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

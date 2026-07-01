# CloudGateway iOS

Native iOS app project home.

Targets:

* CloudGateway app: `com.gocloudlaunch.gateway`
* Packet tunnel extension: `com.gocloudlaunch.gateway.tunnel`

Both targets should use the app group `group.com.gocloudlaunch.gateway`.

## Firebase MVP 1

The app target uses Firebase email/password auth, reads Firestore directly, verifies access through:

```text
https://us-sanjose-1.gocloudlaunch.com/api/auth/check-access
```

and lists the signed-in user's active client configs. The user chooses which config to install; the app does not auto-select a VPN config.

Firebase packages are linked to the app target only:

* `FirebaseCore`
* `FirebaseAuth`
* `FirebaseFirestore`

Do not link Firebase to `CloudGatewayTunnel`. The packet tunnel extension receives the installed provider configuration from the containing app.

`GoogleService-Info.plist` belongs under `CloudGateway/` and must be included in the app bundle only. It contains Firebase app identifiers, not service account credentials.

## No-Device Build Verification

From the repo root:

```sh
swift test --package-path Frontend/Apple/CloudGatewayKit
xcodebuild -list -project Frontend/Apple/iOS/CloudGateway.xcodeproj
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS build
```

The unsigned build proves compile health and package resolution. The signed build also checks explicit provisioning for the app and tunnel extension.

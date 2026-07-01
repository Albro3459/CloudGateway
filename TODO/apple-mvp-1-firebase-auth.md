# Apple MVP 1: Firebase Auth And Config Source

Goal: replace the MVP 0 pasted WireGuard config flow with the same Firebase/Auth/Firestore/API trust model used by the React dashboard. The iOS app lists the user's active configs and installs only the config the user chooses.

## Current Web Data Flow

The React site is the reference implementation for product data access.

* Firebase Auth signs users in.
* Firestore is read directly by provisioned frontend users.
* Firestore rules use `UserRoles/{uid}` as the authorization anchor.
* The regional FastAPI handles mutations and live WireGuard side effects.
* The frontend does not write `Instances` docs directly.

Read paths used by the web app:

* `UserRoles/{uid}` for role lookup.
* enabled `Regions` docs for available regions.
* collection group `Instances` filtered by `ownerUid` for normal users.
* all `Users` plus all `Instances` for admins.

Mutation paths used by the web app:

* `POST /api/auth/check-access`
* `GET /api/capacity`
* `POST /api/clients`
* `DELETE /api/clients/{clientId}`
* admin-only `POST /api/users`
* admin-only `POST /api/admin/sync`

All API calls use a Firebase ID token:

```text
Authorization: Bearer <firebase-id-token>
```

## Apple Client Direction

The iOS app should mirror the web trust model instead of introducing a separate config source.

App launch/sign-in flow:

1. Configure Firebase.
2. Sign in with Firebase email/password.
3. Fetch the Firebase ID token.
4. Read enabled `Regions` from Firestore.
5. Call `POST /api/auth/check-access`.
6. Read this user's `Instances` docs from Firestore.
7. Show active clients with non-empty `wireguardConfig`, using client display name plus region display name.
8. Install or update the local Network Extension tunnel only after the user chooses a config.

The app should not ask normal users to paste or edit WireGuard config. The pasted config UI is a debug fallback only.

For this first native implementation, iOS uses:

```text
https://us-sanjose-1.gocloudlaunch.com/api/auth/check-access
```

for access verification. Region-derived native API routing can replace this later. Firestore region `displayOrder` is still used for display and config-list sorting.

MVP 2 replaced this temporary access-check endpoint with region-derived native API routing. The app now uses the first enabled region for access verification and the selected/config region for capacity, create, delete, and sync calls.

## Source Of Truth And Cache

Firestore/API state is authoritative. Local Apple storage is a cache of the last known usable config.

The cache should store enough metadata to reconcile safely:

* `clientId`
* `regionId`
* `clientName`
* `status`
* `wireguardConfig`
* `readAt`
* `updatedAt` or equivalent server timestamp if available

Reconciliation rules:

* User chooses a remote active config: cache it and install/update the tunnel.
* Remote active config matches the cached installed client: keep current tunnel.
* Cached client is removed, disabled, or missing `wireguardConfig`: show stale state and require the user to choose another config before reinstalling.
* Remote is unavailable: allow the cached installed tunnel to remain usable, but show stale/offline state.

Do not merge local and remote configs. Do not auto-select or auto-install a config for the user.

## Firebase SDK Setup

Use Swift Package Manager, matching Firebase's Apple setup guidance.

Xcode steps:

1. Open `Frontend/Apple/iOS/CloudGateway.xcodeproj`.
2. Use `File > Add Packages`.
3. Add:

```text
https://github.com/firebase/firebase-ios-sdk
```

4. Add products to the app target:

```text
FirebaseCore
FirebaseAuth
FirebaseFirestore
```

The current package resolution uses Firebase iOS SDK `11.15.0`.

Do not add Firebase products to the packet tunnel extension unless the extension explicitly needs them later. The tunnel should keep using provider configuration from the containing app.

Analytics is not required for MVP 1. If analytics is later enabled, prefer an explicit product decision before adding `FirebaseAnalytics` or `FirebaseAnalyticsWithoutAdId`.

## GoogleService-Info.plist

The provided `GoogleService-Info.plist` is for:

* Firebase project: `cloud-launch-gateway`
* iOS bundle ID: `com.gocloudlaunch.gateway`
* Google app ID prefix: `1:970881639303:ios`

Handling rules:

* Add the file to the iOS app target only.
* Do not add it to `CloudGatewayTunnel`.
* Keep the filename exactly `GoogleService-Info.plist`.
* Place it under the app target folder when implemented:

```text
Frontend/Apple/iOS/CloudGateway/GoogleService-Info.plist
```

Firebase documents this plist as containing project/app identifiers, not private secrets, but access is still enforced by Firebase Auth and Firestore rules. Do not put Firebase service account credentials in the app.

## SwiftUI Initialization

Firebase must be configured at app startup using an app delegate adapter.

Target shape:

```swift
import FirebaseCore
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        return true
    }
}

@main
struct CloudGatewayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

## Shared Apple Architecture

Decision: keep Firebase as an app-level adapter and keep the shared config manager in `CloudGatewayKit`.

This avoids a large iOS-to-macOS refactor later without turning MVP 1 into a generic sync framework. `CloudGatewayKit` should own platform-neutral config state, validation, selection, reconciliation, cache writes, and VPN install orchestration. The iOS and macOS app targets should own Firebase setup, Auth, Firestore reads, regional API calls, and SwiftUI lifecycle.

Current layers:

* iOS app target: SwiftUI screens, Firebase app setup, Firebase/Auth/Firestore adapter, regional API adapter, platform composition.
* `CloudGatewayKit`: shared models, config manager, config selection/reconciliation, cache updates, VPN install/update/remove/start/stop.
* Future macOS app: reuse `CloudGatewayKit`, provide macOS-specific UI, Firebase setup, and platform composition.
* Packet tunnel extension: VPN runtime only; no Firebase dependency for MVP 1.

Initial shared model names can mirror Firestore/API concepts:

* `CloudGatewayRegion`
* `CloudGatewayClient`
* `CloudGatewayConfigSnapshot`
* `CloudGatewayConfigSelection`
* `CloudGatewayConfigCache`
* `CloudGatewayConfigManager`

The non-UI config orchestration now lives in `CloudGatewayConfigManager` in `CloudGatewayKit`. It depends on protocols for VPN installation and cache storage. The first concrete remote implementation remains Firebase-backed in the iOS app target.

## MVP 1 Acceptance

Done when:

* The app target links `FirebaseCore`, `FirebaseAuth`, and `FirebaseFirestore`.
* Firebase configures on launch.
* Email/password sign-in and sign-out work.
* Signed-in users are access-checked through the regional API.
* Owned active configs are listed with client display name and region display name.
* The app installs only the user-selected config.
* No Firebase SDK products are linked to the packet tunnel extension.
* `swift test`, unsigned generic iOS build, and signed generic iOS build have been attempted and documented.

## References

* Firebase Apple setup: `https://firebase.google.com/docs/ios/setup`
* Firebase iOS SDK repo: `https://github.com/firebase/firebase-ios-sdk`
* Firebase email/password auth on Apple platforms: `https://firebase.google.com/docs/auth/ios/password-auth`
* Firestore quickstart: `https://firebase.google.com/docs/firestore/quickstart`
* Swift Package Manager: `https://swift.org/package-manager/`

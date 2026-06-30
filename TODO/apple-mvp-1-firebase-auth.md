# Apple MVP 1: Firebase Auth And Config Source

Goal: replace the MVP 0 pasted WireGuard config flow with the same Firebase/Auth/Firestore/API model used by the React dashboard.

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
7. Select an active client with a non-empty `wireguardConfig`.
8. Install or update the local Network Extension tunnel with that config.

The app should not ask the user to paste or edit WireGuard config. The local pasted config UI remains a debug tool only until this flow replaces it.

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

* Remote active config exists and differs from cache: cache it and reinstall/update the tunnel.
* Remote active config matches cache: keep current tunnel.
* Remote client is removed, disabled, or missing `wireguardConfig`: remove or disable the local tunnel.
* Remote is unavailable: allow the cached installed tunnel to remain usable, but show stale/offline state.

Do not merge local and remote configs. Accept the remote config or keep the last known cached config only when offline.

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

Keep Firebase-specific code out of SwiftUI views where practical.

Proposed layers:

* iOS app target: SwiftUI screens, Firebase app setup, platform composition.
* `CloudGatewayKit`: shared models, config selection/reconciliation, VPN install/update/remove/start/stop.
* Future macOS app: reuse `CloudGatewayKit`, provide macOS-specific UI and Firebase setup.

Initial shared model names can mirror Firestore/API concepts:

* `CloudGatewayRegion`
* `CloudGatewayClient`
* `CloudGatewayUserRole`
* `CloudGatewayConfigSnapshot`
* `CloudGatewayConfigCoordinator`

## References

* Firebase Apple setup: `https://firebase.google.com/docs/ios/setup`
* Firebase iOS SDK repo: `https://github.com/firebase/firebase-ios-sdk`
* Firebase email/password auth on Apple platforms: `https://firebase.google.com/docs/auth/ios/password-auth`
* Firestore quickstart: `https://firebase.google.com/docs/firestore/quickstart`
* Swift Package Manager: `https://swift.org/package-manager/`

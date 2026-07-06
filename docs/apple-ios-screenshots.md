# CloudGateway iOS Screenshots

Use the `CloudGatewayScreenshots` scheme to launch a simulator-only copy of the app for App Store screenshots. This target renders the real SwiftUI interface with fixture data for `john@test.com`, but it does not embed the packet tunnel extension, link WireGuardKit, or initialize Firebase.

This target is only for screenshots. Do not archive or submit it.

## Simulators

- 6.9" Display screenshots: `iPhone 17 Pro Max`
- 13" Display: `iPad Pro 13-inch (M5)`

## Build

From the repo root:

```sh
SIMULATOR_DEVICE="iPhone 17 Pro Max" # or "iPad Pro 13-inch (M5)"

DERIVED_DATA=/private/tmp/CloudGatewayScreenshotsDerivedData

xcodebuild \
  -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
  -scheme CloudGatewayScreenshots \
  -destination "platform=iOS Simulator,name=${SIMULATOR_DEVICE},OS=26.5" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The simulator build is unsigned and intentionally avoids the production tunnel target. The production app still embeds `CloudGatewayTunnel.appex`; the screenshot app bypasses it because the simulator cannot link WireGuard's device-only Go archive.

## Boot And Launch

The easiest workflow is to open Xcode, select the `CloudGatewayScreenshots` scheme, choose an iPhone simulator, and press Run.

For command-line launch after the build above:

```sh
xcrun simctl boot "$SIMULATOR_DEVICE"
xcrun simctl bootstatus booted -b
open -a Simulator

xcrun simctl install booted "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CloudGatewayScreenshots.app"
xcrun simctl launch booted com.gocloudlaunch.gateway.screenshots
```

If the simulator is already booted, `simctl boot` may report that state; continue with `bootstatus`, install, and launch.

## Fixture State

The app opens directly to the signed-in dashboard:

- User: `john@test.com`
- Role: normal user, not admin
- Regions: `California` (`us-sanjose-1`) and `Chicago` (`us-ashburn-1`)
- Clients: `John's iPhone` in San Jose and `John's iPad` in Ashburn
- Tunnel controls use in-memory fake state only

Admin-only panels and sync/grant-access controls should not appear.

## Capture Checklist

Use Simulator's `File > New Screenshot` menu item for manual App Store captures.

App Store screenshots:

- Dashboard
- VPN client details
- About page
- Login page

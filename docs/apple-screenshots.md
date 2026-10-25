# Apple screenshots

Run commands from the repository root. These workflows capture UI without
changing VPN connections.

## iOS App Store

Use the `CloudGatewayScreenshots` scheme to launch a simulator-only copy of the app for App Store screenshots. This target renders the real SwiftUI interface with fixture data for `john@test.com`, but it does not embed the packet tunnel extension, link WireGuardKit, or initialize Firebase.

This target is only for screenshots. Do not archive or submit it.

### Simulators

- 6.9" Display screenshots: `iPhone 17 Pro Max`
- 13" Display: `iPad Pro 13-inch (M5)`

### Build

From the repo root:

```sh
SIMULATOR_DEVICE="iPhone 17 Pro Max" # or "iPad Pro 13-inch (M5)"

DERIVED_DATA=/private/tmp/CloudGatewayScreenshotsDerivedData

xcodebuild \
  -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
  -scheme CloudGatewayScreenshots \
  -destination "platform=iOS Simulator,name=${SIMULATOR_DEVICE},OS=26.0" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The production tunnel uses a device-only Go archive, so simulator captures use
this separate unsigned target.

### Boot And Launch

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

### Fixture State

The app opens directly to the signed-in dashboard:

- User: `john@test.com`
- Role: normal user, not admin
- Regions: `California` (`us-sanjose-1`) and `Chicago` (`us-ashburn-1`)
- Clients: `John's iPhone` in San Jose and `John's iPad` in Ashburn
- Tunnel controls use in-memory fake state only

Admin-only panels and sync/grant-access controls should not appear.

### Capture Checklist

Use Simulator's `File > New Screenshot` menu item for manual App Store captures.

App Store screenshots:

- Dashboard
- VPN client details
- About page
- Login page

## macOS menu

Capture the running app's actual native menu over a temporary plain backdrop.
The script saves a PNG with the native rounded corners and shadow. It briefly
covers the desktop while you open the CloudGateway menu, captures it, then
removes the backdrop and returns to your previous app.

1. Run CloudGateway and prepare the state to show, such as a connected VPN.
2. Close other CloudGateway dialogs and leave its menu closed.
3. From the repository root, run:

   ```sh
   swift scripts/macos-menu-screenshot.swift
   ```

4. When the plain backdrop appears, click the CloudGateway menu bar icon within
   30 seconds. Leave the pointer on the icon so no menu row is highlighted.
   The script captures the menu automatically after it opens.

The default output is `docs/images/macos-menu.png`. To save another copy:

```sh
swift scripts/macos-menu-screenshot.swift /tmp/cloudgateway-menu.png
```

The app launching the command needs Screen Recording access.
For the first capture, request the permissions with:

```sh
swift scripts/macos-menu-screenshot.swift --permissions
```

In System Settings → Privacy & Security, enable the launching app (Terminal or
T3 Code, as identified by macOS) under Screen Recording. If
macOS requests a restart of that app, restart it, then rerun the capture command.
The script uses the live menu state and does not change VPN connections.

# MVP 0 Implementation Plan

Goal: prove CloudGateway can ship an iOS app with a packet tunnel extension, receive the required Network Extension entitlement, install a VPN profile, and start a WireGuard tunnel on a real iPhone.

## Scope

Build only the entitlement and tunnel proof. Keep the UI plain and keep product flows out.

Use:

* App bundle ID: `com.gocloudlaunch.gateway`
* Tunnel bundle ID: `com.gocloudlaunch.gateway.tunnel`
* App group: `group.com.gocloudlaunch.gateway`
* WireGuardKit Swift package URL: `https://github.com/Albro3459/wireguard-apple`

Do not add Sign in with Apple, Firestore reads, API config fetches, client creation/removal, region selection, or macOS targets in this stage.

## Step 1: Create Xcode Project

Create the iOS app under:

```text
Frontend/Apple/iOS/
```

Use:

* Product name: `CloudGateway`
* Interface: SwiftUI
* Language: Swift
* Bundle ID: `com.gocloudlaunch.gateway`
* Signing: automatic

Add a Packet Tunnel Provider extension target:

* Target name: `CloudGatewayTunnel`
* Bundle ID: `com.gocloudlaunch.gateway.tunnel`
* Provider class: `PacketTunnelProvider`

## Step 2: Configure Capabilities

App target:

* App Groups: `group.com.gocloudlaunch.gateway`
* Data Protection: Protected Until First User Authentication

Tunnel target:

* App Groups: `group.com.gocloudlaunch.gateway`
* Data Protection: Protected Until First User Authentication
* Network Extensions: Packet Tunnel

Verify the tunnel entitlements include:

```xml
<key>com.apple.developer.networking.networkextension</key>
<array>
  <string>packet-tunnel-provider</string>
</array>
```

## Step 3: Add WireGuardKit

Add Swift package dependency:

```text
https://github.com/Albro3459/wireguard-apple
```

Current project note: the package is pinned to patched fork revision `ba0929fb7fc63ec604d69c35abf47688d17a6252`. The patch line is based on official revision `ccc7472fd7d1c7c19584e6a30c45a56b8ba57790`, fixes an Xcode 26 `WireGuardKitC` module build issue, and includes the Go discovery fix needed for Xcode GUI builds on ARM macOS.

Link `WireGuardKit` to:

* app target
* tunnel extension target

Add the required external build target:

* Target type: External Build System
* Product name: `WireGuardGoBridgeiOS`
* Build tool: `/usr/bin/make`
* Directory:

```text
$(BUILD_DIR)/../../SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo
```

Set that target's `SDKROOT` to:

```text
iphoneos
```

Add `WireGuardGoBridgeiOS` as a dependency of the tunnel extension target.

Local build prerequisite: Go must be installed and visible to Xcode. The WireGuard bridge target uses Go to build `libwg-go.a`.

Resolved Xcode 26 blocker: official WireGuardKit failed to build `WireGuardKitC` because `WireGuardKitC.h` used Darwin typedefs before importing the module that defines them. The CloudGateway fork adds the missing system include before the `ctl_info` and `sockaddr_ctl` declarations.

## Step 4: Add Minimal CloudGatewayKit Boundary

Create a minimal local Swift package under:

```text
Frontend/Apple/CloudGatewayKit/
```

For MVP 0, keep CloudGatewayKit small:

* `GatewayPlatformConfiguration`
* `GatewayVPNManager`
* `GatewayTunnelStatus`
* hardcoded/manual config input path

Design constraint: even in MVP 0, inject app group ID, app bundle ID, provider bundle ID, and display name instead of hardcoding them deep in CloudGatewayKit.

The iOS SwiftUI app should call CloudGatewayKit. SwiftUI views should not call `NETunnelProviderManager` directly.

## Step 5: Install VPN Profile

Implement `GatewayVPNManager.installTunnel(...)` around `NETunnelProviderManager`.

For MVP 0, use one known-good WireGuard config. It can be hardcoded or pasted into a debug text field.

The installed profile should include:

* `providerBundleIdentifier`: `com.gocloudlaunch.gateway.tunnel`
* localized description: `CloudGateway`
* provider configuration containing the WireGuard config or a pointer to app-group stored config

Done when tapping "Install" triggers the iOS VPN permission prompt and saves a visible VPN profile in Settings.

## Step 6: Start And Stop Tunnel

Implement app controls:

* Install
* Start
* Stop
* status/error text

Use `NETunnelProviderSession.startTunnel()` and `stopVPNTunnel()` through CloudGatewayKit.

Observe status via `NEVPNStatusDidChange`.

## Step 7: Implement Packet Tunnel Provider

In the tunnel extension:

* import NetworkExtension
* import WireGuardKit
* create `WireGuardAdapter`
* load the saved/manual config
* convert it into `TunnelConfiguration`
* call `adapter.start(tunnelConfiguration:)`
* stop with `adapter.stop`

Use the upstream `wireguard-apple` packet tunnel provider as the reference implementation, but keep CloudGateway-specific code small.

## Step 8: Real Device Verification

Use a real iPhone. Simulator is not enough for packet tunnel proof.

Verify:

* Xcode signs app and tunnel targets.
* The provisioning profile contains `packet-tunnel-provider`.
* Install prompt appears.
* VPN profile appears in iOS Settings.
* Tunnel extension starts.
* WireGuard interface comes up.
* Stop turns the tunnel off.
* App relaunch still sees the installed profile/status.

## No-Device Build Verification

When no iPhone is available, use these checks to verify the app is ready for device testing. These checks prove compile health, package resolution, signing/profile setup, and generated entitlements. They do not prove that the packet tunnel can install or pass traffic.

Run CloudGatewayKit tests:

```sh
swift test
```

from:

```text
Frontend/Apple/CloudGatewayKit
```

Run an unsigned generic iOS build:

```sh
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
```

This catches Swift/package/project build failures without requiring provisioning to be correct.

Run a signed generic iOS build:

```sh
xcodebuild -project Frontend/Apple/iOS/CloudGateway.xcodeproj -scheme CloudGateway -destination generic/platform=iOS build
```

This checks that Xcode can resolve Swift packages, build `WireGuardGoBridgeiOS`, sign the app and tunnel extension, and use explicit provisioning profiles for:

* `com.gocloudlaunch.gateway`
* `com.gocloudlaunch.gateway.tunnel`

If signing fails with `iOS Team Provisioning Profile: *`, Xcode is using a wildcard profile. The app and tunnel need explicit profiles because App Groups, Data Protection, and Network Extension entitlements cannot be satisfied by a wildcard profile.

Inspect generated entitlements after a signed build:

```sh
cat ~/Library/Developer/Xcode/DerivedData/CloudGateway-*/Build/Intermediates.noindex/CloudGateway.build/Debug-iphoneos/CloudGateway.build/CloudGateway.app.xcent
cat ~/Library/Developer/Xcode/DerivedData/CloudGateway-*/Build/Intermediates.noindex/CloudGateway.build/Debug-iphoneos/CloudGatewayTunnel.build/CloudGatewayTunnel.appex.xcent
```

Expected app entitlements include:

* `com.apple.security.application-groups` with `group.com.gocloudlaunch.gateway`
* `com.apple.developer.default-data-protection`

Expected tunnel entitlements include:

* `com.apple.security.application-groups` with `group.com.gocloudlaunch.gateway`
* `com.apple.developer.default-data-protection`
* `com.apple.developer.networking.networkextension` with `packet-tunnel-provider`

The app target may also include Sign in with Apple or Network Extension if those capabilities are enabled in Xcode. The tunnel target must include `packet-tunnel-provider`.

Known WireGuard build prerequisite:

* Go must be installed.
* The CloudGateway WireGuard fork is patched so Xcode GUI builds can find Homebrew Go from `/opt/homebrew/bin` when building `WireGuardGoBridgeiOS`.

Simulator note:

* The simulator is useful for UI and some compile checks.
* Packet tunnel behavior must be verified on a real iPhone.
* WireGuard Go bridge builds for simulator can fail on Apple Silicon depending on architecture/toolchain settings, so generic iOS/device builds are the better readiness check.

## Acceptance Criteria

MVP 0 is complete when:

* A fresh clone can resolve WireGuardKit from `https://github.com/Albro3459/wireguard-apple`.
* No local WireGuardKit checkout is required to build.
* Xcode builds the app and packet tunnel extension.
* A real iPhone can install the CloudGateway VPN profile.
* A real iPhone can start and stop a WireGuard tunnel.
* The implementation path does not block later macOS reuse of CloudGatewayKit.

## Expected Follow-Up

After MVP 0 works, move to MVP 1:

* add Firebase email/password auth
* read enabled regions and owned client configs from Firestore
* verify account access through the regional API
* list active configs by display name and region
* install/update only the config chosen by the user
* cache the last installed config in app-group storage

# MVP 0 Implementation Plan

Goal: prove CloudGateway can ship an iOS app with a packet tunnel extension, receive the required Network Extension entitlement, install a VPN profile, and start a WireGuard tunnel on a real iPhone.

## Scope

Build only the entitlement and tunnel proof. Keep the UI plain and keep product flows out.

Use:

* App bundle ID: `com.gocloudlaunch.gateway`
* Tunnel bundle ID: `com.gocloudlaunch.gateway.tunnel`
* App group: `group.com.gocloudlaunch.gateway`
* WireGuardKit Swift package URL: `https://git.zx2c4.com/wireguard-apple`

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
https://git.zx2c4.com/wireguard-apple
```

Current project note: the package is pinned to official revision `ccc7472fd7d1c7c19584e6a30c45a56b8ba57790` because the current upstream `Package.swift` declares Swift tools 5.3 while using newer platform declarations that Xcode 26 rejects.

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

Known Xcode 26 blocker: official WireGuardKit currently fails to build `WireGuardKitC` because `WireGuardKitC.h` uses Darwin typedefs before importing the module that defines them. A tiny upstream/fork patch should add the missing system include before the `ctl_info` and `sockaddr_ctl` declarations.

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

## Acceptance Criteria

MVP 0 is complete when:

* A fresh clone can resolve WireGuardKit from `https://git.zx2c4.com/wireguard-apple`.
* No local WireGuardKit checkout is required to build.
* Xcode builds the app and packet tunnel extension.
* A real iPhone can install the CloudGateway VPN profile.
* A real iPhone can start and stop a WireGuard tunnel.
* The implementation path does not block later macOS reuse of CloudGatewayKit.

## Expected Follow-Up

After MVP 0 works, move to MVP 1:

* remove hardcoded config assumptions
* formalize CloudGatewayKit config models
* add install/update/remove APIs
* add app-group storage
* keep the same API shape for future macOS support

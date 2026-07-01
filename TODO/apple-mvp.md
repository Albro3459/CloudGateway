# Apple MVP Progression

## Direction

Build the Apple client stack iOS-first, with shared code in `Frontend/Apple/CloudGatewayKit` and future macOS reuse through `Frontend/Apple/macOS`.

CloudGatewayKit should be designed as the reusable Apple client core, not as an iOS-only helper. Keep platform-specific code behind small boundaries so the same CloudGatewayKit models, config manager, tunnel lifecycle API, validation, and app-group storage strategy can serve both iOS and macOS.

Use WireGuardKit as a Swift Package dependency from:

```text
https://git.zx2c4.com/wireguard-apple
```

Do not rely on a local `/Users/alexbrodsky/GitHub/wireguard-apple` checkout for the project dependency. The local clone is useful for reading source and examples, but the Xcode project should be reproducible from the package URL.

## Core Architecture

```text
Frontend/Apple/iOS
  -> CloudGateway iOS app
  -> Packet tunnel extension
  -> depends on CloudGatewayKit

Frontend/Apple/CloudGatewayKit
  -> CloudGateway VPN/config manager wrapper
  -> owns NETunnelProviderManager integration
  -> owns app-group shared config storage
  -> wraps WireGuardKit-facing models
  -> keeps iOS/macOS differences isolated behind platform adapters

WireGuardKit
  -> upstream Swift package from wireguard-apple
  -> provides WireGuardAdapter, TunnelConfiguration, keys, peers, and packet tunnel support
```

## CloudGatewayKit Design Rules

Build iOS first, but shape CloudGatewayKit so macOS can reuse the core without a large refactor.

Rules:

* Keep SwiftUI views and app lifecycle code outside CloudGatewayKit.
* Keep direct `NETunnelProviderManager` usage behind CloudGatewayKit APIs.
* Keep WireGuardKit mapping/parsing behind CloudGatewayKit APIs.
* Inject platform values instead of hardcoding them: app group ID, app bundle ID, provider bundle ID, tunnel display name, storage locations, and entitlement-related identifiers.
* Keep iOS/macOS differences in small platform adapters or configuration structs.
* Name shared types without iOS-only assumptions.
* Prefer a small shared API surface that can serve both apps: install/update/remove, start/stop, status observation, config validation, and config storage.

Avoid:

* Hardcoding iOS bundle IDs throughout CloudGatewayKit.
* Letting SwiftUI views call NetworkExtension directly.
* Designing storage around a single app target.
* Naming core types around iPhone/iOS when they are really Apple-platform concepts.
* Burying WireGuardKit conversion logic inside app UI code.

## MVP 0: Entitlement And Tunnel Proof

Goal: prove Apple signing, Network Extension entitlement, and WireGuardKit tunnel startup work on a real iPhone.

Build:

* iOS app target: `com.gocloudlaunch.gateway`
* Packet tunnel extension target: `com.gocloudlaunch.gateway.tunnel`
* App Group on both targets: `group.com.gocloudlaunch.gateway`
* Network Extension capability for the tunnel target
* WireGuardKit Swift package dependency from `https://git.zx2c4.com/wireguard-apple`
* External `WireGuardGoBridgeiOS` build target as required by WireGuardKit
* One hardcoded or manually pasted WireGuard config
* Minimal UI: install VPN profile, start tunnel, stop tunnel, show status/error text

Done when:

* Xcode signs both targets with managed signing.
* The tunnel entitlement includes `packet-tunnel-provider`.
* iOS shows the system VPN permission prompt.
* The app installs a `NETunnelProviderManager` profile.
* The packet tunnel extension starts on device.
* WireGuardKit brings up the tunnel with a known-good config.

Non-goals:

* Sign in with Apple
* Firestore reads
* API config fetching
* Region picker
* Client creation/removal
* Full config manager UI
* macOS app

## MVP 1: CloudGatewayKit Config Manager Spine

Goal: replace hardcoded tunnel setup with a small reusable CloudGatewayKit API.

Design the API for both iOS and macOS from the start, even if only the iOS app uses it during this stage.

Build:

* `GatewayVPNManager`
* `GatewayTunnelConfiguration`
* WireGuard config parsing/validation boundary
* Install/update/remove VPN profile methods
* Start/stop methods
* Tunnel status observation
* App Group storage for the selected config

Done when:

* The iOS app no longer talks directly to `NETunnelProviderManager`.
* CloudGatewayKit can install, update, remove, start, and stop one CloudGateway tunnel.
* The tunnel extension can load the config needed to start from the app-managed profile/shared storage.
* The core CloudGatewayKit API does not expose iOS-only assumptions that would block a macOS client.

## MVP 2: CloudGateway Config Source

Goal: connect the app to real CloudGateway configuration data.

Build:

* Firebase email/password auth
* Firestore reads for enabled regions and owned client configs
* Regional API access verification with a Firebase ID token
* User-selected active config list showing client display name and region
* Save the user-selected config through CloudGatewayKit
* Replace the installed VPN profile only when the user chooses a config
* Clear/remove local config when the user removes the VPN client

Done when:

* A real user's active configs can be listed.
* The user can choose which config to install.
* The app can reconnect after a config update.
* The app can remove the VPN profile and local config cleanly.

## MVP 3: Product Flow

Goal: turn the proof into the first usable CloudGateway iOS app.

Build:

* Sign in with Apple
* Account/session handling
* Region selection
* Client create/remove flow
* Config fetch/install flow
* Connection status and error recovery
* Basic privacy-safe diagnostics

Done when:

* A new user can sign in, create or receive a client config, install the VPN, connect, disconnect, and remove the VPN from the app.

## MVP 4: macOS Reuse

Goal: reuse CloudGatewayKit for the macOS app.

Build:

* macOS app target
* macOS packet tunnel extension
* macOS-specific signing/capability setup
* Shared CloudGatewayKit APIs with platform-specific wrappers only where needed

Done when:

* macOS can install, start, stop, and remove a CloudGateway WireGuard tunnel using the same CloudGatewayKit core model as iOS.

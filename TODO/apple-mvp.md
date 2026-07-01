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
* Keep Firebase SDK imports and concrete Auth/Firestore queries outside CloudGatewayKit; app targets should map Firebase data into shared models.
* Keep direct `NETunnelProviderManager` usage behind CloudGatewayKit APIs.
* Keep WireGuardKit mapping/parsing behind CloudGatewayKit APIs.
* Inject platform values instead of hardcoding them: app group ID, app bundle ID, provider bundle ID, tunnel display name, storage locations, and entitlement-related identifiers.
* Keep iOS/macOS differences in small platform adapters or configuration structs.
* Name shared types without iOS-only assumptions.
* Prefer a small shared API surface that can serve both apps: install/update/remove, start/stop, status observation, config validation, and config storage.
* Put the shared config manager in CloudGatewayKit, backed by protocols for remote config loading, access checking, VPN installation, and cache storage.

Avoid:

* Hardcoding iOS bundle IDs throughout CloudGatewayKit.
* Linking Firebase into the packet tunnel extension.
* Making CloudGatewayKit depend on Firebase concrete types.
* Letting SwiftUI views call NetworkExtension directly.
* Designing storage around a single app target.
* Naming core types around iPhone/iOS when they are really Apple-platform concepts.
* Burying WireGuardKit conversion logic inside app UI code.

## MVP 0: Entitlement And Tunnel Proof

**Status: Completed** — validated on device (managed signing, `packet-tunnel-provider` entitlement, system VPN prompt, `NETunnelProviderManager` install, and WireGuardKit tunnel bring-up).

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

**Status: Completed** — non-UI orchestration lives in `CloudGatewayConfigManager` (install/update/remove/start/stop, status, reconciliation, cache) behind VPN and cache protocols; the app no longer touches `NETunnelProviderManager` directly and the core API carries no iOS-only assumptions.

Goal: replace hardcoded or view-model-owned tunnel setup with a small reusable CloudGatewayKit config manager API.

Design the API for both iOS and macOS from the start, even if only the iOS app uses it during this stage.

Build:

* `GatewayVPNManager`
* `CloudGatewayConfigManager`
* `GatewayTunnelConfiguration`
* WireGuard config parsing/validation boundary
* User-selected active config list state
* Local/remote config reconciliation
* Install/update/remove VPN profile methods
* Start/stop methods
* Tunnel status observation
* App Group storage for the selected config

Done when:

* The iOS app no longer talks directly to `NETunnelProviderManager`.
* Non-UI config orchestration lives in CloudGatewayKit instead of the SwiftUI view model.
* CloudGatewayKit can install, update, remove, start, and stop one CloudGateway tunnel.
* The tunnel extension can load the config needed to start from the app-managed profile/shared storage.
* The core CloudGatewayKit API does not expose iOS-only assumptions that would block a macOS client.

## MVP 1: CloudGateway Config Source

**Status: Completed** — see [apple-mvp-1-firebase-auth.md](apple-mvp-1-firebase-auth.md) acceptance. Firebase email/password auth, Firestore region/client reads, ID-token access checks, user-selected config install/update/remove, and cache reconciliation are in place; superseded by MVP 2's region-derived routing.

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

## MVP 2: Native Config Manager

**Status: Completed** — region-derived API routing, enabled-region picker with per-region capacity, owned-config list, create/delete (with confirmation)/refresh/admin-sync, and selected-config install/update/start/stop through CloudGatewayKit are all implemented and tested. `./scripts/test.sh apple` is green.

Goal: make the iOS app a real CloudGateway config manager for signed-in users.

Build:

* Region-aware API routing using `https://<regionId>.gocloudlaunch.com/api/*`.
* Enabled region picker/filter backed by global Firestore `Regions` reads.
* Per-region capacity display through `GET /capacity`.
* Owned config list showing display name, status, and region.
* Create config flow through `POST /clients` in the selected region.
* Delete config flow through `DELETE /clients/{clientId}` in the config's region, with destructive confirmation.
* Refresh state from Firestore/API.
* Admin-only selected-region peer sync through `POST /admin/sync`, showing counts but not raw peer audit logs.
* Install/update/start/stop the explicitly selected active config through CloudGatewayKit and the packet tunnel extension.

Done when:

* Firebase/Firestore/API are the authenticated source of truth.
* Local Apple cache remains only an offline/stale cache and is overwritten by remote truth after auth.
* The app does not auto-select configs.
* The app does not use pasted config UI, QR codes, the external WireGuard app, or manual config files.
* Shared sorting, filtering, reconciliation, and cache behavior are covered by CloudGatewayKit tests.
* `./scripts/test.sh apple` passes for CloudGatewayKit tests and the unsigned no-device iOS build.

Known limitations:

* View-model orchestration tests live in `Frontend/Apple/iOS/CloudGatewayTests/` against a mock `CloudGatewayServicing` and now run in the `./scripts/test.sh apple` gate via `xcodebuild test` on the `CloudGatewayTests` scheme. They are a host-less logic bundle because the app scheme can't build for the simulator (the packet-tunnel extension links WireGuard's device-only `libwg-go.a`); the simulator is overridable with `APPLE_TEST_SIMULATOR`. The thin Firebase/URLSession adapter stays build-validated only.
* Signed no-device build still depends on local signing/provisioning setup and should be run with `./scripts/test.sh apple --signed` when provisioning is available.
* Capacity failures are shown as unavailable; create still relies on the regional API for the authoritative capacity/limit rejection.

## MVP 3: Product Flow

Goal: turn the proof into the first usable CloudGateway iOS app.

Build:

* Sign in with Apple
* Account/session handling
* Connection status and error recovery
* Basic privacy-safe diagnostics
* App polish around MVP2 config manager flows

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

# CloudGateway Apple Shared Packages

This package exports two products for the CloudGateway iOS app and future macOS
app. They deliberately share workflows and VPN behavior without sharing app UI:

* `CloudGatewayKit` owns VPN/configuration, app-group cache metadata, Keychain
  config secrets, and packet-tunnel health. Both containing apps and both
  packet-tunnel extensions may import it.
* `CloudGatewayAppCore` owns Firebase-free app contracts and DTOs, the regional
  control-plane client, service facade, observable app model, and presentation
  refresh lifecycle. Containing apps import it; packet-tunnel extensions do
  not.

`CloudGatewayAppCore` depends on `CloudGatewayKit`. Neither product imports
Firebase, Google Sign-In, SwiftUI, UIKit, or AppKit.

## CloudGatewayKit

CloudGatewayKit owns common tunnel configuration, app-group storage,
platform-neutral VPN control APIs, and the deterministic tunnel-health state
machine. WireGuardKit remains a dependency of each platform packet-tunnel
extension and is hidden behind the kit's plain `Sendable` adapter contracts.

Current shared responsibilities:

* `CloudGatewayVPNManager` owns install/update/remove/start/stop/status around `NETunnelProviderManager`.
* `CloudGatewayWireGuardConfig` validates raw WireGuard config text before install.
* `CloudGatewayRegion`, `CloudGatewayRegionCapacity`, `CloudGatewayClient`, and `CloudGatewayConfigSelection` provide Firebase/API-derived sorting, filtering, capacity display state, all-owned config options, and installable config options without importing Firebase.
* `CloudGatewayConfigCache` stores installed config metadata in the app group; full WireGuard configs live in shared Keychain secret storage so local tunnels remain usable when Firestore/API is temporarily unavailable without duplicating private keys in app-group files.
* `CloudGatewayConfigManager` owns user-selected install orchestration, local/remote reconciliation, cache update ordering, per-config stale state, and start/stop/remove decisions through protocol-backed tunnel and cache dependencies. It can also remove the matching local installed tunnel/cache when the app successfully deletes a remote config.
* `CloudGatewayTunnelHealthMonitor` owns one cancellable wake and callback-driven
  runtime effects without awaiting WireGuard callbacks. It encapsulates the
  coordinator, evaluator/recovery/path/persistence policies, generation-aware
  artifact reconciler, and cancellable FIFO effect-submission arbiter. Together
  they keep stop/restart cleanup bounded, order admitted effects ahead of
  normal adapter stop, and prevent prior-session completions from erasing newer
  shared state.
* `CloudGatewayTunnelHealthTiming.production` is the single timing contract for the
  extension producer and app-side snapshot freshness checks.

The health monitor uses injected monotonic time and a manual scheduler in
deterministic tests. Its plain callback protocols carry no Network,
WireGuardKit, or User Notifications types. A platform adapter maps WireGuard
results and capabilities, deduplicated `NWPath` fingerprints to satisfaction
plus route generation, and stable-ID notification registration/reconciliation.
Snapshot writes and clears enqueue on one private FIFO persistence lane and are
retried toward desired state after failures. Notification registration uses an
epoch fence across authorization and add callbacks so stop, withdrawal, and a
replacement session invalidate stale work synchronously.
The package builds for iOS 17 and macOS 14; that compatibility does not imply a
macOS app integration exists.

## CloudGatewayAppCore

Current shared app responsibilities:

* `CloudGatewayServicing` and the narrower auth, repository, control-plane,
  Google-presentation, notification, health-reader, and sleeper protocols form
  Firebase-free platform seams.
* `CloudGatewayControlPlaneClient` owns apex/regional URL construction, DTO
  encoding and decoding, authenticated request plumbing, error mapping, and
  bounded URL sessions.
* `CloudGatewayAppServiceFacade` composes auth, client persistence, control-plane
  access, and provider presentation behind the service consumed by the model.
* `CloudGatewayViewModel` owns guest/authenticated startup, role/access and
  region/client workflows, VPN command orchestration, destructive-operation
  guards, dead-tunnel presentation, and notification-authorization policy.
* `CloudGatewayViewModel`'s presentation monitor owns the immediate
  health/status refresh and the cancellable five-second presentation loop.
  Native views only start and cancel that operation from their platform
  lifecycle.
* `CloudGatewayServerHealthViewModel` owns mesh membership/link state and
  account-scoped ACL client-isolation state, with an independent Policy
  load-failure flag so a Policy read failure can never blank fresh Mesh
  state. `CloudGatewayMeshStatus` and `CloudGatewayPolicyStatus` own the pure
  derivations, ported from and kept in lockstep with the web helpers.
  `CloudGatewayFirestoreMeshMapper` and `CloudGatewayFirestorePolicyMapper`
  own Firebase-free document mapping; each platform's repository converts
  `Timestamp` to `Date` before calling them.

AppCore tests use protocol-backed doubles. They require no Firebase project,
credentials, network access, app host, packet extension, or UI target.

## Firebase Boundary

Both shared products stay platform-neutral and do not import Firebase SDK
products directly.

Firebase belongs behind containing-app adapters:

* iOS app: configures Firebase, composes the shared AppCore workflows with the
  local Firebase Auth package, iOS Firestore repository, and iOS Google
  presenter, and maps remote config data into Kit VPN/config types.
* Future macOS app: imports both shared products and supplies native Firebase,
  provider-presentation, lifecycle, notification, and UI composition.
* Packet tunnel extension: stays VPN-only and must not link Firebase unless a later product decision explicitly requires it.

Platform packet-tunnel extensions retain only lifecycle, WireGuardKit mapping,
`NWPathMonitor` fingerprinting, app-group store construction, User
Notifications mapping, and bounded stop composition. They must not duplicate
the evaluator/recovery state machine or add a second polling timer.

The shared config manager lives in CloudGatewayKit and depends on small
protocols instead of concrete Firebase types. AppCore depends on those Kit APIs
for VPN workflows. This keeps selection, stale-state reconciliation, cache
updates, install ordering, authentication/control-plane orchestration, and
presentation refresh reusable while native views and lifecycle policy remain
platform-owned.

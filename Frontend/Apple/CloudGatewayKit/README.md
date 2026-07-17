# CloudGatewayKit

Shared Apple VPN and tunnel-health core for CloudGateway iOS and future macOS
apps and packet-tunnel extensions.

CloudGatewayKit owns common tunnel configuration, app-group storage,
platform-neutral VPN control APIs, and the deterministic tunnel-health state
machine. WireGuardKit remains a dependency of each platform packet-tunnel
extension and is hidden behind the kit's plain `Sendable` adapter contracts.

Current shared responsibilities:

* `GatewayVPNManager` owns install/update/remove/start/stop/status around `NETunnelProviderManager`.
* `GatewayWireGuardConfig` validates raw WireGuard config text before install.
* `CloudGatewayRegion`, `CloudGatewayRegionCapacity`, `CloudGatewayClient`, and `CloudGatewayConfigSelection` provide Firebase/API-derived sorting, filtering, capacity display state, all-owned config options, and installable config options without importing Firebase.
* `CloudGatewayConfigCache` stores installed config metadata in the app group; full WireGuard configs live in shared Keychain secret storage so local tunnels remain usable when Firestore/API is temporarily unavailable without duplicating private keys in app-group files.
* `CloudGatewayConfigManager` owns user-selected install orchestration, local/remote reconciliation, cache update ordering, per-config stale state, and start/stop/remove decisions through protocol-backed tunnel and cache dependencies. It can also remove the matching local installed tunnel/cache when the app successfully deletes a remote config.
* `GatewayTunnelHealthCoordinator` composes the evaluator, recovery, path,
  persistence, and notification policies as a pure reducer with explicit
  session, wake, and operation tokens.
* `GatewayTunnelHealthMonitor` owns one cancellable wake and callback-driven
  runtime effects without awaiting WireGuard callbacks. Its generation-aware
  artifact reconciler and cancellable FIFO effect-submission arbiter keep
  stop/restart cleanup bounded, order admitted effects ahead of normal adapter
  stop, and prevent prior-session completions from erasing newer shared state.
* `GatewayTunnelHealthTiming.production` is the single timing contract for the
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

## Firebase Boundary

CloudGatewayKit should stay platform-neutral and should not import Firebase SDK products directly.

Firebase belongs in the app targets as an adapter:

* iOS app: configures Firebase, signs users in, reads Firestore, calls regional access APIs, and maps remote data into CloudGatewayKit models.
* Future macOS app: uses the same CloudGatewayKit models and manager APIs, with its own UI and Firebase setup.
* Packet tunnel extension: stays VPN-only and must not link Firebase unless a later product decision explicitly requires it.

Platform packet-tunnel extensions retain only lifecycle, WireGuardKit mapping,
`NWPathMonitor` fingerprinting, app-group store construction, User
Notifications mapping, and bounded stop composition. They must not duplicate
the evaluator/recovery state machine or add a second polling timer.

The shared config manager lives in CloudGatewayKit and depends on small protocols instead of concrete Firebase types. That keeps config selection, stale-state reconciliation, cache updates, and install ordering reusable across iOS and macOS while keeping Firebase, SwiftUI, and app lifecycle code outside the shared core.

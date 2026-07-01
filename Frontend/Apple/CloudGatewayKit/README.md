# CloudGatewayKit

Shared Apple VPN wrapper for CloudGateway iOS and macOS apps.

CloudGatewayKit is intended to wrap WireGuardKit and own the common tunnel configuration, app-group storage, and platform-neutral VPN control APIs used by the iOS app and future macOS app.

Current shared responsibilities:

* `GatewayVPNManager` owns install/update/remove/start/stop/status around `NETunnelProviderManager`.
* `GatewayWireGuardConfig` validates raw WireGuard config text before install.
* `CloudGatewayRegion`, `CloudGatewayClient`, and `CloudGatewayConfigSelection` provide Firebase-derived sorting and user-selectable config list behavior without importing Firebase.
* `CloudGatewayConfigCache` stores the last installed config snapshot in the app group so the local tunnel remains usable when Firestore/API is temporarily unavailable.
* `CloudGatewayConfigManager` owns user-selected install orchestration, local/remote reconciliation, cache update ordering, stale state, and start/stop/remove decisions through protocol-backed tunnel and cache dependencies.

## Firebase Boundary

CloudGatewayKit should stay platform-neutral and should not import Firebase SDK products directly.

Firebase belongs in the app targets as an adapter:

* iOS app: configures Firebase, signs users in, reads Firestore, calls regional access APIs, and maps remote data into CloudGatewayKit models.
* Future macOS app: uses the same CloudGatewayKit models and manager APIs, with its own UI and Firebase setup.
* Packet tunnel extension: stays VPN-only and must not link Firebase unless a later product decision explicitly requires it.

The shared config manager lives in CloudGatewayKit and depends on small protocols instead of concrete Firebase types. That keeps config selection, stale-state reconciliation, cache updates, and install ordering reusable across iOS and macOS while keeping Firebase, SwiftUI, and app lifecycle code outside the shared core.

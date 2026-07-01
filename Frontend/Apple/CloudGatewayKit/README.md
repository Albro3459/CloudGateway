# CloudGatewayKit

Shared Apple VPN wrapper for CloudGateway iOS and macOS apps.

CloudGatewayKit is intended to wrap WireGuardKit and own the common tunnel configuration, app-group storage, and platform-neutral VPN control APIs used by the iOS app and future macOS app.

Current shared responsibilities:

* `GatewayVPNManager` owns install/update/remove/start/stop/status around `NETunnelProviderManager`.
* `GatewayWireGuardConfig` validates raw WireGuard config text before install.
* `CloudGatewayRegion`, `CloudGatewayClient`, and `CloudGatewayConfigSelection` provide Firebase-derived sorting and user-selectable config list behavior without importing Firebase.
* `CloudGatewayConfigCache` stores the last installed config snapshot in the app group so the local tunnel remains usable when Firestore/API is temporarily unavailable.

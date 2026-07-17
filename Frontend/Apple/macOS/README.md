# CloudGateway macOS

Future native macOS app project home.

No macOS app or packet-tunnel targets exist yet.

The future macOS app should share VPN configuration through `CloudGatewayKit`.
Its packet-tunnel extension should reuse `GatewayTunnelHealthCoordinator`,
`GatewayTunnelHealthMonitor`, `GatewayTunnelHealthArtifactDriver`, the
effect-submission arbiter, notification-registration fence,
`GatewayTunnelHealthTiming`, `GatewayTunnelHealthStore`, and the shared
notification contract without forking the iOS detector or adding another
health timer.

The GUI app will request notification authorization and read the shared health
snapshot. Detection remains in the future packet extension so it continues
while the GUI is backgrounded, closed, or signed out. Bundle, provider,
app-group, and Keychain identifiers remain injected platform configuration.

The macOS extension will provide only platform adapters for:

* WireGuardKit runtime reads and binding refresh;
* `NWPathMonitor` fingerprint and route-generation mapping;
* enqueue-only FIFO app-group snapshot persistence;
* epoch-fenced pending and delivered User Notifications reconciliation;
* packet-tunnel start and bounded normal/deadline stop lifecycle.

WireGuardKit stays outside `CloudGatewayKit`. The pinned fork exposes binding
refresh on macOS, but its public backend-restart entry point is currently
iOS-only. The initial macOS runtime adapter should report backend restart as
unsupported; the shared bounded recovery policy will still confirm and notify.
Exposing macOS backend restart in the fork is a separate implementation and
device-validation task.

Remaining macOS work includes app and extension targets, entitlements, signing,
UI/Firebase composition, adapter compile tests, and the signed real-device
matrix. None of that work was implemented or verified by this extraction.

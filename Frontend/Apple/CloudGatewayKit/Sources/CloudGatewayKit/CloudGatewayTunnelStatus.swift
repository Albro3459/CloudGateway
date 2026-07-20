import NetworkExtension

public enum CloudGatewayTunnelStatus: Equatable, Sendable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting

    public init(_ status: NEVPNStatus) {
        switch status {
        case .invalid:
            self = .invalid
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reasserting:
            self = .reasserting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            self = .invalid
        }
    }

    // Whether a destructive request (delete config / delete account) must be
    // blocked because the tunnel could blackhole its own response over a
    // full-tunnel route.
    //
    // `.disconnecting` is intentionally treated as NOT blocking: we switch the
    // UI off optimistically the moment the user taps Stop, matching Control
    // Center, because Apple is slow to report the final `.disconnected` state.
    // Once teardown has begun the tunnel is no longer expected to route the
    // response, so a destructive op is allowed to proceed rather than trap the
    // user behind a status the OS is slow to clear.
    public var blocksDestructiveOperation: Bool {
        switch self {
        case .connecting, .connected, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting:
            return false
        }
    }
}

import NetworkExtension

public enum GatewayTunnelStatus: Equatable, Sendable {
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

    // True while the tunnel may still be routing traffic. Used to block
    // destructive requests that would blackhole their own response over a
    // full-tunnel route; only a fully disconnected/invalid tunnel is safe.
    public var isConnectionActive: Bool {
        switch self {
        case .connecting, .connected, .reasserting, .disconnecting:
            return true
        case .invalid, .disconnected:
            return false
        }
    }

    public var blocksDestructiveOperation: Bool {
        switch self {
        case .connecting, .connected, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting:
            return false
        }
    }
}

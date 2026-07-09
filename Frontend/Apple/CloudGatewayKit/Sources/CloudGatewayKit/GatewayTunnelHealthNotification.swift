import Foundation

/// Decides when the extension should raise or withdraw the "VPN not responding"
/// local notification, based on the transition between health verdicts. Kept
/// pure so the edge-triggering logic is unit-tested without UserNotifications.
public enum GatewayTunnelHealthNotification {
    /// Stable identifier for the dead-tunnel notification. A single active tunnel
    /// means one notification; posting with the same id replaces any prior one.
    public static let identifier = "com.gocloudlaunch.gateway.tunnel.notresponding"

    public static let title = "VPN not responding"
    public static let body = "Your VPN server isn't responding. Disconnect to restore your connection."

    /// Notify only on the transition *into* notPassingTraffic, so a tunnel that
    /// stays dead is not re-notified on every poll.
    public static func shouldNotify(previous: GatewayTunnelHealth?, current: GatewayTunnelHealth) -> Bool {
        current == .notPassingTraffic && previous != .notPassingTraffic
    }

    /// Withdraw the notification once traffic is confirmed flowing again.
    public static func shouldWithdraw(previous: GatewayTunnelHealth?, current: GatewayTunnelHealth) -> Bool {
        current == .passingTraffic && previous == .notPassingTraffic
    }
}

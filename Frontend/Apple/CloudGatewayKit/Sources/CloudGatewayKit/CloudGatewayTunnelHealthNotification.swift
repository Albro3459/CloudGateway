import Foundation

/// Decides when the extension should raise or withdraw the "VPN connection interrupted"
/// local notification, based on the transition between health verdicts. Kept
/// pure so the edge-triggering logic is unit-tested without UserNotifications.
public enum CloudGatewayTunnelHealthNotification {
    /// Stable identifier for the dead-tunnel notification. A single active tunnel
    /// means one notification; posting with the same id replaces any prior one.
    public static let identifier = "com.gocloudlaunch.gateway.tunnel.notresponding"

    public static let title = "VPN connection interrupted"
    public static let body = "Your internet connection may be weak, or the VPN server may be down for maintenance for a few minutes. You can wait, or disconnect to use this network without the VPN."

    /// Notify only on the transition *into* notPassingTraffic, so a tunnel that
    /// stays dead is not re-notified on every poll.
    public static func shouldNotify(previous: CloudGatewayTunnelHealth?, current: CloudGatewayTunnelHealth) -> Bool {
        current == .notPassingTraffic && previous != .notPassingTraffic
    }

    /// Withdraw the notification once traffic is confirmed flowing again.
    public static func shouldWithdraw(previous: CloudGatewayTunnelHealth?, current: CloudGatewayTunnelHealth) -> Bool {
        current == .passingTraffic && previous == .notPassingTraffic
    }
}

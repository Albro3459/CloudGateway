import Foundation

/// URLSession configuration for the CloudGateway control-plane API.
///
/// A full tunnel (`AllowedIPs = 0.0.0.0/0`) routes every request through the
/// tunnel, so a deleted peer or a dead server silently blackholes traffic. With
/// URLSession's 60s default request timeout the app hangs a full minute per
/// request before failing. A bounded timeout fails fast (~10s) so the app can
/// diagnose the dead tunnel and tell the user quickly. 10s (not lower) keeps
/// slow-but-real cellular requests alive.
public enum CloudGatewayAPISession {
    public static let requestTimeout: TimeInterval = 10

    /// A region sync pass has no server-side duration bound (only per-subprocess and
    /// per-DNS-resolve limits inside it), so it routinely outlives `requestTimeout`. Admin sync
    /// requests override `URLRequest.timeoutInterval` with this value instead of raising the
    /// session default, which must stay fast for the full-tunnel dead-server case above.
    public static let adminSyncRequestTimeout: TimeInterval = 45

    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    public static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }
}

public enum GatewayProviderConfigurationKey {
    public static let appBundleIdentifier = "appBundleIdentifier"
    public static let appGroupIdentifier = "appGroupIdentifier"
    public static let tunnelIdentifier = "tunnelIdentifier"
    public static let wireGuardConfig = "wireGuardConfig"
}

public struct GatewayProviderConfiguration: Equatable, Sendable {
    public let values: [String: String]

    public init(
        platform: GatewayPlatformConfiguration,
        tunnel: GatewayTunnelConfiguration
    ) {
        values = [
            GatewayProviderConfigurationKey.appBundleIdentifier: platform.appBundleIdentifier,
            GatewayProviderConfigurationKey.appGroupIdentifier: platform.appGroupIdentifier,
            GatewayProviderConfigurationKey.tunnelIdentifier: tunnel.identifier,
            GatewayProviderConfigurationKey.wireGuardConfig: tunnel.wireGuardConfig.rawValue
        ]
    }
}

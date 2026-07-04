public enum GatewayProviderConfigurationKey {
    public static let appBundleIdentifier = "appBundleIdentifier"
    public static let appGroupIdentifier = "appGroupIdentifier"
    public static let tunnelIdentifier = "tunnelIdentifier"
    public static let configHash = "configHash"
    public static let keychainService = "keychainService"
    public static let keychainAccount = "keychainAccount"
    public static let keychainAccessGroup = "keychainAccessGroup"
    public static let legacyWireGuardConfig = "wireGuardConfig"
}

public struct GatewayProviderConfiguration: Equatable, Sendable {
    public let values: [String: String]

    public init(
        platform: GatewayPlatformConfiguration,
        tunnel: GatewayTunnelConfiguration
    ) {
        var values = [
            GatewayProviderConfigurationKey.appBundleIdentifier: platform.appBundleIdentifier,
            GatewayProviderConfigurationKey.appGroupIdentifier: platform.appGroupIdentifier,
            GatewayProviderConfigurationKey.tunnelIdentifier: tunnel.identifier,
            GatewayProviderConfigurationKey.configHash: tunnel.configHash,
            GatewayProviderConfigurationKey.keychainService: tunnel.secretReference.service,
            GatewayProviderConfigurationKey.keychainAccount: tunnel.secretReference.account
        ]
        if let keychainAccessGroupIdentifier = platform.keychainAccessGroupIdentifier {
            values[GatewayProviderConfigurationKey.keychainAccessGroup] = keychainAccessGroupIdentifier
        }
        self.values = values
    }
}

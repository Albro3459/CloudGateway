public enum CloudGatewayProviderConfigurationKey {
    public static let appBundleIdentifier = "appBundleIdentifier"
    public static let appGroupIdentifier = "appGroupIdentifier"
    public static let tunnelIdentifier = "tunnelIdentifier"
    public static let configHash = "configHash"
    public static let keychainService = "keychainService"
    public static let keychainAccount = "keychainAccount"
    public static let keychainAccessGroup = "keychainAccessGroup"
}

public struct CloudGatewayProviderConfiguration: Equatable, Sendable {
    public let values: [String: String]

    public init(
        platform: CloudGatewayPlatformConfiguration,
        tunnel: CloudGatewayTunnelConfiguration
    ) {
        var values = [
            CloudGatewayProviderConfigurationKey.appBundleIdentifier: platform.appBundleIdentifier,
            CloudGatewayProviderConfigurationKey.appGroupIdentifier: platform.appGroupIdentifier,
            CloudGatewayProviderConfigurationKey.tunnelIdentifier: tunnel.identifier,
            CloudGatewayProviderConfigurationKey.configHash: tunnel.configHash,
            CloudGatewayProviderConfigurationKey.keychainService: tunnel.secretReference.service,
            CloudGatewayProviderConfigurationKey.keychainAccount: tunnel.secretReference.account
        ]
        if let keychainAccessGroupIdentifier = platform.keychainAccessGroupIdentifier {
            values[CloudGatewayProviderConfigurationKey.keychainAccessGroup] = keychainAccessGroupIdentifier
        }
        self.values = values
    }
}

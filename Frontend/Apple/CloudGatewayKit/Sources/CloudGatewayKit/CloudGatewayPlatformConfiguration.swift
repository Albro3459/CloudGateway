public struct CloudGatewayPlatformConfiguration: Equatable, Sendable {
    public let appGroupIdentifier: String
    public let appBundleIdentifier: String
    public let providerBundleIdentifier: String
    // periphery:ignore - injected platform config value, compared via synthesized Equatable
    public let tunnelDisplayName: String
    public let keychainAccessGroupIdentifier: String?
    public let configSecretServiceName: String

    public init(
        appGroupIdentifier: String,
        appBundleIdentifier: String,
        providerBundleIdentifier: String,
        tunnelDisplayName: String,
        keychainAccessGroupIdentifier: String? = nil,
        configSecretServiceName: String = CloudGatewayConfigSecretDefaults.serviceName
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.appBundleIdentifier = appBundleIdentifier
        self.providerBundleIdentifier = providerBundleIdentifier
        self.tunnelDisplayName = tunnelDisplayName
        self.keychainAccessGroupIdentifier = keychainAccessGroupIdentifier
        self.configSecretServiceName = configSecretServiceName
    }
}

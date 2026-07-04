public struct GatewayPlatformConfiguration: Equatable, Sendable {
    public let appGroupIdentifier: String
    public let appBundleIdentifier: String
    public let providerBundleIdentifier: String
    public let tunnelDisplayName: String
    public let keychainAccessGroupIdentifier: String?
    public let configSecretServiceName: String

    public init(
        appGroupIdentifier: String,
        appBundleIdentifier: String,
        providerBundleIdentifier: String,
        tunnelDisplayName: String,
        keychainAccessGroupIdentifier: String? = nil,
        configSecretServiceName: String = "com.gocloudlaunch.gateway.wireguard-config"
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.appBundleIdentifier = appBundleIdentifier
        self.providerBundleIdentifier = providerBundleIdentifier
        self.tunnelDisplayName = tunnelDisplayName
        self.keychainAccessGroupIdentifier = keychainAccessGroupIdentifier
        self.configSecretServiceName = configSecretServiceName
    }
}

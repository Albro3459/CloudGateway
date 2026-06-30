public struct GatewayPlatformConfiguration: Equatable, Sendable {
    public let appGroupIdentifier: String
    public let appBundleIdentifier: String
    public let providerBundleIdentifier: String
    public let tunnelDisplayName: String

    public init(
        appGroupIdentifier: String,
        appBundleIdentifier: String,
        providerBundleIdentifier: String,
        tunnelDisplayName: String
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.appBundleIdentifier = appBundleIdentifier
        self.providerBundleIdentifier = providerBundleIdentifier
        self.tunnelDisplayName = tunnelDisplayName
    }
}

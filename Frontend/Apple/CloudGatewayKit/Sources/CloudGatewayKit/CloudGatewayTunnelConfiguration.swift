public struct CloudGatewayTunnelConfiguration: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let configHash: String
    public let secretReference: CloudGatewayConfigSecretReference

    public init(
        identifier: String = "default",
        displayName: String,
        configHash: String,
        secretReference: CloudGatewayConfigSecretReference
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.configHash = configHash
        self.secretReference = secretReference
    }
}

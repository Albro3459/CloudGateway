public struct GatewayTunnelConfiguration: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let wireGuardConfig: GatewayWireGuardConfig

    public init(
        identifier: String = "default",
        displayName: String,
        wireGuardConfig: GatewayWireGuardConfig
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.wireGuardConfig = wireGuardConfig
    }
}

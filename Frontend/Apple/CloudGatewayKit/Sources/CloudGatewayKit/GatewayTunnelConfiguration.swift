public struct GatewayTunnelConfiguration: Equatable, Sendable {
    public let identifier: String
    public let wireGuardConfig: GatewayWireGuardConfig

    public init(
        identifier: String = "default",
        wireGuardConfig: GatewayWireGuardConfig
    ) {
        self.identifier = identifier
        self.wireGuardConfig = wireGuardConfig
    }
}

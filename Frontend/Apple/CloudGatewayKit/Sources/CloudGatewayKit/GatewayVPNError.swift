public enum GatewayVPNError: Error, Equatable, Sendable {
    case missingInstalledTunnel
    case missingTunnelSession
    case missingWireGuardConfiguration
    case invalidWireGuardConfiguration
}

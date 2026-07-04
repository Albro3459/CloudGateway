public enum GatewayVPNError: Error, Equatable, Sendable {
    case missingInstalledTunnel
    case missingTunnelSession
    case missingWireGuardConfiguration
    case invalidWireGuardConfiguration
    case missingAppGroupContainer
    case missingConfigSecretReference
    case keychainReadFailed(Int32)
    case keychainWriteFailed(Int32)
    case keychainDeleteFailed(Int32)
}

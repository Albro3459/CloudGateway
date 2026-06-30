import Foundation

public struct GatewayWireGuardConfig: Equatable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw GatewayVPNError.missingWireGuardConfiguration
        }
        guard trimmedValue.contains("[Interface]"),
              trimmedValue.contains("PrivateKey"),
              trimmedValue.contains("[Peer]"),
              trimmedValue.contains("PublicKey") else {
            throw GatewayVPNError.invalidWireGuardConfiguration
        }
        self.rawValue = trimmedValue
    }
}

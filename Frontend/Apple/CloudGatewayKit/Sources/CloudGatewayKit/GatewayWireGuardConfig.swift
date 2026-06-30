import Foundation

public struct GatewayWireGuardConfig: Equatable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw GatewayVPNError.missingWireGuardConfiguration
        }
        do {
            _ = try GatewayWireGuardConfigParser.parse(trimmedValue)
        } catch {
            throw GatewayVPNError.invalidWireGuardConfiguration
        }
        self.rawValue = trimmedValue
    }
}

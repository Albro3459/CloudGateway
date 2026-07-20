import Foundation

public struct CloudGatewayWireGuardConfig: Equatable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw CloudGatewayVPNError.missingWireGuardConfiguration
        }
        do {
            _ = try CloudGatewayWireGuardConfigParser.parse(trimmedValue)
        } catch {
            throw CloudGatewayVPNError.invalidWireGuardConfiguration
        }
        self.rawValue = trimmedValue
    }
}

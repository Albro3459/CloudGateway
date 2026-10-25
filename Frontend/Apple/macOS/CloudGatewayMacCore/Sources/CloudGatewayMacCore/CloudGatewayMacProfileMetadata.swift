import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation

public enum CloudGatewayMacProfileMetadata {
    public static func decode(_ metadata: [String: Any], status: CloudGatewayTunnelStatus) throws -> CloudGatewayMacInstalledProfile {
        guard let identifier = metadata[CloudGatewayMacProviderKey.configId] as? String, validIdentifier(identifier),
              metadata[CloudGatewayProviderConfigurationKey.tunnelIdentifier] as? String == identifier,
              let value = metadata[CloudGatewayMacProviderKey.secretReference] as? String,
              let reference = try? CloudGatewayMacSecretReference(value: value) else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
        let mode: CloudGatewayRoutingMode? = metadata[CloudGatewayMacProviderKey.routingMode] == nil
            ? .full : (metadata[CloudGatewayMacProviderKey.routingMode] as? String).flatMap(CloudGatewayRoutingMode.init(rawValue:))
        return .init(identifier: identifier, reference: reference, status: status, mode: mode)
    }

    public static func validateUnique(_ profiles: [CloudGatewayMacInstalledProfile]) throws {
        guard Set(profiles.map(\.identifier)).count == profiles.count else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
    }

    public static func inactiveTarget(
        identifier: String,
        profiles: [CloudGatewayMacInstalledProfile]
    ) throws -> CloudGatewayMacInstalledProfile? {
        guard validIdentifier(identifier), profiles.allSatisfy({ validIdentifier($0.identifier) }) else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
        try validateUnique(profiles)
        let target = profiles.first { $0.identifier == identifier }
        guard target?.needsConfirmedStop != true else { throw CloudGatewayMacConfigError.clientActive }
        return target
    }

    static func validIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return parts.count == 3 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && $0 != "." && $0 != ".."
                && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

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
        return .init(identifier: identifier, reference: reference, status: status)
    }

    public static func validateUnique(_ profiles: [CloudGatewayMacInstalledProfile]) throws {
        guard Set(profiles.map(\.identifier)).count == profiles.count else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
    }

    private static func validIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return parts.count == 3 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && $0 != "." && $0 != ".."
                && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

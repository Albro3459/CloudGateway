import CryptoKit
import Foundation
import Security

public enum CloudGatewayConfigSecretDefaults {
    public static let serviceName = "com.gocloudlaunch.gateway.wireguard-config"
}

public struct CloudGatewayConfigSecretReference: Codable, Equatable, Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static func make(
        clientId: String,
        configHash: String,
        service: String
    ) -> CloudGatewayConfigSecretReference {
        CloudGatewayConfigSecretReference(
            service: service,
            account: "wireguard-config/\(clientId)/\(configHash)"
        )
    }
}

public protocol CloudGatewayConfigSecretStoring: Sendable {
    func saveConfig(_ config: CloudGatewayWireGuardConfig, for reference: CloudGatewayConfigSecretReference) throws
    // periphery:ignore - called through protocol existential in PacketTunnelProvider
    func loadConfig(for reference: CloudGatewayConfigSecretReference) throws -> CloudGatewayWireGuardConfig
    func deleteConfig(for reference: CloudGatewayConfigSecretReference) throws
}

public final class CloudGatewayKeychainConfigSecretStore: CloudGatewayConfigSecretStoring, Sendable {
    private let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func saveConfig(
        _ config: CloudGatewayWireGuardConfig,
        for reference: CloudGatewayConfigSecretReference
    ) throws {
        guard let data = config.rawValue.data(using: .utf8) else {
            throw CloudGatewayVPNError.invalidWireGuardConfiguration
        }

        let updateStatus = SecItemUpdate(query(for: reference) as CFDictionary, [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CloudGatewayVPNError.keychainWriteFailed(updateStatus)
        }

        var attributes = query(for: reference)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CloudGatewayVPNError.keychainWriteFailed(addStatus)
        }
    }

    public func loadConfig(for reference: CloudGatewayConfigSecretReference) throws -> CloudGatewayWireGuardConfig {
        var attributes = query(for: reference)
        attributes[kSecReturnData as String] = kCFBooleanTrue
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        #endif

        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw CloudGatewayVPNError.keychainReadFailed(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CloudGatewayVPNError.invalidWireGuardConfiguration
        }
        return try CloudGatewayWireGuardConfig(value)
    }

    public func deleteConfig(for reference: CloudGatewayConfigSecretReference) throws {
        var attributes = query(for: reference)
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        #endif

        let status = SecItemDelete(attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudGatewayVPNError.keychainDeleteFailed(status)
        }
    }

    private func query(for reference: CloudGatewayConfigSecretReference) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if let accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        #endif
        return attributes
    }

}

public enum CloudGatewayConfigHash {
    public static func make(for config: CloudGatewayWireGuardConfig) -> String {
        let data = Data(config.rawValue.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

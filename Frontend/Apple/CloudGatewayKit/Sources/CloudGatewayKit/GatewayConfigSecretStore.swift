import CryptoKit
import Foundation
import Security

public enum GatewayConfigSecretDefaults {
    public static let serviceName = "com.gocloudlaunch.gateway.wireguard-config"
}

public struct GatewayConfigSecretReference: Codable, Equatable, Hashable, Sendable {
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
    ) -> GatewayConfigSecretReference {
        GatewayConfigSecretReference(
            service: service,
            account: "wireguard-config/\(clientId)/\(configHash)"
        )
    }
}

public protocol CloudGatewayConfigSecretStoring: Sendable {
    func saveConfig(_ config: GatewayWireGuardConfig, for reference: GatewayConfigSecretReference) throws
    func loadConfig(for reference: GatewayConfigSecretReference) throws -> GatewayWireGuardConfig
    func deleteConfig(for reference: GatewayConfigSecretReference) throws
}

public final class GatewayKeychainConfigSecretStore: CloudGatewayConfigSecretStoring, Sendable {
    private let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func saveConfig(
        _ config: GatewayWireGuardConfig,
        for reference: GatewayConfigSecretReference
    ) throws {
        guard let data = config.rawValue.data(using: .utf8) else {
            throw GatewayVPNError.invalidWireGuardConfiguration
        }

        let updateStatus = SecItemUpdate(query(for: reference) as CFDictionary, [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GatewayVPNError.keychainWriteFailed(updateStatus)
        }

        var attributes = query(for: reference)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GatewayVPNError.keychainWriteFailed(addStatus)
        }
    }

    public func loadConfig(for reference: GatewayConfigSecretReference) throws -> GatewayWireGuardConfig {
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
            throw GatewayVPNError.keychainReadFailed(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw GatewayVPNError.invalidWireGuardConfiguration
        }
        return try GatewayWireGuardConfig(value)
    }

    public func deleteConfig(for reference: GatewayConfigSecretReference) throws {
        var attributes = query(for: reference)
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        #endif

        let status = SecItemDelete(attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayVPNError.keychainDeleteFailed(status)
        }
    }

    private func query(for reference: GatewayConfigSecretReference) -> [String: Any] {
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

public enum GatewayConfigHash {
    public static func make(for config: GatewayWireGuardConfig) -> String {
        let data = Data(config.rawValue.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

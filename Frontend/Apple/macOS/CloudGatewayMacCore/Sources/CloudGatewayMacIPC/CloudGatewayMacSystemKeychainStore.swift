import Foundation
import Security

final class CloudGatewayMacSystemKeychainStore: CloudGatewayMacSecretStoring {
    private let service = "com.gocloudlaunch.gateway.tunnel.macos.configs"

    func add(_ record: CloudGatewayMacStoredSecret, reference: CloudGatewayMacSecretReference) throws {
        var attributes = try query(reference: reference)
        attributes.removeValue(forKey: kSecMatchSearchList as String)
        attributes[kSecUseKeychain as String] = try systemKeychain()
        attributes[kSecValueData as String] = try JSONEncoder().encode(record)
        attributes[kSecAttrLabel as String] = "CloudGateway VPN configuration"
        var trustedApplication: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trustedApplication) == errSecSuccess,
              let trustedApplication else { throw CloudGatewayMacSecretError.storageFailure }
        var access: SecAccess?
        guard SecAccessCreate("CloudGateway VPN configuration" as CFString,
                              [trustedApplication] as CFArray, &access) == errSecSuccess,
              let access else { throw CloudGatewayMacSecretError.storageFailure }
        attributes[kSecAttrAccess as String] = access
        try check(SecItemAdd(attributes as CFDictionary, nil))
    }

    func read(reference: CloudGatewayMacSecretReference) throws -> CloudGatewayMacStoredSecret? {
        var attributes = try query(reference: reference)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data,
              data.count <= CloudGatewayMacSecretBounds.requestBytes,
              let record = try? JSONDecoder().decode(CloudGatewayMacStoredSecret.self, from: data) else {
            throw CloudGatewayMacSecretError.storageFailure
        }
        return record
    }

    func update(_ record: CloudGatewayMacStoredSecret, reference: CloudGatewayMacSecretReference) throws {
        try check(SecItemUpdate(try query(reference: reference) as CFDictionary, [
            kSecValueData as String: try JSONEncoder().encode(record)
        ] as CFDictionary))
    }

    func remove(reference: CloudGatewayMacSecretReference) throws {
        let status = SecItemDelete(try query(reference: reference) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func query(reference: CloudGatewayMacSecretReference) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.value,
            kSecAttrSynchronizable as String: false,
            kSecMatchSearchList as String: [try systemKeychain()],
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    private func systemKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        guard SecKeychainOpen("/Library/Keychains/System.keychain", &keychain) == errSecSuccess,
              let keychain else { throw CloudGatewayMacSecretError.storageFailure }
        return keychain
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CloudGatewayMacSecretError.storageFailure }
    }
}

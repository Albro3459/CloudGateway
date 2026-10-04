import CloudGatewayKit
import CryptoKit
import Foundation

public enum CloudGatewayMacAccountRole: String, Codable, Sendable {
    case user
    case admin
}

public struct CloudGatewayMacAccountCacheSnapshot: Codable, Equatable, Sendable {
    public var configs: [CloudGatewayMacInstalledConfig]
    public var selectedIdentifier: String?
    public var accessAllowed: Bool

    public init(configs: [CloudGatewayMacInstalledConfig] = [], selectedIdentifier: String? = nil, accessAllowed: Bool = false) {
        self.configs = configs
        self.selectedIdentifier = selectedIdentifier
        self.accessAllowed = accessAllowed
    }
}

public enum CloudGatewayMacCacheError: Error, Equatable, Sendable {
    case invalidMetadata
    case unavailable
    case accessDenied
}

public actor CloudGatewayMacAccountCache: CloudGatewayMacSnapshotPersisting {
    private struct Payload: Codable {
        let version: Int
        let accountId: String
        var snapshot: CloudGatewayMacAccountCacheSnapshot
        var authorizedConfigHashes: [String: String]
        var authorizedRole: CloudGatewayMacAccountRole? = nil
    }

    private let directory: URL
    private let files = FileManager.default
    private var deniedAccounts: Set<String> = []

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(accountId: String) throws -> CloudGatewayMacAccountCacheSnapshot {
        try loadPayload(accountId: accountId).snapshot
    }

    private func loadPayload(accountId: String) throws -> Payload {
        try validate(accountId: accountId)
        if deniedAccounts.contains(accountId) {
            return Payload(version: 1, accountId: accountId, snapshot: .init(), authorizedConfigHashes: [:])
        }
        let path = cacheURL(accountId: accountId)
        guard files.fileExists(atPath: path.path) else {
            return Payload(version: 1, accountId: accountId, snapshot: .init(), authorizedConfigHashes: [:])
        }
        do {
            let size = try files.attributesOfItem(atPath: path.path)[.size] as? NSNumber
            guard let size, size.intValue <= 5 * 1024 * 1024 else { throw CloudGatewayMacCacheError.invalidMetadata }
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: path))
            guard payload.version == 1, payload.accountId == accountId,
                  payload.snapshot.configs.count <= 1000 else { throw CloudGatewayMacCacheError.invalidMetadata }
            guard payload.authorizedRole != nil else {
                return Payload(version: 1, accountId: accountId, snapshot: .init(), authorizedConfigHashes: [:])
            }
            for config in payload.snapshot.configs {
                try validate(config, accountId: accountId)
                guard payload.authorizedConfigHashes[config.identifier] == config.snapshot.configHash else {
                    throw CloudGatewayMacCacheError.invalidMetadata
                }
            }
            guard Set(payload.snapshot.configs.map(\.identifier)).count == payload.snapshot.configs.count,
                  payload.snapshot.selectedIdentifier == nil ||
                    payload.snapshot.configs.contains(where: { $0.identifier == payload.snapshot.selectedIdentifier }),
                  payload.snapshot.accessAllowed || payload.snapshot.configs.isEmpty else {
                throw CloudGatewayMacCacheError.invalidMetadata
            }
            return payload
        } catch let error as CloudGatewayMacCacheError { throw error }
        catch { throw CloudGatewayMacCacheError.unavailable }
    }

    public func save(_ config: CloudGatewayMacInstalledConfig) throws {
        try validate(config, accountId: config.accountId)
        var payload = try loadPayload(accountId: config.accountId)
        guard payload.snapshot.accessAllowed,
              payload.authorizedConfigHashes[config.identifier] == config.snapshot.configHash else {
            throw CloudGatewayMacCacheError.accessDenied
        }
        payload.snapshot.configs.removeAll { $0.identifier == config.identifier }
        payload.snapshot.configs.append(config)
        guard payload.snapshot.configs.count <= 1000 else { throw CloudGatewayMacCacheError.invalidMetadata }
        try write(payload)
    }

    @discardableResult
    public func observeRole(accountId: String, role: CloudGatewayMacAccountRole) throws -> Bool {
        // A confirmed downgrade must persist even when the caller quits
        try validate(accountId: accountId)
        if role == .user, (try? loadPayload(accountId: accountId))?.authorizedRole != .user {
            try deny(accountId: accountId)
            return true
        }
        return false
    }

    public func authorize(accountId: String, role: CloudGatewayMacAccountRole, options: [CloudGatewayClientOption]) throws {
        try Task.checkCancellation()
        try validate(accountId: accountId)
        let inventory = options.filter { $0.client.status != .removed }
        guard inventory.count <= 1000 else { throw CloudGatewayMacCacheError.invalidMetadata }
        guard role == .admin || options.allSatisfy({ $0.client.ownerUid == accountId }) else {
            throw CloudGatewayMacCacheError.accessDenied
        }
        var payload = (try? loadPayload(accountId: accountId)) ?? Payload(
            version: 1, accountId: accountId, snapshot: .init(), authorizedConfigHashes: [:]
        )
        payload.authorizedConfigHashes = [:]
        var authorizedOptions: [String: CloudGatewayClientOption] = [:]
        for option in inventory where option.client.hasUsableConfig && option.region?.enabled == true {
            let identifier = "\(accountId)/\(option.client.regionId)/\(option.client.clientId)"
            guard authorizedOptions[identifier] == nil else { throw CloudGatewayMacCacheError.invalidMetadata }
            authorizedOptions[identifier] = option
            payload.authorizedConfigHashes[identifier] = CloudGatewayConfigHash.make(
                for: try CloudGatewayConfigSelection.wireGuardConfig(from: option)
            )
        }
        payload.snapshot.configs = payload.snapshot.configs.compactMap { config in
            guard let option = authorizedOptions[config.identifier],
                  payload.authorizedConfigHashes[config.identifier] == config.snapshot.configHash else { return nil }
            let snapshot = CloudGatewayConfigSnapshot(
                clientId: option.client.clientId, regionId: option.client.regionId,
                clientName: option.client.clientName, regionDisplayName: option.regionDisplayName,
                status: option.client.status, configHash: config.snapshot.configHash,
                secretReference: config.snapshot.secretReference, readAt: Date(), updatedAt: option.client.updatedAt,
                assignedTunnelIpv4: option.client.assignedTunnelIpv4,
                serverEndpointIpv4: option.client.serverEndpointIpv4,
                serverEndpointHostname: option.client.serverEndpointHostname
            )
            return CloudGatewayMacInstalledConfig(accountId: accountId, identifier: config.identifier, snapshot: snapshot)
        }
        if !payload.snapshot.configs.contains(where: { $0.identifier == payload.snapshot.selectedIdentifier }) {
            payload.snapshot.selectedIdentifier = nil
        }
        payload.snapshot.accessAllowed = true
        payload.authorizedRole = role
        try write(payload)
        deniedAccounts.remove(accountId)
    }

    public func deny(accountId: String) throws {
        try validate(accountId: accountId)
        deniedAccounts.insert(accountId)
        try write(Payload(version: 1, accountId: accountId, snapshot: .init(), authorizedConfigHashes: [:]))
    }

    public func select(identifier: String, accountId: String) throws {
        var payload = try loadPayload(accountId: accountId)
        guard payload.snapshot.accessAllowed,
              payload.snapshot.configs.contains(where: { $0.identifier == identifier }) else {
            throw CloudGatewayMacCacheError.invalidMetadata
        }
        payload.snapshot.selectedIdentifier = identifier
        try write(payload)
    }

    private func write(_ payload: Payload) throws {
        let accountId = payload.accountId
        try validate(accountId: accountId)
        do {
            let accountDirectory = cacheURL(accountId: accountId).deletingLastPathComponent()
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.createDirectory(at: accountDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: accountDirectory.path)
            let data = try JSONEncoder().encode(payload)
            guard data.count <= 5 * 1024 * 1024 else { throw CloudGatewayMacCacheError.invalidMetadata }
            let path = cacheURL(accountId: accountId)
            try data.write(to: path, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch let error as CloudGatewayMacCacheError { throw error }
        catch { throw CloudGatewayMacCacheError.unavailable }
    }

    private func cacheURL(accountId: String) -> URL {
        let namespace = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(namespace, isDirectory: true).appendingPathComponent("inventory.json")
    }

    private func validate(accountId: String) throws {
        guard !accountId.isEmpty, accountId.utf8.count <= 128,
              !accountId.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CloudGatewayMacCacheError.invalidMetadata
        }
    }

    private func validate(_ config: CloudGatewayMacInstalledConfig, accountId: String) throws {
        try validate(accountId: accountId)
        guard config.accountId == accountId,
              config.snapshot.status == .active,
              !config.snapshot.clientId.isEmpty, !config.snapshot.regionId.isEmpty,
              config.identifier == "\(accountId)/\(config.snapshot.regionId)/\(config.snapshot.clientId)",
              config.snapshot.configHash.count == 64,
              config.snapshot.configHash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CloudGatewayMacCacheError.invalidMetadata
        }
        _ = try config.reference
    }
}

import Foundation

public actor CloudGatewayConfigCache {
    private let platform: GatewayPlatformConfiguration
    private let fileName: String

    public init(
        platform: GatewayPlatformConfiguration,
        fileName: String = "installed-configs.json"
    ) {
        self.platform = platform
        self.fileName = fileName
    }

    public func load() throws -> [CloudGatewayConfigSnapshot] {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.gatewayConfig.decode([CloudGatewayConfigSnapshot].self, from: data)
    }

    public func save(_ snapshot: CloudGatewayConfigSnapshot) throws {
        var snapshots = try load().filter { $0.clientId != snapshot.clientId }
        snapshots.append(snapshot)
        try save(snapshots)
    }

    public func clear(identifier: String) throws {
        let snapshots = try load().filter { $0.clientId != identifier }
        try save(snapshots)
    }

    private func save(_ snapshots: [CloudGatewayConfigSnapshot]) throws {
        let url = try fileURL()
        let sortedSnapshots = snapshots.sorted { lhs, rhs in
            let nameComparison = lhs.clientDisplayName.localizedCaseInsensitiveCompare(rhs.clientDisplayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.clientId.localizedCaseInsensitiveCompare(rhs.clientId) == .orderedAscending
        }
        let data = try JSONEncoder.gatewayConfig.encode(sortedSnapshots)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    private func fileURL() throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: platform.appGroupIdentifier
        ) else {
            throw GatewayVPNError.missingAppGroupContainer
        }
        return containerURL
            .appendingPathComponent("CloudGateway", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

extension CloudGatewayConfigCache: CloudGatewayConfigCaching {}

private extension JSONEncoder {
    static var gatewayConfig: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var gatewayConfig: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

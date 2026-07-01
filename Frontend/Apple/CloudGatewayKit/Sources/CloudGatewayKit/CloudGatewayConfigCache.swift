import Foundation

public actor CloudGatewayConfigCache {
    private let platform: GatewayPlatformConfiguration
    private let fileName: String

    public init(
        platform: GatewayPlatformConfiguration,
        fileName: String = "selected-config.json"
    ) {
        self.platform = platform
        self.fileName = fileName
    }

    public func load() throws -> CloudGatewayConfigSnapshot? {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.gatewayConfig.decode(CloudGatewayConfigSnapshot.self, from: data)
    }

    public func save(_ snapshot: CloudGatewayConfigSnapshot) throws {
        let url = try fileURL()
        let data = try JSONEncoder.gatewayConfig.encode(snapshot)
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

    public func clear() throws {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
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

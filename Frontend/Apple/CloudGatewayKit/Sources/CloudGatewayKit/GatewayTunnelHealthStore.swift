import Foundation

/// The tunnel-health verdict the extension publishes to the shared app group so
/// the app can read it without a network round-trip. Carries no traffic content,
/// keys, or metadata - just which tunnel, its health, and when it was written.
public struct GatewayTunnelHealthSnapshot: Codable, Equatable, Sendable {
    /// The extension periodically rewrites this file. A bounded
    /// window prevents a dead verdict from surviving an extension crash or a
    /// long suspension and misleading the app later.
    public static var freshnessWindow: TimeInterval {
        GatewayTunnelHealthTiming.production.snapshotFreshness.gatewayTimeInterval
    }

    public let tunnelIdentifier: String
    public let health: GatewayTunnelHealth
    public let updatedAt: Date

    public init(tunnelIdentifier: String, health: GatewayTunnelHealth, updatedAt: Date) {
        self.tunnelIdentifier = tunnelIdentifier
        self.health = health
        self.updatedAt = updatedAt
    }

    public func isFresh(
        at now: Date = Date(),
        timing: GatewayTunnelHealthTiming = .production
    ) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return age >= -timing.snapshotFutureTolerance.gatewayTimeInterval
            && age <= timing.snapshotFreshness.gatewayTimeInterval
    }
}

/// Reads and writes the tunnel-health snapshot in the shared app-group
/// container. The packet-tunnel extension writes it; the app reads it. Writes
/// are atomic so a concurrent read never sees a partial file.
public struct GatewayTunnelHealthStore: Sendable {
    private let appGroupIdentifier: String?
    private let overrideDirectory: URL?
    private let fileName: String

    public init(appGroupIdentifier: String, fileName: String = "tunnel-health.json") {
        self.appGroupIdentifier = appGroupIdentifier
        self.overrideDirectory = nil
        self.fileName = fileName
    }

    // Test seam: write into an explicit directory, bypassing the app-group
    // container that is unavailable to unit tests.
    init(directory: URL, fileName: String = "tunnel-health.json") {
        self.appGroupIdentifier = nil
        self.overrideDirectory = directory
        self.fileName = fileName
    }

    public func write(_ snapshot: GatewayTunnelHealthSnapshot) throws {
        let url = try fileURL()
        let data = try JSONEncoder.gatewayHealth.encode(snapshot)
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

    public func read() throws -> GatewayTunnelHealthSnapshot? {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.gatewayHealth.decode(GatewayTunnelHealthSnapshot.self, from: data)
    }

    public func clear() throws {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL() throws -> URL {
        let directory: URL
        if let overrideDirectory {
            directory = overrideDirectory
        } else if let appGroupIdentifier,
                  let containerURL = FileManager.default.containerURL(
                      forSecurityApplicationGroupIdentifier: appGroupIdentifier
                  ) {
            directory = containerURL.appendingPathComponent("CloudGateway", isDirectory: true)
        } else {
            throw GatewayVPNError.missingAppGroupContainer
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

private extension JSONEncoder {
    static var gatewayHealth: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var gatewayHealth: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

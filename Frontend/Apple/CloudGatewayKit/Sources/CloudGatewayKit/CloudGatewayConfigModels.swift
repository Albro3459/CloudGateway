import Foundation

public enum CloudGatewayClientStatus: String, Codable, Equatable, Sendable {
    case creating
    case active
    case failed
    case removed
}

public struct CloudGatewayRegion: Codable, Equatable, Sendable {
    public let regionId: String
    public let displayName: String
    public let enabled: Bool
    public let displayOrder: Int

    public init(
        regionId: String,
        displayName: String,
        enabled: Bool,
        displayOrder: Int = 1000
    ) {
        self.regionId = regionId
        self.displayName = displayName
        self.enabled = enabled
        self.displayOrder = displayOrder
    }
}

public struct CloudGatewayClient: Codable, Equatable, Sendable {
    public let clientId: String
    public let clientName: String?
    public let regionId: String
    public let status: CloudGatewayClientStatus
    public let wireGuardConfig: String?
    public let updatedAt: Date?

    public init(
        clientId: String,
        clientName: String?,
        regionId: String,
        status: CloudGatewayClientStatus,
        wireGuardConfig: String?,
        updatedAt: Date? = nil
    ) {
        self.clientId = clientId
        self.clientName = clientName
        self.regionId = regionId
        self.status = status
        self.wireGuardConfig = wireGuardConfig
        self.updatedAt = updatedAt
    }

    public var displayName: String {
        guard let clientName,
              !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return clientId
        }
        return clientName
    }

    public var hasUsableConfig: Bool {
        status == .active && !(wireGuardConfig?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public struct CloudGatewayClientOption: Identifiable, Equatable, Sendable {
    public let client: CloudGatewayClient
    public let region: CloudGatewayRegion?

    public init(client: CloudGatewayClient, region: CloudGatewayRegion?) {
        self.client = client
        self.region = region
    }

    public var id: String {
        client.clientId
    }

    public var regionDisplayName: String {
        region?.displayName ?? client.regionId
    }
}

public struct CloudGatewayConfigSnapshot: Codable, Equatable, Sendable {
    public let clientId: String
    public let regionId: String
    public let clientName: String?
    public let regionDisplayName: String
    public let status: CloudGatewayClientStatus
    public let wireGuardConfig: String
    public let readAt: Date
    public let updatedAt: Date?

    public init(
        clientId: String,
        regionId: String,
        clientName: String?,
        regionDisplayName: String,
        status: CloudGatewayClientStatus,
        wireGuardConfig: String,
        readAt: Date,
        updatedAt: Date?
    ) {
        self.clientId = clientId
        self.regionId = regionId
        self.clientName = clientName
        self.regionDisplayName = regionDisplayName
        self.status = status
        self.wireGuardConfig = wireGuardConfig
        self.readAt = readAt
        self.updatedAt = updatedAt
    }

    public var clientDisplayName: String {
        guard let clientName,
              !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return clientId
        }
        return clientName
    }

    public func tunnelConfiguration() throws -> GatewayTunnelConfiguration {
        GatewayTunnelConfiguration(
            identifier: clientId,
            wireGuardConfig: try GatewayWireGuardConfig(wireGuardConfig)
        )
    }
}

public enum CloudGatewayConfigSelection {
    public static func sortedRegions(_ regions: [CloudGatewayRegion]) -> [CloudGatewayRegion] {
        regions.sorted { lhs, rhs in
            if lhs.displayOrder != rhs.displayOrder {
                return lhs.displayOrder < rhs.displayOrder
            }
            let displayNameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if displayNameComparison != .orderedSame {
                return displayNameComparison == .orderedAscending
            }
            return lhs.regionId.localizedCaseInsensitiveCompare(rhs.regionId) == .orderedAscending
        }
    }

    public static func usableOptions(
        clients: [CloudGatewayClient],
        regions: [CloudGatewayRegion]
    ) -> [CloudGatewayClientOption] {
        let regionsById = Dictionary(uniqueKeysWithValues: regions.map { ($0.regionId, $0) })
        return clients
            .filter(\.hasUsableConfig)
            .map { CloudGatewayClientOption(client: $0, region: regionsById[$0.regionId]) }
            .sorted(by: compareOptions)
    }

    public static func snapshot(
        from option: CloudGatewayClientOption,
        readAt: Date = Date()
    ) throws -> CloudGatewayConfigSnapshot {
        guard let wireGuardConfig = option.client.wireGuardConfig?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wireGuardConfig.isEmpty else {
            throw GatewayVPNError.missingWireGuardConfiguration
        }

        return CloudGatewayConfigSnapshot(
            clientId: option.client.clientId,
            regionId: option.client.regionId,
            clientName: option.client.clientName,
            regionDisplayName: option.regionDisplayName,
            status: option.client.status,
            wireGuardConfig: wireGuardConfig,
            readAt: readAt,
            updatedAt: option.client.updatedAt
        )
    }

    public static func containsUsableClient(
        matching snapshot: CloudGatewayConfigSnapshot,
        in options: [CloudGatewayClientOption]
    ) -> Bool {
        matchingOption(for: snapshot, in: options) != nil
    }

    public static func matchingOption(
        for snapshot: CloudGatewayConfigSnapshot,
        in options: [CloudGatewayClientOption]
    ) -> CloudGatewayClientOption? {
        options.first { option in
            option.client.clientId == snapshot.clientId
                && option.client.regionId == snapshot.regionId
                && option.client.hasUsableConfig
        }
    }

    public static func configMatches(
        _ snapshot: CloudGatewayConfigSnapshot,
        option: CloudGatewayClientOption
    ) -> Bool {
        guard option.client.clientId == snapshot.clientId,
              option.client.regionId == snapshot.regionId,
              let remoteConfig = option.client.wireGuardConfig?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return remoteConfig == snapshot.wireGuardConfig.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compareOptions(
        _ lhs: CloudGatewayClientOption,
        _ rhs: CloudGatewayClientOption
    ) -> Bool {
        let lhsRegionOrder = lhs.region?.displayOrder ?? 1000
        let rhsRegionOrder = rhs.region?.displayOrder ?? 1000
        if lhsRegionOrder != rhsRegionOrder {
            return lhsRegionOrder < rhsRegionOrder
        }

        let regionNameComparison = lhs.regionDisplayName.localizedCaseInsensitiveCompare(rhs.regionDisplayName)
        if regionNameComparison != .orderedSame {
            return regionNameComparison == .orderedAscending
        }

        let clientNameComparison = lhs.client.displayName.localizedCaseInsensitiveCompare(rhs.client.displayName)
        if clientNameComparison != .orderedSame {
            return clientNameComparison == .orderedAscending
        }

        return lhs.client.clientId.localizedCaseInsensitiveCompare(rhs.client.clientId) == .orderedAscending
    }
}

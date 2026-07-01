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
    public let capacity: CloudGatewayRegionCapacity?

    public init(
        regionId: String,
        displayName: String,
        enabled: Bool,
        displayOrder: Int = 1000,
        capacity: CloudGatewayRegionCapacity? = nil
    ) {
        self.regionId = regionId
        self.displayName = displayName
        self.enabled = enabled
        self.displayOrder = displayOrder
        self.capacity = capacity
    }
}

public struct CloudGatewayRegionCapacity: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case known
        case unknown
    }

    public let status: Status
    public let limit: Int?
    public let allocated: Int?

    public init(status: Status, limit: Int? = nil, allocated: Int? = nil) {
        self.status = status
        self.limit = limit
        self.allocated = allocated
    }

    public static func known(limit: Int, allocated: Int) -> CloudGatewayRegionCapacity {
        CloudGatewayRegionCapacity(status: .known, limit: limit, allocated: allocated)
    }

    public static var unknown: CloudGatewayRegionCapacity {
        CloudGatewayRegionCapacity(status: .unknown)
    }

    public var isKnown: Bool {
        status == .known
    }

    public var isAtCapacity: Bool {
        guard status == .known, let limit, let allocated else {
            return false
        }
        return allocated >= limit
    }

    public var displayText: String {
        guard status == .known, let limit, let allocated else {
            return "Capacity unavailable"
        }
        return "\(allocated) / \(limit) used"
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

    public static func clientOptions(
        clients: [CloudGatewayClient],
        regions: [CloudGatewayRegion],
        includeRemoved: Bool = false
    ) -> [CloudGatewayClientOption] {
        let regionsById = Dictionary(uniqueKeysWithValues: regions.map { ($0.regionId, $0) })
        return clients
            .filter { includeRemoved || $0.status != .removed }
            .map { client in
                CloudGatewayClientOption(client: client, region: regionsById[client.regionId])
            }
            .sorted(by: compareOptions)
    }

    public static func clientOptions(
        in regionId: String?,
        options: [CloudGatewayClientOption]
    ) -> [CloudGatewayClientOption] {
        guard let regionId, !regionId.isEmpty else {
            return options
        }
        return options.filter { $0.client.regionId == regionId }
    }

    public static func mergeClients(
        existing: [CloudGatewayClient],
        fetched: [CloudGatewayClient]
    ) -> [CloudGatewayClient] {
        var clientsByKey = Dictionary(
            uniqueKeysWithValues: fetched.map { (clientKey(for: $0), $0) }
        )
        for client in existing {
            clientsByKey[clientKey(for: client)] = client
        }
        return Array(clientsByKey.values)
    }

    public static func resolvedRegionSelection(
        current: String?,
        regions: [CloudGatewayRegion]
    ) -> String? {
        if let current, regions.contains(where: { $0.regionId == current }) {
            return current
        }
        return regions.first?.regionId
    }

    public static func prunedClientSelection(
        current: String?,
        regionId: String?,
        options: [CloudGatewayClientOption]
    ) -> String? {
        guard let current else {
            return nil
        }
        let filtered = clientOptions(in: regionId, options: options)
        return filtered.contains(where: { $0.client.clientId == current }) ? current : nil
    }

    public static func selectedRegion(
        id: String?,
        in regions: [CloudGatewayRegion]
    ) -> CloudGatewayRegion? {
        guard let id else {
            return nil
        }
        return regions.first { $0.regionId == id }
    }

    public static func selectedOption(
        clientId: String?,
        in options: [CloudGatewayClientOption]
    ) -> CloudGatewayClientOption? {
        guard let clientId else {
            return nil
        }
        return options.first { $0.client.clientId == clientId }
    }

    public static func usableSelection(
        _ option: CloudGatewayClientOption?
    ) -> CloudGatewayClientOption? {
        guard let option,
              option.client.hasUsableConfig,
              option.region?.enabled == true else {
            return nil
        }
        return option
    }

    private static func clientKey(for client: CloudGatewayClient) -> String {
        "\(client.regionId)/\(client.clientId)"
    }

    public static func usableOptions(
        clients: [CloudGatewayClient],
        regions: [CloudGatewayRegion]
    ) -> [CloudGatewayClientOption] {
        let regionsById = Dictionary(uniqueKeysWithValues: regions.map { ($0.regionId, $0) })
        return clients
            .filter(\.hasUsableConfig)
            .compactMap { client in
                guard let region = regionsById[client.regionId], region.enabled else {
                    return nil
                }
                return CloudGatewayClientOption(client: client, region: region)
            }
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

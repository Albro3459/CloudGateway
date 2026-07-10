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
    public let assignedTunnelIpv4: String?
    public let serverEndpointIpv4: String?
    public let serverEndpointHostname: String?
    public let updatedAt: Date?
    public let ownerUid: String?
    public let ownerEmail: String?

    public init(
        clientId: String,
        clientName: String?,
        regionId: String,
        status: CloudGatewayClientStatus,
        wireGuardConfig: String?,
        assignedTunnelIpv4: String? = nil,
        serverEndpointIpv4: String? = nil,
        serverEndpointHostname: String? = nil,
        updatedAt: Date? = nil,
        ownerUid: String? = nil,
        ownerEmail: String? = nil
    ) {
        self.clientId = clientId
        self.clientName = clientName
        self.regionId = regionId
        self.status = status
        self.wireGuardConfig = wireGuardConfig
        self.assignedTunnelIpv4 = assignedTunnelIpv4
        self.serverEndpointIpv4 = serverEndpointIpv4
        self.serverEndpointHostname = serverEndpointHostname
        self.updatedAt = updatedAt
        self.ownerUid = ownerUid
        self.ownerEmail = ownerEmail
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
    public let configHash: String
    public let secretReference: GatewayConfigSecretReference
    public let readAt: Date
    public let updatedAt: Date?
    public let assignedTunnelIpv4: String?
    public let serverEndpointIpv4: String?
    public let serverEndpointHostname: String?

    public init(
        clientId: String,
        regionId: String,
        clientName: String?,
        regionDisplayName: String,
        status: CloudGatewayClientStatus,
        configHash: String,
        secretReference: GatewayConfigSecretReference,
        readAt: Date,
        updatedAt: Date?,
        assignedTunnelIpv4: String? = nil,
        serverEndpointIpv4: String? = nil,
        serverEndpointHostname: String? = nil
    ) {
        self.clientId = clientId
        self.regionId = regionId
        self.clientName = clientName
        self.regionDisplayName = regionDisplayName
        self.status = status
        self.configHash = configHash
        self.secretReference = secretReference
        self.readAt = readAt
        self.updatedAt = updatedAt
        self.assignedTunnelIpv4 = assignedTunnelIpv4
        self.serverEndpointIpv4 = serverEndpointIpv4
        self.serverEndpointHostname = serverEndpointHostname
    }

    public init(
        clientId: String,
        regionId: String,
        clientName: String?,
        regionDisplayName: String,
        status: CloudGatewayClientStatus,
        wireGuardConfig: String,
        readAt: Date,
        updatedAt: Date?,
        serviceName: String = GatewayConfigSecretDefaults.serviceName
    ) throws {
        let config = try GatewayWireGuardConfig(wireGuardConfig)
        let configHash = GatewayConfigHash.make(for: config)
        self.init(
            clientId: clientId,
            regionId: regionId,
            clientName: clientName,
            regionDisplayName: regionDisplayName,
            status: status,
            configHash: configHash,
            secretReference: GatewayConfigSecretReference.make(
                clientId: clientId,
                configHash: configHash,
                service: serviceName
            ),
            readAt: readAt,
            updatedAt: updatedAt
        )
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
            displayName: "\(regionDisplayName) - \(clientDisplayName)",
            configHash: configHash,
            secretReference: secretReference
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

    /// Builds the region selector from locally installed config metadata when
    /// the remote region list is unavailable. A device can only show regions
    /// represented by its installed snapshots, and the display name comes from
    /// the server response cached when each config was installed.
    public static func offlineRegions(
        from snapshots: [CloudGatewayConfigSnapshot]
    ) -> [CloudGatewayRegion] {
        let snapshotsByRegion = Dictionary(grouping: snapshots, by: \.regionId)
        return sortedRegions(snapshotsByRegion.map { regionId, snapshots in
            let displayName = snapshots
                .sorted { $0.readAt > $1.readAt }
                .first?
                .regionDisplayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CloudGatewayRegion(
                regionId: regionId,
                displayName: displayName?.isEmpty == false ? displayName! : regionId,
                enabled: true
            )
        })
    }

    // Build display rows from locally cached install snapshots, for when the
    // remote client list is unavailable (e.g. offline). Keeps an installed - and
    // possibly connected - tunnel visible and controllable. The WireGuard config
    // itself lives in the keychain, not the snapshot, so `wireGuardConfig` is nil
    // here; these rows drive the tunnel toggle, not (re)installation.
    public static func offlineClientOptions(
        from snapshots: [CloudGatewayConfigSnapshot]
    ) -> [CloudGatewayClientOption] {
        let regionsById = Dictionary(uniqueKeysWithValues: offlineRegions(from: snapshots).map { ($0.regionId, $0) })
        return snapshots
            .map { snapshot in
                CloudGatewayClientOption(
                    client: CloudGatewayClient(
                        clientId: snapshot.clientId,
                        clientName: snapshot.clientName,
                        regionId: snapshot.regionId,
                        status: snapshot.status,
                        wireGuardConfig: nil,
                        assignedTunnelIpv4: snapshot.assignedTunnelIpv4,
                        serverEndpointIpv4: snapshot.serverEndpointIpv4,
                        serverEndpointHostname: snapshot.serverEndpointHostname,
                        updatedAt: snapshot.updatedAt
                    ),
                    region: regionsById[snapshot.regionId]
                )
            }
            .sorted(by: compareOptions)
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
        readAt: Date = Date(),
        serviceName: String = GatewayConfigSecretDefaults.serviceName
    ) throws -> CloudGatewayConfigSnapshot {
        let wireGuardConfig = try wireGuardConfig(from: option)
        let configHash = GatewayConfigHash.make(for: wireGuardConfig)

        return CloudGatewayConfigSnapshot(
            clientId: option.client.clientId,
            regionId: option.client.regionId,
            clientName: option.client.clientName,
            regionDisplayName: option.regionDisplayName,
            status: option.client.status,
            configHash: configHash,
            secretReference: GatewayConfigSecretReference.make(
                clientId: option.client.clientId,
                configHash: configHash,
                service: serviceName
            ),
            readAt: readAt,
            updatedAt: option.client.updatedAt,
            assignedTunnelIpv4: option.client.assignedTunnelIpv4,
            serverEndpointIpv4: option.client.serverEndpointIpv4,
            serverEndpointHostname: option.client.serverEndpointHostname
        )
    }

    public static func wireGuardConfig(from option: CloudGatewayClientOption) throws -> GatewayWireGuardConfig {
        guard let wireGuardConfig = option.client.wireGuardConfig?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wireGuardConfig.isEmpty else {
            throw GatewayVPNError.missingWireGuardConfiguration
        }
        return try GatewayWireGuardConfig(wireGuardConfig)
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
              let remoteConfig = try? wireGuardConfig(from: option) else {
            return false
        }
        return GatewayConfigHash.make(for: remoteConfig) == snapshot.configHash
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

        // Group by owner email so an admin's multi-user list is ordered by user;
        // a no-op for normal users, whose clients share (or lack) one owner email.
        let ownerEmailComparison = (lhs.client.ownerEmail ?? "").localizedCaseInsensitiveCompare(rhs.client.ownerEmail ?? "")
        if ownerEmailComparison != .orderedSame {
            return ownerEmailComparison == .orderedAscending
        }

        let clientNameComparison = lhs.client.displayName.localizedCaseInsensitiveCompare(rhs.client.displayName)
        if clientNameComparison != .orderedSame {
            return clientNameComparison == .orderedAscending
        }

        return lhs.client.clientId.localizedCaseInsensitiveCompare(rhs.client.clientId) == .orderedAscending
    }
}

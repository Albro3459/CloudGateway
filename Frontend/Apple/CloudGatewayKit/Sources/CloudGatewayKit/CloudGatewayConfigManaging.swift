import Foundation

public protocol CloudGatewayTunnelManaging: Sendable {
    func installedStatus(for identifier: String) async throws -> GatewayTunnelStatus
    func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws
    func startTunnel(identifier: String) async throws
    func stopTunnel(identifier: String) async throws
    func removeTunnel(identifier: String) async throws
}

public protocol CloudGatewayConfigCaching: Sendable {
    func load() async throws -> [CloudGatewayConfigSnapshot]
    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws
    func clear(identifier: String) async throws
}

public enum CloudGatewayConfigInstallState: Equatable, Sendable {
    case installed
    case updateAvailable
}

public struct CloudGatewayConfigManagerState: Equatable, Sendable {
    public var regions: [CloudGatewayRegion]
    public var clientOptions: [CloudGatewayClientOption]
    public var configOptions: [CloudGatewayClientOption]
    public var installedSnapshots: [CloudGatewayConfigSnapshot]
    public var tunnelStatuses: [String: GatewayTunnelStatus]
    public var staleTexts: [String: String]
    public var lastRefreshDate: Date?
    public var remoteInvalidInstalledConfigIds: Set<String>

    public init(
        regions: [CloudGatewayRegion] = [],
        clientOptions: [CloudGatewayClientOption] = [],
        configOptions: [CloudGatewayClientOption] = [],
        installedSnapshots: [CloudGatewayConfigSnapshot] = [],
        tunnelStatuses: [String: GatewayTunnelStatus] = [:],
        staleTexts: [String: String] = [:],
        lastRefreshDate: Date? = nil,
        remoteInvalidInstalledConfigIds: Set<String> = []
    ) {
        self.regions = regions
        self.clientOptions = clientOptions
        self.configOptions = configOptions
        self.installedSnapshots = installedSnapshots
        self.tunnelStatuses = tunnelStatuses
        self.staleTexts = staleTexts
        self.lastRefreshDate = lastRefreshDate
        self.remoteInvalidInstalledConfigIds = remoteInvalidInstalledConfigIds
    }

    public func installState(for option: CloudGatewayClientOption) -> CloudGatewayConfigInstallState? {
        guard let installedSnapshot = installedSnapshot(
            clientId: option.client.clientId,
            regionId: option.client.regionId
        ) else {
            return nil
        }
        if CloudGatewayConfigSelection.configMatches(installedSnapshot, option: option) {
            return .installed
        }
        return .updateAvailable
    }

    public func installedSnapshot(clientId: String, regionId: String? = nil) -> CloudGatewayConfigSnapshot? {
        installedSnapshots.first { snapshot in
            snapshot.clientId == clientId && (regionId == nil || snapshot.regionId == regionId)
        }
    }

    public func tunnelStatus(for clientId: String) -> GatewayTunnelStatus? {
        tunnelStatuses[clientId]
    }

    public func staleText(for clientId: String) -> String? {
        staleTexts[clientId]
    }

    public func remoteInvalidInstalledConfig(for clientId: String) -> Bool {
        remoteInvalidInstalledConfigIds.contains(clientId)
    }
}

public enum CloudGatewayConfigManagerError: LocalizedError, Equatable, Sendable {
    case remoteInvalidInstalledConfig

    public var errorDescription: String? {
        switch self {
        case .remoteInvalidInstalledConfig:
            "The installed config is no longer active remotely. Choose another config before starting."
        }
    }
}

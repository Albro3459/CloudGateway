import Foundation

public protocol CloudGatewayTunnelManaging: Sendable {
    func installedStatus() async throws -> GatewayTunnelStatus
    func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws
    func startTunnel() async throws
    func stopTunnel() async throws
    func removeTunnel() async throws
}

public protocol CloudGatewayConfigCaching: Sendable {
    func load() async throws -> CloudGatewayConfigSnapshot?
    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws
    func clear() async throws
}

public enum CloudGatewayConfigInstallState: Equatable, Sendable {
    case installed
    case updateAvailable
}

public struct CloudGatewayConfigManagerState: Equatable, Sendable {
    public var configOptions: [CloudGatewayClientOption]
    public var cachedSnapshot: CloudGatewayConfigSnapshot?
    public var tunnelStatus: GatewayTunnelStatus?
    public var staleText: String?
    public var lastRefreshDate: Date?
    public var remoteInvalidInstalledConfig: Bool

    public init(
        configOptions: [CloudGatewayClientOption] = [],
        cachedSnapshot: CloudGatewayConfigSnapshot? = nil,
        tunnelStatus: GatewayTunnelStatus? = nil,
        staleText: String? = nil,
        lastRefreshDate: Date? = nil,
        remoteInvalidInstalledConfig: Bool = false
    ) {
        self.configOptions = configOptions
        self.cachedSnapshot = cachedSnapshot
        self.tunnelStatus = tunnelStatus
        self.staleText = staleText
        self.lastRefreshDate = lastRefreshDate
        self.remoteInvalidInstalledConfig = remoteInvalidInstalledConfig
    }

    public func installState(for option: CloudGatewayClientOption) -> CloudGatewayConfigInstallState? {
        guard let cachedSnapshot,
              cachedSnapshot.clientId == option.client.clientId,
              cachedSnapshot.regionId == option.client.regionId else {
            return nil
        }
        if CloudGatewayConfigSelection.configMatches(cachedSnapshot, option: option) {
            return .installed
        }
        return .updateAvailable
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

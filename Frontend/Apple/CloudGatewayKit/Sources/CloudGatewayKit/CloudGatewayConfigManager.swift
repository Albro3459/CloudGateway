import Foundation

public actor CloudGatewayConfigManager {
    private let tunnelManager: CloudGatewayTunnelManaging
    private let cache: CloudGatewayConfigCaching
    private let now: @Sendable () -> Date

    public private(set) var state: CloudGatewayConfigManagerState

    public init(
        tunnelManager: CloudGatewayTunnelManaging,
        cache: CloudGatewayConfigCaching,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tunnelManager = tunnelManager
        self.cache = cache
        self.now = now
        state = CloudGatewayConfigManagerState()
    }

    @discardableResult
    public func loadLocalState() async throws -> CloudGatewayConfigManagerState {
        state.cachedSnapshot = try await cache.load()
        return try await refreshStatus()
    }

    @discardableResult
    public func applyRemoteState(
        regions: [CloudGatewayRegion],
        clients: [CloudGatewayClient]
    ) async throws -> CloudGatewayConfigManagerState {
        state.regions = CloudGatewayConfigSelection.sortedRegions(regions)
        state.clientOptions = CloudGatewayConfigSelection.clientOptions(
            clients: clients,
            regions: state.regions
        )
        state.configOptions = CloudGatewayConfigSelection.usableOptions(
            clients: clients,
            regions: state.regions
        )
        state.cachedSnapshot = try await cache.load()
        updateStaleState()
        state.lastRefreshDate = now()
        return try await refreshStatus()
    }

    @discardableResult
    public func removeInstalledConfigIfMatches(
        clientId: String,
        regionId: String
    ) async throws -> CloudGatewayConfigManagerState {
        guard state.cachedSnapshot?.clientId == clientId,
              state.cachedSnapshot?.regionId == regionId else {
            return state
        }
        return try await removeTunnel()
    }

    @discardableResult
    public func markRemoteRefreshUnavailable() -> CloudGatewayConfigManagerState {
        if state.cachedSnapshot != nil, state.staleText == nil {
            state.staleText = "Unable to refresh remote state. The last installed config remains available offline."
            state.remoteInvalidInstalledConfig = false
        }
        return state
    }

    @discardableResult
    public func install(_ option: CloudGatewayClientOption) async throws -> CloudGatewayConfigManagerState {
        let snapshot = try CloudGatewayConfigSelection.snapshot(from: option, readAt: now())
        try await tunnelManager.installTunnel(snapshot.tunnelConfiguration())
        try await cache.save(snapshot)
        state.cachedSnapshot = snapshot
        state.staleText = nil
        state.remoteInvalidInstalledConfig = false
        return try await refreshStatus()
    }

    @discardableResult
    public func startTunnel() async throws -> CloudGatewayConfigManagerState {
        guard !state.remoteInvalidInstalledConfig else {
            throw CloudGatewayConfigManagerError.remoteInvalidInstalledConfig
        }
        try await tunnelManager.startTunnel()
        return try await refreshStatus()
    }

    @discardableResult
    public func stopTunnel() async throws -> CloudGatewayConfigManagerState {
        try await tunnelManager.stopTunnel()
        return try await refreshStatus()
    }

    @discardableResult
    public func removeTunnel() async throws -> CloudGatewayConfigManagerState {
        try await tunnelManager.removeTunnel()
        try await cache.clear()
        state.cachedSnapshot = nil
        state.tunnelStatus = nil
        state.staleText = nil
        state.remoteInvalidInstalledConfig = false
        return state
    }

    @discardableResult
    public func refreshStatus() async throws -> CloudGatewayConfigManagerState {
        do {
            state.tunnelStatus = try await tunnelManager.installedStatus()
        } catch GatewayVPNError.missingInstalledTunnel {
            state.tunnelStatus = nil
        }
        return state
    }

    public func installState(for option: CloudGatewayClientOption) -> CloudGatewayConfigInstallState? {
        guard let cachedSnapshot = state.cachedSnapshot,
              cachedSnapshot.clientId == option.client.clientId,
              cachedSnapshot.regionId == option.client.regionId else {
            return nil
        }
        if CloudGatewayConfigSelection.configMatches(cachedSnapshot, option: option) {
            return .installed
        }
        return .updateAvailable
    }

    private func updateStaleState() {
        state.remoteInvalidInstalledConfig = false
        guard let cachedSnapshot = state.cachedSnapshot else {
            state.staleText = nil
            return
        }
        guard let matchingOption = CloudGatewayConfigSelection.matchingOption(
            for: cachedSnapshot,
            in: state.configOptions
        ) else {
            state.staleText = "The last installed config is not active remotely. Choose another config before starting."
            state.remoteInvalidInstalledConfig = true
            return
        }
        if CloudGatewayConfigSelection.configMatches(cachedSnapshot, option: matchingOption) {
            state.staleText = nil
        } else {
            state.staleText = "The installed config has changed remotely. Install the update to refresh the local tunnel."
        }
    }
}

import Foundation

public actor CloudGatewayConfigManager {
    private let tunnelManager: CloudGatewayTunnelManaging
    private let cache: CloudGatewayConfigCaching
    private let secretStore: CloudGatewayConfigSecretStoring
    private let configSecretServiceName: String
    private let now: @Sendable () -> Date

    public private(set) var state: CloudGatewayConfigManagerState

    public init(
        tunnelManager: CloudGatewayTunnelManaging,
        cache: CloudGatewayConfigCaching,
        secretStore: CloudGatewayConfigSecretStoring,
        configSecretServiceName: String = GatewayConfigSecretDefaults.serviceName,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tunnelManager = tunnelManager
        self.cache = cache
        self.secretStore = secretStore
        self.configSecretServiceName = configSecretServiceName
        self.now = now
        state = CloudGatewayConfigManagerState()
    }

    @discardableResult
    public func loadLocalState() async throws -> CloudGatewayConfigManagerState {
        state.installedSnapshots = try await cache.load()
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
        state.installedSnapshots = try await cache.load()
        updateStaleState()
        state.lastRefreshDate = now()
        return try await refreshStatus()
    }

    @discardableResult
    public func removeInstalledConfigIfMatches(
        clientId: String,
        regionId: String
    ) async throws -> CloudGatewayConfigManagerState {
        guard state.installedSnapshot(clientId: clientId, regionId: regionId) != nil else {
            return state
        }
        return try await removeTunnel(identifier: clientId)
    }

    @discardableResult
    public func markRemoteRefreshUnavailable() -> CloudGatewayConfigManagerState {
        guard !state.installedSnapshots.isEmpty else {
            return state
        }
        for snapshot in state.installedSnapshots where state.staleTexts[snapshot.clientId] == nil {
            state.staleTexts[snapshot.clientId] = "Unable to refresh remote state. The last installed config remains available offline."
        }
        return state
    }

    @discardableResult
    public func install(_ option: CloudGatewayClientOption) async throws -> CloudGatewayConfigManagerState {
        let oldReference = state.installedSnapshot(clientId: option.client.clientId)?.secretReference
        let wireGuardConfig = try CloudGatewayConfigSelection.wireGuardConfig(from: option)
        let snapshot = try CloudGatewayConfigSelection.snapshot(
            from: option,
            readAt: now(),
            serviceName: configSecretServiceName
        )
        do {
            try secretStore.saveConfig(wireGuardConfig, for: snapshot.secretReference)
            try await tunnelManager.installTunnel(snapshot.tunnelConfiguration())
        } catch {
            if oldReference != snapshot.secretReference {
                try? secretStore.deleteConfig(for: snapshot.secretReference)
            }
            throw error
        }
        do {
            try await cache.save(snapshot)
        } catch {
            // The profile + keychain secret are already written, so keep them
            // installed and surface a specific error telling the user the install
            // partially completed; a refresh/reinstall reconciles the local cache.
            throw CloudGatewayConfigManagerError.installCachePersistFailed
        }
        if let oldReference, oldReference != snapshot.secretReference {
            try? secretStore.deleteConfig(for: oldReference)
        }
        replaceInstalledSnapshot(snapshot)
        state.staleTexts[snapshot.clientId] = nil
        state.remoteInvalidInstalledConfigIds.remove(snapshot.clientId)
        return try await refreshStatus()
    }

    @discardableResult
    public func startTunnel(identifier: String) async throws -> CloudGatewayConfigManagerState {
        guard !state.remoteInvalidInstalledConfigIds.contains(identifier) else {
            throw CloudGatewayConfigManagerError.remoteInvalidInstalledConfig
        }
        try await tunnelManager.startTunnel(identifier: identifier)
        return try await refreshStatus()
    }

    @discardableResult
    public func stopTunnel(identifier: String) async throws -> CloudGatewayConfigManagerState {
        try await tunnelManager.stopTunnel(identifier: identifier)
        return try await refreshStatus()
    }

    @discardableResult
    public func removeTunnel(identifier: String) async throws -> CloudGatewayConfigManagerState {
        let secretReference = state.installedSnapshot(clientId: identifier)?.secretReference
        try await tunnelManager.removeTunnel(identifier: identifier)
        try await cache.clear(identifier: identifier)
        if let secretReference {
            try secretStore.deleteConfig(for: secretReference)
        }
        state.installedSnapshots.removeAll { $0.clientId == identifier }
        state.tunnelStatuses[identifier] = nil
        state.staleTexts[identifier] = nil
        state.remoteInvalidInstalledConfigIds.remove(identifier)
        return state
    }

    @discardableResult
    public func refreshStatus() async throws -> CloudGatewayConfigManagerState {
        let identifiers = state.installedSnapshots.map(\.clientId)
        let statuses = try await tunnelManager.installedStatuses(for: identifiers)
        var missingSnapshots = [CloudGatewayConfigSnapshot]()
        for snapshot in state.installedSnapshots {
            if statuses[snapshot.clientId] == nil {
                missingSnapshots.append(snapshot)
            }
        }
        for snapshot in missingSnapshots {
            try await cache.clear(identifier: snapshot.clientId)
            state.installedSnapshots.removeAll { $0.clientId == snapshot.clientId }
            state.staleTexts[snapshot.clientId] = nil
            state.remoteInvalidInstalledConfigIds.remove(snapshot.clientId)
            try? secretStore.deleteConfig(for: snapshot.secretReference)
        }
        state.tunnelStatuses = statuses
        return state
    }

    public func installState(for option: CloudGatewayClientOption) -> CloudGatewayConfigInstallState? {
        state.installState(for: option)
    }

    private func updateStaleState() {
        state.staleTexts = [:]
        state.remoteInvalidInstalledConfigIds = []
        for snapshot in state.installedSnapshots {
            guard let matchingOption = CloudGatewayConfigSelection.matchingOption(
                for: snapshot,
                in: state.configOptions
            ) else {
                state.staleTexts[snapshot.clientId] = "The last installed config is not active remotely. Choose another config before starting."
                state.remoteInvalidInstalledConfigIds.insert(snapshot.clientId)
                continue
            }
            if CloudGatewayConfigSelection.configMatches(snapshot, option: matchingOption) {
                state.staleTexts[snapshot.clientId] = nil
            } else {
                state.staleTexts[snapshot.clientId] = "The installed config has changed remotely. Install the update to refresh the local tunnel."
            }
        }
    }

    private func replaceInstalledSnapshot(_ snapshot: CloudGatewayConfigSnapshot) {
        state.installedSnapshots.removeAll { $0.clientId == snapshot.clientId }
        state.installedSnapshots.append(snapshot)
        state.installedSnapshots.sort { lhs, rhs in
            let nameComparison = lhs.clientDisplayName.localizedCaseInsensitiveCompare(rhs.clientDisplayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.clientId.localizedCaseInsensitiveCompare(rhs.clientId) == .orderedAscending
        }
    }
}

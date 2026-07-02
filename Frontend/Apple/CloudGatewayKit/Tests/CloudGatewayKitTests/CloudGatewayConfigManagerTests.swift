import Foundation
import Testing
@testable import CloudGatewayKit

private let managerConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
"""

private enum ManagerTestError: Error {
    case installFailed
}

@Test func managerApplyRemoteStateDoesNotPreselectConfig() async throws {
    let tunnelManager = RecordingTunnelManager()
    let cache = MemoryConfigCache()
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    let state = try await manager.applyRemoteState(
        regions: [region()],
        clients: [client(id: "client-1")]
    )

    #expect(state.configOptions.map(\.client.clientId) == ["client-1"])
    #expect(state.installedSnapshots.isEmpty)
    #expect(await tunnelManager.installedIdentifiers().isEmpty)
    #expect(await cache.savedSnapshots().isEmpty)
}

@Test func managerApplyRemoteStateKeepsRegionsAndAllOwnedClients() async throws {
    let tunnelManager = RecordingTunnelManager()
    let cache = MemoryConfigCache()
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    let state = try await manager.applyRemoteState(
        regions: [region()],
        clients: [
            client(id: "active"),
            CloudGatewayClient(
                clientId: "creating",
                clientName: "Creating",
                regionId: "us-sanjose-1",
                status: .creating,
                wireGuardConfig: nil
            ),
        ]
    )

    #expect(state.regions.map(\.regionId) == ["us-sanjose-1"])
    #expect(state.clientOptions.map(\.client.clientId) == ["creating", "active"])
    #expect(state.configOptions.map(\.client.clientId) == ["active"])
}

@Test func managerInstallSavesCacheAfterTunnelInstallSucceeds() async throws {
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache()
    let manager = CloudGatewayConfigManager(
        tunnelManager: tunnelManager,
        cache: cache,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let option = CloudGatewayClientOption(client: client(id: "client-1"), region: region())

    let state = try await manager.install(option)

    #expect(await tunnelManager.installedIdentifiers() == ["client-1"])
    #expect(await tunnelManager.installedDisplayNames() == ["Phone"])
    #expect(await cache.savedSnapshots().map(\.clientId) == ["client-1"])
    #expect(state.installedSnapshots.map(\.clientId) == ["client-1"])
    #expect(state.tunnelStatus(for: "client-1") == .disconnected)
}

@Test func managerInstallsMultipleClientsAsDistinctLocalProfiles() async throws {
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache()
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    _ = try await manager.install(CloudGatewayClientOption(client: client(id: "client-1", clientName: "Phone"), region: region()))
    let state = try await manager.install(CloudGatewayClientOption(client: client(id: "client-2", clientName: "Laptop"), region: region()))

    #expect(await tunnelManager.installedIdentifiers() == ["client-1", "client-2"])
    #expect(await tunnelManager.installedDisplayNames() == ["Phone", "Laptop"])
    #expect(state.installedSnapshots.map(\.clientId).sorted() == ["client-1", "client-2"])
    #expect(state.tunnelStatus(for: "client-1") == .disconnected)
    #expect(state.tunnelStatus(for: "client-2") == .disconnected)
}

@Test func managerInstallingUpdateRewritesOnlyMatchingProfileAndCanChangeDisplayName() async throws {
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache()
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    _ = try await manager.install(CloudGatewayClientOption(client: client(id: "client-1", clientName: "Phone"), region: region()))
    _ = try await manager.install(CloudGatewayClientOption(client: client(id: "client-2", clientName: "Laptop"), region: region()))
    let state = try await manager.install(CloudGatewayClientOption(
        client: client(id: "client-1", clientName: "Renamed Phone", wireGuardConfig: managerConfig + "\n# changed"),
        region: region()
    ))

    #expect(await tunnelManager.installedIdentifiers() == ["client-1", "client-2"])
    #expect(await tunnelManager.installedDisplayNames() == ["Renamed Phone", "Laptop"])
    #expect(state.installedSnapshots.count == 2)
    #expect(state.installedSnapshot(clientId: "client-1")?.clientDisplayName == "Renamed Phone")
    #expect(state.installedSnapshot(clientId: "client-2")?.clientDisplayName == "Laptop")
}

@Test func managerDoesNotSaveCacheWhenTunnelInstallFails() async throws {
    let tunnelManager = RecordingTunnelManager(installError: ManagerTestError.installFailed)
    let cache = MemoryConfigCache()
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)
    let option = CloudGatewayClientOption(client: client(id: "client-1"), region: region())

    await #expect(throws: ManagerTestError.installFailed) {
        try await manager.install(option)
    }

    #expect(await cache.savedSnapshots().isEmpty)
}

@Test func managerMarksMissingRemoteInstalledConfigInvalidAndBlocksStart() async throws {
    let snapshot = cachedSnapshot(clientId: "missing")
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache(snapshots: [snapshot])
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    let state = try await manager.applyRemoteState(
        regions: [region()],
        clients: [client(id: "other")]
    )

    #expect(state.remoteInvalidInstalledConfig(for: "missing"))
    #expect(state.staleText(for: "missing") == "The last installed config is not active remotely. Choose another config before starting.")
    await #expect(throws: CloudGatewayConfigManagerError.remoteInvalidInstalledConfig) {
        try await manager.startTunnel(identifier: "missing")
    }
    #expect(await tunnelManager.startCount() == 0)
}

@Test func managerShowsUpdateAvailableForChangedRemoteConfig() async throws {
    let snapshot = cachedSnapshot(clientId: "client-1")
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache(snapshots: [snapshot])
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    let state = try await manager.applyRemoteState(
        regions: [region()],
        clients: [client(id: "client-1", wireGuardConfig: managerConfig + "\n# changed")]
    )

    #expect(!state.remoteInvalidInstalledConfig(for: "client-1"))
    #expect(state.staleText(for: "client-1") == "The installed config has changed remotely. Install the update to refresh the local tunnel.")
    #expect(state.installState(for: state.configOptions[0]) == .updateAvailable)
}

@Test func managerRemoveInstalledConfigIfMatchesOnlyClearsMatchingLocalTunnel() async throws {
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache(snapshots: [
        cachedSnapshot(clientId: "client-1"),
        cachedSnapshot(clientId: "client-2"),
    ])
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)
    _ = try await manager.loadLocalState()

    var state = try await manager.removeInstalledConfigIfMatches(
        clientId: "other",
        regionId: "us-sanjose-1"
    )

    #expect(state.installedSnapshots.map(\.clientId).sorted() == ["client-1", "client-2"])
    #expect(await tunnelManager.removeCount() == 0)

    state = try await manager.removeInstalledConfigIfMatches(
        clientId: "client-1",
        regionId: "us-sanjose-1"
    )

    #expect(state.installedSnapshots.map(\.clientId) == ["client-2"])
    #expect(await tunnelManager.removeCount() == 1)
    #expect(await tunnelManager.removedIdentifiers() == ["client-1"])
    #expect(await cache.clearCount() == 1)
}

@Test func managerRemoveTunnelClearsCacheAndInstalledState() async throws {
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache(snapshots: [
        cachedSnapshot(clientId: "client-1"),
        cachedSnapshot(clientId: "client-2"),
    ])
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)
    _ = try await manager.loadLocalState()

    let state = try await manager.removeTunnel(identifier: "client-1")

    #expect(await tunnelManager.removeCount() == 1)
    #expect(await tunnelManager.removedIdentifiers() == ["client-1"])
    #expect(await cache.clearCount() == 1)
    #expect(state.installedSnapshots.map(\.clientId) == ["client-2"])
    #expect(state.tunnelStatus(for: "client-1") == nil)
    #expect(state.tunnelStatus(for: "client-2") == .disconnected)
}

@Test func managerStartStopTargetsSelectedIdentifier() async throws {
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache(snapshots: [
        cachedSnapshot(clientId: "client-1"),
        cachedSnapshot(clientId: "client-2"),
    ])
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)
    _ = try await manager.loadLocalState()

    var state = try await manager.startTunnel(identifier: "client-2")

    #expect(await tunnelManager.startedIdentifiers() == ["client-2"])
    #expect(state.tunnelStatus(for: "client-1") == .disconnected)
    #expect(state.tunnelStatus(for: "client-2") == .connected)

    state = try await manager.stopTunnel(identifier: "client-2")

    #expect(await tunnelManager.stoppedIdentifiers() == ["client-2"])
    #expect(state.tunnelStatus(for: "client-2") == .disconnected)
}

private func region(
    id: String = "us-sanjose-1",
    displayName: String = "San Jose"
) -> CloudGatewayRegion {
    CloudGatewayRegion(regionId: id, displayName: displayName, enabled: true, displayOrder: 10)
}

private func client(
    id: String,
    clientName: String = "Phone",
    wireGuardConfig: String = managerConfig
) -> CloudGatewayClient {
    CloudGatewayClient(
        clientId: id,
        clientName: clientName,
        regionId: "us-sanjose-1",
        status: .active,
        wireGuardConfig: wireGuardConfig,
        updatedAt: Date(timeIntervalSince1970: 50)
    )
}

private func cachedSnapshot(clientId: String) -> CloudGatewayConfigSnapshot {
    CloudGatewayConfigSnapshot(
        clientId: clientId,
        regionId: "us-sanjose-1",
        clientName: "Phone",
        regionDisplayName: "San Jose",
        status: .active,
        wireGuardConfig: managerConfig,
        readAt: Date(timeIntervalSince1970: 25),
        updatedAt: Date(timeIntervalSince1970: 50)
    )
}

private actor RecordingTunnelManager: CloudGatewayTunnelManaging {
    private var status: GatewayTunnelStatus?
    private let installError: (any Error)?
    private var installedTunnels = [String: GatewayTunnelConfiguration]()
    private var statuses = [String: GatewayTunnelStatus]()
    private var starts = [String]()
    private var stops = [String]()
    private var removes = [String]()

    init(
        status: GatewayTunnelStatus? = nil,
        installError: (any Error)? = nil
    ) {
        self.status = status
        self.installError = installError
    }

    func installedStatus(for identifier: String) async throws -> GatewayTunnelStatus {
        guard let status = statuses[identifier] ?? status else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return status
    }

    func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws {
        if let installError {
            throw installError
        }
        installedTunnels[tunnel.identifier] = tunnel
        statuses[tunnel.identifier] = .disconnected
    }

    func startTunnel(identifier: String) async throws {
        starts.append(identifier)
        statuses[identifier] = .connected
    }

    func stopTunnel(identifier: String) async throws {
        stops.append(identifier)
        statuses[identifier] = .disconnected
    }

    func removeTunnel(identifier: String) async throws {
        removes.append(identifier)
        installedTunnels[identifier] = nil
        statuses[identifier] = nil
    }

    func installedIdentifiers() -> [String] {
        installedTunnels.values.sorted { $0.identifier < $1.identifier }.map(\.identifier)
    }

    func installedDisplayNames() -> [String] {
        installedTunnels.values.sorted { $0.identifier < $1.identifier }.map(\.displayName)
    }

    func startCount() -> Int {
        starts.count
    }

    func startedIdentifiers() -> [String] {
        starts
    }

    func stoppedIdentifiers() -> [String] {
        stops
    }

    func removeCount() -> Int {
        removes.count
    }

    func removedIdentifiers() -> [String] {
        removes
    }
}

private actor MemoryConfigCache: CloudGatewayConfigCaching {
    private var snapshots: [CloudGatewayConfigSnapshot]
    private var saved = [CloudGatewayConfigSnapshot]()
    private var clears = 0

    init(snapshots: [CloudGatewayConfigSnapshot] = []) {
        self.snapshots = snapshots
    }

    func load() async throws -> [CloudGatewayConfigSnapshot] {
        snapshots
    }

    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws {
        snapshots.removeAll { $0.clientId == snapshot.clientId }
        snapshots.append(snapshot)
        saved.append(snapshot)
    }

    func clear(identifier: String) async throws {
        snapshots.removeAll { $0.clientId == identifier }
        clears += 1
    }

    func savedSnapshots() -> [CloudGatewayConfigSnapshot] {
        saved
    }

    func clearCount() -> Int {
        clears
    }
}

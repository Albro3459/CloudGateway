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
    #expect(state.cachedSnapshot == nil)
    #expect(await tunnelManager.installedIdentifiers().isEmpty)
    #expect(await cache.savedSnapshots().isEmpty)
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
    #expect(await cache.savedSnapshots().map(\.clientId) == ["client-1"])
    #expect(state.cachedSnapshot?.clientId == "client-1")
    #expect(state.tunnelStatus == .disconnected)
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
    let cache = MemoryConfigCache(snapshot: snapshot)
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    let state = try await manager.applyRemoteState(
        regions: [region()],
        clients: [client(id: "other")]
    )

    #expect(state.remoteInvalidInstalledConfig)
    #expect(state.staleText == "The last installed config is not active remotely. Choose another config before starting.")
    await #expect(throws: CloudGatewayConfigManagerError.remoteInvalidInstalledConfig) {
        try await manager.startTunnel()
    }
    #expect(await tunnelManager.startCount() == 0)
}

@Test func managerShowsUpdateAvailableForChangedRemoteConfig() async throws {
    let snapshot = cachedSnapshot(clientId: "client-1")
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache(snapshot: snapshot)
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    let state = try await manager.applyRemoteState(
        regions: [region()],
        clients: [client(id: "client-1", wireGuardConfig: managerConfig + "\n# changed")]
    )

    #expect(!state.remoteInvalidInstalledConfig)
    #expect(state.staleText == "The installed config has changed remotely. Install the update to refresh the local tunnel.")
    #expect(state.installState(for: state.configOptions[0]) == .updateAvailable)
}

@Test func managerRemoveTunnelClearsCacheAndInstalledState() async throws {
    let tunnelManager = RecordingTunnelManager(status: .disconnected)
    let cache = MemoryConfigCache(snapshot: cachedSnapshot(clientId: "client-1"))
    let manager = CloudGatewayConfigManager(tunnelManager: tunnelManager, cache: cache)

    let state = try await manager.removeTunnel()

    #expect(await tunnelManager.removeCount() == 1)
    #expect(await cache.clearCount() == 1)
    #expect(state.cachedSnapshot == nil)
    #expect(state.tunnelStatus == nil)
}

private func region(
    id: String = "us-sanjose-1",
    displayName: String = "San Jose"
) -> CloudGatewayRegion {
    CloudGatewayRegion(regionId: id, displayName: displayName, enabled: true, displayOrder: 10)
}

private func client(
    id: String,
    wireGuardConfig: String = managerConfig
) -> CloudGatewayClient {
    CloudGatewayClient(
        clientId: id,
        clientName: "Phone",
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
    private var installedTunnels = [GatewayTunnelConfiguration]()
    private var starts = 0
    private var removes = 0

    init(
        status: GatewayTunnelStatus? = nil,
        installError: (any Error)? = nil
    ) {
        self.status = status
        self.installError = installError
    }

    func installedStatus() async throws -> GatewayTunnelStatus {
        guard let status else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return status
    }

    func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws {
        if let installError {
            throw installError
        }
        installedTunnels.append(tunnel)
        status = .disconnected
    }

    func startTunnel() async throws {
        starts += 1
        status = .connected
    }

    func stopTunnel() async throws {
        status = .disconnected
    }

    func removeTunnel() async throws {
        removes += 1
        status = nil
    }

    func installedIdentifiers() -> [String] {
        installedTunnels.map(\.identifier)
    }

    func startCount() -> Int {
        starts
    }

    func removeCount() -> Int {
        removes
    }
}

private actor MemoryConfigCache: CloudGatewayConfigCaching {
    private var snapshot: CloudGatewayConfigSnapshot?
    private var saved = [CloudGatewayConfigSnapshot]()
    private var clears = 0

    init(snapshot: CloudGatewayConfigSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() async throws -> CloudGatewayConfigSnapshot? {
        snapshot
    }

    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws {
        self.snapshot = snapshot
        saved.append(snapshot)
    }

    func clear() async throws {
        snapshot = nil
        clears += 1
    }

    func savedSnapshots() -> [CloudGatewayConfigSnapshot] {
        saved
    }

    func clearCount() -> Int {
        clears
    }
}

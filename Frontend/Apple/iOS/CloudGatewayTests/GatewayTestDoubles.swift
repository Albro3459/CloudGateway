import CloudGatewayKit
import Foundation

final class FakeTunnelHealthReader: CloudGatewayTunnelHealthReading {
    var snapshot: GatewayTunnelHealthSnapshot?

    init(snapshot: GatewayTunnelHealthSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> GatewayTunnelHealthSnapshot? {
        snapshot
    }
}

/// In-memory tunnel manager for view-model tests. Reports "no installed tunnel" by
/// default so `CloudGatewayConfigManager.refreshStatus()` maps it to a nil status.
actor FakeTunnelManager: CloudGatewayTunnelManaging {
    private var status: GatewayTunnelStatus?
    private var statuses = [String: GatewayTunnelStatus]()
    private var knownIdentifiers = Set<String>()
    private var startError: Error?
    private var stopError: Error?
    private var statusReadError: Error?
    private var allStatusesReadDelay: Duration?
    private var stopDelay: Duration?
    private var stopResultStatus: GatewayTunnelStatus = .disconnected
    private var stoppedIdentifiers = [String]()

    init(status: GatewayTunnelStatus? = nil) {
        self.status = status
    }

    func installedStatus(for identifier: String) async throws -> GatewayTunnelStatus {
        guard let status = try await installedStatuses(for: [identifier])[identifier] else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return status
    }

    func installedStatuses(for identifiers: [String]) async throws -> [String: GatewayTunnelStatus] {
        if let statusReadError {
            throw statusReadError
        }
        knownIdentifiers.formUnion(identifiers)
        return identifiers.reduce(into: [String: GatewayTunnelStatus]()) { result, identifier in
            if let status = statuses[identifier] ?? status {
                result[identifier] = status
            }
        }
    }

    func allInstalledStatuses() async throws -> [String: GatewayTunnelStatus] {
        if let allStatusesReadDelay {
            try await ContinuousClock().sleep(for: allStatusesReadDelay)
        }
        if let statusReadError {
            throw statusReadError
        }
        return knownIdentifiers.reduce(into: statuses) { result, identifier in
            if let status {
                result[identifier] = result[identifier] ?? status
            }
        }
    }

    func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws {
        statuses[tunnel.identifier] = .disconnected
    }

    func startTunnel(identifier: String) async throws {
        if let startError {
            throw startError
        }
        statuses[identifier] = .connected
    }

    func stopTunnel(identifier: String) async throws {
        if let stopError {
            throw stopError
        }
        stoppedIdentifiers.append(identifier)
        if let stopDelay {
            try await ContinuousClock().sleep(for: stopDelay)
        }
        statuses[identifier] = stopResultStatus
    }

    func removeTunnel(identifier: String) async throws {
        statuses[identifier] = nil
    }

    func setStatus(_ status: GatewayTunnelStatus?, for identifier: String) {
        statuses[identifier] = status
    }

    func setStartError(_ error: Error?) {
        startError = error
    }

    func setStopError(_ error: Error?) {
        stopError = error
    }

    func setStatusReadError(_ error: Error?) {
        statusReadError = error
    }

    func setAllStatusesReadDelay(_ delay: Duration?) {
        allStatusesReadDelay = delay
    }

    func setStopDelay(_ delay: Duration?) {
        stopDelay = delay
    }

    func setStopResultStatus(_ status: GatewayTunnelStatus) {
        stopResultStatus = status
    }

    func stopRequests() -> [String] {
        stoppedIdentifiers
    }
}

/// In-memory config cache for view-model tests.
actor FakeConfigCache: CloudGatewayConfigCaching {
    private var snapshots: [CloudGatewayConfigSnapshot]

    init(snapshots: [CloudGatewayConfigSnapshot] = []) {
        self.snapshots = snapshots
    }

    func load() async throws -> [CloudGatewayConfigSnapshot] {
        snapshots
    }

    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws {
        snapshots.removeAll { $0.clientId == snapshot.clientId }
        snapshots.append(snapshot)
    }

    func clear(identifier: String) async throws {
        snapshots.removeAll { $0.clientId == identifier }
    }
}

final class FakeConfigSecretStore: CloudGatewayConfigSecretStoring, @unchecked Sendable {
    private var configs = [GatewayConfigSecretReference: GatewayWireGuardConfig]()

    func saveConfig(_ config: GatewayWireGuardConfig, for reference: GatewayConfigSecretReference) throws {
        configs[reference] = config
    }

    func loadConfig(for reference: GatewayConfigSecretReference) throws -> GatewayWireGuardConfig {
        guard let config = configs[reference] else {
            throw GatewayVPNError.keychainReadFailed(-25300)
        }
        return config
    }

    func deleteConfig(for reference: GatewayConfigSecretReference) throws {
        configs[reference] = nil
    }
}

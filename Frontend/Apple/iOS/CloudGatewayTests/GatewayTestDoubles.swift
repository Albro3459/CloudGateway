import CloudGatewayKit
import Foundation

/// In-memory tunnel manager for view-model tests. Reports "no installed tunnel" by
/// default so `CloudGatewayConfigManager.refreshStatus()` maps it to a nil status.
actor FakeTunnelManager: CloudGatewayTunnelManaging {
    private var status: GatewayTunnelStatus?
    private var statuses = [String: GatewayTunnelStatus]()
    private var startError: Error?
    private var stopError: Error?

    init(status: GatewayTunnelStatus? = nil) {
        self.status = status
    }

    func installedStatus(for identifier: String) async throws -> GatewayTunnelStatus {
        guard let status = statuses[identifier] ?? status else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return status
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
        statuses[identifier] = .disconnected
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

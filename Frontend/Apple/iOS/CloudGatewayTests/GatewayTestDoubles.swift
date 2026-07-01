import CloudGatewayKit
import Foundation

/// In-memory tunnel manager for view-model tests. Reports "no installed tunnel" by
/// default so `CloudGatewayConfigManager.refreshStatus()` maps it to a nil status.
actor FakeTunnelManager: CloudGatewayTunnelManaging {
    private var status: GatewayTunnelStatus?

    init(status: GatewayTunnelStatus? = nil) {
        self.status = status
    }

    func installedStatus() async throws -> GatewayTunnelStatus {
        guard let status else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return status
    }

    func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws {
        status = .disconnected
    }

    func startTunnel() async throws {
        status = .connected
    }

    func stopTunnel() async throws {
        status = .disconnected
    }

    func removeTunnel() async throws {
        status = nil
    }
}

/// In-memory config cache for view-model tests.
actor FakeConfigCache: CloudGatewayConfigCaching {
    private var snapshot: CloudGatewayConfigSnapshot?

    init(snapshot: CloudGatewayConfigSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() async throws -> CloudGatewayConfigSnapshot? {
        snapshot
    }

    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws {
        self.snapshot = snapshot
    }

    func clear() async throws {
        snapshot = nil
    }
}

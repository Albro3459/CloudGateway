import Foundation
import NetworkExtension

public final class GatewayVPNManager {
    public let platform: GatewayPlatformConfiguration

    public init(platform: GatewayPlatformConfiguration) {
        self.platform = platform
    }

    public func makeProtocolConfiguration(
        for tunnel: GatewayTunnelConfiguration
    ) -> NETunnelProviderProtocol {
        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = platform.providerBundleIdentifier
        protocolConfiguration.serverAddress = platform.tunnelDisplayName
        protocolConfiguration.providerConfiguration = GatewayProviderConfiguration(
            platform: platform,
            tunnel: tunnel
        ).values
        return protocolConfiguration
    }

    public func installedStatus() async throws -> GatewayTunnelStatus {
        let manager = try await installedManager()
        return GatewayTunnelStatus(manager.connection.status)
    }

    public func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws {
        let manager = try await installedManagerOrNew()
        manager.localizedDescription = platform.tunnelDisplayName
        manager.protocolConfiguration = makeProtocolConfiguration(for: tunnel)
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    public func removeTunnel() async throws {
        let manager = try await installedManager()
        try await manager.removeFromPreferences()
    }

    public func startTunnel() async throws {
        let manager = try await installedManager()
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw GatewayVPNError.missingTunnelSession
        }
        try session.startTunnel()
    }

    public func stopTunnel() async throws {
        let manager = try await installedManager()
        manager.connection.stopVPNTunnel()
    }

    public func installedManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first(where: { manager in
            guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return protocolConfiguration.providerBundleIdentifier == platform.providerBundleIdentifier
        }) else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return manager
    }

    private func installedManagerOrNew() async throws -> NETunnelProviderManager {
        do {
            return try await installedManager()
        } catch GatewayVPNError.missingInstalledTunnel {
            return NETunnelProviderManager()
        }
    }
}

extension GatewayVPNManager: CloudGatewayTunnelManaging {}

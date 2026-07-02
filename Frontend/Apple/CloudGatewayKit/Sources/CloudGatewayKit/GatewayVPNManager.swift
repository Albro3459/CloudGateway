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
        protocolConfiguration.serverAddress = tunnel.displayName
        protocolConfiguration.providerConfiguration = GatewayProviderConfiguration(
            platform: platform,
            tunnel: tunnel
        ).values
        return protocolConfiguration
    }

    public func installedStatus(for identifier: String) async throws -> GatewayTunnelStatus {
        let manager = try await installedManager(for: identifier)
        return GatewayTunnelStatus(manager.connection.status)
    }

    public func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws {
        let manager = try await installedManagerOrNew(for: tunnel.identifier)
        manager.localizedDescription = tunnel.displayName
        manager.protocolConfiguration = makeProtocolConfiguration(for: tunnel)
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    public func removeTunnel(identifier: String) async throws {
        let manager = try await installedManager(for: identifier)
        try await manager.removeFromPreferences()
    }

    public func startTunnel(identifier: String) async throws {
        let manager = try await installedManager(for: identifier)
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw GatewayVPNError.missingTunnelSession
        }
        try session.startTunnel()
    }

    public func stopTunnel(identifier: String) async throws {
        let manager = try await installedManager(for: identifier)
        manager.connection.stopVPNTunnel()
    }

    public func installedManager(for identifier: String) async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first(where: { manager in
            guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return protocolConfiguration.providerBundleIdentifier == platform.providerBundleIdentifier
                && protocolConfiguration.providerConfiguration?[GatewayProviderConfigurationKey.tunnelIdentifier] as? String == identifier
        }) else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return manager
    }

    private func installedManagerOrNew(for identifier: String) async throws -> NETunnelProviderManager {
        do {
            return try await installedManager(for: identifier)
        } catch GatewayVPNError.missingInstalledTunnel {
            return NETunnelProviderManager()
        }
    }
}

extension GatewayVPNManager: CloudGatewayTunnelManaging {}

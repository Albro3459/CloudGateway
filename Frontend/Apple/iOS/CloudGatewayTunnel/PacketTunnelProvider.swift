import CloudGatewayKit
import NetworkExtension
import os
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        let logType: OSLogType = level == .error ? .error : .debug
        os_log("%{public}@", log: .default, type: logType, message)
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let tunnelConfiguration = try makeTunnelConfiguration()
            adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
                completionHandler(error)
            }
        } catch {
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        adapter.stop { _ in
            completionHandler()
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler else { return }
        guard messageData.count == 1, messageData[0] == 0 else {
            completionHandler(nil)
            return
        }

        adapter.getRuntimeConfiguration { runtimeConfiguration in
            completionHandler(runtimeConfiguration?.data(using: .utf8))
        }
    }

    private func makeTunnelConfiguration() throws -> TunnelConfiguration {
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = protocolConfiguration.providerConfiguration,
              let wireGuardConfig = providerConfiguration[GatewayProviderConfigurationKey.wireGuardConfig] as? String else {
            throw GatewayVPNError.missingWireGuardConfiguration
        }

        let tunnelName = protocolConfiguration.serverAddress ?? "CloudGateway"
        return try WgQuickConfigParser.parse(wireGuardConfig, named: tunnelName)
    }
}

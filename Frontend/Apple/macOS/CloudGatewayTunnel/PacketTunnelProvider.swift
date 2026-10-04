import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import NetworkExtension
import WireGuardKit

enum CloudGatewayMacTunnelRuntime {
    static let secretService = CloudGatewayMacSecretService()
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let lifecycle = CloudGatewayMacTunnelLifecycle()
    private lazy var runtime = MacWireGuardRuntime(provider: self)

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = MacStartCompletion(callback: completionHandler)
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
              let metadata = protocolConfiguration.providerConfiguration,
              let referenceValue = metadata[CloudGatewayMacProviderKey.secretReference] as? String,
              let configId = metadata[CloudGatewayMacProviderKey.configId] as? String,
              let grant = options?[CloudGatewayMacProviderKey.startGrant] as? String,
              let reference = try? CloudGatewayMacSecretReference(value: referenceValue) else {
            completion.callback(MacTunnelError.authorizationFailed)
            return
        }
        lifecycle.start(operation: { [self] attempt in
            let runtime = runtime
            Task {
                do {
                    let config = try await CloudGatewayMacTunnelRuntime.secretService.resolveForStart(
                        reference: reference,
                        configId: configId,
                        grant: grant
                    )
                    let parsed: CloudGatewayParsedWireGuardConfig
                    do {
                        parsed = try CloudGatewayWireGuardConfigParser.parse(config.rawValue, named: "CloudGateway")
                    } catch {
                        attempt.fail(MacTunnelError.invalidConfiguration)
                        return
                    }
                    attempt.submitAdapterStart { callback in
                        runtime.start(config: parsed, completion: callback)
                    }
                } catch {
                    attempt.fail(MacTunnelError.authorizationFailed)
                }
            }
        }, completion: { error in
            completion.callback(error)
        })
    }

    // periphery:ignore - NetworkExtension invokes this provider callback
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = MacStopCompletion(callback: completionHandler)
        lifecycle.stop(operation: { [self] callback in
            runtime.stop(completion: callback)
        }, completion: {
            completion.callback()
        })
    }
}

private enum MacTunnelError: Error, LocalizedError {
    case authorizationFailed
    case invalidConfiguration
    case backendFailed

    var errorDescription: String? {
        switch self {
        case .authorizationFailed: "CloudGateway could not authorize this VPN start. Connect from the menu app."
        case .invalidConfiguration: "The CloudGateway VPN configuration is invalid."
        case .backendFailed: "CloudGateway could not start the VPN backend."
        }
    }
}

private struct MacStartCompletion: @unchecked Sendable {
    let callback: (Error?) -> Void
}

private struct MacStopCompletion: @unchecked Sendable {
    let callback: () -> Void
}

private final class MacWireGuardRuntime: @unchecked Sendable {
    private let adapter: WireGuardAdapter

    init(provider: NEPacketTunnelProvider) {
        // WireGuard log payloads contain private network details
        adapter = WireGuardAdapter(with: provider) { _, _ in }
    }

    func start(
        config: CloudGatewayParsedWireGuardConfig,
        completion: @escaping CloudGatewayMacTunnelLifecycle.StartCompletion
    ) {
        let configuration: TunnelConfiguration
        do {
            configuration = try config.wireGuardTunnelConfiguration()
        } catch {
            completion(MacTunnelError.invalidConfiguration)
            return
        }
        adapter.start(tunnelConfiguration: configuration) { error in
            completion(error == nil ? nil : MacTunnelError.backendFailed)
        }
    }

    func stop(completion: @escaping CloudGatewayMacTunnelLifecycle.StopCompletion) {
        adapter.stop { error in
            switch error {
            case nil, .some(.invalidState): completion()
            default: break
            }
        }
    }
}

private extension CloudGatewayParsedWireGuardConfig {
    func wireGuardTunnelConfiguration() throws -> TunnelConfiguration {
        TunnelConfiguration(
            name: name,
            interface: try interface.wireGuardInterfaceConfiguration(),
            peers: try peers.map { try $0.wireGuardPeerConfiguration() }
        )
    }
}

private extension CloudGatewayParsedWireGuardInterface {
    func wireGuardInterfaceConfiguration() throws -> InterfaceConfiguration {
        guard let privateKey = PrivateKey(base64Key: privateKey) else {
            throw CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidPrivateKey
        }
        var configuration = InterfaceConfiguration(privateKey: privateKey)
        configuration.listenPort = listenPort
        configuration.addresses = try addresses.map { address in
            guard let range = IPAddressRange(from: address) else {
                throw CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidAddress(address)
            }
            return range
        }
        configuration.dns = try dns.map { value in
            guard let server = DNSServer(from: value) else {
                throw CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidDNS(value)
            }
            return server
        }
        configuration.dnsSearch = dnsSearch
        configuration.mtu = mtu
        return configuration
    }
}

private extension CloudGatewayParsedWireGuardPeer {
    func wireGuardPeerConfiguration() throws -> PeerConfiguration {
        guard let publicKey = PublicKey(base64Key: publicKey) else {
            throw CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidPublicKey(self.publicKey)
        }
        var configuration = PeerConfiguration(publicKey: publicKey)
        if let preSharedKey {
            guard let key = PreSharedKey(base64Key: preSharedKey) else {
                throw CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidPreSharedKey
            }
            configuration.preSharedKey = key
        }
        configuration.allowedIPs = try allowedIPs.map { value in
            guard let range = IPAddressRange(from: value) else {
                throw CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidAllowedIP(value)
            }
            return range
        }
        if let endpoint {
            guard let value = Endpoint(from: endpoint) else {
                throw CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidEndpoint(endpoint)
            }
            configuration.endpoint = value
        }
        configuration.persistentKeepAlive = persistentKeepAlive
        return configuration
    }
}

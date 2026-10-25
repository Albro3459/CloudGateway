import Foundation

// periphery:ignore - macOS consumes routing modes through its separate app target
public enum CloudGatewayRoutingMode: String, Codable, Equatable, Sendable, CaseIterable {
    case full
    case mesh

    public var displayName: String {
        switch self {
        case .full: "Full"
        case .mesh: "Mesh only"
        }
    }

    public func configuration(from canonical: CloudGatewayParsedWireGuardConfig) -> CloudGatewayParsedWireGuardConfig {
        guard self == .mesh else { return canonical }
        var interface = canonical.interface
        interface.dns = []
        interface.dnsSearch = []
        let peers = canonical.peers.map { peer in
            var peer = peer
            peer.allowedIPs = ["10.0.0.0/16", "fd42:42:42::/48"]
            return peer
        }
        return CloudGatewayParsedWireGuardConfig(name: canonical.name, interface: interface, peers: peers)
    }
}

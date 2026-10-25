import Foundation
import Testing
@testable import CloudGatewayKit

@Test func routingModesKeepSerializedValuesAndDisplayNamesSeparate() throws {
    #expect(CloudGatewayRoutingMode.allCases == [.full, .mesh])
    #expect(CloudGatewayRoutingMode.full.displayName == "Full")
    #expect(CloudGatewayRoutingMode.mesh.displayName == "Mesh only")
    #expect(try JSONEncoder().encode(CloudGatewayRoutingMode.mesh) == Data("\"mesh\"".utf8))
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(CloudGatewayRoutingMode.self, from: Data("\"unsupported\"".utf8))
    }
}

@Test func fullRoutingPreservesCanonicalParsedConfiguration() throws {
    let canonical = try CloudGatewayWireGuardConfigParser.parse(routingModeConfig, named: "Example")
    #expect(CloudGatewayRoutingMode.full.configuration(from: canonical) == canonical)
}

@Test func meshRoutingChangesOnlyPeerPrefixesAndDNS() throws {
    let canonical = try CloudGatewayWireGuardConfigParser.parse(routingModeConfig, named: "Example")
    let runtime = CloudGatewayRoutingMode.mesh.configuration(from: canonical)
    #expect(runtime.name == "Example")
    #expect(runtime.interface.privateKey == canonical.interface.privateKey)
    #expect(runtime.interface.addresses == ["10.0.0.2/32", "fd42:42:42::2/128"])
    #expect(runtime.interface.listenPort == 51821)
    #expect(runtime.interface.mtu == 1380)
    #expect(runtime.interface.dns.isEmpty)
    #expect(runtime.interface.dnsSearch.isEmpty)
    #expect(runtime.peers.count == 1)
    #expect(runtime.peers[0].allowedIPs == ["10.0.0.0/16", "fd42:42:42::/48"])
    #expect(runtime.peers[0].publicKey == canonical.peers[0].publicKey)
    #expect(runtime.peers[0].preSharedKey == canonical.peers[0].preSharedKey)
    #expect(runtime.peers[0].endpoint == "example.com:51820")
    #expect(runtime.peers[0].persistentKeepAlive == 25)
    #expect(canonical.interface.dns == ["10.0.0.1"])
    #expect(canonical.interface.dnsSearch == ["example.internal"])
    #expect(canonical.peers[0].allowedIPs == ["0.0.0.0/0", "::/0"])
    #expect(CloudGatewayRoutingMode.mesh.configuration(from: runtime) == runtime)
}

private let routingModeConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32, fd42:42:42::2/128
ListenPort = 51821
DNS = 10.0.0.1, example.internal
MTU = 1380
[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
PresharedKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = example.com:51820
PersistentKeepalive = 25
"""

import Testing
@testable import CloudGatewayKit

private let privateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
private let publicKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
private let preSharedKey = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="

private func sampleConfig(
    interface: String = "",
    peer: String = ""
) -> String {
    """
    [Interface]
    PrivateKey = \(privateKey)
    Address = 10.0.0.2/32, fd42:42:42::2/128
    DNS = 10.0.0.1, fd42:42:42::1
    \(interface)

    [Peer]
    PublicKey = \(publicKey)
    Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820
    AllowedIPs = 0.0.0.0/0, ::/0
    PersistentKeepalive = 25
    \(peer)
    """
}

@Test func platformConfigurationKeepsInjectedValues() {
    let configuration = GatewayPlatformConfiguration(
        appGroupIdentifier: "group.com.gocloudlaunch.gateway",
        appBundleIdentifier: "com.gocloudlaunch.gateway",
        providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
        tunnelDisplayName: "CloudGateway"
    )

    #expect(configuration.appGroupIdentifier == "group.com.gocloudlaunch.gateway")
    #expect(configuration.appBundleIdentifier == "com.gocloudlaunch.gateway")
    #expect(configuration.providerBundleIdentifier == "com.gocloudlaunch.gateway.tunnel")
    #expect(configuration.tunnelDisplayName == "CloudGateway")
}

@Test func wireGuardConfigRejectsEmptyConfig() {
    #expect(throws: GatewayVPNError.missingWireGuardConfiguration) {
        try GatewayWireGuardConfig("  \n  ")
    }
}

@Test func wireGuardConfigRejectsIncompleteConfig() {
    #expect(throws: GatewayVPNError.invalidWireGuardConfiguration) {
        try GatewayWireGuardConfig("[Interface]\nPrivateKey = abc")
    }
}

@Test func providerConfigurationUsesStableKeys() throws {
    let platform = GatewayPlatformConfiguration(
        appGroupIdentifier: "group.com.gocloudlaunch.gateway",
        appBundleIdentifier: "com.gocloudlaunch.gateway",
        providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
        tunnelDisplayName: "CloudGateway"
    )
    let wireGuardConfig = try GatewayWireGuardConfig("""
    [Interface]
    PrivateKey = \(privateKey)

    [Peer]
    PublicKey = \(publicKey)
    """)
    let tunnel = GatewayTunnelConfiguration(
        identifier: "mvp0",
        displayName: "Phone",
        wireGuardConfig: wireGuardConfig
    )

    let providerConfiguration = GatewayProviderConfiguration(
        platform: platform,
        tunnel: tunnel
    )

    #expect(providerConfiguration.values[GatewayProviderConfigurationKey.appBundleIdentifier] == "com.gocloudlaunch.gateway")
    #expect(providerConfiguration.values[GatewayProviderConfigurationKey.appGroupIdentifier] == "group.com.gocloudlaunch.gateway")
    #expect(providerConfiguration.values[GatewayProviderConfigurationKey.tunnelIdentifier] == "mvp0")
    #expect(providerConfiguration.values[GatewayProviderConfigurationKey.wireGuardConfig] == wireGuardConfig.rawValue)
}

@Test func parserAcceptsCloudGatewayConfigShape() throws {
    let tunnel = try GatewayWireGuardConfigParser.parse(sampleConfig(), named: "CloudGateway")

    #expect(tunnel.name == "CloudGateway")
    #expect(tunnel.interface.privateKey == privateKey)
    #expect(tunnel.interface.addresses.count == 2)
    #expect(tunnel.interface.dns.count == 2)
    #expect(tunnel.peers.count == 1)
    #expect(tunnel.peers[0].publicKey == publicKey)
    #expect(tunnel.peers[0].allowedIPs.count == 2)
    #expect(tunnel.peers[0].endpoint == "wg.us-sanjose-1.gocloudlaunch.com:51820")
    #expect(tunnel.peers[0].persistentKeepAlive == 25)
}

@Test func parserIgnoresCommentsBlankLinesAndWhitespace() throws {
    let tunnel = try GatewayWireGuardConfigParser.parse("""

      # CloudGateway generated config
      [Interface]
      PrivateKey = \(privateKey) # inline comment
      DNS = 10.0.0.1

      [Peer]
      PublicKey = \(publicKey)
      AllowedIPs = 0.0.0.0/0

    """)

    #expect(tunnel.interface.dns.count == 1)
    #expect(tunnel.peers.count == 1)
}

@Test func parserMergesRepeatedListKeys() throws {
    let tunnel = try GatewayWireGuardConfigParser.parse("""
    [Interface]
    PrivateKey = \(privateKey)
    Address = 10.0.0.2/32
    Address = fd42:42:42::2/128
    DNS = 10.0.0.1
    DNS = fd42:42:42::1

    [Peer]
    PublicKey = \(publicKey)
    AllowedIPs = 0.0.0.0/0
    AllowedIPs = ::/0
    """)

    #expect(tunnel.interface.addresses.count == 2)
    #expect(tunnel.interface.dns.count == 2)
    #expect(tunnel.peers[0].allowedIPs.count == 2)
}

@Test func parserAcceptsOptionalPeerPreSharedKey() throws {
    let tunnel = try GatewayWireGuardConfigParser.parse(sampleConfig(peer: "PreSharedKey = \(preSharedKey)"))

    #expect(tunnel.peers[0].preSharedKey == preSharedKey)
}

@Test func parserRejectsMissingInterface() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.noInterface) {
        try GatewayWireGuardConfigParser.parse("""
        [Peer]
        PublicKey = \(publicKey)
        """)
    }
}

@Test func parserRejectsMissingPrivateKey() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.interfaceHasNoPrivateKey) {
        try GatewayWireGuardConfigParser.parse("""
        [Interface]
        Address = 10.0.0.2/32

        [Peer]
        PublicKey = \(publicKey)
        """)
    }
}

@Test func parserRejectsInvalidPrivateKey() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidPrivateKey("not-a-key")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig().replacingOccurrences(of: privateKey, with: "not-a-key"))
    }
}

@Test func parserRejectsMissingPeerPublicKey() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.peerHasNoPublicKey) {
        try GatewayWireGuardConfigParser.parse("""
        [Interface]
        PrivateKey = \(privateKey)

        [Peer]
        AllowedIPs = 0.0.0.0/0
        """)
    }
}

@Test func parserRejectsInvalidPeerPublicKey() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.peerHasInvalidPublicKey("not-a-key")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig().replacingOccurrences(of: publicKey, with: "not-a-key"))
    }
}

@Test func parserRejectsDuplicateScalarKeys() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.multipleEntriesForKey("PrivateKey")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig(interface: "PrivateKey = \(privateKey)"))
    }
}

@Test func parserRejectsUnknownInterfaceKeys() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.unrecognizedInterfaceKey("Table")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig(interface: "Table = off"))
    }
}

@Test func parserRejectsUnknownPeerKeys() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.unrecognizedPeerKey("Route")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig(peer: "Route = 10.0.0.0/24"))
    }
}

@Test func parserRejectsInvalidAddress() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidAddress("bad-address")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig(interface: "Address = bad-address"))
    }
}

@Test func parserRejectsInvalidDNS() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidDNS("@@@")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig(interface: "DNS = @@@"))
    }
}

@Test func parserRejectsInvalidEndpoint() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.peerHasInvalidEndpoint("missing-port")) {
        try GatewayWireGuardConfigParser.parse(
            sampleConfig().replacingOccurrences(
                of: "Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820",
                with: "Endpoint = missing-port"
            )
        )
    }
}

@Test func parserRejectsInvalidMTUListenPortAndKeepAlive() {
    #expect(throws: GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidMTU("999999")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig(interface: "MTU = 999999"))
    }
    #expect(throws: GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidListenPort("999999")) {
        try GatewayWireGuardConfigParser.parse(sampleConfig(interface: "ListenPort = 999999"))
    }
    #expect(throws: GatewayWireGuardConfigParser.ParseError.peerHasInvalidPersistentKeepAlive("999999")) {
        try GatewayWireGuardConfigParser.parse(
            sampleConfig().replacingOccurrences(
                of: "PersistentKeepalive = 25",
                with: "PersistentKeepalive = 999999"
            )
        )
    }
}

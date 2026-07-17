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
    let configuration = CloudGatewayPlatformConfiguration(
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
    #expect(throws: CloudGatewayVPNError.missingWireGuardConfiguration) {
        try CloudGatewayWireGuardConfig("  \n  ")
    }
}

@Test func wireGuardConfigRejectsIncompleteConfig() {
    #expect(throws: CloudGatewayVPNError.invalidWireGuardConfiguration) {
        try CloudGatewayWireGuardConfig("[Interface]\nPrivateKey = abc")
    }
}

@Test func providerConfigurationUsesStableKeys() throws {
    let platform = CloudGatewayPlatformConfiguration(
        appGroupIdentifier: "group.com.gocloudlaunch.gateway",
        appBundleIdentifier: "com.gocloudlaunch.gateway",
        providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
        tunnelDisplayName: "CloudGateway"
    )
    let wireGuardConfig = try CloudGatewayWireGuardConfig("""
    [Interface]
    PrivateKey = \(privateKey)

    [Peer]
    PublicKey = \(publicKey)
    """)
    let configHash = CloudGatewayConfigHash.make(for: wireGuardConfig)
    let secretReference = CloudGatewayConfigSecretReference.make(
        clientId: "mvp0",
        configHash: configHash,
        service: platform.configSecretServiceName
    )
    let tunnel = CloudGatewayTunnelConfiguration(
        identifier: "mvp0",
        displayName: "Phone",
        configHash: configHash,
        secretReference: secretReference
    )

    let providerConfiguration = CloudGatewayProviderConfiguration(
        platform: platform,
        tunnel: tunnel
    )

    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.appBundleIdentifier] == "com.gocloudlaunch.gateway")
    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.appGroupIdentifier] == "group.com.gocloudlaunch.gateway")
    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.tunnelIdentifier] == "mvp0")
    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.configHash] == configHash)
    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.keychainService] == platform.configSecretServiceName)
    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.keychainAccount] == secretReference.account)
    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.keychainAccessGroup] == nil)
}

@Test func providerConfigurationCarriesExplicitKeychainAccessGroup() throws {
    let platform = CloudGatewayPlatformConfiguration(
        appGroupIdentifier: "group.com.gocloudlaunch.gateway",
        appBundleIdentifier: "com.gocloudlaunch.gateway",
        providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
        tunnelDisplayName: "CloudGateway",
        keychainAccessGroupIdentifier: "TEAMID.com.gocloudlaunch.gateway"
    )
    let wireGuardConfig = try CloudGatewayWireGuardConfig("""
    [Interface]
    PrivateKey = \(privateKey)

    [Peer]
    PublicKey = \(publicKey)
    """)
    let configHash = CloudGatewayConfigHash.make(for: wireGuardConfig)
    let tunnel = CloudGatewayTunnelConfiguration(
        identifier: "mvp0",
        displayName: "Phone",
        configHash: configHash,
        secretReference: CloudGatewayConfigSecretReference.make(
            clientId: "mvp0",
            configHash: configHash,
            service: platform.configSecretServiceName
        )
    )

    let providerConfiguration = CloudGatewayProviderConfiguration(
        platform: platform,
        tunnel: tunnel
    )

    #expect(providerConfiguration.values[CloudGatewayProviderConfigurationKey.keychainAccessGroup] == "TEAMID.com.gocloudlaunch.gateway")
}

@Test func parserAcceptsCloudGatewayConfigShape() throws {
    let tunnel = try CloudGatewayWireGuardConfigParser.parse(sampleConfig(), named: "CloudGateway")

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
    let tunnel = try CloudGatewayWireGuardConfigParser.parse("""

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
    let tunnel = try CloudGatewayWireGuardConfigParser.parse("""
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

@Test func parserNormalizesPrefixLessAddressesToImplicitHostRoutes() throws {
    let tunnel = try CloudGatewayWireGuardConfigParser.parse("""
    [Interface]
    PrivateKey = \(privateKey)
    Address = 10.0.0.2, fd42:42:42::2
    DNS = 10.0.0.1

    [Peer]
    PublicKey = \(publicKey)
    AllowedIPs = 10.0.0.1, fd42:42:42::1/128
    """)

    // A bare IPv4 address becomes /32, a bare IPv6 address becomes /128, and an
    // already-prefixed value is preserved.
    #expect(tunnel.interface.addresses == ["10.0.0.2/32", "fd42:42:42::2/128"])
    #expect(tunnel.peers[0].allowedIPs == ["10.0.0.1/32", "fd42:42:42::1/128"])
}

@Test func parserErrorsOnTrailingPeerHeaderWithNoPublicKey() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.peerHasNoPublicKey) {
        try CloudGatewayWireGuardConfigParser.parse("""
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.0.0.2/32

        [Peer]
        """)
    }
}

@Test func parserErrorsOnTrailingInterfaceHeaderAfterValidInterface() {
    // A truncated config ending in a bare [Interface] header must error like
    // any other duplicate interface instead of being silently dropped.
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.multipleInterfaces) {
        try CloudGatewayWireGuardConfigParser.parse("""
        [Interface]
        PrivateKey = \(privateKey)

        [Peer]
        PublicKey = \(publicKey)

        [Interface]
        """)
    }
}

@Test func parserErrorsOnTrailingInterfaceHeaderWithNoBody() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.interfaceHasNoPrivateKey) {
        try CloudGatewayWireGuardConfigParser.parse("[Interface]")
    }
}

@Test func parserAcceptsOptionalPeerPreSharedKey() throws {
    let tunnel = try CloudGatewayWireGuardConfigParser.parse(sampleConfig(peer: "PreSharedKey = \(preSharedKey)"))

    #expect(tunnel.peers[0].preSharedKey == preSharedKey)
}

@Test func parserRejectsMissingInterface() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.noInterface) {
        try CloudGatewayWireGuardConfigParser.parse("""
        [Peer]
        PublicKey = \(publicKey)
        """)
    }
}

@Test func parserRejectsMissingPrivateKey() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.interfaceHasNoPrivateKey) {
        try CloudGatewayWireGuardConfigParser.parse("""
        [Interface]
        Address = 10.0.0.2/32

        [Peer]
        PublicKey = \(publicKey)
        """)
    }
}

@Test func parserRejectsInvalidPrivateKey() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidPrivateKey) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig().replacingOccurrences(of: privateKey, with: "not-a-key"))
    }
}

@Test func parserRejectsInvalidPreSharedKeyWithoutExposingKeyMaterial() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidPreSharedKey) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(peer: "PreSharedKey = not-a-key"))
    }
}

@Test func parserRedactsSensitiveKeyMaterialFromInvalidLineErrors() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.invalidLine("PrivateKey = <redacted>")) {
        try CloudGatewayWireGuardConfigParser.parse("PrivateKey = not-a-key")
    }
}

@Test func parserRejectsMissingPeerPublicKey() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.peerHasNoPublicKey) {
        try CloudGatewayWireGuardConfigParser.parse("""
        [Interface]
        PrivateKey = \(privateKey)

        [Peer]
        AllowedIPs = 0.0.0.0/0
        """)
    }
}

@Test func parserRejectsInvalidPeerPublicKey() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidPublicKey("not-a-key")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig().replacingOccurrences(of: publicKey, with: "not-a-key"))
    }
}

@Test func parserRejectsDuplicateScalarKeys() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.multipleEntriesForKey("PrivateKey")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(interface: "PrivateKey = \(privateKey)"))
    }
}

@Test func parserRejectsUnknownInterfaceKeys() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.unrecognizedInterfaceKey("Table")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(interface: "Table = off"))
    }
}

@Test func parserRejectsUnknownPeerKeys() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.unrecognizedPeerKey("Route")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(peer: "Route = 10.0.0.0/24"))
    }
}

@Test func parserRejectsInvalidAddress() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidAddress("bad-address")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(interface: "Address = bad-address"))
    }
}

@Test func parserRejectsInvalidDNS() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidDNS("@@@")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(interface: "DNS = @@@"))
    }
}

@Test func parserRejectsInvalidEndpoint() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidEndpoint("missing-port")) {
        try CloudGatewayWireGuardConfigParser.parse(
            sampleConfig().replacingOccurrences(
                of: "Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820",
                with: "Endpoint = missing-port"
            )
        )
    }
}

@Test func parserRejectsInvalidMTUListenPortAndKeepAlive() {
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidMTU("999999")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(interface: "MTU = 999999"))
    }
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.interfaceHasInvalidListenPort("999999")) {
        try CloudGatewayWireGuardConfigParser.parse(sampleConfig(interface: "ListenPort = 999999"))
    }
    #expect(throws: CloudGatewayWireGuardConfigParser.ParseError.peerHasInvalidPersistentKeepAlive("999999")) {
        try CloudGatewayWireGuardConfigParser.parse(
            sampleConfig().replacingOccurrences(
                of: "PersistentKeepalive = 25",
                with: "PersistentKeepalive = 999999"
            )
        )
    }
}

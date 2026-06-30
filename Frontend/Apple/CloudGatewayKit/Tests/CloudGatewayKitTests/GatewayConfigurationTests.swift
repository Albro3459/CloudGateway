import Testing
@testable import CloudGatewayKit

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
    PrivateKey = abc

    [Peer]
    PublicKey = def
    """)
    let tunnel = GatewayTunnelConfiguration(
        identifier: "mvp0",
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

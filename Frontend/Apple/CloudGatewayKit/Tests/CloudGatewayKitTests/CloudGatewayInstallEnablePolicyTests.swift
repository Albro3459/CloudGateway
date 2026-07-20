import Testing
@testable import CloudGatewayKit

@Test func installEnablesWhenNoTunnelIsActive() {
    #expect(CloudGatewayInstallEnablePolicy.shouldEnableOnInstall(
        installing: "client-1",
        activeTunnelIdentifiers: []
    ))
}

@Test func installDoesNotStealSlotFromADifferentActiveTunnel() {
    // Installing client-2 while client-1 is running must leave the new profile
    // disabled so the active VPN is not silently dropped.
    #expect(!CloudGatewayInstallEnablePolicy.shouldEnableOnInstall(
        installing: "client-2",
        activeTunnelIdentifiers: ["client-1"]
    ))
}

@Test func reinstallingTheActiveTunnelKeepsItEnabled() {
    // Updating the config of the tunnel that is currently running should keep it
    // enabled; only *other* active tunnels block the slot.
    #expect(CloudGatewayInstallEnablePolicy.shouldEnableOnInstall(
        installing: "client-1",
        activeTunnelIdentifiers: ["client-1"]
    ))
}

@Test func installStaysDisabledWhenAnotherTunnelIsActiveAlongsideTheTarget() {
    #expect(!CloudGatewayInstallEnablePolicy.shouldEnableOnInstall(
        installing: "client-1",
        activeTunnelIdentifiers: ["client-1", "client-2"]
    ))
}

import Testing
@testable import CloudGatewayKit

@Test func connectionActiveWhileTunnelMayRoute() {
    #expect(GatewayTunnelStatus.connecting.isConnectionActive)
    #expect(GatewayTunnelStatus.connected.isConnectionActive)
    #expect(GatewayTunnelStatus.reasserting.isConnectionActive)
    #expect(GatewayTunnelStatus.disconnecting.isConnectionActive)
}

@Test func connectionInactiveWhenFullyDown() {
    #expect(!GatewayTunnelStatus.disconnected.isConnectionActive)
    #expect(!GatewayTunnelStatus.invalid.isConnectionActive)
}

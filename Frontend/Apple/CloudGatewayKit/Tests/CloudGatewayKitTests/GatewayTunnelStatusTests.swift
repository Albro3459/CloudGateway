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

@Test func disconnectingDoesNotBlockDestructiveOperations() {
    #expect(!GatewayTunnelStatus.disconnecting.blocksDestructiveOperation)
    #expect(GatewayTunnelStatus.connecting.blocksDestructiveOperation)
    #expect(GatewayTunnelStatus.connected.blocksDestructiveOperation)
    #expect(GatewayTunnelStatus.reasserting.blocksDestructiveOperation)
}

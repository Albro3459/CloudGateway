import Testing
@testable import CloudGatewayKit

@Test func activeTunnelBlocksDestructiveOperations() {
    #expect(GatewayTunnelStatus.connecting.blocksDestructiveOperation)
    #expect(GatewayTunnelStatus.connected.blocksDestructiveOperation)
    #expect(GatewayTunnelStatus.reasserting.blocksDestructiveOperation)
}

// `.disconnecting` is optimistically treated as off (matches Control Center),
// so it must not block a destructive op even though teardown may be in flight.
@Test func downOrDisconnectingDoesNotBlockDestructiveOperations() {
    #expect(!GatewayTunnelStatus.disconnecting.blocksDestructiveOperation)
    #expect(!GatewayTunnelStatus.disconnected.blocksDestructiveOperation)
    #expect(!GatewayTunnelStatus.invalid.blocksDestructiveOperation)
}

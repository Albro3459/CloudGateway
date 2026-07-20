import Testing
@testable import CloudGatewayKit

@Test func activeTunnelBlocksDestructiveOperations() {
    #expect(CloudGatewayTunnelStatus.connecting.blocksDestructiveOperation)
    #expect(CloudGatewayTunnelStatus.connected.blocksDestructiveOperation)
    #expect(CloudGatewayTunnelStatus.reasserting.blocksDestructiveOperation)
}

// `.disconnecting` is optimistically treated as off (matches Control Center),
// so it must not block a destructive op even though teardown may be in flight.
@Test func downOrDisconnectingDoesNotBlockDestructiveOperations() {
    #expect(!CloudGatewayTunnelStatus.disconnecting.blocksDestructiveOperation)
    #expect(!CloudGatewayTunnelStatus.disconnected.blocksDestructiveOperation)
    #expect(!CloudGatewayTunnelStatus.invalid.blocksDestructiveOperation)
}

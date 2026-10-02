import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(NSError(domain: "CloudGatewayTunnel", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The packet tunnel is not configured yet."
        ]))
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

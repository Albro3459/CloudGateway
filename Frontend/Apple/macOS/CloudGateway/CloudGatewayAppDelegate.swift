import AppKit

@MainActor
final class CloudGatewayAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CloudGatewayMacAppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = CloudGatewayMacAppController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

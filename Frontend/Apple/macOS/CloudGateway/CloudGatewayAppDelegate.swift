import AppKit
import CloudGatewayMacIPC

@MainActor
final class CloudGatewayAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CloudGatewayMacAppController?
    private let identity: CloudGatewayMacBuildIdentity

    init(identity: CloudGatewayMacBuildIdentity) {
        self.identity = identity
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = CloudGatewayMacAppController(identity: identity)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

import AppKit

@MainActor
final class CloudGatewayAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CloudGatewayMacAppController?
    private var runtime: CloudGatewayMacControllerRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = CloudGatewayMacControllerRuntime()
        self.runtime = runtime
        controller = CloudGatewayMacAppController(controller: runtime.controller)
        runtime.controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        runtime?.shutdown()
    }
}

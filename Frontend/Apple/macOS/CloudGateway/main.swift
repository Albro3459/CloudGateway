import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = CloudGatewayAppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
        application.run()
    }
}

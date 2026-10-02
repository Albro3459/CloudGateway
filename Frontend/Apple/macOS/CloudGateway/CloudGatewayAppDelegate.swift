import AppKit

final class CloudGatewayAppDelegate: NSObject, NSApplicationDelegate {
    // periphery:ignore - NSStatusBar requires the app to retain its menu item
    private var statusItem: NSStatusItem?
    private let activation = CloudGatewayExtensionActivationCoordinator()
    private let setupStatus = NSMenuItem(title: "VPN setup required", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "CloudGateway")
        let menu = NSMenu()
        menu.addItem(setupStatus)
        let setup = NSMenuItem(title: "Set Up VPN…", action: #selector(setUp), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CloudGateway", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        activation.onStatusChange = { [weak self, weak setup] state in
            self?.setupStatus.title = state.title
            setup?.isEnabled = state.canActivate
        }
        activation.refreshReadiness()
    }

    @objc private func setUp() {
        activation.activate()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

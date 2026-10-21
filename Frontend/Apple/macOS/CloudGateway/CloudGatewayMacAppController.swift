import AppKit
import CloudGatewayMacCore
import ServiceManagement

@MainActor
final class CloudGatewayMacAppController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let activation = CloudGatewayExtensionActivationCoordinator()
    private let controller: CloudGatewayMacController
    private let dashboard = URL(string: "https://gocloudlaunch.com")!
    private var browserState = CloudGatewayMacBrowserAuthState.signedOut
    private var frontendErrorMessage: String?
    private var dialogTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(controller: CloudGatewayMacController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        activation.onStatusChange = { [weak self] state in
            self?.controller.setSetupState(state)
        }
        controller.onChange = { [weak self] in self?.controllerChanged() }
        render()
        activation.refreshReadiness()
    }

    private var snapshot: CloudGatewayMacControllerSnapshot {
        controller.snapshot(setupState: activation.state)
    }

    private func controllerChanged() {
        guard !isShuttingDown else { return }
        let state = snapshot
        if state.browserState != browserState {
            browserState = state.browserState
            if case .waitingForApproval(_, let url) = browserState {
                NSWorkspace.shared.open(url)
            }
        }
        if state.accountId == nil { dialogTask?.cancel() }
        render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.menuWillOpen()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        dialogTask?.cancel()
        dialogTask = nil
        controller.onChange = nil
        activation.onStatusChange = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func render() {
        guard !isShuttingDown else { return }
        let state = snapshot
        statusItem.button?.image = CloudGatewayStatusGlyph.image(isActive: state.hasActiveTunnel)
        menu.removeAllItems()
        let status = add(state.statusTitle, #selector(toggleVPN), enabled: state.canToggleVPN)
        if activation.state == .awaitingApproval, state.statusTitle == activation.state.title {
            status.action = #selector(openLoginItemsSettings)
            status.isEnabled = true
        }
        status.state = state.accountId != nil && state.hasActiveTunnel ? .on : .off
        if state.canToggleVPN {
            status.toolTip = state.canTurnOff ? "Disconnect VPN" : "Connect using the last-used client"
        }
        if let message = state.errorMessage ?? frontendErrorMessage { add(message) }
        if state.accountId == nil {
            switch state.browserState {
            case .requestingCode: add("Requesting sign-in code…"); add("Cancel Sign In", #selector(cancelSignIn))
            case .waitingForApproval(let code, _):
                add("Browser sign-in code: \(code)")
                add("Open Browser", #selector(openSignInBrowser))
                add("Cancel Sign In", #selector(cancelSignIn))
            case .exchangingToken: add("Completing sign-in…"); add("Cancel Sign In", #selector(cancelSignIn))
            default:
                add(!state.isRestoringSession ? "Sign In…" : "Restoring session…", #selector(signIn),
                    enabled: !state.isRestoringSession && !state.isAuthSettling)
                if state.hasRetainedSession { add("Refresh Session", #selector(refresh)) }
                if state.canSignOut { add("Sign Out", #selector(signOut)) }
                if state.isAuthSettling {
                    add("Sign-in cleanup is still pending")
                    add("Retry Sign-in Cleanup", #selector(signOut))
                }
            }
        } else {
            if state.hasUnlistedActiveProfile {
                add("Connecting replaces the current CloudGateway VPN")
            }
            for group in state.groups {
                let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for row in group.rows {
                    let title = row.identifier == state.lastSelectedIdentifier ? "\(row.title) (Last used)" : row.title
                    let clientItem = NSMenuItem(title: title, action: #selector(selectClient(_:)), keyEquivalent: "")
                    clientItem.target = self
                    clientItem.representedObject = row.identifier
                    clientItem.isEnabled = row.isEnabled
                    clientItem.state = row.status == .connected || row.status == .reasserting ? .on : .off
                    submenu.addItem(clientItem)
                }
                item.submenu = submenu
                menu.addItem(item)
            }
            add("Add Client…", #selector(addClient), enabled: state.canCreateClient && dialogTask == nil)
            add("Refresh", #selector(refresh), enabled: state.canRefresh && !state.inventoryInFlight)
            add("Sign Out", #selector(signOut), enabled: state.canSignOut)
        }
        if activation.state != .ready {
            if state.statusTitle != activation.state.title {
                add(activation.state.title,
                    activation.state == .awaitingApproval ? #selector(openLoginItemsSettings) : nil)
            }
            if activation.state.canActivate {
                add(activation.state == .updateRequired ? "Update VPN Extension…" : "Set Up VPN…",
                    #selector(setUp))
            }
        }
        menu.addItem(.separator())
        add("Open Website", #selector(openWebsite))
        let loginStatus = SMAppService.mainApp.status
        let login = add(loginStatus == .requiresApproval ? "Launch at Login: Approval Required…" : "Launch at Login",
                        #selector(toggleLaunchAtLogin))
        login.state = loginStatus == .enabled ? .on : .off
        add("Quit CloudGateway", #selector(quitApp), keyEquivalent: "q")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true,
                     keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil && enabled
        menu.addItem(item)
        return item
    }

    @objc private func selectClient(_ item: NSMenuItem) {
        guard let identifier = item.representedObject as? String else { return }
        frontendErrorMessage = nil
        controller.connectClient(identifier: identifier)
    }

    @objc private func toggleVPN() {
        let state = snapshot
        guard state.canToggleVPN else { return }
        frontendErrorMessage = nil
        if state.canTurnOff { controller.turnOff() }
        else if let identifier = state.reconnectIdentifier { controller.connectClient(identifier: identifier) }
    }

    @objc private func addClient() {
        guard dialogTask == nil, let context = controller.clientCreationContext() else { return }
        frontendErrorMessage = nil
        dialogTask = Task { [weak self] in
            guard let self else { return }
            defer { dialogTask = nil; render() }
            do {
                let dialog = CloudGatewayMacClientCreationDialog()
                guard let request = try await dialog.prompt(loadRegions: { [controller] in
                    try await controller.loadCreateRegions(context: context)
                }) else { return }
                try Task.checkCancellation()
                if !controller.createClient(regionId: request.regionId, clientName: request.clientName, context: context) {
                    frontendErrorMessage = "Account or client list changed. Open Add Client again"
                }
            } catch is CancellationError {
            } catch {
                frontendErrorMessage = "Unable to load available regions. Refresh and try again"
            }
        }
        render()
    }

    @objc private func signIn() {
        frontendErrorMessage = nil
        controller.signIn()
    }
    @objc private func cancelSignIn() { controller.cancelSignIn() }
    @objc private func openSignInBrowser() {
        guard case .waitingForApproval(_, let url) = snapshot.browserState else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func setUp() { activation.activate() }
    @objc private func openWebsite() { NSWorkspace.shared.open(dashboard) }
    @objc private func quitApp() { quit() }

    @objc private func signOut() {
        frontendErrorMessage = nil
        dialogTask?.cancel()
        controller.signOut()
    }

    @objc private func refresh() {
        frontendErrorMessage = nil
        controller.refresh()
        activation.refreshReadiness()
    }

    @objc private func toggleLaunchAtLogin() {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch SMAppService.mainApp.status {
                case .enabled: try await SMAppService.mainApp.unregister()
                case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
                case .notRegistered, .notFound: try SMAppService.mainApp.register()
                @unknown default: frontendErrorMessage = "Launch at Login needs attention in System Settings"
                }
            } catch { frontendErrorMessage = "Unable to change Launch at Login. Check System Settings" }
            render()
        }
    }
}

import AppKit
import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Darwin
import ServiceManagement

@MainActor
final class CloudGatewayMacAppController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let client: CloudGatewayMacMenuClient
    private let identity: CloudGatewayMacBuildIdentity
    private let dashboard = URL(string: "https://gocloudlaunch.com")!
    private var browserState = CloudGatewayMacControllerView.BrowserState.signedOut
    private var loginAttemptId: UUID?
    private var frontendErrorMessage: String?
    private var dialogTask: Task<Void, Never>?
    private var reviewDialog: CloudGatewayMacClientReviewDialog?
    private var actionTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private weak var statusMenuItem: NSMenuItem?
    private weak var updateMenuItem: NSMenuItem?
    private var isMenuOpen = false
    private var isShuttingDown = false
    private var isRelaunching = false
    private var attemptedAutomaticExtensionUpdate = false

    init(identity: CloudGatewayMacBuildIdentity) {
        self.identity = identity
        client = CloudGatewayMacMenuClient(identity: identity)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        client.onChange = { [weak self] in self?.controllerChanged() }
        client.onReplacement = { [weak self] identity in self?.openReplacement(identity) }
        render()
        client.start()
    }

    private var snapshot: CloudGatewayMacControllerView {
        client.presentation
    }

    private func controllerChanged() {
        guard !isShuttingDown else { return }
        let state = snapshot
        if client.isSnapshotFresh, state.browserState != browserState {
            browserState = state.browserState
            if state.login?.attemptId == loginAttemptId, state.login?.origin == .menu,
               case .waitingForApproval(_, let url) = browserState {
                NSWorkspace.shared.open(url)
            }
        }
        if state.accountId == nil { dialogTask?.cancel() }
        reviewDialog?.update(snapshot: state, isSnapshotFresh: client.isSnapshotFresh,
                             isCurrentBuild: client.isCurrentBuild && !isRelaunching)
        if client.isSnapshotFresh, state.setupState == .updateRequired, state.canUpdateExtension,
           !attemptedAutomaticExtensionUpdate, actionTask == nil {
            updateExtension(isUserInitiated: false)
        }
        render()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        menuTask?.cancel()
        menuTask = Task { [weak self] in
            guard let self else { return }
            do { _ = try await client.userRequest(.menuWillOpen) }
            catch is CancellationError { }
            catch { render() }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        // Rebuild after AppKit finishes closing and dispatching the selected action
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        reviewDialog?.update(snapshot: snapshot, isSnapshotFresh: false, isCurrentBuild: false)
        dialogTask?.cancel()
        dialogTask = nil
        actionTask?.cancel()
        actionTask = nil
        menuTask?.cancel()
        menuTask = nil
        client.shutdown()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func openReplacement(_ identity: CloudGatewayMacBuildIdentity) {
        guard !isRelaunching else { return }
        let installed = URL(fileURLWithPath: "/Applications/CloudGateway.app")
        guard let verified = try? CloudGatewayMacSignedBundle.installed(
            at: installed, teamIdentifier: "CRQWDQ7QQR", bundleIdentifier: "com.gocloudlaunch.gateway.macos"
        ), verified == identity else { return }
        isRelaunching = true
        dialogTask?.cancel()
        reviewDialog?.update(snapshot: snapshot, isSnapshotFresh: false, isCurrentBuild: false)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { [weak self] application, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if application != nil { quit() }
                else { isRelaunching = false }
            }
        }
    }

    private var setupState: CloudGatewayMacSetupState {
        switch snapshot.setupState {
        case .required: .required
        case .updateRequired: .updateRequired
        case .invalidBundle: .invalidBundle
        case .activating: .activating
        case .awaitingApproval: .awaitingApproval
        case .awaitingRestart: .awaitingRestart
        case .checkingConnection: .checkingConnection
        case .ready: .ready
        case .failed(let code): .failed(code: code)
        case .unavailable: .unavailable
        }
    }

    private var updateTitle: String? {
        guard let update = client.managedUpdate else { return nil }
        switch update.phase {
        case .prepared: return "Preparing VPN extension update…"
        case .stopping: return "Stopping VPN for extension update…"
        case .activating: return "Updating VPN extension…"
        case .approvalRequired: return "Approve CloudGateway in System Settings → Login Items & Extensions"
        case .restartRequired: return "Restart your Mac to finish the VPN extension update"
        case .checkingReadiness: return "Checking updated VPN extension…"
        case .reconnecting: return "Restoring VPN after extension update…"
        case .completed:
            return update.warning == .reconnectSuppressed ? "VPN extension updated. Reconnect was cancelled" : nil
        case .failed: return "VPN extension update failed"
        case .superseded: return "VPN extension update superseded by the installed app"
        }
    }

    private func render() {
        guard !isShuttingDown else { return }
        let state = snapshot
        statusItem.button?.image = CloudGatewayStatusGlyph.image(isActive: state.hasActiveTunnel)
        if isMenuOpen { updateOpenMenu(state); return }
        menu.removeAllItems()
        let status = add(state.statusTitle, #selector(toggleVPN),
                         enabled: state.canToggleVPN && (state.canTurnOff || setupState == .ready))
        statusMenuItem = status
        if setupState == .awaitingApproval, state.statusTitle == setupState.title {
            status.action = #selector(openLoginItemsSettings)
            status.isEnabled = true
        }
        status.state = state.hasActiveTunnel ? .on : .off
        if state.canToggleVPN {
            status.toolTip = state.canTurnOff ? "Disconnect VPN" : "Connect using the last-used client"
        }
        if let message = frontendErrorMessage ?? client.errorMessage ?? state.errorMessage { add(message) }
        updateMenuItem = nil
        if let title = updateTitle, title != state.statusTitle {
            updateMenuItem = add(title, client.managedUpdate?.phase == .approvalRequired ? #selector(openLoginItemsSettings) : nil)
        }
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
                    clientItem.isEnabled = row.isEnabled && actionTask == nil && setupState == .ready
                    clientItem.state = row.status == .connected || row.status == .reasserting ? .on : .off
                    submenu.addItem(clientItem)
                }
                item.submenu = submenu
                menu.addItem(item)
            }
            add("Add Client…", #selector(addClient), enabled: state.canCreateClient && dialogTask == nil && actionTask == nil)
            add("Review client…", #selector(reviewClient),
                enabled: client.isSnapshotFresh && state.canReviewClient && dialogTask == nil && actionTask == nil)
            add(state.inventoryInFlight ? "Refreshing clients…" : "Refresh", #selector(refresh),
                enabled: state.canRefresh && !state.inventoryInFlight && actionTask == nil)
            add("Sign Out", #selector(signOut), enabled: state.canSignOut && actionTask == nil)
        }
        if setupState != .ready {
            let setupTitle = setupState == .updateRequired && state.hasActiveTunnel
                ? "Disconnect VPN to update" : setupState.title
            if state.statusTitle != setupTitle, updateTitle != setupTitle {
                add(setupTitle,
                    setupState == .awaitingApproval ? #selector(openLoginItemsSettings) : nil)
            }
            if setupState.canActivate {
                add(setupState == .updateRequired ? "Update VPN Extension…" : "Set Up VPN…",
                    #selector(setUp), enabled: state.canUpdateExtension && client.isCurrentBuild)
            }
        }
        menu.addItem(.separator())
        add("Install Command Line Tool…", #selector(installCommandLineTool))
        add("Open Website", #selector(openWebsite))
        let loginStatus = SMAppService.mainApp.status
        let login = add(loginStatus == .requiresApproval ? "Launch at Login: Approval Required…" : "Launch at Login",
                        #selector(toggleLaunchAtLogin))
        login.state = loginStatus == .enabled ? .on : .off
        add("Quit CloudGateway", #selector(quitApp), keyEquivalent: "q")
    }

    private func updateOpenMenu(_ state: CloudGatewayMacControllerView) {
        let current = client.isSnapshotFresh && client.isCurrentBuild
        CloudGatewayMacMenuUpdates.updateClients(in: menu, from: state, isSnapshotFresh: current,
            canConnect: actionTask == nil && setupState == .ready)
        for item in menu.items {
            switch item.action {
            case #selector(toggleVPN):
                item.isEnabled = state.canToggleVPN && (state.canTurnOff || setupState == .ready)
                    && (client.isCurrentBuild || state.canTurnOff) && actionTask == nil
            case #selector(signIn):
                item.isEnabled = current && state.accountId == nil && !state.isRestoringSession && !state.isAuthSettling
            case #selector(cancelSignIn), #selector(openSignInBrowser):
                item.isEnabled = current && state.login != nil && state.accountId == nil
            case #selector(signOut): item.isEnabled = current && state.canSignOut && actionTask == nil
            case #selector(refresh):
                item.isEnabled = current && (state.canRefresh || state.hasRetainedSession)
                    && !state.inventoryInFlight && actionTask == nil
            case #selector(addClient):
                item.isEnabled = current && state.canCreateClient && dialogTask == nil && actionTask == nil
            case #selector(reviewClient):
                item.isEnabled = current && state.canReviewClient && dialogTask == nil && actionTask == nil
            case #selector(setUp):
                item.isEnabled = current && state.canUpdateExtension && setupState.canActivate && actionTask == nil
            default: break
            }
        }
        if let updateMenuItem {
            if current { updateMenuItem.title = updateTitle ?? "VPN extension update finished" }
            updateMenuItem.action = current && client.managedUpdate?.phase == .approvalRequired
                ? #selector(openLoginItemsSettings) : nil
            updateMenuItem.isEnabled = updateMenuItem.action != nil
        }
        if current, let statusMenuItem, statusMenuItem.action == #selector(toggleVPN) {
            statusMenuItem.title = state.statusTitle
            statusMenuItem.state = state.hasActiveTunnel ? .on : .off
        }
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true,
                     keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil && enabled
        let controllerActions = [#selector(toggleVPN), #selector(signIn), #selector(cancelSignIn),
                                 #selector(signOut), #selector(refresh), #selector(addClient), #selector(reviewClient), #selector(setUp)]
        if let action, controllerActions.contains(action) {
            item.isEnabled = item.isEnabled && (client.isCurrentBuild || (action == #selector(toggleVPN) && snapshot.canTurnOff))
                && (action == #selector(signIn) || action == #selector(cancelSignIn) || actionTask == nil)
        }
        menu.addItem(item)
        return item
    }

    @objc private func selectClient(_ item: NSMenuItem) {
        guard let identifier = item.representedObject as? String else { return }
        send(.connect, identifier: identifier)
    }

    @objc private func toggleVPN() {
        let state = snapshot
        guard state.canToggleVPN else { return }
        if state.canTurnOff { send(.turnOff) }
        else if setupState == .ready, let identifier = state.reconnectIdentifier {
            send(.connect, identifier: identifier)
        }
    }

    @objc private func addClient() {
        guard dialogTask == nil, snapshot.canCreateClient else { return }
        frontendErrorMessage = nil
        dialogTask = Task { [weak self] in
            guard let self else { return }
            defer { dialogTask = nil; render() }
            do {
                var contextId: UUID?
                let dialog = CloudGatewayMacClientCreationDialog()
                guard let request = try await dialog.prompt(loadRegions: { [client] in
                    let reply = try await client.userRequest(.prepareClient)
                    guard let creation = reply.creation else { throw CloudGatewayMacControllerFailure.invalidRequest }
                    contextId = creation.id
                    return creation.regions
                }), let contextId else { return }
                try Task.checkCancellation()
                let reply = try await client.userRequest(.createClient, regionId: request.regionId,
                                                     clientName: request.clientName, contextId: contextId)
                if reply.accepted != true {
                    frontendErrorMessage = "Account or client list changed. Open Add Client again"
                }
            } catch is CancellationError {
            } catch {
                frontendErrorMessage = client.message(for: error)
            }
        }
        render()
    }

    @objc private func reviewClient() {
        let state = snapshot
        guard dialogTask == nil, actionTask == nil, !isShuttingDown, client.isCurrentBuild,
              client.isSnapshotFresh, state.canReviewClient, let accountId = state.accountId else { return }
        frontendErrorMessage = nil
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { reviewDialog = nil; actionTask = nil; render() }
            do {
                guard !isShuttingDown, !isRelaunching, client.isCurrentBuild, client.isSnapshotFresh,
                      snapshot.accountId == accountId, snapshot.canReviewClient else { return }
                let dialog = CloudGatewayMacClientReviewDialog(snapshot: snapshot)
                reviewDialog = dialog
                guard let identifier = try await dialog.prompt() else { return }
                reviewDialog = nil
                try Task.checkCancellation()
                guard !isShuttingDown, !isRelaunching, client.isCurrentBuild, client.isSnapshotFresh,
                      snapshot.accountId == accountId, snapshot.canReviewClient,
                      snapshot.groups.flatMap(\.rows).contains(where: {
                          $0.identifier == identifier && $0.removalPermission == .inactive
                      }) else { return }
                let outcome = try await client.removeReviewedClient(identifier: identifier, accountId: accountId)
                frontendErrorMessage = client.message(forRemoval: outcome)
            } catch is CancellationError {
            } catch {
                frontendErrorMessage = client.message(for: error)
            }
        }
        render()
    }

    private func send(_ action: CloudGatewayMacControllerRequest.Action, identifier: String? = nil) {
        guard actionTask == nil, !isShuttingDown else { return }
        frontendErrorMessage = nil
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { actionTask = nil; render() }
            let id = UUID()
            do { _ = try await client.userRequest(action, id: id, identifier: identifier) }
            catch is CancellationError { }
            catch {
                frontendErrorMessage = client.message(for: error)
                if error as? CloudGatewayMacControllerFailure == .outcomeUnknown { await resolveUncertainOperation(id) }
            }
        }
        render()
    }

    // Keep actions disabled while the same operation resolves, so the user cannot replay it
    private func resolveUncertainOperation(_ id: UUID) async {
        render()
        guard let operation = try? await client.awaitOutcome(of: id, timeout: .seconds(30)).operation else { return }
        switch operation.state {
        case .completed: frontendErrorMessage = nil
        case .failed: frontendErrorMessage = client.message(for: operation.failure ?? CloudGatewayMacControllerFailure.commandFailed)
        default: break
        }
    }

    @objc private func signIn() {
        guard client.isCurrentBuild, !isShuttingDown else { return }
        let id = UUID()
        loginAttemptId = id
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await client.userRequest(.beginLogin, id: id, loginOrigin: .menu) }
            catch { frontendErrorMessage = client.message(for: error); render() }
        }
    }
    @objc private func cancelSignIn() {
        guard let id = snapshot.login?.attemptId else { return }
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await client.userRequest(.cancelLogin, contextId: id) }
            catch { frontendErrorMessage = client.message(for: error); render() }
        }
    }
    @objc private func openSignInBrowser() {
        guard case .waitingForApproval(_, let url) = snapshot.browserState else { return }
        recordUserActivity()
        NSWorkspace.shared.open(url)
    }
    @objc private func openLoginItemsSettings() {
        recordUserActivity()
        SMAppService.openSystemSettingsLoginItems()
    }
    @objc private func setUp() {
        updateExtension(isUserInitiated: true)
    }

    private func updateExtension(isUserInitiated: Bool) {
        guard actionTask == nil, !isShuttingDown, client.snapshot != nil, client.isCurrentBuild,
              setupState.canActivate, snapshot.canUpdateExtension else { return }
        frontendErrorMessage = nil
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { actionTask = nil; render() }
            let id = UUID()
            do {
                let action: CloudGatewayMacControllerRequest.Action = setupState == .required
                    ? .prepareExtensionUpdate : .update
                let reply: CloudGatewayMacControllerReply
                if isUserInitiated {
                    reply = try await client.userRequest(action, id: id, allowDisconnect: action == .update ? false : nil)
                } else {
                    reply = try await client.request(action, id: id, allowDisconnect: action == .update ? false : nil)
                }
                guard reply.accepted == true else {
                    frontendErrorMessage = "VPN extension update is waiting for all tunnels to disconnect"
                    return
                }
                attemptedAutomaticExtensionUpdate = true
            } catch is CancellationError {
            } catch {
                frontendErrorMessage = client.message(for: error)
                if error as? CloudGatewayMacControllerFailure == .outcomeUnknown { await resolveUncertainOperation(id) }
            }
        }
        render()
    }

    private func recordUserActivity() {
        Task { [weak self] in
            guard let self, !isShuttingDown else { return }
            _ = try? await client.userRequest(.userActivity)
        }
    }

    @objc private func openWebsite() {
        recordUserActivity()
        NSWorkspace.shared.open(dashboard)
    }
    @objc private func quitApp() { quit() }

    @objc private func installCommandLineTool() {
        recordUserActivity()
        let installer = CloudGatewayMacCLIInstaller(homeURL: FileManager.default.homeDirectoryForCurrentUser)
        let explicitPath = installer.executableURL.path
        let explicitCommand = "'" + explicitPath.replacingOccurrences(of: "'", with: "'\\''") + "' status"
        let confirm = NSAlert()
        confirm.messageText = "Install Command Line Tool"
        confirm.informativeText = "Create \(explicitPath) as a link to the signed app in /Applications. No administrator access is needed. Shell configuration is a separate step."
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            let installResult = try installer.install(runningBundleURL: Bundle.main.bundleURL) { [identity] in
                let installed = try CloudGatewayMacSignedBundle.installed(
                    at: URL(fileURLWithPath: "/Applications/CloudGateway.app"),
                    teamIdentifier: "CRQWDQ7QQR", bundleIdentifier: "com.gocloudlaunch.gateway.macos"
                )
                guard installed == identity else { throw CloudGatewayMacCLIInstallError.invalidInstalledApp }
            }
            let path = NSAlert()
            path.messageText = installResult == .installed ? "Command Line Tool Installed" : "Command Line Tool Already Installed"
            path.informativeText = "Run \(explicitCommand), including over noninteractive SSH.\n\nOptionally append export PATH=\"$HOME/.local/bin:$PATH\" to an ordinary ~/.zprofile for new zsh login shells. Custom shell configuration needs a manual edit. This does not set PATH for every SSH session."
            path.addButton(withTitle: "Done")
            path.addButton(withTitle: "Add to Zsh PATH…")
            guard path.runModal() == .alertSecondButtonReturn else { return }
            let environment = ProcessInfo.processInfo.environment
            let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
            let pathResult = try installer.addToZshPath(shell: shell, environment: environment)
            let notice = NSAlert()
            switch pathResult {
            case .added:
                notice.messageText = "Zsh PATH Updated"
                notice.informativeText = "Open a new zsh login shell to use cloudgateway."
            case .alreadyOnPath:
                notice.messageText = "Command Line Tool Is on PATH"
                notice.informativeText = "Your local bin directory is already on this app's PATH. No shell files were changed. Terminal and SSH can use a different PATH."
            case .alreadyConfigured(let file):
                notice.messageText = "Existing Zsh PATH Setup Found"
                notice.informativeText = "Found your local bin directory in ~/\(file). No shell files were changed. Open a new zsh shell and run which cloudgateway to check."
            }
            notice.informativeText += "\n\nFor noninteractive SSH, use \(explicitCommand)."
            notice.runModal()
        } catch {
            let notice = NSAlert()
            notice.messageText = "Command Line Tool Setup"
            let message: String
            switch error as? CloudGatewayMacCLIInstallError {
            case .installationRequired:
                message = "Open CloudGateway from /Applications/CloudGateway.app and try again. Mounted disk images, translocated apps, and development locations cannot be permanent targets."
            case .invalidInstalledApp:
                message = "The installed app is missing, changed, or could not be verified. Open the current signed app in /Applications and try again."
            case .conflictingFile:
                message = "A file or directory already exists at \(explicitPath). Move it yourself if it is no longer needed, then try again."
            case .conflictingLink:
                message = "Another symbolic link exists at \(explicitPath). Review and move it yourself before trying again."
            case .brokenLink:
                message = "A broken symbolic link exists at \(explicitPath). Restore its target or move the link yourself before trying again."
            case .manualShellConfiguration, .unsafeStartupFile:
                message = "Shell configuration needs a manual edit. Review your shell's startup files and add ~/.local/bin to PATH if needed. Automatic editing supports /bin/zsh with a ~/.zprofile containing only comments and simple exports, no ZDOTDIR or ~/.zshenv, and no existing PATH customizations. Symlinked or shared startup files are left alone."
            case .unsafeDirectory:
                message = "The home, ~/.local, or ~/.local/bin directory is linked, shared, or not owned by this user. Review its ownership and permissions before trying again."
            case .filesystemFailure, nil:
                message = "The filesystem change could not be completed. Check permissions and free space, then inspect the installation before retrying."
            }
            notice.informativeText = message + "\n\nExplicit command path for noninteractive SSH: \(explicitCommand)"
            notice.runModal()
        }
    }

    @objc private func signOut() {
        dialogTask?.cancel()
        send(.signOut)
    }

    @objc private func refresh() {
        guard actionTask == nil, !isShuttingDown else { return }
        send(.refresh)
    }

    @objc private func toggleLaunchAtLogin() {
        recordUserActivity()
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

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
    private let activation = CloudGatewayExtensionActivationCoordinator()
    private let client: CloudGatewayMacMenuClient
    private let identity: CloudGatewayMacBuildIdentity
    private let dashboard = URL(string: "https://gocloudlaunch.com")!
    private var browserState = CloudGatewayMacControllerView.BrowserState.signedOut
    private var loginAttemptId: UUID?
    private var frontendErrorMessage: String?
    private var dialogTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var activationReportTask: Task<Void, Never>?
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
        activation.onStatusChange = { [weak self] in self?.render() }
        activation.isCurrentBuild = { [weak self] in self?.isInstalledBuildCurrent() == true }
        activation.onAttemptStatusChange = { [weak self] attemptId, state in
            self?.reportActivation(state, attemptId: attemptId)
        }
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
        activation.updateReadiness(state.setupState)
        if state.setupState == .updateRequired, state.canUpdateExtension,
           !attemptedAutomaticExtensionUpdate, actionTask == nil {
            attemptedAutomaticExtensionUpdate = true
            setUp()
        }
        render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        send(.menuWillOpen, clearsError: false)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        dialogTask?.cancel()
        dialogTask = nil
        actionTask?.cancel()
        actionTask = nil
        activationReportTask?.cancel()
        activationReportTask = nil
        client.shutdown()
        activation.onStatusChange = nil
        activation.onAttemptStatusChange = nil
        activation.isCurrentBuild = nil
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

    private func isInstalledBuildCurrent() -> Bool {
        guard client.isCurrentBuild, let installed = try? CloudGatewayMacSignedBundle.installed(
            at: URL(fileURLWithPath: "/Applications/CloudGateway.app"),
            teamIdentifier: "CRQWDQ7QQR", bundleIdentifier: "com.gocloudlaunch.gateway.macos"
        ) else { return false }
        return installed == identity
    }

    private func render() {
        guard !isShuttingDown else { return }
        let state = snapshot
        statusItem.button?.image = CloudGatewayStatusGlyph.image(isActive: state.hasActiveTunnel)
        menu.removeAllItems()
        let status = add(state.statusTitle, #selector(toggleVPN),
                         enabled: state.canToggleVPN && (state.canTurnOff || activation.state == .ready))
        if activation.state == .awaitingApproval, state.statusTitle == activation.state.title {
            status.action = #selector(openLoginItemsSettings)
            status.isEnabled = true
        }
        status.state = state.hasActiveTunnel ? .on : .off
        if state.canToggleVPN {
            status.toolTip = state.canTurnOff ? "Disconnect VPN" : "Connect using the last-used client"
        }
        if let message = frontendErrorMessage ?? client.errorMessage ?? state.errorMessage { add(message) }
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
                    clientItem.isEnabled = row.isEnabled && actionTask == nil && activation.state == .ready
                    clientItem.state = row.status == .connected || row.status == .reasserting ? .on : .off
                    submenu.addItem(clientItem)
                }
                item.submenu = submenu
                menu.addItem(item)
            }
            add("Add Client…", #selector(addClient), enabled: state.canCreateClient && dialogTask == nil && actionTask == nil)
            add(state.inventoryInFlight ? "Refreshing clients…" : "Refresh", #selector(refresh),
                enabled: state.canRefresh && !state.inventoryInFlight && actionTask == nil)
            add("Sign Out", #selector(signOut), enabled: state.canSignOut && actionTask == nil)
        }
        if activation.state != .ready {
            let setupTitle = activation.state == .updateRequired && state.hasActiveTunnel
                ? "Disconnect VPN to update" : activation.state.title
            if state.statusTitle != setupTitle {
                add(setupTitle,
                    activation.state == .awaitingApproval ? #selector(openLoginItemsSettings) : nil)
            }
            if activation.state.canActivate {
                add(activation.state == .updateRequired ? "Update VPN Extension…" : "Set Up VPN…",
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

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true,
                     keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil && enabled
        let controllerActions = [#selector(toggleVPN), #selector(signIn), #selector(cancelSignIn),
                                 #selector(signOut), #selector(refresh), #selector(addClient), #selector(setUp)]
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
        else if activation.state == .ready, let identifier = state.reconnectIdentifier {
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
                    let reply = try await client.request(.prepareClient)
                    guard let creation = reply.creation else { throw CloudGatewayMacControllerFailure.invalidRequest }
                    contextId = creation.id
                    return creation.regions
                }), let contextId else { return }
                try Task.checkCancellation()
                let reply = try await client.request(.createClient, regionId: request.regionId,
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

    private func send(_ action: CloudGatewayMacControllerRequest.Action, identifier: String? = nil,
                      clearsError: Bool = true) {
        guard actionTask == nil, !isShuttingDown else { return }
        if clearsError { frontendErrorMessage = nil }
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { actionTask = nil; render() }
            let id = UUID()
            do { _ = try await client.request(action, id: id, identifier: identifier) }
            catch is CancellationError { }
            catch {
                if action != .menuWillOpen { frontendErrorMessage = client.message(for: error) }
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
            do { _ = try await client.request(.beginLogin, id: id, loginOrigin: .menu) }
            catch { frontendErrorMessage = client.message(for: error); render() }
        }
    }
    @objc private func cancelSignIn() {
        guard let id = snapshot.login?.attemptId else { return }
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await client.request(.cancelLogin, contextId: id) }
            catch { frontendErrorMessage = client.message(for: error); render() }
        }
    }
    @objc private func openSignInBrowser() {
        guard case .waitingForApproval(_, let url) = snapshot.browserState else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func setUp() {
        guard actionTask == nil, !isShuttingDown, client.snapshot != nil, client.isCurrentBuild,
              activation.state.canActivate, snapshot.canUpdateExtension else { return }
        frontendErrorMessage = nil
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { actionTask = nil; render() }
            do {
                let reply = try await client.request(.prepareExtensionUpdate)
                guard reply.accepted == true, let attemptId = reply.operationId, let target = reply.extensionTarget else {
                    frontendErrorMessage = "VPN extension update is waiting for all tunnels to disconnect"
                    return
                }
                do {
                    let started = try await client.request(.extensionUpdateStarted, contextId: attemptId)
                    guard started.accepted == true else { throw CloudGatewayMacControllerFailure.rejected }
                    activation.activate(attemptId: attemptId, target: target)
                } catch {
                    // No OS request was submitted, so clearing this reservation is safe
                    reportActivation(.failed(code: -1), attemptId: attemptId)
                    throw error
                }
            } catch is CancellationError {
            } catch {
                frontendErrorMessage = client.message(for: error)
            }
        }
        render()
    }

    private func reportActivation(_ state: CloudGatewayMacSetupState, attemptId: UUID) {
        let action: CloudGatewayMacControllerRequest.Action
        switch state {
        case .awaitingApproval: action = .extensionUpdateApproval
        case .awaitingRestart: action = .extensionUpdateRestart
        case .checkingConnection: action = .extensionUpdateFinished
        case .failed, .invalidBundle, .unavailable: action = .extensionUpdateFailed
        default: return
        }
        let previous = activationReportTask
        let requestId = UUID()
        activationReportTask = Task { [weak self] in
            await previous?.value
            guard let self, !isShuttingDown, !Task.isCancelled else { return }
            while !Task.isCancelled, !isShuttingDown {
                do {
                    let reply = try await client.request(action, id: requestId, contextId: attemptId)
                    if reply.accepted != true {
                        frontendErrorMessage = "VPN extension update changed. Refresh status before trying again"
                    } else { frontendErrorMessage = nil }
                    render()
                    return
                } catch is CancellationError { return }
                catch {
                    frontendErrorMessage = client.message(for: error)
                    render()
                    if error as? CloudGatewayMacControllerFailure == .extensionAttemptChanged { return }
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }
    @objc private func openWebsite() { NSWorkspace.shared.open(dashboard) }
    @objc private func quitApp() { quit() }

    @objc private func installCommandLineTool() {
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
        activation.resetActivationFailure()
        send(.refresh)
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

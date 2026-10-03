import AppKit
import CloudGatewayAppCore
import CloudGatewayFirebaseAuthAdapter
import CloudGatewayKit
import CloudGatewayMacCore
import CloudGatewayMacIPC
import FirebaseCore
import FirebaseFirestore
import ServiceManagement

@MainActor
final class CloudGatewayMacAppController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let activation = CloudGatewayExtensionActivationCoordinator()
    private let auth: CloudGatewayFirebaseAuthAdapter
    private let inventory: CloudGatewayMacInventoryService
    private let cache: CloudGatewayMacAccountCache
    private let profiles = CloudGatewayMacVPNProfileAdapter()
    private let configs: CloudGatewayMacConfigCoordinator
    private let dashboard = URL(string: "https://gocloudlaunch.com")!
    private var browser: CloudGatewayMacBrowserAuthCoordinator!
    private var authRegistration: CloudGatewayAuthStateListenerRegistration?
    private var user: AuthenticatedUser?
    private var options: [CloudGatewayClientOption] = []
    private var installed: [CloudGatewayMacInstalledConfig] = []
    private var profileObservation = CloudGatewayMacProfileObservation()
    private var isOffline = false
    private var errorMessage: String?
    private var sessionEpoch: UInt64 = 0
    private var sessionFence = CloudGatewayMacSessionFence()
    private var lastSelectedIdentifier: String?
    private var cancellationTask: Task<Void, Never>?
    private var profileEpoch: UInt64 = 0
    private var profileTask: Task<Void, Never>?
    private var cancellationEpoch: UInt64 = 0
    private var isShuttingDown = false
    private var inventoryTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    override init() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let firebaseOptions = FirebaseOptions(contentsOfFile: path),
              firebaseOptions.bundleID == "com.gocloudlaunch.gateway.macos" else {
            preconditionFailure("The macOS Firebase configuration is missing or has the wrong bundle ID")
        }
        FirebaseApp.configure(options: firebaseOptions)
        let database = Firestore.firestore()
        let settings = FirestoreSettings()
        settings.cacheSettings = MemoryCacheSettings()
        database.settings = settings
        auth = CloudGatewayFirebaseAuthAdapter()
        inventory = CloudGatewayMacInventoryService(auth: auth, database: database)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudGateway/macOS", isDirectory: true)
        cache = CloudGatewayMacAccountCache(directory: directory)
        let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
        let secrets: CloudGatewayMacXPCSecretClient
        do { secrets = try CloudGatewayMacXPCSecretClient(teamIdentifier: teamIdentifier) }
        catch { preconditionFailure("The macOS signing team configuration is invalid") }
        configs = CloudGatewayMacConfigCoordinator(secrets: secrets, profiles: profiles, snapshots: cache)
        super.init()
        browser = CloudGatewayMacBrowserAuthCoordinator(
            service: CloudGatewayDeviceAuthClient(originHost: "gocloudlaunch.com", dashboardOrigin: dashboard),
            auth: auth, dashboardOrigin: dashboard,
            openBrowser: { NSWorkspace.shared.open($0) },
            checkAccess: { [weak self] candidate in
                guard let self else { return false }
                do {
                    await cancellationTask?.value
                    try Task.checkCancellation()
                    let role = try await inventory.checkAccess(for: candidate)
                    try Task.checkCancellation()
                    guard auth.currentUser?.uid == candidate.uid else { throw CancellationError() }
                    try await observeRole(role, accountId: candidate.uid)
                    try Task.checkCancellation()
                    return true
                } catch CloudGatewayMacInventoryService.Failure.accessDenied {
                    try? await cache.deny(accountId: candidate.uid)
                    return false
                }
            }
        )
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        activation.onStatusChange = { [weak self] _ in self?.render() }
        profiles.onChange = { [weak self] in self?.refreshProfiles() }
        browser.onChange = { [weak self] state in self?.browserChanged(state) }
        authRegistration = auth.addAuthStateListener { [weak self] candidate in
            self?.authChanged(candidate)
        }
        render()
        activation.refreshReadiness()
        refreshProfiles()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshProfiles()
        if user != nil { refreshInventory() }
        else if auth.currentUser != nil { restoreSession() }
        render()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        sessionEpoch &+= 1
        profileEpoch &+= 1
        profileTask?.cancel()
        profileTask = nil
        authRegistration?.cancel()
        authRegistration = nil
        activation.onStatusChange = nil
        profiles.onChange = nil
        browser.onChange = nil
        cancelPendingWork()
        browser.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func quit() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }

    private func authChanged(_ candidate: AuthenticatedUser?) {
        guard !isShuttingDown else { return }
        switch browser.state {
        case .requestingCode, .waitingForApproval, .exchangingToken: return
        default: break
        }
        guard let candidate else {
            clearAccountPresentation()
            render()
            return
        }
        if candidate.uid != user?.uid {
            clearAccountPresentation()
            restoreSession()
        } else { render() }
    }

    private func browserChanged(_ state: CloudGatewayMacBrowserAuthState) {
        guard !isShuttingDown else { return }
        switch state {
        case .signedIn(let authorized):
            if user?.uid != authorized.uid {
                clearAccountPresentation()
                user = authorized
                sessionFence.changeAccount(to: authorized.uid)
                errorMessage = nil
                refreshInventory()
            }
        case .signedOut:
            if user != nil { clearAccountPresentation() }
        case .failed(let error):
            errorMessage = error.localizedDescription
        case .requestingCode, .waitingForApproval, .exchangingToken:
            errorMessage = nil
        }
        render()
    }

    private func restoreSession() {
        switch browser.state {
        case .requestingCode, .waitingForApproval, .exchangingToken: return
        default: break
        }
        guard user == nil, restorationTask == nil, let candidate = auth.currentUser,
              !auth.isCustomTokenSignInSettling, !isShuttingDown else { return }
        let epoch = sessionEpoch
        let pendingCancellation = cancellationTask
        restorationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if sessionEpoch == epoch { restorationTask = nil; render() }
            }
            do {
                await pendingCancellation?.value
                try requireCurrent(epoch)
                let role = try await inventory.checkAccess(for: candidate)
                try requireCurrent(epoch)
                guard auth.currentUser?.uid == candidate.uid else { return }
                try await observeRole(role, accountId: candidate.uid)
                try requireCurrent(epoch)
                guard auth.currentUser?.uid == candidate.uid else { return }
                user = candidate
                sessionFence.changeAccount(to: candidate.uid)
                errorMessage = nil
                refreshInventory()
            } catch CloudGatewayMacInventoryService.Failure.offline {
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                let saved = try? await cache.load(accountId: candidate.uid)
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                if let saved, CloudGatewayMacOfflinePolicy.canUseCache(
                    after: CloudGatewayMacInventoryService.Failure.offline.cacheFailure, cache: saved
                ) {
                    user = candidate
                    sessionFence.changeAccount(to: candidate.uid)
                    installed = saved.configs
                    lastSelectedIdentifier = saved.selectedIdentifier
                    isOffline = true
                    errorMessage = nil
                } else { errorMessage = "Connect to the internet to restore this account" }
            } catch CloudGatewayMacInventoryService.Failure.accessDenied {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                try? await cache.deny(accountId: candidate.uid)
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                try? auth.signOut()
                errorMessage = "Account access was denied. Sign in again after access is restored"
            } catch {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                errorMessage = "Unable to restore your session. Refresh to try again"
            }
        }
        render()
    }

    private func refreshInventory() {
        guard let account = user, inventoryTask == nil, commandTask == nil, !isShuttingDown else { return }
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        let pendingCancellation = cancellationTask
        inventoryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if sessionEpoch == epoch { inventoryTask = nil; render() }
            }
            do {
                await pendingCancellation?.value
                try requireCurrent(epoch, token: token)
                let role = try await inventory.checkAccess(for: account)
                try requireCurrent(epoch, token: token)
                try await observeRole(role, accountId: account.uid)
                try requireCurrent(epoch, token: token)
                let fetched = try await inventory.fetchOptions(for: account, role: role)
                try requireCurrent(epoch, token: token)
                try await cache.authorize(accountId: account.uid, role: role, options: fetched)
                try requireCurrent(epoch, token: token)
                let saved = try await cache.load(accountId: account.uid)
                try requireCurrent(epoch, token: token)
                options = fetched
                installed = saved.configs
                lastSelectedIdentifier = saved.selectedIdentifier
                isOffline = false
                errorMessage = nil
            } catch CloudGatewayMacInventoryService.Failure.offline {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                let saved = try? await cache.load(accountId: account.uid)
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                options = []
                if let saved, CloudGatewayMacOfflinePolicy.canUseCache(
                    after: CloudGatewayMacInventoryService.Failure.offline.cacheFailure, cache: saved
                ) {
                    installed = saved.configs
                    lastSelectedIdentifier = saved.selectedIdentifier
                } else {
                    installed = []
                    lastSelectedIdentifier = nil
                }
                isOffline = true
                errorMessage = installed.isEmpty ? "Offline. No installed configs are available for this account" : nil
            } catch CloudGatewayMacInventoryService.Failure.accessDenied {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                options = []
                installed = []
                try? await cache.deny(accountId: account.uid)
                guard sessionEpoch == epoch else { return }
                signOut()
                errorMessage = "Account access was denied. Sign in again after access is restored"
            } catch {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                options = []
                installed = []
                errorMessage = "Unable to refresh inventory. Try Refresh again"
            }
        }
        render()
    }

    private func observeRole(_ role: CloudGatewayMacAccountRole, accountId: String) async throws {
        try Task.checkCancellation()
        guard auth.currentUser?.uid == accountId else { throw CancellationError() }
        do {
            let invalidated = try await cache.observeRole(accountId: accountId, role: role)
            guard auth.currentUser?.uid == accountId else { throw CancellationError() }
            if invalidated { clearInventoryPresentation(for: accountId) }
        } catch {
            guard auth.currentUser?.uid == accountId else { throw CancellationError() }
            clearInventoryPresentation(for: accountId)
            // Failed invalidation must not restore stale privileges after relaunch
            try? auth.signOut()
            throw error
        }
    }

    private func clearInventoryPresentation(for accountId: String) {
        guard user?.uid == accountId else { return }
        options = []
        installed = []
        lastSelectedIdentifier = nil
        render()
    }

    private func refreshProfiles() {
        guard !isShuttingDown else { return }
        profileTask?.cancel()
        profileEpoch &+= 1
        let epoch = profileEpoch
        profileTask = Task { [weak self] in
            guard let self else { return }
            defer { if profileEpoch == epoch { profileTask = nil } }
            do {
                let snapshot = try await profiles.installedProfiles()
                guard profileEpoch == epoch, !Task.isCancelled else { return }
                profileObservation.didRead(snapshot)
            } catch {
                guard profileEpoch == epoch, !Task.isCancelled else { return }
                profileObservation.didFailRead()
            }
            render()
        }
    }

    private func clearAccountPresentation() {
        sessionEpoch &+= 1
        sessionFence.changeAccount(to: nil)
        lastSelectedIdentifier = nil
        cancelPendingWork()
        user = nil
        options = []
        installed = []
        isOffline = false
        errorMessage = nil
    }

    private func cancelPendingWork() {
        let pendingCommand = commandTask
        inventoryTask?.cancel()
        restorationTask?.cancel()
        commandTask?.cancel()
        inventoryTask = nil
        restorationTask = nil
        commandTask = nil
        sessionFence.invalidate()
        cancellationEpoch &+= 1
        let epoch = cancellationEpoch
        let previousCancellation = cancellationTask
        cancellationTask = Task { [weak self] in
            await previousCancellation?.value
            guard let self else { return }
            await configs.cancelPendingWork()
            await pendingCommand?.value
            await configs.waitForPendingWork()
            guard cancellationEpoch == epoch else { return }
            cancellationTask = nil
            render()
        }
    }

    private func requireCurrent(_ epoch: UInt64, token: CloudGatewayMacSessionToken? = nil) throws {
        guard sessionEpoch == epoch, !Task.isCancelled, !isShuttingDown else { throw CancellationError() }
        if let token {
            guard sessionFence.isCurrent(token), auth.currentUser?.uid == token.accountId else { throw CancellationError() }
        }
    }

    private var presentation: CloudGatewayMacMenuState {
        CloudGatewayMacMenuState(accountId: user?.uid, setupState: activation.state,
            onlineOptions: options, cachedConfigs: installed, profiles: profileObservation.profiles,
            commandInFlight: commandTask != nil || cancellationTask != nil, isOffline: isOffline,
            inventoryInFlight: inventoryTask != nil,
            hasRetainedSession: auth.currentUser != nil, lastSelectedIdentifier: lastSelectedIdentifier)
    }

    private var visibleErrorMessage: String? {
        (user != nil ? profileObservation.errorMessage : nil) ?? errorMessage
    }

    private var canStartClientCreation: Bool {
        user != nil && !isOffline && inventoryTask == nil && commandTask == nil
            && cancellationTask == nil && !isShuttingDown
    }

    private func render() {
        guard !isShuttingDown else { return }
        let state = presentation
        statusItem.button?.image = CloudGatewayStatusGlyph.image(isActive: state.hasActiveTunnel)
        menu.removeAllItems()
        let status = add(state.statusTitle, #selector(toggleVPN), enabled: state.canToggleVPN)
        if activation.state == .awaitingApproval, state.statusTitle == activation.state.title {
            status.action = #selector(openLoginItemsSettings)
            status.isEnabled = true
        }
        status.state = user != nil && state.hasActiveTunnel ? .on : .off
        if state.canToggleVPN {
            status.toolTip = state.canTurnOff ? "Disconnect VPN" : "Connect using the last-used client"
        }
        if let visibleErrorMessage { add(visibleErrorMessage) }
        if user == nil {
            switch browser.state {
            case .requestingCode: add("Requesting sign-in code…"); add("Cancel Sign In", #selector(cancelSignIn))
            case .waitingForApproval(let code, _):
                add("Browser sign-in code: \(code)")
                add("Open Browser", #selector(openSignInBrowser))
                add("Cancel Sign In", #selector(cancelSignIn))
            case .exchangingToken: add("Completing sign-in…"); add("Cancel Sign In", #selector(cancelSignIn))
            default:
                add(restorationTask == nil ? "Sign In…" : "Restoring session…", #selector(signIn),
                    enabled: restorationTask == nil && !auth.isCustomTokenSignInSettling)
                if auth.currentUser != nil { add("Refresh Session", #selector(refresh)) }
                if state.canSignOut { add("Sign Out", #selector(signOut)) }
                if auth.isCustomTokenSignInSettling {
                    add("Sign-in cleanup is still pending")
                    add("Retry Sign-in Cleanup", #selector(signOut))
                }
            }
        } else {
            let visible = Set(state.groups.flatMap(\.rows).map(\.identifier))
            if profileObservation.profiles.contains(where: { $0.needsConfirmedStop && !visible.contains($0.identifier) }) {
                add("Connecting replaces the current CloudGateway VPN")
            }
            for group in state.groups {
                let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for row in group.rows {
                    let title = row.identifier == lastSelectedIdentifier ? "\(row.title) (Last used)" : row.title
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
            add("Add Client…", #selector(addClient), enabled: canStartClientCreation)
            add("Refresh", #selector(refresh), enabled: state.canRefresh && inventoryTask == nil)
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
        connectClient(identifier: identifier)
    }

    @objc private func toggleVPN() {
        let state = presentation
        guard state.canToggleVPN else { return }
        if state.canTurnOff { turnOff() }
        else if let identifier = state.reconnectIdentifier { connectClient(identifier: identifier) }
    }

    private func connectClient(identifier: String) {
        guard let account = user,
              presentation.groups.flatMap(\.rows).contains(where: { $0.identifier == identifier && $0.isEnabled }),
              commandTask == nil, inventoryTask == nil, auth.currentUser?.uid == account.uid else { return }
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        let option = options.first { "\(account.uid)/\($0.client.regionId)/\($0.client.clientId)" == identifier }
        let saved = installed.first { $0.identifier == identifier && $0.accountId == account.uid }
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionEpoch == epoch { commandTask = nil; refreshProfiles(); render() } }
            do {
                try requireCurrent(epoch, token: token)
                let latestProfiles = try await profiles.installedProfiles()
                try requireCurrent(epoch, token: token)
                let savedProfileExists = saved.map { config in
                    latestProfiles.contains { $0.identifier == config.identifier && $0.reference == (try? config.reference) }
                } ?? false
                var config: CloudGatewayMacInstalledConfig
                if let saved, savedProfileExists, isOffline || option.map({ CloudGatewayConfigSelection.configMatches(saved.snapshot, option: $0) }) == true {
                    config = saved
                } else if let option, !isOffline {
                    config = try await configs.install(option: option, accountId: account.uid)
                } else { throw CloudGatewayMacConfigError.unavailable }
                try requireCurrent(epoch, token: token)
                do {
                    try await configs.connect(config)
                } catch CloudGatewayMacConfigError.unavailable {
                    try requireCurrent(epoch, token: token)
                    guard config == saved, let option, !isOffline else { throw CloudGatewayMacConfigError.unavailable }
                    config = try await configs.install(option: option, accountId: account.uid)
                    try requireCurrent(epoch, token: token)
                    try await configs.connect(config)
                }
                try requireCurrent(epoch, token: token)
                try await cache.select(identifier: config.identifier, accountId: account.uid)
                try requireCurrent(epoch, token: token)
                let savedMetadata = try await cache.load(accountId: account.uid)
                try requireCurrent(epoch, token: token)
                installed = savedMetadata.configs
                lastSelectedIdentifier = savedMetadata.selectedIdentifier
                try requireCurrent(epoch, token: token)
                errorMessage = nil
            } catch {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                switch error as? CloudGatewayMacConfigError {
                case .profileInstallationFailed:
                    errorMessage = "Unable to save the VPN profile. Refresh before trying again"
                case .secretCommitFailed:
                    errorMessage = "The VPN profile was saved, but secure storage did not finish. Refresh before retrying"
                case .snapshotPersistenceFailed:
                    errorMessage = "The VPN profile was saved, but offline metadata could not be saved. Refresh before retrying"
                default:
                    errorMessage = "VPN command could not finish. Refresh preferences before trying again"
                }
            }
        }
        render()
    }

    @objc private func addClient() {
        guard canStartClientCreation, let account = user else { return }
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionEpoch == epoch { commandTask = nil; render() } }
            var createdClientName: String?
            var creationAttempted = false
            do {
                try requireCurrent(epoch, token: token)
                let enabledRegions = try await inventory.fetchCreateRegions(for: account)
                try requireCurrent(epoch, token: token)
                let creatableRegions = CloudGatewayConfigSelection.sortedRegions(enabledRegions.filter {
                    $0.enabled && $0.capacity?.isKnown == true && $0.capacity?.isAtCapacity == false
                })
                guard !creatableRegions.isEmpty else {
                    if enabledRegions.isEmpty {
                        errorMessage = "No enabled regions are available"
                    } else if enabledRegions.contains(where: { $0.capacity?.isKnown != true }) {
                        errorMessage = "Unable to check region capacity. Try Add Client again"
                    } else {
                        errorMessage = "No region currently has available client capacity"
                    }
                    return
                }
                guard let request = promptForClient(in: creatableRegions, account: account, epoch: epoch) else {
                    render()
                    return
                }
                try requireCurrent(epoch, token: token)
                let role = try await inventory.checkAccess(for: account)
                try requireCurrent(epoch, token: token)
                try await observeRole(role, accountId: account.uid)
                try requireCurrent(epoch, token: token)
                creationAttempted = true
                let created = try await inventory.createClient(
                    regionId: request.regionId, clientName: request.clientName, for: account
                )
                try requireCurrent(epoch, token: token)
                createdClientName = created

                let fetched = try await inventory.fetchOptions(for: account, role: role)
                try requireCurrent(epoch, token: token)
                try await cache.authorize(accountId: account.uid, role: role, options: fetched)
                try requireCurrent(epoch, token: token)
                let saved = try await cache.load(accountId: account.uid)
                try requireCurrent(epoch, token: token)
                options = fetched
                installed = saved.configs
                lastSelectedIdentifier = saved.selectedIdentifier
                errorMessage = nil
            } catch CloudGatewayMacInventoryService.Failure.accessDenied, CloudGatewayAppError.apiAccessDenied(_) {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                clearInventoryPresentation(for: account.uid)
                try? await cache.deny(accountId: account.uid)
                guard sessionEpoch == epoch, !Task.isCancelled, auth.currentUser?.uid == account.uid else { return }
                signOut()
                errorMessage = "Account access was denied. Sign in again after access is restored"
            } catch CloudGatewayAppError.accessDenied(let message) {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                errorMessage = message
            } catch {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                if let createdClientName {
                    errorMessage = "\(createdClientName) was created, but the client list could not refresh. Choose Refresh before trying again"
                } else if creationAttempted {
                    errorMessage = "Could not confirm whether the client was created. Refresh the client list before trying again"
                } else {
                    errorMessage = "Unable to load available regions. Refresh and try again"
                }
            }
        }
        render()
    }

    private func promptForClient(
        in regions: [CloudGatewayRegion], account: AuthenticatedUser, epoch: UInt64
    ) -> (regionId: String, clientName: String)? {
        let regionPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for region in regions {
            let item = NSMenuItem(title: "\(region.displayName) · \(region.capacity?.displayText ?? "Capacity unavailable")",
                                  action: nil, keyEquivalent: "")
            item.representedObject = region.regionId
            regionPicker.menu?.addItem(item)
        }
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.placeholderString = "For example, Work Mac"
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Region"), regionPicker,
            NSTextField(labelWithString: "Display name"), nameField
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        NSLayoutConstraint.activate([
            regionPicker.widthAnchor.constraint(equalToConstant: 320),
            nameField.widthAnchor.constraint(equalToConstant: 320)
        ])
        stack.setFrameSize(stack.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Add VPN Client"
        alert.informativeText = "Create a client in the selected region."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn,
              sessionEpoch == epoch, !isShuttingDown, user?.uid == account.uid,
              auth.currentUser?.uid == account.uid,
              sessionFence.currentToken?.accountId == account.uid else { return nil }
        let clientName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientName.isEmpty, clientName.unicodeScalars.count <= 80,
              let regionId = regionPicker.selectedItem?.representedObject as? String else {
            errorMessage = "Enter a client name with 1 to 80 characters and choose a region"
            return nil
        }
        return (regionId, clientName)
    }

    @objc private func turnOff() {
        guard presentation.canTurnOff, commandTask == nil else { return }
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionEpoch == epoch { commandTask = nil; refreshProfiles(); render() } }
            do {
                try requireCurrent(epoch, token: token)
                try await configs.turnOff()
                try requireCurrent(epoch, token: token)
                errorMessage = nil
            } catch {
                if sessionEpoch == epoch, !Task.isCancelled {
                    errorMessage = "VPN has not confirmed stop. Try again after checking System Settings"
                }
            }
        }
        render()
    }

    @objc private func signIn() {
        guard restorationTask == nil, !isShuttingDown else { return }
        errorMessage = nil
        if auth.currentUser != nil { restoreSession() }
        else { _ = browser.begin() }
        render()
    }

    @objc private func cancelSignIn() {
        clearAccountPresentation()
        browser.cancel()
        render()
    }
    @objc private func openSignInBrowser() { browser.openBrowser() }
    @objc private func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func setUp() { activation.activate() }
    @objc private func openWebsite() { NSWorkspace.shared.open(dashboard) }
    @objc private func quitApp() { quit() }

    @objc private func signOut() {
        clearAccountPresentation()
        browser.signOut()
        render()
    }

    @objc private func refresh() {
        refreshProfiles()
        activation.refreshReadiness()
        if user != nil { refreshInventory() }
        else { restoreSession() }
        render()
    }

    deinit {
        authRegistration?.cancel()
    }

    @objc private func toggleLaunchAtLogin() {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch SMAppService.mainApp.status {
                case .enabled: try await SMAppService.mainApp.unregister()
                case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
                case .notRegistered, .notFound: try SMAppService.mainApp.register()
                @unknown default: errorMessage = "Launch at Login needs attention in System Settings"
                }
            } catch { errorMessage = "Unable to change Launch at Login. Check System Settings" }
            render()
        }
    }
}

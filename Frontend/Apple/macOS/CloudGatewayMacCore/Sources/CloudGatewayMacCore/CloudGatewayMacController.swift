import CloudGatewayAppCore
import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation

@MainActor
public final class CloudGatewayMacController {
    public var onChange: (() -> Void)?

    private let auth: any CloudGatewayMacControllerAuthServicing
    private let inventory: any CloudGatewayMacInventoryServicing
    private let cache: CloudGatewayMacAccountCache
    private let profiles: any CloudGatewayMacProfileAdapter
    private let configs: CloudGatewayMacConfigCoordinator
    private let controllerId = UUID()
    private var setupState: CloudGatewayMacSetupState = .required
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
    private var isStarted = false
    private var isShuttingDown = false
    private var inventoryTask: Task<Void, Never>?
    private var inventoryEpoch: UInt64 = 0
    private var lastInventoryRefresh: ContinuousClock.Instant?
    private var restorationTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    public init(
        auth: any CloudGatewayMacControllerAuthServicing,
        deviceAuth: any CloudGatewayDeviceAuthServicing,
        inventory: any CloudGatewayMacInventoryServicing,
        profiles: any CloudGatewayMacProfileAdapter,
        cache: CloudGatewayMacAccountCache,
        configs: CloudGatewayMacConfigCoordinator,
        dashboardOrigin: URL
    ) {
        self.auth = auth
        self.inventory = inventory
        self.profiles = profiles
        self.cache = cache
        self.configs = configs
        browser = CloudGatewayMacBrowserAuthCoordinator(
            service: deviceAuth, auth: auth, dashboardOrigin: dashboardOrigin,
            checkAccess: { [weak self] candidate in
                guard let self else { return false }
                let epoch = sessionEpoch
                do {
                    await cancellationTask?.value
                    try requireCurrent(epoch)
                    let role = try await inventory.checkAccess(for: candidate)
                    try requireCurrent(epoch)
                    guard auth.currentUser?.uid == candidate.uid else { throw CancellationError() }
                    try await observeRole(role, accountId: candidate.uid)
                    try requireCurrent(epoch)
                    return true
                } catch CloudGatewayMacInventoryError.accessDenied {
                    try requireCurrent(epoch)
                    try? await cache.deny(accountId: candidate.uid)
                    return false
                }
            }
        )
    }

    public func start() {
        guard !isStarted, !isShuttingDown else { return }
        isStarted = true
        browser.onChange = { [weak self] state in self?.browserChanged(state) }
        authRegistration = auth.addAuthStateListener { [weak self] candidate in
            self?.authChanged(candidate)
        }
        authChanged(auth.currentUser)
        refreshProfiles()
        notifyChange()
    }

    public func setSetupState(_ state: CloudGatewayMacSetupState) {
        guard !isShuttingDown, setupState != state else { return }
        setupState = state
        notifyChange()
    }

    public var hasPendingWork: Bool {
        if inventoryTask != nil || restorationTask != nil || commandTask != nil
            || cancellationTask != nil || profileTask != nil || auth.isCustomTokenSignInSettling {
            return true
        }
        switch browser.state {
        case .requestingCode, .waitingForApproval, .exchangingToken: return true
        default: return false
        }
    }

    public func snapshot(setupState: CloudGatewayMacSetupState) -> CloudGatewayMacControllerSnapshot {
        let state = presentation(setupState: setupState)
        let groups = state.groups
        let visible = Set(groups.flatMap(\.rows).map(\.identifier))
        return CloudGatewayMacControllerSnapshot(
            groups: groups, statusTitle: state.statusTitle,
            canToggleVPN: state.canToggleVPN, canTurnOff: state.canTurnOff,
            hasActiveTunnel: state.hasActiveTunnel, reconnectIdentifier: state.reconnectIdentifier,
            canRefresh: state.canRefresh, canSignOut: state.canSignOut,
            accountId: user?.uid, lastSelectedIdentifier: lastSelectedIdentifier,
            browserState: visibleBrowserState, isRestoringSession: restorationTask != nil,
            isAuthSettling: auth.isCustomTokenSignInSettling,
            hasRetainedSession: auth.currentUser != nil, inventoryInFlight: inventoryTask != nil,
            canCreateClient: canStartClientCreation, errorMessage: visibleErrorMessage,
            hasUnlistedActiveProfile: user != nil && profileObservation.profiles.contains {
                $0.needsConfirmedStop && !visible.contains($0.identifier)
            }
        )
    }

    public func menuWillOpen() {
        guard isStarted, !isShuttingDown else { return }
        refreshProfiles()
        if user != nil { refreshInventory(force: false) }
        else if auth.currentUser != nil { restoreSession() }
        notifyChange()
    }

    public func profilesDidChange() {
        refreshProfiles()
    }

    public func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        sessionEpoch &+= 1
        profileEpoch &+= 1
        profileTask?.cancel()
        profileTask = nil
        authRegistration?.cancel()
        authRegistration = nil
        browser.onChange = nil
        if isStarted {
            cancelPendingWork()
            browser.cancel()
        }
        onChange = nil
    }

    private func authChanged(_ candidate: AuthenticatedUser?) {
        guard isStarted, !isShuttingDown else { return }
        switch browser.state {
        case .requestingCode, .waitingForApproval, .exchangingToken: return
        default: break
        }
        guard let candidate else {
            clearAccountPresentation()
            notifyChange()
            return
        }
        if candidate.uid != user?.uid {
            clearAccountPresentation()
            restoreSession()
        } else { notifyChange() }
    }

    private func browserChanged(_ state: CloudGatewayMacBrowserAuthState) {
        guard isStarted, !isShuttingDown else { return }
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
        notifyChange()
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
                if sessionEpoch == epoch { restorationTask = nil; notifyChange() }
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
            } catch CloudGatewayMacInventoryError.offline {
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                let saved = try? await cache.load(accountId: candidate.uid)
                guard sessionEpoch == epoch, !Task.isCancelled,
                      auth.currentUser?.uid == candidate.uid else { return }
                if let saved, CloudGatewayMacOfflinePolicy.canUseCache(
                    after: CloudGatewayMacInventoryError.offline.cacheFailure, cache: saved
                ) {
                    user = candidate
                    sessionFence.changeAccount(to: candidate.uid)
                    installed = saved.configs
                    lastSelectedIdentifier = saved.selectedIdentifier
                    isOffline = true
                    errorMessage = nil
                } else { errorMessage = "Unable to reach CloudGateway to restore this account" }
            } catch CloudGatewayMacInventoryError.accessDenied {
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
        notifyChange()
    }

    private func refreshInventory(force: Bool = true) {
        guard let account = user, inventoryTask == nil, commandTask == nil, !isShuttingDown else { return }
        let now = ContinuousClock().now
        if !force, let lastInventoryRefresh, lastInventoryRefresh.duration(to: now) < .seconds(30) { return }
        lastInventoryRefresh = now
        inventoryEpoch &+= 1
        let refreshEpoch = inventoryEpoch
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        let pendingCancellation = cancellationTask
        inventoryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if sessionEpoch == epoch, inventoryEpoch == refreshEpoch { inventoryTask = nil; notifyChange() }
            }
            do {
                await pendingCancellation?.value
                try requireCurrent(epoch, token: token)
                if options.isEmpty {
                    let saved = try await cache.load(accountId: account.uid)
                    try requireCurrent(epoch, token: token)
                    installed = saved.configs
                    lastSelectedIdentifier = saved.selectedIdentifier
                    notifyChange()
                }
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
            } catch CloudGatewayMacInventoryError.offline {
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                let saved = try? await cache.load(accountId: account.uid)
                guard sessionEpoch == epoch, !Task.isCancelled else { return }
                options = []
                if let saved, CloudGatewayMacOfflinePolicy.canUseCache(
                    after: CloudGatewayMacInventoryError.offline.cacheFailure, cache: saved
                ) {
                    installed = saved.configs
                    lastSelectedIdentifier = saved.selectedIdentifier
                } else {
                    installed = []
                    lastSelectedIdentifier = nil
                }
                isOffline = true
                errorMessage = installed.isEmpty ? "Unable to reach CloudGateway. No installed configs are available for this account" : nil
            } catch CloudGatewayMacInventoryError.accessDenied {
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
        notifyChange()
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
        notifyChange()
    }

    private func refreshProfiles() {
        guard isStarted, !isShuttingDown else { return }
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
            notifyChange()
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
        lastInventoryRefresh = nil
        errorMessage = nil
    }

    private func cancelPendingWork() {
        let pendingCommand = commandTask
        inventoryTask?.cancel()
        inventoryEpoch &+= 1
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
            notifyChange()
        }
    }

    private func requireCurrent(_ epoch: UInt64, token: CloudGatewayMacSessionToken? = nil) throws {
        guard isStarted, sessionEpoch == epoch, !Task.isCancelled, !isShuttingDown else { throw CancellationError() }
        if let token {
            guard sessionFence.isCurrent(token), auth.currentUser?.uid == token.accountId else { throw CancellationError() }
        }
    }

    private func presentation(setupState: CloudGatewayMacSetupState) -> CloudGatewayMacMenuState {
        CloudGatewayMacMenuState(accountId: user?.uid, setupState: setupState,
            onlineOptions: options, cachedConfigs: installed, profiles: profileObservation.profiles,
            commandInFlight: commandTask != nil || cancellationTask != nil || !isStarted || isShuttingDown,
            isOffline: isOffline, inventoryInFlight: inventoryTask != nil,
            hasRetainedSession: auth.currentUser != nil, lastSelectedIdentifier: lastSelectedIdentifier)
    }

    private var visibleErrorMessage: String? {
        (user != nil ? profileObservation.errorMessage : nil) ?? errorMessage
    }

    private var visibleBrowserState: CloudGatewayMacBrowserAuthState {
        if case .signedIn(let authorized) = browser.state, authorized.uid != user?.uid { return .signedOut }
        return browser.state
    }

    private var canStartClientCreation: Bool {
        user != nil && inventoryTask == nil && commandTask == nil
            && cancellationTask == nil && isStarted && !isShuttingDown
            && auth.currentUser?.uid == user?.uid
    }

    private func notifyChange() {
        guard isStarted, !isShuttingDown else { return }
        onChange?()
    }

    @discardableResult
    public func connectClient(identifier: String) -> Bool {
        guard isStarted, !isShuttingDown, setupState == .ready, let account = user,
              presentation(setupState: setupState).groups.flatMap(\.rows).contains(where: { $0.identifier == identifier && $0.isEnabled }),
              commandTask == nil, auth.currentUser?.uid == account.uid else { return false }
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        let option = options.first { "\(account.uid)/\($0.client.regionId)/\($0.client.clientId)" == identifier }
        let saved = installed.first { $0.identifier == identifier && $0.accountId == account.uid }
        inventoryTask?.cancel()
        inventoryTask = nil
        inventoryEpoch &+= 1
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionEpoch == epoch { commandTask = nil; refreshProfiles(); notifyChange() } }
            do {
                try requireCurrent(epoch, token: token)
                let latestProfiles = try await profiles.installedProfiles()
                try requireCurrent(epoch, token: token)
                let savedProfileExists = saved.map { config in
                    latestProfiles.contains { $0.identifier == config.identifier && $0.reference == (try? config.reference) }
                } ?? false
                var config: CloudGatewayMacInstalledConfig
                if let saved, isOffline || option == nil || option.map({ CloudGatewayConfigSelection.configMatches(saved.snapshot, option: $0) }) == true {
                    let authorized = try await cache.load(accountId: account.uid)
                    try requireCurrent(epoch, token: token)
                    guard authorized.accessAllowed, authorized.configs.contains(where: {
                        $0.identifier == saved.identifier && $0.snapshot.configHash == saved.snapshot.configHash
                            && $0.snapshot.secretReference == saved.snapshot.secretReference
                    }) else { throw CloudGatewayMacConfigError.unavailable }
                    config = saved
                } else if let option, !isOffline {
                    config = try await configs.install(option: option, accountId: account.uid)
                } else { throw CloudGatewayMacConfigError.unavailable }
                try requireCurrent(epoch, token: token)
                do {
                    if config == saved, !savedProfileExists { try await configs.restore(config) }
                    try requireCurrent(epoch, token: token)
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
                if error as? CloudGatewayMacSecretError == .storageFailure {
                    errorMessage = "Unable to access secure VPN storage"
                    return
                }
                switch error as? CloudGatewayMacConfigError {
                case .unavailable:
                    errorMessage = "Saved VPN configuration is unavailable. Refresh and try again"
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
        notifyChange()
        return true
    }

    public func clientCreationContext() -> CloudGatewayMacClientCreationContext? {
        guard canStartClientCreation, let session = sessionFence.currentToken else { return nil }
        return CloudGatewayMacClientCreationContext(session: session, controllerId: controllerId)
    }

    public func loadCreateRegions(context: CloudGatewayMacClientCreationContext) async throws -> [CloudGatewayRegion] {
        guard canStartClientCreation, let account = user,
              context.controllerId == controllerId, sessionFence.isCurrent(context.session),
              context.session.accountId == account.uid else {
            throw CancellationError()
        }
        let epoch = sessionEpoch
        let token = context.session
        do {
            try requireCurrent(epoch, token: token)
            let regions = try await inventory.fetchCreateRegions(for: account)
            try requireCurrent(epoch, token: token)
            return regions
        } catch CloudGatewayMacInventoryError.accessDenied, CloudGatewayAppError.apiAccessDenied(_) {
            try requireCurrent(epoch, token: token)
            clearInventoryPresentation(for: account.uid)
            try? await cache.deny(accountId: account.uid)
            try requireCurrent(epoch, token: token)
            signOut()
            errorMessage = "Account access was denied. Sign in again after access is restored"
            notifyChange()
            throw CloudGatewayMacInventoryError.accessDenied
        } catch CloudGatewayAppError.accessDenied(let message) {
            try requireCurrent(epoch, token: token)
            errorMessage = message
            notifyChange()
            throw CloudGatewayAppError.accessDenied(message)
        } catch {
            try requireCurrent(epoch, token: token)
            errorMessage = "Unable to load available regions. Refresh and try again"
            notifyChange()
            throw error
        }
    }

    @discardableResult
    public func createClient(
        regionId: String,
        clientName: String,
        context: CloudGatewayMacClientCreationContext
    ) -> Bool {
        guard canStartClientCreation, let account = user,
              context.controllerId == controllerId, sessionFence.isCurrent(context.session),
              context.session.accountId == account.uid else { return false }
        let epoch = sessionEpoch
        let token = context.session
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionEpoch == epoch { commandTask = nil; notifyChange() } }
            var clientWasCreated = false
            var creationAttempted = false
            do {
                try requireCurrent(epoch, token: token)
                let role = try await inventory.checkAccess(for: account)
                try requireCurrent(epoch, token: token)
                try await observeRole(role, accountId: account.uid)
                try requireCurrent(epoch, token: token)
                creationAttempted = true
                _ = try await inventory.createClient(
                    regionId: regionId, clientName: clientName, for: account
                )
                try requireCurrent(epoch, token: token)
                clientWasCreated = true

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
            } catch CloudGatewayMacInventoryError.accessDenied, CloudGatewayAppError.apiAccessDenied(_) {
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
                if clientWasCreated {
                    errorMessage = "Client was created, but the client list could not refresh. Choose Refresh before trying again"
                } else if creationAttempted {
                    errorMessage = "Could not confirm whether the client was created. Refresh the client list before trying again"
                } else {
                    errorMessage = "Unable to load available regions. Refresh and try again"
                }
            }
        }
        notifyChange()
        return true
    }

    @discardableResult
    public func turnOff() -> Bool {
        guard isStarted, !isShuttingDown, presentation(setupState: setupState).canTurnOff, commandTask == nil else { return false }
        let epoch = sessionEpoch
        let token = sessionFence.currentToken
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionEpoch == epoch { commandTask = nil; refreshProfiles(); notifyChange() } }
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
        notifyChange()
        return true
    }

    public func signIn() {
        guard isStarted, restorationTask == nil, !isShuttingDown else { return }
        errorMessage = nil
        if auth.currentUser != nil { restoreSession() }
        else { _ = browser.begin() }
        notifyChange()
    }

    public func cancelSignIn() {
        guard isStarted, !isShuttingDown else { return }
        clearAccountPresentation()
        browser.cancel()
        notifyChange()
    }

    public func signOut() {
        guard isStarted, !isShuttingDown else { return }
        clearAccountPresentation()
        browser.signOut()
        notifyChange()
    }

    public func refresh() {
        guard isStarted, !isShuttingDown else { return }
        refreshProfiles()
        if user != nil { refreshInventory() }
        else { restoreSession() }
        notifyChange()
    }

    deinit {
        authRegistration?.cancel()
    }
}
